output "control_plane_vip" {
  description = "Cluster API server endpoint. Use this to build a kubeconfig."
  value       = var.control_plane_vip
}

output "control_plane_ips" {
  value = var.control_plane_ip_addresses
}

output "worker_ips" {
  value = slice(var.worker_ip_addresses, 0, var.worker_count)
}

output "kubeconfig_fetch_command" {
  description = "Run this after apply to pull a working kubeconfig from the primary control-plane node."
  value       = "ssh ubuntu@${var.control_plane_ip_addresses[0]} sudo cat /etc/rancher/rke2/rke2.yaml | sed 's/127.0.0.1/${var.control_plane_vip}/' > kubeconfig.yaml"
}
