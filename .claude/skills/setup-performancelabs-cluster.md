# setup-performancelabs-cluster

Automatically setup and monitor a complete PerformanceLabs OpenShift cluster deployment.

## Trigger

Use this skill when the user wants to:
- Set up a new performancelabs cluster
- Deploy OpenShift on a performancelabs instance
- Install and configure a complete performancelabs environment

## Instructions

This skill actively executes and monitors the complete setup of a PerformanceLabs OpenShift cluster.

### Step 1: Gather Prerequisites

Ask the user for:
1. **LAB_SSH_PASSWORD** - "What is your LAB_SSH_PASSWORD?" (or check if already set in environment with `echo $LAB_SSH_PASSWORD`)
2. **Bastion hostname** - "What is your bastion hostname? (e.g., x37-h15-000-r740xd.rdu3.labs.perfscale.redhat.com)"
3. **Lab cloud name** - "What is your lab cloud name? (e.g., cloud42, cloud50, cloud52)"
4. **Lab ID** - "What is your lab ID? (usually same number as cloud name)"
5. **OCP version** (optional) - "Which OCP version? (default: latest-4.20)"

Check if required local files exist:
- Use Bash tool: `ls -lh ~/Downloads/pull-secret.txt`
- Use Bash tool: `ls -lh ~/Downloads/smcipmitool.tar.gz`
- Warn if missing but continue

### Step 2: Setup Bastion First

**IMPORTANT**: Run bastion setup BEFORE creating all.yml (the script needs to clone jetlag repo first)

1. **Make setup script executable and run it**:
   ```bash
   chmod +x ./scripts/setup-bastion.sh
   export LAB_SSH_PASSWORD='<password>'
   ./scripts/setup-bastion.sh <bastion-hostname>
   ```
   - Monitor output in real-time
   - Verify success by checking for "SETUP COMPLETE" message
   - This uploads files, installs dependencies, clones repos, and organizes everything

### Step 3: Generate all.yml Configuration on Bastion

**CRITICAL**: The create-all-yml.sh script MUST run on the bastion (it uses dmidecode to detect hardware)

1. **Run create-all-yml.sh on the bastion**:
   ```bash
   ssh root@<bastion-hostname> "cd /root/jetlag && /home/temp-scripts/create-all-yml.sh <lab-cloud> <ocp-version>"
   ```
   - This detects hardware type (R740xd, R7425, R7525, 6029P) and sets correct interfaces/disk paths
   - Verify success message: "[SUCCESS] all.yml generated"

2. **Fix missing required variables in all.yml**:
   ```bash
   # Set lab to performancelab
   ssh root@<bastion-hostname> "sed -i 's/^lab:$/lab: performancelab/' /root/jetlag/ansible/vars/all.yml"

   # Set cluster_type to sno (for Single Node OpenShift)
   ssh root@<bastion-hostname> "sed -i 's/^cluster_type:$/cluster_type: sno/' /root/jetlag/ansible/vars/all.yml"
   ```

3. **Verify the configuration**:
   ```bash
   ssh root@<bastion-hostname> "grep -E '(lab:|cluster_type:|lab_cloud:|ocp_version:|bastion_lab_interface:|bastion_controlplane_interface:|controlplane_lab_interface:|install_disk:)' /root/jetlag/ansible/vars/all.yml"
   ```
   - Check that all values are properly set (no empty values)
   - For R740xd, expect: eno3, eno1, /dev/disk/by-path/pci-0000:18:00.0-scsi-0:2:0:0

### Step 4: Deploy OpenShift Cluster

1. **Update LAB_CLOUD in jetlag-install.sh**:
   ```bash
   ssh root@<bastion-hostname> "sed -i 's/LAB_CLOUD=\".*\"/LAB_CLOUD=\"<lab-cloud>\"/' /root/jetlag/jetlag-install.sh"
   ```
   - Verify: `ssh root@<bastion-hostname> "grep 'LAB_CLOUD=' /root/jetlag/jetlag-install.sh | head -3"`

2. **Fix SSH host key verification** (required before running jetlag-install):
   ```bash
   ssh root@<bastion-hostname> "ssh-keyscan <bastion-hostname> >> ~/.ssh/known_hosts"
   ```

3. **Run JetLag installation in background**:
   ```bash
   ssh root@<bastion-hostname> "cd /root/jetlag && nohup ./jetlag-install.sh > /root/jetlag-install.log 2>&1 &"
   ```
   - Inform user: "🚀 OpenShift deployment started. This will take approximately 45-60 minutes..."
   - Monitor progress periodically:
     ```bash
     ssh root@<bastion-hostname> "tail -50 /root/jetlag-install.log"
     ```

4. **Key milestones to watch for**:
   - "Setting up and activating the Python virtual environment..."
   - "Creating Ansible inventory file..."
   - "Setting up the bastion machine..."
   - "Wait up to 40 min for nodes to be discovered"
   - "Waiting for cluster to be ready"
   - "Wait until cluster is stable"
   - "KUBECONFIG environment variable added to /root/.bashrc"
   - "Deployment script finished." ✅

5. **Verify cluster deployment**:
   ```bash
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get nodes"
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get co"
   ```
   - Check that node status is "Ready"
   - Check that all cluster operators show "AVAILABLE=True" and "DEGRADED=False"
   - Verify KUBECONFIG is in bashrc: `ssh root@<bastion-hostname> "grep -i kubeconfig ~/.bashrc"`

### Step 5: Post-Installation Configuration

Ask user: "Which storage provider do you want? (local-storage-operator / local-path-provisioner)"

1. **Install chosen storage**:
   ```bash
   ssh root@<bastion-hostname> "/home/temp-scripts/install-<chosen-storage>.sh"
   ```
   - Monitor output for success
   - Verify StorageClass: `ssh root@<bastion-hostname> "oc get sc"`

2. **Test storage (optional)**:
   - Ask user: "Do you want to test storage? (yes/no)"
   - If yes, run test script and show results

3. **Enable OpenShift internal registry**:
   ```bash
   ssh root@<bastion-hostname> "chmod +x /home/temp-scripts/openshift-internal-registry-enable.sh && /home/temp-scripts/openshift-internal-registry-enable.sh"
   ```
   - Monitor output for success messages
   - Verify registry is enabled and route is created
   - Capture and display the registry route to user

4. **Increase pod limits**:
   ```bash
   ssh root@<bastion-hostname> "/home/temp-scripts/increate_max_allocatable_pods.sh"
   ```

5. **Configure DevWorkspace** (ask user first):
   - Ask: "Are you setting this up for DevWorkspaces/DevSpaces? (yes/no)"
   - If yes, apply the DevWorkspaceOperatorConfig

### Step 6: Scale to Multi-Node (Optional)

Ask user: "Do you want to scale to multi-node? If yes, how many worker nodes?"

If user wants to scale, use the automated scale-out.sh script:

1. **Run scale-out.sh script**:
   ```bash
   ssh root@<bastion-hostname> "cd /home/temp-scripts && echo 'y' | nohup ./scale-out.sh <lab-cloud> <target-worker-count> <current-worker-count> > /root/scale-out.log 2>&1 &"
   ```

   **Parameters**:
   - `lab-cloud`: e.g., cloud52
   - `target-worker-count`: Total number of workers desired (e.g., 3)
   - `current-worker-count`: Current workers (0 for SNO, or current count for existing MNO)

   **Example**: Scale from SNO (0 workers) to 3 workers:
   ```bash
   ssh root@<bastion-hostname> "cd /home/temp-scripts && echo 'y' | nohup ./scale-out.sh cloud52 3 0 > /root/scale-out.log 2>&1 &"
   ```

2. **What the script does automatically**:
   - Updates `worker_node_count` in all.yml
   - Changes `cluster_type` from `sno` to `mno`
   - Regenerates inventory with new worker nodes
   - Runs scale-out Ansible playbook
   - Approves CSRs as workers join
   - Waits for all workers to become Ready

3. **Monitor the scale-out progress**:
   ```bash
   ssh root@<bastion-hostname> "tail -100 /root/scale-out.log"
   ```

   **Key milestones**:
   - "SCALE-OUT EXECUTION PLAN" - Shows worker counts
   - "Updating worker_node_count" - Configuration updated
   - "Regenerating inventory" - New nodes added to inventory
   - "Running scale-out playbook" - Ansible deploying workers
   - "Approving pending CSRs" - Workers joining cluster
   - "Current Worker Node Count: X" - Progress indicator
   - "[SUCCESS] Scale-Out Completed Successfully!" - Done! ✅

4. **Expected duration**:
   - Typical: 30-45 minutes for 3 worker nodes
   - Can vary based on hardware discovery and CSR approval time
   - Much faster than the estimated 2 hours if everything goes smoothly

5. **Verify scale-out completion**:
   ```bash
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get nodes"
   ```
   - All nodes should show STATUS "Ready"
   - Should see 1 control-plane + N worker nodes

   Check cluster operators are still healthy:
   ```bash
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get co"
   ```
   - All operators should be AVAILABLE=True, DEGRADED=False

6. **Increase pod capacity on ALL nodes** (CRITICAL for multi-node clusters):
   ```bash
   ssh root@<bastion-hostname> "chmod +x /home/temp-scripts/increate_max_allocatable_pods.sh && /home/temp-scripts/increate_max_allocatable_pods.sh"
   ```

   **What this does**:
   - Sets maxPods to 1500 (from default 250) on all nodes
   - Applies KubeletConfig for both master and worker machine config pools
   - Triggers a rolling reboot of ALL nodes to apply changes

   **Monitor the rolling reboot**:
   Create and run a monitoring script to watch progress:
   ```bash
   ssh root@<bastion-hostname> "cat > /root/monitor-mcp.sh << 'EOF'
#!/bin/bash
while true; do
  echo -e \"\n[\$(date '+%Y-%m-%d %H:%M:%S')]\"
  if oc get nodes &>/dev/null; then
    oc get nodes
    oc get machineconfigpools
    MASTER_UPDATED=\$(oc get mcp master -o jsonpath='{.status.updatedMachineCount}')
    MASTER_TOTAL=\$(oc get mcp master -o jsonpath='{.status.machineCount}')
    WORKER_UPDATED=\$(oc get mcp worker -o jsonpath='{.status.updatedMachineCount}')
    WORKER_TOTAL=\$(oc get mcp worker -o jsonpath='{.status.machineCount}')
    echo \"Master: \$MASTER_UPDATED/\$MASTER_TOTAL | Worker: \$WORKER_UPDATED/\$WORKER_TOTAL\"
    if [ \"\$MASTER_UPDATED\" = \"\$MASTER_TOTAL\" ] && [ \"\$WORKER_UPDATED\" = \"\$WORKER_TOTAL\" ]; then
      echo \"✅ All nodes updated!\"
      break
    fi
  else
    echo \"API unavailable (node rebooting)...\"
  fi
  sleep 30
done
EOF
chmod +x /root/monitor-mcp.sh && nohup /root/monitor-mcp.sh > /root/mcp-monitor.log 2>&1 &"
   ```

   **Check progress**:
   ```bash
   ssh root@<bastion-hostname> "tail -50 /root/mcp-monitor.log"
   ```

   **Expected duration**: 15-30 minutes for all nodes to reboot

   **Verify pod capacity after completion**:
   ```bash
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get nodes -o custom-columns='NAME:.metadata.name,MAX_PODS:.status.allocatable.pods,STATUS:.status.conditions[?(@.type==\"Ready\")].status'"
   ```
   - All nodes should show MAX_PODS=1500 and STATUS=True

### Step 7: Final Verification and Summary

1. **Run comprehensive verification**:
   ```bash
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get nodes"
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get co"
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get clusterversion"
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get sc"
   ssh root@<bastion-hostname> "source ~/.bashrc && oc get route -n openshift-image-registry"
   ```

2. **Display summary**:
   ```
   ✅ Cluster Setup Complete!

   Cluster Details:
   - Lab Cloud: <cloud-name>
   - Bastion: <hostname>
   - OCP Version: <version>
   - Cluster Type: SNO (if 0 workers) / MNO (if scaled with workers)
   - Total Nodes: <count> (1 control-plane + N workers)

   Installed Components:
   ✓ Storage: <provider>
   ✓ Registry: Enabled at <route>
   ✓ Pod Capacity: 1500 per node (increased from 250)
   ✓ DevWorkspace: Configured (if applicable)

   Access Information:
   - SSH: ssh root@<bastion-hostname>
   - KUBECONFIG: /root/sno/<node-name>/kubeconfig (auto-loaded in bashrc)
   - Console: https://<console-url>

   Next Steps:
   - Install DevSpaces operator if needed
   - Run performance/load tests
   - Configure monitoring
   ```

## Error Handling

Common issues and fixes:

1. **"Invalid lab selected"**:
   - Fix: Set `lab: performancelab` in all.yml

2. **"Invalid cluster_type selected"**:
   - Fix: Set `cluster_type: sno` (or `mno` for multi-node) in all.yml

3. **"Host key verification failed"**:
   - Fix: `ssh-keyscan <bastion-hostname> >> ~/.ssh/known_hosts` on the bastion

4. **"cannot stat 'ansible/vars/all.sample.yml'"**:
   - Fix: Must run create-all-yml.sh ON the bastion after setup-bastion.sh

5. **Ansible errors during deployment**:
   - Check: `ssh root@<bastion-hostname> "tail -100 /root/jetlag-install.log"`
   - Look for specific error messages and address them

6. **Scale-out script hangs or doesn't progress**:
   - The script has a confirmation prompt that requires 'y' input
   - Fix: Pipe 'y' to the script: `echo 'y' | nohup ./scale-out.sh ...`
   - If already running: Kill process and restart with echo 'y' piped

7. **API server unreachable after pod capacity increase**:
   - This is normal during the rolling reboot (master node reboots first)
   - Wait 5-10 minutes for master node to come back online
   - Monitor with the mcp-monitor script: `tail -f /root/mcp-monitor.log`
   - If stuck for >30 minutes, check node power status via BMC

For each command:
- Capture exit code
- If non-zero, show error output
- Attempt to diagnose from common issues list above
- Ask user if they want to retry or continue
- Provide specific troubleshooting steps

## Monitoring Strategy

For long-running operations:
- Run in background with nohup: `nohup command > logfile 2>&1 &`
- Monitor log file periodically: `tail -50 logfile`
- Show progress indicators based on log output
- Display relevant log excerpts at key milestones
- Alert user when "Deployment script finished" appears

Check deployment status every 5-10 minutes during the 45-60 minute install period.

## Interactive Prompts

Throughout the process:
- Ask for confirmation before starting 45-60 minute deployment
- Provide options where applicable (storage provider, DevWorkspace, scaling)
- Allow user to skip optional steps
- Offer to continue on non-critical errors
- Give status updates during long operations
