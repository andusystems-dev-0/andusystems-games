#!/usr/bin/env bash
# Fail if any image references a public container registry (the "no public images" rule —
# docs/registry-audit.md). Everything must be forgejo.andusystems.com/*. Run in CI (a lint gate) once
# the registry migration lands; today it still reports the not-yet-migrated references.
#   scripts/lint-no-public-images.sh        # exit 1 if any public-registry ref found
set -uo pipefail
cd "$(dirname "$0")/.."

# Registries that are NOT allowed to appear in committed manifests/Dockerfiles/workflows.
PUB='ghcr\.io|docker\.io|gcr\.io|quay\.io|registry\.k8s\.io|mcr\.microsoft\.com'

# Search app manifests, Dockerfiles, workflows, ansible — not the migration tooling that legitimately
# names public sources (the mirror list, this linter, the audit doc), nor vendored/gitignored trees.
# A match only counts as a real image reference: comments (prose that explains the migration) and
# `sed 's#quay.io/...#forgejo...#'` rewrite rules (tooling that ELIMINATES the public ref, like the
# mirror workflow) are stripped from each line before the registry test, so they don't false-positive.
hits=$(grep -rnE "$PUB" \
  --include='*.yaml' --include='*.yml' --include='Dockerfile*' \
  apps ansible .github 2>/dev/null \
  | grep -vE 'mirror-images\.(txt|yml)|registry-audit\.md|lint-no-public-images\.sh' \
  | awk -v pub="${PUB//\\./[.]}" '{
      i = index($0, ":"); r = substr($0, i+1);           # drop "file:"
      j = index(r, ":"); c = substr(r, j+1);             # c = line content (after "lineno:")
      gsub(/(^|[[:space:]])#.*$/, "", c);                # strip full-line + inline comments
      gsub(/sed .*/, "", c);                             # strip image-rewrite pipelines (migration tooling)
      if (c ~ pub) print $0;
    }' \
  || true)

if [ -n "$hits" ]; then
  echo "✗ public container registry references found (must be forgejo.andusystems.com/*):"
  echo "$hits" | sed 's/^/  /'
  exit 1
fi
echo "✓ no public container registry references"
