#!/usr/bin/env bash
# End-to-end CNPG restore drill for the games cluster (proves the S3 backups are RECOVERABLE, not
# just that they upload). Stands up a throwaway canary Postgres, seeds rows, backs up to
# s3://andusystems-dr/cnpg/dr-drill, then RECOVERS into a second cluster from that same S3 path and
# checks the row counts match. Safe: everything lives in a throwaway namespace and never touches
# games-db / games-db-uat / forge-db. Idempotent (unique serverName + namespace per run).
#
# This exercises the exact restore path a redeploy relies on (bootstrap.recovery + externalClusters
# barmanObjectStore). Model: andusystems-platform/scripts/dr-drill.sh. Run monthly (ROADMAP cross-cut).
#
# Requires: KUBECONFIG pointing at the games cluster (with the CNPG operator installed),
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the environment, and the andusystems-dr bucket.
# Region us-east-1 (bucket default; endpointURL omitted -> default AWS S3).
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"
: "${KUBECONFIG:?KUBECONFIG must point at the games cluster}"

DR_BUCKET=${DR_BUCKET:-andusystems-dr}
DRILL_STORE=${DRILL_STORE:-dr-drill}                 # s3://$DR_BUCKET/cnpg/$DRILL_STORE
SRV="drill-$(date +%s)"                              # unique serverName so a re-run never reads stale backups
NS="dr-drill-$(date +%s)"
K() { kubectl "$@"; }

echo "==> Create canary namespace $NS (serverName=$SRV)"
K create ns "$NS"
cleanup() { K delete ns "$NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Seed cnpg-backup-creds (AWS) into $NS"
K -n "$NS" create secret generic cnpg-backup-creds \
  --from-literal=ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | K -n "$NS" apply -f -

echo "==> Create source cluster 'drill' backing up to s3://$DR_BUCKET/cnpg/$DRILL_STORE"
cat <<EOF | K -n "$NS" apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: drill }
spec:
  instances: 1
  storage: { size: 1Gi }        # cluster-default storageClass (local-path on k3s)
  env:
    - { name: AWS_REGION, value: "us-east-1" }
  backup:
    barmanObjectStore:
      serverName: ${SRV}
      destinationPath: s3://${DR_BUCKET}/cnpg/${DRILL_STORE}
      s3Credentials:
        accessKeyId:     { name: cnpg-backup-creds, key: ACCESS_KEY_ID }
        secretAccessKey: { name: cnpg-backup-creds, key: SECRET_ACCESS_KEY }
      wal:  { compression: gzip }
      data: { compression: gzip }
EOF

echo "==> Wait for source ready"
K -n "$NS" wait --for=condition=Ready cluster/drill --timeout=10m

echo "==> Seed canary rows"
K -n "$NS" exec drill-1 -- psql -c "create table canary(i int); insert into canary select generate_series(1,1000);"
SEED_COUNT=$(K -n "$NS" exec drill-1 -- psql -At -c "select count(*) from canary;")
echo "    seeded rows: $SEED_COUNT"

echo "==> Trigger on-demand backup (uploads base + WAL to S3)"
cat <<EOF | K -n "$NS" apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: drill-backup }
spec:
  cluster: { name: drill }
EOF
for _ in $(seq 1 60); do
  phase=$(K -n "$NS" get backup drill-backup -o jsonpath='{.status.phase}' 2>/dev/null || true)
  echo "    backup phase: ${phase:-<pending>}"
  [[ "$phase" == "completed" ]] && break
  [[ "$phase" == "failed" ]] && { echo "BACKUP FAILED"; exit 1; }
  sleep 10
done
[[ "$phase" == "completed" ]] || { echo "backup did not complete in time"; exit 1; }

echo "==> RECOVER into a second cluster 'drill-restored' from the same S3 path"
cat <<EOF | K -n "$NS" apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: drill-restored }
spec:
  instances: 1
  storage: { size: 1Gi }
  env:
    - { name: AWS_REGION, value: "us-east-1" }
  bootstrap:
    recovery: { source: origin }
  externalClusters:
    - name: origin
      barmanObjectStore:
        serverName: ${SRV}
        destinationPath: s3://${DR_BUCKET}/cnpg/${DRILL_STORE}
        s3Credentials:
          accessKeyId:     { name: cnpg-backup-creds, key: ACCESS_KEY_ID }
          secretAccessKey: { name: cnpg-backup-creds, key: SECRET_ACCESS_KEY }
        wal:  { compression: gzip }
        data: { compression: gzip }
EOF

echo "==> Wait for restored cluster ready"
K -n "$NS" wait --for=condition=Ready cluster/drill-restored --timeout=15m

RESTORE_COUNT=$(K -n "$NS" exec drill-restored-1 -- psql -At -c "select count(*) from canary;")
echo "==> seeded=$SEED_COUNT  restored=$RESTORE_COUNT"
if [[ "$SEED_COUNT" == "$RESTORE_COUNT" ]]; then
  echo "✓ DR RESTORE DRILL PASSED — row counts match."
else
  echo "✗ DR RESTORE DRILL FAILED — row counts differ."
  exit 1
fi
