mirrors:
  "${registry_address}":
    endpoint:
      - "http://${registry_address}"
configs:
  "${registry_address}":
    auth:
      username: ${registry_username}
      password: ${registry_password}
