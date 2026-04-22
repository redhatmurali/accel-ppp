#!/bin/bash
# =============================================================================
# Accel-PPP v2 — Hardened ISP Installer (10k+ Users)
# Fixes: firewall ordering, conntrack, QoS/HTB, sysctl, RADIUS shaping
# Fix v2: CLI section now exposes BOTH Unix socket AND TCP port 2001
#         so both  accel-cmd show stat  AND
#                  accel-cmd -s /var/run/accel-ppp/cli.sock show stat  work.
# =============================================================================
set -euo pipefail

############################
# EDIT THESE VARIABLES
############################
LAN_IF="ens34"           # PPPoE interface (OLT side)
WAN_IF="ens33"           # Internet/uplink interface

RADIUS_IP="192.168.29.60"
# SECURITY: load secret from env or file — never hardcode
# Run: echo "yourpassword" > /etc/accel-ppp-radius.secret && chmod 600 /etc/accel-ppp-radius.secret
RADIUS_SECRET_FILE="/etc/accel-ppp-radius.secret"

IP_POOL_START="10.10.0.2"
IP_POOL_END="10.10.50.254"
GW_IP="10.10.0.1"

# WAN uplink speed (for TC/HTB global shaping)
WAN_UPLINK_MBIT=1000
WAN_DOWNLINK_MBIT=1000

# CPU core count for thread tuning
CPU_CORES=$(nproc)
THREAD_COUNT=$(( CPU_CORES * 4 ))

############################
# PREFLIGHT CHECKS
############################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root." >&2
  exit 1
fi

if [ ! -f "$RADIUS_SECRET_FILE" ]; then
  echo "ERROR: RADIUS secret file not found: $RADIUS_SECRET_FILE"
  echo "  Create it: echo 'yourpassword' > $RADIUS_SECRET_FILE && chmod 600 $RADIUS_SECRET_FILE"
  exit 1
fi

RADIUS_SECRET=$(cat "$RADIUS_SECRET_FILE")

############################
# SYSTEM UPDATE & DEPS
############################
apt-get update
# dist-upgrade handles held-back kernel/netplan packages without breaking anything
apt-get dist-upgrade -y
apt-get install -y --fix-missing \
  build-essential git cmake make gcc g++ \
  libssl-dev libpcre2-dev libpcre3-dev liblua5.1-0-dev \
  libnl-3-dev libnl-genl-3-dev libreadline-dev \
  libxtables-dev libip4tc-dev libip6tc-dev \
  iptables iptables-persistent netfilter-persistent \
  iproute2 curl wget

############################
# BUILD ACCEL-PPP — OFFICIAL SOURCE
# Official org:    https://github.com/accel-ppp/accel-ppp  (actively maintained)
# Original author: https://github.com/xebd/accel-ppp       (syncs occasionally)
# Project site:    https://accel-ppp.org
############################
cd /usr/src
ACCEL_REPO="https://github.com/accel-ppp/accel-ppp.git"

# Best practice: pin to a specific tag or commit hash.
# To find the latest tag after cloning:  git tag --sort=-v:refname | head -5
# Then set ACCEL_TAG to that value, e.g. "1.12.0"
ACCEL_TAG=""   # Leave empty to use latest commit on master (less stable)

if [ ! -d "accel-ppp" ]; then
  git clone "$ACCEL_REPO"
fi

cd accel-ppp
git fetch --tags origin

if [ -n "$ACCEL_TAG" ]; then
  echo ">>> Checking out tag: $ACCEL_TAG"
  git checkout "tags/$ACCEL_TAG" -b "build-$ACCEL_TAG"
else
  echo ">>> No tag set — using latest master"
  git checkout master && git pull origin master
  echo ">>> Current commit: $(git rev-parse HEAD)"
  echo "    Available tags:  $(git tag --sort=-v:refname | head -5 | tr '\n' ' ')"
  echo "    Tip: pin ACCEL_TAG to a tag above for reproducible builds."
fi

rm -rf build && mkdir build && cd build

cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_PPTP_DRIVER=FALSE \
  -DBUILD_L2TP=FALSE \
  -DBUILD_SSTP=FALSE \
  -DRADIUS=TRUE \
  -DSHAPER=TRUE \
  -DLOG_PGSQL=FALSE \
  -DNETSNMP=FALSE

make -j"$CPU_CORES"
make install

mkdir -p /var/log/accel-ppp

############################
# CONFIG FILE
############################
cat > /etc/accel-ppp.conf <<EOF
[modules]
log_file
pppoe
auth_pap
auth_chap_md5
radius
ippool
shaper

[core]
thread-count=$THREAD_COUNT
max-sessions=12000

[pppoe]
interface=$LAN_IF
padi-limit=10000
# Prevent PADI storms from a single MAC
pado-delay=0
verbose=0

[auth]
auth=chap-md5,pap

[radius]
server=$RADIUS_IP,$RADIUS_SECRET,auth-port=1812,acct-port=1813
nas-identifier=accel-ppp-01
nas-ip-address=$GW_IP
acct-interim-interval=120
timeout=5
max-try=5
# RADIUS delivers per-user speeds via these attributes:
# Accel-Download-Speed  (VSA 14, type integer — kbps)
# Accel-Upload-Speed    (VSA 15, type integer — kbps)
# Or standard: WISPr-Bandwidth-Max-Down / WISPr-Bandwidth-Max-Up

[ippool]
gw-ip-address=$GW_IP
$IP_POOL_START-$IP_POOL_END
# Pre-warm the pool for faster session setup under load
preload=1

[dns]
dns1=8.8.8.8
dns2=1.1.1.1

# ===========================
# QoS / Shaper Configuration
# ===========================
# The shaper uses Linux HTB (Hierarchical Token Bucket).
# Per-user rates come from RADIUS attributes (see above).
# Fallback default speeds if RADIUS doesn't supply them:
[shaper]
vendor=linux
rate-multiplier=1
# Default rates for users whose RADIUS profile has no speed attributes
down-rate-limit=50000    # 50 Mbps default download (kbps)
up-rate-limit=10000      # 10 Mbps default upload (kbps)
# Burst: allow short bursts up to 2x rate for responsiveness
down-burst-ratio=2
up-burst-ratio=2

# ===========================
# CLI — FIXED: Both UNIX socket AND TCP enabled
# UNIX socket : accel-cmd -s /var/run/accel-ppp/cli.sock show stat
# TCP port    : accel-cmd show stat   (default localhost:2001)
# ===========================
[cli]
unix=/var/run/accel-ppp/cli.sock
tcp=127.0.0.1:2001

[log]
log-file=/var/log/accel-ppp/accel.log
log-emerg=/var/log/accel-ppp/emerg.log
level=2
EOF

chmod 640 /etc/accel-ppp.conf

############################
# SYSCTL — 10k USER TUNING
############################
cat > /etc/sysctl.d/99-accel-ppp.conf <<EOF
# --- Routing ---
net.ipv4.ip_forward=1

# --- Conntrack: must support 10k users × multiple flows each ---
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_udp_timeout=120
net.netfilter.nf_conntrack_generic_timeout=120
# Reserve conntrack bucket memory
net.netfilter.nf_conntrack_buckets=131072

# --- Socket buffers for high-throughput PPP ---
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728

# --- Queue tuning ---
net.core.somaxconn=65535
net.core.netdev_max_backlog=500000
net.ipv4.tcp_max_syn_backlog=65535

# --- Time-wait / fin-wait tuning under load ---
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=20
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5

# --- ARP protection (PPPoE best practice) ---
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1

# --- File descriptors ---
fs.file-max=2000000
EOF

sysctl --system

# Load conntrack module early
modprobe nf_conntrack
echo "nf_conntrack" >> /etc/modules-load.d/accel-ppp.conf

############################
# IPTABLES — CORRECT ORDER
############################

# Default policies — FAIL CLOSED
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# Flush everything cleanly
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

# --- INPUT: allow only what's needed on this box ---
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH from management net (CHANGE THIS to your mgmt subnet)
iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT

# Allow RADIUS replies inbound
iptables -A INPUT -s "$RADIUS_IP" -p udp --sport 1812 -j ACCEPT
iptables -A INPUT -s "$RADIUS_IP" -p udp --sport 1813 -j ACCEPT

# Allow accel-cmd TCP CLI access from localhost only
iptables -A INPUT -i lo -p tcp --dport 2001 -j ACCEPT

# Allow PPPoE discovery frames on LAN interface (kernel handles pppX, but needed for LCP)
# NOTE: PPPoE Discovery (0x8863) and Session (0x8864) are EtherType values,
# NOT IP protocol numbers. iptables operates at L3 and cannot match them.
# The kernel PPPoE driver (pppoe module) handles these L2 frames directly
# on $LAN_IF — no iptables rule needed or valid here.

# Allow ICMP echo-request to this box (rate limited)
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec --limit-burst 10 -j ACCEPT

# Drop everything else to INPUT
iptables -A INPUT -j DROP

# --- FORWARD rules (ORDER MATTERS) ---

# 1. Accept established/related first (fast path)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# 2. Drop invalid packets
iptables -A FORWARD -m state --state INVALID -j DROP

# 3. Anti-spoofing: PPP sessions sourcing from outside the pool
iptables -A FORWARD -i "$LAN_IF" ! -s 10.10.0.0/16 -j DROP

# 4. User isolation: block subscriber-to-subscriber traffic
iptables -A FORWARD -s 10.10.0.0/16 -d 10.10.0.0/16 -j DROP

# 5. Block RFC1918 leakage FROM WAN into subscriber space
iptables -A FORWARD -i "$WAN_IF" -s 10.0.0.0/8 -j DROP
iptables -A FORWARD -i "$WAN_IF" -s 172.16.0.0/12 -j DROP
iptables -A FORWARD -i "$WAN_IF" -s 192.168.0.0/16 -j DROP

# 6. ICMP rate limit (forward)
iptables -A FORWARD -p icmp -m limit --limit 20/sec --limit-burst 50 -j ACCEPT
iptables -A FORWARD -p icmp -j DROP

# 7. Allow subscribers to reach internet
iptables -A FORWARD -s 10.10.0.0/16 -o "$WAN_IF" -j ACCEPT

# NOTE: Rule 1 handles WAN→subscriber return traffic via ESTABLISHED/RELATED

# --- NAT ---
iptables -t nat -A POSTROUTING -s 10.10.0.0/16 -o "$WAN_IF" -j MASQUERADE

# --- MANGLE: DSCP marking for QoS classification ---
# Mark interactive traffic (SSH, DNS, VoIP) as high priority
iptables -t mangle -A FORWARD -p tcp --dport 22  -j DSCP --set-dscp-class AF31
iptables -t mangle -A FORWARD -p udp --dport 53  -j DSCP --set-dscp-class AF31
iptables -t mangle -A FORWARD -p udp --dport 5060 -j DSCP --set-dscp-class EF   # SIP/VoIP
iptables -t mangle -A FORWARD -p udp --dport 5061 -j DSCP --set-dscp-class EF

netfilter-persistent save

############################
# TC/HTB — GLOBAL WAN QoS
# Protects uplink from any single burst. Per-user rates
# are handled by Accel-PPP's shaper (see [shaper] above).
############################

# Clear existing rules
tc qdisc del dev "$WAN_IF" root 2>/dev/null || true

# Root HTB qdisc
tc qdisc add dev "$WAN_IF" root handle 1: htb default 30

# Total WAN bandwidth ceiling
tc class add dev "$WAN_IF" parent 1:  classid 1:1  htb rate "${WAN_UPLINK_MBIT}mbit"

# High-priority class (VoIP, DNS, SSH) — 20% guaranteed, can burst to 100%
tc class add dev "$WAN_IF" parent 1:1 classid 1:10 htb rate "$(( WAN_UPLINK_MBIT * 20 / 100 ))mbit" \
  ceil "${WAN_UPLINK_MBIT}mbit" prio 1 burst 32k

# Normal traffic — 70% guaranteed
tc class add dev "$WAN_IF" parent 1:1 classid 1:20 htb rate "$(( WAN_UPLINK_MBIT * 70 / 100 ))mbit" \
  ceil "${WAN_UPLINK_MBIT}mbit" prio 2 burst 64k

# Bulk / best-effort — 10% guaranteed
tc class add dev "$WAN_IF" parent 1:1 classid 1:30 htb rate "$(( WAN_UPLINK_MBIT * 10 / 100 ))mbit" \
  ceil "${WAN_UPLINK_MBIT}mbit" prio 3 burst 16k

# SFQ fairness within each class (prevents single flow domination)
tc qdisc add dev "$WAN_IF" parent 1:10 handle 10: sfq perturb 10
tc qdisc add dev "$WAN_IF" parent 1:20 handle 20: sfq perturb 10
tc qdisc add dev "$WAN_IF" parent 1:30 handle 30: sfq perturb 10

# Filters: match DSCP → class
tc filter add dev "$WAN_IF" parent 1: protocol ip prio 1 u32 \
  match ip dsfield 0x68 0xfc flowid 1:10  # EF (VoIP)
tc filter add dev "$WAN_IF" parent 1: protocol ip prio 2 u32 \
  match ip dsfield 0x38 0xfc flowid 1:10  # AF31 (interactive)

# Persist TC rules across reboots via a systemd unit
cat > /etc/systemd/system/tc-qos.service <<SVC
[Unit]
Description=TC QoS rules for WAN interface
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash /etc/tc-qos.sh
ExecStop=/sbin/tc qdisc del dev $WAN_IF root

[Install]
WantedBy=multi-user.target
SVC

# Save the TC commands to a file the service will run
cat > /etc/tc-qos.sh <<TCSCRIPT
#!/bin/bash
WAN_IF="$WAN_IF"
WAN_UPLINK_MBIT=$WAN_UPLINK_MBIT
tc qdisc del dev "\$WAN_IF" root 2>/dev/null || true
tc qdisc add dev "\$WAN_IF" root handle 1: htb default 30
tc class add dev "\$WAN_IF" parent 1:  classid 1:1  htb rate "\${WAN_UPLINK_MBIT}mbit"
tc class add dev "\$WAN_IF" parent 1:1 classid 1:10 htb rate "\$(( WAN_UPLINK_MBIT * 20 / 100 ))mbit" ceil "\${WAN_UPLINK_MBIT}mbit" prio 1 burst 32k
tc class add dev "\$WAN_IF" parent 1:1 classid 1:20 htb rate "\$(( WAN_UPLINK_MBIT * 70 / 100 ))mbit" ceil "\${WAN_UPLINK_MBIT}mbit" prio 2 burst 64k
tc class add dev "\$WAN_IF" parent 1:1 classid 1:30 htb rate "\$(( WAN_UPLINK_MBIT * 10 / 100 ))mbit" ceil "\${WAN_UPLINK_MBIT}mbit" prio 3 burst 16k
tc qdisc add dev "\$WAN_IF" parent 1:10 handle 10: sfq perturb 10
tc qdisc add dev "\$WAN_IF" parent 1:20 handle 20: sfq perturb 10
tc qdisc add dev "\$WAN_IF" parent 1:30 handle 30: sfq perturb 10
tc filter add dev "\$WAN_IF" parent 1: protocol ip prio 1 u32 match ip dsfield 0x68 0xfc flowid 1:10
tc filter add dev "\$WAN_IF" parent 1: protocol ip prio 2 u32 match ip dsfield 0x38 0xfc flowid 1:10
TCSCRIPT
chmod +x /etc/tc-qos.sh

############################
# FILE DESCRIPTOR LIMITS
############################
cat > /etc/security/limits.d/accel-ppp.conf <<EOF
*    soft nofile 1000000
*    hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

# Systemd override for service FD limit
mkdir -p /etc/systemd/system/accel-ppp.service.d
cat > /etc/systemd/system/accel-ppp.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=1000000
LimitNPROC=65536
EOF

############################
# UNIX SOCKET PERMISSIONS
############################
mkdir -p /var/run/accel-ppp
chmod 750 /var/run/accel-ppp

############################
# SYSTEMD SERVICE
############################
cat > /etc/systemd/system/accel-ppp.service <<EOF
[Unit]
Description=Accel-PPP PPPoE Server
After=network.target tc-qos.service
Requires=network.target

[Service]
ExecStart=/usr/local/sbin/accel-pppd -c /etc/accel-ppp.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000
LimitNPROC=65536
# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/log/accel-ppp /var/run/accel-ppp

[Install]
WantedBy=multi-user.target
EOF

############################
# LOGROTATE
############################
cat > /etc/logrotate.d/accel-ppp <<EOF
/var/log/accel-ppp/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    postrotate
        systemctl kill -s HUP accel-ppp
    endscript
}
EOF

############################
# START SERVICES
############################
systemctl daemon-reload
systemctl enable tc-qos
systemctl enable accel-ppp
systemctl restart tc-qos
systemctl restart accel-ppp

#=========================================================
# Fix 1 — Create /var/run/accel-ppp on boot automatically (systemd handles it)
mkdir -p /etc/systemd/system/accel-ppp.service.d/
cat > /etc/systemd/system/accel-ppp.service.d/runtime-dir.conf << 'EOF'
[Service]
RuntimeDirectory=accel-ppp
RuntimeDirectoryMode=0750
EOF

# Fix 2 — Fix service dependencies so it waits for network properly
cat > /etc/systemd/system/accel-ppp.service << 'EOF'
[Unit]
Description=Accel-PPP PPPoE Server
After=network-online.target tc-qos.service
Wants=network-online.target tc-qos.service

[Service]
RuntimeDirectory=accel-ppp
RuntimeDirectoryMode=0750
ExecStart=/usr/local/sbin/accel-pppd -c /etc/accel-ppp.conf
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
TimeoutStartSec=60
LimitNOFILE=1000000
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
EOF

# Fix 3 — Enable network-online.target
systemctl enable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager-wait-online.service 2>/dev/null || true

# Fix 4 — Reload and enable everything
systemctl daemon-reload
systemctl enable tc-qos accel-ppp

# Test with a reboot simulation
systemctl restart tc-qos
systemctl restart accel-ppp
sleep 3
systemctl status accel-ppp --no-pager | head -5
#=========================================================
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
netfilter-persistent save
# ============================================================
# PART 1 COMPLETE
# ============================================================
echo ""
echo "================================================================"
echo "  🟢  PART 1 COMPLETE — Accel-PPP Core Network"
echo "================================================================"
echo "  LAN (PPPoE)    : $LAN_IF"
echo "  WAN            : $WAN_IF"
echo "  IP Pool        : $IP_POOL_START – $IP_POOL_END"
echo "  RADIUS         : $RADIUS_IP"
echo "  Threads        : $THREAD_COUNT  (${CPU_CORES} cores × 4)"
echo "  Conntrack max  : 524,288 entries"
echo "  FD limit       : 1,000,000"
echo "  WAN QoS        : ${WAN_UPLINK_MBIT}Mbps HTB (VoIP/Normal/Bulk)"
echo "================================================================"
echo ""
echo "👉 Verify service:"
echo "  systemctl status accel-ppp"
echo "  systemctl status tc-qos"
echo ""
echo "👉 Verify accel-cmd (TCP — default):"
echo "  accel-cmd show stat"
echo "  accel-cmd show sessions"
echo "  accel-cmd show version"
echo ""
echo "👉 Verify accel-cmd (UNIX socket — alternative):"
echo "  accel-cmd -s /var/run/accel-ppp/cli.sock show stat"
echo "  accel-cmd -s /var/run/accel-ppp/cli.sock show sessions"
echo ""
echo "👉 Verify kernel & network:"
echo "  tc -s class show dev $WAN_IF"
echo "  cat /proc/sys/net/netfilter/nf_conntrack_count"
echo "  cat /proc/sys/net/netfilter/nf_conntrack_max"
echo "  ss -tlnp | grep 2001"
echo "  lsmod | grep nf_conntrack"
echo ""
echo "👉 Verify logs (check for errors):"
echo "  tail -50 /var/log/accel-ppp/accel.log"
echo "  tail -20 /var/log/accel-ppp/emerg.log"
echo "  journalctl -u accel-ppp -n 30"
echo ""
echo "👉 RADIUS QoS attributes (per subscriber profile):"
echo "  Filter-Id = 102400           (100 Mbps symmetric, in kbps)"
echo "  Filter-Id = 102400/20480     (100 Mbps down / 20 Mbps up)"
echo ""
echo "  ▶  Run part2-monitoring.sh next to install Prometheus + Grafana"
echo "================================================================"
