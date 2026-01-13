#!/usr/bin/env bash
# install-mosquitto-quadlet.sh
# Idempotent-ish installer: creates quadlet & mosquitto config for a user-level quadlet,
# installs podman if missing, installs the quadlet and starts/enables the service.
set -euo pipefail

# --- Configurable variables (edit if you want different names/locations) ---
QUADLET_FILENAME="mosquitto.container"
QUADLET_TMP="/tmp/${QUADLET_FILENAME}"
QUADLET_NAME="mosquitto"
XDG_CONF_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QUADLET_TARGET_DIR="${XDG_CONF_HOME}/containers/systemd"
MOSQ_HOST_BASE="$HOME/containers/mosquitto"
MOSQ_CONFIG_DIR="${MOSQ_HOST_BASE}/config"
MOSQ_DATA_DIR="${MOSQ_HOST_BASE}/data"
MOSQ_LOG_DIR="${MOSQ_HOST_BASE}/log"
MOSQ_CONF_FILE="${MOSQ_CONFIG_DIR}/mosquitto.conf"
IMAGE="docker.io/library/eclipse-mosquitto:latest"

# The .container content you provided (keeps exact contents)
read -r -d '' CONTAINER_CONTENT || true <<'EOF'
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
Volume=%h/containers/mosquitto/config:/mosquitto/config:Z
Volume=%h/containers/mosquitto/data:/mosquitto/data:Z
Volume=%h/containers/mosquitto/log:/mosquitto/log:Z

[Service]
Restart=on-failure
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target default.target
EOF

# The mosquitto.conf content you provided
read -r -d '' MOSQUITTO_CONF_CONTENT || true <<'EOF'
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

# --- helper functions ---
log() { printf '\e[1;32m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[WARN]\e[0m %s\n' "$*"; }
err() { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*"; }

# detect package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  echo ""
}

install_pkgs() {
  local pkgs=("$@")
  local pm="$1"; shift
  case "$pm" in
    apt)
      sudo apt-get update
      sudo apt-get install -y "${pkgs[@]:1}"
      ;;
    dnf)
      sudo dnf -y install "${pkgs[@]:1}"
      ;;
    yum)
      sudo yum -y install "${pkgs[@]:1}"
      ;;
    pacman)
      sudo pacman -Syu --noconfirm "${pkgs[@]:1}"
      ;;
    zypper)
      sudo zypper --non-interactive install "${pkgs[@]:1}"
      ;;
    apk)
      sudo apk add "${pkgs[@]:1}"
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Main ---
log "Starting Mosquitto (Podman + Quadlet) installer..."

# 1) Ensure directories
log "Creating host directories under ${MOSQ_HOST_BASE}..."
mkdir -p "${MOSQ_CONFIG_DIR}" "${MOSQ_DATA_DIR}" "${MOSQ_LOG_DIR}" "${QUADLET_TARGET_DIR}"
chmod 700 "${MOSQ_HOST_BASE}" || true

# 2) Write mosquitto.conf
log "Writing mosquitto.conf to ${MOSQ_CONF_FILE}..."
cat > "${MOSQ_CONF_FILE}" <<'EOF'
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

# 3) Check podman
if ! command -v podman >/dev/null 2>&1; then
  log "podman not found. Attempting to install podman using package manager..."
  PM="$(detect_pkg_manager)"
  if [ -z "$PM" ]; then
    warn "No supported package manager detected on this system. Please install podman manually and re-run this script."
  else
    case "$PM" in
      apt) PKGS=(apt podman podman-plugins) ;;
      dnf) PKGS=(dnf podman podman-plugins) ;;
      yum) PKGS=(yum podman podman-plugins) ;;
      pacman) PKGS=(pacman podman) ;;
      zypper) PKGS=(zypper podman podman-plugins) ;;
      apk) PKGS=(apk podman) ;;
      *) PKGS=("$PM" podman) ;;
    esac
    if install_pkgs "${PKGS[@]}"; then
      log "Installed podman (and possible plugins)."
    else
      warn "Automatic install failed; please install podman (and podman-plugins if available) and re-run this script."
    fi
  fi
else
  log "podman is already installed."
fi

# Check for podman quadlet support
if podman quadlet --help >/dev/null 2>&1; then
  log "podman quadlet is available."
else
  warn "podman quadlet subcommand not available. Quadlet support is expected in Podman 4.4+. If your distro ships an older podman, you may need to upgrade Podman or install quadlet support/package."
fi

# 4) Write quadlet file to a temp file, then use podman quadlet install (preferred)
log "Creating temporary quadlet file ${QUADLET_TMP}..."
cat > "${QUADLET_TMP}" <<'EOF'
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
Volume=%h/containers/mosquitto/config:/mosquitto/config:Z
Volume=%h/containers/mosquitto/data:/mosquitto/data:Z
Volume=%h/containers/mosquitto/log:/mosquitto/log:Z

[Service]
Restart=on-failure
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target default.target
EOF

# 5) Install the quadlet (this places it into ~/.config/containers/systemd by default)
if command -v podman >/dev/null 2>&1; then
  if podman quadlet install "${QUADLET_TMP}" --replace >/dev/null 2>&1; then
    log "Quadlet installed into ${QUADLET_TARGET_DIR} (via podman quadlet install)."
  else
    warn "podman quadlet install failed — attempting to copy the file directly into ${QUADLET_TARGET_DIR}."
    cp -f "${QUADLET_TMP}" "${QUADLET_TARGET_DIR}/${QUADLET_FILENAME}"
    log "Quadlet copied to ${QUADLET_TARGET_DIR}/${QUADLET_FILENAME}."
    # try reload
    systemctl --user daemon-reload || true
  fi
else
  # if podman not available, just place file so user can run the install later
  cp -f "${QUADLET_TMP}" "${QUADLET_TARGET_DIR}/${QUADLET_FILENAME}"
  log "Podman not installed: quadlet file created at ${QUADLET_TARGET_DIR}/${QUADLET_FILENAME}. Install podman and run 'podman quadlet install ${QUADLET_TARGET_DIR}/${QUADLET_FILENAME}' or 'systemctl --user daemon-reload'."
fi

# Clean up temp file
rm -f "${QUADLET_TMP}"

# 6) Pre-pull the image (best-effort)
if command -v podman >/dev/null 2>&1; then
  log "Pulling Mosquitto image (${IMAGE})..."
  podman pull "${IMAGE}" || warn "podman pull failed — image may be pulled automatically on first start."
fi

# 7) Enable & start the service (user service)
log "Attempting to enable and start the user service 'mosquitto.service'..."
if systemctl --user enable --now "${QUADLET_NAME}.service" >/dev/null 2>&1; then
  log "Service enabled and started: ${QUADLET_NAME}.service (user)."
else
  warn "Failed to enable/start ${QUADLET_NAME}.service via systemctl --user. You may need to run:"
  echo "  systemctl --user daemon-reload"
  echo "  systemctl --user enable --now ${QUADLET_NAME}.service"
  echo ""
  echo "If you want the service to run across reboots without logging in, run (as root):"
  echo "  sudo loginctl enable-linger ${USER}"
fi

log "All done. Mosquitto config is at: ${MOSQ_CONF_FILE}"
log "Host data directory: ${MOSQ_DATA_DIR}"
log "Host log directory: ${MOSQ_LOG_DIR}"
log ""
log "Useful commands:"
echo "  # Check service status"
echo "  systemctl --user status ${QUADLET_NAME}.service"
echo ""
echo "  # Start / stop"
echo "  systemctl --user start  ${QUADLET_NAME}.service"
echo "  systemctl --user stop   ${QUADLET_NAME}.service"
echo ""
echo "  # If you want the unit system-wide (root), copy the .container to /etc/containers/systemd/ and then run:"
echo "  #   sudo systemctl daemon-reload"
echo "  #   sudo systemctl enable --now ${QUADLET_NAME}.service"
echo ""
log "Installer finished."

