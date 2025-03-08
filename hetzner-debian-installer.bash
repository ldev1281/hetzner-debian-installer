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
    : "${HOSTNAME:?$(read -rp 'Hostname: ' HOSTNAME)}"
    : "${ROOT_PASSWORD:?$(read -rp 'Root password: ' ROOT_PASSWORD)}"
}

configure_cleanup() {
    echo "[Configuring] Cleanup parameters (usually nothing to configure)"
}

### RUN FUNCTIONS (Empty placeholders) ###
run_partitioning() { echo "[Running] Partitioning..."; }
run_debian_install() { echo "[Running] Debian installation..."; }
run_network() { echo "[Running] Network setup..."; }
run_bootloader() { echo "[Running] Bootloader installation..."; }
run_initial_config() { echo "[Running] Initial configuration..."; }
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
