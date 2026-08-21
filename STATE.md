# andusystems-games — state & handoff

Snapshot of the games estate. **Start here if you return.** The estate is fully documented but
**not yet built** — this is the planning baseline.

_Last updated: 2026-08-21._

---

## 1. Status: PLANNING ✅ / BUILD: not started

All architecture, contracts, and the phased plan are written (this repo's `docs/` + `ROADMAP.md`,
plus the four sibling repos). Nothing is deployed. No cluster exists yet. The next action is
**ROADMAP Phase 0** (stand up the games k3s cluster).

## 2. Decisions locked (see `docs/decisions.md` for the full ADR log)

| # | Decision |
|---|---|
| D-001 | **Dedicated games cluster** (not a namespace on an existing cluster) — hard blast-radius boundary from SaaS. |
| D-002 | **CDN/edge = Cloudflare** — R2 (zero egress) for bundles, Pages/Worker hosting, Cloudflare Tunnel for the prod API, WAF/rate-limit. |
| D-003 | **Identity = anonymous device id, upgradeable** to a linked account (email/OAuth) later. |
| D-004 | **Save model = all three shapes**, per-game configured: default single-blob LWW, optional light version history, optional named slots. |
| D-005 | **Datastore = in-cluster CloudNativePG Postgres**, backups to R2. Data stays on our infra. |
| D-006 | **One shared save-api for all games** (prod) + a **second UAT copy**; adding a game never adds a workload. |
| D-007 | **Every game has two envs:** private **UAT** (Pangolin, IP-allow-listed) + public **prod** (Cloudflare). |
| D-008 | **Games ship to the App Store + Play Store** — Phaser bundle wrapped with **Capacitor**, released via **Fastlane** (TestFlight/Play-internal = UAT, production tracks = prod). |
| D-009 | **SpriteForge** (AI 2D asset+animation studio) is a private app on this cluster, reached via **Pangolin**; heavy inference via a cloud gateway (fal.ai/Replicate). |
| D-010 | **SDK repo + package = public** (thin client, no secrets); server + template stay private — public game repos install with no tokens. |
| D-011 | **Mobile app = thin offline Capacitor shell** rendering the *same* web bundle — no per-game native code (games are "just a rendered website"). |
| D-012 | **Web build is the single artifact** — built once, fanned out to web (prod/uat) + the store shell. |
| D-015 | **Payments = games-owned Stripe** (own account, Hireship conventions); **web-first purchase → entitlement sync**; stores' IAP required for any in-app digital purchase. |

## 3. Estate map (repos)

| Repo | Vis | Role | Status |
|---|---|---|---|
| `andusystems-games` (this) | public | cluster IaC + GitOps + docs hub | docs done, no code |
| `andusystems-games-save-api` | private | save service (Go) | docs done, no code |
| `andusystems-games-sdk` | public | TS client for games | docs done, no code |
| `andusystems-games-template` | private | Phaser+Capacitor starter (GH template) | docs done, no code |
| `andusystems-spriteforge` | private | AI asset+animation studio | docs done, no code |
| `andusystems-game-<slug>` | public | per-game client (web+mobile) | none yet |

¹ see D-010.

## 4. Deployment (IaC written + validated; provisioned via the GHA pipeline)

| Thing | Value |
|---|---|
| Cluster | k3s HA 3-node on Proxmox, **games VLAN 70** `10.238.70.0/24` (verified free) |
| Nodes / MetalLB | nodes `.41-.43`, MetalLB pool `.50-.69`, Traefik VIP `10.238.70.50` |
| Provisioning | `terraform/` + `ansible/k3s.yml` via `.github/workflows/deploy.yml` on `[self-hosted, linux, andusystems-mgmt]` (pterodactyl-style). `redeploy.yml` = DESTROY-gated. |
| ArgoCD | **spoke** of the mgmt cluster hub; apps reconcile from this repo |
| Monitoring | grafana-agent → remote_write to mgmt LGTM (`andusystems-monitoring`) |
| Prod web | `<slug>.games.andusystems.com` → Cloudflare (R2 `bundles/<slug>/prod`) |
| Prod API | `api.games.andusystems.com` → Cloudflare **Tunnel** → Traefik → `save-api` |
| UAT web | `uat.<slug>.games.andusystems.com` → **Pangolin** → shared UAT static host |
| UAT API | `uat-api.games.andusystems.com` → **Pangolin** → `save-api-uat` |
| SpriteForge | `spriteforge.andusystems.com` → **Pangolin** → `spriteforge` |
| DB | CNPG `games-db` (prod) + `games-db-uat`, backups → R2 |
| TF state | S3 `andusystems-tfstate`, key `games/layer-*` |

## 5. Open items to resolve before/while building

- [x] ~~CONFIRM the games VLAN~~ — **VLAN 70** (`10.238.70.0/24`), nodes `.41-.43`, MetalLB `.50-.69` — verified free 2026-08-21.
- [~] **GitHub secrets** on `andusystems-dev-0/andusystems-games`: PROXMOX_ENDPOINT, PROXMOX_SSH_KEY, SSH_PUBKEY, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, MGMT_KUBECONFIG **set 2026-08-21**. Remaining: **PROXMOX_API_TOKEN** (from Proxmox UI / your vault — not on disk) and **GH_ONBOARD_TOKEN** (PAT, new-game.yml only). Then confirm `proxmox_node`/`template_vm_id` defaults (`worker3`/`9000`), register a repo-scoped self-hosted runner, and run `deploy.yml`.
- [ ] **CONFIRM a macOS build path** for iOS (no macOS in the estate today) — Mac mini vs hosted macOS runner. Blocks iOS store release only.
- [ ] **Apple Developer Program** ($99/yr) + **Google Play Developer** ($25) accounts — Alex sets up; store submission blocked until then.
- [x] ~~Decide D-010~~ — **SDK repo + package are public** (2026-08-21).
- [ ] Pangolin: create the UAT + SpriteForge **Sites/resources** (manual in the Pangolin UI, like pterodactyl) and capture Newt IDs/secrets as sealed secrets.
- [ ] **Stripe:** create the games Stripe account + products/prices (test + live); decide what's sold (digital unlocks/cosmetics/remove-ads vs subscriptions). UAT = test keys, prod = live keys.

## 6. Next action

App stack (save-api, SDK, template+shell, spriteforge) is **built + verified**; cluster IaC +
`apps/*` are **written + validated** (terraform validate, kustomize build, ansible syntax-check).
Next: **fill the placeholder secrets** (see §5) and run `.github/workflows/deploy.yml` to provision
the VLAN-70 cluster, then let ArgoCD reconcile `apps/`. Then create the Pangolin/Cloudflare/Stripe
resources and swap their placeholders. Push the 5 repos to `andusystems-dev-0` when ready.
