# -----------------------------------------------------------------------------
# vSphere connection
# -----------------------------------------------------------------------------

variable "vsphere_user" {
  description = "vSphere username. Defaults to the VSPHERE_USER env var if unset."
  type        = string
  default     = null
}

variable "vsphere_password" {
  description = "vSphere password. Defaults to the VSPHERE_PASSWORD env var if unset."
  type        = string
  default     = null
  sensitive   = true
}

variable "vsphere_server" {
  description = "vCenter server FQDN or IP. Defaults to the VSPHERE_SERVER env var if unset."
  type        = string
  default     = null
}

variable "vsphere_allow_unverified_ssl" {
  description = "Allow self-signed vCenter certificates."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# vSphere inventory
# -----------------------------------------------------------------------------

variable "vsphere_datacenter" {
  description = "Name of the vSphere datacenter to deploy into."
  type        = string
}

variable "vsphere_cluster" {
  description = "Name of the vSphere compute cluster (host cluster) to deploy into."
  type        = string
}

variable "vsphere_datastore" {
  description = "Name of the datastore to place VM disks on."
  type        = string
}

variable "vsphere_datastore_url" {
  description = <<-EOT
    The datastore's ds:/// URL (not its display name), used by the vSphere CSI
    StorageClass to target volume placement. Not exposed by the vsphere_datastore
    data source -- find it via the datastore's summary.url property, e.g. with
    a short pyvmomi/govc script against the same vCenter, or "Configuration >
    Path" in the vSphere client.
  EOT
  type        = string
}

variable "vsphere_network" {
  description = "Name of the portgroup / network the VMs will attach to."
  type        = string
}

variable "vsphere_folder" {
  description = "Optional VM folder path (relative to the datacenter's VM folder) to place cluster VMs in."
  type        = string
  default     = ""
}

variable "template_name" {
  description = <<-EOT
    Name of the source VM template to clone. Must already exist in vSphere with
    cloud-init installed and the VMware GuestInfo datasource enabled (default on
    Ubuntu 22.04+ cloud images). See CLAUDE.md for how to build one with Packer.
  EOT
  type        = string
}

# -----------------------------------------------------------------------------
# Node sizing
# -----------------------------------------------------------------------------

variable "control_plane_cpu" {
  type    = number
  default = 4
}

variable "control_plane_memory_mb" {
  type    = number
  default = 8192
}

variable "control_plane_disk_gb" {
  type    = number
  default = 80
}

variable "worker_cpu" {
  type    = number
  default = 4
}

variable "worker_memory_mb" {
  type    = number
  default = 16384
}

variable "worker_disk_gb" {
  type    = number
  default = 100
}

# -----------------------------------------------------------------------------
# Cluster topology
# -----------------------------------------------------------------------------

variable "cluster_name" {
  description = "Short name used as a hostname/VM-name prefix, e.g. \"rke2-lab\"."
  type        = string
  default     = "rke2"
}

variable "worker_count" {
  description = "Number of worker nodes to create."
  type        = number
  default     = 2
}

variable "control_plane_ip_addresses" {
  description = "Static IPs for the 3 control-plane nodes, in order."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_ip_addresses) == 3
    error_message = "This topology is fixed at 3 control-plane nodes; provide exactly 3 IPs."
  }
}

variable "worker_ip_addresses" {
  description = "Static IPs for worker nodes, in order. Must have at least worker_count entries."
  type        = list(string)
}

variable "control_plane_vip" {
  description = "Virtual IP (kube-vip, ARP mode) used as the stable control-plane / API server endpoint."
  type        = string
}

variable "network_prefix_length" {
  description = "CIDR prefix length shared by all node static IPs (e.g. 24)."
  type        = number
}

variable "network_gateway" {
  type = string
}

variable "network_dns_servers" {
  type    = list(string)
  default = ["8.8.8.8", "8.8.4.4"]
}

variable "network_interface_name" {
  description = "Guest OS network interface name used in the cloud-init network config. Verify this against the template (commonly ens192 for VMXNET3 on Linux)."
  type        = string
  default     = "ens192"
}

variable "vm_domain" {
  type    = string
  default = "local"
}

# -----------------------------------------------------------------------------
# RKE2 / access
# -----------------------------------------------------------------------------

variable "rke2_version" {
  description = "RKE2 channel/version passed to the install script, e.g. v1.30.4+rke2r1."
  type        = string
  default     = "v1.30.4+rke2r1"
}

variable "rke2_token" {
  description = "Pre-shared cluster token used by all nodes to join. Generate with e.g. `openssl rand -hex 32`."
  type        = string
  sensitive   = true
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule for RKE2's built-in etcd snapshotting. Snapshots land on each control-plane node's local disk (/var/lib/rancher/rke2/server/db/snapshots) -- this alone is not off-node backup/DR, just protection against a bad write/upgrade."
  type        = string
  default     = "0 */6 * * *"
}

variable "etcd_snapshot_retention" {
  description = "How many local etcd snapshots to retain per control-plane node."
  type        = number
  default     = 10
}

variable "vsphere_csi_driver_version" {
  description = "kubernetes-sigs/vsphere-csi-driver release tag to install."
  type        = string
  default     = "v3.7.2"
}

# -----------------------------------------------------------------------------
# In-cluster image registry
# -----------------------------------------------------------------------------

variable "registry_node_port" {
  description = "NodePort the in-cluster registry:2 Service listens on. Reachable at control_plane_vip:this-port, since the VIP's node always runs kube-proxy too."
  type        = number
  default     = 30500
}

variable "registry_storage_size" {
  description = "Size of the PVC (on the vsphere-csi StorageClass) backing the registry's image storage."
  type        = string
  default     = "50Gi"
}

variable "registry_username" {
  description = "Basic auth username for the in-cluster registry. Required on both the registry side (htpasswd) and the node side (registries.yaml), so every node can actually pull from it."
  type        = string
  default     = "admin"
}

variable "registry_password" {
  description = "Basic auth password for the in-cluster registry. Generate with e.g. `openssl rand -hex 20`."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# MetalLB (LoadBalancer Services)
# -----------------------------------------------------------------------------

variable "metallb_version" {
  description = "metallb/metallb release tag to install."
  type        = string
  default     = "v0.16.0"
}

variable "metallb_ip_range" {
  description = "IP range MetalLB hands out for type: LoadBalancer Services, e.g. \"192.168.100.20-192.168.100.29\". Must not overlap the cluster's own static IPs/VIP, and should be excluded from the network's DHCP pool."
  type        = string
}

variable "ssh_public_key" {
  description = "Public key installed on the default \"ubuntu\" user of every node."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the matching private key, used by the provisioner that waits for the first control-plane node to bootstrap."
  type        = string
  default     = "~/.ssh/id_rsa"
}
