# All real values come from env/tfvars (placeholders in terraform.tfvars.example). Never commit secrets.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = false
    username = "root"
    # private key provided via PROXMOX_SSH_KEY on the runner (docs/runbook.md)
  }
}
