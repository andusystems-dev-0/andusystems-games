# andusystems-games

GitOps + IaC for the **andusystems games estate**: a dedicated k3s cluster that runs one
**multi-tenant save-state API** for *all* mobile/web games (Phaser), plus the private
**SpriteForge** asset studio — managed and monitored from the existing platform-mgmt cluster.

> **This repo is PUBLIC.** No plaintext secrets ever land here — see
> [`docs/decisions.md#secrets`](docs/decisions.md) and the sealed-secrets flow. It is also the
> canonical home for the whole estate's design docs, even though `save-api`, `sdk`, `template`,
> and `spriteforge` live in separate private repos.

## The shape in one paragraph

Games are **static Phaser bundles** on Cloudflare (R2 + Pages) — they never touch the cluster.
The only server compute is a tiny **save-state API**: a game syncs an opaque state blob on a
debounced timer and on close/crash, keyed by an **anonymous device identity** (upgradeable to a
real account later). The API is one Go service backed by **CloudNativePG Postgres**, exposed
publicly through a **Cloudflare Tunnel** (no open ports, no exposed MetalLB VIP). The cluster is
a **spoke** of the mgmt cluster's ArgoCD and remote-writes metrics to the mgmt Grafana/LGTM.
Adding game #N is a template clone + a registry entry + a CDN publish — **it never adds a
cluster workload.**

## Why a separate cluster (not a namespace)

Games are public, anonymous, internet-facing, and bursty; the SaaS estate is authenticated and
paying. A separate cluster gives a hard blast-radius/security boundary, independent lifecycle,
and clean cost attribution. Compute is trivial, so the cluster is small — the cost we pay is a
second control plane, and the mgmt ArgoCD hub makes that cheap to run. Full rationale:
[`docs/decisions.md`](docs/decisions.md).

## Repos in this estate

| Repo | Vis | What |
|---|---|---|
| **andusystems-games** (this) | public | Games cluster IaC + GitOps + the estate design docs |
| **andusystems-games-save-api** | private | The multi-tenant save-state service (Go) |
| **andusystems-games-sdk** | public | TypeScript client the games use to talk to the save API |
| **andusystems-games-template** | private | Phaser starter (GitHub template) — `gh repo create … --template` |
| **andusystems-spriteforge** | private | AI 2D asset + animation studio (deploys to this cluster) |
| **andusystems-game-\<slug\>** | public | One per game — static Phaser client, builds to R2 |

¹ The SDK is **public** (D-010) — thin client, no secrets — so public game repos install it with no
tokens. Full map: [`docs/repos.md`](docs/repos.md).

## Quickstart (once implemented — see ROADMAP)

```bash
cp .env.example .env.local          # Proxmox + Cloudflare + JWT signing key (git-ignored)
make cluster                         # terraform VMs + ansible k3s (games VLAN)
make register-spoke                  # register this cluster with the mgmt ArgoCD hub
make bootstrap-secrets               # seal + seed the bootstrap secrets
# ArgoCD then reconciles apps/ (cnpg, save-api, cloudflared, monitoring, spriteforge)
```

## Docs — read in this order

- [`STATE.md`](STATE.md) — **start here if returning:** status, what exists, next action.
- [`ROADMAP.md`](ROADMAP.md) — the phased build plan with checkboxes. This drives the work.
- [`docs/architecture.md`](docs/architecture.md) — cluster, network, data flow, monitoring, edge.
- [`docs/decisions.md`](docs/decisions.md) — every design decision + tradeoff (ADR log).
- [`docs/save-model.md`](docs/save-model.md) — the three save shapes + per-game registry config.
- [`docs/data-model.md`](docs/data-model.md) — the Postgres schema.
- [`docs/api-spec.md`](docs/api-spec.md) — the save API contract (endpoints + auth flow).
- [`docs/identity.md`](docs/identity.md) — anonymous-device → linked-account identity.
- [`docs/cloudflare.md`](docs/cloudflare.md) — R2, Pages, Tunnel, WAF, backups.
- [`docs/onboarding-a-game.md`](docs/onboarding-a-game.md) — how to add game #N.
- [`docs/repos.md`](docs/repos.md) — full repo map, visibility, and secret handling.
- [`docs/runbook.md`](docs/runbook.md) — operations: deploy, backup, restore, redeploy.

## Conventions (inherited from the estate)

Modeled on `andusystems-platform` / `andusystems-pterodactyl`: Terraform (`bpg/proxmox`) for
VMs, Ansible for k3s, ArgoCD for apps, sealed-secrets + git-ignored `.env.local` (never commit
secrets/IPs into source), Cloudflare for edge + DNS-01, CNPG for Postgres, Kyverno policies
(runAsNonRoot, drop-ALL caps). TF state in S3 (`andusystems-tfstate`, key `games/…`); app data,
bundles, and backups in **Cloudflare R2**.
