#!/bin/bash

set -e
set -o pipefail

# Stores a list of successful steps
SUCCESSFUL_STEPS=()

#--------------------------------------
# UTILITY FUNCTIONS
#--------------------------------------

log_success() {
    SUCCESSFUL_STEPS+=("$1")
    echo "✅ $1 completed."
}

prompt_if_blank() {
    local var_name=$1
    local prompt_text=$2
    if [[ -z "${!var_name:-}" ]]; then
        read -p "? $prompt_text" value
        export "$var_name"="$value"
    else
        echo "ℹ $var_name already set to: ${!var_name}"
    fi
}

prompt_secret_if_blank() {
    local var_name=$1
    local prompt_text=$2
    if [[ -z "${!var_name:-}" ]]; then
        read -s -p "? $prompt_text" value
        echo
        export "$var_name"="$value"
    else
        echo "ℹ $var_name already set"
    fi
}

#--------------------------------------
# POLLING FUNCTIONS
#--------------------------------------

poll_catalogsource_until_ready() {
    local name="$1"
    local namespace="$2"
    local max_duration=$((10 * 60))  # 10 minutes in seconds
    local interval=20  # seconds between polls
    local elapsed=0

    echo "Polling CatalogSource '$name' in namespace '$namespace' for up to $((max_duration / 60)) minutes..."

    while [ "$elapsed" -lt "$max_duration" ]; do
        local status
        status=$(oc get catalogsource "$name" \
            --template '{{.status.connectionState.lastObservedState}}{{"\n"}}' \
            -n "$namespace" 2>/dev/null || echo "NOT_FOUND")

        echo "Current CatalogSource Status: $status"

        if [ "$status" == "READY" ]; then
            echo "CatalogSource is READY."
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo "Timeout reached. CatalogSource '$name' did not become READY within 10 minutes."
    return 1
}

wait_for_installplan() {
    local namespace="$1"
    local label="$2"
    local max_duration=$((10 * 60))  # 10 minutes in seconds
    local interval=10  # seconds between polls
    local elapsed=0

    echo "Waiting for InstallPlan with label '$label' in namespace '$namespace'..."

    while [ "$elapsed" -lt "$max_duration" ]; do
        local install_plan
        install_plan=$(oc get installplan -l "$label" -n "$namespace" -o jsonpath="{.items[*].metadata.name}" 2>/dev/null || echo "")

        if [[ -n "$install_plan" ]]; then
            echo "InstallPlan found: $install_plan"
            return 0
        fi

        echo "Waiting for InstallPlan to appear... (${elapsed}s elapsed)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo "Timeout reached. InstallPlan did not appear within $((max_duration / 60)) minutes."
    return 1
}

wait_for_csv_succeeded() {
    local namespace="$1"
    local operator_name="$2"
    local max_duration=$((10 * 60))  # 10 minutes in seconds
    local interval=10  # seconds between polls
    local elapsed=0

    echo "Waiting for CSV for operator '$operator_name' to reach Succeeded phase in namespace '$namespace'..."

    while [ "$elapsed" -lt "$max_duration" ]; do
        local csv_phase
        csv_phase=$(oc get csv -n "$namespace" -o json 2>/dev/null | \
            jq -r ".items[] | select(.spec.displayName == \"$operator_name\" or .metadata.name | startswith(\"$operator_name\")) | .status.phase" 2>/dev/null || echo "")

        if [[ "$csv_phase" == "Succeeded" ]]; then
            echo "CSV for '$operator_name' has reached Succeeded phase."
            return 0
        fi

        echo "Current CSV phase: ${csv_phase:-NOT_FOUND} (${elapsed}s elapsed)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo "Timeout reached. CSV for '$operator_name' did not reach Succeeded phase within $((max_duration / 60)) minutes."
    return 1
}

wait_for_deployments() {
    local namespace="$1"
    shift
    local deployments=("$@")

    echo "Waiting for deployments to be ready in namespace '$namespace'..."

    for deployment in "${deployments[@]}"; do
        echo "Checking deployment: $deployment"

        # First, wait for the deployment to exist
        local max_wait=120
        local elapsed=0
        local interval=5

        while [ "$elapsed" -lt "$max_wait" ]; do
            if oc get deployment "$deployment" -n "$namespace" &>/dev/null; then
                echo "Deployment '$deployment' exists."
                break
            fi
            echo "Waiting for deployment '$deployment' to be created... (${elapsed}s elapsed)"
            sleep "$interval"
            elapsed=$((elapsed + interval))
        done

        if [ "$elapsed" -ge "$max_wait" ]; then
            echo "Timeout: Deployment '$deployment' was not created within $max_wait seconds."
            return 1
        fi

        # Now wait for rollout
        echo "Waiting for rollout of deployment '$deployment'..."
        if ! oc rollout status deployment "$deployment" -n "$namespace" --timeout=300s; then
            echo "Deployment '$deployment' failed to become ready."
            return 1
        fi

        echo "Deployment '$deployment' is ready."
    done

    echo "All deployments are ready."
    return 0
}

re_tag_iib_image() {
    local current_image="$1"
    local new_image

    if [[ "$current_image" == "brew.registry.redhat.io/rh-osbs/iib:"* ]]; then
        echo "Image '$current_image' is already in the correct brew registry format. No action needed."
        return 0
    fi

    local tag="${current_image##*:}"
    new_image="brew.registry.redhat.io/rh-osbs/iib:$tag"

    echo "Current Image: $current_image"
    echo "New Brew Image: $new_image"
    IIB_IMAGE="$new_image"
}

#--------------------------------------
# MAIN SCRIPT
#--------------------------------------

echo "=========================================="
echo "  DWO Installation from IIB"
echo "=========================================="
echo ""

# Step 0: Collect inputs
prompt_if_blank IIB_IMAGE "Enter IIB_IMAGE (e.g., registry-proxy.engineering.redhat.com/rh-osbs/iib:12345): "
prompt_if_blank TOKEN_USERNAME "Enter TOKEN_USERNAME for brew.registry.redhat.io: "
prompt_secret_if_blank PASSWORD "Enter PASSWORD for brew.registry.redhat.io: "

re_tag_iib_image "$IIB_IMAGE"
log_success "Step 0: Image collection and tagging"

# Step 1: Setup authentication
echo ""
echo "Step 1: Setting up authentication..."
echo "Attempting to log in to brew.registry.redhat.io..."

oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > authfile

if ! echo "$PASSWORD" | podman login --authfile authfile --username "$TOKEN_USERNAME" --password-stdin brew.registry.redhat.io; then
    echo "❌ Podman login failed. Exiting."
    rm -f authfile
    exit 1
fi

echo "✅ Podman login successful. Updating pull-secret..."
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile
rm -f authfile
log_success "Step 1: Authentication configured"

# Step 2: Create ImageContentSourcePolicy
echo ""
echo "Step 2: Creating ImageContentSourcePolicy..."
cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: dwo-mirrors
spec:
  repositoryDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io
    source: registry.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
  - mirrors:
    - quay.io/redhat-user-workloads/devworkspace-tenant/devworkspace
    source: registry.redhat.io/devworkspace
EOF

echo "Waiting 10 seconds for ImageContentSourcePolicy to propagate..."
sleep 10
log_success "Step 2: ImageContentSourcePolicy created"

# Step 3: Create CatalogSource
echo ""
echo "Step 3: Creating CatalogSource..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: devworkspace-operator-testing-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${IIB_IMAGE}
  publisher: DWO Testing
  displayName: DevWorkspace Operator Catalog
EOF

echo "Waiting for CatalogSource to become ready..."
poll_catalogsource_until_ready "devworkspace-operator-testing-catalog" "openshift-marketplace"
log_success "Step 3: CatalogSource created and ready"

# Step 4: Create Subscription
echo ""
echo "Step 4: Creating Subscription with manual approval..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: devworkspace-operator
  namespace: openshift-operators
spec:
  channel: fast
  installPlanApproval: Manual
  name: devworkspace-operator
  source: devworkspace-operator-testing-catalog
  sourceNamespace: openshift-marketplace
EOF
log_success "Step 4: Subscription created"

# Step 5: Wait for and approve InstallPlan
echo ""
echo "Step 5: Waiting for InstallPlan..."
wait_for_installplan "openshift-operators" "operators.coreos.com/devworkspace-operator.openshift-operators"

INSTALL_PLAN_NAME=$(oc get installplan \
    -l operators.coreos.com/devworkspace-operator.openshift-operators \
    -n openshift-operators \
    -o jsonpath="{.items[0].metadata.name}")

echo "InstallPlan Name: $INSTALL_PLAN_NAME"
echo ""
echo "InstallPlan Details:"
oc get installplan "$INSTALL_PLAN_NAME" -n openshift-operators -o yaml

echo ""
echo "Approving InstallPlan: $INSTALL_PLAN_NAME"
oc patch installplan "$INSTALL_PLAN_NAME" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
log_success "Step 5: InstallPlan approved"

# Step 6: Wait for CSV to succeed
echo ""
echo "Step 6: Waiting for operator CSV to reach Succeeded phase..."
wait_for_csv_succeeded "openshift-operators" "DevWorkspace Operator"
log_success "Step 6: CSV reached Succeeded phase"

# Step 7: Wait for deployments to be ready
echo ""
echo "Step 7: Waiting for operator deployments to be ready..."
wait_for_deployments "openshift-operators" \
    "devworkspace-controller-manager" \
    "devworkspace-webhook-server"
log_success "Step 7: All operator deployments are ready"

# Final Summary
echo ""
echo "=========================================="
echo "🎉 Installation completed successfully!"
echo "=========================================="
echo ""
echo "Summary of completed steps:"
for step in "${SUCCESSFUL_STEPS[@]}"; do
    echo "  ✅ $step"
done
echo ""

echo "Operator Status:"
oc get csv -n openshift-operators | grep -i devworkspace || echo "No DevWorkspace CSV found"
echo ""
oc get deployment -n openshift-operators | grep -i devworkspace || echo "No DevWorkspace deployments found"
echo ""
echo "Installation complete! The DevWorkspace Operator is now running."
