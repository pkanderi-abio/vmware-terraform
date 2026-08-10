# ---------------------------------------------------------------------------
# Multi-tenant isolation (see variables.tf for the full model description).
# Everything in this file is keyed off var.tenants, which defaults to {} --
# this file is a complete no-op against the live cluster until a tenant is
# actually declared.
# ---------------------------------------------------------------------------

locals {
  tenant_k8s_objects = {
    for name, cfg in var.tenants : name => concat([
      {
        apiVersion = "v1"
        kind       = "Namespace"
        metadata = {
          name = "tenant-${name}"
          labels = merge(
            {
              tenant                               = name
              "pod-security.kubernetes.io/enforce" = "baseline"
              "pod-security.kubernetes.io/audit"   = "restricted"
              "pod-security.kubernetes.io/warn"    = "restricted"
            },
            length(cfg.dedicated_node_names) > 0 ? { "tenant-isolation" = "dedicated-nodes" } : {}
          )
        }
      },
      {
        apiVersion = "v1"
        kind       = "ResourceQuota"
        metadata   = { name = "${name}-quota", namespace = "tenant-${name}" }
        spec = {
          hard = {
            "requests.cpu"     = cfg.cpu_limit
            "requests.memory"  = cfg.memory_limit
            "limits.cpu"       = cfg.cpu_limit
            "limits.memory"    = cfg.memory_limit
            "requests.storage" = cfg.storage_limit
            "pods"             = tostring(cfg.pod_limit)
          }
        }
      },
      {
        apiVersion = "v1"
        kind       = "LimitRange"
        metadata   = { name = "${name}-limits", namespace = "tenant-${name}" }
        spec = {
          limits = [{
            type           = "Container"
            default        = { cpu = "500m", memory = "512Mi" }
            defaultRequest = { cpu = "100m", memory = "128Mi" }
          }]
        }
      },
      {
        # Deliberately excludes resourcequotas/limitranges/networkpolicies/
        # roles/rolebindings -- a tenant admin gets full control of their own
        # workloads but cannot edit or delete the objects that enforce the
        # isolation boundary around them, and cannot grant themselves (or
        # anyone else) broader RBAC from inside their own namespace.
        apiVersion = "rbac.authorization.k8s.io/v1"
        kind       = "Role"
        metadata   = { name = "tenant-admin", namespace = "tenant-${name}" }
        rules = [
          {
            apiGroups = [""]
            resources = ["pods", "pods/log", "pods/exec", "services", "endpoints", "configmaps", "secrets", "persistentvolumeclaims", "serviceaccounts", "events"]
            verbs     = ["*"]
          },
          {
            apiGroups = ["apps"]
            resources = ["deployments", "statefulsets", "daemonsets", "replicasets"]
            verbs     = ["*"]
          },
          {
            apiGroups = ["batch"]
            resources = ["jobs", "cronjobs"]
            verbs     = ["*"]
          },
          {
            apiGroups = ["autoscaling"]
            resources = ["horizontalpodautoscalers"]
            verbs     = ["*"]
          },
          {
            apiGroups = ["networking.k8s.io"]
            resources = ["ingresses"]
            verbs     = ["*"]
          },
        ]
      },
      {
        apiVersion = "rbac.authorization.k8s.io/v1"
        kind       = "RoleBinding"
        metadata   = { name = "tenant-admin-binding", namespace = "tenant-${name}" }
        subjects = [
          for s in cfg.admin_subjects : s.kind == "ServiceAccount" ? {
            kind      = "ServiceAccount"
            name      = s.name
            namespace = s.namespace
            } : {
            kind     = s.kind
            name     = s.name
            apiGroup = "rbac.authorization.k8s.io"
          }
        ]
        roleRef = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "tenant-admin" }
      },
      {
        apiVersion = "networking.k8s.io/v1"
        kind       = "NetworkPolicy"
        metadata   = { name = "default-deny-all", namespace = "tenant-${name}" }
        spec       = { podSelector = {}, policyTypes = ["Ingress", "Egress"] }
      },
      {
        apiVersion = "networking.k8s.io/v1"
        kind       = "NetworkPolicy"
        metadata   = { name = "allow-intra-tenant", namespace = "tenant-${name}" }
        spec = {
          podSelector = {}
          policyTypes = ["Ingress", "Egress"]
          ingress     = [{ from = [{ podSelector = {} }] }]
          egress      = [{ to = [{ podSelector = {} }] }]
        }
      },
      {
        apiVersion = "networking.k8s.io/v1"
        kind       = "NetworkPolicy"
        metadata   = { name = "allow-dns", namespace = "tenant-${name}" }
        spec = {
          podSelector = {}
          policyTypes = ["Egress"]
          egress = [{
            to    = [{ namespaceSelector = {} }]
            ports = [{ port = 53, protocol = "UDP" }, { port = 53, protocol = "TCP" }]
          }]
        }
      },
      ], length(cfg.dedicated_node_names) == 0 ? [] : [
      {
        # Auto-injects the placement constraint into every pod created in
        # this tenant's namespace, rather than relying on the tenant admin to
        # remember to ask for it -- physical isolation that's enforced, not
        # merely documented.
        apiVersion = "kyverno.io/v1"
        kind       = "ClusterPolicy"
        metadata   = { name = "tenant-${name}-pin-to-dedicated-nodes" }
        spec = {
          rules = [{
            name  = "add-node-affinity"
            match = { any = [{ resources = { kinds = ["Pod"], namespaces = ["tenant-${name}"] } }] }
            mutate = {
              patchStrategicMerge = {
                spec = {
                  nodeSelector = { tenant = name }
                  tolerations = [{
                    key      = "tenant"
                    operator = "Equal"
                    value    = name
                    effect   = "NoSchedule"
                  }]
                }
              }
            }
          }]
        }
      }
    ])
  }

  tenant_manifest_yaml = {
    for name, objs in local.tenant_k8s_objects : name => join("\n---\n", [for o in objs : yamlencode(o)])
  }

  # kubectl taint/label commands for each tenant's dedicated nodes, if any.
  tenant_node_commands = {
    for name, cfg in var.tenants : name => flatten([
      for node in cfg.dedicated_node_names : [
        "eval $KCTL taint nodes ${node} tenant=${name}:NoSchedule --overwrite",
        "eval $KCTL label nodes ${node} tenant=${name} --overwrite",
      ]
    ])
  }
}

resource "null_resource" "apply_tenant" {
  for_each   = var.tenants
  depends_on = [null_resource.install_kyverno]

  triggers = {
    manifest_hash = md5(local.tenant_manifest_yaml[each.key])
  }

  connection {
    type        = "ssh"
    host        = var.control_plane_ip_addresses[0]
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.tenant_manifest_yaml[each.key]
    destination = "/tmp/tenant-${each.key}.yaml"
  }

  provisioner "remote-exec" {
    inline = concat(
      [
        "KCTL='sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl'",
        "eval $KCTL apply -f /tmp/tenant-${each.key}.yaml",
      ],
      local.tenant_node_commands[each.key],
      ["rm -f /tmp/tenant-${each.key}.yaml"],
    )
  }
}
