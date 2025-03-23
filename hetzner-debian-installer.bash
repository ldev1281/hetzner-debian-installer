#!/bin/bash
set -e

CONFIG_FILE="hetzner-debian-installer.conf.bash"
SESSION_NAME="debian_install"

# Load config file if exists
if [ -f "$CONFIG_FILE" ]; then
    echo "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "No configuration file found, proceeding interactively."
fi

# Auto-start inside screen session
if [ -z "$STY" ]; then
    if ! command -v screen &>/dev/null; then
        echo "Installing screen..."
        apt update && apt install screen -y
    fi
    echo "Launching installation inside screen session '$SESSION_NAME'..."
    screen -dmS "$SESSION_NAME" bash "$0"
    echo "Reconnect with: screen -r $SESSION_NAME"
    exit 0
fi

screen -S "$STY" -X sessionname "$SESSION_NAME"

### CONFIGURE FUNCTIONS ###

configure_partitioning() {
    echo "[Configuring] Partitioning parameters"
    : "${PART_DRIVE1:?$(read -rp 'Primary disk (e.g., /dev/nvme0n1): ' PART_DRIVE1)}"
    : "${PART_DRIVE2:?$(read -rp 'Secondary disk for RAID (optional): ' PART_DRIVE2)}"
    : "${PART_USE_RAID:?$(read -rp 'Use RAID? (yes/no): ' PART_USE_RAID)}"
    : "${PART_RAID_LEVEL:?$(read -rp 'RAID Level (e.g., 1): ' PART_RAID_LEVEL)}"
    : "${PART_BOOT_SIZE:?$(read -rp 'Boot partition size (e.g., 512M): ' PART_BOOT_SIZE)}"
    : "${PART_SWAP_SIZE:?$(read -rp 'Swap size (e.g., 32G): ' PART_SWAP_SIZE)}"
    : "${PART_ROOT_FS:?$(read -rp 'Root filesystem type (e.g., ext4): ' PART_ROOT_FS)}"
    : "${PART_BOOT_FS:?$(read -rp 'Boot filesystem type (e.g., ext3): ' PART_BOOT_FS)}"
}

configure_debian_install() {
    echo "[Configuring] Debian install parameters"
    : "${DEBIAN_RELEASE:?$(read -rp 'Debian release (e.g., stable): ' DEBIAN_RELEASE)}"
    : "${DEBIAN_MIRROR:?$(read -rp 'Debian mirror: ' DEBIAN_MIRROR)}"
}

configure_network() {
    echo "[Configuring] Network parameters"
    : "${NETWORK_USE_DHCP:?$(read -rp 'Use DHCP? (yes/no): ' NETWORK_USE_DHCP)}"
}

configure_bootloader() {
    echo "[Configuring] Bootloader parameters"
    if [ -z "${GRUB_TARGET_DRIVES[*]}" ]; then
        read -rp 'GRUB target drives (space-separated): ' -a GRUB_TARGET_DRIVES
    fi
}

configure_initial_config() {
  echo "[Configuring] Initial system settings"

  read -p "Enter hostname [debian-server]: " SYSTEM_HOSTNAME
  SYSTEM_HOSTNAME=${SYSTEM_HOSTNAME:-debian-server}

  read -p "Enter username for sudo access [admin]: " SYSTEM_SUDO_USER
  SYSTEM_SUDO_USER=${SYSTEM_SUDO_USER:-admin}

  while true; do
    read -s -p "Enter password for user '$SYSTEM_SUDO_USER': " password
    echo
    read -s -p "Confirm password: " password2
    echo
    if [ "$password" != "$password2" ]; then
      echo "[WARN] Passwords do not match. Try again."
    else
      break
    fi
  done

  SYSTEM_USER_PASSWORD_HASH=$(openssl passwd -6 "$password")

  echo "Saving user config to $CONFIG_FILE"
  cat <<EOF >> "$CONFIG_FILE"
SYSTEM_HOSTNAME="$SYSTEM_HOSTNAME"
SYSTEM_SUDO_USER="$SYSTEM_SUDO_USER"
SYSTEM_USER_PASSWORD_HASH="$SYSTEM_USER_PASSWORD_HASH"
EOF
}

run_cleanup() {
  echo "[INFO] Cleaning up temporary mounts and rebooting..."

  # Удалить chroot-связи, если они есть
  for dir in dev proc sys; do
    if mountpoint -q "$INSTALL_TARGET/$dir"; then
      echo "[INFO] Unmounting $INSTALL_TARGET/$dir"
      umount -l "$INSTALL_TARGET/$dir"
    fi
  done

  if mountpoint -q "$INSTALL_TARGET/boot"; then
    echo "[INFO] Unmounting $INSTALL_TARGET/boot"
    umount "$INSTALL_TARGET/boot"
  fi

  if mountpoint -q "$INSTALL_TARGET"; then
    echo "[INFO] Unmounting $INSTALL_TARGET"
    umount "$INSTALL_TARGET"
  fi

  echo "[INFO] Syncing filesystem..."
  sync

  echo "[OK] Installation complete. Rebooting system..."
  reboot
}


### RUN FUNCTIONS (Empty placeholders) ###
run_partitioning() {
  set -euo pipefail

  source "$CONFIG_FILE"

  echo "[INFO] Partitioning disks according to the configuration:"
  cat "$CONFIG_FILE"

  read -p "Continue? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "[ABORTED] Operation cancelled by user."
    exit 1
  fi

  # Проверка, что диск существует
  [ ! -b "$PART_DRIVE1" ] && echo "[ERROR] Primary disk $PART_DRIVE1 not found" && exit 1
  if [ "$PART_USE_RAID" == "yes" ]; then
    [ ! -b "$PART_DRIVE2" ] && echo "[ERROR] Secondary disk $PART_DRIVE2 not found" && exit 1
    echo "[INFO] Creating RAID array..."
    yes | mdadm --create /dev/md0 --level="$PART_RAID_LEVEL" --raid-devices=2 "$PART_DRIVE1" "$PART_DRIVE2"
    target_disk="/dev/md0"
  else
    target_disk="$PART_DRIVE1"
  fi

  echo "[INFO] Creating GPT partition table..."
  parted -s "$target_disk" mklabel gpt

  echo "[INFO] Creating /boot partition..."
  parted -s "$target_disk" mkpart primary "$PART_BOOT_FS" 1MiB "$PART_BOOT_SIZE"
  parted -s "$target_disk" set 1 boot on

  echo "[INFO] Creating swap partition..."
  BOOT_END=$(numfmt --from=iec "$PART_BOOT_SIZE")
  SWAP_END=$(numfmt --from=iec "$PART_SWAP_SIZE")
  parted -s "$target_disk" mkpart primary linux-swap "$PART_BOOT_SIZE" "$((BOOT_END + SWAP_END))B"

  echo "[INFO] Creating root partition..."
  parted -s "$target_disk" mkpart primary "$PART_ROOT_FS" "$((BOOT_END + SWAP_END))B" 100%

  echo "[INFO] Waiting for partitions to be available..."
  sleep 3

  # Автоопределение правильных разделов, с учетом nvmep1, sda1 и т.д.
  PART_SUFFIX=""
  [[ "$target_disk" =~ nvme ]] && PART_SUFFIX="p"

  BOOT_PARTITION="${target_disk}${PART_SUFFIX}1"
  SWAP_PARTITION="${target_disk}${PART_SUFFIX}2"
  ROOT_PARTITION="${target_disk}${PART_SUFFIX}3"

  echo "[INFO] Formatting partitions..."
  mkfs."$PART_BOOT_FS" "$BOOT_PARTITION"
  mkfs."$PART_ROOT_FS" "$ROOT_PARTITION"
  mkswap "$SWAP_PARTITION"

  echo "[OK] Disk partitioning and formatting completed."
}

run_debian_install() {
  set -euo pipefail
  source "$CONFIG_FILE"

  echo "[INFO] Preparing for Debian base system installation..."

  # Проверка существования target
  if [ -z "${INSTALL_TARGET:-}" ]; then
    INSTALL_TARGET="/mnt"
  fi

  echo "[INFO] Unmounting any existing mounts under $INSTALL_TARGET..."
  umount -R "$INSTALL_TARGET" 2>/dev/null || true
  mkdir -p "$INSTALL_TARGET"

  echo "[INFO] Mounting root partition to $INSTALL_TARGET..."
  mount "$ROOT_PARTITION" "$INSTALL_TARGET"

  echo "[INFO] Creating /boot and /proc inside chroot..."
  mkdir -p "$INSTALL_TARGET"/{boot,proc,sys,dev}

  echo "[INFO] Mounting boot partition..."
  mount "$BOOT_PARTITION" "$INSTALL_TARGET/boot"

  echo "[INFO] Mounting /proc, /sys, /dev..."
  mount -t proc none "$INSTALL_TARGET/proc"
  mount --rbind /sys "$INSTALL_TARGET/sys"
  mount --rbind /dev "$INSTALL_TARGET/dev"

  echo "[INFO] Starting debootstrap (Debian $DEBIAN_RELEASE)..."
  if debootstrap --arch=amd64 "$DEBIAN_RELEASE" "$INSTALL_TARGET" "$DEBIAN_MIRROR"; then
    echo "[OK] Debian base system installed successfully in $INSTALL_TARGET."
  else
    echo "[ERROR] debootstrap failed."
    exit 1
  fi
}

run_network() {
  set -euo pipefail
  source "$CONFIG_FILE"

  echo "[INFO] Configuring network..."

  INTERFACES_FILE="$INSTALL_TARGET/etc/network/interfaces"
  RESOLVCONF_FILE="$INSTALL_TARGET/etc/resolv.conf"

  # Определение основного интерфейса
  NET_IFACE=$(ip -o link show | awk -F': ' '!/lo/ {print $2; exit}')
  echo "[INFO] Detected network interface: $NET_IFACE"

  mkdir -p "$(dirname "$INTERFACES_FILE")"
  echo "# Generated by hetzner-debian-installer" > "$INTERFACES_FILE"

  if [ "$NETWORK_USE_DHCP" == "yes" ]; then
    echo "[INFO] Setting up DHCP configuration..."
    cat <<EOF >> "$INTERFACES_FILE"
auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet dhcp
EOF
  else
    echo "[INFO] Setting up static configuration..."
    : "${NETWORK_IP:?Missing static IP}"
    : "${NETWORK_MASK:=255.255.255.0}"
    : "${NETWORK_GATEWAY:?Missing gateway}"
    : "${NETWORK_DNS:=8.8.8.8 1.1.1.1}"

    cat <<EOF >> "$INTERFACES_FILE"
auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet static
    address $NETWORK_IP
    netmask $NETWORK_MASK
    gateway $NETWORK_GATEWAY
EOF

    echo "[INFO] Writing DNS servers to resolv.conf..."
    echo "# Generated by hetzner-debian-installer" > "$RESOLVCONF_FILE"
    for dns in $NETWORK_DNS; do
      echo "nameserver $dns" >> "$RESOLVCONF_FILE"
    done
  fi

  echo "[OK] Network configuration completed."
}

run_bootloader() {
  set -euo pipefail
  source "$CONFIG_FILE"

  echo "[INFO] Installing GRUB bootloader..."

  # Используем GRUB_TARGET_DRIVES (из configure_bootloader)
  if [ -z "${GRUB_TARGET_DRIVES[*]:-}" ]; then
    echo "[ERROR] No target drives specified for GRUB installation."
    exit 1
  fi

  echo "[INFO] Mounting system into chroot..."
  mount --bind /dev "$INSTALL_TARGET/dev"
  mount --bind /proc "$INSTALL_TARGET/proc"
  mount --bind /sys "$INSTALL_TARGET/sys"

  # Устанавливаем GRUB в каждый выбранный диск
  for disk in "${GRUB_TARGET_DRIVES[@]}"; do
    echo "[INFO] Installing GRUB to $disk..."
    chroot "$INSTALL_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck || \
    chroot "$INSTALL_TARGET" grub-install "$disk"
  done

  echo "[INFO] Updating GRUB config..."
  chroot "$INSTALL_TARGET" update-grub

  echo "[OK] GRUB installation complete."
}

run_initial_config() {
  set -euo pipefail
  source "$CONFIG_FILE"

  echo "[INFO] Applying initial system configuration..."

  # Установка hostname
  echo "[INFO] Setting hostname to $SYSTEM_HOSTNAME"
  echo "$SYSTEM_HOSTNAME" > "$INSTALL_TARGET/etc/hostname"
  echo "127.0.1.1 $SYSTEM_HOSTNAME" >> "$INSTALL_TARGET/etc/hosts"

  # Создание пользователя
  echo "[INFO] Creating user $SYSTEM_SUDO_USER"
  chroot "$INSTALL_TARGET" useradd -m -s /bin/bash "$SYSTEM_SUDO_USER"

  # Установка пароля
  echo "[INFO] Setting password for $SYSTEM_SUDO_USER"
  echo "$SYSTEM_SUDO_USER:$SYSTEM_USER_PASSWORD_HASH" | chroot "$INSTALL_TARGET" chpasswd -e

  # Добавление в sudo
  echo "[INFO] Adding $SYSTEM_SUDO_USER to sudo group"
  chroot "$INSTALL_TARGET" usermod -aG sudo "$SYSTEM_SUDO_USER"

  # Отключение root-доступа по SSH
  echo "[INFO] Disabling root SSH login"
  sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' "$INSTALL_TARGET/etc/ssh/sshd_config" || \
    echo "PermitRootLogin no" >> "$INSTALL_TARGET/etc/ssh/sshd_config"
  chroot "$INSTALL_TARGET" systemctl restart sshd || true

  echo "[OK] Initial system configuration completed."
}

run_cleanup() { echo "[Running] Cleanup and reboot..."; }

### Summary and Confirmation ###
summary_and_confirm() {
    echo ""
    echo "🚀 Configuration Summary:"
    echo "----------------------------------------"
    echo "Primary disk:          $PART_DRIVE1"
    echo "Secondary disk:        $PART_DRIVE2"
    echo "Use RAID:              $PART_USE_RAID (Level: $PART_RAID_LEVEL)"
    echo "Boot size/filesystem:  $PART_BOOT_SIZE / $PART_BOOT_FS"
    echo "Swap size:             $PART_SWAP_SIZE"
    echo "Root filesystem:       $PART_ROOT_FS"
    echo "Debian release/mirror: $DEBIAN_RELEASE / $DEBIAN_MIRROR"
    echo "Use DHCP:              $NETWORK_USE_DHCP"
    echo "GRUB targets:          ${GRUB_TARGET_DRIVES[*]}"
    echo "Hostname:              $HOSTNAME"
    echo "----------------------------------------"
    read -rp "Start installation with these settings? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Installation aborted by user."
        exit 1
    fi
}

### Entrypoints ###
configuring() {
    configure_partitioning
    configure_debian_install
    configure_network
    configure_bootloader
    configure_initial_config
    configure_cleanup
}

running() {
    run_partitioning
    run_debian_install
    run_network
    run_bootloader
    run_initial_config
    run_cleanup
}

main() {
    configuring
    summary_and_confirm
    running
}

main
