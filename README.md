# Hetzner Debian Installer

This repository contains a Bash script that automatically installs a minimal Debian operating system on your Hetzner dedicated server directly from **Rescue Mode**.

The installation is performed via official Debian tools (`debootstrap`), ensuring full transparency and control over the entire installation process.

---

## ⚡ Quick Start Guide

To install Debian on your Hetzner server:

1. **Reboot** your server into **Rescue Mode** via the Hetzner control panel.
2. Connect to your server via SSH.
3. Run the following command:
```bash
wget https://github.com/username/hetzner-debian-installer/releases/latest/download/hetzner-debian-installer.bash && chmod +x hetzner-debian-installer.bash && ./hetzner-debian-installer.bash
```

The installation script runs automatically within a detached `screen` session.

> **ℹ️ Note:**  
> During the first interactive run, your chosen parameters will automatically be saved into `hetzner-debian-installer.conf.bash`.  
> You can reuse this file to perform future installations non-interactively.

**In case of SSH connection loss**, reconnect and resume the installation by running:
```bash
screen -r debian_install
```
