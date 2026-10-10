#!/usr/bin/env bash
# Ubuntu 24.04 installer for pretty66/iptables-web.
# Installs a systemd service, listens on all IPv4 interfaces, and persists TCP/10001.
set -Eeuo pipefail
umask 077

REPO_URL="https://github.com/pretty66/iptables-web.git"
INSTALL_DIR="/opt/iptables-web"
BIN_PATH="/usr/local/bin/iptables-server"
SERVICE_NAME="iptables-web"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="/etc/${SERVICE_NAME}.env"
LISTEN_ADDRESS="${IPT_WEB_ADDRESS:-0.0.0.0:10001}"
IPT_WEB_USERNAME="${IPT_WEB_USERNAME:-admin}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run with sudo: sudo bash $0"
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
  die "This installer targets Ubuntu 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}"

if [[ -z "${IPT_WEB_PASSWORD:-}" ]]; then
  read -r -s -p "Set a strong iptables-web password (at least 16 characters): " IPT_WEB_PASSWORD
  printf '\n'
fi
[[ ${#IPT_WEB_PASSWORD} -ge 16 ]] || die "Password must be at least 16 characters."
# Keep the password safe to write into a systemd EnvironmentFile without ambiguous escaping.
[[ "$IPT_WEB_PASSWORD" =~ ^[A-Za-z0-9_@%+=.,:-]+$ ]] || \
  die "Use only letters, numbers, and these symbols in the password: _ @ % + = . , : -"

log "Installing build tools, iptables, and persistent firewall tooling"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates git golang-go build-essential iptables iptables-persistent

log "Fetching iptables-web source"
install -d -o root -g root -m 0755 "$INSTALL_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" fetch --depth=1 origin main
  git -C "$INSTALL_DIR" checkout -f FETCH_HEAD
else
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' EXIT
  git clone --depth=1 --branch main "$REPO_URL" "$tmpdir/src"
  cp -a "$tmpdir/src/." "$INSTALL_DIR/"
  rm -rf "$tmpdir"
  trap - EXIT
fi

log "Building iptables-server"
(
  cd "$INSTALL_DIR"
  commit="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  build_date="$(date '+%Y-%m-%d %H:%M:%S')"
  go build -ldflags "-s -w -X main.BuildVersion=${commit} -X 'main.BuildDate=${build_date}'" -o "$BIN_PATH" .
)
chown root:root "$BIN_PATH"
chmod 0755 "$BIN_PATH"

log "Writing protected credentials file"
cat > "$ENV_FILE" <<EOF
IPT_WEB_USERNAME=${IPT_WEB_USERNAME}
IPT_WEB_PASSWORD=${IPT_WEB_PASSWORD}
IPT_WEB_ADDRESS=${LISTEN_ADDRESS}
EOF
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

log "Installing systemd service"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=iptables Web Management Console
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH}
Restart=on-failure
RestartSec=3
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chown root:root "$UNIT_FILE"
chmod 0600 "$UNIT_FILE"

log "Allowing TCP port 10001 in the existing INPUT firewall"
# Insert before the current DROP rule. Do not flush or reset existing firewall rules.
if ! iptables -C INPUT -p tcp --dport 10001 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; then
  iptables -I INPUT 1 -p tcp --dport 10001 -m conntrack --ctstate NEW -j ACCEPT
fi

log "Saving firewall rules for persistence across reboot"
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
else
  die "netfilter-persistent is unavailable; TCP/10001 was added for this boot but could not be saved."
fi

log "Enabling and starting service"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 1
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  die "Service failed to start; inspect the logs above."
fi

log "Installation completed"
echo "Service:          systemctl status ${SERVICE_NAME}"
echo "Logs:             journalctl -u ${SERVICE_NAME} -f"
echo "LAN URL:          http://SERVER_LAN_IP:10001/"
echo "Listen address:   ${LISTEN_ADDRESS}"
echo "Firewall rule:    TCP/10001 allowed in INPUT and saved by netfilter-persistent"
echo "Credentials file: ${ENV_FILE} (root-readable only)"
echo
echo "To verify:"
echo "  sudo ss -lntp | grep 10001"
echo "  sudo iptables -C INPUT -p tcp --dport 10001 -m conntrack --ctstate NEW -j ACCEPT"
echo "  sudo netfilter-persistent save"
echo
echo "WAN reminder: if this server is behind a router, configure TCP/10001 port forwarding"
echo "to this server's LAN IP. Restrict access at the router to trusted source IPs where possible."
echo "This UI can execute firewall-management operations. Do not expose it openly to the Internet;"
echo "prefer VPN or HTTPS with additional access controls."
