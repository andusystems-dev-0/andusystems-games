# Architecture — andusystems games estate

How the pieces fit. Read `../README.md` for the one-paragraph version and `decisions.md` for *why*
each choice was made.

## The big picture

```
                    ┌─────────────────────── Cloudflare (edge) ───────────────────────┐
  players (public)  │  <slug>.games.andusystems.com  → Pages/Worker → R2 bundles/prod  │
        │           │  api.games.andusystems.com     → Cloudflare Tunnel ──────────┐   │
        │           └──────────────────────────────────────────────────────────────┼───┘
        ▼                                                                           ▼
  App/Play stores ← thin Capacitor shell (same web bundle, offline)         ┌──────────────┐
                                                                            │ games k3s    │
  the operator (private) ── Pangolin/Newt ──► uat.<slug>… / uat-api… / spriteforge… │  VLAN 70     │
                                                                            │  (spoke)     │
                                                                            └──────┬───────┘
  mgmt cluster (VLAN 10): ArgoCD hub  ─── reconciles apps/ ───►                    │
                          Grafana/LGTM ◄── remote_write metrics ──────────────────┘
```

- **Games are static.** A Phaser game is one web bundle. It renders in a browser (prod on
  Cloudflare, UAT behind Pangolin) and, unchanged, inside a thin Capacitor shell for the stores.
  No game logic runs in the cluster.
- **The only server compute** is the save-state API (one shared service, prod + UAT copies) and
  the SpriteForge studio. Everything else is edge + storage.

## Cluster

- **k3s HA, 3 nodes** on Proxmox, **games VLAN 70** `10.238.70.0/24` — **verified free** against the
  live map (taken: 10 mgmt, 20 apps, 30 pihole, 40 storage, 50 monitoring, 60 fleetdock, 80/90
  hireship). Nodes `.41–.43`, MetalLB pool `.50–.69`, Traefik VIP `10.238.70.50`. Provisioned by
  `terraform/` (`bpg/proxmox`) + `ansible/` (k3s), modeled on `andusystems-platform`.
- **Spoke, not a hub.** The cluster runs **no ArgoCD of its own**. The **mgmt cluster's ArgoCD**
  registers it as a managed cluster and reconciles `apps/*` from this repo. This is the
  hub-and-spoke the operator asked for: manage + monitor games from the platform cluster.
- **Namespaces:** `save-api` (prod API + `games-db`), `save-api-uat` (UAT API + `games-db-uat`),
  `web-uat` (shared UAT static host), `edge` (cloudflared Tunnel + Newt connector), `spriteforge`,
  `monitoring` (grafana-agent), `sealed-secrets`, `cert-manager`, `cnpg-system`.

## Data flow: a save

1. Game calls the **SDK**; the SDK writes to **device storage first** (web: IndexedDB; native:
   Capacitor Preferences/Filesystem) — the device is the source of truth.
2. On a **debounced timer** and on **pause / visibilitychange / pagehide / crash-handler**, the SDK
   flushes to the API: `PUT /v1/games/{game_id}/saves/{slot}` with a bearer token.
3. The API validates the token (anonymous device identity, upgradeable), enforces the game's
   `save_mode` (LWW / LWW+history / slots) and size caps, and upserts into **CNPG Postgres**
   (`saves`, plus `save_history` when versioning is on). Large blobs above a threshold spill to R2.
4. On next launch the SDK reconciles device state with `GET …/saves/{slot}` (last-write-wins by
   version, or the game's conflict hook).

See `data-model.md`, `api-spec.md`, `save-model.md`, `identity.md`.

## Two planes of exposure (never crossed)

| Plane | Who | How | What |
|---|---|---|---|
| **Public / prod** | anyone | **Cloudflare** — R2/Pages for bundles, **Cloudflare Tunnel** for the API | `<slug>.games…`, `api.games…` |
| **Private / UAT + tools** | the operator (IP-allow-listed) | **Pangolin** resources via a co-located **Newt** connector | `uat.<slug>.games…`, `uat-api.games…`, `spriteforge…` |

The Tunnel and Newt both dial **out** — no inbound ports, and the MetalLB VIP is never exposed
publicly (this sidesteps the devbox-can't-reach-VIP issue noted estate-wide). Internal routing is
Traefik IngressRoute CRDs; internal TLS via cert-manager DNS-01 (Cloudflare) where needed.

## Environments

Each game has **UAT** (private, Pangolin) and **prod** (public, Cloudflare). They are fully
isolated: separate API deployment, separate CNPG database, separate JWT signing key, separate R2
prefix, separate store track (TestFlight/Play-internal vs production). One web build flows to both.
Details in `environments.md`.

## Storage & durability

- **Postgres:** CloudNativePG. `games-db` (prod) and `games-db-uat`, each streaming WAL + base
  backups to **R2** via barman-cloud. A cluster rebuild restores from R2 (the pterodactyl
  durability-in-object-store contract).
- **Bundles + assets:** R2 (`andusystems-games-bundles`, prefixes `prod/<slug>/`, `uat/<slug>/`;
  SpriteForge under its own bucket/prefix).
- **TF state:** S3 `andusystems-tfstate`, key `games/layer-*` (kept in AWS per estate convention).

## Observability

grafana-agent on the games cluster remote-writes node/kube + app metrics (save-api ServiceMonitor,
CNPG, cloudflared) to the **mgmt LGTM** (`andusystems-monitoring`). Dashboards + alerts live in the
mgmt Grafana — one pane of glass. Save error-rate/latency, DB health, and **backup age** are the
key alerts.

## SpriteForge (summary — full docs in its repo)

A private SvelteKit studio + Go backend on this cluster (ns `spriteforge`, Pangolin-only) that
generates 2D assets and, from one asset, many animations. Heavy inference goes to a cloud gateway
(fal.ai primary / Replicate fallback); no GPU runs here. Outputs Phaser-ready sprite sheets and
Spine/DragonBones rigs to R2. It depends only on the cluster + edge + CNPG + R2 (Phase 0/1), not on
the save API. See `andusystems-spriteforge/`.

## Payments (summary — full docs in `payments.md`)

A games-owned Stripe integration (own account/keys, Hireship conventions) lives in the save-api.
Purchases happen **on the web** (Stripe Checkout); a webhook grants an **entitlement** on the
player's **account**; every surface — web and the app — reads entitlements to gate content. The
mobile app never processes payment for digital goods (App Store 3.1.1 / Play Billing), it only
reads entitlements. UAT uses Stripe test keys, prod uses live keys.

## Security baseline

Kyverno enforce (runAsNonRoot, drop-ALL caps) estate-wide; WAF + rate-limits on the public API;
Pangolin IP-allow-lists on every private resource; sealed-secrets only (this repo is public);
stable JWT signing keys; least-privilege Cloudflare/R2 tokens.
