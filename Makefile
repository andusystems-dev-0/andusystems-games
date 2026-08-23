# andusystems-games entrypoints (AGENTS.md). Every operation is GHA + GitOps: these targets only
# TRIGGER GitHub Actions (`gh workflow run`) on the self-hosted runner — nothing here touches the
# cluster from a devbox. Declarative state is GitOps (ArgoCD reconciles apps/). Requires the `gh` CLI
# authenticated against andusystems-dev-0/andusystems-games.
.PHONY: help cluster register-spoke redeploy backup restore dr-drill backup-sealed-key restore-sealed-key

REPO := andusystems-dev-0/andusystems-games

help:
	@echo "Cluster (GHA self-hosted runners):"
	@echo "  make cluster            # deploy.yml: create-or-keep VMs + k3s + register ArgoCD spoke"
	@echo "  make register-spoke     # (part of deploy.yml — see below)"
	@echo "  make redeploy CONFIRM=DESTROY   # redeploy.yml: destroy + recreate + restore"
	@echo "DR / ops (all run on the runner via ops.yml — never locally):"
	@echo "  make backup             # on-demand CNPG base backup of all three DBs -> S3"
	@echo "  make dr-drill           # safe canary: backup + recover + verify row counts"
	@echo "  make backup-sealed-key  # persist the sealed-secrets master key -> S3 (first-write-wins)"
	@echo "  make restore-sealed-key # re-seed the sealed-secrets master key onto the cluster"
	@echo "  make restore            # print the GitOps restore-from-S3 procedure (a git edit, not kubectl)"

# --- Provisioning: GHA pipeline on self-hosted runners (pterodactyl-style), not local ---
cluster:
	gh workflow run deploy.yml -R $(REPO)

register-spoke:
	@echo "Spoke registration is the final step of deploy.yml (applies the games AppProject + apps/argocd/)."
	@echo "Run 'make cluster' (safe, create-or-keep) to (re)register."

redeploy:
	@test "$(CONFIRM)" = "DESTROY" || { echo "refusing: run 'make redeploy CONFIRM=DESTROY'"; exit 1; }
	gh workflow run redeploy.yml -R $(REPO) -f confirm=DESTROY

# --- DR / ops: trigger ops.yml on the runner (fetches kubeconfig + runs the script there) ---
backup:
	gh workflow run ops.yml -R $(REPO) -f op=cnpg-backup

dr-drill:
	gh workflow run ops.yml -R $(REPO) -f op=dr-drill

backup-sealed-key:
	gh workflow run ops.yml -R $(REPO) -f op=sealed-key-backup

restore-sealed-key:
	gh workflow run ops.yml -R $(REPO) -f op=sealed-key-restore

# Restore is GitOps, not an out-of-band apply: games-cnpg has selfHeal:true, so a `kubectl apply` of a
# recovery Cluster would be reverted. Recover by editing apps/cnpg/resources.yaml on a branch (add
# bootstrap.recovery from the previous serverName generation + bump the new one) and merging — ArgoCD
# then applies it. scripts/cnpg-recovery.template.yaml shows the exact stanza. See docs/runbook.md.
restore:
	@echo "Restore = GitOps edit (NOT kubectl apply — ArgoCD selfHeal would revert it):"
	@echo "  1. On a branch, edit apps/cnpg/resources.yaml for the target Cluster (e.g. games-db):"
	@echo "       - bump backup serverName generation (games-db-g1 -> games-db-g2)"
	@echo "       - add spec.bootstrap.recovery + externalClusters pointing at the OLD generation"
	@echo "       (copy the stanza from scripts/cnpg-recovery.template.yaml)"
	@echo "  2. PR + merge -> ArgoCD recreates the Cluster and replays base+WAL from S3."
	@echo "  3. Prove the mechanics first, safely: make dr-drill"
