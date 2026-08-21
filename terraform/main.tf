# Games k3s cluster — 3 HA server nodes on Proxmox VLAN 70 (10.238.70.0/24).
# Mirrors the estate pattern (andusystems-platform k3s-node): download the Ubuntu 24.04 cloud image
# to each host's `local` store, boot each VM from it via cloud-init. MetalLB pool .50-.69 (Traefik
# VIP .50) is configured by Ansible. Applied by the GHA pipeline on a self-hosted runner.

# Download the cloud image once per Proxmox host that will run a node.
resource "proxmox_virtual_environment_file" "ubuntu_image" {
  for_each     = toset([for n in var.nodes : n.proxmox_host])
  content_type = var.vm_cloud_image_content_type
  datastore_id = var.vm_download_datastore_id
  node_name    = each.key

  source_file {
    path = var.vm_cloud_image_url
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name        = each.key
  vm_id       = each.value.vm_id
  node_name   = each.value.proxmox_host
  description = "k3s server for games (VLAN 70)"
  tags        = ["k3s", "games", "server", "terraform"]

  agent { enabled = true }
  stop_on_destroy = true

  cpu {
    cores = each.value.cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
    floating  = each.value.memory_mb # floating == dedicated → no ballooning (estate convention)
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = proxmox_virtual_environment_file.ubuntu_image[each.value.proxmox_host].id
    interface    = "scsi0"
    size         = each.value.disk_gb
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge  = var.network_bridge
    vlan_id = var.network_vlan_id
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.datastore_id

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = var.ci_user
      keys     = var.ssh_public_keys
    }
  }
}

# Emit the Ansible inventory the k3s playbook consumes (-i inventory/games).
resource "local_file" "inventory" {
  filename        = "${path.module}/../ansible/inventory/games/hosts.yml"
  file_permission = "0644"

  content = yamlencode({
    all = {
      vars = {
        ansible_user                 = var.ci_user
        ansible_ssh_private_key_file = "~/.ssh/andusystems-proxmox"
        ansible_ssh_common_args      = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        metallb_address_pool         = "10.238.70.50-10.238.70.69"
        traefik_vip                  = "10.238.70.50"
      }
      children = {
        k3s_servers = {
          hosts = { for name, cfg in var.nodes : name => { ansible_host = cfg.ip } }
        }
      }
    }
  })

  depends_on = [proxmox_virtual_environment_vm.node]
}
