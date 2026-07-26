apiVersion: v1
kind: Secret
metadata:
  name: vsphere-config-secret
  namespace: vmware-system-csi
stringData:
  csi-vsphere.conf: |
    [Global]
    cluster-id = "${cluster_id}"

    [VirtualCenter "${vsphere_server}"]
    insecure-flag = "${insecure_flag}"
    user = "${vsphere_user}"
    password = "${vsphere_password}"
    port = "443"
    datacenters = "${datacenter}"
