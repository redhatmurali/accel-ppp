#!/bin/bash
# =============================================================================
# Part 2 - ISP Monitoring Stack
# accel-exporter -> Prometheus -> Grafana
# Run AFTER part1 has completed successfully.
# =============================================================================
set -euo pipefail

############################
# CONFIGURATION
############################
LAN_IF="ens34"
WAN_IF="ens33"
WAN_UPLINK_MBIT=1000
GRAFANA_ADMIN_PASS="AccelPPP-ISP-2024"
EXPORTER_PORT=9101
MGMT_SUBNET="0.0.0.0/0"

############################
# PREFLIGHT
############################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root." >&2; exit 1
fi

if ! systemctl is-active --quiet accel-ppp 2>/dev/null; then
  echo "WARNING: accel-ppp not running. Continuing anyway..."
  sleep 2
fi

if ! /usr/local/bin/accel-cmd show stat &>/dev/null; then
  echo "WARNING: accel-cmd cannot reach localhost:2001"
  echo "  Check [cli] section has: tcp=127.0.0.1:2001"
  sleep 2
fi

############################
# INSTALL Go
############################
echo ">>> Checking Go..."
GO_VERSION="1.22.5"
if /usr/local/go/bin/go version 2>/dev/null | grep -qE 'go1\.(2[1-9]|[3-9][0-9])'; then
  echo ">>> Go OK: $(/usr/local/go/bin/go version)"
else
  echo ">>> Installing Go ${GO_VERSION}..."
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

############################
# BUILD ACCEL-EXPORTER
############################
echo ">>> Building accel-exporter..."
cd /usr/src
if [ ! -d "accel-exporter" ]; then
  git clone https://github.com/taihen/accel-exporter.git
fi
cd accel-exporter
git fetch origin
git checkout main && git pull origin main
echo ">>> Commit: $(git rev-parse HEAD)"
go build -o /usr/local/bin/accel-exporter ./cmd/accel-exporter/
chmod 755 /usr/local/bin/accel-exporter
echo ">>> accel-exporter built OK"

############################
# ACCEL-EXPORTER SERVICE
# Uses -accel-cmd.path only (no socket flag in this version)
############################
python3 - "${EXPORTER_PORT}" << 'PYEOF'
import sys
port = sys.argv[1]
svc = f"""[Unit]
Description=Accel-PPP Prometheus Exporter
Documentation=https://github.com/taihen/accel-exporter
After=network.target accel-ppp.service
Requires=accel-ppp.service

[Service]
User=root
ExecStart=/usr/local/bin/accel-exporter -accel-cmd.path=/usr/local/bin/accel-cmd -web.listen-address=:{port} -web.metrics-path=/metrics -log.level=info
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""
with open('/etc/systemd/system/accel-exporter.service', 'w') as f:
    f.write(svc)
print(">>> accel-exporter.service written")
PYEOF

# Firewall
iptables -D INPUT -s 127.0.0.1 -p tcp --dport "${EXPORTER_PORT}" -j ACCEPT 2>/dev/null || true
iptables -A INPUT -s 127.0.0.1 -p tcp --dport "${EXPORTER_PORT}" -j ACCEPT
netfilter-persistent save

systemctl daemon-reload
systemctl enable accel-exporter
systemctl restart accel-exporter
sleep 4

echo ">>> Testing accel-exporter..."
EXPORTER_OK=0
for i in 1 2 3 4 5; do
  if curl -sf "http://localhost:${EXPORTER_PORT}/metrics" 2>/dev/null | grep -q "^accel_"; then
    echo ">>> accel-exporter OK - metrics flowing"
    EXPORTER_OK=1
    break
  fi
  echo "    ...waiting for exporter attempt ${i}/5"
  sleep 3
done
if [ "$EXPORTER_OK" = "0" ]; then
  echo ">>> WARNING: exporter not responding yet - continuing install"
  echo "    Check later: journalctl -u accel-exporter -n 20"
fi

############################
# PROMETHEUS
############################
echo ">>> Installing Prometheus..."

PROM_VERSION=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest \
  | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
# Fallback if API rate-limited or network issue
if [ -z "${PROM_VERSION}" ]; then
  echo ">>> WARNING: Could not fetch latest Prometheus version, using known stable"
  PROM_VERSION="3.11.2"
fi
echo ">>> Prometheus version: ${PROM_VERSION}"

useradd --system --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true
mkdir -p /etc/prometheus /var/lib/prometheus
chown prometheus:prometheus /var/lib/prometheus

PROM_EXTRACT="/tmp/prom-extract"
rm -rf "${PROM_EXTRACT}" && mkdir -p "${PROM_EXTRACT}"
cd /tmp
curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
  -o prometheus.tar.gz
tar -xzf prometheus.tar.gz --strip-components=1 -C "${PROM_EXTRACT}"
rm -f prometheus.tar.gz

cp "${PROM_EXTRACT}/prometheus" /usr/local/bin/
cp "${PROM_EXTRACT}/promtool"   /usr/local/bin/
[ -d "${PROM_EXTRACT}/consoles" ]          && cp -r "${PROM_EXTRACT}/consoles"          /etc/prometheus/ || true
[ -d "${PROM_EXTRACT}/console_libraries" ] && cp -r "${PROM_EXTRACT}/console_libraries" /etc/prometheus/ || true
chown -R prometheus:prometheus /etc/prometheus
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
rm -rf "${PROM_EXTRACT}"
/usr/local/bin/prometheus --version 2>&1 | head -1 | xargs -I{} echo ">>> {}" || echo ">>> prometheus installed"

# Write prometheus.yml using python3 - no heredoc
python3 - "${EXPORTER_PORT}" << 'PYEOF'
import sys
port = sys.argv[1]
cfg = f"""global:
  scrape_interval:     15s
  evaluation_interval: 15s
  scrape_timeout:      10s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: accel-ppp
    scrape_interval: 15s
    scrape_timeout:  10s
    static_configs:
      - targets: ['localhost:{port}']
        labels:
          instance: bras-01
          environment: production
"""
with open('/etc/prometheus/prometheus.yml', 'w') as f:
    f.write(cfg)
print(">>> prometheus.yml written")
PYEOF

chown prometheus:prometheus /etc/prometheus/prometheus.yml
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml

# Write prometheus.service using python3
python3 << 'PYEOF'
svc = """[Unit]
Description=Prometheus Monitoring
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.listen-address=127.0.0.1:9090 \
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""
with open('/etc/systemd/system/prometheus.service', 'w') as f:
    f.write(svc)
print(">>> prometheus.service written")
PYEOF

iptables -D INPUT -s "${MGMT_SUBNET}" -p tcp --dport 9090 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -s "${MGMT_SUBNET}" -p tcp --dport 9090 -j ACCEPT
netfilter-persistent save

systemctl daemon-reload
systemctl enable prometheus
systemctl restart prometheus
echo ">>> Prometheus started"

############################
# GRAFANA
############################
echo ">>> Installing Grafana..."

apt-get install -y apt-transport-https software-properties-common wget curl
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
chmod 644 /etc/apt/keyrings/grafana.asc
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  | tee /etc/apt/sources.list.d/grafana.list
apt-get update -q
apt-get install -y grafana

systemctl stop grafana-server 2>/dev/null || true

GF_SECRET=$(openssl rand -hex 32)

# Write grafana.ini using python3 - handles all special chars safely
python3 - "${GRAFANA_ADMIN_PASS}" "${GF_SECRET}" << 'PYEOF'
import sys
admin_pass = sys.argv[1]
secret_key = sys.argv[2]
cfg = f"""[server]
http_addr = 0.0.0.0
http_port = 3000
domain = localhost
root_url = %(protocol)s://%(domain)s:%(http_port)s/

[security]
admin_user = admin
admin_password = {admin_pass}
secret_key = {secret_key}
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
"""
with open('/etc/grafana/grafana.ini', 'w') as f:
    f.write(cfg)
print(">>> grafana.ini written")
PYEOF

# Write datasource provisioning
mkdir -p /etc/grafana/provisioning/datasources
python3 << 'PYEOF'
cfg = """apiVersion: 1
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
"""
with open('/etc/grafana/provisioning/datasources/prometheus.yml', 'w') as f:
    f.write(cfg)
print(">>> datasource provisioning written")
PYEOF

# Write dashboard provisioning
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /var/lib/grafana/dashboards
python3 << 'PYEOF'
cfg = """apiVersion: 1
providers:
  - name: Accel-PPP
    orgId: 1
    folder: ISP / Accel-PPP
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
"""
with open('/etc/grafana/provisioning/dashboards/accel-ppp.yml', 'w') as f:
    f.write(cfg)
print(">>> dashboard provisioning written")
PYEOF

# Write Grafana dashboard JSON
# All metric names verified from live accel-exporter output
python3 << 'PYEOF'
import json

dashboard = {
  "title": "Accel-PPP BRAS Monitor",
  "uid": "accel-ppp-bras-v3",
  "schemaVersion": 38,
  "version": 3,
  "refresh": "15s",
  "tags": ["accel-ppp", "isp", "pppoe"],
  "time": {"from": "now-1h", "to": "now"},
  "panels": [
    {"id":1,"type":"stat","title":"Daemon Up",
     "gridPos":{"x":0,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"mappings":[{"type":"value","options":{"0":{"text":"DOWN","color":"red"},"1":{"text":"UP","color":"green"}}}],"thresholds":{"steps":[{"color":"red","value":None},{"color":"green","value":1}]}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_up","legendFormat":"Status"}]},

    {"id":2,"type":"stat","title":"Uptime",
     "gridPos":{"x":3,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"unit":"s","color":{"mode":"fixed","fixedColor":"blue"}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_uptime_seconds","legendFormat":"Uptime"}]},

    {"id":3,"type":"stat","title":"Active Sessions",
     "gridPos":{"x":6,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"thresholds":{"steps":[{"color":"green","value":None},{"color":"yellow","value":5000},{"color":"red","value":9000}]}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_sessions_active","legendFormat":"Active"}]},

    {"id":4,"type":"stat","title":"PPPoE Active",
     "gridPos":{"x":9,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"color":{"mode":"fixed","fixedColor":"green"}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_pppoe_active","legendFormat":"PPPoE"}]},

    {"id":5,"type":"stat","title":"CPU Usage",
     "gridPos":{"x":12,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"unit":"percent","thresholds":{"steps":[{"color":"green","value":None},{"color":"yellow","value":60},{"color":"red","value":85}]}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_cpu_usage_percent","legendFormat":"CPU%"}]},

    {"id":6,"type":"stat","title":"Memory RSS",
     "gridPos":{"x":15,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"unit":"bytes","color":{"mode":"fixed","fixedColor":"purple"}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_memory_rss_bytes","legendFormat":"RSS"}]},

    {"id":7,"type":"stat","title":"RADIUS State",
     "gridPos":{"x":18,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"mappings":[{"type":"value","options":{"0":{"text":"DOWN","color":"red"},"1":{"text":"ACTIVE","color":"green"}}}],"thresholds":{"steps":[{"color":"red","value":None},{"color":"green","value":1}]}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_radius_state","legendFormat":"{{server_ip}}"}]},

    {"id":8,"type":"stat","title":"RADIUS Failures",
     "gridPos":{"x":21,"y":0,"w":3,"h":4},
     "fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"thresholds":{"steps":[{"color":"green","value":None},{"color":"red","value":1}]}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_radius_fail_count_total","legendFormat":"{{server_ip}}"}]},

    {"id":10,"type":"timeseries","title":"Sessions - Active / Starting / Finishing",
     "gridPos":{"x":0,"y":4,"w":12,"h":8},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_sessions_active","legendFormat":"Active"},
       {"datasource":"Prometheus","expr":"accel_sessions_starting","legendFormat":"Starting"},
       {"datasource":"Prometheus","expr":"accel_sessions_finishing","legendFormat":"Finishing"}
     ]},

    {"id":11,"type":"timeseries","title":"PPPoE Packet Rates",
     "gridPos":{"x":12,"y":4,"w":12,"h":8},
     "fieldConfig":{"defaults":{"unit":"pps","custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"rate(accel_pppoe_recv_padi_total[1m])","legendFormat":"PADI recv/s"},
       {"datasource":"Prometheus","expr":"rate(accel_pppoe_sent_pado_total[1m])","legendFormat":"PADO sent/s"},
       {"datasource":"Prometheus","expr":"rate(accel_pppoe_recv_padr_total[1m])","legendFormat":"PADR recv/s"},
       {"datasource":"Prometheus","expr":"rate(accel_pppoe_sent_pads_total[1m])","legendFormat":"PADS sent/s"},
       {"datasource":"Prometheus","expr":"rate(accel_pppoe_drop_padi_total[1m])","legendFormat":"PADI drop/s"}
     ]},

    {"id":12,"type":"timeseries","title":"CPU Usage %",
     "gridPos":{"x":0,"y":12,"w":8,"h":7},
     "fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100,"custom":{"lineWidth":2},"thresholds":{"steps":[{"color":"green","value":None},{"color":"yellow","value":60},{"color":"red","value":85}]}}},
     "targets":[{"datasource":"Prometheus","expr":"accel_cpu_usage_percent","legendFormat":"CPU%"}]},

    {"id":13,"type":"timeseries","title":"Memory",
     "gridPos":{"x":8,"y":12,"w":8,"h":7},
     "fieldConfig":{"defaults":{"unit":"bytes","custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_memory_rss_bytes","legendFormat":"RSS"},
       {"datasource":"Prometheus","expr":"accel_memory_virtual_bytes","legendFormat":"Virtual"}
     ]},

    {"id":14,"type":"timeseries","title":"Mempool",
     "gridPos":{"x":16,"y":12,"w":8,"h":7},
     "fieldConfig":{"defaults":{"unit":"bytes","custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_core_mempool_allocated_bytes","legendFormat":"Allocated"},
       {"datasource":"Prometheus","expr":"accel_core_mempool_available_bytes","legendFormat":"Available"}
     ]},

    {"id":20,"type":"timeseries","title":"Core Threads",
     "gridPos":{"x":0,"y":19,"w":8,"h":7},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_core_thread_count","legendFormat":"Total"},
       {"datasource":"Prometheus","expr":"accel_core_thread_active","legendFormat":"Active"}
     ]},

    {"id":21,"type":"timeseries","title":"Core Contexts",
     "gridPos":{"x":8,"y":19,"w":8,"h":7},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_core_context_count","legendFormat":"Total"},
       {"datasource":"Prometheus","expr":"accel_core_context_sleeping","legendFormat":"Sleeping"},
       {"datasource":"Prometheus","expr":"accel_core_context_pending","legendFormat":"Pending"}
     ]},

    {"id":22,"type":"timeseries","title":"MD Handlers and Timers",
     "gridPos":{"x":16,"y":19,"w":8,"h":7},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_core_md_handler_count","legendFormat":"MD handlers"},
       {"datasource":"Prometheus","expr":"accel_core_md_handler_pending","legendFormat":"MD pending"},
       {"datasource":"Prometheus","expr":"accel_core_timer_count","legendFormat":"Timers"},
       {"datasource":"Prometheus","expr":"accel_core_timer_pending","legendFormat":"Timer pending"}
     ]},

    {"id":30,"type":"timeseries","title":"RADIUS Auth Sent / Lost",
     "gridPos":{"x":0,"y":26,"w":12,"h":8},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"rate(accel_radius_auth_sent_total[1m])*60","legendFormat":"Sent/min {{server_ip}}"},
       {"datasource":"Prometheus","expr":"rate(accel_radius_auth_lost_total[1m])*60","legendFormat":"Lost/min {{server_ip}}"}
     ]},

    {"id":31,"type":"timeseries","title":"RADIUS Auth Response Time",
     "gridPos":{"x":12,"y":26,"w":12,"h":8},
     "fieldConfig":{"defaults":{"unit":"s","custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_radius_auth_avg_time_1m_seconds","legendFormat":"Avg 1m {{server_ip}}"},
       {"datasource":"Prometheus","expr":"accel_radius_auth_avg_time_5m_seconds","legendFormat":"Avg 5m {{server_ip}}"}
     ]},

    {"id":32,"type":"timeseries","title":"RADIUS Accounting Sent / Lost",
     "gridPos":{"x":0,"y":34,"w":12,"h":8},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"rate(accel_radius_acct_sent_total[1m])*60","legendFormat":"Sent/min {{server_ip}}"},
       {"datasource":"Prometheus","expr":"rate(accel_radius_acct_lost_total[1m])*60","legendFormat":"Lost/min {{server_ip}}"}
     ]},

    {"id":33,"type":"timeseries","title":"RADIUS Acct Response Time",
     "gridPos":{"x":12,"y":34,"w":12,"h":8},
     "fieldConfig":{"defaults":{"unit":"s","custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_radius_acct_avg_time_1m_seconds","legendFormat":"Avg 1m {{server_ip}}"},
       {"datasource":"Prometheus","expr":"accel_radius_acct_avg_time_5m_seconds","legendFormat":"Avg 5m {{server_ip}}"}
     ]},

    {"id":34,"type":"timeseries","title":"RADIUS Interim Sent / Lost",
     "gridPos":{"x":0,"y":42,"w":12,"h":8},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"rate(accel_radius_interim_sent_total[1m])*60","legendFormat":"Sent/min {{server_ip}}"},
       {"datasource":"Prometheus","expr":"rate(accel_radius_interim_lost_total[1m])*60","legendFormat":"Lost/min {{server_ip}}"}
     ]},

    {"id":35,"type":"timeseries","title":"RADIUS Queue and Requests",
     "gridPos":{"x":12,"y":42,"w":12,"h":8},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":2}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_radius_queue_length","legendFormat":"Queue {{server_ip}}"},
       {"datasource":"Prometheus","expr":"accel_radius_request_count","legendFormat":"Requests {{server_ip}}"}
     ]},

    {"id":40,"type":"timeseries","title":"PPPoE Discovery Totals",
     "gridPos":{"x":0,"y":50,"w":24,"h":7},
     "fieldConfig":{"defaults":{"custom":{"lineWidth":1}}},
     "targets":[
       {"datasource":"Prometheus","expr":"accel_pppoe_recv_padi_total","legendFormat":"PADI recv"},
       {"datasource":"Prometheus","expr":"accel_pppoe_sent_pado_total","legendFormat":"PADO sent"},
       {"datasource":"Prometheus","expr":"accel_pppoe_recv_padr_total","legendFormat":"PADR recv"},
       {"datasource":"Prometheus","expr":"accel_pppoe_sent_pads_total","legendFormat":"PADS sent"},
       {"datasource":"Prometheus","expr":"accel_pppoe_drop_padi_total","legendFormat":"PADI dropped"},
       {"datasource":"Prometheus","expr":"accel_pppoe_filtered_total","legendFormat":"Filtered"},
       {"datasource":"Prometheus","expr":"accel_pppoe_recv_padr_dup_total","legendFormat":"PADR dup"},
       {"datasource":"Prometheus","expr":"accel_pppoe_delayed_pado","legendFormat":"Delayed PADO"}
     ]}
  ]
}

with open('/var/lib/grafana/dashboards/accel-ppp-bras.json', 'w') as f:
    json.dump(dashboard, f, indent=2)
print(">>> Grafana dashboard JSON written")
PYEOF

chown -R grafana:grafana /var/lib/grafana/dashboards /etc/grafana/provisioning

# Firewall
iptables -D INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -p tcp --dport 3000 -j ACCEPT
netfilter-persistent save

############################
# START GRAFANA
############################
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server

echo ">>> Waiting for Grafana (max 120s)..."
GRAFANA_URL="http://localhost:3000"
ELAPSED=0
until curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1; do
  sleep 3 || true; ELAPSED=$((ELAPSED+3))
  echo "    ...${ELAPSED}s"
  if [ "$ELAPSED" -ge 120 ]; then
    echo "ERROR: Grafana did not start"
    journalctl -u grafana-server --no-pager -n 20
    exit 1
  fi
done
echo ">>> Grafana UP"

curl -sf -u "admin:${GRAFANA_ADMIN_PASS}" \
  -X POST "${GRAFANA_URL}/api/admin/provisioning/dashboards/reload" > /dev/null 2>&1 \
  && echo ">>> Dashboards provisioned" || true

GF_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -u "admin:${GRAFANA_ADMIN_PASS}" "${GRAFANA_URL}/api/org")
[ "$GF_HTTP" = "200" ] && echo ">>> Admin login OK" || echo ">>> Admin login HTTP: ${GF_HTTP}"

############################
# DONE
############################
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "================================================================"
echo "  PART 2 COMPLETE - Monitoring Stack"
echo "================================================================"
echo "  accel-exporter : http://localhost:${EXPORTER_PORT}/metrics"
echo "  Prometheus     : http://localhost:9090"
echo "  Grafana        : http://${SERVER_IP}:3000"
echo "  Grafana login  : admin / ${GRAFANA_ADMIN_PASS}"
echo "  Dashboard      : ISP / Accel-PPP -> Accel-PPP BRAS Monitor"
echo "================================================================"
echo ""
echo "Verify:"
echo "  systemctl status accel-exporter prometheus grafana-server"
echo "  curl -s http://localhost:${EXPORTER_PORT}/metrics | grep accel_sessions_active"
echo "  curl -s http://localhost:9090/-/healthy"
echo "  curl -s http://localhost:3000/api/health"
echo "  curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health"
echo "================================================================"
