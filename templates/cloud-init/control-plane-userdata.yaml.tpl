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
      tls-san:
        - ${control_plane_vip}
      node-name: ${hostname}
      etcd-snapshot-schedule-cron: "${etcd_snapshot_schedule_cron}"
      etcd-snapshot-retention: ${etcd_snapshot_retention}
%{ if !is_primary ~}
      server: https://${control_plane_vip}:9345
%{ endif ~}
%{ if is_primary ~}
  - path: /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
    permissions: '0644'
    encoding: b64
    content: ${kube_vip_manifest_b64}
%{ endif ~}
  - path: /etc/rancher/rke2/registries.yaml
    permissions: '0644'
    encoding: b64
    content: ${registries_config_b64}

runcmd:
  - curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} INSTALL_RKE2_TYPE=server sh -
  - systemctl enable rke2-server.service
  - systemctl start rke2-server.service
