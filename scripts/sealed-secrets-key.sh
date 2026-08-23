#!/usr/bin/env bash
# Persist / restore the sealed-secrets controller MASTER KEY for the games cluster.
#
# WHY: every committed SealedSecret (JWT signing keys, CNPG owner/backup creds, Newt creds, the
# Cloudflare DNS-01 token, the Forgejo pull creds) is encrypted against ONE controller key. A
# from-scratch rebuild spins up a fresh controller that generates a NEW key -> every committed
# SealedSecret becomes undecryptable -> save-api/spriteforge/edge/tls/backups all break. Persisting
# and re-seeding the key is the #1 "redeploy fresh" guarantee. This mirrors the platform's
# scripts/dr-backup.sh (which captures the same `sealedsecrets.bitnami.com/sealed-secrets-key`).
#
# The key lives ONLY in the private S3 DR bucket (SSE-AES256) + the live cluster — NEVER in this
# PUBLIC repo. Access is gated by the same AWS creds that already gate the CNPG S3 backups.
#
# Usage (KUBECONFIG must point at the games cluster; AWS creds in the environment):
#   scripts/sealed-secrets-key.sh backup            # first-write-wins: upload only if S3 has none
#   scripts/sealed-secrets-key.sh backup --force    # overwrite the canonical copy (rare; after a rotation)
#   scripts/sealed-secrets-key.sh restore           # seed the key onto the cluster (no-op on first deploy)
#   scripts/sealed-secrets-key.sh restore --required # FAIL if S3 has no key (use on redeploy)
set -euo pipefail

NS=sealed-secrets
LABEL=sealedsecrets.bitnami.com/sealed-secrets-key
S3_URI=${SEALED_KEY_S3_URI:-s3://andusystems-dr/games/sealed-secrets-key.json}

cmd=${1:-}
flag=${2:-}

for bin in kubectl aws jq; do
  command -v "$bin" >/dev/null || { echo "::error::$bin not found on PATH"; exit 1; }
done

# kubectl get -o json against a label selector returns a List; strip server-managed fields so the
# manifest re-applies cleanly (as a CREATE) onto a fresh cluster.
strip() {
  jq 'del(
        .items[].metadata.uid,
        .items[].metadata.resourceVersion,
        .items[].metadata.creationTimestamp,
        .items[].metadata.ownerReferences,
        .items[].metadata.managedFields,
        .items[].metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .items[].status
      )'
}

backup() {
  if [ "$flag" != "--force" ] && aws s3 ls "$S3_URI" >/dev/null 2>&1; then
    echo "sealed-secrets key already persisted at $S3_URI (first-write-wins). Use --force to overwrite."
    return 0
  fi
  echo "Waiting for the sealed-secrets controller to publish its master key..."
  for _ in $(seq 1 90); do
    [ "$(kubectl -n "$NS" get secret -l "$LABEL" -o name 2>/dev/null | wc -l)" -ge 1 ] && break
    sleep 10
  done
  kubectl -n "$NS" get secret -l "$LABEL" -o json | strip > /tmp/ss-key.json
  cnt=$(jq '.items | length' /tmp/ss-key.json)
  [ "${cnt:-0}" -ge 1 ] || { echo "::error::no sealed-secrets key found in ns/$NS to back up"; exit 1; }
  aws s3 cp /tmp/ss-key.json "$S3_URI" --sse AES256
  echo "Persisted $cnt sealed-secrets key(s) to $S3_URI"
}

restore() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  if ! aws s3 cp "$S3_URI" /tmp/ss-key.json 2>/dev/null; then
    if [ "$flag" = "--required" ]; then
      echo "::error::no persisted key at $S3_URI — a rebuilt controller would generate a NEW key and every committed SealedSecret would be undecryptable. Run 'backup' from the live cluster first."
      exit 1
    fi
    echo "No persisted key at $S3_URI (first deploy). The controller will generate one; back it up post-sync."
    return 0
  fi
  # Seed BEFORE the controller Deployment exists so it adopts this key on start. If the controller is
  # already running, restart it so it reloads the newly-seeded key instead of its freshly-generated one.
  kubectl apply -f /tmp/ss-key.json
  kubectl -n "$NS" rollout restart deploy -l app.kubernetes.io/name=sealed-secrets 2>/dev/null || true
  echo "Restored the sealed-secrets key from $S3_URI"
}

case "$cmd" in
  backup)  backup ;;
  restore) restore ;;
  *) echo "usage: $0 {backup|restore} [--force|--required]"; exit 2 ;;
esac
