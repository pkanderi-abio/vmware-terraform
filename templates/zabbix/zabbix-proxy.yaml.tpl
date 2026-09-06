apiVersion: v1
kind: Namespace
metadata:
  name: zabbix
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zabbix-proxy-data
  namespace: zabbix
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: vsphere-csi
  resources:
    requests:
      storage: ${storage_size}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zabbix-proxy
  namespace: zabbix
spec:
  # A second replica would just be a second, independently-buffering proxy
  # registering under the same active-proxy name -- Zabbix has no concept of
  # HA for a single proxy identity outside its separate "Proxy Group"
  # feature, which this isn't set up for. Recreate (not RollingUpdate) so the
  # SQLite file is never opened by two pods at once.
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: zabbix-proxy
  template:
    metadata:
      labels:
        app: zabbix-proxy
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1997
        fsGroup: 1997
      containers:
        - name: zabbix-proxy
          image: ${image_ref}
          securityContext:
            runAsNonRoot: true
            runAsUser: 1997
            allowPrivilegeEscalation: false
          env:
            # Active mode (default: ZBX_PROXYMODE=0) -- the proxy connects
            # OUT to the server, so nothing here needs inbound exposure via
            # MetalLB/Ingress. ZBX_HOSTNAME must exactly match a proxy
            # already created on the server side with mode set to Active.
            - name: ZBX_HOSTNAME
              value: "${proxy_hostname}"
            - name: ZBX_SERVER_HOST
              value: "${zabbix_server_host}"
            # This proxy name already carries ~12,000 items across 20 hosts
            # from a prior deployment (visible server-side even before this
            # pod ever ran) -- the default CacheSize is far too small to
            # hold that much config, and the proxy crash-loops on startup
            # with "__zbx_shmem_realloc(): out of memory" / "please increase
            # CacheSize" the instant it tries to sync it all down. 128M is
            # generous headroom over what a 4-5MB raw config payload needs
            # once Zabbix's own allocator overhead/fragmentation is factored
            # in (observed ~7MB used across 81k+ chunks at the default size).
            - name: ZBX_CACHESIZE
              value: "128M"
          ports:
            - containerPort: 10051
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          volumeMounts:
            - name: data
              mountPath: /var/lib/zabbix
          readinessProbe:
            tcpSocket:
              port: 10051
            initialDelaySeconds: 10
          livenessProbe:
            tcpSocket:
              port: 10051
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: zabbix-proxy-data
