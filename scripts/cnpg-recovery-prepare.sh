#!/usr/bin/env bash
# Prepare apps/cnpg + apps/spriteforge for a DESTROY+RECREATE so the rebuilt clusters RESTORE their
# data from S3 instead of coming up empty. Called by redeploy.yml BEFORE re-registering ArgoCD; the
# edits are committed to git so ArgoCD reconciles the recovery spec (Option 1: self-committing redeploy).
#
# Per DB it: finds the latest barman generation in S3 that has a base backup (FROM=g<N>), rewrites the
# Cluster to bootstrap.recovery from FROM and archive to a FRESH generation (TO=g<N+1>) — CNPG refuses
# to archive to a serverName that already has WAL, so each rebuild advances the generation (validated by
# scripts/dr-drill.sh). ScheduledBackups + comments in the files are preserved (targeted yq edits).
#
# Requires: yq (v4), aws, KUBECONFIG not needed. AWS creds in env. Idempotent per generation.
#   scripts/cnpg-recovery-prepare.sh                 # rewrite all three clusters for recovery
#   FROM=1 TO=2 scripts/cnpg-recovery-prepare.sh games-db   # rewrite one, explicit gens (for tests)
set -euo pipefail

DR_BUCKET=${DR_BUCKET:-andusystems-dr}
YQ=${YQ:-yq}
here="$(cd "$(dirname "$0")/.." && pwd)"

# db -> file mapping (name:file, relative to repo root)
declare -A FILE=(
  [games-db]="apps/cnpg/resources.yaml"
  [games-db-uat]="apps/cnpg/resources.yaml"
  [forge-db]="apps/spriteforge/resources.yaml"
)

# Highest generation N (from serverName <db>-g<N>) that has a base backup in S3, else 0 (genesis).
latest_gen() {
  local db="$1" max=0 sn n
  for sn in $(aws s3 ls "s3://${DR_BUCKET}/cnpg/${db}/" 2>/dev/null | awk '{print $2}' | tr -d '/'); do
    case "$sn" in
      "${db}-g"*)
        n="${sn##*-g}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        # count only generations that actually hold a base backup (WAL-only can't bootstrap)
        [ -n "$(aws s3 ls "s3://${DR_BUCKET}/cnpg/${db}/${sn}/base/" 2>/dev/null)" ] || continue
        [ "$n" -gt "$max" ] && max="$n"
        ;;
    esac
  done
  echo "$max"
}

# Rewrite one Cluster doc to recover from FROM and archive to TO.
rewrite() {
  local db="$1" from="$2" to="$3" file="${here}/${FILE[$db]}"
  echo "  $db: recover from ${db}-g${from} -> archive to ${db}-g${to}  ($file)"
  DB="$db" FROM="$db-g$from" TO="$db-g$to" PATH_="s3://${DR_BUCKET}/cnpg/${db}" \
  "$YQ" -i '
    (select(.kind == "Cluster" and .metadata.name == env(DB)).spec) |= (
      .backup.barmanObjectStore.serverName = env(TO)
      | .bootstrap = {"recovery": {"source": "fromS3"}}
      | .externalClusters = [{
          "name": "fromS3",
          "barmanObjectStore": {
            "destinationPath": env(PATH_),
            "serverName": env(FROM),
            "s3Credentials": {
              "accessKeyId":     {"name": "cnpg-backup-creds", "key": "ACCESS_KEY_ID"},
              "secretAccessKey": {"name": "cnpg-backup-creds", "key": "SECRET_ACCESS_KEY"}
            },
            "wal":  {"compression": "gzip", "encryption": "AES256"},
            "data": {"compression": "gzip", "encryption": "AES256"}
          }
        }]
    )
  ' "$file"
}

dbs=("$@"); [ ${#dbs[@]} -eq 0 ] && dbs=(games-db games-db-uat forge-db)
for db in "${dbs[@]}"; do
  if [ -n "${FROM:-}" ] && [ -n "${TO:-}" ]; then
    rewrite "$db" "$FROM" "$TO"                 # explicit (tests)
  else
    from=$(latest_gen "$db")
    [ "$from" -ge 1 ] || { echo "::error::$db has no base backup in S3 — refusing to rewrite (would recover nothing)"; exit 1; }
    rewrite "$db" "$from" "$((from + 1))"
  fi
done
