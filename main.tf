data "vsphere_datacenter" "dc" {
  name = var.vsphere_datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.vsphere_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  name          = var.vsphere_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.vsphere_network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_folder" "vm_folder" {
  count = var.vsphere_folder != "" ? 1 : 0

  path          = var.vsphere_folder
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc.id
}

# ---------------------------------------------------------------------------
# Governance tagging -- marks every VM this repo manages at the vCenter level,
# independent of anything visible from inside Terraform state alone.
# ---------------------------------------------------------------------------

resource "vsphere_tag_category" "managed_by" {
  name             = "managed-by"
  description      = "What provisioned this object."
  cardinality      = "SINGLE"
  associable_types = ["VirtualMachine"]
}

resource "vsphere_tag" "terraform_managed" {
  name        = "terraform:${var.cluster_name}"
  category_id = vsphere_tag_category.managed_by.id
  description = "Managed by the ${var.cluster_name} Terraform state. Do not hand-edit in vCenter."
}

# ---------------------------------------------------------------------------
# Control-plane node 0: bootstraps the cluster (cluster-init) and carries the
# kube-vip manifest that gives the other nodes a stable join address.
# ---------------------------------------------------------------------------

module "control_plane_primary" {
  source = "./modules/vm"

  name             = local.control_plane_names[0]
  folder           = local.vm_folder_path
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  network_id       = data.vsphere_network.network.id
  template_uuid    = data.vsphere_virtual_machine.template.id

  num_cpus  = var.control_plane_cpu
  memory_mb = var.control_plane_memory_mb
  disk_gb   = var.control_plane_disk_gb

  # etcd is latency-sensitive -- guard it against host contention.
  reserve_memory  = true
  cpu_share_level = "high"
  tag_ids         = [vsphere_tag.terraform_managed.id]

  metadata = templatefile("${path.module}/templates/cloud-init/metadata.yaml.tpl", {
    hostname       = local.control_plane_names[0]
    ip_address     = var.control_plane_ip_addresses[0]
    prefix_length  = var.network_prefix_length
    gateway        = var.network_gateway
    dns_servers    = var.network_dns_servers
    interface_name = var.network_interface_name
  })

  userdata = templatefile("${path.module}/templates/cloud-init/control-plane-userdata.yaml.tpl", {
    hostname                    = local.control_plane_names[0]
    domain                      = var.vm_domain
    ssh_public_key              = var.ssh_public_key
    rke2_token                  = var.rke2_token
    rke2_version                = var.rke2_version
    control_plane_vip           = var.control_plane_vip
    is_primary                  = true
    kube_vip_manifest_b64       = local.kube_vip_manifest_b64
    registries_config_b64       = local.registries_config_yaml_b64
    etcd_snapshot_schedule_cron = var.etcd_snapshot_schedule_cron
    etcd_snapshot_retention     = var.etcd_snapshot_retention
    cis_profile                 = var.rke2_cis_profile
    registry_ca_cert_b64        = local.registry_ca_cert_b64
    oidc_issuer_url             = var.oidc_issuer_url
    oidc_client_id              = var.oidc_client_id
    oidc_username_claim         = var.oidc_username_claim
    oidc_groups_claim           = var.oidc_groups_claim
  })
}

# Blocks the rest of the cluster from creating until the first control-plane
# node has actually finished cloud-init and RKE2 is serving on the VIP -- VM
# creation alone doesn't imply that.
resource "null_resource" "wait_for_primary" {
  depends_on = [module.control_plane_primary]

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "until sudo systemctl is-active --quiet rke2-server; do sleep 5; done",
      # RKE2 disables anonymous auth by default, so /readyz always 401s for an
      # unauthenticated caller -- that 401 still proves the VIP is routing to a
      # live apiserver. Check raw TCP reachability on the actual join port (9345)
      # instead of trying to parse an auth-gated HTTP response.
      "until timeout 3 bash -c 'cat < /dev/null > /dev/tcp/${var.control_plane_vip}/9345' 2>/dev/null; do sleep 5; done",
    ]
  }
}

# ---------------------------------------------------------------------------
# Remaining control-plane nodes join via the VIP once it's live.
# ---------------------------------------------------------------------------

module "control_plane_secondary" {
  source   = "./modules/vm"
  for_each = toset(["1", "2"])

  name             = local.control_plane_names[tonumber(each.key)]
  folder           = local.vm_folder_path
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  network_id       = data.vsphere_network.network.id
  template_uuid    = data.vsphere_virtual_machine.template.id

  num_cpus  = var.control_plane_cpu
  memory_mb = var.control_plane_memory_mb
  disk_gb   = var.control_plane_disk_gb

  reserve_memory  = true
  cpu_share_level = "high"
  tag_ids         = [vsphere_tag.terraform_managed.id]

  metadata = templatefile("${path.module}/templates/cloud-init/metadata.yaml.tpl", {
    hostname       = local.control_plane_names[tonumber(each.key)]
    ip_address     = var.control_plane_ip_addresses[tonumber(each.key)]
    prefix_length  = var.network_prefix_length
    gateway        = var.network_gateway
    dns_servers    = var.network_dns_servers
    interface_name = var.network_interface_name
  })

  userdata = templatefile("${path.module}/templates/cloud-init/control-plane-userdata.yaml.tpl", {
    hostname                    = local.control_plane_names[tonumber(each.key)]
    domain                      = var.vm_domain
    ssh_public_key              = var.ssh_public_key
    rke2_token                  = var.rke2_token
    rke2_version                = var.rke2_version
    control_plane_vip           = var.control_plane_vip
    is_primary                  = false
    kube_vip_manifest_b64       = ""
    registries_config_b64       = local.registries_config_yaml_b64
    etcd_snapshot_schedule_cron = var.etcd_snapshot_schedule_cron
    etcd_snapshot_retention     = var.etcd_snapshot_retention
    cis_profile                 = var.rke2_cis_profile
    registry_ca_cert_b64        = local.registry_ca_cert_b64
    oidc_issuer_url             = var.oidc_issuer_url
    oidc_client_id              = var.oidc_client_id
    oidc_username_claim         = var.oidc_username_claim
    oidc_groups_claim           = var.oidc_groups_claim
  })

  depends_on = [null_resource.wait_for_primary]
}

# Nothing about DRS placement inherently keeps the 3 etcd members on separate
# hosts -- without this, a single ESXi host failure can take out the entire
# control plane despite "3 nodes" suggesting otherwise. `mandatory = true`
# requires at least 3 hosts in the cluster (verified: 4 here); it will block
# host maintenance-mode entry if too few hosts remain to satisfy it.
resource "vsphere_compute_cluster_vm_anti_affinity_rule" "control_plane" {
  name               = "${var.cluster_name}-control-plane-anti-affinity"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  enabled            = true
  mandatory          = true
  virtual_machine_ids = concat(
    [module.control_plane_primary.id],
    [for m in module.control_plane_secondary : m.id],
  )
}

# ---------------------------------------------------------------------------
# Workers
# ---------------------------------------------------------------------------

module "workers" {
  source   = "./modules/vm"
  for_each = toset([for i in range(var.worker_count) : tostring(i)])

  name             = local.worker_names[tonumber(each.key)]
  folder           = local.vm_folder_path
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  network_id       = data.vsphere_network.network.id
  template_uuid    = data.vsphere_virtual_machine.template.id

  num_cpus  = var.worker_cpu
  memory_mb = var.worker_memory_mb
  disk_gb   = var.worker_disk_gb

  tag_ids = [vsphere_tag.terraform_managed.id]

  metadata = templatefile("${path.module}/templates/cloud-init/metadata.yaml.tpl", {
    hostname       = local.worker_names[tonumber(each.key)]
    ip_address     = var.worker_ip_addresses[tonumber(each.key)]
    prefix_length  = var.network_prefix_length
    gateway        = var.network_gateway
    dns_servers    = var.network_dns_servers
    interface_name = var.network_interface_name
  })

  userdata = templatefile("${path.module}/templates/cloud-init/worker-userdata.yaml.tpl", {
    hostname              = local.worker_names[tonumber(each.key)]
    domain                = var.vm_domain
    ssh_public_key        = var.ssh_public_key
    rke2_token            = var.rke2_token
    rke2_version          = var.rke2_version
    control_plane_vip     = var.control_plane_vip
    registries_config_b64 = local.registries_config_yaml_b64
    cis_profile           = var.rke2_cis_profile
    registry_ca_cert_b64  = local.registry_ca_cert_b64
  })

  depends_on = [null_resource.wait_for_primary]
}

# ---------------------------------------------------------------------------
# vSphere CSI driver: gives the cluster a default StorageClass backed by real
# VMDKs on var.vsphere_datastore. RKE2 ships no CSI driver out of the box.
# ---------------------------------------------------------------------------

resource "null_resource" "install_vsphere_csi" {
  depends_on = [module.control_plane_secondary, module.workers]

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.csi_config_secret_yaml
    destination = "/tmp/csi-vsphere-config-secret.yaml"
  }

  provisioner "file" {
    content     = local.csi_storageclass_yaml
    destination = "/tmp/csi-vsphere-storageclass.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      # The uploaded file carries a plaintext vCenter password (see the CSI
      # secret template) -- restrict it before anything else touches the node,
      # and remove it once applied rather than leaving credentials on disk.
      "chmod 600 /tmp/csi-vsphere-config-secret.yaml",
      "KCTL='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl'",
      "eval $KCTL apply -f ${local.csi_namespace_manifest_url}",
      "eval $KCTL apply -f /tmp/csi-vsphere-config-secret.yaml",
      "eval $KCTL apply -f ${local.csi_driver_manifest_url}",
      "eval $KCTL -n vmware-system-csi rollout status deployment/vsphere-csi-controller --timeout=5m",
      "eval $KCTL -n vmware-system-csi rollout status daemonset/vsphere-csi-node --timeout=5m",
      "eval $KCTL apply -f /tmp/csi-vsphere-storageclass.yaml",
      # RKE2 ships its own default "local-path" StorageClass; having two
      # StorageClasses marked default is ambiguous, so demote it in favor of
      # the vSphere-backed one set up above.
      "eval $KCTL patch storageclass local-path -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}' || true",
      "shred -u /tmp/csi-vsphere-config-secret.yaml 2>/dev/null || rm -f /tmp/csi-vsphere-config-secret.yaml",
      "rm -f /tmp/csi-vsphere-storageclass.yaml",
    ]
  }
}

# ---------------------------------------------------------------------------
# In-cluster image registry: registry:2 with htpasswd basic auth, TLS (see
# tls.tf for the internal CA + server cert), backed by a vsphere-csi PVC.
# Nodes pull from it as https://<control_plane_vip>:<node_port> -- NodePort
# is exposed by kube-proxy on every node, so this works regardless of which
# node currently holds the kube-vip VIP.
# ---------------------------------------------------------------------------

resource "null_resource" "install_registry" {
  depends_on = [null_resource.install_vsphere_csi]

  # Without this, changing registry.yaml.tpl (e.g. adding TLS) would never
  # re-apply against a cluster this resource already succeeded on -- same
  # stale-push lesson as the configure_registry_mirror_* resources below.
  triggers = {
    manifest_hash = md5(local.registry_manifest_yaml)
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.registry_manifest_yaml
    destination = "/tmp/registry.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      # Carries the registry's bcrypt htpasswd -- restrict and clean up.
      "chmod 600 /tmp/registry.yaml",
      "KCTL='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl'",
      "eval $KCTL apply -f /tmp/registry.yaml",
      "eval $KCTL -n registry rollout status deployment/registry --timeout=5m",
      "rm -f /tmp/registry.yaml",
    ]
  }
}

# ---------------------------------------------------------------------------
# Push registries.yaml directly to nodes that already existed before this
# config was added. Cloud-init's write_files/runcmd stage only runs once per
# instance (tracked by a marker on disk) -- a plain reboot with updated
# extra_config does NOT make an already-bootstrapped node re-process its
# user-data, so a fresh clone's cloud-init step alone can't reach these nodes.
# Safe to leave in permanently: on a brand-new node this is a harmless no-op
# (the file's already there from cloud-init), and it self-heals any drift.
# ---------------------------------------------------------------------------

resource "null_resource" "configure_registry_mirror_workers" {
  for_each   = toset([for i in range(var.worker_count) : tostring(i)])
  depends_on = [null_resource.install_registry]

  # Without this, a content-only change (e.g. adding registry auth) would
  # never re-run on nodes this already succeeded against -- null_resource
  # has no other way to detect that the *rendered file* changed underneath it.
  triggers = {
    config_hash = md5(local.registries_config_yaml)
    ca_hash     = md5(local.registry_ca_cert_pem)
    # Bump this when the provisioner script itself changes (not just the
    # content it pushes) -- config_hash alone can't detect that, and a stale
    # push otherwise silently leaves already-provisioned nodes unpatched.
    script_version = "3"
  }

  connection {
    type        = "ssh"
    host        = var.worker_ip_addresses[tonumber(each.key)]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.registries_config_yaml
    destination = "/tmp/registries.yaml"
  }

  provisioner "file" {
    content     = local.registry_ca_cert_pem
    destination = "/tmp/registry-ca.crt"
  }

  provisioner "remote-exec" {
    inline = [
      # Carries the registry's plaintext password (see registries.yaml.tpl's
      # configs.auth block) -- restrict before it lands, clean up after.
      "chmod 600 /tmp/registries.yaml",
      "sudo cp /tmp/registries.yaml /etc/rancher/rke2/registries.yaml",
      "sudo chmod 600 /etc/rancher/rke2/registries.yaml",
      "sudo cp /tmp/registry-ca.crt /etc/rancher/rke2/registry-ca.crt",
      "sudo chmod 644 /etc/rancher/rke2/registry-ca.crt",
      "sudo systemctl restart rke2-agent",
      "rm -f /tmp/registries.yaml /tmp/registry-ca.crt",
    ]
  }
}

# Control-plane nodes one at a time -- restarting rke2-server also restarts
# the local etcd member, so all three restarting together risks quorum loss.
resource "null_resource" "configure_registry_mirror_cp0" {
  depends_on = [null_resource.install_registry]

  triggers = {
    config_hash = md5(local.registries_config_yaml)
    ca_hash     = md5(local.registry_ca_cert_pem)
    # Bump this when the provisioner script itself changes (not just the
    # content it pushes) -- config_hash alone can't detect that, and a stale
    # push otherwise silently leaves already-provisioned nodes unpatched.
    script_version = "3"
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.registries_config_yaml
    destination = "/tmp/registries.yaml"
  }

  provisioner "file" {
    content     = local.registry_ca_cert_pem
    destination = "/tmp/registry-ca.crt"
  }

  provisioner "remote-exec" {
    inline = [
      # Carries the registry's plaintext password (see registries.yaml.tpl's
      # configs.auth block) -- restrict before it lands, clean up after.
      "chmod 600 /tmp/registries.yaml",
      "sudo cp /tmp/registries.yaml /etc/rancher/rke2/registries.yaml",
      "sudo chmod 600 /etc/rancher/rke2/registries.yaml",
      "sudo cp /tmp/registry-ca.crt /etc/rancher/rke2/registry-ca.crt",
      "sudo chmod 644 /etc/rancher/rke2/registry-ca.crt",
      "sudo systemctl restart rke2-server",
      "rm -f /tmp/registries.yaml /tmp/registry-ca.crt",
    ]
  }
}

resource "null_resource" "configure_registry_mirror_cp1" {
  depends_on = [null_resource.configure_registry_mirror_cp0]

  triggers = {
    config_hash = md5(local.registries_config_yaml)
    ca_hash     = md5(local.registry_ca_cert_pem)
    # Bump this when the provisioner script itself changes (not just the
    # content it pushes) -- config_hash alone can't detect that, and a stale
    # push otherwise silently leaves already-provisioned nodes unpatched.
    script_version = "3"
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[1]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.registries_config_yaml
    destination = "/tmp/registries.yaml"
  }

  provisioner "file" {
    content     = local.registry_ca_cert_pem
    destination = "/tmp/registry-ca.crt"
  }

  provisioner "remote-exec" {
    inline = [
      # Carries the registry's plaintext password (see registries.yaml.tpl's
      # configs.auth block) -- restrict before it lands, clean up after.
      "chmod 600 /tmp/registries.yaml",
      "sudo cp /tmp/registries.yaml /etc/rancher/rke2/registries.yaml",
      "sudo chmod 600 /etc/rancher/rke2/registries.yaml",
      "sudo cp /tmp/registry-ca.crt /etc/rancher/rke2/registry-ca.crt",
      "sudo chmod 644 /etc/rancher/rke2/registry-ca.crt",
      "sudo systemctl restart rke2-server",
      "rm -f /tmp/registries.yaml /tmp/registry-ca.crt",
    ]
  }
}

resource "null_resource" "configure_registry_mirror_cp2" {
  depends_on = [null_resource.configure_registry_mirror_cp1]

  triggers = {
    config_hash = md5(local.registries_config_yaml)
    ca_hash     = md5(local.registry_ca_cert_pem)
    # Bump this when the provisioner script itself changes (not just the
    # content it pushes) -- config_hash alone can't detect that, and a stale
    # push otherwise silently leaves already-provisioned nodes unpatched.
    script_version = "3"
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[2]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.registries_config_yaml
    destination = "/tmp/registries.yaml"
  }

  provisioner "file" {
    content     = local.registry_ca_cert_pem
    destination = "/tmp/registry-ca.crt"
  }

  provisioner "remote-exec" {
    inline = [
      # Carries the registry's plaintext password (see registries.yaml.tpl's
      # configs.auth block) -- restrict before it lands, clean up after.
      "chmod 600 /tmp/registries.yaml",
      "sudo cp /tmp/registries.yaml /etc/rancher/rke2/registries.yaml",
      "sudo chmod 600 /etc/rancher/rke2/registries.yaml",
      "sudo cp /tmp/registry-ca.crt /etc/rancher/rke2/registry-ca.crt",
      "sudo chmod 644 /etc/rancher/rke2/registry-ca.crt",
      "sudo systemctl restart rke2-server",
      "rm -f /tmp/registries.yaml /tmp/registry-ca.crt",
    ]
  }
}

# ---------------------------------------------------------------------------
# MetalLB: gives Services of type LoadBalancer (starting with ingress-nginx,
# which otherwise only has per-node hostPort 80/443 -- reachable, but callers
# would need to know all N node IPs rather than one stable floating address)
# a real floating IP from var.metallb_ip_range, ARP-advertised the same way
# kube-vip advertises the control-plane VIP.
# ---------------------------------------------------------------------------

resource "null_resource" "install_metallb" {
  depends_on = [null_resource.install_vsphere_csi]

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.metallb_config_yaml
    destination = "/tmp/metallb-config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "KCTL='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl'",
      "eval $KCTL apply -f ${local.metallb_manifest_url}",
      "eval $KCTL -n metallb-system rollout status deployment/controller --timeout=5m",
      "eval $KCTL -n metallb-system rollout status daemonset/speaker --timeout=5m",
      # The validating webhook's endpoint can take a few seconds past
      # "rollout complete" to actually start accepting connections -- retry
      # rather than fail on the first attempt.
      "for i in $(seq 1 12); do eval $KCTL apply -f /tmp/metallb-config.yaml && break; sleep 5; done",
    ]
  }
}

# ---------------------------------------------------------------------------
# Security tooling: Kyverno (policy-as-code admission control), Trivy-Operator
# (continuous in-cluster vulnerability scanning), Falco (runtime/syscall-level
# threat detection). None of the three publish a single kubectl-applyable
# manifest upstream the way vsphere-csi-driver/MetalLB/kube-vip do above, so
# Helm is installed once on the primary control-plane node and reused for
# all three rather than mixing install patterns.
# ---------------------------------------------------------------------------

resource "null_resource" "install_helm" {
  depends_on = [null_resource.install_vsphere_csi]

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "which helm || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash",
    ]
  }
}

resource "null_resource" "install_kyverno" {
  depends_on = [null_resource.install_helm]

  # Re-run when the pinned chart version changes or the baseline policy set
  # itself changes -- Helm's own idempotency handles the chart install/
  # upgrade either way, but the ClusterPolicy apply needs the same
  # stale-push protection as everything else in this file.
  triggers = {
    chart_version = var.kyverno_chart_version
    policies_hash = md5(local.kyverno_baseline_policies_yaml)
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "10m"
  }

  provisioner "file" {
    content     = local.kyverno_baseline_policies_yaml
    destination = "/tmp/kyverno-baseline-policies.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "HELM='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml helm'",
      "KCTL='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl'",
      "eval $HELM repo add kyverno https://kyverno.github.io/kyverno/",
      "eval $HELM repo update kyverno",
      "eval $HELM upgrade --install kyverno kyverno/kyverno --namespace kyverno --create-namespace --version ${var.kyverno_chart_version} --wait --timeout 5m",
      "eval $KCTL apply -f /tmp/kyverno-baseline-policies.yaml",
      "rm -f /tmp/kyverno-baseline-policies.yaml",
    ]
  }
}

resource "null_resource" "install_trivy_operator" {
  depends_on = [null_resource.install_helm]

  triggers = {
    chart_version = var.trivy_operator_chart_version
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "HELM='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml helm'",
      "eval $HELM repo add aqua https://aquasecurity.github.io/helm-charts/",
      "eval $HELM repo update aqua",
      "eval $HELM upgrade --install trivy-operator aqua/trivy-operator --namespace trivy-system --create-namespace --version ${var.trivy_operator_chart_version} --set trivy.ignoreUnfixed=true --wait --timeout 5m",
    ]
  }
}

resource "null_resource" "install_falco" {
  depends_on = [null_resource.install_helm]

  triggers = {
    chart_version = var.falco_chart_version
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "HELM='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml helm'",
      "eval $HELM repo add falcosecurity https://falcosecurity.github.io/charts",
      "eval $HELM repo update falcosecurity",
      # Modern eBPF driver -- no kernel module build/load required, works
      # out of the box on kernel >= 5.8 (this template's Ubuntu 22.04 ships
      # 5.15+), avoiding the DKMS/driver-loader complexity of older Falco
      # deployment modes.
      "eval $HELM upgrade --install falco falcosecurity/falco --namespace falco --create-namespace --version ${var.falco_chart_version} --set driver.kind=modern_ebpf --wait --timeout 5m",
    ]
  }
}

# ---------------------------------------------------------------------------
# Ingress hardening: WAF (ModSecurity + OWASP CRS), rate limiting, security
# response headers, forced HTTPS. Applies cluster-wide to every Ingress
# behind RKE2's bundled ingress-nginx via its HelmChartConfig override.
# ---------------------------------------------------------------------------

resource "null_resource" "harden_ingress" {
  depends_on = [null_resource.install_metallb]

  triggers = {
    config_hash = md5(local.ingress_waf_config_yaml)
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    # Terraform's SSH communicator attempts agent forwarding by default even
    # when a private_key is given directly, and hard-fails if SSH_AUTH_SOCK
    # isn't reachable in whatever environment `terraform apply` runs in
    # (common on macOS depending on terminal/IDE integration). The private
    # key alone is sufficient for auth; agent forwarding was never needed.
    agent   = false
    timeout = "5m"
  }

  provisioner "file" {
    content     = local.ingress_waf_config_yaml
    destination = "/tmp/ingress-waf-config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "KCTL='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl'",
      "eval $KCTL apply -f /tmp/ingress-waf-config.yaml",
      "rm -f /tmp/ingress-waf-config.yaml",
    ]
  }
}
