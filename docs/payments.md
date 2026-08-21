# Payments & entitlements — Stripe (games-owned)

Games monetize through a **dedicated Stripe integration** modeled on Hireship's (same env-var
names, `/webhooks/stripe` HMAC pattern, checkout + customer portal, sealed per env) but on its
**own Stripe account/keys** — it does **not** share Hireship's resources (D-015).

## ⚠️ The store constraint (read this first)
Apple (Guideline **3.1.1**) and Google Play Billing require **their** in-app purchase system for
**digital goods consumed inside the app**. You may **not** ship a Stripe "Buy" button for digital
goods inside the iOS/Android app by default — that's a rejection. Stripe is fully allowed on the
**web**. So the compliant, low-risk model we use is **web-first purchase + entitlement sync**:

| Surface | How a purchase happens |
|---|---|
| **Web** (public prod, UAT) | Stripe Checkout directly — full flow, no store cut |
| **Mobile app** | Reads the **entitlement** (bought on web, attached to the account) and unlocks content. No in-app Stripe purchase for digital goods. |

The app *renders* purchased content because the entitlement is on the player's **account** — it
never processes the payment. This is the account-based "buy elsewhere, use in app" model stores
permit. Options if you later want in-app buying UX on mobile:
- **A — web-first entitlement (default, recommended):** as above. Simplest; zero store fees; no
  rejection risk.
- **B — external-purchase-link entitlement:** link out to web Stripe from inside the app, using
  Apple's External Purchase Link Entitlement / Google alternative billing. Allowed in **US/EU**
  (post-2025 injunction / DMA), reduced store commission still applies, more compliance overhead.
- **C — native IAP + Stripe hybrid:** Apple/Google IAP inside the app (store cut), Stripe on web;
  unify entitlements server-side. Highest reach, most work. Defer unless needed.

We build **A** now; the entitlement model makes **B/C** additive later without schema changes.

## Purchases require an account
Buying implies wanting the purchase to persist and follow the player, so **checkout requires a
linked account** (email via the identity flow — see `identity.md`). Entitlements attach to the
`account_id`, not the anonymous `player_id`, so they sync across every device and both web + app.

## Flow
1. Player links an account (email) if anonymous.
2. Web build calls `POST /v1/checkout { product_id }` → save-api creates a Stripe **Checkout
   Session** for that account's Stripe customer → returns `{ url }` → redirect.
3. Stripe → `POST /webhooks/stripe` (HMAC-verified): on `checkout.session.completed` /
   `customer.subscription.*` / refund events, grant/revoke an **entitlement** on the account
   (idempotent by event id).
4. Any surface reads `GET /v1/games/{slug}/entitlements` (and `/v1/entitlements` cross-game); the
   SDK exposes `entitlements()` and gates content. `POST /v1/billing/portal` → Stripe customer
   portal for self-serve manage/cancel.

## Products
Registry-driven, like games. A product maps to a Stripe **price id**:
```yaml
# apps/save-api/products.yaml (GitOps; env picks test vs live price ids)
products:
  - product_id: asteroid-drift.remove-ads   # <slug>.<thing>, or global e.g. coins.500
    slug: asteroid-drift                     # null = cross-game
    kind: one_time                           # one_time | subscription | consumable
    price_env: STRIPE_PRICE_ASTEROID_REMOVE_ADS
```
Data model: `products`, `entitlements`, `stripe_customers`, `webhook_events` — see `data-model.md`.

## Env config (mirrors Hireship, per-env)
Sealed secrets, **test mode for UAT / live for prod**:
```
GAMES_STRIPE_SECRET_KEY        # sk_test_… (uat) / sk_live_… (prod)
GAMES_STRIPE_WEBHOOK_SECRET    # whsec_… per env
GAMES_STRIPE_API_BASE          # test seam; empty in prod
STRIPE_PORTAL_RETURN_URL       # <slug>.games… (prod) / uat.<slug>… (uat)
STRIPE_PRICE_*                 # one per product, per env
```

## Gotcha: UAT webhooks can't be reached by Stripe
UAT API is **private (Pangolin)** — Stripe's servers can't POST to it. For test-mode webhooks, run
`stripe listen --forward-to https://uat-api.games.andusystems.com/webhooks/stripe` from the devbox
(which is on the Pangolin network), or use the Stripe CLI's local forward. **Prod** webhooks work
directly — the prod API is public via Cloudflare Tunnel. Flagged in `environments.md`.

## Reused Hireship conventions (not resources)
Same webhook path + HMAC verification, `STRIPE_PRICE_*`-per-SKU pattern, customer portal, AES-GCM
`SECRETS_ENCRYPTION_KEY` for any signed URLs, and the SIT/PROD secret split — but a separate Stripe
account, separate keys, separate products. Nothing points at Hireship (D-015).
