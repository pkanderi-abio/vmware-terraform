#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.${domain}
prefer_fqdn_over_hostname: true

# Explicit rather than relying on the base image's own defaults -- key-only
# SSH access is the sole compensating control for the NOPASSWD sudo below.
ssh_pwauth: false
disable_root: true

users:
  - name: ubuntu
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

write_files:
  - path: /etc/rancher/rke2/config.yaml
    permissions: '0600'
    content: |
      token: ${rke2_token}
      tls-san:
        - ${control_plane_vip}
      node-name: ${hostname}
      etcd-snapshot-schedule-cron: "${etcd_snapshot_schedule_cron}"
      etcd-snapshot-retention: ${etcd_snapshot_retention}
      # Encrypts Secret objects at rest in etcd (AES-CBC, key auto-managed by
      # RKE2) -- CISA/NSA Kubernetes Hardening Guidance calls this out by name.
      # Only takes effect for a genuinely fresh node; do not expect an
      # extra_config update to retrofit this onto an already-bootstrapped
      # control-plane node (see the etcd-identity rough edge in CLAUDE.md) --
      # enabling it on a running cluster is a separate day-2 operation via
      # `rke2 secrets-encrypt enable` on each server node.
      secrets-encryption: true
%{ if cis_profile ~}
      profile: "cis"
%{ endif ~}
      kube-apiserver-arg:
        - "audit-policy-file=/etc/rancher/rke2/audit-policy.yaml"
        - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
        - "audit-log-maxage=30"
        - "audit-log-maxbackup=10"
        - "audit-log-maxsize=100"
%{ if !is_primary ~}
      server: https://${control_plane_vip}:9345
%{ endif ~}
  - path: /etc/rancher/rke2/audit-policy.yaml
    permissions: '0600'
    content: |
      apiVersion: audit.k8s.io/v1
      kind: Policy
      rules:
        # Skip noisy, low-value events entirely.
        - level: None
          resources:
            - group: ""
              resources: ["events"]
        # Full request/response for anything security-sensitive.
        - level: RequestResponse
          resources:
            - group: ""
              resources: ["secrets", "configmaps", "serviceaccounts"]
            - group: "rbac.authorization.k8s.io"
              resources: ["*"]
        # Metadata-only (who/what/when, no bodies) for everything else.
        - level: Metadata
          omitStages: ["RequestReceived"]
%{ if is_primary ~}
  - path: /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
    permissions: '0644'
    encoding: b64
    content: ${kube_vip_manifest_b64}
%{ endif ~}
  - path: /etc/rancher/rke2/registries.yaml
    permissions: '0600'
    encoding: b64
    content: ${registries_config_b64}

runcmd:
  - mkdir -p /var/lib/rancher/rke2/server/logs
  - curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} INSTALL_RKE2_TYPE=server sh -
  - systemctl enable rke2-server.service
  - systemctl start rke2-server.service
