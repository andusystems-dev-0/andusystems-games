#!/usr/bin/env bash
# End-to-end CNPG DR drill — proves the EXACT redeploy contract used by redeploy.yml + apps/cnpg: a
# cluster can be destroyed and rebuilt, recovering from its latest S3 barman generation and archiving
# to a FRESH one (CNPG refuses to archive to a serverName that already has WAL, so each rebuild advances
# the generation). Safe: everything lives in a throwaway namespace, never touches the real DBs.
#
# Phases (mirroring genesis → backup → redeploy → rebuild → keep running → redeploy again):
#   1. genesis cluster (initdb) archiving to gen g1; seed 1000 rows; base backup to g1.
#   2. DESTROY, rebuild: recover from g1 -> archive to fresh g2. Verify 1000 rows.
#   3. Keep running: +500 rows (1500), base backup to g2.
#   4. DESTROY, rebuild AGAIN: recover from g2 -> archive to fresh g3. Verify 1500 (post-recovery writes
#      are themselves recoverable — the generation ping-pong is repeatable).
#
# Requires: KUBECONFIG at the games cluster (CNPG operator installed), AWS creds in env, andusystems-dr
# bucket. Run via .github/workflows/ops.yml (op=dr-drill). Region us-east-1 (bucket default).
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"
: "${KUBECONFIG:?KUBECONFIG must point at the games cluster}"

DR_BUCKET=${DR_BUCKET:-andusystems-dr}
DRILL_STORE=${DRILL_STORE:-dr-drill}
BASE="drill-$(date +%s)"                 # unique per run so a re-run never reads stale backups
SRV1="${BASE}-g1"; SRV2="${BASE}-g2"; SRV3="${BASE}-g3"   # generations: CNPG must archive to an EMPTY store
NS="dr-drill-$(date +%s)"
DEST="s3://${DR_BUCKET}/cnpg/${DRILL_STORE}"
K() { kubectl -n "$NS" "$@"; }

echo "==> namespace $NS  generations $SRV1 -> $SRV2 -> $SRV3  dest $DEST"
kubectl create ns "$NS"
trap 'kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true' EXIT

K create secret generic cnpg-backup-creds \
  --from-literal=ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | K apply -f -

# barmanObjectStore fields. $1 = leading indent (backup=6, externalClusters=8), $2 = serverName.
store_block() {
  local i="$1" sn="$2"
  cat <<EOF
${i}serverName: ${sn}
${i}destinationPath: ${DEST}
${i}s3Credentials:
${i}  accessKeyId:     { name: cnpg-backup-creds, key: ACCESS_KEY_ID }
${i}  secretAccessKey: { name: cnpg-backup-creds, key: SECRET_ACCESS_KEY }
${i}wal:  { compression: gzip }
${i}data: { compression: gzip }
EOF
}

genesis_cluster() {   # $1 = archive serverName
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
$(store_block "      " "$1")
EOF
}

recover_cluster() {   # $1 = recover-FROM serverName (populated), $2 = archive-TO serverName (must be EMPTY)
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
$(store_block "      " "$2")
  bootstrap:
    recovery: { source: origin }
  externalClusters:
    - name: origin
      barmanObjectStore:
$(store_block "        " "$1")
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

echo "== PHASE 1: genesis (initdb) archiving to $SRV1 + seed + base backup =="
genesis_cluster "$SRV1"
K wait --for=condition=Ready cluster/drill --timeout=10m
K exec drill-1 -- psql -c "create table canary(i int); insert into canary select generate_series(1,1000);"
echo "    seeded: $(count) rows"
backup_now drill-backup-1

echo "== PHASE 2: DESTROY + rebuild (recover from $SRV1 -> archive to fresh $SRV2) =="
K delete cluster drill --timeout=5m
recover_cluster "$SRV1" "$SRV2"
K wait --for=condition=Ready cluster/drill --timeout=8m
C2=$(count); echo "    after rebuild: $C2 rows (want 1000)"
[ "$C2" = "1000" ] || { echo "✗ FAIL: recovery did not restore rows"; exit 1; }

echo "== PHASE 3: keep running — write more + base backup to the new generation $SRV2 =="
K exec drill-1 -- psql -c "insert into canary select generate_series(1001,1500);"
C3=$(count); echo "    after more writes: $C3 rows (want 1500)"
backup_now drill-backup-2   # base backup on the recovered timeline, to the new generation

echo "== PHASE 4: DESTROY + rebuild AGAIN (recover from $SRV2 -> archive to fresh $SRV3) =="
K delete cluster drill --timeout=5m
recover_cluster "$SRV2" "$SRV3"
K wait --for=condition=Ready cluster/drill --timeout=8m
C4=$(count); echo "    after 2nd rebuild: $C4 rows (want 1500)"

if [ "$C4" = "1500" ]; then
  echo "✓ DR DRILL PASSED — recover-from-generation-N -> archive-to-fresh-N+1, repeatable across rebuilds."
else
  echo "✗ DR DRILL FAILED — expected 1500 after the 2nd rebuild, got $C4"; exit 1
fi
