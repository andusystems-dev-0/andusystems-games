# Registry & CI policy — compliance audit

_Audited 2026-08-23 across the games estate: `andusystems-games`, `-save-api`, `-sdk`, `-template`,
`-spriteforge`, `-game-idlebartender`._

## The rules
1. **All CI/ops run on GitHub Actions self-hosted runners** (`[self-hosted, linux, andusystems-mgmt]`) —
   never GitHub-hosted (`ubuntu-latest`, public) and never Forgejo Actions.
2. **All container images come from the private Forgejo registry** (`forgejo.andusystems.com`).
3. **No public container registries or images anywhere** (no docker.io / ghcr.io / gcr.io / quay.io /
   registry.k8s.io, and no unqualified images, which default to docker.io).

## Rule 1 — CI runners
| Workflow | runs-on | Status |
|---|---|---|
| games: deploy / redeploy / ops / new-game / mobile-package(android) | `[self-hosted, linux, andusystems-mgmt]` | ✅ |
| template: ci.yml · idlebartender: ci.yml | `[self-hosted, linux, andusystems-mgmt]` | ✅ |
| **save-api: image.yml** | `ubuntu-latest` | ❌ fix → self-hosted |
| **spriteforge: image.yml** | `ubuntu-latest` | ❌ fix → self-hosted |
| mobile-package: ios job | `${{ vars.IOS_RUNNER }}` | ⚠ must be a **self-hosted** macOS runner (not a hosted one) |

## Rule 2/3 — public images (this table IS the mirror list)
Everything below must be mirrored into `forgejo.andusystems.com/andusystems/mirror/…` and repointed.

| Public image | Used by | Kind |
|---|---|---|
| `ghcr.io/andusystems-dev-0/{games-save-api,spriteforge}` | save-api/spriteforge `image.yml` (push target) | app (wrong registry — must push to Forgejo) |
| `golang:1.25`, `golang:1.24-bookworm` | save-api / spriteforge Dockerfiles | build base (docker.io) |
| `node:22-bookworm-slim` | spriteforge Dockerfile (UI) | build base (docker.io) |
| `gcr.io/distroless/static:nonroot` | save-api / spriteforge Dockerfiles | runtime base |
| `fosrl/newt:latest` | `apps/edge` | app runtime (docker.io) |
| `grafana/agent:v0.44.2` | `apps/monitoring` | app runtime (docker.io) |
| `nginxinc/nginx-unprivileged:stable` | `apps/web-uat` | app runtime (docker.io) |
| `ghcr.io/cloudnative-pg/postgresql:16-system-bookworm` | `apps/cnpg` + `apps/spriteforge` + operator default | DB operand |
| cnpg operator image | `cloudnative-pg` Helm chart | operator (chart default) |
| kyverno images (admission/background/cleanup/reports) | `kyverno` Helm chart | operator (chart default) |
| `docker.io/bitnamilegacy/kubectl:1.30.2` | kyverno chart cleanup hooks (override) | operator hook |
| cert-manager images (controller/webhook/cainjector) | `jetstack` Helm chart | operator (chart default) |
| sealed-secrets controller image | `bitnami` Helm chart | operator (chart default) |
| metallb controller + speaker | `ansible/k3s.yml` (metallb-native.yaml, quay.io) | cluster add-on |
| k3s bundled: traefik, coredns, metrics-server, local-path, klipper-lb | k3s install (ansible) | cluster (baked into k3s; needs `--system-default-registry` or air-gap images) |

Helm **chart sources** (`bitnami.github.io`, `cloudnative-pg.github.io`, `kyverno.github.io`,
`charts.jetstack.io`) are HTTP chart repos, not container registries — allowed — but each chart's
**operand images** (above) must be overridden to the Forgejo mirror via Helm values.

## Staged migration (chosen: full estate) — sequenced so nothing breaks
- **Stage 1 — mirror (non-breaking):** a GHA self-hosted `mirror-images.yml` that `crane copy`s the pinned
  set above into `forgejo.andusystems.com/andusystems/mirror/…`. Run + verify before any repoint.
- **Stage 2 — app images:** rewrite save-api/spriteforge `image.yml` → self-hosted runner, build + push
  to Forgejo (kill ghcr); repoint Dockerfile bases (golang/node/distroless) + `apps/{edge,monitoring,web-uat}`
  images to the Forgejo mirror.
- **Stage 3 — operators:** Helm values `image.registry`/`image.repository` overrides → Forgejo mirror for
  cnpg (operator + `POSTGRES_IMAGE_NAME`), kyverno, cert-manager, sealed-secrets; drop bitnamilegacy.
- **Stage 4 — cluster:** metallb from a Forgejo-hosted manifest; k3s `--system-default-registry=forgejo.andusystems.com`
  (or preload the k3s air-gap images) in `ansible/k3s.yml`; add containerd `registries.yaml` **mirror**
  entries so docker.io/ghcr.io/gcr.io/quay.io/registry.k8s.io all resolve through Forgejo (belt-and-suspenders).
- **Stage 5 — enforce:** (a) a CI lint step that greps the repo and **fails** on any public-registry string;
  (b) a Kyverno `ClusterPolicy` that **denies** any Pod whose image isn't `forgejo.andusystems.com/*`
  (start in Audit during the migration, flip to Enforce once Stage 1–4 land). This is what makes the rule
  self-enforcing going forward.

## Non-image note
The GHA workflows also `curl` binaries from public sources (get.opentofu.org, dl.k8s.io, awscli.amazonaws.com,
github releases). Those are **not container images** so they don't violate the image rule, but a strict
air-gap would vendor them too — tracked here, out of scope for the image migration.
