# Runbook — operations

**All ops are GHA + GitOps** — nothing operates the cluster from a devbox. The `Makefile` (`make help`)
is a thin `gh workflow run` trigger: `cluster`/`redeploy` → `deploy.yml`/`redeploy.yml`; every DR/ops
target → `ops.yml`, which runs on the self-hosted runner (fetches the games kubeconfig, runs the
matching `scripts/*.sh` there). Declarative state is GitOps — ArgoCD reconciles `apps/*` from GitHub;
never `kubectl apply` by hand except the documented bootstrap. You can also trigger any of these from
the GitHub **Actions** tab.

## Cluster lifecycle
| Command | What |
|---|---|
| `make cluster` | Triggers `deploy.yml` (self-hosted runner): Terraform VMs (games VLAN) + Ansible k3s + register ArgoCD spoke. Safe, converge-only. |
| `make register-spoke` | Register the cluster with the mgmt ArgoCD hub; apply the `games` AppProject + app-of-apps. |
| `make bootstrap-secrets` | Seal + seed the bootstrap secrets (see list below). |
| `make redeploy` (`CONFIRM=DESTROY`) | Destroy + recreate the cluster and **restore CNPG from S3**. Durability is off-cluster (S3), not disk. Runs `.github/workflows/redeploy.yml`. |

ArgoCD (mgmt hub) reconciles `apps/*` from GitHub — don't `kubectl apply` by hand except the
documented bootstrap.

### Redeploy reproducibility (what makes "rebuild from scratch" actually true)
A fresh cluster must come back with the same identity and decryptable secrets, from GitOps alone:

- **Cluster add-ons are ArgoCD apps, not hand-installs.** `sealed-secrets` (wave -50), `cert-manager`
  (-40), `cnpg-operator` (-30), `kyverno` (-20), and `kyverno-policies` (5) are all Applications in
  `apps/argocd/applications.yaml`. A `deploy.yml` / `redeploy.yml` run recreates every one — nothing
  is installed by `kubectl` on the side anymore.
- **The sealed-secrets master key is persisted, not regenerated.** Every committed SealedSecret (JWT
  keys, CNPG owner/backup creds, Newt, Cloudflare token, Forgejo pull creds) is encrypted against one
  controller key. `scripts/sealed-secrets-key.sh` backs it up (first-write-wins) to
  `s3://andusystems-dr/games/sealed-secrets-key.json` (SSE-AES256, gated by the same AWS creds as the
  CNPG backups — **never** in this public repo) and re-seeds it before the controller starts.
  `redeploy.yml` restores it with `--required` (hard-fails rather than rebuild an unrecoverable cluster).
  Ad-hoc: `make backup-sealed-key` / `make restore-sealed-key` (both trigger `ops.yml` on the runner).
- **Postgres restores from S3.** CNPG replays base backup + WAL from `s3://andusystems-dr/cnpg/*`.
- **Stable JWT keys** (prod + UAT) survive because their SealedSecrets are decryptable again (above).

> **First-time / live-cluster cutover:** the add-ons were originally installed by hand. Before letting
> ArgoCD adopt them, run **`make backup-sealed-key`** (triggers `ops.yml`) so the current key reaches S3
> (a normal `deploy.yml` run also does this via the "Persist" step). Confirm the live sealed-secrets
> install is the bitnami chart in ns `sealed-secrets` (matching the app) so ArgoCD adopts rather than
> duplicates it.

## Data / backups
| Command | What |
|---|---|
| `make backup` | On-demand CNPG base backup of all three DBs → S3 (`s3://andusystems-dr/cnpg/*`). Nightly is a scheduled CNPG backup. |
| `make restore` | Prints the restore-from-S3 procedure (see below). |
| `make dr-drill` | **Safe** canary: stand up a throwaway CNPG, back up, recover, verify row counts (`scripts/dr-drill.sh`). Run monthly. |

### Restore from S3 (the real recovery path — GitOps)
> ⚠️ **Gap to close:** `apps/cnpg/resources.yaml` creates `games-db` / `games-db-uat` as **empty**
> clusters (no `bootstrap.recovery`), so a plain destroy+recreate comes back with **no data**.
>
> Restore is a **git edit**, not a `kubectl apply` — `games-cnpg` has `selfHeal: true`, so an
> out-of-band recovery Cluster is reverted to the git spec. On a branch, edit the target Cluster in
> `apps/cnpg/resources.yaml`: bump its `serverName` generation (`games-db-g1` → `games-db-g2`) and add
> the `spec.bootstrap.recovery` + `externalClusters` stanzas that point at the OLD generation (copy from
> `scripts/cnpg-recovery.template.yaml`). PR + merge → ArgoCD recreates the Cluster and replays base+WAL
> from S3. `make restore` prints this procedure.
>
> `make dr-drill` proves these exact mechanics without touching prod (throwaway namespace, not
> ArgoCD-managed, so no selfHeal conflict). Backup **age** is alerted in mgmt Grafana. (Follow-up:
> decide whether `redeploy.yml` should stamp the recovery stanza automatically so a rebuild restores
> data — needs a live test to avoid a first-deploy chicken-and-egg.)

## Access recap
- **Public/prod:** Cloudflare — `<slug>.games…` (R2/Pages), `api.games…` (Tunnel). No open ports.
- **Private/UAT + SpriteForge:** Pangolin/Newt — `uat.*.games…`, `uat-api…`, `spriteforge…`,
  IP-allow-listed. Devbox reaches these via the Pangolin client (not the MetalLB VIP directly).

## Secrets (sealed-secrets; plaintext only in `.env.local` + GH secrets)
- `CLOUDFLARE_API_TOKEN` (DNS + R2 + Tunnel; account-scoped, least-privilege), `CF_TUNNEL_TOKEN`.
- `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` (bundles + backups; CNPG barman uses a scoped key).
- `JWT_SIGNING_KEY` (prod) + `JWT_SIGNING_KEY_UAT` — **stable across redeploys**; rotating invalidates tokens.
- CNPG superuser/app creds (prod + uat).
- `NEWT_ID` / `NEWT_SECRET` per Pangolin Site (UAT web, UAT API, SpriteForge).
- `GAMES_STRIPE_SECRET_KEY` / `GAMES_STRIPE_WEBHOOK_SECRET` / `STRIPE_PRICE_*` — test (uat) + live (prod).
- `PROXMOX_*` (VM provisioning), `AWS_*` (TF state in S3).
- SpriteForge: `FAL_KEY` / `REPLICATE_API_TOKEN`.
- Mobile (in the public hub / org secrets, not here): `PLAY_SERVICE_ACCOUNT_JSON`, `APPLE_API_KEY_P8`, signing certs.

## Common tasks
- **Add a game:** `docs/onboarding-a-game.md`.
- **Change a game's save mode / caps:** PR `apps/save-api/games-registry.yaml`; API hot-reloads.
- **Add a product/price:** PR `apps/save-api/products.yaml` + `STRIPE_PRICE_*` secret; see `payments.md`.
- **Promote UAT→prod:** re-publish the same artifact + `release` mobile lane; no rebuild.

## Troubleshooting quick hits
- **API 5xx after redeploy:** CNPG may still be restoring from R2 — wait; check `readyz`.
- **Tokens all invalid:** a signing key rotated — restore the stable key from `.env.local`.
- **Stripe test webhook not firing in UAT:** UAT API is private — run `stripe listen --forward-to …`
  from the devbox (`payments.md`).
- **Game unreachable on UAT:** 3-layer model (game → Newt tunnel → Pangolin edge), same as
  `andusystems-pterodactyl/docs/pangolin.md`.
