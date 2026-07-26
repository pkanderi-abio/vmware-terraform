apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: vsphere-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.vsphere.vmware.com
parameters:
  datastoreurl: "${datastore_url}"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
