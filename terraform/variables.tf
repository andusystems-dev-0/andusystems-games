# --- Proxmox connection (placeholders in terraform.tfvars.example; real values via GH secrets) ---
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://proxmox.example:8006/"
}

variable "proxmox_api_token" {
  type        = string
  description = "Proxmox API token (id=secret). Placeholder locally; real value from PROXMOX_API_TOKEN secret."
  sensitive   = true
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox host to place the games VMs on (CONFIRM the target host)."
  default     = "worker3"
}

variable "template_vm_id" {
  type        = number
  description = "VMID of the Ubuntu 24.04 cloud-init template to clone (CONFIRM)."
  default     = 9000
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

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "ci_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "SSH public keys for the ci_user."
  default     = ["ssh-ed25519 AAAA_PLACEHOLDER_REPLACE_ME games-cluster"]
}

# --- Node sizing (games compute is tiny; sized for HA control plane + the save-api/spriteforge) ---
variable "cpu_cores" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 6144
}

variable "disk_gb" {
  type    = number
  default = 60
}
