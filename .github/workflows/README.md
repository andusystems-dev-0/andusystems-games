# .github/workflows/ — CI/CD

Runs on the estate's **self-hosted** runners (`[self-hosted, linux, andusystems-mgmt]`); iOS needs a
macOS runner (`vars.IOS_RUNNER`, CONFIRM). GitHub is the **user account `andusystems-dev-0`** (not an
org), so runners are **repo-scoped** — register runners on this repo like pterodactyl did.

| Workflow | Trigger | What |
|---|---|---|
| `deploy.yml` | manual | Terraform apply (VLAN-70 VMs) → Ansible k3s+MetalLB → register the ArgoCD spoke. Safe (keeps VMs). |
| `redeploy.yml` | manual, `DESTROY`-gated | Terraform destroy+recreate → converge → ArgoCD reconciles; CNPG restores from R2. |
| `new-game.yml` | manual (`slug`) | Create the game repo from the template + open the registry PR. Near-zero manual steps. |
| **`mobile-package.yml`** | `workflow_call` | **reusable** — package a game's web bundle into the Capacitor shell + Fastlane to the stores. Called by public `andusystems-game-<slug>` repos. |

All secrets are **placeholders** set as repo secrets and filled later (Proxmox, AWS TF-state, mgmt
kubeconfig, signing keys). None are committed. `mobile-package.yml` pulls signing secrets from the
caller at call time (`secrets: inherit`).
