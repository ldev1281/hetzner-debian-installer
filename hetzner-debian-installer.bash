#!/bin/bash
set -e

SESSION_NAME="debian_install"

# If we're not inside a screen session, start one automatically
if [ -z "$STY" ]; then
    if ! command -v screen &> /dev/null; then
        echo "Installing screen..."
        apt update && apt install screen -y
    fi
    echo "Starting installation inside a screen session: $SESSION_NAME"
    screen -dmS "$SESSION_NAME" bash "$0"
    echo "Reattach using: screen -r $SESSION_NAME"
    exit 0
fi

# Rename screen session
screen -S "$STY" -X sessionname "$SESSION_NAME"

### STEP 1: Configuration Parameters ###
configure_installation() {
    echo "[STEP 1] Configuration parameters..."

    # Example configuration prompts (to be customized)
    read -rp "Enter your desired hostname: " HOSTNAME
    read -rp "Enter root password: " ROOT_PASSWORD
    read -rp "Enter main disk name (e.g., /dev/nvme0n1): " DISK

    # Exporting variables for other steps
    export HOSTNAME ROOT_PASSWORD DISK

    echo "Configuration set:"
    echo "Hostname: $HOSTNAME"
    echo "Disk: $DISK"
}

### STEP 2: Disk Partitioning ###
partition_disk() {
    echo "[STEP 2] Disk partitioning..."
    echo "Disk selected: $DISK"
    # Future disk partitioning commands go here
}

### STEP 3: Minimal Debian Installation ###
install_debian() {
    echo "[STEP 3] Installing minimal Debian via debootstrap..."
    # Future debootstrap installation commands go here
}

### STEP 4: Network Configuration ###
setup_network() {
    echo "[STEP 4] Setting up network configuration..."
    # Future network configuration commands go here
}

### STEP 5: Bootloader Installation ###
install_bootloader() {
    echo "[STEP 5] Installing bootloader (GRUB)..."
    # Future bootloader installation commands go here
}

### STEP 6: Initial System Configuration ###
initial_config() {
    echo "[STEP 6] Initial system configuration..."
    echo "Hostname: $HOSTNAME, Root Password: [hidden]"
    # Future system initial configuration commands go here
}

### STEP 7: Cleanup and Reboot ###
cleanup_and_reboot() {
    echo "[STEP 7] Cleanup and reboot..."
    # Future cleanup and reboot commands go here
}

### MAIN: Execute all steps sequentially ###
main() {
    configure_installation
    partition_disk
    install_debian
    setup_network
    install_bootloader
    initial_config
    cleanup_and_reboot
}

main
