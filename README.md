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

## 🛠 Advanced: Using Configuration Files

The installer supports automatic configuration through the use of a **predefined configuration file**:

### How it works:

1. **Create** a file named `hetzner-debian-installer.conf.bash` in the same directory as the installation script.

   Example configuration (`hetzner-debian-installer.conf.bash`):

   ```bash
   # Partitioning
   PART_DRIVE1="/dev/nvme0n1"
   PART_DRIVE2="/dev/nvme1n1"
   PART_USE_RAID="yes"
   PART_RAID_LEVEL="1"
   PART_BOOT_SIZE="512M"
   PART_SWAP_SIZE="32G"
   PART_ROOT_FS="ext4"
   PART_BOOT_FS="ext3"

   # Debian installation
   DEBIAN_RELEASE="stable"
   DEBIAN_MIRROR="http://deb.debian.org/debian"

   ....
   
   ```

2. **Run the installer script** as usual. It will automatically detect and apply configuration values from the file.  
   If some parameters are not defined, the installer will ask interactively during runtime.

3. Before starting the installation, the installer will display a **summary of the configuration** and ask you to confirm.
