#!/bin/bash

set -euo pipefail

PVC_NAME="test-local-pvc"
POD_NAME="test-local-pod"
STORAGE_CLASS="local-sc"
NAMESPACE="default"  # Change if needed

echo "🧪 Creating test PVC..."
cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $STORAGE_CLASS
  resources:
    requests:
      storage: 1Gi
EOF

echo "🚀 Creating test pod that uses the PVC..."
cat <<EOF | oc apply -n $NAMESPACE -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: busybox
    command: [ "sh", "-c", "echo Hello from local storage > /mnt/test/test.txt && cat /mnt/test/test.txt && sleep 10" ]
    volumeMounts:
    - mountPath: /mnt/test
      name: local-volume
  volumes:
  - name: local-volume
    persistentVolumeClaim:
      claimName: $PVC_NAME
EOF

echo "⏳ Waiting for pod to complete..."
oc wait --for=condition=Succeeded pod/$POD_NAME -n $NAMESPACE --timeout=300s || {
  echo "❌ Test pod failed or timed out. Dumping logs..."
  oc logs pod/$POD_NAME -n $NAMESPACE
  exit 1
}

echo "📄 Output from test pod:"
oc logs pod/$POD_NAME -n $NAMESPACE

echo "✅ Local Storage Operator is working as expected."

# Optional cleanup
read -p "🧹 Do you want to delete test pod and PVC? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  oc delete pod/$POD_NAME pvc/$PVC_NAME -n $NAMESPACE
  echo "🧽 Cleanup completed."
else
  echo "ℹ️ Resources left for inspection."
fi

