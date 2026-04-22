#!/bin/bash
# =============================================================================
# 🔵 Part 2 — ISP Monitoring Stack
# accel-exporter  →  Prometheus  →  Grafana
# Run AFTER part1-accel-ppp.sh has completed successfully.
# =============================================================================
set -euo pipefail

############################
# EDIT THESE IF NEEDED
# (should match Part 1 values)
############################
LAN_IF="ens34"
WAN_IF="ens33"
IP_POOL_START="10.10.0.2"
IP_POOL_END="10.10.50.254"
GW_IP="10.10.0.1"
WAN_UPLINK_MBIT=1000

CPU_CORES=$(nproc)
THREAD_COUNT=$(( CPU_CORES * 4 ))

# Grafana admin password — CHANGE after first login
GRAFANA_ADMIN_PASS="AccelPPP@ISP!"

# Port accel-exporter listens on
EXPORTER_PORT=9101

# Prometheus scrape bind (127.0.0.1 = local only; 0.0.0.0 = all interfaces)
PROMETHEUS_BIND="127.0.0.1"

# Management subnet allowed to access Grafana (port 3000) and Prometheus (port 9090)
# Set to 0.0.0.0/0 to allow from anywhere, or e.g. 192.168.29.0/24 to restrict
MGMT_SUBNET="0.0.0.0/0"

############################
# PREFLIGHT CHECK
############################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root." >&2
  exit 1
fi

# Warn if accel-ppp is not running
if ! systemctl is-active --quiet accel-ppp 2>/dev/null; then
  echo "⚠️  WARNING: accel-ppp service not running."
  echo "   Run part1-accel-ppp.sh first, then re-run this script."
  echo "   Continuing anyway — exporter will connect once accel-ppp starts."
  sleep 3
fi

############################
# ACCEL-EXPORTER
# Prometheus exporter for Accel-PPP
# Source: https://github.com/taihen/accel-exporter
# Reads metrics via accel-cmd → exposes /metrics on :9101
############################

echo ""
echo ">>> Installing accel-exporter (Prometheus exporter)..."

# Install Go from official source.
# Ubuntu 22.04 ships Go 1.18 — too old. accel-exporter needs Go 1.21+
# (uses the 'slices' stdlib package added in Go 1.21).
GO_VERSION="1.22.5"
if /usr/local/go/bin/go version 2>/dev/null | grep -qE 'go1\.(2[1-9]|[3-9][0-9])'; then
  echo ">>> Go already >= 1.21: $(/usr/local/go/bin/go version)"
else
  echo ">>> Installing Go ${GO_VERSION} from golang.org..."
  cd /tmp
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf go.tar.gz
  rm -f go.tar.gz
  ln -sf /usr/local/go/bin/go    /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  echo ">>> Go installed: $(/usr/local/go/bin/go version)"
fi
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="/root/go"
export GOMODCACHE="/root/go/pkg/mod"
cd /usr/src

# Build accel-exporter from source
cd /usr/src
if [ ! -d "accel-exporter" ]; then
  git clone https://github.com/taihen/accel-exporter.git
fi

cd accel-exporter
git fetch origin
git checkout main && git pull origin main
echo ">>> accel-exporter commit: $(git rev-parse HEAD)"

# Build the binary
go build -o /usr/local/bin/accel-exporter ./cmd/accel-exporter/
chmod 755 /usr/local/bin/accel-exporter

# Dedicated unprivileged user for the exporter
if ! id -u accel-exporter &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin accel-exporter
fi

# Give the exporter user access to the accel-ppp CLI socket
# The socket is owned by root:root — add the user to the group,
# or use a wrapper. Simplest: run exporter as root (or same user as accel-pppd).
# For production: create a dedicated group and share the socket.
usermod -aG root accel-exporter   # tighten this later if desired

# Copy the Grafana dashboard to a known location
DASHBOARD_DIR="/etc/accel-exporter/dashboards"
mkdir -p "$DASHBOARD_DIR"
if [ -f "/usr/src/accel-exporter/dashboards/dashboard.json" ]; then
  cp /usr/src/accel-exporter/dashboards/*.json "$DASHBOARD_DIR/"
  echo ">>> Grafana dashboard saved to: $DASHBOARD_DIR"
fi

############################
# ACCEL-EXPORTER SYSTEMD SERVICE
############################
# NOTE: accel-cmd path after Accel-PPP install is /usr/local/sbin/accel-cmd
# The exporter connects to the CLI socket we configured in [cli] section.
# We pass --accel-cmd-path so it calls accel-cmd with the UNIX socket flag.

ACCEL_CMD_PATH="/usr/local/sbin/accel-cmd"
EXPORTER_LISTEN=":9101"
EXPORTER_CLI_SOCK="/var/run/accel-ppp/cli.sock"

cat > /etc/systemd/system/accel-exporter.service <<EOF
[Unit]
Description=Accel-PPP Prometheus Exporter
Documentation=https://github.com/taihen/accel-exporter
After=network.target accel-ppp.service
Requires=accel-ppp.service

[Service]
User=accel-exporter
Group=root
ExecStart=$ACCEL_CMD_PATH \
  --accel-cmd-path=$ACCEL_CMD_PATH \
  --accel-cmd-socket=$EXPORTER_CLI_SOCK \
  --web.listen-address=$EXPORTER_LISTEN \
  --web.telemetry-path=/metrics
Restart=on-failure
RestartSec=10s
NoNewPrivileges=yes
ProtectSystem=strict
ReadOnlyPaths=/usr/local/sbin

[Install]
WantedBy=multi-user.target
EOF

# Fix: the binary to run is accel-exporter, not accel-cmd
sed -i "s|ExecStart=$ACCEL_CMD_PATH|ExecStart=/usr/local/bin/accel-exporter|" \
  /etc/systemd/system/accel-exporter.service

############################
# FIREWALL: allow Prometheus to scrape port 9101
# ONLY from localhost or your Prometheus server IP
# Change 127.0.0.1 to your Prometheus server IP if remote
############################
PROMETHEUS_IP="127.0.0.1"
iptables -A INPUT -s "$PROMETHEUS_IP" -p tcp --dport 9101 -j ACCEPT
netfilter-persistent save

############################
# PROMETHEUS SCRAPE CONFIG HINT
############################
mkdir -p /etc/accel-exporter
cat > /etc/accel-exporter/prometheus-scrape.yml <<EOF
# Add this block to your Prometheus prometheus.yml under scrape_configs:
scrape_configs:
  - job_name: 'accel-ppp'
    static_configs:
      - targets: ['localhost:9101']
    scrape_interval: 30s
    scrape_timeout: 10s
EOF

############################
# START EXPORTER
############################
systemctl daemon-reload
systemctl enable accel-exporter
systemctl restart accel-exporter

# ============================================================
# PROMETHEUS INSTALL
# Binary install from official GitHub releases (latest stable)
# Runs as dedicated 'prometheus' user on port 9090
# ============================================================
echo ""
echo ">>> Installing Prometheus..."

# Fetch the latest stable release version dynamically
PROM_VERSION=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest \
  | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')

echo ">>> Prometheus version: $PROM_VERSION"

# Create prometheus user and directories
useradd --system --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true
mkdir -p /etc/prometheus /var/lib/prometheus
chown prometheus:prometheus /var/lib/prometheus

# Download and extract into a fixed directory — avoids all versioned dirname guessing
PROM_EXTRACT="/tmp/prometheus-extract"
rm -rf "$PROM_EXTRACT"
mkdir -p "$PROM_EXTRACT"
cd /tmp

echo ">>> Downloading Prometheus ${PROM_VERSION}..."
curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
  -o prometheus.tar.gz

# Extract stripping the top-level versioned directory — contents land directly in $PROM_EXTRACT
tar -xzf prometheus.tar.gz --strip-components=1 -C "$PROM_EXTRACT"
rm -f prometheus.tar.gz

echo ">>> Extracted files:"
ls "$PROM_EXTRACT"

# Sanity check — make sure key files are present
# Sanity check — only binaries required (consoles removed in Prometheus v3)
for f in prometheus promtool; do
  if [ ! -e "${PROM_EXTRACT}/${f}" ]; then
    echo "ERROR: Missing expected file/dir after extract: ${PROM_EXTRACT}/${f}"
    echo "Contents of ${PROM_EXTRACT}:"
    ls -la "$PROM_EXTRACT"
    exit 1
  fi
done

# Install binaries and web assets
cp "${PROM_EXTRACT}/prometheus"           /usr/local/bin/
cp "${PROM_EXTRACT}/promtool"             /usr/local/bin/
# consoles/ and console_libraries/ removed in Prometheus v3 — skip if absent
[ -d "${PROM_EXTRACT}/consoles" ]          && cp -r "${PROM_EXTRACT}/consoles"          /etc/prometheus/
[ -d "${PROM_EXTRACT}/console_libraries" ] && cp -r "${PROM_EXTRACT}/console_libraries" /etc/prometheus/
chown -R prometheus:prometheus /etc/prometheus
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
rm -rf "$PROM_EXTRACT"
echo ">>> Prometheus binaries installed: $(prometheus --version 2>&1 | head -1)" 

# -------------------------------------------------------
# Prometheus config — scrapes accel-exporter on :9101
# and also scrapes itself for meta-monitoring
# -------------------------------------------------------
cat > /etc/prometheus/prometheus.yml <<PROMCFG
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  scrape_timeout:      10s

scrape_configs:
  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Accel-PPP metrics via accel-exporter
  - job_name: 'accel-ppp'
    scrape_interval: 15s
    scrape_timeout:  10s
    static_configs:
      - targets: ['localhost:9101']
        labels:
          instance: 'bras-01'
          environment: 'production'

  # Node metrics (optional — remove if not needed)
  # - job_name: 'node'
  #   static_configs:
  #     - targets: ['localhost:9100']
PROMCFG

chown prometheus:prometheus /etc/prometheus/prometheus.yml

# Validate config
promtool check config /etc/prometheus/prometheus.yml

# Prometheus systemd service
cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Monitoring
Documentation=https://prometheus.io/docs/introduction/overview/
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --storage.tsdb.retention.time=30d \\
  # --web.console.* flags removed — Prometheus v3 dropped console directories
  # --web.console.* flags removed — Prometheus v3 dropped console directories
  --web.listen-address=127.0.0.1:9090 \\
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Allow Prometheus UI only from localhost (access via SSH tunnel or change to 0.0.0.0 if needed)
# Open Prometheus to management subnet (default: all; restrict as needed)
iptables -A INPUT -s "$MGMT_SUBNET" -p tcp --dport 9090 -j ACCEPT
netfilter-persistent save

systemctl daemon-reload
systemctl enable prometheus
systemctl restart prometheus

echo ">>> Prometheus started — http://localhost:9090"

# ============================================================
# GRAFANA INSTALL
# Official APT repo — always installs latest stable OSS release
# Runs on port 3000 with auto-provisioned datasource + dashboard
# ============================================================
echo ""
echo ">>> Installing Grafana OSS..."

apt-get install -y apt-transport-https software-properties-common wget curl

# Import Grafana GPG key (official method from grafana.com/docs)
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
chmod 644 /etc/apt/keyrings/grafana.asc

# Add stable repo
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  | tee /etc/apt/sources.list.d/grafana.list

apt-get update
apt-get install -y grafana

# -------------------------------------------------------
# Grafana config: harden defaults
# Listen on 0.0.0.0 so all interfaces are reachable
# -------------------------------------------------------

# Generate secret key before the heredoc ($(…) doesn't expand inside heredocs)
GF_SECRET=$(openssl rand -hex 32)

# Stop Grafana before writing config (avoids partial-write issues)
systemctl stop grafana-server 2>/dev/null || true

cat > /etc/grafana/grafana.ini <<GFINI
[server]
http_addr = 0.0.0.0
http_port = 3000
domain = localhost
root_url = %(protocol)s://%(domain)s:%(http_port)s/

[security]
# CHANGE THIS PASSWORD immediately after first login!
admin_user = admin
admin_password = ${GRAFANA_ADMIN_PASS}
secret_key = ${GF_SECRET}
disable_gravatar = true
cookie_secure = false
cookie_samesite = lax

[users]
allow_sign_up = false
allow_org_create = false
auto_assign_org_role = Viewer

[auth.anonymous]
enabled = false

[analytics]
reporting_enabled = false
check_for_updates = true

[log]
mode = file
level = warn
GFINI

echo ">>> Grafana config written (http_addr = 0.0.0.0, port 3000)"

# -------------------------------------------------------
# Grafana Provisioning — Prometheus datasource (auto-wired)
# -------------------------------------------------------
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<DS
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: false
    jsonData:
      httpMethod: POST
      timeInterval: "15s"
DS

# -------------------------------------------------------
# Grafana Provisioning — Dashboard folder config
# Grafana will auto-load any JSON files in the folder below
# -------------------------------------------------------
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /var/lib/grafana/dashboards

cat > /etc/grafana/provisioning/dashboards/accel-ppp.yml <<DBPROV
apiVersion: 1
providers:
  - name: 'Accel-PPP'
    orgId: 1
    folder: 'ISP / Accel-PPP'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
DBPROV

# -------------------------------------------------------
# Copy accel-exporter dashboard JSON (from repo clone)
# and embed a built-in Accel-PPP dashboard as fallback
# -------------------------------------------------------

# Copy from repo if present
if ls /usr/src/accel-exporter/dashboards/*.json 2>/dev/null; then
  cp /usr/src/accel-exporter/dashboards/*.json /var/lib/grafana/dashboards/
  echo ">>> Copied accel-exporter dashboards from repo"
fi

# Also write a comprehensive built-in Accel-PPP dashboard
cat > /var/lib/grafana/dashboards/accel-ppp-bras.json <<'DASHEOF'
{
  "title": "Accel-PPP BRAS Monitor",
  "uid": "accel-ppp-bras",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "15s",
  "tags": ["accel-ppp", "isp", "pppoe"],
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    {
      "id": 1, "type": "stat", "title": "Active Sessions",
      "gridPos": { "x": 0, "y": 0, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "color": { "mode": "thresholds" },
        "thresholds": { "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 5000 },
          { "color": "red", "value": 9000 }
        ]}
      }},
      "targets": [{ "datasource": "Prometheus",
        "expr": "accel_ppp_sessions_active", "legendFormat": "Active" }]
    },
    {
      "id": 2, "type": "stat", "title": "Total Sessions (lifetime)",
      "gridPos": { "x": 4, "y": 0, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "color": { "mode": "fixed", "fixedColor": "blue" }}},
      "targets": [{ "datasource": "Prometheus",
        "expr": "accel_ppp_sessions_total", "legendFormat": "Total" }]
    },
    {
      "id": 3, "type": "stat", "title": "Session Errors",
      "gridPos": { "x": 8, "y": 0, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "color": { "mode": "thresholds" },
        "thresholds": { "steps": [
          { "color": "green", "value": null },
          { "color": "red", "value": 1 }
        ]}
      }},
      "targets": [{ "datasource": "Prometheus",
        "expr": "rate(accel_ppp_sessions_error_total[5m]) * 60", "legendFormat": "Errors/min" }]
    },
    {
      "id": 4, "type": "stat", "title": "Uptime",
      "gridPos": { "x": 12, "y": 0, "w": 4, "h": 4 },
      "fieldConfig": { "defaults": { "unit": "s" }},
      "targets": [{ "datasource": "Prometheus",
        "expr": "accel_ppp_uptime_seconds", "legendFormat": "Uptime" }]
    },
    {
      "id": 5, "type": "timeseries", "title": "Sessions Over Time",
      "gridPos": { "x": 0, "y": 4, "w": 12, "h": 8 },
      "fieldConfig": { "defaults": { "custom": { "lineWidth": 2 }}},
      "targets": [
        { "datasource": "Prometheus", "expr": "accel_ppp_sessions_active", "legendFormat": "Active Sessions" },
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_sessions_total[5m]) * 300", "legendFormat": "New Sessions/5m" }
      ]
    },
    {
      "id": 6, "type": "timeseries", "title": "Session Rate (connects/disconnects per min)",
      "gridPos": { "x": 12, "y": 4, "w": 12, "h": 8 },
      "targets": [
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_sessions_total[1m]) * 60", "legendFormat": "Connect rate/min" },
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_sessions_finished_total[1m]) * 60", "legendFormat": "Disconnect rate/min" }
      ]
    },
    {
      "id": 7, "type": "timeseries", "title": "Traffic Throughput",
      "gridPos": { "x": 0, "y": 12, "w": 24, "h": 8 },
      "fieldConfig": { "defaults": { "unit": "bps" }},
      "targets": [
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_bytes_sent_total[1m]) * 8", "legendFormat": "TX (upload)" },
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_bytes_received_total[1m]) * 8", "legendFormat": "RX (download)" }
      ]
    },
    {
      "id": 8, "type": "timeseries", "title": "Packet Rate",
      "gridPos": { "x": 0, "y": 20, "w": 12, "h": 8 },
      "fieldConfig": { "defaults": { "unit": "pps" }},
      "targets": [
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_packets_sent_total[1m])", "legendFormat": "TX packets/s" },
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_packets_received_total[1m])", "legendFormat": "RX packets/s" }
      ]
    },
    {
      "id": 9, "type": "timeseries", "title": "RADIUS Auth (success / fail)",
      "gridPos": { "x": 12, "y": 20, "w": 12, "h": 8 },
      "targets": [
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_radius_auth_success_total[1m]) * 60", "legendFormat": "Auth OK/min" },
        { "datasource": "Prometheus", "expr": "rate(accel_ppp_radius_auth_failed_total[1m]) * 60", "legendFormat": "Auth FAIL/min" }
      ]
    }
  ]
}
DASHEOF

chown -R grafana:grafana /var/lib/grafana/dashboards /etc/grafana/provisioning

# -------------------------------------------------------
# Firewall: open port 3000 BEFORE starting Grafana
# -------------------------------------------------------
iptables -D INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -s "$MGMT_SUBNET" -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -p tcp --dport 3000 -j ACCEPT
netfilter-persistent save
echo ">>> Port 3000 open in iptables"

# -------------------------------------------------------
# Start Grafana and wait until it is truly ready
# -------------------------------------------------------
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server

echo ">>> Waiting for Grafana to become ready (max 120s)..."
GRAFANA_URL="http://localhost:3000"
MAX_WAIT=120
ELAPSED=0

until curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1; do
  sleep 3
  ELAPSED=$((ELAPSED + 3))
  echo "    ... waited ${ELAPSED}s"
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Grafana did not start in ${MAX_WAIT}s"
    systemctl status grafana-server --no-pager -l
    journalctl -u grafana-server --no-pager -n 20
    echo "Fix manually: systemctl restart grafana-server"
    break
  fi
done

if curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1; then
  echo ">>> Grafana is UP at ${GRAFANA_URL}"

  # Verify Prometheus datasource
  echo ">>> Testing Prometheus datasource..."
  curl -sf -u "admin:${GRAFANA_ADMIN_PASS}"     -X POST -H "Content-Type: application/json"     "${GRAFANA_URL}/api/datasources/1/health" > /dev/null 2>&1     && echo ">>> Datasource OK"     || echo ">>> Datasource check skipped — Prometheus may still be starting"

  # Force provisioning reload so dashboards appear immediately
  curl -sf -u "admin:${GRAFANA_ADMIN_PASS}"     -X POST "${GRAFANA_URL}/api/admin/provisioning/dashboards/reload" > /dev/null 2>&1     && echo ">>> Dashboards provisioned"     || echo ">>> Provisioning reload skipped"

  # Confirm admin login works
  GF_HTTP=$(curl -sf -o /dev/null -w "%{http_code}"     -u "admin:${GRAFANA_ADMIN_PASS}" "${GRAFANA_URL}/api/org")
  if [ "$GF_HTTP" = "200" ]; then
    echo ">>> Admin login confirmed OK"
  else
    echo ">>> Admin login returned HTTP ${GF_HTTP}"
    echo "    Reset password: grafana-cli admin reset-admin-password '${GRAFANA_ADMIN_PASS}'"
  fi
fi

# PART 2 COMPLETE
# ============================================================
echo ""
echo "================================================================"
echo "  🔵  PART 2 COMPLETE — Monitoring Stack"
echo "================================================================"
echo "  accel-exporter : http://localhost:${EXPORTER_PORT}/metrics"
echo "  Prometheus     : http://${PROMETHEUS_BIND}:9090"
echo "  Grafana        : http://$(hostname -I | awk '{print $1}'):3000"
echo "  Grafana login  : admin / ${GRAFANA_ADMIN_PASS}"
echo "  Dashboard      : ISP / Accel-PPP  →  Accel-PPP BRAS Monitor"
echo "================================================================"
echo ""
echo "👉 Verify all services:"
echo "  systemctl status accel-exporter prometheus grafana-server"
echo ""
echo "👉 Quick checks:"
echo "  curl -s http://localhost:${EXPORTER_PORT}/metrics | grep accel_ppp_sessions"
echo "  curl -s http://localhost:9090/-/healthy"
echo "  curl -s http://localhost:3000/api/health"
echo ""
echo "  ⚠️  Change Grafana password immediately after first login!"
echo "  ⚠️  Restrict port 3000 in iptables to your management subnet:"
echo "       iptables -I INPUT -p tcp --dport 3000 ! -s YOUR_MGMT_IP -j DROP"
echo "================================================================"
