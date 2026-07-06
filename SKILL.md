# PerformanceLabs OpenShift Cluster Setup Guide

Complete guide for setting up and configuring OpenShift clusters in PerformanceLabs environment with DevWorkspace Operator.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Cluster Deployment](#cluster-deployment)
- [Post-Installation Configuration](#post-installation-configuration)
- [DevWorkspace Operator Installation](#devworkspace-operator-installation)
- [Scale-Out to Multi-Node](#scale-out-to-multi-node)
- [Useful Aliases](#useful-aliases)
- [Troubleshooting](#troubleshooting)
- [Scripts Reference](#scripts-reference)

---

## Overview

This guide covers the complete process of deploying an OpenShift cluster in PerformanceLabs, scaling it to multi-node, installing storage, registry, and DevWorkspace Operator from IIB.

**IMPORTANT:** Cluster scale-out from SNO to multi-node (3 workers) is **ALWAYS** performed as part of the standard deployment. Do not wait for user confirmation - proceed automatically to scale-out after initial SNO deployment completes.

**Typical Timeline:**
- Bastion setup: ~2 minutes
- SNO cluster deployment: ~60 minutes
- Post-installation config: ~20 minutes
- Scale to 3 workers: ~35 minutes
- DWO installation: ~10 minutes
- **Total: ~2 hours**

---

## Prerequisites

### Required Information

1. **Bastion hostname** (e.g., `x37-h23-000-r740xd.rdu3.labs.perfscale.redhat.com`)
2. **Lab cloud name** (e.g., `cloud02`)
3. **Lab ID** (usually same as cloud name)
4. **OCP version** (e.g., `latest-4.20`)
5. **LAB_SSH_PASSWORD** (set as environment variable)

### Required Local Files

- `~/Downloads/pull-secret.txt` - OpenShift pull secret
- `~/Downloads/smcipmitool.tar.gz` - IPMI tool for hardware management

---

## Cluster Deployment

### Step 1: Setup Bastion

The bastion setup script prepares the bastion host with all necessary tools and dependencies.

```bash
chmod +x ./scripts/setup-bastion.sh
export LAB_SSH_PASSWORD='<your-password>'
./scripts/setup-bastion.sh <bastion-hostname>
```

**What it does:**
- Copies SSH keys
- Uploads pull-secret and IPMI tools
- Installs dependencies (tmux, git, python3-pip, sshpass, k6, Node.js, chectl)
- Clones JetLag and DevWorkspace repos
- Organizes files in the correct locations

### Step 2: Generate Cluster Configuration

**CRITICAL:** The `create-all-yml.sh` script MUST run on the bastion (uses `dmidecode` to detect hardware).

```bash
ssh root@<bastion-hostname> "cd /root/jetlag && /home/temp-scripts/create-all-yml.sh <lab-cloud> <ocp-version>"
```

**Hardware Detection:**
- R740xd: eno3 (lab), eno1 (controlplane)
- R7425/R7525/6029P: Different interface mappings
- Install disk paths auto-detected

**Verify configuration:**
```bash
ssh root@<bastion-hostname> "grep -E '(lab:|cluster_type:|lab_cloud:|ocp_version:|bastion_lab_interface:|bastion_controlplane_interface:|controlplane_lab_interface:|install_disk:)' /root/jetlag/ansible/vars/all.yml"
```

### Step 3: Deploy OpenShift Cluster

```bash
ssh root@<bastion-hostname> "cd /root/jetlag && nohup ./jetlag-install.sh > /root/jetlag-install.log 2>&1 &"
```

**Monitor progress:**
```bash
ssh root@<bastion-hostname> "tail -50 /root/jetlag-install.log"
```

**Key milestones:**
1. Setting up Python virtual environment
2. Creating Ansible inventory
3. Setting up bastion machine
4. Wait up to 40 min for nodes to be discovered
5. Waiting for cluster to be ready
6. Wait until cluster is stable
7. KUBECONFIG added to bashrc
8. "Deployment script finished." ✅

**Installation Monitoring URL:**
```
http://<bastion-ip>:8080/
```

**Expected duration:** 45-60 minutes

---

## Post-Installation Configuration

### 1. Install Storage Provider

**Option 1: Local Storage Operator** (recommended for production)

```bash
ssh root@<bastion-hostname> "chmod +x /home/temp-scripts/install-local-storage-operator.sh && /home/temp-scripts/install-local-storage-operator.sh"
```

**Option 2: Local Path Provisioner** (lightweight)

```bash
ssh root@<bastion-hostname> "chmod +x /home/temp-scripts/install-local-path-provisioner.sh && /home/temp-scripts/install-local-path-provisioner.sh"
```

### 2. Enable OpenShift Internal Registry

```bash
ssh root@<bastion-hostname> "chmod +x /home/temp-scripts/openshift-internal-registry-enable.sh && /home/temp-scripts/openshift-internal-registry-enable.sh"
```

**Verify:**
```bash
oc get route -n openshift-image-registry
oc get deployment -n openshift-image-registry
```

### 3. Increase Pod Limits

Default pod limit is 250 per node. Increase to 1500 for DevWorkspace workloads:

```bash
ssh root@<bastion-hostname> "chmod +x /home/temp-scripts/increate_max_allocatable_pods.sh && /home/temp-scripts/increate_max_allocatable_pods.sh"
```

**IMPORTANT:** This triggers a rolling reboot of all nodes (15-30 minutes)

**Monitor the rolling reboot:**
```bash
watch oc get machineconfigpools
```

**Verify after completion:**
```bash
oc get nodes -o custom-columns='NAME:.metadata.name,MAX_PODS:.status.allocatable.pods,STATUS:.status.conditions[?(@.type=="Ready")].status'
```

All nodes should show `MAX_PODS=1500` and `STATUS=True`

---

## DevWorkspace Operator Installation

### Install DWO from IIB

Use the provided script to install DevWorkspace Operator from an IIB (Index Image Build):

```bash
./scripts/install-dwo-from-iib.sh
```

**Required parameters** (will prompt if not set):
- `IIB_IMAGE` - e.g., `registry-proxy.engineering.redhat.com/rh-osbs/iib:1168724`
- `TOKEN_USERNAME` - Your brew.registry.redhat.io username
- `PASSWORD` - Your brew.registry.redhat.io password

**Or set environment variables:**
```bash
export IIB_IMAGE="registry-proxy.engineering.redhat.com/rh-osbs/iib:1168724"
export TOKEN_USERNAME="your-username"
export PASSWORD="your-password"
./scripts/install-dwo-from-iib.sh
```

**What the script does:**
1. Sets up authentication with brew.registry.redhat.io
2. Creates ImageContentSourcePolicy for registry mirrors
3. Creates CatalogSource from the IIB
4. Creates Subscription with manual approval
5. Waits for and approves the InstallPlan
6. Waits for CSV to reach Succeeded phase
7. Waits for deployments to be ready

**Verify installation:**
```bash
oc get csv -n openshift-operators | grep devworkspace
oc get deployment -n openshift-operators | grep devworkspace
oc get pods -n openshift-operators | grep devworkspace
```

### Apply DevWorkspace Operator Config

Apply optimized configuration for PerformanceLabs environment:

```bash
oc apply -f ./dwoc.yaml
```

**Configuration settings:**
- `imagePullPolicy: IfNotPresent` - Avoids intermittent image pull failures
- `progressTimeout: 3600s` - Extended timeout (1 hour) for workspace startup

**Verify:**
```bash
oc get devworkspaceoperatorconfig -n openshift-operators
```

### Test DevWorkspace

Create a simple test workspace:

```bash
cat <<EOF | oc apply -f -
apiVersion: workspace.devfile.io/v1alpha2
kind: DevWorkspace
metadata:
  name: simple-test
  namespace: default
spec:
  started: true
  template:
    components:
    - name: tooling
      container:
        image: quay.io/devfile/universal-developer-image:latest
        memoryLimit: 512Mi
        memoryRequest: 256Mi
        cpuRequest: 100m
EOF
```

**Monitor:**
```bash
watch oc get devworkspace -n default
```

**Expected:** DevWorkspace reaches `Running` phase in ~90 seconds

**Cleanup:**
```bash
oc delete devworkspace simple-test -n default
```

---

## Scale-Out to Multi-Node

Scale from SNO (Single Node OpenShift) to multi-node cluster with additional workers.

### Automated Scale-Out Script

```bash
ssh root@<bastion-hostname> "cd /home/temp-scripts && echo 'y' | nohup ./scale-out.sh <lab-cloud> <target-worker-count> <current-worker-count> > /root/scale-out.log 2>&1 &"
```

**Example:** Scale from SNO (0 workers) to 3 workers:
```bash
ssh root@<bastion-hostname> "cd /home/temp-scripts && echo 'y' | nohup ./scale-out.sh cloud02 3 0 > /root/scale-out.log 2>&1 &"
```

**Parameters:**
- `lab-cloud`: Your lab cloud name (e.g., cloud02)
- `target-worker-count`: Total number of workers desired (e.g., 3)
- `current-worker-count`: Current workers (0 for SNO)

**What happens automatically:**
1. Updates `worker_node_count` in all.yml
2. Changes `cluster_type` from `sno` to `mno`
3. Regenerates inventory with new worker nodes
4. Runs scale-out Ansible playbook
5. Powers on worker nodes via BMC
6. Approves CSRs as workers join
7. Waits for all workers to become Ready

**Monitor progress:**
```bash
ssh root@<bastion-hostname> "tail -100 /root/scale-out.log"
```

**Key milestones:**
- "SCALE-OUT EXECUTION PLAN" - Shows worker counts
- "Updating worker_node_count" - Configuration updated
- "Regenerating inventory" - New nodes added
- "Running scale-out playbook" - Ansible deploying workers
- "Approving pending CSRs" - Workers joining cluster
- "Current Worker Node Count: X" - Progress indicator
- "[SUCCESS] Scale-Out Completed Successfully!" ✅

**Expected duration:** 30-45 minutes (can vary based on hardware discovery)

**Verify completion:**
```bash
oc get nodes
oc get co
```

All nodes should show STATUS "Ready" and all operators AVAILABLE=True, DEGRADED=False

### CRITICAL: Increase Pod Capacity on All Nodes

After scale-out, you MUST increase pod capacity on all nodes (including the new workers):

```bash
ssh root@<bastion-hostname> "chmod +x /home/temp-scripts/increate_max_allocatable_pods.sh && /home/temp-scripts/increate_max_allocatable_pods.sh"
```

This triggers a rolling reboot of ALL nodes to apply the maxPods=1500 setting.

---

## Useful Aliases

A comprehensive set of Kubernetes/OpenShift aliases are configured in `/root/.bashrc` on the bastion for easier cluster management.

### Quick Commands
```bash
p              # oc get pods
d <resource>   # oc delete <resource>
c <file>       # oc create -f <file>
l <pod>        # kubectl logs <pod>
gg <pattern>   # git grep -in <pattern>
```

### DevWorkspace Specific
```bash
dw             # oc get dw --all-namespaces
dwd            # oc delete dw --all
dwolog         # oc logs -lapp.kubernetes.io/name=devworkspace-controller -nopenshift-operators -f
chelog         # oc logs -lapp.kubernetes.io/component=che-operator -nopenshift-operators -f
ocop           # oc get pods -nopenshift-operators -w
```

### Resource Shortcuts
```bash
pods           # oc get pods
pod            # oc get pod
svc            # oc get svc
deploy         # oc get deploy
cm             # oc get configmap
secret         # oc get secret
ns             # oc get ns
pv             # oc get pv
pvc            # oc get pvc
sc             # oc get sc
events         # oc get events
```

### Describe Shortcuts
```bash
dp <pod>       # oc describe pod <pod>
ds <svc>       # oc describe svc <svc>
dcm <cm>       # oc describe configmap <cm>
dsecret <sec>  # oc describe secret <sec>
```

### YAML Output
```bash
py <pod>       # oc get pod <pod> -o yaml | less
deployy        # oc get deploy -o yaml
cmy            # oc get configmap -o yaml
secrety        # oc get secret -o yaml
nsy            # oc get namespace -o yaml
nodey          # oc get node -o yaml
```

**Note:** Aliases are available in interactive SSH sessions. After SSHing to the bastion, they are immediately available.

---

## Troubleshooting

### Common Issues

#### 1. "Invalid lab selected" error
**Fix:** Set `lab: performancelab` in all.yml
```bash
ssh root@<bastion> "sed -i 's/^lab:$/lab: performancelab/' /root/jetlag/ansible/vars/all.yml"
```

#### 2. "Invalid cluster_type selected" error
**Fix:** Set `cluster_type: sno` (or `mno` for multi-node) in all.yml
```bash
ssh root@<bastion> "sed -i 's/^cluster_type:$/cluster_type: sno/' /root/jetlag/ansible/vars/all.yml"
```

#### 3. "Host key verification failed"
**Fix:** Add bastion to SSH known_hosts
```bash
ssh root@<bastion> "ssh-keyscan <bastion-hostname> >> ~/.ssh/known_hosts"
```

#### 4. Scale-out script hangs at confirmation prompt
**Fix:** Pipe 'y' to the script
```bash
echo 'y' | nohup ./scale-out.sh <lab-cloud> <target> <current> > /root/scale-out.log 2>&1 &
```

#### 5. API server unreachable after pod capacity increase
**Cause:** Normal during the rolling reboot (master node reboots first)
**Fix:** Wait 5-10 minutes for master node to come back online
**Monitor:** `tail -f /root/mcp-monitor.log`

#### 6. DevWorkspace stuck in CrashLoopBackOff (project-clone)
**Cause:** Network/git access issues in isolated lab environment
**Solution:** Use DevWorkspaces without git cloning, or configure HTTP/HTTPS proxy settings

#### 7. CSV not found during DWO installation
**Check CSV status:**
```bash
oc get csv -n openshift-operators | grep devworkspace
```
**Check InstallPlan:**
```bash
oc get installplan -n openshift-operators | grep devworkspace
```

### Verification Commands

**Cluster health:**
```bash
oc get nodes
oc get co
oc get clusterversion
```

**Storage:**
```bash
oc get sc
oc get pv
oc get pvc
```

**Registry:**
```bash
oc get route -n openshift-image-registry
oc get deployment -n openshift-image-registry
```

**DevWorkspace Operator:**
```bash
oc get csv -n openshift-operators | grep devworkspace
oc get deployment -n openshift-operators | grep devworkspace
oc get pods -n openshift-operators | grep devworkspace
oc get devworkspaceoperatorconfig -n openshift-operators
```

**Pod capacity:**
```bash
oc get nodes -o custom-columns='NAME:.metadata.name,MAX_PODS:.status.allocatable.pods'
```

---

## Scripts Reference

### Created Scripts

| Script | Location | Purpose |
|--------|----------|---------|
| `setup-bastion.sh` | `./scripts/` | Setup bastion with dependencies and repos |
| `create-all-yml.sh` | `/home/temp-scripts/` (on bastion) | Generate cluster configuration with hardware detection |
| `install-local-storage-operator.sh` | `/home/temp-scripts/` (on bastion) | Install local storage operator |
| `install-local-path-provisioner.sh` | `/home/temp-scripts/` (on bastion) | Install local path provisioner |
| `openshift-internal-registry-enable.sh` | `/home/temp-scripts/` (on bastion) | Enable OpenShift internal registry |
| `increate_max_allocatable_pods.sh` | `/home/temp-scripts/` (on bastion) | Increase pod capacity to 1500 per node |
| `scale-out.sh` | `/home/temp-scripts/` (on bastion) | Scale cluster from SNO to multi-node |
| `install-dwo-from-iib.sh` | `./scripts/` | Install DevWorkspace Operator from IIB |

### Configuration Files

| File | Location | Purpose |
|------|----------|---------|
| `dwoc.yaml` | `./` | DevWorkspace Operator Config with optimized settings |
| `all.yml` | `/root/jetlag/ansible/vars/` (on bastion) | Main cluster configuration |

---

## Best Practices

### Before Starting
1. ✅ Verify required files are in `~/Downloads/`
2. ✅ Set `LAB_SSH_PASSWORD` environment variable
3. ✅ Confirm bastion hostname and lab cloud name
4. ✅ Have IIB image tag and brew.registry credentials ready

### During Deployment
1. ✅ Monitor installation via web UI: `http://<bastion>:8080/`
2. ✅ Check logs regularly: `tail -f /root/jetlag-install.log`
3. ✅ Don't interrupt the process during node discovery or cluster installation
4. ✅ Wait for "Deployment script finished" before proceeding

### After Deployment
1. ✅ Verify all cluster operators are healthy
2. ✅ Test storage by creating a PVC
3. ✅ Verify registry route is accessible
4. ✅ Confirm pod capacity is 1500 on all nodes
5. ✅ Test DevWorkspace with a simple example before production use

### Scale-Out
1. ✅ Run scale-out during a maintenance window (30-45 min)
2. ✅ Always increase pod capacity after adding workers
3. ✅ Verify all nodes are Ready before declaring success
4. ✅ Check all cluster operators remain healthy after scale-out

### DevWorkspace
1. ✅ Apply DevWorkspaceOperatorConfig for production deployments
2. ✅ Test with simple workspace before deploying complex ones
3. ✅ For git cloning issues, consider proxy configuration
4. ✅ Monitor DWO logs: `dwolog` alias

---

## Performance and Timing

### Resource Requirements

**Single Node (SNO):**
- 1 node with control-plane, master, worker roles
- Pod capacity: 1500 (after configuration)
- Suitable for development/testing

**Multi-Node (MNO):**
- 1 control-plane node + N worker nodes
- Pod capacity: 1500 × (1 + N) total
- Suitable for production workloads

### Typical Timelines

| Phase | Duration |
|-------|----------|
| Bastion setup | ~2 minutes |
| Configuration generation | <1 minute |
| SNO deployment | 45-60 minutes |
| Storage installation | 2-5 minutes |
| Registry enablement | 2-3 minutes |
| Pod capacity increase | 15-30 minutes (rolling reboot) |
| Scale to 3 workers | 30-45 minutes |
| DWO installation | 5-10 minutes |
| **Total (SNO only)** | ~1.5 hours |
| **Total (4-node MNO)** | ~2 hours |

---

## Quick Reference

### Essential URLs

**Assisted Installer Web UI:**
```
http://<bastion-hostname>:8080/
```

**OpenShift Console:**
```
https://console-openshift-console.apps.<cluster-name>.example.com
```

**Internal Registry:**
```
image-registry.openshift-image-registry.svc:5000
```

### Essential Files

**KUBECONFIG:**
```bash
/root/sno/<node-name>/kubeconfig  # Auto-loaded in bashrc
```

**Logs:**
```bash
/root/jetlag-install.log          # Initial deployment
/root/scale-out.log                # Scale-out process
```

### Quick Health Check

```bash
# Node status
oc get nodes

# Operator status
oc get co

# Cluster version
oc get clusterversion

# Storage classes
oc get sc

# Registry
oc get route -n openshift-image-registry

# DevWorkspace Operator
oc get csv -n openshift-operators | grep devworkspace
oc get deployment -n openshift-operators | grep devworkspace

# Pod capacity
oc get nodes -o custom-columns='NAME:.metadata.name,MAX_PODS:.status.allocatable.pods'
```

---

## Support and Resources

### Documentation
- JetLag: `/root/jetlag/README.md`
- DevWorkspace Operator: https://github.com/devfile/devworkspace-operator
- OpenShift Docs: https://docs.openshift.com/

### Lab Resources
- Lab Wiki: http://wiki.rdu3.labs.perfscale.redhat.com/
- Network/Interfaces Design: http://wiki.rdu3.labs.perfscale.redhat.com/usage
- Lab DevOps Team: http://wiki.rdu3.labs.perfscale.redhat.com/contact/

---

## Changelog

### 2026-07-06
- Initial documentation created
- Added complete cluster setup process
- Added DevWorkspace Operator installation from IIB
- Added scale-out procedure
- Added bash aliases
- Added troubleshooting section

---

**End of Guide**

For questions or issues, refer to the troubleshooting section or consult the PerformanceLabs DevOps team.
