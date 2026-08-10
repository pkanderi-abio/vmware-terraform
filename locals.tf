locals {
  control_plane_names = [for i in range(3) : "${var.cluster_name}-cp-${i}"]
  worker_names        = [for i in range(var.worker_count) : "${var.cluster_name}-worker-${i}"]
  vm_folder_path      = try(vsphere_folder.vm_folder[0].path, null)

  kube_vip_manifest_b64 = base64encode(templatefile("${path.module}/templates/manifests/kube-vip.yaml.tpl", {
    vip_address      = var.control_plane_vip
    interface_name   = var.network_interface_name
    kube_vip_version = "v0.8.2"
  }))

  csi_namespace_manifest_url = "https://raw.githubusercontent.com/kubernetes-sigs/vsphere-csi-driver/${var.vsphere_csi_driver_version}/manifests/vanilla/namespace.yaml"
  csi_driver_manifest_url    = "https://raw.githubusercontent.com/kubernetes-sigs/vsphere-csi-driver/${var.vsphere_csi_driver_version}/manifests/vanilla/vsphere-csi-driver.yaml"

  csi_config_secret_yaml = templatefile("${path.module}/templates/csi/vsphere-config-secret.yaml.tpl", {
    cluster_id       = var.cluster_name
    vsphere_server   = var.vsphere_server
    vsphere_user     = var.vsphere_user
    vsphere_password = var.vsphere_password
    datacenter       = var.vsphere_datacenter
    insecure_flag    = var.vsphere_allow_unverified_ssl ? "true" : "false"
  })

  csi_storageclass_yaml = templatefile("${path.module}/templates/csi/storageclass.yaml.tpl", {
    datastore_url = var.vsphere_datastore_url
  })

  registry_address = "${var.control_plane_vip}:${var.registry_node_port}"

  # bcrypt() is a native Terraform function -- no external htpasswd tool needed.
  registry_htpasswd = "${var.registry_username}:${bcrypt(var.registry_password)}"

  # TLS material for the registry (see tls.tf). Only the CA's public cert is
  # ever distributed to nodes -- the server key stays in this Secret alone.
  registry_tls_cert_b64 = base64encode(tls_locally_signed_cert.registry_server.cert_pem)
  registry_tls_key_b64  = base64encode(tls_private_key.registry_server.private_key_pem)
  registry_ca_cert_pem  = tls_self_signed_cert.registry_ca.cert_pem
  registry_ca_cert_b64  = base64encode(local.registry_ca_cert_pem)

  registry_manifest_yaml = templatefile("${path.module}/templates/registry/registry.yaml.tpl", {
    storage_size     = var.registry_storage_size
    node_port        = var.registry_node_port
    htpasswd_content = local.registry_htpasswd
    tls_cert_b64     = local.registry_tls_cert_b64
    tls_key_b64      = local.registry_tls_key_b64
  })

  registries_config_yaml = templatefile("${path.module}/templates/registries.yaml.tpl", {
    registry_address  = local.registry_address
    registry_username = var.registry_username
    registry_password = var.registry_password
  })
  registries_config_yaml_b64 = base64encode(local.registries_config_yaml)

  metallb_manifest_url = "https://raw.githubusercontent.com/metallb/metallb/${var.metallb_version}/config/manifests/metallb-native.yaml"

  metallb_config_yaml = templatefile("${path.module}/templates/metallb/config.yaml.tpl", {
    ip_range = var.metallb_ip_range
  })

  # Installed via Helm (like Trivy-Operator and Falco below) rather than a
  # static manifest URL -- unlike vsphere-csi-driver/MetalLB/kube-vip, none
  # of these three publish a single kubectl-applyable install.yaml upstream.
  kyverno_baseline_policies_yaml = file("${path.module}/templates/security/kyverno-baseline-policies.yaml")

  ingress_waf_config_yaml = file("${path.module}/templates/ingress/waf-config.yaml")
}
