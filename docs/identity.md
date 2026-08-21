# Identity — anonymous device, upgradeable to account

Goal: zero signup friction for casual games, with a real path to cross-device sync later (D-003).
The **device is the source of truth**; the server is durable backup + sync.

## Anonymous, from first launch
1. On first run the SDK generates a random **`device_id`** and persists it (web: IndexedDB; native:
   Capacitor Preferences — survives app restarts, not reinstalls).
2. SDK calls `POST /v1/players { device_id, platform }` → server creates a `players` row + a
   `devices` row and returns a signed **token** (JWT).
3. The token is a **JWT (EdDSA)** with claims `{ player_id, ver, env, exp }`, signed by the
   environment's stable signing key. `device_id` is stored **hashed**; the token — not the raw
   device id — authorizes save/load.
4. SDK refreshes via `POST /v1/players/token { device_id }` before expiry.

**Stable signing key.** Each env (prod, UAT) has its own signing key that **must not rotate** — a
rotated key invalidates every live token (like `PTERO_APP_KEY`). Seeded once as a sealed secret,
kept across redeploys (see `AGENTS.md` rule 2).

## Upgrading to an account (opt-in, later)
When a player wants cross-device sync:
1. `POST /v1/players/link { method: "email"|"oauth", … }` → server starts a link (email magic-link
   or OAuth code).
2. `POST /v1/players/link/confirm { link_id, code }` → server creates/links an `accounts` row, sets
   `players.account_id`, **merges saves** (the anonymous player's saves become the account's;
   conflicts resolved by the game's `conflict` policy), and returns a new account-bound token.
3. Another device linking the same account attaches its own `devices` row under the same
   `player`/`account`, and syncs the shared saves.

Accounts are **optional forever** — a game that never calls `link` stays fully anonymous.

## Save lifecycle (why local-first)
Mobile OSes kill apps without warning and crash handlers can't reliably do network I/O. So:
- **Write locally first**, always. The SDK persists every change to device storage synchronously.
- **Sync opportunistically:** a debounced background `PUT` during play, plus a best-effort flush on
  `visibilitychange`/`pagehide` (web) and Capacitor `App` `pause`/`appStateChange` (native).
- **Reconcile on launch:** `GET` the server save, compare `version`, and apply last-write-wins (or
  the game's conflict hook). The server is a safety net, never the sole writer — this is the design
  that makes "save on close/crash" reliable despite unreliable close/crash hooks.

## Abuse surface (anonymous = harden the edge)
Anonymous registration is open, so protect it: Cloudflare WAF + rate-limit on `POST /v1/players`
and on writes; per-player/IP token buckets in-service; `max_blob_bytes` caps; optional proof-of-work
or Turnstile on registration if abused. UAT is Pangolin-gated so it needs none of this.
