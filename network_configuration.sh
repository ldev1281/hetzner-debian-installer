#!/bin/bash

CONFIG_FILE="hetzner-debian-installer.conf.bash"

configure_network() {
  read -p "Use DHCP? (yes/no) [yes]: " NETWORK_USE_DHCP
  NETWORK_USE_DHCP=${NETWORK_USE_DHCP:-yes}

  if [ "$NETWORK_USE_DHCP" = "no" ]; then
    read -p "Enter static IP (e.g., 192.168.1.100): " NETWORK_IP

    read -p "Enter netmask (e.g., 255.255.255.0) [255.255.255.0]: " NETWORK_MASK
    NETWORK_MASK=${NETWORK_MASK:-255.255.255.0}

    read -p "Enter gateway (e.g., 192.168.1.1): " NETWORK_GATEWAY

    read -p "Enter DNS servers (space-separated) [8.8.8.8 1.1.1.1]: " NETWORK_DNS
    NETWORK_DNS=${NETWORK_DNS:-"8.8.8.8 1.1.1.1"}
  fi

  echo "Saving network configuration to $CONFIG_FILE"

  cat <<EOF >> $CONFIG_FILE
NETWORK_USE_DHCP="$NETWORK_USE_DHCP"
NETWORK_IP="$NETWORK_IP"
NETWORK_MASK="$NETWORK_MASK"
NETWORK_GATEWAY="$NETWORK_GATEWAY"
NETWORK_DNS="$NETWORK_DNS"
EOF

  echo "Network configuration saved."
}

run_network() {
  source $CONFIG_FILE

  echo "Network configuration:"
  echo "Use DHCP: $NETWORK_USE_DHCP"

  if [ "$NETWORK_USE_DHCP" = "no" ]; then
    echo "Static IP: $NETWORK_IP"
    echo "Netmask: $NETWORK_MASK"
    echo "Gateway: $NETWORK_GATEWAY"
    echo "DNS servers: $NETWORK_DNS"
  fi

  read -p "Apply this network configuration? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Operation cancelled."
    exit 1
  fi

  if [ "$NETWORK_USE_DHCP" = "yes" ]; then
    cat <<EOF > /mnt/etc/network/interfaces
auto eth0
iface eth0 inet dhcp
EOF
  else
    cat <<EOF > /mnt/etc/network/interfaces
auto eth0
iface eth0 inet static
    address $NETWORK_IP
    netmask $NETWORK_MASK
    gateway $NETWORK_GATEWAY
    dns-nameservers $NETWORK_DNS
EOF
  fi

  echo "Network configuration successfully applied."
}

# Example usage
#configure_network
#run_network
