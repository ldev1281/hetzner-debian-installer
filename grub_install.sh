#!/bin/bash

CONFIG_FILE="hetzner-debian-installer.conf.bash"

run_bootloader() {
  source $CONFIG_FILE

  if [ "$PART_USE_RAID" = "yes" ]; then
    BOOTLOADER_DISKS=($PART_DRIVE1 $PART_DRIVE2)
  else
    BOOTLOADER_DISKS=($PART_DRIVE1)
  fi

  echo "Installing GRUB bootloader on disks: ${BOOTLOADER_DISKS[@]}"

  for disk in "${BOOTLOADER_DISKS[@]}"; do
    grub-install --root-directory=/mnt --boot-directory=/mnt/boot --target=i386-pc $disk
    if [ $? -ne 0 ]; then
      echo "Error: GRUB installation failed on $disk"
      exit 1
    fi
  done

  echo "Updating GRUB configuration..."

  mount --bind /dev /mnt/dev
  mount --bind /proc /mnt/proc
  mount --bind /sys /mnt/sys

  chroot /mnt update-grub

  umount /mnt/dev
  umount /mnt/proc
  umount /mnt/sys

  echo "GRUB successfully installed and configured."
}

# Example usage
#run_bootloader