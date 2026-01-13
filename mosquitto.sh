#!/usr/bin/env bash
set -euo pipefail

# ---------- Variables ----------
QUADLET_DIR="/etc/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/mosquitto.container"

BASE_DIR="/opt/containers/mosquitto"
CONFIG_DIR="${BASE_DIR}/config"
DATA_DIR="${BASE_DIR}/data"
LOG_DIR="${BASE_DIR}/log"
CONF_FILE="${CONFIG_DIR}/mosquitto.conf"

IMAGE="docker.io/library/eclipse-mosquitto:latest"

# ---------- Must be root ----------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run this script as root"
  exit 1
fi

# ---------- Directories ----------
echo "[INFO] Creating directories..."
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"

# ---------- mosquitto.conf ----------
echo "[INFO] Writing mosquitto.conf..."
cat > "$CONF_FILE" <<'EOF'
# Use per-listener security settings (recommended)
per_listener_settings false

# Allow anonymous connections (not secure, for testing/demo)
allow_anonymous true

# Define a listener that accepts connections from all interfaces (default port 1883)
listener 1883 0.0.0.0

# Enable message persistence (store messages across broker restarts)
persistence true
persistence_location /mosquitto/data/

# Log to file (customize path as needed)
log_dest file /mosquitto/log/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information
EOF

# ---------- Quadlet ----------
echo "[INFO] Writing quadlet file..."
cat > "$QUADLET_FILE" <<'EOF'
[Unit]
Description=Mosquitto MQTT Broker
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=mosquitto
Image=docker.io/library/eclipse-mosquitto:latest
PublishPort=1883:1883
PublishPort=9001:9001
AutoUpdate=registry

Volume=/opt/containers/mosquitto/config:/mosquitto/config:Z
Volume=/opt/containers/mosquitto/data:/mosquitto/data:Z
Volume=/opt/containers/mosquitto/log:/mosquitto/log:Z

[Service]
Restart=on-failure
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# ---------- Activate ----------
echo "[INFO] Reloading systemd..."
systemctl daemon-reload

echo "[INFO] Pulling image..."
podman pull "$IMAGE"

echo "[INFO] Enabling and starting mosquitto.service..."
systemctl enable --now mosquitto.service

echo
echo "[INFO] Done."
echo "Check status:"
echo "  systemctl status mosquitto.service"
