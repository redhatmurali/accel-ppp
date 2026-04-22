#!/bin/bash
# =============================================================================
# 🟡 Part 3 — ISP System Metrics (node_exporter + custom collectors + dashboard)
#
# Collects:
#   NAT/conntrack · Bandwidth · Drops · CPU · Memory
#   Top Users · Interface · Sessions · Quality (ping/latency)
#
# Run AFTER part1 and part2 have completed successfully.
# Installs node_exporter + custom textfile collectors + Grafana dashboard
# =============================================================================
set -euo pipefail

############################
# EDIT THESE IF NEEDED
# Must match Part 1 values
############################
LAN_IF="ens37"               # PPPoE/OLT interface
WAN_IF="ens33"               # Internet/WAN interface
MGMT_SUBNET="0.0.0.0/0"     # Subnet allowed to access metrics

# Grafana settings — must match Part 2
GRAFANA_ADMIN_PASS="AccelPPP@ISP!"
GRAFANA_URL="http://localhost:3001"

# Ping targets for quality metrics
PING_TARGET_1="8.8.8.8"
PING_TARGET_2="1.1.1.1"

# node_exporter port
NODE_EXPORTER_PORT=9100

# Textfile collector directory (node_exporter reads .prom files from here)
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

############################
# PREFLIGHT
############################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root." >&2
  exit 1
fi

if ! systemctl is-active --quiet prometheus 2>/dev/null; then
  echo "WARNING: Prometheus not running — run part2-monitoring.sh first"
  sleep 3
fi

echo ""
echo "================================================================"
echo "  🟡 Part 3 — ISP System Metrics Installer"
echo "================================================================"

############################
# INSTALL DEPENDENCIES
############################
apt-get update -qq
apt-get install -y --fix-missing \
  wget curl iproute2 iptables \
  iputils-ping fping \
  jq bc gawk cron

############################
# INSTALL NODE_EXPORTER
# Official Prometheus node exporter — system metrics
# CPU, memory, network, disk, interrupts, softirqs
############################
echo ""
echo ">>> Installing node_exporter..."

NODE_VER=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest \
  | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
echo ">>> node_exporter version: $NODE_VER"

useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true

cd /tmp
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VER}/node_exporter-${NODE_VER}.linux-amd64.tar.gz" \
  -o node_exporter.tar.gz
tar -xzf node_exporter.tar.gz
cp "node_exporter-${NODE_VER}.linux-amd64/node_exporter" /usr/local/bin/
chmod 755 /usr/local/bin/node_exporter
chown node_exporter:node_exporter /usr/local/bin/node_exporter
rm -rf "node_exporter-${NODE_VER}.linux-amd64" node_exporter.tar.gz

# Create textfile directory for custom metrics
mkdir -p "$TEXTFILE_DIR"
chown node_exporter:node_exporter "$TEXTFILE_DIR"

# node_exporter systemd service
cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=:${NODE_EXPORTER_PORT} \\
  --collector.textfile.directory=${TEXTFILE_DIR} \\
  --collector.systemd \\
  --collector.processes \\
  --collector.interrupts \\
  --collector.softirqs \\
  --collector.conntrack \\
  --collector.netstat \\
  --collector.tcpstat
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter
echo ">>> node_exporter started on :${NODE_EXPORTER_PORT}"

############################
# CUSTOM TEXTFILE COLLECTORS
# These scripts run every minute via cron and write .prom files
# node_exporter reads them and exposes via /metrics
############################
echo ""
echo ">>> Installing custom metric collectors..."

mkdir -p /usr/local/lib/isp-collectors

# ── Collector 1: NAT / conntrack ──────────────────────────────
cat > /usr/local/lib/isp-collectors/conntrack.sh << 'SCRIPT'
#!/bin/bash
# Collects NAT/conntrack metrics
OUTFILE="/var/lib/node_exporter/textfile_collector/isp_conntrack.prom"
TMP="${OUTFILE}.tmp"

CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
CT_PCT=0
if [ "$CT_MAX" -gt 0 ]; then
  CT_PCT=$(echo "scale=2; $CT_COUNT * 100 / $CT_MAX" | bc 2>/dev/null || echo 0)
fi

# New connections per second (compare with previous count)
CT_PREV_FILE="/tmp/ct_prev_count"
CT_PREV_TIME_FILE="/tmp/ct_prev_time"
CT_NOW=$(date +%s)
CT_NEW_PER_SEC=0
if [ -f "$CT_PREV_FILE" ] && [ -f "$CT_PREV_TIME_FILE" ]; then
  CT_PREV=$(cat "$CT_PREV_FILE")
  CT_PREV_TIME=$(cat "$CT_PREV_TIME_FILE")
  CT_ELAPSED=$(( CT_NOW - CT_PREV_TIME ))
  if [ "$CT_ELAPSED" -gt 0 ]; then
    CT_NEW_PER_SEC=$(( (CT_COUNT - CT_PREV) / CT_ELAPSED ))
  fi
fi
echo "$CT_COUNT" > "$CT_PREV_FILE"
echo "$CT_NOW" > "$CT_PREV_TIME_FILE"

cat > "$TMP" << EOF
# HELP isp_conntrack_count Current number of conntrack entries
# TYPE isp_conntrack_count gauge
isp_conntrack_count $CT_COUNT
# HELP isp_conntrack_max Maximum conntrack entries
# TYPE isp_conntrack_max gauge
isp_conntrack_max $CT_MAX
# HELP isp_conntrack_usage_percent Conntrack table usage percentage
# TYPE isp_conntrack_usage_percent gauge
isp_conntrack_usage_percent $CT_PCT
# HELP isp_conntrack_new_per_sec New connections per second
# TYPE isp_conntrack_new_per_sec gauge
isp_conntrack_new_per_sec $CT_NEW_PER_SEC
EOF
mv "$TMP" "$OUTFILE"
SCRIPT

# ── Collector 2: Bandwidth & Interface ────────────────────────
cat > /usr/local/lib/isp-collectors/bandwidth.sh << 'SCRIPT'
#!/bin/bash
# Collects per-interface bandwidth, drops, errors, link status
OUTFILE="/var/lib/node_exporter/textfile_collector/isp_bandwidth.prom"
TMP="${OUTFILE}.tmp"

# Read interfaces from args or default
INTERFACES="${ISP_INTERFACES:-$(ls /sys/class/net | grep -v lo | tr '\n' ' ')}"

cat > "$TMP" << 'HEADER'
# HELP isp_interface_tx_bytes_total Total TX bytes
# TYPE isp_interface_tx_bytes_total counter
# HELP isp_interface_rx_bytes_total Total RX bytes
# TYPE isp_interface_rx_bytes_total counter
# HELP isp_interface_tx_rate_bytes Transmit rate bytes/sec
# TYPE isp_interface_tx_rate_bytes gauge
# HELP isp_interface_rx_rate_bytes Receive rate bytes/sec
# TYPE isp_interface_rx_rate_bytes gauge
# HELP isp_interface_tx_packets_dropped_total TX dropped packets
# TYPE isp_interface_tx_packets_dropped_total counter
# HELP isp_interface_rx_packets_dropped_total RX dropped packets
# TYPE isp_interface_rx_packets_dropped_total counter
# HELP isp_interface_tx_errors_total TX errors
# TYPE isp_interface_tx_errors_total counter
# HELP isp_interface_rx_errors_total RX errors
# TYPE isp_interface_rx_errors_total counter
# HELP isp_interface_link_status Interface link status (1=up, 0=down)
# TYPE isp_interface_link_status gauge
HEADER

for IF in $INTERFACES; do
  [ -d "/sys/class/net/$IF" ] || continue
  
  TX=$(cat /sys/class/net/$IF/statistics/tx_bytes 2>/dev/null || echo 0)
  RX=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null || echo 0)
  TX_DROP=$(cat /sys/class/net/$IF/statistics/tx_dropped 2>/dev/null || echo 0)
  RX_DROP=$(cat /sys/class/net/$IF/statistics/rx_dropped 2>/dev/null || echo 0)
  TX_ERR=$(cat /sys/class/net/$IF/statistics/tx_errors 2>/dev/null || echo 0)
  RX_ERR=$(cat /sys/class/net/$IF/statistics/rx_errors 2>/dev/null || echo 0)
  OPERSTATE=$(cat /sys/class/net/$IF/operstate 2>/dev/null || echo "unknown")
  LINK=0; [ "$OPERSTATE" = "up" ] && LINK=1

  # Rate calculation
  PREV_TX_FILE="/tmp/bw_tx_${IF}"
  PREV_RX_FILE="/tmp/bw_rx_${IF}"
  PREV_TIME_FILE="/tmp/bw_time_${IF}"
  NOW=$(date +%s)
  TX_RATE=0; RX_RATE=0
  if [ -f "$PREV_TX_FILE" ] && [ -f "$PREV_TIME_FILE" ]; then
    PREV_TX=$(cat "$PREV_TX_FILE")
    PREV_RX=$(cat "$PREV_RX_FILE" 2>/dev/null || echo 0)
    PREV_TIME=$(cat "$PREV_TIME_FILE")
    ELAPSED=$(( NOW - PREV_TIME ))
    if [ "$ELAPSED" -gt 0 ]; then
      TX_RATE=$(( (TX - PREV_TX) / ELAPSED ))
      RX_RATE=$(( (RX - PREV_RX) / ELAPSED ))
    fi
  fi
  echo "$TX" > "$PREV_TX_FILE"
  echo "$RX" > "$PREV_RX_FILE"
  echo "$NOW" > "$PREV_TIME_FILE"

  cat >> "$TMP" << EOF
isp_interface_tx_bytes_total{interface="$IF"} $TX
isp_interface_rx_bytes_total{interface="$IF"} $RX
isp_interface_tx_rate_bytes{interface="$IF"} $TX_RATE
isp_interface_rx_rate_bytes{interface="$IF"} $RX_RATE
isp_interface_tx_packets_dropped_total{interface="$IF"} $TX_DROP
isp_interface_rx_packets_dropped_total{interface="$IF"} $RX_DROP
isp_interface_tx_errors_total{interface="$IF"} $TX_ERR
isp_interface_rx_errors_total{interface="$IF"} $RX_ERR
isp_interface_link_status{interface="$IF"} $LINK
EOF
done
mv "$TMP" "$OUTFILE"
SCRIPT

# ── Collector 3: Firewall / iptables drops ────────────────────
cat > /usr/local/lib/isp-collectors/firewall.sh << 'SCRIPT'
#!/bin/bash
# Collects iptables packet drop counters
OUTFILE="/var/lib/node_exporter/textfile_collector/isp_firewall.prom"
TMP="${OUTFILE}.tmp"

# Count total DROP policy hits across all chains
FW_INPUT_DROP=$(iptables -L INPUT -nvx 2>/dev/null | grep -c "DROP" || echo 0)
FW_FORWARD_DROP=$(iptables -L FORWARD -nvx 2>/dev/null | grep -c "DROP" || echo 0)

# Total packet drops from FORWARD chain (sum pkts for DROP rules)
FW_PKT_DROPS=$(iptables -L FORWARD -nvx 2>/dev/null | grep "DROP" | awk '{sum+=$1} END {print sum+0}')
FW_BYTE_DROPS=$(iptables -L FORWARD -nvx 2>/dev/null | grep "DROP" | awk '{sum+=$2} END {print sum+0}')

# NAT masquerade packet count
NAT_PKTS=$(iptables -t nat -L POSTROUTING -nvx 2>/dev/null | grep "MASQUERADE" | awk '{sum+=$1} END {print sum+0}')
NAT_BYTES=$(iptables -t nat -L POSTROUTING -nvx 2>/dev/null | grep "MASQUERADE" | awk '{sum+=$2} END {print sum+0}')

cat > "$TMP" << EOF
# HELP isp_firewall_drop_packets_total Total firewall dropped packets
# TYPE isp_firewall_drop_packets_total counter
isp_firewall_drop_packets_total $FW_PKT_DROPS
# HELP isp_firewall_drop_bytes_total Total firewall dropped bytes
# TYPE isp_firewall_drop_bytes_total counter
isp_firewall_drop_bytes_total $FW_BYTE_DROPS
# HELP isp_firewall_input_drop_rules Number of INPUT DROP rules
# TYPE isp_firewall_input_drop_rules gauge
isp_firewall_input_drop_rules $FW_INPUT_DROP
# HELP isp_firewall_forward_drop_rules Number of FORWARD DROP rules
# TYPE isp_firewall_forward_drop_rules gauge
isp_firewall_forward_drop_rules $FW_FORWARD_DROP
# HELP isp_nat_masquerade_packets_total NAT masquerade packets
# TYPE isp_nat_masquerade_packets_total counter
isp_nat_masquerade_packets_total $NAT_PKTS
# HELP isp_nat_masquerade_bytes_total NAT masquerade bytes
# TYPE isp_nat_masquerade_bytes_total counter
isp_nat_masquerade_bytes_total $NAT_BYTES
EOF
mv "$TMP" "$OUTFILE"
SCRIPT

# ── Collector 4: Top Users by bandwidth ───────────────────────
cat > /usr/local/lib/isp-collectors/top_users.sh << 'SCRIPT'
#!/bin/bash
# Collects top IPs by conntrack — approximation of top users
OUTFILE="/var/lib/node_exporter/textfile_collector/isp_top_users.prom"
TMP="${OUTFILE}.tmp"

cat > "$TMP" << 'HEADER'
# HELP isp_top_ip_connections Number of conntrack connections per source IP
# TYPE isp_top_ip_connections gauge
HEADER

# Get top 20 IPs by connection count from conntrack
if command -v conntrack &>/dev/null; then
  conntrack -L 2>/dev/null \
    | grep -oP 'src=\K[0-9.]+' \
    | sort | uniq -c | sort -rn \
    | head -20 \
    | while read COUNT IP; do
        echo "isp_top_ip_connections{src_ip=\"$IP\"} $COUNT" >> "$TMP"
      done
else
  # Fallback: parse /proc/net/nf_conntrack
  cat /proc/net/nf_conntrack 2>/dev/null \
    | grep -oP 'src=\K[0-9.]+' \
    | sort | uniq -c | sort -rn \
    | head -20 \
    | while read COUNT IP; do
        echo "isp_top_ip_connections{src_ip=\"$IP\"} $COUNT" >> "$TMP"
      done
fi

mv "$TMP" "$OUTFILE"
SCRIPT

# ── Collector 5: Quality — ping latency/jitter/loss ───────────
cat > /usr/local/lib/isp-collectors/quality.sh << "SCRIPT"
#!/bin/bash
# Collects network quality metrics via ping
OUTFILE="/var/lib/node_exporter/textfile_collector/isp_quality.prom"
TMP="${OUTFILE}.tmp"

TARGETS="${PING_TARGETS:-8.8.8.8 1.1.1.1}"

cat > "$TMP" << 'HEADER'
# HELP isp_ping_latency_ms Ping latency in milliseconds
# TYPE isp_ping_latency_ms gauge
# HELP isp_ping_jitter_ms Ping jitter in milliseconds
# TYPE isp_ping_jitter_ms gauge
# HELP isp_ping_loss_percent Ping packet loss percentage
# TYPE isp_ping_loss_percent gauge
HEADER

for TARGET in $TARGETS; do
  RESULT=$(ping -c 5 -q "$TARGET" 2>/dev/null)
  if [ $? -eq 0 ]; then
    # Parse: min/avg/max/mdev
    STATS=$(echo "$RESULT" | grep "min/avg/max" | awk -F'/' '{print $5, $6, $8}')
    AVG=$(echo "$STATS" | awk '{print $1}')
    JITTER=$(echo "$STATS" | awk '{print $3}')
    LOSS=$(echo "$RESULT" | grep -oP '\K[0-9.]+(?=% packet loss)')
    [ -z "$AVG" ]    && AVG=0
    [ -z "$JITTER" ] && JITTER=0
    [ -z "$LOSS" ]   && LOSS=0
  else
    AVG=0; JITTER=0; LOSS=100
  fi
  cat >> "$TMP" << EOF
isp_ping_latency_ms{target="$TARGET"} $AVG
isp_ping_jitter_ms{target="$TARGET"} $JITTER
isp_ping_loss_percent{target="$TARGET"} $LOSS
EOF
done
mv "$TMP" "$OUTFILE"
SCRIPT

# ── Collector 6: TCP sessions quality ─────────────────────────
cat > /usr/local/lib/isp-collectors/tcp_sessions.sh << 'SCRIPT'
#!/bin/bash
# Collects TCP session quality metrics from /proc/net/snmp
OUTFILE="/var/lib/node_exporter/textfile_collector/isp_tcp.prom"
TMP="${OUTFILE}.tmp"

# Parse /proc/net/snmp for TCP stats
TCP_RETRANS=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $13}' 2>/dev/null || echo 0)
TCP_RESETS=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $9}' 2>/dev/null || echo 0)
TCP_CURR=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $10}' 2>/dev/null || echo 0)
TCP_ACTIVE=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $6}' 2>/dev/null || echo 0)
TCP_PASSIVE=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $7}' 2>/dev/null || echo 0)

# Connections per second
CONN_PREV_FILE="/tmp/tcp_conn_prev"
CONN_TIME_FILE="/tmp/tcp_conn_time"
NOW=$(date +%s)
CONN_PER_SEC=0
if [ -f "$CONN_PREV_FILE" ] && [ -f "$CONN_TIME_FILE" ]; then
  PREV=$(cat "$CONN_PREV_FILE")
  PREV_TIME=$(cat "$CONN_TIME_FILE")
  ELAPSED=$(( NOW - PREV_TIME ))
  if [ "$ELAPSED" -gt 0 ]; then
    CONN_PER_SEC=$(( (TCP_ACTIVE - PREV) / ELAPSED ))
  fi
fi
echo "$TCP_ACTIVE" > "$CONN_PREV_FILE"
echo "$NOW" > "$CONN_TIME_FILE"

cat > "$TMP" << EOF
# HELP isp_tcp_retransmissions_total Total TCP retransmissions
# TYPE isp_tcp_retransmissions_total counter
isp_tcp_retransmissions_total $TCP_RETRANS
# HELP isp_tcp_resets_total Total TCP connection resets
# TYPE isp_tcp_resets_total counter
isp_tcp_resets_total $TCP_RESETS
# HELP isp_tcp_current_established Current established TCP connections
# TYPE isp_tcp_current_established gauge
isp_tcp_current_established $TCP_CURR
# HELP isp_tcp_active_opens_total Total active TCP opens
# TYPE isp_tcp_active_opens_total counter
isp_tcp_active_opens_total $TCP_ACTIVE
# HELP isp_tcp_passive_opens_total Total passive TCP opens
# TYPE isp_tcp_passive_opens_total counter
isp_tcp_passive_opens_total $TCP_PASSIVE
# HELP isp_connections_per_second New connections per second
# TYPE isp_connections_per_second gauge
isp_connections_per_second $CONN_PER_SEC
EOF
mv "$TMP" "$OUTFILE"
SCRIPT

############################
# MAKE ALL COLLECTORS EXECUTABLE
############################
chmod +x /usr/local/lib/isp-collectors/*.sh

############################
# MASTER COLLECTOR SCRIPT
# Called by cron every minute
############################
cat > /usr/local/lib/isp-collectors/run-all.sh << SCRIPT
#!/bin/bash
# Master collector — runs all ISP metric collectors
export PING_TARGETS="${PING_TARGET_1} ${PING_TARGET_2}"
export ISP_INTERFACES="${LAN_IF} ${WAN_IF}"

COLLECTOR_DIR="/usr/local/lib/isp-collectors"
for SCRIPT_FILE in "\${COLLECTOR_DIR}"/*.sh; do
  [ "\$SCRIPT_FILE" = "\${COLLECTOR_DIR}/run-all.sh" ] && continue
  bash "\$SCRIPT_FILE" 2>/dev/null &
done
wait
SCRIPT
chmod +x /usr/local/lib/isp-collectors/run-all.sh

############################
# RUN COLLECTORS NOW (initial data)
############################
echo ">>> Running collectors to generate initial metrics..."
bash /usr/local/lib/isp-collectors/run-all.sh
sleep 3
echo ">>> Collector output files:"
ls -la "$TEXTFILE_DIR"/*.prom 2>/dev/null || echo "  (none yet — will appear after cron runs)"

############################
# CRON JOB — every minute
############################
# Remove any existing cron entry for this
crontab -l 2>/dev/null | grep -v "isp-collectors" > /tmp/existing_cron || true
echo "* * * * * /usr/local/lib/isp-collectors/run-all.sh >> /var/log/isp-collectors.log 2>&1" \
  >> /tmp/existing_cron
crontab /tmp/existing_cron
rm /tmp/existing_cron
echo ">>> Cron job installed (runs every minute)"

############################
# ADD node_exporter TO PROMETHEUS
############################
echo ""
echo ">>> Adding node_exporter to Prometheus scrape config..."

cat > /etc/prometheus/prometheus.yml << 'PROMEOF'
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  scrape_timeout:      10s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'accel-ppp'
    scrape_interval: 15s
    scrape_timeout:  10s
    static_configs:
      - targets: ['localhost:9101']
        labels:
          instance: 'bras-01'
          environment: 'production'

  - job_name: 'node'
    scrape_interval: 15s
    static_configs:
      - targets: ['localhost:9100']
        labels:
          instance: 'bras-01'
          environment: 'production'
PROMEOF

chown prometheus:prometheus /etc/prometheus/prometheus.yml
promtool check config /etc/prometheus/prometheus.yml
systemctl reload prometheus 2>/dev/null || systemctl restart prometheus
echo ">>> Prometheus config updated — node_exporter scrape added"

############################
# FIREWALL — open node_exporter port
############################
iptables -D INPUT -p tcp --dport "${NODE_EXPORTER_PORT}" -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -p tcp --dport "${NODE_EXPORTER_PORT}" -j ACCEPT
netfilter-persistent save > /dev/null 2>&1
echo ">>> Port ${NODE_EXPORTER_PORT} open in iptables"

############################
# INSTALL GRAFANA DASHBOARD
############################
echo ""
echo ">>> Installing ISP System Metrics dashboard in Grafana..."

mkdir -p /var/lib/grafana/dashboards

cat > /var/lib/grafana/dashboards/isp-system-metrics.json << 'DASHEOF'
{
  "title": "ISP System Metrics",
  "uid": "isp-system-metrics",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "30s",
  "tags": ["isp", "system", "nat", "bandwidth"],
  "time": { "from": "now-1h", "to": "now" },
  "panels": [

    { "id": 1, "type": "row", "title": "NAT & Conntrack", "gridPos": {"x":0,"y":0,"w":24,"h":1}, "collapsed": false },

    { "id": 2, "type": "stat", "title": "Conntrack Usage %",
      "gridPos": {"x":0,"y":1,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "percent", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":70},{"color":"red","value":90}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"isp_conntrack_usage_percent","legendFormat":"Usage %"}]
    },
    { "id": 3, "type": "stat", "title": "Conntrack Count",
      "gridPos": {"x":4,"y":1,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"isp_conntrack_count","legendFormat":"Count"}]
    },
    { "id": 4, "type": "stat", "title": "Conntrack Max",
      "gridPos": {"x":8,"y":1,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"isp_conntrack_max","legendFormat":"Max"}]
    },
    { "id": 5, "type": "stat", "title": "New Connections/sec",
      "gridPos": {"x":12,"y":1,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"isp_conntrack_new_per_sec","legendFormat":"Conn/s"}]
    },
    { "id": 6, "type": "stat", "title": "NAT Packets",
      "gridPos": {"x":16,"y":1,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"rate(isp_nat_masquerade_packets_total[1m]) * 60","legendFormat":"pkts/min"}]
    },
    { "id": 7, "type": "timeseries", "title": "Conntrack Over Time",
      "gridPos": {"x":0,"y":5,"w":12,"h":7},
      "fieldConfig": {"defaults": {"custom": {"lineWidth": 2}}},
      "targets": [
        {"datasource":"Prometheus","expr":"isp_conntrack_count","legendFormat":"Active"},
        {"datasource":"Prometheus","expr":"isp_conntrack_max","legendFormat":"Max"}
      ]
    },
    { "id": 8, "type": "timeseries", "title": "New Connections/sec Over Time",
      "gridPos": {"x":12,"y":5,"w":12,"h":7},
      "targets": [
        {"datasource":"Prometheus","expr":"isp_conntrack_new_per_sec","legendFormat":"New conn/s"},
        {"datasource":"Prometheus","expr":"isp_connections_per_second","legendFormat":"TCP conn/s"}
      ]
    },

    { "id": 10, "type": "row", "title": "Bandwidth", "gridPos": {"x":0,"y":12,"w":24,"h":1}, "collapsed": false },

    { "id": 11, "type": "timeseries", "title": "WAN Bandwidth (TX/RX)",
      "gridPos": {"x":0,"y":13,"w":12,"h":8},
      "fieldConfig": {"defaults": {"unit": "Bps", "custom": {"lineWidth": 2}}},
      "targets": [
        {"datasource":"Prometheus","expr":"rate(node_network_transmit_bytes_total{device=\"ens33\"}[1m])","legendFormat":"TX"},
        {"datasource":"Prometheus","expr":"rate(node_network_receive_bytes_total{device=\"ens33\"}[1m])","legendFormat":"RX"}
      ]
    },
    { "id": 12, "type": "timeseries", "title": "LAN Bandwidth (TX/RX)",
      "gridPos": {"x":12,"y":13,"w":12,"h":8},
      "fieldConfig": {"defaults": {"unit": "Bps", "custom": {"lineWidth": 2}}},
      "targets": [
        {"datasource":"Prometheus","expr":"rate(node_network_transmit_bytes_total{device=\"ens37\"}[1m])","legendFormat":"TX"},
        {"datasource":"Prometheus","expr":"rate(node_network_receive_bytes_total{device=\"ens37\"}[1m])","legendFormat":"RX"}
      ]
    },

    { "id": 20, "type": "row", "title": "Drops & Firewall", "gridPos": {"x":0,"y":21,"w":24,"h":1}, "collapsed": false },

    { "id": 21, "type": "stat", "title": "Firewall Drops",
      "gridPos": {"x":0,"y":22,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"red","value":1}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"rate(isp_firewall_drop_packets_total[1m]) * 60","legendFormat":"drops/min"}]
    },
    { "id": 22, "type": "stat", "title": "Interface RX Drops",
      "gridPos": {"x":4,"y":22,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"rate(node_network_receive_drop_total[1m]) * 60","legendFormat":"drops/min"}]
    },
    { "id": 23, "type": "stat", "title": "Interface TX Drops",
      "gridPos": {"x":8,"y":22,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"rate(node_network_transmit_drop_total[1m]) * 60","legendFormat":"drops/min"}]
    },
    { "id": 24, "type": "stat", "title": "Interface Errors",
      "gridPos": {"x":12,"y":22,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"rate(node_network_receive_errs_total[1m]) * 60 + rate(node_network_transmit_errs_total[1m]) * 60","legendFormat":"errors/min"}]
    },
    { "id": 25, "type": "timeseries", "title": "Packet Drops Over Time",
      "gridPos": {"x":0,"y":26,"w":24,"h":7},
      "targets": [
        {"datasource":"Prometheus","expr":"rate(isp_firewall_drop_packets_total[1m])","legendFormat":"Firewall drops/s"},
        {"datasource":"Prometheus","expr":"rate(node_network_receive_drop_total[1m])","legendFormat":"RX drops/s"},
        {"datasource":"Prometheus","expr":"rate(node_network_transmit_drop_total[1m])","legendFormat":"TX drops/s"}
      ]
    },

    { "id": 30, "type": "row", "title": "CPU & Memory", "gridPos": {"x":0,"y":33,"w":24,"h":1}, "collapsed": false },

    { "id": 31, "type": "stat", "title": "CPU Usage %",
      "gridPos": {"x":0,"y":34,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "percent", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":70},{"color":"red","value":90}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)","legendFormat":"CPU %"}]
    },
    { "id": 32, "type": "stat", "title": "Load Average (1m)",
      "gridPos": {"x":4,"y":34,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"node_load1","legendFormat":"Load 1m"}]
    },
    { "id": 33, "type": "stat", "title": "Memory Usage %",
      "gridPos": {"x":8,"y":34,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "percent", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":75},{"color":"red","value":90}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100","legendFormat":"Mem %"}]
    },
    { "id": 34, "type": "stat", "title": "Memory Free",
      "gridPos": {"x":12,"y":34,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "bytes"}},
      "targets": [{"datasource":"Prometheus","expr":"node_memory_MemAvailable_bytes","legendFormat":"Free"}]
    },
    { "id": 35, "type": "stat", "title": "SoftIRQ Rate",
      "gridPos": {"x":16,"y":34,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"rate(node_softirqs_total[1m])","legendFormat":"{{softirq}}"}]
    },
    { "id": 36, "type": "timeseries", "title": "CPU Usage Over Time",
      "gridPos": {"x":0,"y":38,"w":12,"h":7},
      "fieldConfig": {"defaults": {"unit": "percent"}},
      "targets": [
        {"datasource":"Prometheus","expr":"100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)","legendFormat":"CPU %"},
        {"datasource":"Prometheus","expr":"avg(rate(node_cpu_seconds_total{mode=\"softirq\"}[1m])) * 100","legendFormat":"SoftIRQ %"},
        {"datasource":"Prometheus","expr":"avg(rate(node_cpu_seconds_total{mode=\"iowait\"}[1m])) * 100","legendFormat":"IO Wait %"}
      ]
    },
    { "id": 37, "type": "timeseries", "title": "Memory Over Time",
      "gridPos": {"x":12,"y":38,"w":12,"h":7},
      "fieldConfig": {"defaults": {"unit": "bytes"}},
      "targets": [
        {"datasource":"Prometheus","expr":"node_memory_MemTotal_bytes","legendFormat":"Total"},
        {"datasource":"Prometheus","expr":"node_memory_MemAvailable_bytes","legendFormat":"Available"},
        {"datasource":"Prometheus","expr":"node_memory_MemFree_bytes","legendFormat":"Free"}
      ]
    },

    { "id": 40, "type": "row", "title": "TCP Sessions", "gridPos": {"x":0,"y":45,"w":24,"h":1}, "collapsed": false },

    { "id": 41, "type": "stat", "title": "Established TCP",
      "gridPos": {"x":0,"y":46,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"isp_tcp_current_established","legendFormat":"Established"}]
    },
    { "id": 42, "type": "stat", "title": "TCP Retransmissions/min",
      "gridPos": {"x":4,"y":46,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":100},{"color":"red","value":1000}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"rate(isp_tcp_retransmissions_total[1m]) * 60","legendFormat":"Retrans/min"}]
    },
    { "id": 43, "type": "stat", "title": "Connection Resets/min",
      "gridPos": {"x":8,"y":46,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":50},{"color":"red","value":500}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"rate(isp_tcp_resets_total[1m]) * 60","legendFormat":"Resets/min"}]
    },
    { "id": 44, "type": "stat", "title": "Connections/sec",
      "gridPos": {"x":12,"y":46,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "targets": [{"datasource":"Prometheus","expr":"isp_connections_per_second","legendFormat":"conn/s"}]
    },
    { "id": 45, "type": "timeseries", "title": "TCP Health Over Time",
      "gridPos": {"x":0,"y":50,"w":24,"h":7},
      "targets": [
        {"datasource":"Prometheus","expr":"isp_tcp_current_established","legendFormat":"Established"},
        {"datasource":"Prometheus","expr":"rate(isp_tcp_retransmissions_total[1m]) * 60","legendFormat":"Retrans/min"},
        {"datasource":"Prometheus","expr":"rate(isp_tcp_resets_total[1m]) * 60","legendFormat":"Resets/min"}
      ]
    },

    { "id": 50, "type": "row", "title": "Network Quality", "gridPos": {"x":0,"y":57,"w":24,"h":1}, "collapsed": false },

    { "id": 51, "type": "stat", "title": "Latency to 8.8.8.8 (ms)",
      "gridPos": {"x":0,"y":58,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "ms", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":50},{"color":"red","value":150}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"isp_ping_latency_ms{target=\"8.8.8.8\"}","legendFormat":"Latency"}]
    },
    { "id": 52, "type": "stat", "title": "Jitter to 8.8.8.8 (ms)",
      "gridPos": {"x":4,"y":58,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "ms", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":10},{"color":"red","value":30}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"isp_ping_jitter_ms{target=\"8.8.8.8\"}","legendFormat":"Jitter"}]
    },
    { "id": 53, "type": "stat", "title": "Packet Loss 8.8.8.8 (%)",
      "gridPos": {"x":8,"y":58,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "percent", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":1},{"color":"red","value":5}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"isp_ping_loss_percent{target=\"8.8.8.8\"}","legendFormat":"Loss %"}]
    },
    { "id": 54, "type": "stat", "title": "Latency to 1.1.1.1 (ms)",
      "gridPos": {"x":12,"y":58,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "ms", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":50},{"color":"red","value":150}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"isp_ping_latency_ms{target=\"1.1.1.1\"}","legendFormat":"Latency"}]
    },
    { "id": 55, "type": "stat", "title": "Packet Loss 1.1.1.1 (%)",
      "gridPos": {"x":16,"y":58,"w":4,"h":4},
      "fieldConfig": {"defaults": {"unit": "percent", "thresholds": {"steps": [
        {"color":"green","value":null},{"color":"yellow","value":1},{"color":"red","value":5}
      ]}}},
      "targets": [{"datasource":"Prometheus","expr":"isp_ping_loss_percent{target=\"1.1.1.1\"}","legendFormat":"Loss %"}]
    },
    { "id": 56, "type": "timeseries", "title": "Latency & Jitter Over Time",
      "gridPos": {"x":0,"y":62,"w":24,"h":7},
      "fieldConfig": {"defaults": {"unit": "ms"}},
      "targets": [
        {"datasource":"Prometheus","expr":"isp_ping_latency_ms{target=\"8.8.8.8\"}","legendFormat":"Latency 8.8.8.8"},
        {"datasource":"Prometheus","expr":"isp_ping_jitter_ms{target=\"8.8.8.8\"}","legendFormat":"Jitter 8.8.8.8"},
        {"datasource":"Prometheus","expr":"isp_ping_latency_ms{target=\"1.1.1.1\"}","legendFormat":"Latency 1.1.1.1"},
        {"datasource":"Prometheus","expr":"isp_ping_loss_percent{target=\"8.8.8.8\"}","legendFormat":"Loss % 8.8.8.8"}
      ]
    },

    { "id": 60, "type": "row", "title": "Top Users", "gridPos": {"x":0,"y":69,"w":24,"h":1}, "collapsed": false },

    { "id": 61, "type": "bargauge", "title": "Top IPs by Connections",
      "gridPos": {"x":0,"y":70,"w":24,"h":10},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "options": {"orientation": "horizontal", "displayMode": "gradient"},
      "targets": [{"datasource":"Prometheus","expr":"topk(20, isp_top_ip_connections)","legendFormat":"{{src_ip}}"}]
    },

    { "id": 70, "type": "row", "title": "Interface Status", "gridPos": {"x":0,"y":80,"w":24,"h":1}, "collapsed": false },

    { "id": 71, "type": "stat", "title": "Interface Link Status",
      "gridPos": {"x":0,"y":81,"w":12,"h":4},
      "fieldConfig": {"defaults": {"mappings": [
        {"type":"value","options":{"0":{"text":"DOWN","color":"red"},"1":{"text":"UP","color":"green"}}}
      ]}},
      "targets": [{"datasource":"Prometheus","expr":"isp_interface_link_status","legendFormat":"{{interface}}"}]
    },
    { "id": 72, "type": "table", "title": "Interface Statistics",
      "gridPos": {"x":0,"y":85,"w":24,"h":8},
      "targets": [
        {"datasource":"Prometheus","expr":"isp_interface_tx_rate_bytes","legendFormat":"TX Rate {{interface}}","instant":true},
        {"datasource":"Prometheus","expr":"isp_interface_rx_rate_bytes","legendFormat":"RX Rate {{interface}}","instant":true},
        {"datasource":"Prometheus","expr":"isp_interface_tx_packets_dropped_total","legendFormat":"TX Drops {{interface}}","instant":true},
        {"datasource":"Prometheus","expr":"isp_interface_rx_packets_dropped_total","legendFormat":"RX Drops {{interface}}","instant":true}
      ]
    }
  ]
}
DASHEOF

chown grafana:grafana /var/lib/grafana/dashboards/isp-system-metrics.json
echo ">>> Dashboard JSON written"

############################
# WAIT FOR GRAFANA + RELOAD
############################
sleep 5
if curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1; then
  curl -sf -u "admin:${GRAFANA_ADMIN_PASS}" \
    -X POST "${GRAFANA_URL}/api/admin/provisioning/dashboards/reload" > /dev/null 2>&1 \
    && echo ">>> Grafana dashboard provisioning reloaded" \
    || echo ">>> Reload skipped — Grafana may need restart"
  systemctl restart grafana-server
  echo ">>> Grafana restarted"
else
  echo ">>> Grafana not responding — restart manually: systemctl restart grafana-server"
fi

############################
# DONE
############################
echo ""
echo "================================================================"
echo "  🟡 Part 3 COMPLETE — ISP System Metrics"
echo "================================================================"
echo "  node_exporter  : http://localhost:${NODE_EXPORTER_PORT}/metrics"
echo "  Collectors     : /usr/local/lib/isp-collectors/"
echo "  Textfile dir   : ${TEXTFILE_DIR}"
echo "  Cron           : every 1 minute"
echo "  Dashboard      : ISP / Accel-PPP > ISP System Metrics"
echo "================================================================"
echo ""
echo "👉 Verify:"
echo "  systemctl status node_exporter --no-pager"
echo "  curl -s http://localhost:9100/metrics | grep isp_"
echo "  ls -la ${TEXTFILE_DIR}"
echo ""
echo "👉 Manual collector run:"
echo "  bash /usr/local/lib/isp-collectors/run-all.sh"
echo ""
echo "  Open Grafana: http://$(hostname -I | awk '{print $1}'):3001"
echo "  Dashboard: ISP / Accel-PPP → ISP System Metrics"
echo "================================================================"
