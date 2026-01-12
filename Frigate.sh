#!/usr/bin/env bash
# install-frigate-quadlet.sh
# Create Podman "quadlet" container unit for Frigate and perform minimal setup.
# Run as root or via sudo.
set -euo pipefail
IFS=$'\n\t'

CONTAINER_NAME="frigate"
QUADLET_DIR="/etc/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/${CONTAINER_NAME}.container"
IMAGE="ghcr.io/blakeblackshear/frigate:stable"
FRIGATE_ROOT="/var/frigate"
MEDIA_DIR="${FRIGATE_ROOT}/media"
CONFIG_DIR="${FRIGATE_ROOT}/config"
ENV_FILE="${CONFIG_DIR}/frigate.env"
TMPFS_SIZE="1000000000"   # bytes for tmpfs-size in quadlet
SHM_SIZE="128m"
PORTS=(8971/tcp 5000/tcp 8554/tcp 8555/tcp)

# helper to run as root when invoked by non-root user
_run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "==> Ensure directories exist"
_run mkdir -p "${MEDIA_DIR}" "${CONFIG_DIR}" "${QUADLET_DIR}"
_run chown root:root "${MEDIA_DIR}" "${CONFIG_DIR}"
_run chmod 750 "${MEDIA_DIR}" "${CONFIG_DIR}"

# create a safe env file if missing (do NOT store secrets in world-readable files)
if [ ! -f "${ENV_FILE}" ]; then
  echo "==> Creating example env file at ${ENV_FILE} (edit with real credentials, chmod 600)"
  _run tee "${ENV_FILE}" > /dev/null <<EOF
# Example Frigate env (do not commit)
# FRIGATE_RTSP_PASSWORD=super-secret-rtsp
# FRIGATE_MQTT_USER=frigate
# FRIGATE_MQTT_PASSWORD=super-secret-mqtt
EOF
  _run chmod 600 "${ENV_FILE}"
else
  echo "Env file exists: ${ENV_FILE}"
fi

# Pull image (idempotent)
if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman not installed. Please install podman first."
  exit 1
fi
echo "==> Pulling image ${IMAGE}"
_run podman pull "${IMAGE}"

# Write quadlet file if missing (idempotent)
if [ -f "${QUADLET_FILE}" ]; then
  echo "Quadlet already exists: ${QUADLET_FILE} (leaving it unchanged)"
else
  echo "==> Writing quadlet to ${QUADLET_FILE}"
  _run tee "${QUADLET_FILE}" > /dev/null <<EOF
[Unit]
Description=Frigate video recorder
After=network-online.target

[Container]
ContainerName=${CONTAINER_NAME}
Image=${IMAGE}
Network=host
# Use an EnvironmentFile so secrets are not baked into the quadlet file
EnvironmentFile=${ENV_FILE}
# Mounts/Volumes - use :Z for proper SELinux label on Fedora/RHEL family
Volume=${MEDIA_DIR}:/media:Z
Volume=${CONFIG_DIR}:/config:Z
Volume=/etc/localtime:/etc/localtime:ro
# tmpfs for cache (quadlet accepts tmpfs-size in bytes)
Mount=type=tmpfs,target=/tmp/cache,tmpfs-size=${TMPFS_SIZE}
ShmSize=${SHM_SIZE}
AutoUpdate=registry

[Service]
Restart=always
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF
  _run chmod 644 "${QUADLET_FILE}"
fi

# SELinux labeling (persistent if semanage available)
if command -v semanage >/dev/null 2>&1; then
  echo "==> Applying persistent SELinux file context via semanage"
  _run semanage fcontext -a -t container_file_t "${FRIGATE_ROOT}(/.*)?" || true
  _run restorecon -Rv "${FRIGATE_ROOT}" || true
else
  echo "semanage not found: applying non-persistent chcon to ${FRIGATE_ROOT}"
  _run chcon -Rt container_file_t "${FRIGATE_ROOT}" || true
  echo "Install policycoreutils-python-utils (or equivalent) for persistent semanage support."
fi

# Open ports if firewalld is active
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  echo "==> Adding firewalld rules"
  for p in "${PORTS[@]}"; do
    _run firewall-cmd --permanent --zone=public --add-port="${p}" || true
  done
  _run firewall-cmd --reload
else
  echo "firewalld not present or not active — skipping firewall changes"
fi

# Reload systemd, enable and start the generated service
SERVICE="containers-${CONTAINER_NAME}.service"
echo "==> Reloading systemd daemon"
_run systemctl daemon-reload

echo "==> Done."
cat <<EOF

Notes:
- The quadlet is at: ${QUADLET_FILE}
- The service created is: ${SERVICE}
- Edit ${ENV_FILE} and ${CONFIG_DIR}/config.yml to configure cameras and credentials.
- To view logs: journalctl -u ${SERVICE} -f
- To inspect container: podman ps -a --filter name=${CONTAINER_NAME}
EOF

