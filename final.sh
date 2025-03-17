#!/bin/bash

finalize_installation() {
  echo "Unmounting temporary filesystems..."

  umount /mnt/dev >/dev/null 2>&1
  umount /mnt/proc >/dev/null 2>&1
  umount /mnt/sys >/dev/null 2>&1
  umount /mnt/boot >/dev/null 2>&1
  umount /mnt >/dev/null 2>&1

  echo "Cleaning up temporary files..."
  rm -rf /mnt/tmp/*

  echo "Installation completed successfully. The system will now reboot."

  sleep 5
  reboot
}

# Example usage
finalize_installation