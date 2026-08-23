#!/usr/bin/env bash
# Onboard a new game with near-zero manual steps (scalability goal).
#   ./scripts/new-game.sh <slug> [save_mode] [max_slots] [history_depth]
# Does: (1) create the public game repo from the template, (2) append the game to the registry on a
# branch + open a PR. Merging the PR → ArgoCD reconciles → save-api hot-reloads. No workload change.
set -euo pipefail

SLUG="${1:?usage: new-game.sh <slug> [save_mode] [max_slots] [history_depth]}"
MODE="${2:-lww}"          # lww | lww_history | slots
SLOTS="${3:-1}"
HIST="${4:-0}"
USER_ACCT="andusystems-dev-0"   # GitHub USER account (not an org)
REG="apps/save-api/games-registry.yaml"

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# Validate before touching anything (slug feeds hostnames + the registry key; mode is an enum).
[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "slug must be kebab-case [a-z0-9-]"; exit 1; }
case "$MODE" in lww|lww_history|slots) ;; *) echo "save_mode must be lww|lww_history|slots"; exit 1;; esac
grep -qE "^  - slug: ${SLUG}\$" "$REG" && { echo "'$SLUG' is already registered in $REG"; exit 1; }

echo "1/3 creating public repo $USER_ACCT/andusystems-game-$SLUG from the template…"
gh repo create "$USER_ACCT/andusystems-game-$SLUG" \
  --template "$USER_ACCT/andusystems-games-template" --public --clone=false

echo "2/3 registering '$SLUG' ($MODE) in $REG…"
BRANCH="add-game-$SLUG"
git switch -C "$BRANCH"   # -C: reset if a prior run left the branch around, so re-runs don't abort
cat >> "$REG" <<EOF
  - slug: $SLUG
    save_mode: $MODE
    history_depth: $HIST
    max_slots: $SLOTS
    max_blob_bytes: 262144
    conflict: last_write_wins
EOF
git add "$REG"
git commit -m "games: register $SLUG"
git push -u origin "$BRANCH"

echo "3/3 opening PR…"
# NOTE: --fill is mutually exclusive with --title/--body in gh; pass explicit title+body only.
gh pr create --title "games: register $SLUG" \
  --body "Registers $SLUG ($MODE). Merge → ArgoCD reconciles → save-api hot-reloads. Then CDN/DNS auto-covers <slug>.games… (Cloudflare) + uat.<slug>… (Pangolin wildcard)."

cat <<DONE

Done. Remaining (all automated once secrets exist):
  - merge the PR (registry live in prod + uat)
  - push to the new game repo → its CI builds the web bundle → R2 uat/prod + calls mobile-package.yml
  - first time only: create the App Store Connect + Play Console records for com.andusystems.games.$SLUG
DONE
