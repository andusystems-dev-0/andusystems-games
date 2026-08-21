# All real values come from env/tfvars (placeholders in terraform.tfvars.example). Never commit secrets.
# The bpg provider SSHes to the Proxmox host (root) for image download/disk ops — same key that
# ansible uses for the VMs (PROXMOX_SSH_KEY / SSH_PUBKEY). Provisioned to the key path by deploy.yml.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent       = false
    username    = var.proxmox_ssh_username
    private_key = file(var.proxmox_ssh_key_path)
  }
}
