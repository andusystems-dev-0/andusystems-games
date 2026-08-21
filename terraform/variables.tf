# --- Proxmox connection (placeholders in terraform.tfvars.example; real values via GH secrets) ---
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://10.238.0.101:8006/"
}

variable "proxmox_api_token" {
  type        = string
  description = "Proxmox API token (terraform@pam!terraform=<uuid>). From PROXMOX_API_TOKEN secret."
  sensitive   = true
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_ssh_username" {
  type    = string
  default = "root"
}

variable "proxmox_ssh_key_path" {
  type        = string
  description = "Private key the bpg provider uses for Proxmox host-side ops. deploy.yml provisions it here."
  default     = "/root/.ssh/andusystems-proxmox"
}

# --- Ubuntu cloud image (downloaded to each host's `local` store, booted from — estate pattern) ---
variable "vm_cloud_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "vm_cloud_image_content_type" {
  type    = string
  default = "iso"
}

variable "vm_download_datastore_id" {
  type    = string
  default = "local"
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

# --- Games cluster network: VLAN 70 (10.238.70.0/24) — verified free against the live VLAN map ---
variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "network_vlan_id" {
  type    = number
  default = 70
}

variable "network_gateway" {
  type    = string
  default = "10.238.70.1"
}

variable "network_prefix" {
  type    = number
  default = 24
}

variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "1.0.0.1"]
}

variable "ci_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "SSH public keys for the ci_user (from SSH_PUBKEY secret)."
  default     = ["ssh-ed25519 AAAA_PLACEHOLDER_REPLACE_ME games-cluster"]
}

# --- Nodes: 3 HA k3s servers on VLAN 70, spread across separate Proxmox hosts for host-failure HA.
# Games compute is tiny (2c/6G). Placement mirrors the estate's worker0/2/3 (all exist, have headroom);
# adjust proxmox_host per your live capacity. vm_ids 704x encode the VLAN. ---
variable "nodes" {
  type = map(object({
    proxmox_host = string
    ip           = string
    vm_id        = number
    cpu_cores    = number
    memory_mb    = number
    disk_gb      = number
  }))
  default = {
    games-1 = { proxmox_host = "worker0", ip = "10.238.70.41", vm_id = 7041, cpu_cores = 2, memory_mb = 6144, disk_gb = 60 }
    games-2 = { proxmox_host = "worker2", ip = "10.238.70.42", vm_id = 7042, cpu_cores = 2, memory_mb = 6144, disk_gb = 60 }
    games-3 = { proxmox_host = "worker3", ip = "10.238.70.43", vm_id = 7043, cpu_cores = 2, memory_mb = 6144, disk_gb = 60 }
  }
}
