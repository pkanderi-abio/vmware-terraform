apiVersion: v1
kind: Namespace
metadata:
  name: registry
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-htpasswd
  namespace: registry
stringData:
  htpasswd: |
    ${htpasswd_content}
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-tls
  namespace: registry
type: kubernetes.io/tls
data:
  tls.crt: ${tls_cert_b64}
  tls.key: ${tls_key_b64}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: registry
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
  name: registry
  namespace: registry
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
        - name: registry
          image: registry:2
          ports:
            - containerPort: 5000
          env:
            - name: REGISTRY_AUTH
              value: htpasswd
            - name: REGISTRY_AUTH_HTPASSWD_REALM
              value: Registry
            - name: REGISTRY_AUTH_HTPASSWD_PATH
              value: /auth/htpasswd
            - name: REGISTRY_HTTP_TLS_CERTIFICATE
              value: /certs/tls.crt
            - name: REGISTRY_HTTP_TLS_KEY
              value: /certs/tls.key
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
            - name: auth
              mountPath: /auth
              readOnly: true
            - name: certs
              mountPath: /certs
              readOnly: true
          readinessProbe:
            tcpSocket:
              port: 5000
            initialDelaySeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: registry-data
        - name: auth
          secret:
            secretName: registry-htpasswd
        - name: certs
          secret:
            secretName: registry-tls
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  type: NodePort
  selector:
    app: registry
  ports:
    - port: 5000
      targetPort: 5000
      nodePort: ${node_port}
---
# Ingress is intentionally left unrestricted here: traffic arrives via
# NodePort (kube-proxy DNATs/SNATs it depending on externalTrafficPolicy),
# so a podSelector-based ingress rule can't reliably distinguish legitimate
# node-originated pulls without risking blocking them outright -- the
# registry is already gated by TLS + basic auth at the application layer.
# Egress is fully denied: registry:2 has no legitimate reason to ever
# initiate an outbound connection (it only serves requests and reads/writes
# its own PVC), so blocking egress entirely caps the blast radius if this
# specific container were ever compromised.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: registry-deny-egress
  namespace: registry
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress: []
