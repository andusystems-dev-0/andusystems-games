# Building a game's web frontend

The reusable playbook for a game's client (Phaser + TypeScript + Vite), learned from **idlebartender**.
Pairs with `onboarding-a-game.md` (registry/DNS/stores) and `save-model.md`/`identity.md` (the API).

## Shape & deploy path (what idlebartender actually does)

A game is a **static bundle baked into a private nginx image**, hosted **on the games cluster** — not
Cloudflare Pages/R2. (Pages/R2 is still the option in `cloudflare.md`; idlebartender chose in-cluster
nginx so the same Pangolin+Traefik edge serves game web *and* the API. Either is fine; match an
existing game.)

```
game repo (andusystems-game-<slug>)
  └─ .github/workflows/image.yml   # GH Actions on the SELF-HOSTED runner
       builds the Vite bundle → nginx image → pushes to PRIVATE Forgejo (no public registries)
andusystems-games/apps/game-<slug>/resources.yaml
  └─ Deployment(image pinned to the build SHA) + Service + IngressRoute   # ArgoCD reconciles
```

**Release = bump the image SHA** in `apps/game-<slug>/resources.yaml` and push; ArgoCD rolls it.
The game CI only builds/pushes the image — it does **not** touch the games repo.

- **Exposure** (same as the save-api, below): an `IngressRoute` with `entryPoints: [web, websecure]`
  + `tls: {}` (the default `games-edge-tls` store cert — the `*.games.andusystems.com` wildcard, and
  the game's own domain via Cloudflare "Full"), fronted by a **Pangolin** resource that TCP-passes
  :443 to the games Traefik VIP `10.238.70.50`. **Cloudflare is DNS/CDN only.** No open ports, no
  exposed MetalLB VIP (estate rule 5).
- **Transient CI failures** (`error from registry: unknown`) are the shared mgmt cluster under build
  storms — just re-run `image.yml`.

## iOS home-screen ("web app") — the full-bleed recipe

This ate ~2 dozen deploys on idlebartender. Do it right the first time. To make an installed web app
fill the screen edge-to-edge in portrait (no top/bottom bars) on iOS:

1. **Do NOT link a web manifest.** A `<link rel="manifest">` makes iOS 16.4+ honor the manifest's
   `display` mode and **ignore `apple-mobile-web-app-status-bar-style`**, so it reserves the status bar
   → the webview is `screen − topInset` (e.g. 852 − 59 = **793**) pinned to the top → a dead bar at the
   bottom painted in the page bg color. `display: fullscreen` does **not** fix it. Just omit the link;
   the apple metas below are the proven full-bleed path (keep the manifest file for Android if you want,
   but don't link it on iOS — or serve it only to non-iOS).
2. **Apple metas** in `<head>`:
   ```html
   <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
   <meta name="apple-mobile-web-app-capable" content="yes" />
   <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
   <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
   ```
   No `user-scalable=no` (it can interfere with `viewport-fit=cover`; prevent zoom with `touch-action`).
3. **Make the document trivially scrollable** so iOS grants the FULL-height (large) viewport — a locked
   `overflow:hidden` page gets the SHORT one (the bar). The fixed canvas eats every touch, so nothing
   actually scrolls:
   ```css
   html { height: 100%; }
   body { margin: 0; min-height: calc(100vh + 2px); overscroll-behavior: none; background: <page-bg>; }
   #game { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; overflow: hidden; touch-action: none; }
   ```
   Add `window.scrollTo(0, 1)` on `load`/`orientationchange` to apply the large viewport instantly.
4. **Scale mode:** Phaser `Scale.ENVELOP` (cover/crop the sides) in portrait; switch to `FIT` in
   landscape so it pillarboxes instead of over-zooming.
5. **Applying changes:** manifest/status-bar are baked at *add-to-home-screen* → the user must
   delete + re-add. The scrollable-doc part is per-load (ships via the auto-updater).
6. **Auto-updater:** home-screen apps resume a *cached* page, so a new deploy looks like it "didn't
   apply." In `main.ts`, on `visibilitychange`/`pageshow` fetch `/` no-store, compare the running
   `assets/index-*.js` hash to the served one, and `location.reload()` if changed (save first).
7. **Diagnosing iOS viewport/safe-area:** `chromium --headless` **cannot** reproduce it (and can't
   screenshot a WebGL canvas). Use an on-device probe: append `position:fixed` divs sized to each unit
   (`100vh`,`100dvh`,`env(safe-area-inset-*)`, …), read `getBoundingClientRect().height`, and print
   `innerHeight`/`screen.height`/`navigator.standalone`; have the user screenshot once.

Also: build the HUD/menus as a **DOM overlay** above the canvas (crisp text, reliable taps). Put
`pointer-events: none` on the overlay root and `auto` only on real controls, and **`stopPropagation`**
pointer events on the overlay — otherwise a tap on a control bubbles to `window`, wedges Phaser's
pointer state, and breaks flicking/dragging after a menu closes.

## Cloud saves (durable, cross-device, survives app deletion)

Everything server-side already exists — the shared **save-api** + **`@andusystems/games-sdk`** (see
`save-model.md`, `identity.md`, `api-spec.md`). To add saves to a game:

1. **Register** the game in `apps/save-api/games-registry.yaml` (`save_mode: lww` for a single blob).
2. **Bundle the SDK.** It's public but not on npm — either vendor `andusystems-games-sdk/src/*` into
   `src/sdk/` (idlebartender does this: zero CI/dep risk; drop the `.js` import extensions) or add it
   as a git dependency. Bundle at build time.
3. **Local-first wiring** (idlebartender's `state.ts`):
   - Keep your existing synchronous local save (localStorage) as the **instant source of truth** — this
     is what makes **updates/redeploys never lose progress** (localStorage is per-origin; the
     auto-updater saves before reload).
   - `initCloud()` after boot (never blocks): `AnduGames.init({ gameId, env: 'prod', deviceId })`, then
     `await cloud.load()` and **adopt the server save if it's "ahead"** (e.g. compare a monotonic
     lifetime score) — this handles a fresh install + restore code and a second device. Otherwise push
     local up. `save()` mirrors to the cloud (SDK debounces + flushes on hide).
4. **Restore across app deletion / a new phone.** Local storage is wiped on delete, so this needs a
   recovery identity. The **device id doubles as a backup code**: `POST /v1/players` is idempotent per
   device id (returns the same player), so surface `getBackupCode()` (= the device id) for the player to
   copy, and `restoreFromCode(code)` = set `andu:device_id` to the code, clear local, reload → the
   cloud save is adopted. (Anyone with the code can read that save — fine for casual progress; a real
   account link is the future upgrade, `identity.md`.)
5. **It's optional/graceful:** with the API unreachable the SDK stays local-only — no boot block, no
   regression. Which means you can ship the client before the endpoint is exposed.