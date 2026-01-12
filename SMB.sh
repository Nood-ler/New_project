#!/bin/bash

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Prompt for inputs
read -rp "Enter the full path of the mount point to share: " MOUNT_PATH
if [ ! -d "$MOUNT_PATH" ]; then
    echo "Directory does not exist. Creating..."
    mkdir -p "$MOUNT_PATH"
fi

read -rp "Enter the Samba username: " SMB_USER
read -rsp "Enter the Samba password: " SMB_PASS
echo
read -rsp "Confirm the Samba password: " SMB_PASS2
echo

if [ "$SMB_PASS" != "$SMB_PASS2" ]; then
    echo "Passwords do not match!"
    exit 1
fi

# Add system user if it doesn't exist
if ! id "$SMB_USER" &>/dev/null; then
    echo "Creating system user $SMB_USER"
    useradd -M -s /sbin/nologin "$SMB_USER"
fi

# Set ownership and permissions
chown -R "$SMB_USER":"$SMB_USER" "$MOUNT_PATH"
chmod -R 2775 "$MOUNT_PATH"

# Add Samba user
(echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -s -a "$SMB_USER"
smbpasswd -e "$SMB_USER"

# Backup existing smb.conf
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%F_%T)

# Add share to smb.conf
cat >> /etc/samba/smb.conf <<EOF

[${SMB_USER}_share]
   path = ${MOUNT_PATH}
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0664
   directory mask = 0775
EOF

# Restart Samba
systemctl restart smb nmb
systemctl enable smb nmb

echo "Samba share '${SMB_USER}_share' created for user $SMB_USER at $MOUNT_PATH"
echo "You can access it on the network now."
