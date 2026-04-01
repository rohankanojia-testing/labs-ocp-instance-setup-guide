#!/usr/bin/env bash
set -euo pipefail

echo "🔧 Enabling OpenShift internal image registry..."

# Ensure config exists
if ! oc get configs.imageregistry.operator.openshift.io cluster >/dev/null 2>&1; then
  echo "❌ Image registry config not found"
  exit 1
fi

# Enable registry (if not already)
CURRENT_STATE=$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}')

if [[ "$CURRENT_STATE" != "Managed" ]]; then
  echo "➡️ Setting managementState to Managed"
  oc patch configs.imageregistry.operator.openshift.io cluster \
    --type=merge \
    -p '{"spec":{"managementState":"Managed"}}'
else
  echo "✅ Registry already Managed"
fi

# Ensure storage (use emptyDir if not configured)
STORAGE_TYPE=$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.storage}')

if [[ -z "$STORAGE_TYPE" || "$STORAGE_TYPE" == "null" ]]; then
  echo "➡️ Configuring emptyDir storage (ephemeral)"
  oc patch configs.imageregistry.operator.openshift.io cluster \
    --type=merge \
    -p '{"spec":{"storage":{"emptyDir":{}}}}'
else
  echo "✅ Storage already configured"
fi

# Ensure route is enabled
DEFAULT_ROUTE=$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.defaultRoute}')

if [[ "$DEFAULT_ROUTE" != "true" ]]; then
  echo "➡️ Enabling default route"
  oc patch configs.imageregistry.operator.openshift.io cluster \
    --type=merge \
    -p '{"spec":{"defaultRoute":true}}'
else
  echo "✅ Default route already enabled"
fi

echo "⏳ Waiting for registry rollout..."

# Wait for deployment to be ready
oc rollout status deployment/image-registry -n openshift-image-registry --timeout=120s || {
  echo "⚠️ Registry rollout check failed, printing debug info..."
  oc get pods -n openshift-image-registry
  exit 1
}

echo "🔍 Verifying service..."
oc get svc -n openshift-image-registry | grep image-registry || {
  echo "❌ Registry service not found"
  exit 1
}

echo "🔍 Fetching route..."
ROUTE=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)

echo ""
echo "🎉 OpenShift internal registry is ready!"
echo ""

if [[ -n "$ROUTE" ]]; then
  echo "🌐 External route:"
  echo "   $ROUTE"
fi

echo "🔗 Internal endpoint:"
echo "   image-registry.openshift-image-registry.svc:5000"

echo ""
echo "🔐 Login command:"
echo "   podman login $ROUTE -u \$(oc whoami) -p \$(oc whoami -t)"

echo ""
echo "📦 Example push:"
echo "   podman tag alpine $ROUTE/<namespace>/alpine"
echo "   podman push $ROUTE/<namespace>/alpine"
