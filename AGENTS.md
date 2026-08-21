# AGENTS.md — andusystems-games

GitOps + IaC for the **games cluster** and the design hub for the whole games estate. You are
an automation agent on Alex's **devbox** (network access to Proxmox, both k3s clusters, MinIO, Cloudflare,
AWS, Pangolin). Read `STATE.md` then `ROADMAP.md` before doing anything.

## What this is
A dedicated k3s cluster that runs **one multi-tenant save-state API for all games** (prod + a
private UAT copy), the private **SpriteForge** asset studio, and nothing per-game. Games
themselves are static **Phaser** bundles wrapped with **Capacitor** for the app stores; their web
prod builds live on **Cloudflare** and never run in the cluster. The cluster is a **spoke** of the
mgmt cluster's ArgoCD and ships metrics to the mgmt Grafana/LGTM.

## Non-negotiable rules
1. **This repo is PUBLIC.** Never commit secrets, tokens, real internal IPs beyond the VLAN plan,
   or private hostnames-with-creds. Secrets go through **sealed-secrets** (encrypted values may be
   committed) + git-ignored `.env.local` + GitHub Actions secrets (`scripts/sync-gh-secrets.sh`).
   Model the `.env.local` flow on `andusystems-pterodactyl`.
2. **The JWT signing keys MUST stay stable across redeploys** (prod and UAT have separate keys) —
   like `PTERO_APP_KEY`. A rotated key invalidates every player's token. Seed them once, keep them.
3. **Durability is in R2, not on disk.** CNPG streams WAL + base backups to Cloudflare R2. A
   cluster rebuild restores Postgres from R2. TF state stays in S3 (`andusystems-tfstate`,
   `games/…`).
4. **Adding a game adds NO cluster workload.** All games share the prod save-api, the UAT save-api,
   and the shared UAT static host. A new game = a template clone + a registry entry + a CDN/store
   publish. If you ever feel the urge to deploy per-game server code, extend the shared API instead.
5. **Two identities of exposure, do not cross them.** Public/prod is Cloudflare (R2/Pages +
   Cloudflare **Tunnel** for the API) — no open ports, no exposed MetalLB VIP. Private/UAT +
   SpriteForge are **Pangolin** resources (co-located Newt), IP-allow-listed. See `docs/cloudflare.md`
   and `docs/environments.md`.
6. **GitOps-first.** ArgoCD (the mgmt hub) reconciles `apps/*` from
   `github.com/andusystems-dev-0/andusystems-games`. Don't `kubectl apply` by hand except the
   documented bootstrap. Kyverno policies apply estate-wide: runAsNonRoot + drop-ALL caps.

## Conventions (inherited)
Terraform (`bpg/proxmox`) = VMs only; Ansible = k3s + post-boot; ArgoCD = apps; Kustomize base +
per-env overlays; Traefik IngressRoute CRDs; cert-manager DNS-01 (Cloudflare) for any internal
TLS. Go for services, SvelteKit+Skeleton for UIs, TypeScript for the SDK + games. Naming:
`andusystems-*` repos, `andusystems-game-<slug>` per game, bundle id `com.andusystems.games.<slug>`.

## Entrypoints (Makefile — build them in Phase 0/1)
`make cluster` (TF+ansible), `make register-spoke` (add to mgmt ArgoCD), `make bootstrap-secrets`,
`make backup` / `make restore` (CNPG ↔ R2), `make redeploy` (destroy+recreate+restore, `CONFIRM=DESTROY`).

## Markers
The games VLAN is resolved: **VLAN 70** (`10.238.70.0/24`), verified free against the live map;
nodes `.41-.43`, MetalLB `.50-.69`. Remaining `CONFIRM` markers (e.g. the Proxmox target host +
Ubuntu template VMID, macOS runner availability) must be resolved against the real network/accounts
before applying — same discipline as `andusystems-shipyard`. Provisioning runs via the **GHA
pipeline on self-hosted runners** (`deploy.yml`/`redeploy.yml`), not local applies. GitHub is the
**user account `andusystems-dev-0`** (not an org) — self-hosted runners are **repo-scoped** (pterodactyl gotcha).
