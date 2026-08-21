# ROADMAP — andusystems games estate

The phased build plan. Each phase is independently shippable and leaves the estate in a working
state. Check boxes as you go; keep `STATE.md` in sync. Phases 0–2 are the critical path to "a game
can save"; 3–6 make games easy to ship; 7 is payments; 8 is SpriteForge; 9 proves it end-to-end.

Legend: ⛴ = shippable milestone. `CONFIRM` = verify against live estate first.

---

## Phase 0 — Cluster foundation ⛴
Goal: a healthy games k3s cluster, registered as an ArgoCD spoke, sending metrics to mgmt Grafana.

- [ ] `terraform/` — 3 VMs on **games VLAN 70** (verified free), `bpg/proxmox`, static IPs `.41-.43`. State in S3 `games/layer-1-cluster`. **Applied via `.github/workflows/deploy.yml` on self-hosted runners** (`[self-hosted, linux, andusystems-mgmt]`), not locally.
- [ ] `ansible/` — install k3s HA (reuse `andusystems-platform` `k3s-cluster` module conventions), fetch kubeconfig.
- [ ] MetalLB pool `.50-.69`; Traefik (VIP `10.238.70.50`); sealed-secrets controller; cert-manager (DNS-01 Cloudflare) for internal TLS.
- [ ] Kyverno policies pulled in (runAsNonRoot, drop-ALL) to match estate baseline.
- [ ] `make register-spoke` — add this cluster to the **mgmt ArgoCD** as a managed cluster; create the `games` AppProject + app-of-apps pointing at `apps/`.
- [ ] `apps/monitoring` — grafana-agent (or Prometheus agent) remote_write → mgmt LGTM/Mimir. Confirm nodes appear in mgmt Grafana.
- [ ] `scripts/bootstrap-secrets.sh` + `.env.example` + `sync-gh-secrets.sh` (model on pterodactyl).

## Phase 1 — Edge & data ⛴
Goal: the cluster can be reached the two intended ways, and Postgres is durable.

- [ ] `apps/cnpg` — CloudNativePG operator + `games-db` (prod, ns `save-api`) and `games-db-uat` (ns `save-api-uat`), each with barman-cloud backups → **R2**.
- [ ] Cloudflare: create zone records + **R2 buckets** (`andusystems-games-bundles`, `andusystems-games-backups`), API token (DNS + R2 + Tunnel) as sealed secret. See `docs/cloudflare.md`.
- [ ] `apps/cloudflared` — Cloudflare **Tunnel** publishing `api.games.andusystems.com` → Traefik → `save-api` (prod only). WAF + rate-limit rules on that hostname.
- [ ] `apps/edge/newt` — co-located **Newt** connector for the Pangolin private resources. Create Pangolin Sites/resources (manual UI, capture Newt IDs/secrets as sealed secrets): `uat-api.games…`, `uat.<slug>.games…` (wildcard), `spriteforge.andusystems.com`. IP-allow-list. See `docs/environments.md`.
- [ ] `make backup` / `make restore` verified: kill `games-db`, restore from R2, data intact.

## Phase 2 — Save API (prod + UAT) ⛴  ← the core deliverable
Goal: games can register an anonymous identity and save/load state; all three save shapes work.

Build in `andusystems-games-save-api`, deploy here via `apps/save-api` (+ `apps/save-api-uat`).
- [ ] Schema migrations per `docs/data-model.md` (games registry, players, accounts, devices, saves, save_history).
- [ ] Endpoints per `docs/api-spec.md`: register/link identity; PUT/GET/LIST/DELETE saves; history; `/healthz` `/readyz` `/metrics`.
- [ ] Identity per `docs/identity.md`: anonymous device token (JWT, stable signing key), account link/merge.
- [ ] Save model per `docs/save-model.md`: per-game `save_mode` (`lww` | `lww_history` | `slots`), history depth, blob-size + slot caps; large-blob → R2 offload threshold.
- [ ] **Games registry** as GitOps: `apps/save-api/games-registry.yaml` (ConfigMap); API hot-reloads; UAT + prod read the same registry, separate DBs.
- [ ] Two deployments: prod (`save-api`, behind Tunnel) + UAT (`save-api-uat`, behind Pangolin), separate CNPG + separate signing key. ServiceMonitor → mgmt Grafana.
- [ ] Rate-limit, request-size cap, idempotent upsert, ETag/If-Match conflict handling.

## Phase 3 — SDK ⛴
Goal: one versioned TypeScript client both web and mobile games use.

Build in `andusystems-games-sdk`.
- [ ] `AnduGames` client: `init({gameId, env, baseUrl})`, `save(slot?, blob)`, `load(slot?)`, `list()`, `delete(slot?)`, `history(slot?)`, `linkAccount()`.
- [ ] **Local-first**: writes to device storage (web: IndexedDB; native: Capacitor Preferences/Filesystem) as source of truth, then **debounced background sync** + best-effort flush on close/crash (see `docs/identity.md`).
- [ ] Offline queue + retry/backoff; conflict policy hook; env-aware base URL (prod vs uat).
- [ ] Publish package (GitHub Packages; public if D-010 flips). Semver.

## Phase 4 — Game template ⛴
Goal: `gh repo create andusystems-game-<slug> --template andusystems-games-template` yields a
buildable **web** game wired to the SDK. The web bundle is the **only** artifact a game author
produces — the store apps are a generic wrapper around that same bundle (Phase 6), never
hand-written per game.

Build in `andusystems-games-template`.
- [ ] Phaser + Vite scaffold; SDK dependency; env config (`.env.uat` / `.env.prod`) with API base + `gameId`.
- [ ] Save-lifecycle wiring: web `visibilitychange`/`pagehide` (and Capacitor `App` pause/resume once wrapped) → SDK flush.
- [ ] `game.json` manifest: `slug`, display name, bundle id `com.andusystems.games.<slug>`, icon/splash source (a SpriteForge asset), orientation.
- [ ] CI: build web **once** → publish (uat → R2 `uat/<slug>/` behind the Pangolin static host; prod → R2 `prod/<slug>/` on Cloudflare), then call the shared mobile-package workflow (Phase 6) with that same artifact.

## Phase 5 — Onboarding automation ⛴
Goal: adding a game is one command + one PR.

- [ ] `scripts/new-game.sh <slug>` — create repo from template, open a PR adding the game to `games-registry.yaml`, provision DNS (`<slug>.games…`, `uat.<slug>.games…`), R2 prefixes, and bundle id.
- [ ] an automation agent skill `/new-game` wrapping it (mirror the pterodactyl `/game-port` skill pattern).
- [ ] `docs/onboarding-a-game.md` kept as the runbook of record.

## Phase 6 — Mobile store pipeline ⛴
Goal: the **same web bundle** is packaged into a thin **offline** Capacitor shell and shipped to
the stores — no per-game native code, no separate game development.

Build the shared wrapper + reusable workflow in **this** (public) repo so public game repos can call it.
- [ ] `mobile/shell` — one generic Capacitor app; `webDir` = the game's built bundle (assets bundled **offline**, not a remote URL); reads `game.json` for id/name/icons/splash/orientation.
- [ ] `.github/workflows/mobile-package.yml` (reusable `workflow_call`): input = {slug, web-artifact, track}; regenerates the Android/iOS projects, injects metadata, builds signed `.aab`/`.ipa`.
- [ ] Native save routes through the SDK via Capacitor Preferences/Filesystem (source of truth) — keeps it a real offline game and clears App Store 4.2 "minimum functionality" (see `docs/mobile-release.md`).
- [ ] Apple Developer + Google Play accounts (the operator); service-account JSON + Apple API key as sealed/GH secrets.
- [ ] **Fastlane** lanes: `beta` (TestFlight + Play internal = UAT), `release` (App Store + Play production = prod). Signing: Play App Signing; iOS match/manual. macOS runner path resolved (CONFIRM).
- [ ] Store metadata/screenshots pipeline (optionally sourced from SpriteForge).

## Phase 7 — Payments & entitlements ⛴
Goal: players buy on the web via Stripe; entitlements sync to every surface, incl. the store app.

Build in `andusystems-games-save-api` (payments module), deploy with the API. See `docs/payments.md`.
- [ ] Own Stripe account + products/prices (test **and** live); `apps/save-api/products.yaml` registry (GitOps).
- [ ] Schema: `products`, `entitlements` (on `account_id`), `stripe_customers`, `webhook_events` (idempotency).
- [ ] Endpoints: `POST /v1/checkout`, `POST /v1/billing/portal`, `GET …/entitlements`, `POST /webhooks/stripe` (HMAC).
- [ ] Checkout requires a linked account (triggers the identity link flow); grant/revoke on webhook events, exactly once.
- [ ] SDK: `entitlements()` + `checkoutUrl()` (web only); the app gates content on entitlements — never buys in-app for digital goods.
- [ ] Env: **test** keys for UAT, **live** for prod; UAT webhooks via `stripe listen --forward-to` (UAT API is private).
- [ ] **Store compliance:** no in-app Stripe purchase for digital goods (App Store 3.1.1 / Play Billing) — see `docs/mobile-release.md`.

## Phase 8 — SpriteForge (parallelizable after Phase 1)
Goal: a private studio to generate 2D assets and many animations from one asset.

Tracked in `andusystems-spriteforge/ROADMAP.md`. Deploys here via `apps/spriteforge`, reached via
Pangolin. Depends only on Phase 0/1 (cluster + edge + CNPG + R2), not on the save API.

## Phase 9 — First game, end-to-end ⛴
Goal: prove the whole path with one real (tiny) game.

- [ ] Scaffold `andusystems-game-<slug>`; art from SpriteForge; save via SDK.
- [ ] UAT: reachable via Pangolin, TestFlight + Play internal build installs and saves.
- [ ] Prod: public URL live on Cloudflare; store production submission passes review.
- [ ] Grafana shows the game's save traffic; R2 has its saves; a restore drill recovers them.

---

## Cross-cutting (do continuously, not a phase)
- Observability: per-service dashboards in mgmt Grafana; alerts on save error-rate/latency, DB, backup-age.
- Security: WAF + rate-limits on public API; Pangolin IP-allow-lists on private resources; Kyverno enforce; no secrets in the public repo.
- DR: monthly restore drill (CNPG from R2); the redeploy contract (destroy+recreate+restore) verified like pterodactyl's.
