# andusystems-games — state & handoff

Snapshot of the games estate. **Start here if you return.**

_Last updated: 2026-08-23._

---

## 1. Status: CLUSTER LIVE ✅ / hardening for redeploy-reproducibility

The VLAN-70 k3s cluster is up and registered as an ArgoCD spoke; `apps/*` reconcile from GitHub
(cnpg + save-api + save-api-uat + edge/newt + web-uat + spriteforge + monitoring + cert-manager +
tls). Backups stream to **S3** (`s3://andusystems-dr/cnpg/*`), not R2. Current focus is **Phase 0
hardening** so a from-scratch rebuild is truly reproducible.

**Just landed (this repo, pending commit+push+deploy):** the reproducibility trio —
- sealed-secrets, cnpg-operator, kyverno (+ games kyverno baseline) converted from hand-installs to
  ArgoCD Helm apps (`apps/argocd/applications.yaml`, early sync-waves; AppProject sourceRepos updated);
- sealed-secrets **master-key persistence** (`scripts/sealed-secrets-key.sh` → S3, re-seeded by
  `deploy.yml`/`redeploy.yml`) so committed SealedSecrets survive a rebuild — see `docs/runbook.md`.

**One-time cutover** on the live cluster before ArgoCD adopts the add-ons: back up the current
sealed-secrets key to S3 (`scripts/sealed-secrets-key.sh backup`, or a normal `deploy.yml` run),
then confirm the live sealed-secrets/cnpg installs match the new apps (bitnami chart in ns
`sealed-secrets`; cnpg operator in ns `cnpg-system`) so ArgoCD adopts rather than duplicates.

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
- [ ] **Apple Developer Program** ($99/yr) + **Google Play Developer** ($25) accounts — the operator sets up; store submission blocked until then.
- [x] ~~Decide D-010~~ — **SDK repo + package are public** (2026-08-21).
- [ ] Pangolin: create the UAT + SpriteForge **Sites/resources** (manual in the Pangolin UI, like pterodactyl) and capture Newt IDs/secrets as sealed secrets.
- [ ] **Stripe:** create the games Stripe account + products/prices (test + live); decide what's sold (digital unlocks/cosmetics/remove-ads vs subscriptions). UAT = test keys, prod = live keys.

## 6. Next action

The cluster + app stack are live. The entire **no-keys audit backlog is now built + validated**
(pushed to `main`, both this repo + `andusystems-spriteforge`):

- ✅ Reproducibility trio (operators-as-apps, sealed-secrets key persistence, Kyverno baseline).
- ✅ Restore drill (`scripts/dr-drill.sh`) + real restore template + `Makefile` DR targets.
- ✅ `idlebartender` registered; monitoring remote_write wired to mgmt Prometheus; UAT edge TLS routes.
- ✅ `new-game.sh` fixed + `/new-game` skill; SpriteForge real S3 asset store (`go build` clean).

**Activate (operator):** run `deploy.yml` (create-or-keep) to (a) create the new ArgoCD apps and
(b) persist the sealed-secrets key; do the one-time cutover (§1); then verify a real redeploy.

**Remaining — key/account-gated (send keys → I build the slice):**
- **fal.ai** `FAL_KEY` → real SpriteForge generation (S3 store already persists whatever it returns).
- **Stripe** account + keys → payments schema + checkout + entitlements + webhook (Phase 7).
- **Apple Developer + Google Play** → store submission; **macOS build path** (CONFIRM) for iOS (Phase 6).
- **Pangolin resources** (manual UI) for `uat-api` / `uat.*` / `spriteforge` → capture Newt creds as sealed secrets.
- **Cloudflare** prod web DNS/records per game + (optional) Tunnel for the public save-api.

**Bigger builds (no keys, larger):** SpriteForge Rig&Animate + Export-to-S3 backends; mobile Fastlane
pipeline; the real idlebartender game (tic-tac-toe placeholder today); Phase 9 end-to-end sign-off.

### Ops model: GHA + GitOps only
Nothing operates the cluster from a devbox. `Makefile` targets are thin `gh workflow run` triggers:
`cluster`/`redeploy` → `deploy.yml`/`redeploy.yml`; `backup`/`dr-drill`/`{backup,restore}-sealed-key`
→ `ops.yml` (runs on the self-hosted runner, fetches kubeconfig, runs `scripts/*.sh` there).
Declarative state is GitOps (ArgoCD reconciles `apps/*`). Also triggerable from the Actions tab.

### Core loops — verified 2026-08-23
- **Backup loop ✅** WAL archiving + nightly base + on-demand + sealed-key, all three DBs → S3 (checked
  live: ContinuousArchiving=True, firstRecoverabilityPoint/lastSuccessfulBackup set, on-demand completes).
- **Restore ✅** `make dr-drill` (via `ops.yml`) passes: genesis→g1, recover g1→g2, write, recover g2→g3,
  row counts match. Proves the generation-bump pattern + repeatability.
- **Redeploy retains DBs ✅ (built)** `redeploy.yml` self-commits a recovery spec (recover latest S3
  generation → archive fresh one) via `scripts/cnpg-recovery-prepare.sh`, then seeds a base backup in the
  new generation. Ultimate proof is a real `redeploy CONFIRM=DESTROY` (de-risked; live clusters untouched
  until then). CNPG constraint that shaped this: can't archive to a non-empty serverName, so generations
  advance per rebuild; can't flip a live cluster's bootstrap, so recovery only lands on fresh clusters.
- ~~Operators hand-installed on the live cluster; ArgoCD must adopt not duplicate~~ **RESOLVED
  2026-08-23:** the first `deploy.yml` duplicated (sealed-secrets was raw-manifest in kube-system, cnpg
  was upstream manifests) — remediated interactively (canonical sealed-secrets key migrated into ns
  `sealed-secrets`, duplicates removed, cnpg rolled to 1.24.1, canonical key force-backed-up to S3). See
  `docs/runbook.md` cutover note. A fresh redeploy won't recur (no hand-installs on a clean cluster).
