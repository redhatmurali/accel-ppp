#  Accel-PPP Installation Guide (Ubuntu 22.04)

##  Requirements
- Ubuntu 22.04 Server  
  Download: https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso

## Installation Steps

### 1Set RADIUS Secret

```bash
echo 'yourpassword' > /etc/accel-ppp-radius.secret && chmod 600 /etc/accel-ppp-radius.secret

chmod +x part1-core.sh && bash part1-core.sh

chmod +x part2-pro-graf.sh && bash part2-pro-graf.sh

chmod +x part3-nat-graf.sh && part3-nat-graf.sh

chmod +x part4-log-install.sh && bash part4-log-install.sh

chmod +x part5-GenieACS.sh && bash part5-GenieACS.sh
```
