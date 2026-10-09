# Accel-PPP Installation Guide — Ubuntu 22.04

Installation and configuration guide for deploying an Accel-PPP-based network services stack on Ubuntu Server 22.04 LTS.

The setup includes core installation, monitoring, logging, and GenieACS integration scripts, along with Linux connection-tracking configuration for high-connection workloads.

## Requirements

- Ubuntu Server 22.04 LTS (64-bit)
- Root or `sudo` access
- Internet connectivity
- Sufficient CPU, RAM, and storage for the expected workload

**Ubuntu Server download:** [Ubuntu 22.04 Server ISO](https://releases.ubuntu.com/22.04/)

## Installation

### 1. Configure the RADIUS secret

Create a protected file for the RADIUS shared secret:

```bash
echo 'REPLACE_WITH_A_STRONG_SECRET' | sudo tee /etc/accel-ppp-radius.secret >/dev/null
sudo chmod 600 /etc/accel-ppp-radius.secret
```

Use the same secret on the corresponding RADIUS client and server. Do not commit real secrets to GitHub.

### 2. Run the installation scripts

The following scripts are provided by the repository:

| Script | Purpose |
|---|---|
| `part1-core.sh` | Core installation |
| `part2-pro-graf.sh` | Monitoring and Grafana components |
| `part3-nat-graf.sh` | NAT-related monitoring/configuration |
| `part4-log-install.sh` | Logging components |
| `part5-GenieACS.sh` | GenieACS integration |

Download and inspect the scripts before running them with root privileges.

```bash
mkdir -p ~/accel-ppp-install
cd ~/accel-ppp-install

wget https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part1-core.sh
wget https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part2-pro-graf.sh
wget https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part3-nat-graf.sh
wget https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part4-log-install.sh
wget https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part5-GenieACS.sh
```

Review each script:

```bash
less part1-core.sh
```

After reviewing the scripts and confirming their source, run them in the intended order:

```bash
sudo bash part1-core.sh
sudo bash part2-pro-graf.sh
sudo bash part3-nat-graf.sh
sudo bash part4-log-install.sh
sudo bash part5-GenieACS.sh
```

The components installed by each script depend on its actual implementation and configuration.

## Configure connection tracking for 4 million entries

Linux connection tracking uses kernel parameters to control the maximum number of tracked connections and the hash table size.

### 1. Temporary configuration

These settings apply immediately but do not persist across reboot:

```bash
sudo sysctl -w net.netfilter.nf_conntrack_max=4194304

echo 1048576 | sudo tee /sys/module/nf_conntrack/parameters/hashsize
```

### 2. Persistent configuration

Set the maximum connection count in a dedicated sysctl configuration file:

```bash
echo 'net.netfilter.nf_conntrack_max=4194304' |
  sudo tee /etc/sysctl.d/99-accel-ppp.conf

sudo sysctl --system
```

Configure the hash table size for module loading:

```bash
echo 'options nf_conntrack hashsize=1048576' |
  sudo tee /etc/modprobe.d/nf_conntrack.conf
```

**Important:** The module hash size is normally applied when `nf_conntrack` is loaded. Writing the file does not guarantee that an already-loaded module will adopt the new value. Apply the setting during a planned reboot or appropriate maintenance window and verify it afterward.

### 3. Verify the settings

```bash
cat /proc/sys/net/netfilter/nf_conntrack_max

cat /sys/module/nf_conntrack/parameters/hashsize
```

Expected values, if successfully applied:

| Parameter | Value |
|---|---:|
| Maximum tracked connections | 4,194,304 |
| Hash table size | 1,048,576 |

## Operational considerations

- Connection tracking consumes kernel memory; actual memory usage depends on traffic patterns and connection count.
- Size the settings according to available RAM and expected concurrent connections.
- Monitor connection-table usage and dropped packets under load.
- Validate the configuration on a test server before deploying it to production.

## Repository

[View Accel-PPP installation scripts on GitHub](https://github.com/redhatmurali/accel-ppp)

## Security

Never publish RADIUS secrets, passwords, private keys, or other credentials. Review installation scripts before running them as root, and restrict access to management interfaces and monitoring dashboards.

## License

Add a `LICENSE` file if you intend to distribute this project for reuse.
