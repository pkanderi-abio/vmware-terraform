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
}
