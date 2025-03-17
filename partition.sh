#!/bin/bash

CONFIG_FILE="hetzner-debian-installer.conf.bash"

configure_partitioning() {
  echo "Detecting disks:"
  disks=($(lsblk -dn -o NAME,SIZE | awk '{print "/dev/"$1" ("$2")"}'))

  for disk in "${disks[@]}"; do
    echo "- $disk"
  done

  default_primary=$(echo ${disks[0]} | awk '{print $1}')
  default_secondary=$(echo ${disks[1]} | awk '{print $1}')

  read -p "Primary disk [$default_primary]: " PART_DRIVE1
  PART_DRIVE1=${PART_DRIVE1:-$default_primary}

  read -p "Secondary disk for RAID (leave empty if none) [$default_secondary]: " PART_DRIVE2
  PART_DRIVE2=${PART_DRIVE2:-$default_secondary}

  if [ -z "$PART_DRIVE2" ]; then
    default_use_raid="no"
  else
    default_use_raid="yes"
  fi

  read -p "Use RAID? (yes/no) [$default_use_raid]: " PART_USE_RAID
  PART_USE_RAID=${PART_USE_RAID:-$default_use_raid}

  if [ "$PART_USE_RAID" == "yes" ]; then
    read -p "RAID Level [1]: " PART_RAID_LEVEL
    PART_RAID_LEVEL=${PART_RAID_LEVEL:-1}
  fi

  read -p "Boot partition size [512M]: " PART_BOOT_SIZE
  PART_BOOT_SIZE=${PART_BOOT_SIZE:-512M}

  default_swap_size=$(free -h | grep Mem: | awk '{print $2}')
  read -p "Swap partition size [$default_swap_size]: " PART_SWAP_SIZE
  PART_SWAP_SIZE=${PART_SWAP_SIZE:-$default_swap_size}

  read -p "Root filesystem type [ext4]: " PART_ROOT_FS
  PART_ROOT_FS=${PART_ROOT_FS:-ext4}

  read -p "Boot filesystem type [ext3]: " PART_BOOT_FS
  PART_BOOT_FS=${PART_BOOT_FS:-ext3}

  echo "Saving configuration to $CONFIG_FILE"

  cat <<EOF > $CONFIG_FILE
PART_DRIVE1="$PART_DRIVE1"
PART_DRIVE2="$PART_DRIVE2"
PART_USE_RAID="$PART_USE_RAID"
PART_RAID_LEVEL="$PART_RAID_LEVEL"
PART_BOOT_SIZE="$PART_BOOT_SIZE"
PART_SWAP_SIZE="$PART_SWAP_SIZE"
PART_ROOT_FS="$PART_ROOT_FS"
PART_BOOT_FS="$PART_BOOT_FS"
EOF

  echo "Configuration saved."
}

run_partitioning() {
  source $CONFIG_FILE

  echo "Partitioning disks according to the configuration:"
  cat $CONFIG_FILE

  read -p "Continue? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Operation aborted."
    exit 1
  fi

  if [ "$PART_USE_RAID" == "yes" ]; then
    echo "Creating RAID array..."
    mdadm --create /dev/md0 --level=$PART_RAID_LEVEL --raid-devices=2 $PART_DRIVE1 $PART_DRIVE2
    target_disk="/dev/md0"
  else
    target_disk=$PART_DRIVE1
  fi

  echo "Creating partitions..."
  parted -s $target_disk mklabel gpt

  parted -s $target_disk mkpart primary $PART_BOOT_FS 1MiB $PART_BOOT_SIZE
  parted -s $target_disk set 1 boot on

  parted -s $target_disk mkpart primary linux-swap $PART_BOOT_SIZE $(echo $PART_BOOT_SIZE + $PART_SWAP_SIZE | sed 's/M//')MiB

  parted -s $target_disk mkpart primary $PART_ROOT_FS $(echo $PART_BOOT_SIZE + $PART_SWAP_SIZE | sed 's/M//')MiB 100%

  sleep 3

  BOOT_PARTITION=${target_disk}p1
  SWAP_PARTITION=${target_disk}p2
  ROOT_PARTITION=${target_disk}p3

  echo "Formatting partitions..."

  mkfs.$PART_BOOT_FS $BOOT_PARTITION
  mkfs.$PART_ROOT_FS $ROOT_PARTITION
  mkswap $SWAP_PARTITION

  echo "Partitioning and formatting completed."
}

# Example execution
#configure_partitioning
#run_partitioning