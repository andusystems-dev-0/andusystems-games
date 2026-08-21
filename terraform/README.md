# terraform/ — cluster VMs

Provisions the 3 games k3s VMs on Proxmox (`bpg/proxmox`), VLAN **70** (verified free). VMs only —
everything above the OS is Ansible + ArgoCD. Applied by `.github/workflows/deploy.yml` on a
self-hosted runner, **not** locally. State in S3 (`andusystems-tfstate`, key
`games/layer-1-cluster`).

```
versions.tf              # provider pins (bpg/proxmox, hashicorp/local)
provider.tf              # proxmox connection (endpoint/token via vars)
backend.tf               # S3 state
variables.tf             # all inputs; VLAN 70 defaults baked in
main.tf                  # 3 VMs (games-1/2/3 → .41/.42/.43) + writes the ansible inventory
outputs.tf               # node_ips, metallb_pool, traefik_vip
terraform.tfvars.example # PLACEHOLDERS — fill Proxmox creds/host/template, then copy to terraform.tfvars
```

- Nodes `10.238.70.41-.43`; MetalLB pool `.50-.69` + Traefik VIP `.50` are set by Ansible, not here.
- `main.tf` emits `../ansible/inventory/games/hosts.yml` so the k3s playbook picks it up.
- Validated: `terraform init -backend=false && terraform validate` (passes against the bpg/proxmox schema).
- **CONFIRM before apply:** `proxmox_node` (target host) and `template_vm_id` (Ubuntu 24.04 cloud-init template).
