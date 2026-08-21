# Environments — UAT (private) & prod (public)

Every game has two fully isolated environments (D-007). One web build flows to both; nothing
crosses between them.

## Matrix

| | **UAT** (private) | **Prod** (public) |
|---|---|---|
| Web | `uat.<slug>.games.andusystems.com` via **Pangolin** (Newt) → shared UAT static host (serves R2 `uat/<slug>/`), IP-allow-listed | `<slug>.games.andusystems.com` via **Cloudflare** (Pages/Worker → R2 `prod/<slug>/`) |
| Save API | `uat-api.games.andusystems.com` via **Pangolin** → `save-api-uat` | `api.games.andusystems.com` via **Cloudflare Tunnel** → `save-api` |
| Database | CNPG `games-db-uat` (ns `save-api-uat`) | CNPG `games-db` (ns `save-api`) |
| JWT signing key | UAT key (stable) | prod key (stable, different) |
| Stripe | **test** keys/prices; webhooks via `stripe listen` | **live** keys/prices; webhook direct (public) |
| Store track | TestFlight + Play **internal testing** | App Store + Play **production** |
| R2 prefix | `uat/<slug>/` | `prod/<slug>/` |
| Reach | Alex only (Pangolin allow-list) | anyone |

## Why isolated
UAT is where a build is exercised before public release — its saves, purchases (Stripe test), and
identities must never touch prod data. Separate deployments + databases + keys guarantee that. The
only shared thing is the **games registry** (`games-registry.yaml` / `products.yaml`), read by both
against their own DBs.

## Shared UAT static host
Rather than a web deployment per game (which would grow cluster workloads), **one** static-file
service in ns `web-uat` serves every game's UAT bundle from R2 `uat/<slug>/`, routed by hostname.
It sits behind Traefik → Newt → a Pangolin **wildcard** resource `uat.*.games.andusystems.com`
(IP-allow-listed). Adding a game adds a prefix + a DNS/route entry, not a workload.

## Pangolin resources (create in the Pangolin UI, like pterodactyl)
- `uat.*.games.andusystems.com` → Traefik VIP `10.238.70.50` (UAT web, wildcard, allow-list).
- `uat-api.games.andusystems.com` → Traefik VIP (UAT API, allow-list).
- `spriteforge.andusystems.com` → Traefik VIP (SpriteForge, allow-list).
Capture each Site's Newt id/secret as a sealed secret; the co-located Newt (`apps/edge/newt`) dials
out. Full 3-layer model (game → tunnel → edge) mirrors `andusystems-pterodactyl/docs/pangolin.md`.

## Gotcha: Stripe test webhooks can't reach UAT
UAT API is private, so Stripe's servers can't POST to it. For test-mode webhooks run
`stripe listen --forward-to https://uat-api.games.andusystems.com/webhooks/stripe` from the devbox
(on the Pangolin network). Prod webhooks work directly through the Tunnel. See `payments.md`.

## Promotion
A commit's web build is published to UAT first (Pangolin + TestFlight/Play-internal). After
sign-off, the **same artifact** is promoted to prod (Cloudflare + store production) — no rebuild,
no divergence (D-012). Promotion is a CI action, not a new build.
