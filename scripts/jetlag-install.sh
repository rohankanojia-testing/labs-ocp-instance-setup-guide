#!/bin/bash

# --- VARIABLES ---
# Replace with your actual lab cloud name, e.g., cloud42
LAB_CLOUD="cloud50"
INVENTORY_FILE="ansible/inventory/${LAB_CLOUD}.local"

# --- MAIN SCRIPT ---
echo "Starting Jetlag OpenShift SNO deployment..."

# Step 1: Navigate to the jetlag directory
echo "Navigating to the jetlag directory..."
cd /root/jetlag || { echo "Failed to change directory. Exiting."; exit 1; }

# Step 2: Set up and activate the Python virtual environment
echo "Setting up and activating the Python virtual environment..."
source bootstrap.sh
source .ansible/bin/activate || { echo "Failed to activate virtual environment. Exiting."; exit 1; }

# Step 3: Create the Ansible inventory file
echo "Creating Ansible inventory file..."
ansible-playbook ansible/create-inventory.yml || { echo "Failed to create inventory. Exiting."; exit 1; }

# Step 4: Set up the bastion machine
echo "Setting up the bastion machine..."
ansible-playbook -i "$INVENTORY_FILE" ansible/setup-bastion.yml || { echo "Failed to set up bastion. Exiting."; exit 1; }

# Step 5: Deploy the Single Node OpenShift cluster
echo "Deploying the Single Node OpenShift cluster..."
ansible-playbook -i "$INVENTORY_FILE" ansible/sno-deploy.yml || { echo "Failed to deploy SNO cluster. Exiting."; exit 1; }

# Step 6: Configure KUBECONFIG environment variable in /root/.bashrc
echo "Configuring KUBECONFIG environment variable..."
KUBECONFIG_PATH=$(find /root/sno -name kubeconfig 2>/dev/null | head -n 1)
if [ -n "$KUBECONFIG_PATH" ]; then
    echo "Found kubeconfig at: $KUBECONFIG_PATH"
    # Remove any existing KUBECONFIG export from .bashrc
    sed -i '/export KUBECONFIG=.*\/sno\//d' /root/.bashrc
    # Add the new KUBECONFIG export
    echo "export KUBECONFIG=$KUBECONFIG_PATH" >> /root/.bashrc
    echo "KUBECONFIG environment variable added to /root/.bashrc"
else
    echo "Warning: kubeconfig not found in /root/sno directory"
fi

echo "Deployment script finished."
