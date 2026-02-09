#!/bin/bash

#===============================================================================
# OCP Worker Node Scale-Out Utility
#===============================================================================
# This script automates the process of scaling out OpenShift worker nodes using
# Jetlag/Ansible by:
#   1. Updating worker node count in configuration
#   2. Regenerating inventory with new nodes
#   3. Executing the scale-out playbook
#
# Usage: scale-out.sh <labid> <new_worker_count> [current_worker_count]
#
# Arguments:
#   labid                Lab/Cloud ID (e.g., cloud41, cloud42)
#   new_worker_count     Target number of worker nodes
#   current_worker_count Current number of workers (optional, default: 0)
#
# Example:
#   ./scale-out.sh cloud42 5 2
#   ./scale-out.sh cloud41 3
#===============================================================================

set -euo pipefail

# --- Command-line Arguments ---
LABID="${1:-}"
NEW_WORKER_COUNT="${2:-}"
CURRENT_WORKER_COUNT="${3:-0}"

# --- Path Configuration ---
JETLAG_ROOT="/root/jetlag"
VENV_PATH="${JETLAG_ROOT}/.ansible/bin/activate"
VARS_FILE="${JETLAG_ROOT}/ansible/vars/all.yml"
SCALE_VARS="${JETLAG_ROOT}/ansible/vars/scale_out.yml"
INVENTORY_PATH="${JETLAG_ROOT}/ansible/inventory/${LABID}.local"
BACKUP_PATH="${JETLAG_ROOT}/ansible/inventory/${LABID}-backup.local"

# --- Color Codes (for better readability) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#===============================================================================
# Helper Functions
#===============================================================================

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_step() {
    echo ""
    echo -e "${BLUE}==>${NC} Step $1: $2"
}

show_usage() {
    cat << EOF
Usage: $(basename "$0") <labid> <new_worker_count> [current_worker_count]

OCP Worker Node Scale-Out Utility

ARGUMENTS:
    labid                    Lab/Cloud ID (e.g., cloud41, cloud42)
    new_worker_count         Target number of worker nodes
    current_worker_count     Current number of workers (optional, default: 0)

EXAMPLES:
    # Scale to 5 worker nodes in cloud42 lab
    $(basename "$0") cloud42 5

    # Scale from 2 to 5 workers in cloud42
    $(basename "$0") cloud42 5 2

    # Fresh deployment with 3 workers
    $(basename "$0") cloud41 3

ENVIRONMENT VARIABLES:
    JETLAG_ROOT              Override Jetlag installation path (default: /root/jetlag)

EOF
    exit 0
}

# Validate command-line arguments
validate_args() {
    # Check if help is requested or insufficient arguments
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]] || [[ $# -lt 2 ]]; then
        show_usage
    fi

    # Check if lab ID is provided
    if [[ -z "$LABID" ]]; then
        print_error "Lab ID is required as the first argument."
        echo "Usage: $(basename "$0") <labid> <new_worker_count> [current_worker_count]"
        exit 1
    fi

    # Check if worker count is provided
    if [[ -z "$NEW_WORKER_COUNT" ]]; then
        print_error "Target worker count is required as the second argument."
        echo "Usage: $(basename "$0") <labid> <new_worker_count> [current_worker_count]"
        exit 1
    fi

    # Update paths based on LABID
    INVENTORY_PATH="${JETLAG_ROOT}/ansible/inventory/${LABID}.local"
    BACKUP_PATH="${JETLAG_ROOT}/ansible/inventory/${LABID}-backup.local"
}

# Validate prerequisites
validate_prerequisites() {
    print_step 0 "Validating Prerequisites"

    # Validate worker count is a positive integer
    if ! [[ "$NEW_WORKER_COUNT" =~ ^[0-9]+$ ]] || [[ "$NEW_WORKER_COUNT" -lt 1 ]]; then
        print_error "Worker node count must be a positive integer (got: $NEW_WORKER_COUNT)"
        exit 1
    fi

    # Validate current worker count
    if ! [[ "$CURRENT_WORKER_COUNT" =~ ^[0-9]+$ ]]; then
        print_error "Current worker count must be a non-negative integer (got: $CURRENT_WORKER_COUNT)"
        exit 1
    fi

    # Check if scaling down
    if [[ "$NEW_WORKER_COUNT" -le "$CURRENT_WORKER_COUNT" ]]; then
        print_warning "New worker count ($NEW_WORKER_COUNT) is less than or equal to current count ($CURRENT_WORKER_COUNT)"
        print_warning "This script is designed for scaling OUT. Scaling down requires different procedures."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Operation cancelled by user."
            exit 0
        fi
    fi

    # Check if Jetlag directory exists
    if [[ ! -d "$JETLAG_ROOT" ]]; then
        print_error "Jetlag directory not found at: $JETLAG_ROOT"
        print_info "Please ensure Jetlag is installed or set JETLAG_ROOT environment variable."
        exit 1
    fi

    # Check if virtual environment exists
    if [[ ! -f "$VENV_PATH" ]]; then
        print_error "Python virtual environment not found at: $VENV_PATH"
        print_info "Please run 'cd $JETLAG_ROOT && source bootstrap.sh' first."
        exit 1
    fi

    # Check if vars file exists
    if [[ ! -f "$VARS_FILE" ]]; then
        print_error "Variables file not found at: $VARS_FILE"
        exit 1
    fi

    print_success "All prerequisites validated"
}

# Show execution plan
show_execution_plan() {
    echo ""
    echo "==============================================================================="
    echo "                       SCALE-OUT EXECUTION PLAN"
    echo "==============================================================================="
    echo "  Lab ID:                 $LABID"
    echo "  Current Worker Count:   $CURRENT_WORKER_COUNT"
    echo "  Target Worker Count:    $NEW_WORKER_COUNT"
    echo "  Workers to Add:         $((NEW_WORKER_COUNT - CURRENT_WORKER_COUNT))"
    echo "  Inventory Path:         $INVENTORY_PATH"
    echo "==============================================================================="
    echo ""
}

# Confirm with user
confirm_execution() {
    read -p "Proceed with scale-out? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Operation cancelled by user."
        exit 0
    fi
}

# Platform-agnostic sed in-place editing
sed_inplace() {
    local pattern="$1"
    local file="$2"

    # Check if we're on macOS (requires empty string arg for -i)
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}

# Activate virtual environment
activate_venv() {
    print_step 1 "Activating Python Virtual Environment"

    # shellcheck disable=SC1090
    source "$VENV_PATH"
    print_success "Virtual environment activated"
}

# Update worker count in vars file
update_worker_count() {
    print_step 2 "Updating Worker Count in Configuration"

    print_info "File: $VARS_FILE"
    print_info "Setting worker_node_count to: $NEW_WORKER_COUNT"

    sed_inplace "s/worker_node_count:.*/worker_node_count: $NEW_WORKER_COUNT/" "$VARS_FILE"

    print_success "Configuration updated"
}

# Backup current inventory
backup_inventory() {
    print_step 3 "Backing Up Current Inventory"

    if [[ -f "$INVENTORY_PATH" ]]; then
        print_info "Creating backup..."
        cp "$INVENTORY_PATH" "$BACKUP_PATH"
        print_success "Backup created: $BACKUP_PATH"
    else
        print_warning "No existing inventory found at: $INVENTORY_PATH"
        print_info "This appears to be a fresh deployment."
    fi
}

# Generate new inventory
generate_inventory() {
    print_step 4 "Generating New Inventory"

    cd "$JETLAG_ROOT" || exit 1
    if ansible-playbook ansible/create-inventory.yml; then
        print_success "Inventory generated successfully"
    else
        print_error "Inventory generation failed"
        exit 1
    fi
}

# Show inventory diff
show_inventory_diff() {
    print_step 5 "Comparing Inventory Changes"

    if [[ -f "$BACKUP_PATH" && -f "$INVENTORY_PATH" ]]; then
        echo "--- Inventory Changes ---"
        if diff "$INVENTORY_PATH" "$BACKUP_PATH"; then
            print_info "No changes detected in inventory"
        else
            print_info "Differences shown above (this is expected when adding nodes)"
        fi
        echo "--- End of Changes ---"
    else
        print_info "Skipping diff (backup or new inventory not found)"
    fi
}

# Update scale-out variables
update_scale_vars() {
    print_step 6 "Updating Scale-Out Variables"

    print_info "File: $SCALE_VARS"

    cat > "$SCALE_VARS" <<EOF
current_worker_count: $CURRENT_WORKER_COUNT
scale_out_count: $NEW_WORKER_COUNT
EOF
    print_success "Scale-out variables updated"
}

# Execute scale-out playbook
execute_scale_out() {
    print_step 7 "Executing OCP Scale-Out Playbook"

    print_warning "This operation may take 1-2 hours to complete."
    print_info "Starting playbook execution..."

    START_TIME=$SECONDS

    cd "$JETLAG_ROOT" || exit 1
    if ansible-playbook -i "$INVENTORY_PATH" ansible/ocp-scale-out.yml; then
        DURATION=$((SECONDS - START_TIME))
        HOURS=$((DURATION / 3600))
        MINUTES=$(((DURATION % 3600) / 60))
        SECS=$((DURATION % 60))

        echo ""
        echo "==============================================================================="
        print_success "Scale-Out Completed Successfully!"
        echo "  Total Duration: ${HOURS}h ${MINUTES}m ${SECS}s"
        echo "  Lab ID:         $LABID"
        echo "  Worker Nodes:   $CURRENT_WORKER_COUNT -> $NEW_WORKER_COUNT"
        echo "==============================================================================="
    else
        print_error "Scale-out playbook failed"
        print_info "Check ansible logs for details"
        exit 1
    fi
}

# Cleanup function
cleanup() {
    # Deactivate virtual environment if it was activated
    if declare -f deactivate > /dev/null; then
        deactivate 2>/dev/null || true
    fi
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    # Check for help or validate arguments first
    if [[ $# -lt 2 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show_usage
    fi

    # Set up cleanup trap
    trap cleanup EXIT

    # Validate arguments
    validate_args "$@"

    # Show header
    echo "==============================================================================="
    echo "          OCP Worker Node Scale-Out Utility"
    echo "==============================================================================="

    # Validate prerequisites
    validate_prerequisites

    # Show execution plan
    show_execution_plan

    # Confirm with user
    confirm_execution

    # Execute scale-out steps
    activate_venv
    update_worker_count
    backup_inventory
    generate_inventory
    show_inventory_diff
    update_scale_vars
    execute_scale_out
}

# Run main function
main "$@"
