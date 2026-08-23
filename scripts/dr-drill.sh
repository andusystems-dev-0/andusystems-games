#!/usr/bin/env bash
# End-to-end CNPG DR drill for the games cluster — proves the EXACT redeploy contract used by
# apps/cnpg: a cluster can be destroyed and rebuilt in place, recovering from its S3 barman backups
# on the SAME serverName and then continuing to archive to it. Safe: everything lives in a throwaway
# namespace and never touches games-db / games-db-uat / forge-db.
#
# Phases (mirroring genesis → nightly backup → redeploy → rebuild → keep running → redeploy again):
#   1. genesis cluster (initdb) archiving to serverName S; seed rows; base backup to S.
#   2. DESTROY it (as `redeploy.yml` does), rebuild in place: bootstrap.recovery from S AND archive to S.
#      Verify the rows came back.
#   3. Keep running: insert more rows, take ANOTHER backup to S — proves continue-archiving to the same
#      store works (no serverName collision) after a recovery.
#   4. DESTROY + rebuild AGAIN — verify the post-recovery writes (step 3) are themselves recoverable.
#
# Requires: KUBECONFIG at the games cluster (CNPG operator installed), AWS creds in env, andusystems-dr
# bucket. Run via .github/workflows/ops.yml (op=dr-drill). Region us-east-1 (bucket default).
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"
: "${KUBECONFIG:?KUBECONFIG must point at the games cluster}"

DR_BUCKET=${DR_BUCKET:-andusystems-dr}
DRILL_STORE=${DRILL_STORE:-dr-drill}
SRV="drill-$(date +%s)"                 # unique serverName so a re-run never reads stale backups
NS="dr-drill-$(date +%s)"
DEST="s3://${DR_BUCKET}/cnpg/${DRILL_STORE}"
K() { kubectl -n "$NS" "$@"; }

echo "==> namespace $NS  serverName $SRV  dest $DEST"
kubectl create ns "$NS"
trap 'kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true' EXIT

K create secret generic cnpg-backup-creds \
  --from-literal=ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | K apply -f -

# barmanObjectStore block reused for backup + externalCluster (same serverName = recover-and-continue).
store_block() {
  cat <<EOF
      serverName: ${SRV}
      destinationPath: ${DEST}
      s3Credentials:
        accessKeyId:     { name: cnpg-backup-creds, key: ACCESS_KEY_ID }
        secretAccessKey: { name: cnpg-backup-creds, key: SECRET_ACCESS_KEY }
      wal:  { compression: gzip }
      data: { compression: gzip }
EOF
}

genesis_cluster() {
  cat <<EOF | K apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: drill, annotations: { cnpg.io/skipEmptyWalArchiveCheck: "true" } }
spec:
  instances: 1
  storage: { size: 1Gi }
  env: [ { name: AWS_REGION, value: "us-east-1" } ]
  backup:
    barmanObjectStore:
$(store_block)
EOF
}

recover_cluster() {   # rebuild in place: recover from S, then continue archiving to S
  cat <<EOF | K apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: drill, annotations: { cnpg.io/skipEmptyWalArchiveCheck: "true" } }
spec:
  instances: 1
  storage: { size: 1Gi }
  env: [ { name: AWS_REGION, value: "us-east-1" } ]
  backup:
    barmanObjectStore:
$(store_block)
  bootstrap:
    recovery: { source: origin }
  externalClusters:
    - name: origin
      barmanObjectStore:
$(store_block)
EOF
}

backup_now() {   # $1 = backup name
  cat <<EOF | K apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: $1 }
spec: { cluster: { name: drill } }
EOF
  for _ in $(seq 1 60); do
    p=$(K get backup "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$p" = "completed" ] && { echo "    backup $1: completed"; return 0; }
    [ "$p" = "failed" ] && { echo "    backup $1: FAILED"; K get backup "$1" -o jsonpath='{.status.error}{"\n"}'; return 1; }
    sleep 10
  done
  echo "    backup $1 did not complete in time"; return 1
}

count() { K exec drill-1 -- psql -At -c "select count(*) from canary;" 2>/dev/null; }

echo "== PHASE 1: genesis (initdb) + seed + base backup =="
genesis_cluster
K wait --for=condition=Ready cluster/drill --timeout=10m
K exec drill-1 -- psql -c "create table canary(i int); insert into canary select generate_series(1,1000);"
echo "    seeded: $(count) rows"
backup_now drill-backup-1

echo "== PHASE 2: DESTROY + rebuild-in-place (recover from same serverName) =="
K delete cluster drill --timeout=5m
recover_cluster
K wait --for=condition=Ready cluster/drill --timeout=15m
C2=$(count); echo "    after rebuild: $C2 rows (want 1000)"
[ "$C2" = "1000" ] || { echo "✗ FAIL: recovery did not restore rows"; exit 1; }

echo "== PHASE 3: keep running — write more + backup to the SAME store (continue-archiving) =="
K exec drill-1 -- psql -c "insert into canary select generate_series(1001,1500);"
C3=$(count); echo "    after more writes: $C3 rows (want 1500)"
backup_now drill-backup-2   # proves archiving continues on the same serverName post-recovery

echo "== PHASE 4: DESTROY + rebuild AGAIN — post-recovery writes must also be recoverable =="
K delete cluster drill --timeout=5m
recover_cluster
K wait --for=condition=Ready cluster/drill --timeout=15m
C4=$(count); echo "    after 2nd rebuild: $C4 rows (want 1500)"

if [ "$C4" = "1500" ]; then
  echo "✓ DR DRILL PASSED — rebuild-in-place recovers AND continues archiving on the same serverName."
else
  echo "✗ DR DRILL FAILED — expected 1500 after the 2nd rebuild, got $C4"; exit 1
fi
