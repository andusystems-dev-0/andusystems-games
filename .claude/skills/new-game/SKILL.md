---
name: new-game
description: Onboard a new game to the andusystems games estate — create the public game repo from the template and register it with the shared save-api. Use when the user wants to add/onboard a new game, scaffold a game repo, or register a game slug in the save-api registry.
---

# Onboard a new game

Full background: `docs/onboarding-a-game.md`. This skill is the executable version. Adding a game is
**one command + one PR** and adds **no cluster workload** (all games share the prod + UAT save-api).

## The one command

From the devbox, or via GitHub → Actions → **new-game** (`.github/workflows/new-game.yml`):

```sh
./scripts/new-game.sh <slug> [save_mode] [max_slots] [history_depth]
#   slug       kebab-case [a-z0-9-]; becomes gameId + hostnames + bundle id com.andusystems.games.<slug>
#   save_mode  lww (default) | lww_history | slots
#   max_slots  default 1        history_depth  default 0
```

It (1) creates the public repo `andusystems-dev-0/andusystems-game-<slug>` from
`andusystems-games-template`, then (2) appends the game to `apps/save-api/games-registry.yaml` on a
branch and opens a PR. The script validates the slug/mode and refuses a duplicate slug up front.

## What happens on merge (automatic)

- ArgoCD reconciles the registry ConfigMap → **both** save-api prod and UAT hot-reload it (same
  registry, separate DBs). The game can now register identities + save/load.
- **UAT reachability is already wired**: `uat.<slug>.games.andusystems.com` matches the existing
  `web-uat` wildcard IngressRoute (websecure) behind the Pangolin `uat.*.games…` resource. No per-game
  route or DNS is needed for UAT.
- Push to the new game repo → its CI builds the web bundle once → publishes to R2 (`uat/<slug>/`,
  `prod/<slug>/`) and calls the shared `mobile-package.yml`.

## Remaining manual steps (by design — need accounts/keys, do once per game)

- **Prod web DNS/route:** create the `<slug>.games.andusystems.com` Cloudflare record → Pages/Worker
  serving R2 `prod/<slug>/` (needs the Cloudflare API token). UAT needs nothing (wildcard, above).
- **Store records (first release):** App Store Connect + Play Console entries for
  `com.andusystems.games.<slug>` (needs the Apple/Google accounts).
- **Payments (only if the game sells something):** add products to `apps/save-api/products.yaml` +
  the `STRIPE_PRICE_*` secret — see `docs/payments.md`.

## Gotchas

- The registry key **must** match the game's `game.json` `slug` and `VITE_GAME_ID` (check the new
  repo's `.env.uat`/`.env.prod` — the template's `.env.uat.example` may still say `demo-tapper`).
- `save_mode`/`max_slots` must be consistent: `slots` ⇒ `max_slots > 1`; `lww`/`lww_history` ⇒
  `max_slots = 1`. See `docs/save-model.md`.
- The API hot-reloads the registry; you do **not** redeploy save-api to add a game.
