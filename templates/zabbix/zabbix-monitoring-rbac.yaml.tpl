# RBAC for Zabbix's native Kubernetes-API monitoring (the "Kubernetes ...
# by HTTP" template family) -- the Zabbix Server/proxy polls the API server
# and kubelet /metrics endpoints directly using this ServiceAccount's
# token, no in-cluster agent required. Rules copied verbatim from the
# official Zabbix kubernetes-helm chart's ClusterRole (see
# https://git.zabbix.com/projects/ZT/repos/kubernetes-helm/browse/templates/cluster-role.yaml)
# so this token has exactly the permissions those templates expect --
# not a hand-guessed set.
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: zabbix-monitoring
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: zabbix-monitoring
rules:
  - nonResourceURLs:
      - "/metrics"
      - "/metrics/cadvisor"
      - "/version"
      - "/healthz"
      - "/readyz"
    verbs: ["get"]
  - apiGroups: [""]
    resources:
      - nodes/metrics
      - nodes/spec
      - nodes/proxy
      - nodes/stats
    verbs: ["get"]
  - apiGroups: [""]
    resources:
      - namespaces
      - pods
      - services
      - componentstatuses
      - nodes
      - endpoints
      - events
    verbs: ["get", "list"]
  - apiGroups: ["batch"]
    resources:
      - jobs
      - cronjobs
    verbs: ["get", "list"]
  - apiGroups: ["apps"]
    resources:
      - statefulsets
      - deployments
      - daemonsets
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: zabbix-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: zabbix-monitoring
subjects:
  - kind: ServiceAccount
    name: zabbix-monitoring
    namespace: monitoring
