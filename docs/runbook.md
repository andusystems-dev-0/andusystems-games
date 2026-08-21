# Runbook — operations

Run from the devbox (`/home/admin/andusystems/andusystems-games`, sources `.env.local`). Mirrors
the pterodactyl/platform operational model. Everything below is the *intended* interface — build the
Makefile/scripts in ROADMAP Phase 0–1.

## Cluster lifecycle
| Command | What |
|---|---|
| `make cluster` | Terraform VMs (games VLAN) + Ansible k3s. Safe, converge-only. |
| `make register-spoke` | Register the cluster with the mgmt ArgoCD hub; apply the `games` AppProject + app-of-apps. |
| `make bootstrap-secrets` | Seal + seed the bootstrap secrets (see list below). |
| `make redeploy` (`CONFIRM=DESTROY`) | Destroy + recreate the cluster and **restore CNPG from R2**. Durability is in R2, not disk. |

ArgoCD (mgmt hub) reconciles `apps/*` from GitHub — don't `kubectl apply` by hand except the
documented bootstrap.

## Data / backups
| Command | What |
|---|---|
| `make backup` | On-demand CNPG base backup → R2 (`andusystems-games-backups`). Nightly is a scheduled CNPG backup. |
| `make restore` | Restore the latest R2 backup onto `games-db` / `games-db-uat`. |
| DR drill (monthly) | Kill a DB, restore from R2, verify a known save round-trips. Backup **age** is alerted in Grafana. |

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
