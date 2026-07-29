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
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
            - name: auth
              mountPath: /auth
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
