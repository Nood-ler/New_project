#!/bin/bash
# setup-samba.sh
# Sets up Samba with per-user isolated shares, firewall, SELinux, and ACLs.
# Type "DONE" (uppercase) when prompted for username to finish user creation.

set -euo pipefail
IFS=$'\n\t'

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Helper: package install wrapper (dnf/yum/apt)
install_packages() {
  pkgs=("$@")
  if command -v dnf &>/dev/null; then
    dnf install -y "${pkgs[@]}" || true
  elif command -v yum &>/dev/null; then
    yum install -y "${pkgs[@]}" || true
  elif command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || true
  else
    echo "No supported package manager found (dnf/yum/apt). Please install: ${pkgs[*]}"
  fi
}

######### User input #########
read -rp "Enter the full path of the mount point to share (e.g. /srv/samba): " MOUNTPOINT
MOUNTPOINT="${MOUNTPOINT%/}"  # remove trailing slash

if [ -z "$MOUNTPOINT" ]; then
  echo "Mount point cannot be empty."
  exit 1
fi

if [ ! -d "$MOUNTPOINT" ]; then
  echo "Directory $MOUNTPOINT does not exist. Creating..."
  mkdir -p "$MOUNTPOINT"
fi

######### Functions #########

set_permissions_acls() {
  echo "Applying recommended ACLs on ${MOUNTPOINT}..."
  # Ensure group exists
  if ! getent group sambashare >/dev/null; then
    groupadd sambashare || true
  fi

  chown root:root "$MOUNTPOINT"
  chmod 0755 "$MOUNTPOINT"

  # Optional: default ACLs so new files/directories inherit group and default perms
  if command -v setfacl &>/dev/null; then
    setfacl -m g:sambashare:rwx "$MOUNTPOINT" || true
    setfacl -d -m g:sambashare:rwx "$MOUNTPOINT" || true
  else
    echo "setfacl not found; skipping default ACLs. Install acl package if you want ACLs."
  fi
}

enable_services_and_firewall() {
  echo "Installing/ensuring samba and firewall packages are present..."
  # Install samba and firewall packages if missing
  if ! rpm -q samba &>/dev/null && ! dpkg -s samba &>/dev/null; then
    install_packages samba samba-client samba-common firewalld acl
  else
    install_packages firewalld acl || true
  fi

  echo "Enabling and starting firewalld, smb and nmb..."
  # Enable/start
  systemctl enable --now firewalld || true
  # Some distros name samba service differently; attempt common names
  systemctl enable --now smb nmb 2>/dev/null || systemctl enable --now samba 2>/dev/null || true

  echo "Configuring firewall for Samba..."
  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=samba || true
    # also ensure NETBIOS ports (137-139) and samba (445) are open if service not present
    firewall-cmd --reload || true
  else
    echo "firewall-cmd not found; please ensure your firewall allows Samba (ports 137-139/udp/tcp and 445/tcp)."
  fi
}

configure_selinux_for_samba() {
  if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce || echo "Disabled")
  else
    SELINUX_STATUS="Disabled"
  fi

  if [[ "$SELINUX_STATUS" =~ Enforce|Permissive ]]; then
    echo "Configuring SELinux file contexts and booleans for Samba..."

    if ! command -v semanage &>/dev/null; then
      echo "semanage not found; attempting to install policycoreutils-python-utils or equivalents..."
      install_packages policycoreutils-python-utils policycoreutils-python python3-policycoreutils || true
    fi

    if command -v semanage &>/dev/null; then
      semanage fcontext -a -t samba_share_t "${MOUNTPOINT}(/.*)?" || true
      restorecon -Rv "${MOUNTPOINT}" || true
    else
      echo "Warning: semanage not available; cannot set SELinux filecontext automatically."
    fi

    # Set booleans so Samba can serve home-style directories and export read/write
    if command -v setsebool &>/dev/null; then
      setsebool -P samba_enable_home_dirs 1 || true
      setsebool -P samba_export_all_rw 1 || true
    fi
  else
    echo "SELinux appears disabled or not present. Skipping SELinux configuration."
  fi
}

backup_smb_conf() {
  if [ -f /etc/samba/smb.conf ]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%F_%T) || true
    echo "Backed up existing /etc/samba/smb.conf"
  else
    # create a minimal smb.conf if not exists
    cat > /etc/samba/smb.conf <<'EOF'
[global]
  workgroup = WORKGROUP
  server string = Samba Server
  security = user
EOF
    echo "Created minimal /etc/samba/smb.conf"
  fi
}

create_samba_users_and_shares() {
  echo
  echo "Creating Samba users and isolated per-user shares."
  echo "A directory ${MOUNTPOINT}/<username> will be created for each Samba user."
  echo "Type DONE (uppercase) to finish."

  # Loop until DONE
  while true; do
    read -rp "Enter username (or type DONE to finish): " USERNAME
    if [ "$USERNAME" = "DONE" ]; then
      echo "Finished creating users."
      break
    fi

    # basic validation
    if [[ -z "$USERNAME" ]]; then
      echo "Username cannot be empty. Try again."
      continue
    fi

    # If user exists, note it; otherwise create system user w/ home under mount and nologin
    if id "$USERNAME" &>/dev/null; then
      echo "System user $USERNAME exists; re-using."
    else
      echo "Creating system user $USERNAME (no login, home: ${MOUNTPOINT}/${USERNAME})..."
      useradd --home-dir "${MOUNTPOINT}/${USERNAME}" --no-create-home --shell /sbin/nologin "$USERNAME" || useradd -M -s /sbin/nologin -d "${MOUNTPOINT}/${USERNAME}" "$USERNAME" || true
    fi

    SHARE_DIR="${MOUNTPOINT}/${USERNAME}"
    mkdir -p "$SHARE_DIR"
    chown "$USERNAME":"$USERNAME" "$SHARE_DIR"
    chmod 0700 "$SHARE_DIR"

    # Prompt for Samba password interactively
    echo "Set SMB password for $USERNAME (you will be prompted twice):"
    # Use smbpasswd interactive instead of -s for better security prompt
    if command -v smbpasswd &>/dev/null; then
      smbpasswd -a "$USERNAME" || true
      smbpasswd -e "$USERNAME" || true
    else
      echo "smbpasswd command not found. Install samba client utilities (samba, samba-common-bin) and set password manually."
    fi

    # Append per-user share to smb.conf
    cat >> /etc/samba/smb.conf <<EOF

[${USERNAME}]
   path = ${SHARE_DIR}
   valid users = ${USERNAME}
   read only = no
   browsable = yes
   guest ok = no
   create mask = 0700
   directory mask = 0700
EOF

    # Ensure ACLs (user-only rwx and default)
    if command -v setfacl &>/dev/null; then
      setfacl -R -m u:"$USERNAME":rwx "$SHARE_DIR" || true
      setfacl -d -m u:"$USERNAME":rwx "$SHARE_DIR" || true
    fi

    echo "Created Samba share for $USERNAME at $SHARE_DIR"
  done

  # Validate smb configuration
  if command -v testparm &>/dev/null; then
    echo "Validating smb.conf with testparm..."
    testparm -s || true
  fi
}

restart_and_enable_services() {
  echo "Restarting and enabling Samba services..."
  # Try common service names
  systemctl restart smb nmb 2>/dev/null || systemctl restart samba 2>/dev/null || true
  systemctl enable smb nmb 2>/dev/null || systemctl enable samba 2>/dev/null || true
}

######### Main flow #########
echo "Starting Samba setup for mount point: ${MOUNTPOINT}"

# Apply permissions & ACLs
set_permissions_acls

# Ensure services and firewall
enable_services_and_firewall

# SELinux configuration
configure_selinux_for_samba

# Backup smb.conf
backup_smb_conf

# Create users and per-user shares
create_samba_users_and_shares

# Restart/enable services
restart_and_enable_services

echo "Samba setup complete. Per-user shares live under ${MOUNTPOINT}."
echo "If SELinux is enabled, verify contexts with: ls -Z ${MOUNTPOINT}"
echo "If firewall is present, Samba ports/service should be allowed."

exit 0
