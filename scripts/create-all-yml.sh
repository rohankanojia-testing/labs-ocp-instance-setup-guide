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
# Stable trailing portion of the install disk's by-path name. Used to
# re-detect the disk when the controller's PCI address differs from the
# hard-coded default (see disk resolution below).
DISK_SUFFIX="ata-1"

case "$PRODUCT" in
  *"R740xd"*)
    BASTION_LAB_IF="eno3"
    BASTION_CP_IF="eno1"
    CONTROLPLANE_IF="eno3"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:18:00.0-scsi-0:2:0:0"
    DISK_SUFFIX="scsi-0:2:0:0"
    ;;
  *"R7425"*)
    BASTION_LAB_IF="eno3"
    BASTION_CP_IF="eno1"
    CONTROLPLANE_IF="eno3"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:e2:00.0-scsi-0:2:0:0"
    DISK_SUFFIX="scsi-0:2:0:0"
    ;;
  *"R7525"*)
    BASTION_LAB_IF="eno1"
    BASTION_CP_IF="enp33np0"
    CONTROLPLANE_IF="eno1"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:01:00.0-scsi-0:2:0:0"
    DISK_SUFFIX="scsi-0:2:0:0"
    ;;
  *"6029P"*)
    BASTION_LAB_IF="eno1"
    BASTION_CP_IF="enp95s0f0"
    CONTROLPLANE_IF="eno1"
    INSTALL_DISK="/dev/disk/by-path/pci-0000:00:11.5-ata-5"
    DISK_SUFFIX="ata-5"
    ;;
esac

# -----------------------------
# Resolve + validate install disk
# -----------------------------
# The RAID/SATA controller can enumerate at different PCI addresses on
# otherwise-identical hardware (e.g. R740xd units observed at both
# pci-0000:18:00.0 and pci-0000:86:00.0). Prefer the known per-model path,
# but if it is absent fall back to the first by-path device whose name ends
# in the same disk suffix so a shifted PCI address does not break generation.
# Partition entries (…-part1) do not end in the bare suffix, so they are
# naturally excluded.
if [[ ! -e "$INSTALL_DISK" ]]; then
  echo "[WARN] Preferred install disk not found: $INSTALL_DISK"
  echo "[INFO] Auto-detecting by-path device ending in '${DISK_SUFFIX}'..."
  detected=""
  for candidate in /dev/disk/by-path/*"${DISK_SUFFIX}"; do
    if [[ -e "$candidate" ]]; then
      detected="$candidate"
      break
    fi
  done
  if [[ -n "$detected" ]]; then
    INSTALL_DISK="$detected"
    echo "[INFO] Using detected install disk: $INSTALL_DISK"
  else
    echo "[ERROR] Disk not found: no /dev/disk/by-path entry ending in '${DISK_SUFFIX}'"
    ls -l /dev/disk/by-path/ || true
    exit 1
  fi
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

# lab (required by jetlag validation)
sed -i "s/^lab:$/lab: performancelab/" "$OUTPUT"

# cluster_type (required by jetlag validation - sno for Single Node OpenShift)
sed -i "s/^cluster_type:$/cluster_type: sno/" "$OUTPUT"

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

echo "[SUCCESS] all.yml generated with the following configuration:"
echo "  - lab: performancelab"
echo "  - cluster_type: sno"
echo "  - lab_cloud: ${LAB_CLOUD}"
echo "  - ocp_version: ${OCP_VERSION}"
echo "  - Hardware detected: ${PRODUCT}"
echo "  - Install disk: ${INSTALL_DISK}"
