# ---------------------------------------------------------------------------
# Internal CA + registry server certificate. Generated locally (no ACME/CA
# dependency) so the in-cluster registry can serve HTTPS instead of the
# plaintext HTTP it shipped with -- registry credentials no longer cross the
# wire in cleartext. This CA's private key never leaves Terraform state /
# the node filesystem it's rendered onto; only the CA's public certificate
# is distributed to nodes (for containerd to verify the registry's cert
# against), via the same delivery paths as registries.yaml.
#
# This is NOT a substitute for a publicly-trusted certificate if this cluster
# is ever exposed to the public internet under a real domain name -- for
# anything reachable from outside this network, use cert-manager's ACME
# (Let's Encrypt) issuer instead (see the cert-manager install below), which
# every browser/client already trusts without needing this CA distributed
# to them. This internal CA exists specifically to secure node<->registry
# traffic, which will never be internet-facing regardless.
# ---------------------------------------------------------------------------

resource "tls_private_key" "registry_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "registry_ca" {
  private_key_pem       = tls_private_key.registry_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600 # 10 years -- internal root CA; rotate by tainting this resource if ever compromised.

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]

  subject {
    common_name  = "${var.cluster_name} internal registry CA"
    organization = var.cluster_name
  }
}

resource "tls_private_key" "registry_server" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "registry_server" {
  private_key_pem = tls_private_key.registry_server.private_key_pem

  subject {
    common_name = var.control_plane_vip
  }

  # Nodes reach the registry at the VIP by IP, not a DNS name -- the cert
  # must carry it as an IP SAN or clients will reject it even with the CA
  # trusted, since CN alone is not honored by modern TLS stacks.
  ip_addresses = [var.control_plane_vip]
  dns_names    = ["registry.${var.cluster_name}.local", "registry"]
}

resource "tls_locally_signed_cert" "registry_server" {
  cert_request_pem   = tls_cert_request.registry_server.cert_request_pem
  ca_private_key_pem = tls_private_key.registry_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.registry_ca.cert_pem

  validity_period_hours = 8760 # 1 year
  early_renewal_hours   = 720  # renew automatically 30 days before expiry on a plan/apply

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}
