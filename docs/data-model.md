# Data model — save-api Postgres (CloudNativePG)

Multi-tenant, one database per environment (`games-db` prod, `games-db-uat`). Opaque save blobs;
the server never parses game state. All ids are UUIDs unless noted. Migrations live in
`andusystems-games-save-api` (goose/atlas — TBD in Phase 2).

## Tables

```sql
-- The games registry, synced from apps/save-api/games-registry.yaml on boot/reload.
-- Registry file is source of truth; this table is its materialized form for FK integrity.
CREATE TABLE games (
  slug            text PRIMARY KEY,              -- e.g. 'asteroid-drift' == game_id
  save_mode       text NOT NULL,                 -- 'lww' | 'lww_history' | 'slots'
  history_depth   int  NOT NULL DEFAULT 0,
  max_slots       int  NOT NULL DEFAULT 1,
  max_blob_bytes  int  NOT NULL DEFAULT 262144,
  conflict        text NOT NULL DEFAULT 'last_write_wins',
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- An anonymous player identity (see identity.md). account_id is set only after linking.
CREATE TABLE players (
  player_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   uuid REFERENCES accounts(account_id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

-- A real account, created when a player upgrades from anonymous.
CREATE TABLE accounts (
  account_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email       citext UNIQUE,                     -- null until an email/OAuth identity is attached
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Device binding for the anonymous token (one player may have several devices after linking).
CREATE TABLE devices (
  device_id    text PRIMARY KEY,                 -- client-generated, stored hashed
  player_id    uuid NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
  platform     text,                             -- 'web' | 'ios' | 'android'
  first_seen   timestamptz NOT NULL DEFAULT now(),
  last_seen    timestamptz NOT NULL DEFAULT now()
);

-- The current save. One row per (game, player, slot). slot='default' for lww/lww_history.
CREATE TABLE saves (
  slug         text NOT NULL REFERENCES games(slug) ON DELETE CASCADE,
  player_id    uuid NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
  slot         text NOT NULL DEFAULT 'default',
  version      bigint NOT NULL DEFAULT 1,        -- server-assigned, monotonic per (slug,player,slot)
  etag         text   NOT NULL,                  -- for If-Match conflict checks
  blob         bytea,                            -- inline blob, or NULL if offloaded
  r2_key       text,                             -- set if blob offloaded to R2 (large saves)
  size_bytes   int    NOT NULL,
  checksum     text   NOT NULL,                  -- sha256 of the blob
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (slug, player_id, slot)
);

-- Retained revisions, only for lww_history / history-enabled slots. Pruned to games.history_depth.
CREATE TABLE save_history (
  slug        text NOT NULL,
  player_id   uuid NOT NULL,
  slot        text NOT NULL,
  version     bigint NOT NULL,
  blob        bytea,
  r2_key      text,
  size_bytes  int NOT NULL,
  checksum    text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (slug, player_id, slot, version)
);

CREATE INDEX ON players (account_id);
CREATE INDEX ON devices (player_id);
CREATE INDEX ON saves (player_id);
CREATE INDEX ON save_history (slug, player_id, slot);
```

## Payments tables (see `payments.md`)

```sql
-- SKUs, registry-synced from apps/save-api/products.yaml. price id resolved per-env from STRIPE_PRICE_*.
CREATE TABLE products (
  product_id  text PRIMARY KEY,               -- '<slug>.<thing>' or global e.g. 'coins.500'
  slug        text REFERENCES games(slug),    -- null = cross-game product
  kind        text NOT NULL,                  -- 'one_time' | 'subscription' | 'consumable'
  price_env   text NOT NULL,                  -- name of the STRIPE_PRICE_* var to use
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Entitlements attach to the ACCOUNT (cross-device), never the anonymous player.
CREATE TABLE entitlements (
  entitlement_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id     uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  product_id     text NOT NULL REFERENCES products(product_id),
  status         text NOT NULL,               -- 'active' | 'canceled' | 'refunded' | 'expired'
  source         text NOT NULL,               -- 'stripe' | 'apple_iap' | 'google_play'
  external_ref   text,                         -- stripe sub/payment id or store transaction id
  granted_at     timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz,                  -- null = perpetual (one_time)
  UNIQUE (account_id, product_id)
);

CREATE TABLE stripe_customers (
  account_id         uuid PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  stripe_customer_id text UNIQUE NOT NULL
);

-- Webhook idempotency: dedupe Stripe events so grants/revokes apply exactly once.
CREATE TABLE webhook_events (
  event_id    text PRIMARY KEY,               -- Stripe event id
  type        text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON entitlements (account_id);
```

## Invariants
- **Blob is opaque.** Server stores/returns bytes; the game owns the format and versions it
  internally.
- **`version` is server-assigned** and monotonic per `(slug, player_id, slot)`; `etag` derives from
  `(version, checksum)`.
- **History is bounded.** On each accepted write to a history-enabled game, append to
  `save_history` and prune rows beyond `history_depth`.
- **Offload rule:** `size_bytes > INLINE_BLOB_MAX` → `blob = NULL`, `r2_key` set (see
  `save-model.md#large-blobs`). Exactly one of `blob` / `r2_key` is non-null.
- **Env isolation:** prod and UAT are **separate databases** with separate JWT signing keys; no row
  crosses environments (D-007).

## Backups
CNPG streams WAL + scheduled base backups to R2 (`andusystems-games-backups`, prefix per db). A
rebuild restores from R2 (see `runbook.md`). Backup **age** is a monitored alert.
