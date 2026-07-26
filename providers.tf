# Credentials are read from the VSPHERE_USER / VSPHERE_PASSWORD / VSPHERE_SERVER
# environment variables by default. Override via variables only if you need to.
provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = var.vsphere_allow_unverified_ssl
}
