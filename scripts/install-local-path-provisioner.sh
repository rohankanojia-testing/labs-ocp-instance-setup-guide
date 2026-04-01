#!/bin/bash
set -e

# --- CONFIGURATION ---
NAMESPACE="local-path-storage"
SC_NAME="local-path"
TEST_PVC_COUNT=2  # Small count for initial verification
UBI_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal"

echo "🚀 Starting Local Path Provisioner setup for OpenShift (R740xd Lab)..."

# 1. Create Namespace
oc create namespace $NAMESPACE || true

# 2. Fix OpenShift Security (SCC)
echo "🔒 Adjusting Security Context Constraints (SCC)..."
oc adm policy add-scc-to-user hostaccess -z local-path-provisioner-service-account -n $NAMESPACE
oc adm policy add-scc-to-user privileged -z local-path-provisioner-service-account -n $NAMESPACE

# 3. Deploy Provisioner
echo "📦 Deploying Provisioner Base..."
oc apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# 4. Apply the CORRECT ConfigMap (The one that worked for DevWorkspace)
echo "🛠 Applying Golden ConfigMap (UBI + 0777 + SELinux)..."
cat <<EOF | oc apply -f -
kind: ConfigMap
apiVersion: v1
metadata:
  name: local-path-config
  namespace: $NAMESPACE
data:
  config.json: |-
    {
      "nodePathMap":[
        {
          "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths":["/tmp/local-path-provisioner"]
        }
      ]
    }
  setup: |-
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "\$VOL_DIR"
    chcon -Rt container_file_t "\$VOL_DIR" || true
  teardown: |-
    #!/bin/sh
    set -eu
    rm -rf "\$VOL_DIR"
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
      - name: helper-pod
        image: $UBI_IMAGE
        securityContext:
          privileged: true
EOF

# 5. Restart Provisioner to pick up ConfigMap changes
echo "🔄 Restarting Provisioner Pod..."
oc delete pod -l app=local-path-provisioner -n $NAMESPACE

# 6. Wait for Pod to be Ready
echo "⏳ Waiting for provisioner to be ready..."
oc rollout status deployment/local-path-provisioner -n $NAMESPACE --timeout=60s

# 7. Set as Default StorageClass
echo "🛠 Setting $SC_NAME as default..."
oc patch storageclass $SC_NAME -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# --- THE VERIFICATION TEST ---
echo "🧪 Running Test ($TEST_PVC_COUNT UBI Pods)..."

for i in $(seq 1 $TEST_PVC_COUNT); do
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-$i
  namespace: $NAMESPACE
  labels:
    test: local-path-verify
spec:
  accessModes: [ "ReadWriteOnce" ]
  storageClassName: $SC_NAME
  resources:
    requests:
      storage: 128Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-$i
  namespace: $NAMESPACE
  labels:
    test: local-path-verify
spec:
  containers:
  - name: writer
    image: $UBI_IMAGE
    command: ["/bin/bash", "-c", "echo 'Storage success' > /data/test.log && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc-$i
EOF
done

echo "✅ Test pods submitted. Watch status with: oc get pods -n $NAMESPACE -l test=local-path-verify"
