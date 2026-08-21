# Repo map

Six repo kinds. The axis that grows with game count is **public game repos** (cheap, identical
CI); everything else is fixed.

| Repo | Vis | Contains | CI produces |
|---|---|---|---|
| **andusystems-games** (this) | public | cluster IaC + GitOps (`apps/`), the estate docs, the mobile shell + reusable packaging workflow | cluster reconcile; reusable `mobile-package.yml` |
| **andusystems-games-save-api** | private | the multi-tenant save + payments service (Go), migrations | container image → deployed via `apps/save-api` |
| **andusystems-games-sdk** | public | TypeScript client (`AnduGames`) | npm package |
| **andusystems-games-template** | private | Phaser+Vite starter, `game.json`, env config, SDK dep | the GitHub *template* source |
| **andusystems-spriteforge** | private | AI asset+animation studio (SvelteKit + Go) | 2 images → `apps/spriteforge` |
| **andusystems-game-\<slug\>** | public | one game's web source only | web bundle → R2; calls `mobile-package.yml` |

¹ **D-010 accepted** — the SDK repo + package are **public** (thin client, no secrets), so public
game repos `npm install @andusystems/games-sdk` with no tokens. Server + template stay private.

## Why this split
- **One public hub** (`andusystems-games`) holds the cluster config, the docs, and the shared
  mobile shell/workflow — public so public game repos can call the workflow freely.
- **Private product code** (save-api, spriteforge, template) stays closed; none of it carries
  secrets in-repo (sealed-secrets + `.env.local`).
- **Public game repos** are pure web clients; the only thing they consume externally is the SDK
  package and the public packaging workflow.

## GitHub
Org `andusystems-dev-0`. Self-hosted runners on the mgmt runner VM (`10.238.10.30`); Android builds
run there, iOS needs a macOS runner (CONFIRM — `mobile-release.md`). Bundle ids
`com.andusystems.games.<slug>`.

## Secrets discipline (because the hub is public)
Never commit secrets/tokens/real internal creds. Encrypted **sealed-secrets** may be committed;
plaintext lives in git-ignored `.env.local` + GitHub Actions secrets (`scripts/sync-gh-secrets.sh`).
The signing keys (JWT prod/uat) and Stripe keys are seeded once and kept stable. Full list in
`runbook.md`.
