#!/bin/bash

set -euo pipefail

NAMESPACE="local-storage"
DEVICE_PATH="/dev/sdb"
STORAGE_CLASS_NAME="local-sc"

echo "📦 Creating namespace: $NAMESPACE"
oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc create ns "$NAMESPACE"
sleep 10

echo "🧩 Creating OperatorGroup..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-storage-operatorgroup
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
EOF

echo "📥 Creating Subscription for Local Storage Operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: $NAMESPACE
spec:
  channel: stable
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "⏳ Waiting for Local Storage Operator deployment to be ready..."
sleep 10
oc -n "$NAMESPACE" rollout status deployment/local-storage-operator --timeout=10m

echo "🔍 Detecting nodes with device $DEVICE_PATH..."

NODE_LIST=()

# Get list of worker nodes (or all nodes)
ALL_NODES=$(oc get nodes --no-headers -o custom-columns=":metadata.name")

for NODE in $ALL_NODES; do
  echo "   🔎 Checking $NODE..."
  if oc debug node/"$NODE" -- chroot /host ls "$DEVICE_PATH" &>/dev/null; then
    echo "      ✅ Found $DEVICE_PATH on $NODE"
    NODE_LIST+=("$NODE")
  else
    echo "      ❌ $DEVICE_PATH not found on $NODE"
  fi
done

if [ "${#NODE_LIST[@]}" -eq 0 ]; then
  echo "🚫 Error: No nodes found with device path $DEVICE_PATH. Aborting."
  exit 1
fi

echo "🛠 Generating LocalVolume manifest with node list..."

TMPFILE=$(mktemp)

cat <<EOF > "$TMPFILE"
apiVersion: local.storage.openshift.io/v1
kind: LocalVolume
metadata:
  name: local-disks
  namespace: $NAMESPACE
spec:
  managementState: Managed
  logLevel: Normal
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
EOF

for NODE in "${NODE_LIST[@]}"; do
  echo "        - $NODE" >> "$TMPFILE"
done

cat <<EOF >> "$TMPFILE"
  storageClassDevices:
  - storageClassName: $STORAGE_CLASS_NAME
    volumeMode: Filesystem
    fsType: xfs
    devicePaths:
    - $DEVICE_PATH
EOF

echo "🚀 Applying LocalVolume configuration..."
oc apply -f "$TMPFILE"
rm "$TMPFILE"

echo "Making this as default StorageClass for all PVCs on this cluster"
oc patch storageclass local-sc \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'


echo "✅ Local Storage Operator installation and LocalVolume setup completed successfully."
