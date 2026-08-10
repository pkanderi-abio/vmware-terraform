apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-vip
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-vip-role
rules:
  - apiGroups: [""]
    resources: ["services", "services/status", "nodes", "endpoints"]
    verbs: ["list", "get", "watch", "update"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["list", "get", "watch", "update", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-vip-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-vip-role
subjects:
  - kind: ServiceAccount
    name: kube-vip
    namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-vip-ds
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-vip-ds
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-vip-ds
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-vip-ds
    spec:
      serviceAccountName: kube-vip
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
      containers:
        - name: kube-vip
          image: ghcr.io/kube-vip/kube-vip:${kube_vip_version}
          imagePullPolicy: IfNotPresent
          args: ["manager"]
          env:
            - name: vip_arp
              value: "true"
            - name: port
              value: "6443"
            - name: vip_interface
              value: "${interface_name}"
            - name: vip_cidr
              value: "32"
            - name: cp_enable
              value: "true"
            - name: cp_namespace
              value: "kube-system"
            - name: vip_ddns
              value: "false"
            - name: svc_enable
              value: "false"
            - name: vip_leaderelection
              value: "true"
            # kube-vip treats ANY lost-leadership event (including a lease
            # renewal that simply took too long) as fatal and restarts the
            # entire process -- it does not gracefully step back to standby.
            # kube-vip's own upstream defaults (5s/3s/1s) assume apiserver/
            # etcd responds quickly; this cluster's ongoing datastore I/O
            # incident (see CLAUDE.md) has produced apiserver reads taking
            # up to 17.8s and etcd fsyncs up to 15.1s, which made the tight
            # defaults crash-loop kube-vip continuously (600+ lease
            # transitions, all 3 pods in CrashLoopBackOff simultaneously) --
            # not because kube-vip was broken, but because it was faithfully
            # treating routine storage-induced latency as a fatal event.
            # These values give real margin above the worst latency directly
            # observed, at the cost of slower failover on a genuine node
            # loss. Tighten back toward the upstream defaults once the
            # datastore incident is actually resolved -- this is a mitigation
            # for current abnormal conditions, not a permanent improvement.
            - name: vip_leaseduration
              value: "30"
            - name: vip_renewdeadline
              value: "20"
            - name: vip_retryperiod
              value: "3"
            - name: address
              value: "${vip_address}"
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
      hostNetwork: true
