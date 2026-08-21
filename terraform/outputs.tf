output "node_ips" {
  description = "Games cluster node IPs on VLAN 70."
  value       = { for name, cfg in local.nodes : name => cfg.ip }
}

output "metallb_pool" {
  value = "10.238.70.50-10.238.70.69"
}

output "traefik_vip" {
  description = "Traefik LoadBalancer VIP (Pangolin resources target this)."
  value       = "10.238.70.50"
}
