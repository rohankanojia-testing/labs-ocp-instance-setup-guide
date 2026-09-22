# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Infrastructure automation for deploying OpenShift clusters on Red Hat PerformanceLabs bare-metal hardware, primarily for DevWorkspace Operator (DWO) performance/scale testing. It is a collection of Bash scripts and YAML manifests — not a software application. There is no build system, test framework, linter, or CI/CD pipeline.

## Running Scripts

Scripts are executed directly via bash. There is no package manager or build step.

```bash
# All scripts live in scripts/ and are run from the repo root or on the bastion
./scripts/setup-bastion.sh <bastion-hostname>

# Most scripts after setup-bastion.sh run ON the bastion, not locally
ssh root@<bastion> "cd /root/jetlag && /home/temp-scripts/create-all-yml.sh <lab-cloud> <ocp-version>"
```

There are no unit tests. The only "test" script (`test-local-storage-setup.sh`) validates live OpenShift storage on a running cluster.

## Deployment Pipeline (Script Execution Order)

The scripts form a sequential pipeline — each phase depends on the previous one completing:

1. **`setup-bastion.sh`** — Local machine → bastion. Copies SSH keys, pull-secret, IPMI tools; installs deps; clones JetLag/DWO repos.
2. **`create-all-yml.sh`** — Runs on bastion only (requires `dmidecode`). Detects hardware model (R740xd, R7425, R7525, 6029P), sets correct NIC names and disk paths, generates JetLag `all.yml`.
3. **`jetlag-install.sh`** — Deploys SNO (Single Node OpenShift) via JetLag Ansible playbooks (~60 min).
4. **Post-install** (run any/all after cluster is up):
   - `install-local-storage-operator.sh` — Production storage via LSO + LocalVolume
   - `install-local-path-provisioner.sh` — Lightweight alternative storage
   - `install-hostpath-storage-pv.sh` — Fallback HostPath PVs
   - `openshift-internal-registry-enable.sh` — Enables OCP internal image registry with external route
   - `increate_max_allocatable_pods.sh` — Raises maxPods from 250 → 1500 per node (triggers node reboot)
5. **`scale-out.sh`** — Scales SNO → MNO by adding worker nodes (~35 min per worker).
6. **`install-dwo-from-iib.sh`** — Installs DevWorkspace Operator from IIB for pre-release testing. Handles brew registry auth, ICSP, CatalogSource, Subscription, and InstallPlan approval.

## Key Architecture Details

- **JetLag** is the underlying tool — this repo wraps it with hardware-aware config generation and post-install automation. JetLag lives at `/root/jetlag` on the bastion.
- **Hardware detection** in `create-all-yml.sh` maps hardware model → NIC interfaces + disk paths. This is critical because PerformanceLabs uses multiple Dell/Supermicro models with different device naming.
- **`all.yml`** (at `ansible/vars/all.yml` in the JetLag directory) is the central config file that drives the entire deployment. It sets lab type, cloud name, cluster type, OCP version, network interfaces, and disk paths.
- **SNO-first strategy**: Always deploy SNO first, then scale out to MNO. Direct MNO deployment is not supported by these scripts.
- **Scale-out** (`scale-out.sh`) is always performed as part of standard deployment — don't wait for confirmation.

## File Conventions

- Scripts use `set -euo pipefail` and include validation of required tools/env vars at the top.
- The `.gitignore` aggressively excludes secrets: pull-secret files, SSH keys, credentials, `.env` files, and IPMI tool archives. Never commit these.
- `SKILL.md` is the comprehensive operational reference (timelines, troubleshooting, verification commands). The Claude Code skill at `.claude/skills/setup-performancelabs-cluster.md` automates the workflow interactively.

## Commit Convention

Commits follow conventional format: `feat:`, `fix:`, `refactor:` with optional scopes like `feat(storage):`, `feat(registry):`.
