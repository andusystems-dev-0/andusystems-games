# andusystems-games entrypoints (AGENTS.md). Provisioning runs via the GHA pipeline on self-hosted
# runners (not local applies) — those targets just trigger the workflow with `gh`. Data/DR targets act
# on the live cluster and need KUBECONFIG pointed at games + AWS creds in the environment.
.PHONY: help cluster register-spoke redeploy backup restore dr-drill backup-sealed-key restore-sealed-key

help:
	@echo "Cluster (GHA self-hosted runners):"
	@echo "  make cluster            # deploy.yml: create-or-keep VMs + k3s + register ArgoCD spoke"
	@echo "  make register-spoke     # (part of deploy.yml — see below)"
	@echo "  make redeploy CONFIRM=DESTROY   # redeploy.yml: destroy + recreate + restore"
	@echo "Data / DR (needs KUBECONFIG=games + AWS_* in env):"
	@echo "  make backup             # on-demand CNPG base backup of all three DBs -> S3"
	@echo "  make restore            # print the restore-from-S3 procedure (scripts/cnpg-recovery.template.yaml)"
	@echo "  make dr-drill           # safe canary: backup + recover + verify row counts"
	@echo "  make backup-sealed-key  # persist the sealed-secrets master key -> S3 (first-write-wins)"
	@echo "  make restore-sealed-key # re-seed the sealed-secrets master key onto the cluster"

# --- Provisioning: GHA pipeline on self-hosted runners (pterodactyl-style), not local ---
cluster:
	gh workflow run deploy.yml

register-spoke:
	@echo "Spoke registration is the final step of deploy.yml (applies the games AppProject + apps/argocd/)."
	@echo "Run 'make cluster' (safe, create-or-keep) to (re)register."

redeploy:
	@test "$(CONFIRM)" = "DESTROY" || { echo "refusing: run 'make redeploy CONFIRM=DESTROY'"; exit 1; }
	gh workflow run redeploy.yml -f confirm=DESTROY

# --- Data / DR: act on the live cluster ---
backup:
	@test -n "$$KUBECONFIG" || { echo "set KUBECONFIG to the games cluster"; exit 1; }
	@ts=$$(date +%Y%m%d%H%M%S); \
	for pair in "games-db save-api" "games-db-uat save-api-uat" "forge-db spriteforge"; do \
	  set -- $$pair; \
	  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Backup\nmetadata: { name: ondemand-%s, namespace: %s }\nspec: { cluster: { name: %s } }\n' "$$ts" "$$2" "$$1" \
	    | kubectl apply -f - ; \
	done

restore:
	@echo "Restore is a one-shot recovery into a fresh cluster from S3 (games-db has no bootstrap.recovery"
	@echo "by default, so a plain rebuild comes back EMPTY). Bump the serverName generation and recover"
	@echo "from the previous one, e.g. games-db (g1 -> g2):"
	@echo ""
	@echo "  sed -e 's/__DB__/games-db/' -e 's/__NS__/save-api/' \\"
	@echo "      -e 's/__FROM_GEN__/games-db-g1/' -e 's/__NEW_GEN__/games-db-g2/' \\"
	@echo "      scripts/cnpg-recovery.template.yaml | kubectl apply -f -"
	@echo ""
	@echo "See docs/runbook.md 'Restore from S3'. Prove the mechanics safely first with 'make dr-drill'."

dr-drill:
	scripts/dr-drill.sh

backup-sealed-key:
	scripts/sealed-secrets-key.sh backup

restore-sealed-key:
	scripts/sealed-secrets-key.sh restore
