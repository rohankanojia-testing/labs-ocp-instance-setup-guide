#!/usr/bin/env bash
set -Eeuo pipefail

REGISTRY_CONFIG="configs.imageregistry.operator.openshift.io/cluster"
REGISTRY_NS="openshift-image-registry"
REGISTRY_DEPLOYMENT="image-registry"

echo "🔧 Enabling OpenShift internal image registry..."

# Verify oc login
oc whoami >/dev/null 2>&1 || {
  echo "❌ Not logged into OpenShift"
  exit 1
}

# Verify registry config exists
oc get "$REGISTRY_CONFIG" >/dev/null 2>&1 || {
  echo "❌ Image registry config not found"
  exit 1
}

# -------------------------------------------------------------------
# Enable managementState
# -------------------------------------------------------------------

CURRENT_STATE=$(oc get "$REGISTRY_CONFIG" -o jsonpath='{.spec.managementState}')

if [[ "$CURRENT_STATE" != "Managed" ]]; then
  echo "➡️ Setting managementState=Managed"

  oc patch "$REGISTRY_CONFIG" \
    --type=merge \
    -p '{"spec":{"managementState":"Managed"}}'
else
  echo "✅ Registry already Managed"
fi

echo "⏳ Waiting for operator reconciliation..."

oc wait \
  --for=jsonpath='{.spec.managementState}'=Managed \
  "$REGISTRY_CONFIG" \
  --timeout=60s >/dev/null

# -------------------------------------------------------------------
# Configure storage if missing
# -------------------------------------------------------------------

STORAGE_JSON=$(oc get "$REGISTRY_CONFIG" -o jsonpath='{.spec.storage}' 2>/dev/null || true)

if [[ -z "$STORAGE_JSON" || "$STORAGE_JSON" == "{}" ]]; then
  echo "➡️ Configuring emptyDir storage (ephemeral)"

  oc patch "$REGISTRY_CONFIG" \
    --type=json \
    -p='[
      {
        "op":"replace",
        "path":"/spec/storage",
        "value":{"emptyDir":{}}
      }
    ]' || \
  oc patch "$REGISTRY_CONFIG" \
    --type=json \
    -p='[
      {
        "op":"add",
        "path":"/spec/storage",
        "value":{"emptyDir":{}}
      }
    ]'
else
  echo "✅ Storage already configured"
fi

# -------------------------------------------------------------------
# Enable external route
# -------------------------------------------------------------------

DEFAULT_ROUTE=$(oc get "$REGISTRY_CONFIG" \
  -o jsonpath='{.spec.defaultRoute}' 2>/dev/null || true)

if [[ "$DEFAULT_ROUTE" != "true" ]]; then
  echo "➡️ Enabling default route"

  oc patch "$REGISTRY_CONFIG" \
    --type=merge \
    -p '{"spec":{"defaultRoute":true}}'
else
  echo "✅ Default route already enabled"
fi

# -------------------------------------------------------------------
# Wait for deployment
# -------------------------------------------------------------------

echo "⏳ Waiting for registry deployment..."

for i in {1..30}; do
  if oc get deployment "$REGISTRY_DEPLOYMENT" -n "$REGISTRY_NS" >/dev/null 2>&1; then
    break
  fi

  sleep 5

  if [[ "$i" -eq 30 ]]; then
    echo "❌ Registry deployment never appeared"
    oc get all -n "$REGISTRY_NS" || true
    exit 1
  fi
done

# -------------------------------------------------------------------
# Wait for rollout
# -------------------------------------------------------------------

echo "⏳ Waiting for rollout completion..."

if ! oc rollout status deployment/"$REGISTRY_DEPLOYMENT" \
  -n "$REGISTRY_NS" \
  --timeout=180s; then

  echo "❌ Registry rollout failed"
  echo ""

  oc get pods -n "$REGISTRY_NS" -o wide || true

  echo ""
  echo "📜 Recent events:"
  oc get events -n "$REGISTRY_NS" \
    --sort-by=.lastTimestamp | tail -20 || true

  exit 1
fi

# -------------------------------------------------------------------
# Validate service
# -------------------------------------------------------------------

echo "🔍 Verifying registry service..."

oc get svc image-registry -n "$REGISTRY_NS" >/dev/null 2>&1 || {
  echo "❌ Registry service not found"
  exit 1
}

# -------------------------------------------------------------------
# Fetch route
# -------------------------------------------------------------------

ROUTE=$(oc get route default-route \
  -n "$REGISTRY_NS" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)

# -------------------------------------------------------------------
# Final output
# -------------------------------------------------------------------

echo ""
echo "🎉 OpenShift internal registry is ready!"
echo ""

echo "🔗 Internal endpoint:"
echo "   image-registry.openshift-image-registry.svc:5000"

if [[ -n "$ROUTE" ]]; then
  echo ""
  echo "🌐 External route:"
  echo "   $ROUTE"

  echo ""
  echo "🔐 Login command:"
  echo "   podman login $ROUTE -u \$(oc whoami) -p \$(oc whoami -t)"

  echo ""
  echo "📦 Example push:"
  echo "   podman tag alpine $ROUTE/<namespace>/alpine"
  echo "   podman push $ROUTE/<namespace>/alpine"
fi

echo ""
echo "📊 Registry status:"
oc get clusteroperator image-registry
