output "node_ips" {
  description = "Games cluster node IPs on VLAN 70."
  value       = { for name, cfg in var.nodes : name => cfg.ip }
}

output "node_placement" {
  description = "Which Proxmox host runs each node."
  value       = { for name, cfg in var.nodes : name => cfg.proxmox_host }
}

output "metallb_pool" {
  value = "10.238.70.50-10.238.70.69"
}

output "traefik_vip" {
  description = "Traefik LoadBalancer VIP (Cloudflare Tunnel + Pangolin resources target this)."
  value       = "10.238.70.50"
}

output "first_server_ip" {
  description = "Bootstrap server (kubeconfig + ArgoCD spoke registration point)."
  value       = var.nodes["games-1"].ip
}
