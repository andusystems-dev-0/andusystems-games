#!/usr/bin/env bash
# On-demand CNPG base backup of all three games DBs → S3 (barman). Nightly backups are the in-cluster
# ScheduledBackup CRs (GitOps: apps/cnpg + apps/spriteforge); this is the imperative "back up now",
# run on the self-hosted runner via .github/workflows/ops.yml (op=cnpg-backup) — not from a devbox.
# Needs KUBECONFIG pointing at the games cluster.
set -euo pipefail
: "${KUBECONFIG:?KUBECONFIG must point at the games cluster}"

ts=$(date +%Y%m%d%H%M%S)
for pair in "games-db save-api" "games-db-uat save-api-uat" "forge-db spriteforge"; do
  # shellcheck disable=SC2086
  set -- $pair
  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Backup\nmetadata: { name: ondemand-%s, namespace: %s }\nspec: { cluster: { name: %s } }\n' "$ts" "$2" "$1" \
    | kubectl apply -f -
done
echo "requested on-demand backups (suffix $ts): games-db, games-db-uat, forge-db"
