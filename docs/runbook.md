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

> **Live-cluster cutover (DONE 2026-08-23):** the add-ons were originally hand-installed in places the
> GitOps Helm apps don't match — sealed-secrets as raw manifests in **kube-system**, cnpg via **upstream
> manifests** (`cnpg-controller-manager`). So the first `deploy.yml` **duplicated** rather than adopted:
> a second sealed-secrets controller came up in ns `sealed-secrets` with a fresh key (all SealedSecrets
> went "no key could decrypt"), a second cnpg operator ran, and the best-effort "Persist" step pushed the
> *wrong* key to S3. Remediation (one-time, interactive):
> 1. Copied the canonical key (`kube-system/…keypmqtz`) into ns `sealed-secrets`, dropped the fresh key,
>    restarted the controller → 12/12 SealedSecrets SYNCED again; deleted the kube-system controller.
> 2. Deleted the upstream `cnpg-controller-manager` (the Helm operator already owned the webhooks/service);
>    the Helm operator rolled all three DBs 1.24.0→1.24.1 (HA, no data loss).
> 3. `ops.yml op=sealed-key-backup-force` → the **canonical** key is now in S3 (redeploy-safe).
>
> A truly fresh redeploy won't hit this (no hand-installs exist; `redeploy.yml` re-seeds the S3 key before
> the controller starts). Harmless orphans left in kube-system (dead `sealed-secrets-controller` svc/sa +
> a break-glass copy of the key) — optional cleanup.

## Data / backups
| Command | What |
|---|---|
| `make backup` | On-demand CNPG base backup of all three DBs → S3 (`s3://andusystems-dr/cnpg/*`). Nightly is a scheduled CNPG backup. |
| `make restore` | Prints the manual restore-into-a-running-cluster procedure (see below). Full-cluster restore is automatic on `redeploy`. |
| `make dr-drill` | **Safe** canary: genesis → backup → recover → continue → recover again, verify row counts (`scripts/dr-drill.sh`). Run monthly. |

### Redeploy restores DBs automatically (the redeploy contract)
`redeploy.yml` no longer comes back empty. Before destroying anything it runs
`scripts/cnpg-recovery-prepare.sh`, which per DB finds the **latest S3 barman generation that has a base
backup** (`FROM=g<N>`), rewrites the Cluster in `apps/cnpg` / `apps/spriteforge` to
`bootstrap.recovery` from `FROM` and archive to a **fresh** `TO=g<N+1>`, and commits that (self-committing
redeploy). ArgoCD then recreates the clusters and replays base+WAL from S3. Why a *fresh* generation:
**CNPG refuses to archive to a serverName that already has WAL** ("expected empty archive" — even
`skipEmptyWalArchiveCheck` doesn't bypass it at recovery time), so each rebuild advances the generation.
After recovery the workflow takes an immediate base backup into the new generation so a back-to-back
redeploy can't fall back and lose interim writes. Proven end-to-end by `make dr-drill` (recover g1→g2,
write, recover g2→g3, counts match). The live clusters stay `initdb`+ArgoCD-synced until a redeploy (the
recovery spec only lands on the fresh clusters, avoiding the "too many bootstrap types" webhook rejection).

### Manual restore into a fresh cluster (rare — outside a redeploy)
`make restore` prints the git-edit procedure (bump `serverName` generation + add the
`bootstrap.recovery`/`externalClusters` stanzas from `scripts/cnpg-recovery.template.yaml`, PR + merge);
`games-cnpg` has `selfHeal: true`, so it must be a git edit, not an out-of-band `kubectl apply`. Backup
**age** is alerted in mgmt Grafana.

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
