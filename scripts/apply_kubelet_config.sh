#!/bin/bash

echo "🔍 Checking Machine Config Pools..."
oc get machineconfigpools

echo "📝 Creating kubeletconfig-master.yaml..."
cat <<EOF > kubeletconfig-master.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increase-max-pods-master
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    maxPods: 2500
EOF

echo "📝 Creating kubeletconfig-worker.yaml..."
cat <<EOF > kubeletconfig-worker.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increase-max-pods-worker
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    maxPods: 2500
EOF

echo "🚀 Applying configurations..."
oc apply -f kubeletconfig-master.yaml
oc apply -f kubeletconfig-worker.yaml

echo "-------------------------------------------------------"
echo "⚠️  WARNING: Node rolling reboots are now starting!"
echo "📡 Monitor progress with: watch oc get machineconfigpools"
echo "-------------------------------------------------------"
