# Cloudflare edge

Everything **public/prod** goes through Cloudflare. Everything **private/UAT** goes through Pangolin
instead (see `environments.md`) — this doc is the prod edge only.

## Zone & DNS
- Zone: **`games.andusystems.com`** (sub-zone of the estate's `andusystems.com`).
- `<slug>.games.andusystems.com` → the game's prod web bundle (Pages/Worker over R2).
- `api.games.andusystems.com` → the save API via **Cloudflare Tunnel**.
- DNS managed by the estate Cloudflare account; token needs **Zone:DNS:Edit** + **R2** + **Tunnel**
  scopes (least-privilege, account-scoped — verify via `/accounts/<id>/tokens/verify`, the
  pterodactyl gotcha).

## R2 (object storage — zero egress)
- **`andusystems-games-bundles`** — static game builds. Prefixes:
  `prod/<slug>/…` (public, served via Pages/Worker) and `uat/<slug>/…` (served by the in-cluster
  UAT static host, **not** public).
- **`andusystems-games-backups`** — CNPG WAL + base backups (private).
- **`andusystems-spriteforge`** — generated assets, sprite sheets, rigs (private; SpriteForge repo).
- R2 credentials (S3-compatible access key/secret) as sealed secrets; CNPG barman + the CI publish
  jobs use scoped keys.

## Serving prod bundles
Two clean options — pick in Phase 1:
- **Cloudflare Pages** project bound to R2 per game (simple, per-game custom domain), **or**
- a single **Worker** that maps `<slug>.games…` → `bundles/prod/<slug>/…` in R2 (one deploy serves
  all games; adding a game is just a new prefix + DNS record — preferred for "many games").
Immutable, content-hashed assets; long cache TTLs; SPA fallback to `index.html`.

## Cloudflare Tunnel (the prod API)
- `cloudflared` runs **in-cluster** (`apps/cloudflared`, ns `edge`), dialing out — **no inbound
  ports, no exposed MetalLB VIP**. Publishes `api.games.andusystems.com` → Traefik →
  `save-api.save-api.svc`.
- Tunnel token as a sealed secret. Only the **prod** API is tunneled; UAT API is Pangolin.

## WAF, rate-limit, DDoS (public API + web)
- Rate-limit rules on `api.games.andusystems.com`: tighter on `POST /v1/players` and write paths
  (anonymous abuse surface — see `identity.md`).
- Managed WAF ruleset + bot-fight; optional **Turnstile** on player registration if abused.
- Cache game bundles aggressively; **never** cache API responses.

## What is NOT on Cloudflare
UAT web, UAT API, and SpriteForge are **private** and reached via **Pangolin/Newt**, not Cloudflare
(`environments.md`). Keep the two planes separate — don't put a public CF route in front of a
private resource.
