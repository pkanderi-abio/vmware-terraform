mirrors:
  "${registry_address}":
    endpoint:
      - "https://${registry_address}"
configs:
  "${registry_address}":
    auth:
      username: ${registry_username}
      password: ${registry_password}
    tls:
      ca_file: /etc/rancher/rke2/registry-ca.crt
