instance-id: ${hostname}
local-hostname: ${hostname}
network:
  version: 2
  ethernets:
    ${interface_name}:
      addresses:
        - ${ip_address}/${prefix_length}
      gateway4: ${gateway}
      nameservers:
        addresses: ${jsonencode(dns_servers)}
