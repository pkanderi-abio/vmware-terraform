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
      server: https://${control_plane_vip}:9345
      node-name: ${hostname}
%{ if cis_profile ~}
      profile: "cis"
%{ endif ~}
  - path: /etc/rancher/rke2/registries.yaml
    permissions: '0600'
    encoding: b64
    content: ${registries_config_b64}
  - path: /etc/rancher/rke2/registry-ca.crt
    permissions: '0644'
    encoding: b64
    content: ${registry_ca_cert_b64}

runcmd:
  - curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} INSTALL_RKE2_TYPE=agent sh -
  - systemctl enable rke2-agent.service
  - systemctl start rke2-agent.service
