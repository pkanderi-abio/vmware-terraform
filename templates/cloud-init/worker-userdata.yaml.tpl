#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.${domain}
prefer_fqdn_over_hostname: true

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

runcmd:
  - curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} INSTALL_RKE2_TYPE=agent sh -
  - systemctl enable rke2-agent.service
  - systemctl start rke2-agent.service
