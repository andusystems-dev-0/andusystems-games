# Decisions (ADR log) — andusystems games estate

Every material design decision, with the tradeoff, so future-you doesn't re-litigate them. Status:
**accepted** unless noted. Supersede rather than edit when a decision changes.

---

### D-001 — Dedicated games cluster (not a namespace) — accepted
Separate k3s cluster for games, apart from the SaaS estate.
**Why:** games are public, anonymous, internet-facing, and bursty; SaaS is authenticated/paying.
A separate cluster gives a hard blast-radius + security boundary, independent lifecycle, and clean
cost attribution. Compute is trivial, so the cluster is small.
**Cost:** a second control plane to run. Mitigated by making it an ArgoCD **spoke** of the mgmt
hub, so ops is centralized. **Alternative rejected:** a `games` namespace on an existing cluster —
softer isolation, but chosen against because public game traffic must not share a control plane
with SaaS.

### D-002 — Edge/CDN = Cloudflare — accepted
R2 for bundles, Pages/Worker for hosting, Cloudflare **Tunnel** for the prod API, WAF + rate-limits.
**Why:** R2 has **zero egress** (games are almost all bandwidth); the Tunnel exposes an on-prem
origin with **no open ports and no exposed MetalLB VIP** (directly sidesteps the estate's
VIP-reachability constraint); WAF/DDoS/rate-limit are built in. **Alternative rejected:** AWS
CloudFront+S3+WAF+ALB — more moving parts and egress cost, only wins if already AWS-invested. TF
state stays in S3, but that's the only AWS surface here.

### D-003 — Identity = anonymous device id, upgradeable — accepted
First launch mints a device-bound id + signed token; a player can later link an email/OAuth account
to sync across devices and merge saves.
**Why:** zero signup friction for casual games, but a real growth path. **Alternative rejected:**
accounts-from-day-one (friction) and anonymous-only (loses saves on device reset, no cross-device).
See `identity.md`.

### D-004 — Save model = all three shapes, per-game configured — accepted
Per-game `save_mode`: `lww` (single blob, last-write-wins — the default), `lww_history` (LWW + keep
N revisions), `slots` (multiple named saves). Configured in the games registry.
**Why:** Alex confirmed most games are LWW, some want light history, some want named slots. One
schema + one API serve all three via config; no per-game backend. See `save-model.md`.

### D-005 — Datastore = in-cluster CloudNativePG Postgres — accepted
Multi-tenant schema, backups to R2.
**Why:** keeps save data on our own infra (matches the on-prem estate ethos), standard robust
tooling, HA-capable. **Alternatives rejected:** Cloudflare D1 (couples data to CF, blob/row limits,
less sovereign); managed cloud Postgres (external dependency + cost).

### D-006 — One shared save-api for all games — accepted
A single multi-tenant service keyed by `(game_id, player_id, slot)`; adding a game is a registry
entry, never a new deployment.
**Why:** the axis that must stay flat as game count grows is *cluster workloads*, not repos. If a
game ever needs bespoke server logic, extend the shared API — don't fork a per-game backend.

### D-007 — Every game has UAT (private) + prod (public) — accepted
UAT is a Pangolin-gated, IP-allow-listed environment; prod is public on Cloudflare. Fully isolated:
separate API deploy, DB, signing key, R2 prefix, and store track.
**Why:** Alex wants to test privately before public release, on both web and store builds.
See `environments.md`.

### D-008 — Games ship to the App Store + Play Store — accepted
Released via Fastlane: TestFlight + Play-internal = UAT; production tracks = prod.
**Why:** reach mobile users through the stores, not just the web.

### D-009 — SpriteForge is a private cluster app via Pangolin — accepted
AI 2D asset+animation studio; deploys to the games cluster, reached only through a Pangolin private
resource; heavy inference via a cloud gateway (no GPU on-prem).
**Why:** Alex wants a fast private asset pipeline on their infra without running GPUs. See
`andusystems-spriteforge/`.

### D-010 — SDK repo + package are public — accepted (2026-08-21)
The **SDK repo and npm package are public** (thin client, no secrets); the *server* and the
*template* stay private. Public game repos then `npm install @andusystems/games-sdk` with **no auth
tokens** — no CI friction, open-source-friendly. Supersedes the earlier "private" request, at Alex's
direction ("make it public").

### D-011 — Mobile app = thin offline wrapper of the same web bundle — accepted
The game is one **web bundle**. The store apps are a **generic Capacitor shell** that bundles that
exact web build **offline** and renders it — no per-game native code, no separate development.
The shell + a reusable packaging workflow live in the **public** `andusystems-games` repo so public
game repos can call them without private-repo access.
**Why:** Alex wants store apps that are "just a rendered version of the website." Bundling assets
**offline** (not a remote URL) + native save via Capacitor keeps it a real, self-contained app,
which clears **App Store Guideline 4.2** (minimum functionality / "not just a website"). A remote-URL
webview would risk rejection and require connectivity. See `mobile-release.md`.

### D-012 — Web build is the single source artifact — accepted
CI builds the web bundle **once** per commit and fans it out: → R2 `prod/` (Cloudflare) or `uat/`
(Pangolin static host) → the Capacitor shell for the stores. One artifact, three delivery channels;
no divergence between web and app.

### D-013 — Cloud inference gateway for SpriteForge (fal.ai primary, Replicate fallback) — accepted
**Why:** cheapest per-call, fastest to ship, no GPU ops; broad model catalog (FLUX, ControlNet,
IP-Adapter/Redux, SAM 2, video). Abstracted behind a provider interface so a self-hosted **ComfyUI**
path can be added later if a GPU node appears. See `andusystems-spriteforge/docs/models.md`.

### D-014 — Animation via skeletal rig first, redraw second — accepted
"One asset → many animations without changing the asset" is achieved by **rigging** the cutout
(auto-segment → bones → reusable animation presets) and exporting Spine/DragonBones — the pixels
never change, only transforms. Per-frame **redraw** (IP-Adapter reference + ControlNet pose) is the
fallback when rigging can't express the motion; image-to-video is reserved for ambient effects.
See `andusystems-spriteforge/docs/animation.md`.

### D-015 — Payments = games-owned Stripe, web-first entitlement sync — accepted
A dedicated Stripe integration (own account/keys, modeled on Hireship's conventions — **not** its
resources). Purchases happen on the **web**; a webhook grants an **entitlement** on the account;
web + app read entitlements to unlock content.
**Why:** reuse a proven Stripe pattern while respecting store policy — Apple **3.1.1** / Google Play
Billing require IAP for **in-app** digital goods, so a Stripe "Buy" button inside the app risks
rejection. Web-first + entitlement sync sidesteps that with zero store fees and no rejection risk;
external-link entitlements (US/EU) or native IAP can be added later without schema changes.
**Alternatives deferred:** external-purchase-link entitlement (B), native IAP hybrid (C) — see
`payments.md`. **Rejected:** sharing Hireship's Stripe account (Alex: separate resources).

### D-016 — Entitlements attach to accounts, so checkout requires an account — accepted
Buying links (or creates) an email account; entitlements key on `account_id` and sync across
devices and surfaces.
**Why:** a purchase must persist and follow the player; anonymous-only can't do that. This also
nudges the account-upgrade path in `identity.md`.

### D-017 — SpriteForge classifies assets by game; game-scoped generation uses them as context — accepted
Every asset belongs to a game (or `shared`); generating for a game injects that game's existing
assets + palette + style tokens (+ optional per-game LoRA) as context so new art **looks like it
belongs**. See `andusystems-spriteforge/docs/style-packs.md`.
**Why:** a game's art must stay coherent as it grows; per-game **style packs** make consistency the
default rather than a per-prompt effort.

---

## Open decisions to close
- ~~CONFIRM games VLAN~~ → **VLAN 70** (`10.238.70.0/24`) chosen, verified free against the live map (2026-08-21).
- **CONFIRM** macOS build path for iOS — Mac mini vs hosted macOS runner (before Phase 6 iOS).
