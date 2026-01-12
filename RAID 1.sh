#!/bin/bash

# =======================
# Global Variables
# =======================
RAID_ARRAY_NAME="/dev/md0"
FILESYSTEM_TYPE="ext4"
DEFAULT_MOUNT_POINT="/mnt/raid1_share"
DEFAULT_OWNER="nobody:nogroup"
DEFAULT_CHMOD="0775"

# =======================
# Error handling
# =======================
error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

# =======================
# Root check
# =======================
check_root() {
  echo "-------------------------------------------------------------------"
  echo "  Checking for root privileges..."
  if [ "$EUID" -ne 0 ]; then
    echo "  ERROR: This script must be run as root."
    echo "  Use: sudo ./$(basename "$0")"
    echo "-------------------------------------------------------------------"
    exit 1
  fi
  echo "  Root privileges confirmed."
  echo "-------------------------------------------------------------------"
}

# =======================
# mdadm check (Debian)
# =======================
check_mdadm() {
  echo "  Checking for 'mdadm' package..."
  if ! dpkg -s mdadm &>/dev/null; then
    echo "  'mdadm' not found. Installing..."
    apt update && apt install -y mdadm \
      || error_exit "Failed to install mdadm."
    echo "  'mdadm' installed successfully."
  else
    echo "  'mdadm' is already installed."
  fi
  echo "-------------------------------------------------------------------"
}

clear
echo "-------------------------------------------------------------------"
echo "  --- Starting RAID 1 Array Configuration Script (Debian) ---"
echo "-------------------------------------------------------------------"
echo ""
echo "  WARNING: THIS WILL ERASE ALL DATA ON THE SELECTED DISKS!"
echo ""
sleep 3

check_root
check_mdadm

# =======================
# Disk selection
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- Disk Selection for RAID 1 ---"
echo "-------------------------------------------------------------------"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
echo ""

read -rp "  Enter FIRST disk (e.g., /dev/sdb): " DEVICE1
read -rp "  Enter SECOND disk (e.g., /dev/sdc): " DEVICE2

if [[ -z "$DEVICE1" || -z "$DEVICE2" ]]; then
  error_exit "Both disk paths are required."
elif [[ ! -b "$DEVICE1" || ! -b "$DEVICE2" ]]; then
  error_exit "Invalid block device(s)."
elif [[ "$DEVICE1" == "$DEVICE2" ]]; then
  error_exit "Disks must be different."
fi

echo ""
echo "  Selected disks: $DEVICE1 and $DEVICE2"
read -rp "  Confirm? (y/N): " confirm
confirm=${confirm:-N}
[[ "$confirm" =~ ^[Yy]$ ]] || error_exit "Cancelled."

# =======================
# Zero superblocks
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- Zeroing Superblocks ---"
echo "-------------------------------------------------------------------"
read -rp "  THIS DESTROYS DATA. Continue? (y/N): " confirm_zero
confirm_zero=${confirm_zero:-N}
[[ "$confirm_zero" =~ ^[Yy]$ ]] || error_exit "Cancelled."

mdadm --zero-superblock "$DEVICE1" || true
mdadm --zero-superblock "$DEVICE2" || true
sleep 2

# =======================
# Create RAID
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- Creating RAID 1 Array ---"
echo "-------------------------------------------------------------------"
mdadm --create "$RAID_ARRAY_NAME" \
  --level=1 \
  --raid-devices=2 \
  "$DEVICE1" "$DEVICE2" \
  || error_exit "RAID creation failed."

cat /proc/mdstat
sleep 5

# =======================
# Persist RAID (Debian)
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- Saving RAID Configuration ---"
echo "-------------------------------------------------------------------"
mdadm --detail --scan > /etc/mdadm/mdadm.conf \
  || error_exit "Failed to save mdadm.conf"

update-initramfs -u \
  || error_exit "Failed to update initramfs"

sleep 2

# =======================
# Format RAID
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- Formatting RAID Array ---"
echo "-------------------------------------------------------------------"
mkfs.$FILESYSTEM_TYPE "$RAID_ARRAY_NAME" \
  || error_exit "Formatting failed"

sleep 2

# =======================
# Mount & fstab
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- Mount Configuration ---"
echo "-------------------------------------------------------------------"
read -rp "  Mount point [$DEFAULT_MOUNT_POINT]: " CUSTOM_MOUNT_POINT
CUSTOM_MOUNT_POINT=${CUSTOM_MOUNT_POINT:-$DEFAULT_MOUNT_POINT}

mkdir -p "$CUSTOM_MOUNT_POINT" || error_exit "mkdir failed"

echo "$RAID_ARRAY_NAME $CUSTOM_MOUNT_POINT $FILESYSTEM_TYPE defaults 0 0" \
  >> /etc/fstab || error_exit "fstab update failed"

mount "$CUSTOM_MOUNT_POINT" || error_exit "Mount failed"
sleep 2

# =======================
# Permissions
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- Permissions ---"
echo "-------------------------------------------------------------------"
read -rp "  Owner [$DEFAULT_OWNER]: " CUSTOM_OWNER
CUSTOM_OWNER=${CUSTOM_OWNER:-$DEFAULT_OWNER}
chown -R "$CUSTOM_OWNER" "$CUSTOM_MOUNT_POINT" || true

read -rp "  Permissions [$DEFAULT_CHMOD]: " CUSTOM_CHMOD
CUSTOM_CHMOD=${CUSTOM_CHMOD:-$DEFAULT_CHMOD}
chmod "$CUSTOM_CHMOD" "$CUSTOM_MOUNT_POINT" || true

# =======================
# Verification
# =======================
clear
echo "-------------------------------------------------------------------"
echo "  --- RAID 1 SETUP COMPLETE ---"
echo "-------------------------------------------------------------------"
echo " RAID Array : $RAID_ARRAY_NAME"
echo " Devices    : $DEVICE1 $DEVICE2"
echo " Filesystem : $FILESYSTEM_TYPE"
echo " Mount      : $CUSTOM_MOUNT_POINT"
echo ""
df -h "$CUSTOM_MOUNT_POINT"
echo ""
cat /proc/mdstat
echo ""
lsblk -f
echo ""
echo " RAID is persistent and will mount on boot."
echo "-------------------------------------------------------------------"

exit 0
