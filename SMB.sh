#!/usr/bin/env bash
set -euo pipefail

# Configurable variables
MOUNTPOINT="/srv/samba"
MD_DEVICE="/dev/md0"
FS_TYPE="ext4"
FSTAB_OPTS="defaults,_netdev"
MDADM_CONF_CANDIDATES=(/etc/mdadm.conf /etc/mdadm/mdadm.conf)

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Exiting."
    exit 1
  fi
}

detect_disks() {
  echo "Detecting block devices (non-loop):"
  ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' || true)
  echo "Detected root device (will be shown but do NOT select unless intended): ${ROOT_DEV:-UNKNOWN}"
  lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk || true
  echo
  echo "Enter the devices to use for RAID (space-separated). Example: /dev/sdb /dev/sdc"
  read -r -a RAID_DEVS
  if [ "${#RAID_DEVS[@]}" -lt 2 ]; then
    echo "At least two devices are required for RAID1. Exiting."
    exit 1
  fi
  for d in "${RAID_DEVS[@]}"; do
    if [ ! -b "$d" ]; then
      echo "Device $d not found or not a block device. Exiting."
      exit 1
    fi
    if [ "$d" = "$ROOT_DEV" ]; then
      echo "WARNING: You selected the root device ($ROOT_DEV). This will destroy the running system."
      read -rp "Type EXACTLY 'I_UNDERSTAND' to continue or anything else to abort: " CONFROOT
      if [ "$CONFROOT" != "I_UNDERSTAND" ]; then
        echo "Aborted by user."
        exit 1
      fi
    fi
  done
}

install_packages() {
  echo "Installing required packages (mdadm, samba, firewall, ACL, SELinux tools)..."
  dnf install -y mdadm samba samba-client samba-common policycoreutils-python-utils firewalld acl e2fsprogs
}

stop_and_remove_existing_raid_arrays() {
  echo "Stopping any assembled md arrays (if present)..."
  for md in /dev/md*; do
    [ -e "$md" ] || continue
    mdadm --stop "$md" 2>/dev/null || true
    mdadm --remove "$md" 2>/dev/null || true
  done

  echo
  read -rp "Zero existing md superblocks on selected devices (${RAID_DEVS[*]})? (yes/NO): " ZEROCONF
  if [[ "$ZEROCONF" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    for d in "${RAID_DEVS[@]}"; do
      echo "Zeroing md superblock on $d ..."
      mdadm --zero-superblock "$d" || true
      dd if=/dev/zero of="$d" bs=512 count=2048 conv=fsync 2>/dev/null || true
    done
  else
    echo "Skipping zero-superblock step per user choice."
  fi
}

create_raid1() {
  echo "Creating RAID1 device ${MD_DEVICE} with devices: ${RAID_DEVS[*]}"
  read -rp "Final confirmation: Type YES to create RAID (this will destroy data on the devices): " CONF
  if [ "$CONF" != "YES" ]; then
    echo "Aborted by user."
    exit 1
  fi

  NUM="${#RAID_DEVS[@]}"
  mdadm --create "$MD_DEVICE" --level=1 --raid-devices="$NUM" "${RAID_DEVS[@]}" --metadata=1.2 --force

  echo "Waiting for array to become active (showing /proc/mdstat periodically)..."
  for i in {1..60}; do
    # robust extraction of "Active Devices" numeric value
    ACTIVES=$(mdadm --detail "$MD_DEVICE" 2>/dev/null | awk -F: '/Active Devices/ {gsub(/ /,"",$2); print $2}' | tr -d '[:space:]' || true)

    # only compare when ACTIVES is a valid integer
    if [[ "$ACTIVES" =~ ^[0-9]+$ ]] && [ "$ACTIVES" -eq "$NUM" ]; then
      break
    fi
    sleep 1
  done

  echo "RAID creation command issued. Array details:"
  mdadm --detail "$MD_DEVICE" || true

  for conf in "${MDADM_CONF_CANDIDATES[@]}"; do
    dirn=$(dirname "$conf")
    if [ -d "$dirn" ] || [ ! -e "$conf" ]; then
      echo "Updating mdadm config at $conf"
      mdadm --detail --scan > "$conf"
      break
    fi
  done
}

format_and_mount() {
  echo "Formatting ${MD_DEVICE} as ${FS_TYPE}"
  if [ "$FS_TYPE" = "ext4" ]; then
    mkfs.ext4 -F "$MD_DEVICE"
  else
    mkfs -t "$FS_TYPE" -F "$MD_DEVICE"
  fi

  mkdir -p "$MOUNTPOINT"
  UUID=$(blkid -s UUID -o value "$MD_DEVICE" || true)
  if [ -z "$UUID" ]; then
    FSTAB_ENTRY="${MD_DEVICE}"
  else
    FSTAB_ENTRY="UUID=${UUID}"
  fi

  cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
  echo -e "${FSTAB_ENTRY}\t${MOUNTPOINT}\t${FS_TYPE}\t${FSTAB_OPTS}\t0 0" >> /etc/fstab

  echo "Mounting ${MOUNTPOINT}"
  mount "$MOUNTPOINT"

  echo "Mount and disk usage:"
  df -h "$MOUNTPOINT" || true
}

configure_samba() {
  echo "Backing up existing smb.conf"
  cp /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%s)" || true

  cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = Rocky Samba Server
   security = user
   map to guest = bad user
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *New*password* %n\n *Retype*new*password* %n\n .
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   log level = 1
   max log size = 1000
   socket options = TCP_NODELAY SO_RCVBUF=131072 SO_SNDBUF=131072
EOF

  mkdir -p "$MOUNTPOINT"
  chown root:root "$MOUNTPOINT"
  chmod 2775 "$MOUNTPOINT"
}

create_samba_users_and_shares() {
  echo "Creating Samba users and isolated per-user shares."
  echo "A directory ${MOUNTPOINT}/<username> will be created for each Samba user."
  echo "Leave username blank to finish."

  while true; do
    read -rp "Enter username (or press Enter to finish): " USERNAME
    [ -z "$USERNAME" ] && break

    if id "$USERNAME" &>/dev/null; then
      echo "System user $USERNAME exists."
    else
      useradd --home-dir "${MOUNTPOINT}/${USERNAME}" --no-create-home --shell /sbin/nologin "$USERNAME"
    fi

    SHARE_DIR="${MOUNTPOINT}/${USERNAME}"
    mkdir -p "$SHARE_DIR"
    chown "$USERNAME:$USERNAME" "$SHARE_DIR"
    chmod 0700 "$SHARE_DIR"

    echo "Set SMB password for $USERNAME (you will be prompted):"
    smbpasswd -a "$USERNAME"
    smbpasswd -e "$USERNAME"

    cat >> /etc/samba/smb.conf <<EOF

[${USERNAME}]
   path = ${SHARE_DIR}
   valid users = ${USERNAME}
   read only = no
   browsable = no
   guest ok = no
   create mask = 0700
   directory mask = 0700
EOF

    setfacl -R -m u:"$USERNAME":rwx "$SHARE_DIR" || true
    setfacl -d -m u:"$USERNAME":rwx "$SHARE_DIR" || true

    echo "Created Samba share for $USERNAME at $SHARE_DIR"
  done

  testparm -s || true
}

set_permissions_acls() {
  echo "Applying recommended ACLs on ${MOUNTPOINT}"
  chown root:root "$MOUNTPOINT"
  chmod 2775 "$MOUNTPOINT"
  if ! getent group sambashare >/dev/null; then
    groupadd sambashare || true
  fi
}

enable_services_and_firewall() {
  echo "Enabling and starting firewalld, smb and nmb..."
  systemctl enable --now firewalld
  systemctl enable --now smb nmb
  firewall-cmd --permanent --add-service=samba
  firewall-cmd --reload
}

configure_selinux_for_samba() {
  echo "Configuring SELinux file contexts and booleans for Samba..."
  if ! command -v semanage &>/dev/null; then
    echo "semanage not found; installing policycoreutils-python-utils..."
    dnf install -y policycoreutils-python-utils || true
  fi

  if command -v semanage &>/dev/null; then
    semanage fcontext -a -t samba_share_t "${MOUNTPOINT}(/.*)?"
    restorecon -Rv "${MOUNTPOINT}" || true
  else
    echo "Warning: semanage not available; cannot set SELinux filecontext automatically."
  fi

  setsebool -P samba_enable_home_dirs 1 || true
  setsebool -P samba_export_all_rw 1 || true
}

show_raid_status() {
  echo
  echo "==== /proc/mdstat ===="
  cat /proc/mdstat || true
  echo
  echo "==== mdadm --detail ${MD_DEVICE} ===="
  mdadm --detail "${MD_DEVICE}" || true
  echo
  echo "==== Samba status and mount ===="
  mount | grep "${MOUNTPOINT}" || true
  systemctl status smb --no-pager || true
  systemctl status nmb --no-pager || true
}

main() {
  require_root
  detect_disks
  install_packages
  stop_and_remove_existing_raid_arrays
  create_raid1
  format_and_mount
  configure_samba
  create_samba_users_and_shares
  set_permissions_acls
  enable_services_and_firewall
  configure_selinux_for_samba
  show_raid_status

  echo
  echo "Done. Samba shares available under: ${MOUNTPOINT}"
}

main "$@"
