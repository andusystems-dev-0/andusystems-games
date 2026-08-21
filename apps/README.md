# apps/ — ArgoCD Applications (reconciled by the mgmt hub)

Each dir is one Application in the `games` AppProject, reconciled from this repo by the **mgmt
cluster's ArgoCD**. Kustomize base + overlays; Kyverno enforce (runAsNonRoot, drop-ALL).

| App | What |
|---|---|
| `argocd/` | the `games` AppProject + app-of-apps root (spoke registration lives in mgmt) |
| `cnpg/` | CloudNativePG operator + `games-db` (prod) & `games-db-uat`, barman backups → R2 |
| `save-api/` | prod save+payments API; `games-registry.yaml` + `products.yaml` configmaps |
| `save-api-uat/` | UAT copy of the API (separate DB, test Stripe keys, Pangolin-exposed) |
| `web-uat/` | shared static host serving R2 `uat/<slug>/` (all games' UAT web) |
| `cloudflared/` | Cloudflare **Tunnel** → prod API (`api.games…`), public |
| `edge/newt/` | co-located **Newt** connector for the Pangolin private resources |
| `spriteforge/` | the asset studio (images from `andusystems-spriteforge`), Pangolin-only |
| `monitoring/` | grafana-agent → remote_write to mgmt LGTM; ServiceMonitors |

**Adding a game does not add an app here** — games share `save-api`, `web-uat`, and the mobile
shell. New app dirs are for new *platform* capabilities only.
