# Onboarding a game

Adding game #N must never touch the cluster. It's a template clone, a registry PR, and a CDN/store
publish. Target: one command (`scripts/new-game.sh <slug>`) + one PR.

> **Client build, iOS web-app full-bleed, and cloud saves:** see **`game-frontend.md`** — the
> hardened playbook from idlebartender (it also documents that the first game ships as an in-cluster
> nginx image via GH Actions → Forgejo → ArgoCD, exposed through Pangolin + Cloudflare DNS, rather
> than the Pages/R2 path sketched in step 5 below).

## Prerequisites (once)
Cluster + edge + save-api live (ROADMAP 0–2); template + SDK ready (3–4); payments + mobile ready
if the game sells or ships to stores (6–7).

## Steps
1. **Create the repo** from the template (public):
   ```bash
   gh repo create andusystems-dev-0/andusystems-game-<slug> \
     --template andusystems-dev-0/andusystems-games-template --public
   ```
2. **Fill `game.json`** in the new repo: `slug`, display name, bundle id
   `com.andusystems.games.<slug>`, icon/splash (a SpriteForge asset), orientation.
3. **Register the game** — PR to this repo adding `apps/save-api/games-registry.yaml`:
   ```yaml
   - slug: <slug>
     save_mode: lww          # lww | lww_history | slots
     history_depth: 0
     max_slots: 1
     max_blob_bytes: 262144
     conflict: last_write_wins
   ```
   ArgoCD reconciles; prod + UAT save-api hot-reload. (If it sells anything, also add to
   `products.yaml` — see `payments.md`.)
4. **DNS + R2** (scripted): `<slug>.games…` (prod, Cloudflare) and `uat.<slug>.games…` (UAT,
   Pangolin wildcard already covers it); R2 prefixes `prod/<slug>/` + `uat/<slug>/`.
5. **Ship**: the game repo's CI builds the web bundle once →
   - UAT: publish to R2 `uat/<slug>/` (reachable via Pangolin) + `beta` mobile lane (TestFlight /
     Play internal).
   - Prod (after sign-off): promote the **same** artifact to R2 `prod/<slug>/` + `release` mobile lane.
6. **Stores** (first time per game): create the App Store Connect + Play Console app records for
   `com.andusystems.games.<slug>` (see `mobile-release.md`).

## What you do NOT do
- No new Deployment, Service, or ArgoCD app — all games share the save-api, the UAT static host,
  and the mobile shell.
- No per-game native/mobile code — the wrapper is generic (`mobile/shell`).
- No new database — the game is a `slug` partition of the shared multi-tenant schema.

## Automate it
`scripts/new-game.sh <slug>` does 1–4 and opens the registry PR; a an automation agent skill `/new-game`
wraps it (mirror the pterodactyl `/game-port` skill). Keep this doc as the runbook of record.
