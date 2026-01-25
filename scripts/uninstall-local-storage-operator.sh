#!/bin/bash

# Configuration
NAMESPACE="local-storage"
OPERATOR_NAME="local-storage-operator"

echo "### Starting Local Storage Operator Cleanup ###"

# 1. Delete the LocalVolume instances (this triggers PV deletion)
echo "Deleting LocalVolume CRs..."
oc delete localvolume --all -n $NAMESPACE --timeout=60s

# 2. Delete the Subscription and CSV
echo "Removing Operator Subscription and CSV..."
CSV_NAME=$(oc get subscription $OPERATOR_NAME -n $NAMESPACE -o jsonpath='{.status.installedCSV}' 2>/dev/null)
oc delete subscription $OPERATOR_NAME -n $NAMESPACE
if [ ! -z "$CSV_NAME" ]; then
    oc delete clusterserviceversion $CSV_NAME -n $NAMESPACE
fi

# 3. Delete the Operator Group
oc delete operatorgroup -n $NAMESPACE --all

# 4. Remove Finalizers from PVs if they are stuck
# LSO often leaves 'storage.openshift.com/lso-symlink-deleter'
echo "Cleaning up stuck PV finalizers..."
for pv in $(oc get pv -o jsonpath='{.items[?(@.metadata.labels.storage\.openshift\.com/owner-kind=="LocalVolume")].metadata.name}'); do
    echo "Patching PV: $pv"
    oc patch pv $pv -p '{"metadata":{"finalizers":null}}' --type=merge
done

# 5. Delete CRDs
echo "Deleting Local Storage CRDs..."
oc delete crd localvolumes.local.storage.openshift.io \
             localvolumediscoveries.local.storage.openshift.io \
             localvolumediscoveryresults.local.storage.openshift.io

# 6. Optional: Clean up the host directories
# This requires a DaemonSet or manual ssh. LSO leaves symlinks in /mnt/local-storage
echo "HINT: To completely clean host nodes, you must remove /mnt/local-storage/"
echo "Example: oc debug node/<node-name> -- chroot /host rm -rf /mnt/local-storage"

echo "### Cleanup Complete ###"
