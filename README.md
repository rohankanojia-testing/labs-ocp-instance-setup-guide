# Creating OCP Cluster on lab instance

## Quick Start: Automated Setup with Claude Code Skill

**NEW!** The easiest way to set up a PerformanceLabs cluster is using the Claude Code skill that automates the entire process.

### Installing the Skill

1. **Copy the skill to your Claude Code skills directory**:
   ```bash
   mkdir -p ~/.claude/skills
   cp .claude/skills/setup-performancelabs-cluster.md ~/.claude/skills/
   ```

2. **Verify installation**:
   ```bash
   ls -lh ~/.claude/skills/setup-performancelabs-cluster.md
   ```

### Using the Skill

Once installed, you can trigger the skill in a Claude Code conversation by saying:
- "Set up my performancelabs cluster"
- "Deploy OpenShift on my performancelabs instance"
- "Install my performancelabs environment"

The skill will guide you through:
1. ✅ Gathering prerequisites (bastion hostname, lab cloud, passwords)
2. ✅ Setting up the bastion with all dependencies
3. ✅ Generating hardware-specific configuration
4. ✅ Deploying Single Node OpenShift (SNO)
5. ✅ (Optional) Scaling to Multi-Node OpenShift (MNO)
6. ✅ Increasing pod capacity to 1500 per node
7. ✅ Post-installation configuration (storage, registry, DevWorkspace)

**Time to complete**: ~90 minutes for SNO, ~2 hours for MNO with 3 workers

### What You Need

Before starting, make sure you have:
- `~/Downloads/pull-secret.txt` - Your OpenShift pull secret
- `~/Downloads/smcipmitool.tar.gz` - SMC IPMI tool for hardware management
- `LAB_SSH_PASSWORD` environment variable set
- Lab allocation details (bastion hostname, cloud name, lab ID)

---

## Manual Setup Instructions

If you prefer to run the scripts manually instead of using the skill, follow the instructions below.

## Lab Access
## Lab Access
You should've received an email about environment allocation like this:

You've been allocated a new environment!

**cloud42: 3** (DevWorkSpaces Perf/Scale)

Please take note of lab name (`cloud42` in this case) as it will be used during installation.

You should've also received lab password, save it as an environment variable:

Note that machine ssh password is different from foreman password.

```shell
export LAB_SSH_PASSWORD=<your-password>
```
## Bastion Access

Accessible via VPN

```bash
sshpass -p $LAB_SSH_PASSWORD ssh root@perflab_hostname
```

Find out System Information (Find which model you're on)
```
dmidecode -t system | grep -E "Manufacturer"
```

Run `setup-bastion.sh` in order to setup bastion with SSH keys, pull secret etc:

```bash
./scripts/setup-bastion.sh my-bastion.example.com
```

## JetLag Single Node Deployment Steps

After setting up the bastion, you can deploy a Single Node OpenShift (SNO) cluster using JetLag.

**Note:** Before running the script, you need to:
1. SSH into the bastion host
2. Edit the script to set your `LAB_CLOUD` variable (e.g., `cloud42`, `cloud50`)

Run the deployment script:

```bash
./scripts/jetlag-install.sh
```

The script will:
1. Navigate to the `/root/jetlag` directory
2. Set up and activate the Python virtual environment
3. Create the Ansible inventory file
4. Set up the bastion machine
5. Deploy the Single Node OpenShift cluster

**Note:** Make sure you have the `pull-secret.txt` file in `/root/jetlag/` directory (this should have been set up by `setup-bastion.sh`).

## Scaling single node cluster to multiple nodes

To scale from a Single Node OpenShift (SNO) cluster to a Multi-Node OpenShift (MNO) cluster, you'll need to:

1. Modify the JetLag configuration to change `cluster_type` from `sno` to `mno` in your inventory/vars file
2. Set the `worker_node_count` to the desired number of worker nodes
3. Re-run the deployment playbooks with the updated configuration

**Note:** This process may require additional configuration and is typically done through JetLag's Ansible playbooks. Refer to the JetLag documentation for detailed scaling procedures.

update worker_node_count in the ansible/vars/all.yml 
```shell
worker_node_count: 1
```

Re-run inventory file:

```shell
ansible-playbook ansible/create-inventory.yml
```

Diff between old inventory and new inventory
 diff ansible/inventory/cloud42.local ansible/inventory/cloud42-backup.local


Update to `cloud42.local` move it to bottom

Update ansible/vars/scale_out.yml

```shell
cat ansible/vars/scale_out.yml
current_worker_count: 0
scale_out_count: 1
```

Takes 2 hours to complete
```shell
ansible-playbook -i ansible/inventory/cloud50.local ansible/ocp-scale-out.yml
```

## Post Installation Steps

Once OpenShift cluster has been setup you need to perform some additional steps before running load tests.

### Setting up Storage

Install the Local Storage Operator and configure local storage for your cluster:

```bash
./scripts/install-local-storage-operator.sh
```

This script will:
1. Create the `local-storage` namespace
2. Install the Local Storage Operator from the OperatorHub
3. Detect nodes with the `/dev/sdb` device
4. Create a LocalVolume resource to provision local storage
5. Set the `local-sc` StorageClass as the default storage class

**Note:** The script assumes `/dev/sdb` is available on your nodes. If your device path is different, you'll need to modify the `DEVICE_PATH` variable in the script.

After installation, you can test the local storage setup:

```bash
./scripts/test-local-storage-setup.sh
```

This test script will:
1. Create a test PersistentVolumeClaim (PVC) using the `local-sc` StorageClass
2. Create a test pod that mounts the PVC
3. Verify the storage is working by writing and reading data
4. Optionally clean up the test resources

### Increasing Max allocatable pod limits

Apply this script to increase allocatable pod limits:

```shell
./scripts/apply_kubelet_config.sh
```

### Making sure DevWorkspaceOperatorConfig is tuned to avoid intermittent errors

```shell
kubectl apply -f - <<EOF
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: devworkspace-operator-config
  namespace: openshift-operators
config:
  workspace:
    imagePullPolicy: IfNotPresent
    progressTimeout: 3600s
EOF
```
