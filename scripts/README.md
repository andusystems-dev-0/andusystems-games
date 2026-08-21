# scripts/ — devbox helpers

Model on `andusystems-pterodactyl/scripts` (source `.env.local`).

| Script | What |
|---|---|
| `bootstrap-secrets.sh` | Seal + seed the bootstrap K8s secrets (see `docs/runbook.md` list). |
| `sync-gh-secrets.sh` | Mirror `.env.local` → GitHub Actions secrets. |
| `register-spoke.sh` | Register this cluster with the mgmt ArgoCD hub. |
| `new-game.sh <slug>` | Create a game repo from the template + open the registry PR (`docs/onboarding-a-game.md`). |
| `backup.sh` / `restore.sh` | CNPG ↔ R2 (wrap `make backup`/`restore`). |

Secrets never committed; real values in git-ignored `.env.local`.
