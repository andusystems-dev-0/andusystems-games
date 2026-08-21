# Games k3s cluster — 3 HA nodes on Proxmox VLAN 70 (10.238.70.0/24).
# Node IPs .41-.43; MetalLB pool .50-.69 (Traefik VIP .50) is configured by Ansible, not here.
# Applied by the GHA pipeline on a self-hosted runner (.github/workflows/{deploy,redeploy}.yml).

locals {
  nodes = {
    "games-1" = { ip = "10.238.70.41" }
    "games-2" = { ip = "10.238.70.42" }
    "games-3" = { ip = "10.238.70.43" }
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name      = each.key
  node_name = var.proxmox_node
  tags      = ["games", "k3s"]

  clone {
    vm_id = var.template_vm_id
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
    # floating == dedicated disables ballooning so the OS always sees full RAM (estate convention)
    floating = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_gb
    file_format  = "raw"
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.network_vlan_id
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.ci_user
      keys     = var.ssh_public_keys
    }
  }
}

# Emit the Ansible inventory so the k3s playbook can pick it up (-i inventory/games).
resource "local_file" "inventory" {
  filename = "${path.module}/../ansible/inventory/games/hosts.yml"
  content = yamlencode({
    all = {
      vars = {
        ansible_user                 = var.ci_user
        ansible_ssh_private_key_file = "~/.ssh/andusystems-proxmox"
        metallb_address_pool         = "10.238.70.50-10.238.70.69"
        traefik_vip                  = "10.238.70.50"
      }
      children = {
        k3s_servers = {
          hosts = { for name, cfg in local.nodes : name => { ansible_host = cfg.ip } }
        }
      }
    }
  })
}
