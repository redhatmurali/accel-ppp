#  Accel-PPP Installation Guide (Ubuntu 22.04)

##  Requirements
- Ubuntu 22.04 Server  
  Download: https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso

## Installation Steps

### Set RADIUS Secret

```bash
echo 'yourpassword' > /etc/accel-ppp-radius.secret && chmod 600 /etc/accel-ppp-radius.secret

bash -c "$(wget -qO- https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part1-core.sh)"
bash -c "$(wget -qO- https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part2-pro-graf.sh)"
bash -c "$(wget -qO- https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part3-nat-graf.sh)"
bash -c "$(wget -qO- https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part4-log-install.sh)"
bash -c "$(wget -qO- https://raw.githubusercontent.com/redhatmurali/accel-ppp/main/part5-GenieACS.sh)"

```
### Temporary (instant apply) 4 million conntrack
```bash
sysctl -w net.netfilter.nf_conntrack_max=4194304
echo 1048576 > /sys/module/nf_conntrack/parameters/hashsize
```
### Permanent (after reboot) 4 million conntrack
```bash
echo "net.netfilter.nf_conntrack_max=4194304" >> /etc/sysctl.conf
sysctl -p

echo "options nf_conntrack hashsize=1048576" > /etc/modprobe.d/nf_conntrack.conf
```
### Verify 4 million conntrack
```bash
cat /proc/sys/net/netfilter/nf_conntrack_max
cat /sys/module/nf_conntrack/parameters/hashsize
```
