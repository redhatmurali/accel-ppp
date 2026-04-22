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
