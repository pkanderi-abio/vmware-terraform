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

variable "vsphere_storage_policy_name" {
  description = <<-EOT
    Name of an existing VM Storage Policy to assign explicitly to every VM
    clone, rather than relying on the target datastore's own default policy
    designation. On a 2-host, single-fault-domain vSAN cluster (K8S-CL01,
    no witness appliance), the built-in "vSAN Default Storage Policy"
    requires FTT=1 (3 fault domains) and editing it in place to FTT=0/"No
    data redundancy" does not reliably take effect for new object creation.
    Default here is vSAN's own built-in policy meant for exactly this
    topology; change only if the target datastore/cluster is not this one.
  EOT
  type        = string
  default     = "Management Storage Policy - Single Node"
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

variable "kyverno_chart_version" {
  description = "kyverno/kyverno Helm chart version -- policy-as-code admission control (CISA/NSA guidance: 'Use admission control'). Confirm against https://kyverno.github.io/kyverno/ before changing."
  type        = string
  default     = "3.8.2"
}

variable "trivy_operator_chart_version" {
  description = "aquasecurity/trivy-operator Helm chart version -- continuous in-cluster image/config vulnerability scanning."
  type        = string
  default     = "0.35.0"
}

variable "falco_chart_version" {
  description = "falcosecurity/falco Helm chart version -- runtime (syscall-level) threat detection. Uses the modern eBPF driver (no kernel module build/load needed on kernel >= 5.8)."
  type        = string
  default     = "9.1.0"
}

variable "kubernetes_dashboard_chart_version" {
  description = "kubernetes-dashboard/kubernetes-dashboard Helm chart version -- web UI for cluster inspection/management. The project moved to kubernetes-retired/dashboard on GitHub; its own README still documents the old (now-404) kubernetes.github.io/dashboard/ repo URL, so main.tf points at the working kubernetes-retired.github.io/dashboard/ one instead. Re-check https://github.com/kubernetes-retired/dashboard before assuming either URL is still current."
  type        = string
  default     = "7.14.0"
}

variable "oidc_issuer_url" {
  description = <<-EOT
    OIDC issuer URL for real user authentication against the API server (the
    `admin_subjects` in var.tenants are only meaningful once users actually
    authenticate as something other than the shared kubeconfig admin cert --
    RBAC without this is authorization with no real authentication behind
    it). Left empty by default: this repo doesn't pick an identity provider
    for you. Point it at an existing corporate IdP (Okta/Azure AD/Google
    Workspace all support OIDC directly), or deploy Dex
    (https://github.com/dexidp/dex, CNCF, open source) in-cluster first if
    you want a self-contained option with pluggable backends (LDAP, GitHub,
    SAML, static users for a quick start). Takes effect on fresh
    control-plane nodes only, same as every other config.yaml setting.
  EOT
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client ID registered with the issuer above. Ignored if oidc_issuer_url is empty."
  type        = string
  default     = ""
}

variable "oidc_username_claim" {
  description = "OIDC claim mapped to the Kubernetes username (RBAC subject name)."
  type        = string
  default     = "email"
}

variable "oidc_groups_claim" {
  description = "OIDC claim mapped to Kubernetes groups -- lets you bind var.tenants admin_subjects to an IdP group instead of individual users."
  type        = string
  default     = "groups"
}

variable "tenants" {
  description = <<-EOT
    Multi-tenant isolation. Each key becomes a `tenant-<key>` Namespace with:
    a ResourceQuota/LimitRange, a `tenant-admin` Role scoped to that namespace
    (deliberately excluding ResourceQuota/LimitRange/NetworkPolicy/Role edits,
    so a tenant admin can't loosen their own isolation boundary or escalate
    privilege), a RoleBinding to `admin_subjects`, and default-deny
    NetworkPolicies (intra-tenant traffic allowed, cross-tenant denied, DNS
    egress allowed). This is LOGICAL isolation -- the same model GKE/EKS
    multi-tenant setups typically use in production.

    Set `dedicated_node_names` (must be names from control_plane_ip_addresses'
    worker equivalents, i.e. existing rke2-lab-worker-N nodes) for PHYSICAL
    isolation on top of that: those nodes get tainted/labeled for this tenant
    alone, and a generated Kyverno mutation policy auto-injects the matching
    nodeSelector/toleration into every pod created in that tenant's namespace,
    so tenant workloads land only on their own dedicated hardware without
    relying on the tenant admin to remember to ask for it. Costs real spare
    worker capacity -- there is no separate tenant-only VM pool provisioned
    by this variable, it repurposes existing workers you name explicitly.

    Defaults to an empty map: adding this variable to the repo does not
    change the live cluster's behavior at all until you actually declare a
    tenant in terraform.tfvars.
  EOT
  type = map(object({
    admin_subjects = list(object({
      kind      = string # "User", "Group", or "ServiceAccount"
      name      = string
      namespace = optional(string) # required, and only meaningful, for kind = "ServiceAccount"
    }))
    cpu_limit            = optional(string, "8")
    memory_limit         = optional(string, "16Gi")
    storage_limit        = optional(string, "100Gi")
    pod_limit            = optional(number, 50)
    dedicated_node_names = optional(list(string), [])
  }))
  default = {}
}

variable "rke2_cis_profile" {
  description = <<-EOT
    Enables RKE2's built-in `profile: cis` mode (kubelet protect-kernel-defaults,
    restricted PSA-aligned defaults, etc.) -- RKE2's own mapping of the CIS
    Kubernetes Benchmark, which CISA/NSA's Kubernetes Hardening Guidance is
    itself largely built on. Defaults to false so enabling it is a deliberate
    opt-in, not a silent behavior change: it can affect what already-running
    workloads are permitted to do (e.g. hostNetwork/privileged pods), and like
    every other setting in config.yaml it only takes effect on a genuinely
    fresh node -- see the etcd-identity rough edge in CLAUDE.md before ever
    flipping this on an already-bootstrapped cluster via extra_config alone.
  EOT
  type        = bool
  default     = false
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

# -----------------------------------------------------------------------------
# Zabbix proxy (monitoring)
# -----------------------------------------------------------------------------

variable "zabbix_proxy_image" {
  description = <<-EOT
    Tag of the zabbix-proxy-sqlite3 image hosted in this repo's own in-cluster
    registry (see local.registry_address) -- NOT a Docker Hub tag. As of
    2026-08, neither Docker Hub nor the zabbix-community Helm chart have
    published anything past Zabbix 7.4, but the target Zabbix Server here
    runs 8.0.0 -- Zabbix's proxy/server compatibility check hard-rejects a
    proxy a full major version behind ("proxy and server major versions do
    not match"), so 7.4.x doesn't actually work here even though it's newer
    than nothing. This image was built locally from zabbix/zabbix-docker's
    `trunk` branch (`make base && make bake-target TARGET=build-sqlite3 &&
    make bake-target TARGET=proxy-sqlite3`, in a throwaway clone -- not
    vendored into this repo) and pushed to the in-cluster registry as
    "8.0.0rc1" (that's genuinely what `zabbix_proxy -V` reports -- trunk
    tracks pre-release code, since 8.0 hasn't GA'd publicly as stable
    packages yet). Re-point this at an upstream Docker Hub tag once Zabbix
    publishes real 8.0.x images -- this local build is a stopgap, not
    something to keep maintaining by hand long-term.
  EOT
  type        = string
  default     = "8.0.0rc1"
}

variable "zabbix_server_host" {
  description = "IP/hostname of the existing external Zabbix Server this proxy reports to. The proxy runs in active mode (connects out to this address on port 10051) -- no inbound exposure needed, so nothing here goes through MetalLB/Ingress."
  type        = string
}

variable "zabbix_proxy_hostname" {
  description = "Name this proxy registers as. For an active proxy, this must exactly match a proxy already created on the Zabbix Server (Administration -> Proxies) with mode set to Active -- the server silently ignores data from a name it doesn't recognize."
  type        = string
  default     = "rke2-cluster-proxy"
}

variable "zabbix_proxy_storage_size" {
  description = "PVC size for the proxy's SQLite database (its local buffer, not permanent history -- the server owns real long-term storage)."
  type        = string
  default     = "5Gi"
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
