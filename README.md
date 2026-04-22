# 🚀 Accel-PPP Installation Guide (Ubuntu 22.04)

## 📋 Requirements

- Ubuntu 22.04 Server  
  Download: https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso

---

## ⚙️ Installation Steps

### 1️⃣ Set RADIUS Secret

```bash
echo 'yourpassword' > /etc/accel-ppp-radius.secret
chmod 600 /etc/accel-ppp-radius.secret
```

---

### 2️⃣ Make Script Executable

```bash
chmod +x accel-ppp-hardened-install.sh
```

---

### 3️⃣ Run Installation Script

```bash
bash accel-ppp-hardened-install.sh
```

---

## 🔁 Re-run Script (Optional)

```bash
chmod +x accel-ppp-hardened-install.sh
bash accel-ppp-hardened-install.sh
```

---

## ✅ Notes

- Run all commands as **root user**
- Ensure internet connectivity
- Place script in current directory

---

## 🎯 Output

- Accel-PPP installed
- PPPoE server ready
- RADIUS authentication enabled

---

## ⚠️ Security

- Keep `/etc/accel-ppp-radius.secret` secure
- Do not share credentials

---

## 🚀 Next Steps

- Configure FreeRADIUS
- Add PPPoE users
- Setup monitoring (Grafana / Prometheus)
