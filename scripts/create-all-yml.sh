#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="ansible/vars/all.sample.yml"
OUTPUT="ansible/vars/all.yml"

LAB_CLOUD="${1:-cloud08}"
OCP_VERSION="${2:-latest-4.20}"

cp "$TEMPLATE" "$OUTPUT"

echo "[INFO] Using lab_cloud=$LAB_CLOUD"
echo "[INFO] Using ocp_version=$OCP_VERSION"

# -----------------------------
# Detect hardware
# -----------------------------
PRODUCT=$(dmidecode -t system | awk -F: '/Product Name/ {print $2}' | xargs)

BASTION_LAB_IF="eno8303"
BASTION_CP_IF="ens3f0"
CONTROLPLANE_IF="eno8303"
INSTALL_DISK="/dev/disk/by-path/pci-0000:05:00.0-ata-1"

case "$PRODUCT" in
  *"R740xd"*)
    BASTION_LAB_IF="eno3"
    BASTION_CP_IF="eno1"
    CONTROLPLANE_IF="eno3"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:18:00.0-scsi-0:2:0:0"
    ;;
  *"R7425"*)
    BASTION_LAB_IF="eno3"
    BASTION_CP_IF="eno1"
    CONTROLPLANE_IF="eno3"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:e2:00.0-scsi-0:2:0:0"
    ;;
  *"R7525"*)
    BASTION_LAB_IF="eno1"
    BASTION_CP_IF="enp33np0"
    CONTROLPLANE_IF="eno1"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:01:00.0-scsi-0:2:0:0"
    ;;
  *"6029P"*)
    BASTION_LAB_IF="eno1"
    BASTION_CP_IF="enp95s0f0"
    CONTROLPLANE_IF="eno1"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:00:11.5-ata-5"
    ;;
esac

# -----------------------------
# Validate disk
# -----------------------------
if [[ ! -e "$INSTALL_DISK" ]]; then
  echo "[ERROR] Disk not found: $INSTALL_DISK"
  ls -l /dev/disk/by-path/ || true
  exit 1
fi

# -----------------------------
# Replace values (preserve comments)
# -----------------------------

# lab_cloud
sed -i "s/^lab_cloud:.*/lab_cloud: ${LAB_CLOUD}/" "$OUTPUT"

# ocp_version
sed -i "s/^ocp_version:.*/ocp_version: \"${OCP_VERSION}\"/" "$OUTPUT"

# worker_node_count (force 3 like your example)
sed -i "s/^worker_node_count:.*/worker_node_count: 3/" "$OUTPUT"

# -----------------------------
# Uncomment + set interfaces
# -----------------------------

sed -i "s|^# bastion_lab_interface:.*|bastion_lab_interface: ${BASTION_LAB_IF}|" "$OUTPUT"
sed -i "s|^# bastion_controlplane_interface:.*|bastion_controlplane_interface: ${BASTION_CP_IF}|" "$OUTPUT"
sed -i "s|^# controlplane_lab_interface:.*|controlplane_lab_interface: ${CONTROLPLANE_IF}|" "$OUTPUT"

# -----------------------------
# Append extra vars (clean block)
# -----------------------------

cat >> "$OUTPUT" <<EOF

control_plane_install_disk: ${INSTALL_DISK}
worker_install_disk: ${INSTALL_DISK}
sno_install_disk: ${INSTALL_DISK}
cluster_network_host_prefix:
- 20
cluster_network_cidr:
- 10.128.0.0/14
EOF

echo "[SUCCESS] all.yml generated exactly like template style"
