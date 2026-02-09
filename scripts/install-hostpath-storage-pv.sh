#!/bin/bash
# Script to create HostPath PVs for nodes without local PVs
# Fully OpenShift-compatible (no oc debug), uses DirectoryOrCreate

# Variables
BASE_DIR="/tmp/hostpath-storage"
STORAGE_CLASS="hostpath-sc"
PV_SIZE="100Gi"

# Get nodes that already have a PV
PV_NODES=$(oc get pv -o json | jq -r '.items[].spec.nodeAffinity.required.nodeSelectorTerms[].matchExpressions[].values[]')

# Get nodes without a PV
NODES=$(oc get nodes -o json | jq -r --argjson pv_nodes "$(echo $PV_NODES | jq -R -s -c 'split(" ")')" '
  .items[] | select(.metadata.name as $node | ($pv_nodes | index($node) | not)) | .metadata.name
')

if [[ -z "$NODES" ]]; then
  echo "All nodes already have PVs. Nothing to do."
  exit 0
fi

echo "Creating HostPath PVs for nodes: $NODES"

for NODE in $NODES; do
  NODE_DIR="$BASE_DIR/$NODE"

  PV_NAME="hostpath-pv-$NODE"

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV_NAME
spec:
  capacity:
    storage: $PV_SIZE
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: $STORAGE_CLASS
  hostPath:
    path: $NODE_DIR
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - $NODE
EOF

  echo "HostPath PV $PV_NAME created for node $NODE (directory will be created automatically when PV is used)"
done

echo "All HostPath PVs applied successfully."

oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hostpath-sc
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
reclaimPolicy: Delete
EOF

oc patch storageclass hostpath-sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
