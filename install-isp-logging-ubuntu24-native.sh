#!/usr/bin/env bash
set -Eeuo pipefail

# Native/systemd ISP logging installer. OpenObserve is installed as a native
# binary, never in Docker. Grafana Alloy is installed from Grafana's APT repo.
#
# Usage:
#   sudo bash install-isp-logging-ubuntu24-native.sh central
#   sudo bash install-isp-logging-ubuntu24-native.sh agent
#
# central: Ubuntu 24.04 only; installs OpenObserve + Alloy.
# agent: Ubuntu 22.04/24.04; installs Alloy and forwards local logs to central.

MODE="${1:-}"
OO_BIN="/usr/local/bin/openobserve"
OO_ENV="/etc/openobserve.env"
OO_SERVICE="/etc/systemd/system/openobserve.service"
ALLOY_CONFIG="/etc/alloy/config.alloy"
ALLOY_ENV="/etc/default/alloy"
HOST_LABEL="$(hostname -s | tr -cd 'A-Za-z0-9_.-' | cut -c1-63)"
[[ -n "$HOST_LABEL" ]] || HOST_LABEL="ubuntu-host"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo -e "\n[INFO] $*"; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
[[ "$MODE" == "central" || "$MODE" == "agent" ]] || {
  echo "Usage: sudo bash $0 central"
  echo "       sudo bash $0 agent"
  exit 2
}

source /etc/os-release
if [[ "$MODE" == "central" ]]; then
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == "24.04" ]] || die "central mode requires Ubuntu 24.04."
else
  [[ "${ID:-}" == ubuntu && ( "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ) ]] || die "agent mode supports Ubuntu 22.04 or 24.04."
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) ;; *) die "Unsupported architecture: $ARCH (supported: amd64, arm64)." ;; esac

info "Installing prerequisites (this script does not install or use Docker)..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg tar acl openssl

# Install Grafana Alloy from the official Grafana APT repository.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
chmod 0644 /etc/apt/keyrings/grafana.asc
cat > /etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y alloy

install -d -m 0750 /opt/opsora /etc/alloy /var/lib/alloy
touch "$ALLOY_ENV"
chmod 0640 "$ALLOY_ENV"

set_env_file() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then grep -v -E "^${key}=" "$file" > "$tmp" || true; fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  install -m 0640 "$tmp" "$file"
  rm -f "$tmp"
}

# Let Alloy read systemd journal entries.
if getent group systemd-journal >/dev/null; then usermod -aG systemd-journal alloy || true; fi
if getent group adm >/dev/null; then usermod -aG adm alloy || true; fi

if [[ "$MODE" == "central" ]]; then
  info "Installing OpenObserve OSS as a native binary and systemd service..."
  if [[ ! -x "$OO_BIN" ]]; then
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR:-}"' EXIT
    # Official OpenObserve downloader resolves the latest stable OSS binary.
    curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve/main/downloadO2.sh -o "$TMP_DIR/downloadO2.sh"
    (cd "$TMP_DIR" && sh ./downloadO2.sh opensource)
    [[ -f "$TMP_DIR/openobserve" ]] || die "OpenObserve binary was not found after official download."
    install -o root -g root -m 0755 "$TMP_DIR/openobserve" "$OO_BIN"
    rm -rf "$TMP_DIR"
    trap - EXIT
  else
    info "Existing OpenObserve binary found; preserving it."
  fi

  if ! id -u openobserve >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/openobserve --no-create-home --shell /usr/sbin/nologin openobserve
  fi
  install -d -o openobserve -g openobserve -m 0750 /var/lib/openobserve

  if [[ ! -f "$OO_ENV" ]]; then
    read -r -p "OpenObserve admin email [admin@example.com]: " ROOT_EMAIL
    ROOT_EMAIL="${ROOT_EMAIL:-admin@example.com}"
    ROOT_PASSWORD="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"
    umask 077
    cat > "$OO_ENV" <<EOF
ZO_ROOT_USER_EMAIL=${ROOT_EMAIL}
ZO_ROOT_USER_PASSWORD=${ROOT_PASSWORD}
ZO_DATA_DIR=/var/lib/openobserve
EOF
    chmod 0600 "$OO_ENV"
    echo
    echo "Generated OpenObserve password (also saved in $OO_ENV):"
    echo "$ROOT_PASSWORD"
    echo "Save it in your password manager."
  else
    info "Existing $OO_ENV found; keeping its credentials."
  fi
  chown root:openobserve "$OO_ENV"
  chmod 0640 "$OO_ENV"
  chown root:root "$OO_BIN"
  chmod 0755 "$OO_BIN"

  cat > "$OO_SERVICE" <<'EOF'
[Unit]
Description=OpenObserve observability platform
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=openobserve
Group=openobserve
EnvironmentFile=/etc/openobserve.env
ExecStart=/usr/local/bin/openobserve
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/openobserve

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now openobserve

  set_env_file "$ALLOY_ENV" HOST_LABEL "$HOST_LABEL"
  set_env_file "$ALLOY_ENV" OPENOBSERVE_LOKI_URL "http://127.0.0.1:5080/api/default/loki/api/v1/push"
  OO_USER="$(sed -n 's/^ZO_ROOT_USER_EMAIL=//p' "$OO_ENV" | tail -n1)"
  read -r -p "OpenObserve admin email for Alloy ingestion [${OO_USER}]: " USER_INPUT
  OO_USER="${USER_INPUT:-$OO_USER}"
  read -r -s -p "OpenObserve password for Alloy: " OO_PASSWORD
  echo
  [[ -n "$OO_USER" && -n "$OO_PASSWORD" ]] || die "OpenObserve username/password required for Alloy."
  set_env_file "$ALLOY_ENV" OPENOBSERVE_USER "$OO_USER"
  set_env_file "$ALLOY_ENV" OPENOBSERVE_PASSWORD "$OO_PASSWORD"
else
  echo "This agent sends this host's logs to an existing OpenObserve instance."
  read -r -p "OpenObserve base URL (e.g. http://192.168.29.70:5080 or https://logs.example.com): " OO_BASE
  [[ "$OO_BASE" =~ ^https?:// ]] || die "URL must start with http:// or https://"
  OO_BASE="${OO_BASE%/}"
  read -r -p "OpenObserve organization [default]: " OO_ORG
  OO_ORG="${OO_ORG:-default}"
  read -r -p "OpenObserve login email: " OO_USER
  read -r -s -p "OpenObserve password: " OO_PASSWORD
  echo
  [[ -n "$OO_USER" && -n "$OO_PASSWORD" ]] || die "OpenObserve username/password required."
  set_env_file "$ALLOY_ENV" HOST_LABEL "$HOST_LABEL"
  set_env_file "$ALLOY_ENV" OPENOBSERVE_LOKI_URL "${OO_BASE}/api/${OO_ORG}/loki/api/v1/push"
  set_env_file "$ALLOY_ENV" OPENOBSERVE_USER "$OO_USER"
  set_env_file "$ALLOY_ENV" OPENOBSERVE_PASSWORD "$OO_PASSWORD"
fi

cat > "$ALLOY_CONFIG" <<'EOF'
logging {
  level  = "info"
  format = "logfmt"
}

loki.write "openobserve" {
  endpoint {
    url = sys.env("OPENOBSERVE_LOKI_URL")
    basic_auth {
      username = sys.env("OPENOBSERVE_USER")
      password = sys.env("OPENOBSERVE_PASSWORD")
    }
  }
}

local.file_match "accel_ppp" {
  path_targets = [
    {
      "__path__"       = "/var/log/accel-ppp/*.log",
      "job"            = "accel-ppp",
      "host"           = sys.env("HOST_LABEL"),
      "o2_stream_name" = "accelpp_logs",
    },
  ]
}

loki.source.file "accel_ppp" {
  targets       = local.file_match.accel_ppp.targets
  forward_to    = [loki.write.openobserve.receiver]
  tail_from_end = true
}

loki.source.journal "system_journal" {
  max_age = "12h"
  labels = {
    "job"            = "systemd-journal",
    "host"           = sys.env("HOST_LABEL"),
    "o2_stream_name" = "system_journal",
  }
  forward_to = [loki.write.openobserve.receiver]
}
EOF

# Add systemd override for environment variables and journal permissions.
install -d -m 0755 /etc/systemd/system/alloy.service.d
cat > /etc/systemd/system/alloy.service.d/opsora.conf <<'EOF'
[Service]
EnvironmentFile=/etc/default/alloy
SupplementaryGroups=systemd-journal adm
EOF

# Add narrowly scoped ACLs for Accel-PPP logs, if present.
if [[ -d /var/log/accel-ppp ]]; then
  setfacl -m u:alloy:rx /var/log/accel-ppp || true
  find /var/log/accel-ppp -maxdepth 1 -type f -name '*.log' -exec setfacl -m u:alloy:r {} + 2>/dev/null || true
  setfacl -d -m u:alloy:rx /var/log/accel-ppp || true
fi

alloy fmt "$ALLOY_CONFIG" >/dev/null
systemctl daemon-reload
systemctl enable --now alloy
systemctl restart alloy

echo
echo "Native logging installation complete."
if [[ "$MODE" == "central" ]]; then
  echo "OpenObserve UI: http://$(hostname -I | awk '{print $1}'):5080"
  echo "OpenObserve service: sudo systemctl status openobserve --no-pager"
  echo "OpenObserve logs:    sudo journalctl -u openobserve -f"
fi
echo "Alloy service:       sudo systemctl status alloy --no-pager"
echo "Alloy logs:          sudo journalctl -u alloy -f"
echo "Alloy config:        $ALLOY_CONFIG"
echo
echo "No Docker packages or containers are installed/used by this script."
echo "Restrict OpenObserve port 5080 to trusted LAN sources or a secured reverse proxy."
