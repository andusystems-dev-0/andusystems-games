# API spec — save-api v1

Small, boring, REST/JSON over HTTPS. One service, two deployments (prod behind Cloudflare Tunnel at
`api.games.andusystems.com`; UAT behind Pangolin at `uat-api.games.andusystems.com`). Contract is
identical across envs; only the base URL and signing key differ. Blobs are opaque bytes.

Auth: `Authorization: Bearer <token>` where the token is the anonymous device JWT (see
`identity.md`). All routes are per-`game_id` (the game's `slug`).

## Identity

```
POST /v1/players                      # register an anonymous player for this device
  body: { device_id, platform }       # device_id client-generated (random, persisted)
  200:  { player_id, token, expires_at }

POST /v1/players/token                 # refresh / re-mint a token for a known device
  body: { device_id }
  200:  { token, expires_at }

POST /v1/players/link                  # begin linking an account (email magic-link / OAuth)
  auth: bearer
  body: { method: "email"|"oauth", email? , oauth_code? }
  202:  { link_id }                    # completes via callback; merges saves on success

POST /v1/players/link/confirm          # confirm email code / oauth; merges anon player → account
  body: { link_id, code? }
  200:  { account_id, token }          # new token now bound to the account
```

## Saves

```
PUT    /v1/games/{slug}/saves/{slot}   # upsert (slot defaults to 'default' for lww modes)
  auth: bearer;  header If-Match: <etag>   (optional; required if game conflict=reject_stale)
  body: raw bytes (Content-Type: application/octet-stream) or { blob: <base64>, client_version? }
  200:  { slot, version, etag, size_bytes, updated_at }
  409:  { current: {version, etag, blob|r2_url}, message }     # stale write, reject_stale games
  413:  { max_blob_bytes }                                     # too large

GET    /v1/games/{slug}/saves/{slot}   # load current
  auth: bearer
  200:  { slot, version, etag, blob|r2_url, size_bytes, updated_at }
  404:  no save yet

GET    /v1/games/{slug}/saves          # list slots (slots-mode games)
  auth: bearer
  200:  { slots: [ {slot, version, etag, size_bytes, updated_at} ] }

DELETE /v1/games/{slug}/saves/{slot}
  auth: bearer;  200: { deleted: true }

GET    /v1/games/{slug}/saves/{slot}/history            # lww_history / history-enabled slots
  auth: bearer;  200: { versions: [ {version, size_bytes, created_at} ] }

GET    /v1/games/{slug}/saves/{slot}/history/{version}  # fetch a specific revision
  auth: bearer;  200: { version, blob|r2_url, checksum, created_at }
```

## Ops

```
GET /healthz     # liveness (no deps)
GET /readyz      # readiness (DB + registry loaded)
GET /metrics     # Prometheus (scraped by ServiceMonitor → mgmt LGTM)
GET /v1/games/{slug}/config   # public: the game's save_mode/caps (SDK self-configures)
```

## Payments & entitlements (see `payments.md`)

```
POST /v1/checkout                      # web only; requires an account-bound token
  auth: bearer;  body: { product_id, return_url? }
  200:  { url }                        # Stripe Checkout Session URL → redirect

POST /v1/billing/portal                # Stripe customer portal (manage/cancel)
  auth: bearer(account);  200: { url }

GET  /v1/games/{slug}/entitlements     # the app/web reads this to gate content
  auth: bearer;  200: { entitlements: [ {product_id, status, expires_at} ] }

GET  /v1/entitlements                   # cross-game, all products for the account
  auth: bearer;  200: { entitlements: [...] }

POST /webhooks/stripe                   # Stripe → grant/revoke; HMAC-verified, idempotent by event id
  200 always (204 on dupes)
```

- Checkout **requires a linked account** (entitlements attach to `account_id`, not the anonymous
  player) — the SDK triggers the link flow first if needed.
- **Mobile note:** the app must **not** call `/v1/checkout` for digital goods (App Store 3.1.1 /
  Play Billing) — it only reads `entitlements`. Web builds drive checkout. See `mobile-release.md`.

## Rules
- **Idempotent upsert** keyed on `(slug, player_id, slot)`; server assigns `version`/`etag`.
- **Size cap** per game (`max_blob_bytes`); large blobs offload to R2 transparently (blob returned
  as `r2_url`, a short-lived signed GET).
- **Rate limits** at the edge (Cloudflare WAF for prod) and in-service (token-bucket per player/IP).
- **Registry-driven:** unknown `slug` → 404; a game's mode/caps come from the registry
  (`save-model.md`).
- **Versioned path** (`/v1`) so the contract can evolve without breaking shipped games.
- Errors are JSON `{ error, message }` with correct status codes; every response carries a
  `request_id` (traced to Grafana/Tempo).
