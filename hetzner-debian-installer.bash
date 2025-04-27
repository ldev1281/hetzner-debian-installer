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

# CONFIGURE FUNCTIONS ###

configure_partitioning() {
    echo "Detected disks:"
    lsblk -o NAME,SIZE -dn | while read -r disk size; do
        if [[ $(lsblk -o TYPE -dn "/dev/$disk") == "disk" ]]; then
            echo "- /dev/$disk ($size)"
        fi
    done

    echo "[Configuring] Partitioning parameters"

    if [[ -z "$PART_DRIVE1" ]]; then
        read -rp 'Primary disk (e.g., nvme0n1): ' PART_DRIVE1
        PART_DRIVE1="${PART_DRIVE1:-nvme0n1}"
        echo "PART_DRIVE1=\"$PART_DRIVE1\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$PART_DRIVE2" ]]; then
        read -rp 'Secondary disk for RAID (optional): ' PART_DRIVE2
        PART_DRIVE2="${PART_DRIVE2:-nvme1n1}"
        echo "PART_DRIVE2=\"$PART_DRIVE2\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$PART_USE_RAID" ]]; then
        read -rp 'Use RAID? (yes/no): ' PART_USE_RAID
        PART_USE_RAID="${PART_USE_RAID:-yes}"
        echo "PART_USE_RAID=\"$PART_USE_RAID\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$PART_RAID_LEVEL" && "$PART_USE_RAID" == "yes" ]]; then
        read -rp 'RAID Level (e.g., 1): ' PART_RAID_LEVEL
        PART_RAID_LEVEL="${PART_RAID_LEVEL:-1}"
        echo "PART_RAID_LEVEL=\"$PART_RAID_LEVEL\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$PART_BOOT_SIZE" ]]; then
        read -rp 'Boot partition size (e.g., 512M): ' PART_BOOT_SIZE
        PART_BOOT_SIZE="${PART_BOOT_SIZE:-512M}"
        echo "PART_BOOT_SIZE=\"$PART_BOOT_SIZE\"" >> "$CONFIG_FILE"
    fi

        if [[ -z "$PART_EFI_SIZE" ]]; then
        read -rp 'EFI partition size (e.g., 256M): ' PART_EFI_SIZE
        PART_EFI_SIZE="${PART_EFI_SIZE:-256M}"
        echo "PART_EFI_SIZE=\"$PART_EFI_SIZE\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$PART_SWAP_SIZE" ]]; then
        read -rp 'Swap size (e.g., 32G): ' PART_SWAP_SIZE
        PART_SWAP_SIZE="${PART_SWAP_SIZE:-32G}"
        echo "PART_SWAP_SIZE=\"$PART_SWAP_SIZE\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$PART_ROOT_FS" ]]; then
        read -rp 'Root filesystem type (e.g., ext4): ' PART_ROOT_FS
        PART_ROOT_FS="${PART_ROOT_FS:-ext4}"
        echo "PART_ROOT_FS=\"$PART_ROOT_FS\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$PART_BOOT_FS" ]]; then
        read -rp 'Boot filesystem type (e.g., ext3): ' PART_BOOT_FS
        PART_BOOT_FS="${PART_BOOT_FS:-ext3}"
        echo "PART_BOOT_FS=\"$PART_BOOT_FS\"" >> "$CONFIG_FILE"
    fi

       if [[ -z "$PART_EFI_FS" ]]; then
       read -rp 'EFI filesystem type (e.g., fat16): ' PART_EFI_FS
       PART_EFI_FS="${PART_EFI_FS:-fat16}"
       echo "PART_EFI_FS=\"$PART_EFI_FS\"" >> "$CONFIG_FILE"
    fi
}


configure_debian_install() {
    echo "[Configuring] Debian install parameters"

    if [[ -z "$DEBIAN_RELEASE" ]]; then
        read -rp "Choose Debian release (stable, testing, sid) [stable]: " DEBIAN_RELEASE
        DEBIAN_RELEASE="${DEBIAN_RELEASE:-stable}"
        echo "DEBIAN_RELEASE=\"$DEBIAN_RELEASE\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$DEBIAN_MIRROR" ]]; then
        read -rp "Enter Debian mirror [http://deb.debian.org/debian]: " DEBIAN_MIRROR
        DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
        echo "DEBIAN_MIRROR=\"$DEBIAN_MIRROR\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$INSTALL_TARGET" ]]; then
        read -rp "Enter install target [/mnt]: " INSTALL_TARGET
        INSTALL_TARGET="${INSTALL_TARGET:-/mnt}"
        echo "INSTALL_TARGET=\"$INSTALL_TARGET\"" >> "$CONFIG_FILE"
    fi

    if mount | grep -q "$INSTALL_TARGET"; then
        echo "Error: Unmount $INSTALL_TARGET"
        exit 1
    fi
}


configure_network() {
    echo "[Configuring] Network parameters"

    if [[ -z "$NETWORK_USE_DHCP" ]]; then
        read -rp "Use DHCP? (yes/no) [yes]: " NETWORK_USE_DHCP
        NETWORK_USE_DHCP="${NETWORK_USE_DHCP:-yes}"
        echo "NETWORK_USE_DHCP=\"$NETWORK_USE_DHCP\"" >> "$CONFIG_FILE"
    fi

    if [[ "$NETWORK_USE_DHCP" == "no" ]]; then
        if [[ -z "$NETWORK_IP" ]]; then
            read -rp "Enter static IP: " NETWORK_IP
            echo "NETWORK_IP=\"$NETWORK_IP\"" >> "$CONFIG_FILE"
        fi

        if [[ -z "$NETWORK_MASK" ]]; then
            read -rp "Enter netmask (e.g., 255.255.255.0) [255.255.255.0]: " NETWORK_MASK
            NETWORK_MASK="${NETWORK_MASK:-255.255.255.0}"
            echo "NETWORK_MASK=\"$NETWORK_MASK\"" >> "$CONFIG_FILE"
        fi

        if [[ -z "$NETWORK_GATEWAY" ]]; then
            read -rp "Enter gateway (e.g., 192.168.1.1): " NETWORK_GATEWAY
            echo "NETWORK_GATEWAY=\"$NETWORK_GATEWAY\"" >> "$CONFIG_FILE"
        fi

        if [[ -z "$NETWORK_DNS" ]]; then
            read -rp "Enter DNS servers (space-separated) [8.8.8.8 1.1.1.1]: " NETWORK_DNS
            NETWORK_DNS="${NETWORK_DNS:-8.8.8.8 1.1.1.1}"
            echo "NETWORK_DNS=\"$NETWORK_DNS\"" >> "$CONFIG_FILE"
        fi
    fi
}

configure_bootloader() {
    echo "[Configuring] Bootloader"
    
    if [[ -z "$BOOTLOADER_DISKS" ]]; then
        read -rp "Disks for install grub [/dev/nvme0n1 /dev/nvme1n1]: " BOOTLOADER_DISKS
        BOOTLOADER_DISKS="${BOOTLOADER_DISKS:-/dev/${PART_DRIVE1} /dev/${PART_DRIVE2}}"
        echo "BOOTLOADER_DISKS=\"$BOOTLOADER_DISKS\"" >> "$CONFIG_FILE"
    fi
}

configure_initial_config() {
    echo "[Configuring] Initial system settings"

    if [[ -z "$SYSTEM_HOSTNAME" ]]; then
        read -rp "Enter hostname [debian-server]: " SYSTEM_HOSTNAME
        SYSTEM_HOSTNAME="${SYSTEM_HOSTNAME:-debian-server}"
        echo "SYSTEM_HOSTNAME=\"$SYSTEM_HOSTNAME\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$SYSTEM_SUDO_USER" ]]; then
        read -rp "Enter username for sudo access [admin]: " SYSTEM_SUDO_USER
        SYSTEM_SUDO_USER="${SYSTEM_SUDO_USER:-admin}"
        echo "SYSTEM_SUDO_USER=\"$SYSTEM_SUDO_USER\"" >> "$CONFIG_FILE"
    fi

    if [[ -z "$SYSTEM_USER_PASSWORD_HASH" ]]; then
      while true; do
          read -rsp "Enter password for user '$SYSTEM_SUDO_USER': " USER_PASSWORD
          echo
          read -rsp "Confirm password: " USER_PASSWORD_CONFIRM
          echo
          if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]]; then
              break
          else
              echo "Passwords do not match. Try again."
          fi
      done
      fi

    if [[ -z "$SYSTEM_USER_PASSWORD_HASH" ]]; then
        USER_PASSWORD_HASH=$(openssl passwd -6 "$USER_PASSWORD")
        echo "SYSTEM_USER_PASSWORD_HASH=\"$USER_PASSWORD_HASH\"" >> "$CONFIG_FILE"
    else
        USER_PASSWORD_HASH="$SYSTEM_USER_PASSWORD_HASH"
    fi
}


configure_cleanup() {
   echo "[Configuring] Cleanup parameters (usually nothing to configure)"
}

## RUN FUNCTIONS (Empty placeholders) ###
run_partitioning() {
    echo "[Running] Partitioning..."

    local EFI_END=$(numfmt --to=si $(($(numfmt --from=iec $PART_EFI_SIZE) + $(numfmt --from=iec 1M))))
    local BOOT_END=$(numfmt --to=si $(($(numfmt --from=iec $PART_BOOT_SIZE) + $(numfmt --from=iec ${EFI_END}))))
    local SWAP_END=$(numfmt --to=si $(($(numfmt --from=iec $PART_SWAP_SIZE) + $(numfmt --from=iec ${BOOT_END}))))  

    if [[ "$PART_USE_RAID" == "yes" ]]; then
        parted -s "/dev/$PART_DRIVE1" mklabel gpt
        parted -s "/dev/$PART_DRIVE2" mklabel gpt

        parted -s "/dev/$PART_DRIVE1" mkpart EFI $PART_EFI_FS 1MiB "$EFI_END"
        parted -s "/dev/$PART_DRIVE1" set 1 boot on
        parted -s "/dev/$PART_DRIVE1" mkpart BOOT $PART_BOOT_FS $EFI_END $BOOT_END
        parted -s "/dev/$PART_DRIVE1" mkpart SWAP linux-swap $BOOT_END "$SWAP_END"
        parted -s "/dev/$PART_DRIVE1" mkpart ROOT $PART_ROOT_FS $SWAP_END 100%

        parted -s "/dev/$PART_DRIVE2" mkpart EFI $PART_EFI_FS 1MiB "$EFI_END"
        parted -s "/dev/$PART_DRIVE2" set 1 boot on
        parted -s "/dev/$PART_DRIVE2" mkpart BOOT $PART_BOOT_FS $EFI_END $BOOT_END
        parted -s "/dev/$PART_DRIVE2" mkpart SWAP linux-swap $BOOT_END "$SWAP_END"
        parted -s "/dev/$PART_DRIVE2" mkpart ROOT $PART_ROOT_FS $SWAP_END 100%

        echo yes | mdadm --create --verbose /dev/md0 --level=1 --raid-devices=2 --metadata=1.0 "/dev/${PART_DRIVE1}p1" "/dev/${PART_DRIVE2}p1" # EFI
        echo yes | mdadm --create --verbose /dev/md1 --level=1 --raid-devices=2 --metadata=1.2 "/dev/${PART_DRIVE1}p2" "/dev/${PART_DRIVE2}p2"
        echo yes | mdadm --create --verbose /dev/md2 --level=1 --raid-devices=2 --metadata=1.2 "/dev/${PART_DRIVE1}p3" "/dev/${PART_DRIVE2}p3"
        echo yes | mdadm --create --verbose /dev/md3 --level=1 --raid-devices=2 --metadata=1.2 "/dev/${PART_DRIVE1}p4" "/dev/${PART_DRIVE2}p4"

        mkfs.vfat -n EFI /dev/md0
        mkfs.ext3 /dev/md1
        mkswap /dev/md2
        mkfs.ext4 -L LINUX /dev/md3
        swapon /dev/md2
    else
        parted -s "/dev/$PART_DRIVE1" mklabel gpt
        parted -s "/dev/$PART_DRIVE1" mkpart EFI $PART_EFI_FS 1MiB "$EFI_END"
        parted -s "/dev/$PART_DRIVE1" set 1 boot on
        parted -s "/dev/$PART_DRIVE1" mkpart BOOT $PART_BOOT_FS $EFI_END $BOOT_END
        parted -s "/dev/$PART_DRIVE1" mkpart SWAP linux-swap $BOOT_END "$SWAP_END"
        parted -s "/dev/$PART_DRIVE1" mkpart ROOT $PART_ROOT_FS $SWAP_END 100%

        mkfs.vfat -n EFI /dev/${PART_DRIVE1}p1
        mkfs.ext3 /dev/${PART_DRIVE1}p2
        mkswap /dev/${PART_DRIVE1}p3
        mkfs.ext4 -L LINUX /dev/${PART_DRIVE1}p4
        swapon /dev/${PART_DRIVE1}p3
    fi
}


run_debian_install() {
    echo "[Running] Debian installation..."

    if [[ "$PART_USE_RAID" == "yes" ]]; then
        mount /dev/md3 "$INSTALL_TARGET"
        mkdir -p "$INSTALL_TARGET/boot"
        mount /dev/md1 "$INSTALL_TARGET/boot"
        mkdir -p "$INSTALL_TARGET/boot/efi"
        mount /dev/md0 "$INSTALL_TARGET/boot/efi"
    else
        mount "/dev/${PART_DRIVE1}p4" "$INSTALL_TARGET"
        mkdir -p "$INSTALL_TARGET/boot"
        mount "/dev/${PART_DRIVE1}p2" "$INSTALL_TARGET/boot"
        mkdir -p "$INSTALL_TARGET/boot/efi"
        mount "/dev/${PART_DRIVE1}p1" "$INSTALL_TARGET/boot/efi"
    fi

    echo "Starting debootstrap for $DEBIAN_RELEASE..."
    if debootstrap --arch=amd64 "$DEBIAN_RELEASE" "$INSTALL_TARGET" "$DEBIAN_MIRROR"; then
        echo "Debian installed in $INSTALL_TARGET."
    else
        echo "Error: debootstrap failed"
        exit 1
    fi
}

run_network() {
    echo "[Running] Network setup..."

    local target_etc="$INSTALL_TARGET/etc"
    mkdir -p "$target_etc/network"

    if [[ "$NETWORK_USE_DHCP" == "yes" ]]; then
        echo "auto enp5s0
iface enp5s0 inet dhcp" >"$target_etc/network/interfaces"
        echo "DHCP configuration applied."
    else
        echo "auto enp5s0
iface enp5s0 inet static
 address $NETWORK_IP
 netmask $NETWORK_MASK
 gateway $NETWORK_GATEWAY" >"$target_etc/network/interfaces"
        echo "Static network configuration applied."

        local resolv_file="$target_etc/resolv.conf"
        echo "# DNS from install script" >"$resolv_file"
        for dns in $NETWORK_DNS; do
            echo "nameserver $dns" >>"$resolv_file"
        done
        echo 'resolv.conf: Done'
    fi
}

run_bootloader() {
    echo "[Running] Bootloader installation..."

    local fstab_file="$INSTALL_TARGET/etc/fstab"
    echo "proc /proc proc defaults 0 0" >"$fstab_file"

    if [[ "$PART_USE_RAID" == "yes" ]]; then
        echo "UUID=$(blkid -s UUID -o value /dev/md0) /boot/efi vfat umask=0077 0 1" >>"$fstab_file"
        echo "UUID=$(blkid -s UUID -o value /dev/md1) /boot $PART_BOOT_FS defaults 0 0" >>"$fstab_file"
        echo "UUID=$(blkid -s UUID -o value /dev/md3) / $PART_ROOT_FS defaults 0 0" >>"$fstab_file"
        echo "UUID=$(blkid -s UUID -o value /dev/md2) none swap sw 0 0" >>"$fstab_file"
    else
        echo "UUID=$(blkid -s UUID -o value /dev/${PART_DRIVE1}p1) /boot/efi vfat umask=0077 0 1" >>"$fstab_file"
        echo "UUID=$(blkid -s UUID -o value /dev/${PART_DRIVE1}p2) /boot $PART_BOOT_FS defaults 0 0" >>"$fstab_file"
        echo "UUID=$(blkid -s UUID -o value /dev/${PART_DRIVE1}p4) / $PART_ROOT_FS defaults 0 0" >>"$fstab_file"
        echo "UUID=$(blkid -s UUID -o value /dev/${PART_DRIVE1}p3) none swap sw 0 0" >>"$fstab_file"
    fi

    echo "fstab: done"

     mount --bind /dev ${INSTALL_TARGET}/dev
     mount -t devpts /dev/pts ${INSTALL_TARGET}/dev/pts
     mount -t proc proc ${INSTALL_TARGET}/proc
     mount -t sysfs sysfs ${INSTALL_TARGET}/sys
     mount -t tmpfs tmpfs ${INSTALL_TARGET}/tmp

    chroot $INSTALL_TARGET apt update
    chroot $INSTALL_TARGET apt remove -y grub-efi grub-efi-amd64
    chroot $INSTALL_TARGET apt install -y mdadm locales linux-image-amd64 linux-headers-amd64 grub-efi sudo ssh net-tools systemd

    chroot $INSTALL_TARGET echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    chroot $INSTALL_TARGET locale-gen
    chroot $INSTALL_TARGET echo 'LANG="en_US.UTF-8"' > /etc/default/locale

    for disk in $BOOTLOADER_DISKS; do
        echo "Installing GRUB on $disk..."
  #      chroot "$INSTALL_TARGET" grub-mkconfig -o /boot/grub/grub.cfg 2>&1
        chroot "$INSTALL_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-nvram --removable
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to install GRUB on $disk."
            exit 1
        fi
    done

    chroot $INSTALL_TARGET update-grub
    echo "grub: done"
   apt-get install -y -V firmware-linux 
}

run_initial_config() {
    echo "[Running] Initial system configuration..."

    local ip_address="$(ifconfig eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')"
    echo "$ip_address   $SYSTEM_HOSTNAME" >> "$INSTALL_TARGET/etc/hosts"
    echo "$SYSTEM_HOSTNAME" > "$INSTALL_TARGET/etc/hostname"
    chroot "$INSTALL_TARGET" useradd -m -s /bin/bash "$SYSTEM_SUDO_USER"
    echo "$SYSTEM_SUDO_USER:$USER_PASSWORD_HASH" | chroot "$INSTALL_TARGET" chpasswd -e
    chroot "$INSTALL_TARGET" usermod -aG sudo "$SYSTEM_SUDO_USER"
    sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' "$INSTALL_TARGET/etc/ssh/sshd_config"
    chroot "$INSTALL_TARGET" systemctl restart sshd

    echo "Initial system configuration completed."
}

run_cleanup() {
    echo "[Running] Cleanup and reboot..."
    umount -R "$INSTALL_TARGET"

    read -rp "Reboot system? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancel reboot"
        exit 1
    fi
    reboot
}

### Summary and Confirmation ###
summary_and_confirm() {
    echo ""
    echo "🚀 Configuration Summary:"
    echo "----------------------------------------"
    echo "Primary disk:          $PART_DRIVE1"
    echo "Secondary disk:        $PART_DRIVE2"
    echo "Use RAID:              $PART_USE_RAID (Level: $PART_RAID_LEVEL)"
    echo "Boot size/filesystem:  $PART_BOOT_SIZE / $PART_BOOT_FS"
    echo "EFI size/filesystem:   $PART_EFI_SIZE / $PART_EFI_FS"   
    echo "Swap size:             $PART_SWAP_SIZE"
    echo "Root filesystem:       $PART_ROOT_FS"
    echo "Debian release/mirror: $DEBIAN_RELEASE / $DEBIAN_MIRROR"
    echo "Use DHCP:              $NETWORK_USE_DHCP"
    echo "GRUB targets:          ${BOOTLOADER_DISKS[*]}"
    echo "Hostname:              $SYSTEM_HOSTNAME"
    echo "User:                  $SYSTEM_SUDO_USER"
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