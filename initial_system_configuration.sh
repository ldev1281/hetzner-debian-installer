#!/bin/bash

CONFIG_FILE="hetzner-debian-installer.conf.bash"

configure_initial_config() {
  read -p "Enter hostname [debian-server]: " SYSTEM_HOSTNAME
  SYSTEM_HOSTNAME=${SYSTEM_HOSTNAME:-debian-server}

  read -p "Enter username for sudo access [admin]: " SYSTEM_SUDO_USER
  SYSTEM_SUDO_USER=${SYSTEM_SUDO_USER:-admin}

  while true; do
    read -s -p "Enter password for user '$SYSTEM_SUDO_USER': " USER_PASSWORD
    echo
    read -s -p "Confirm password: " USER_PASSWORD_CONFIRM
    echo
    if [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ]; then
      break
    else
      echo "Passwords do not match, try again."
    fi
  done

  USER_PASSWORD_HASH=$(openssl passwd -6 "$USER_PASSWORD")

  echo "Saving initial system configuration to $CONFIG_FILE"

  cat <<EOF >> $CONFIG_FILE
SYSTEM_HOSTNAME="$SYSTEM_HOSTNAME"
SYSTEM_SUDO_USER="$SYSTEM_SUDO_USER"
SYSTEM_USER_PASSWORD_HASH="$USER_PASSWORD_HASH"
EOF

  echo "Configuration saved."
}

run_initial_config() {
  source $CONFIG_FILE

  echo "Applying initial system configuration:"
  echo "Hostname: $SYSTEM_HOSTNAME"
  echo "Sudo user: $SYSTEM_SUDO_USER"

  # Hostname setup
  echo "$SYSTEM_HOSTNAME" > /mnt/etc/hostname
  echo "127.0.1.1 $SYSTEM_HOSTNAME" >> /mnt/etc/hosts

  # User creation
  chroot /mnt useradd -m -s /bin/bash "$SYSTEM_SUDO_USER"
  echo "$SYSTEM_SUDO_USER:$SYSTEM_USER_PASSWORD_HASH" | chroot /mnt chpasswd -e

  # Add user to sudo group
  chroot /mnt usermod -aG sudo "$SYSTEM_SUDO_USER"

  # Disable root SSH login
  chroot /mnt sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
  chroot /mnt systemctl restart sshd

  echo "Initial system configuration successfully applied."
}

# Example usage
#configure_initial_config
#run_initial_config