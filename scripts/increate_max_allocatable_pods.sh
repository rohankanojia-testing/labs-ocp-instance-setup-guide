#!/bin/bash

# =========================
# Configuration
# =========================
MAX_PODS=1500 


echo "Setting maxPods to: $MAX_PODS"
echo

# =========================
# Master Nodes
# =========================
cat << EOF > kubeletconfig-master.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increase-max-pods-master
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    maxPods: ${MAX_PODS}
EOF

echo "Created kubeletconfig-master.yaml with maxPods: ${MAX_PODS}"

# =========================
# Worker Nodes
# =========================
cat << EOF > kubeletconfig-worker.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increase-max-pods-worker
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    maxPods: ${MAX_PODS}
EOF

echo "Created kubeletconfig-worker.yaml with maxPods: ${MAX_PODS}"

# =========================
# Apply Configurations
# =========================
echo "Applying KubeletConfig for master nodes..."
oc apply -f kubeletconfig-master.yaml

echo "Applying KubeletConfig for worker nodes..."
oc apply -f kubeletconfig-worker.yaml

echo "-------------------------------------------------------"
echo "⚠️  WARNING: Node rolling reboots are now starting!"
echo "📡 Monitor progress with: watch oc get machineconfigpools"
echo "-------------------------------------------------------"
