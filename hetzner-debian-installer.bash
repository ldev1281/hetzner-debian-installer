#!/usr/bin/env bash

# Trap on unset variables. Trap on errors.
set -Euo pipefail
# Set trap handler
trap sys::cleanup SIGINT SIGTERM EXIT

### SYSTEM FUNCTIONS ###

sys::cidr_to_netmask() {
  local cidr=$1
  local mask=""
  local full_octets=$((cidr / 8))
  local remaining_bits=$((cidr % 8))

  for ((i = 0; i < 4; i++)); do
    if [ $i -lt $full_octets ]; then
      mask+="255"
    elif [ $i -eq $full_octets ]; then
      mask+=$((256 - 2 ** (8 - remaining_bits)))
    else
      mask+="0"
    fi
    [ $i -lt 3 ] && mask+="."
  done
  echo "$mask"
}

sys::tmux() {
  # Auto-start inside screen session
  if [ -z "${STY:-}" ]; then
    if ! command -v screen &>/dev/null; then
      msg::info "Installing screen..."
      sys::exec apt update && apt install screen -y || sys::die "Operation failed"
    fi
    msg::info "Installation is not run in screen. Re-Launching inside screen session $SESSION_NAME..."

    if sys::exec screen -list | grep -q "\.${SESSION_NAME}"; then
      msg::info "Screen session $SESSION_NAME already exists. Attaching..."
    else
      msg::info "Creating a new screen session ${SESSION_NAME}..."
      sys::exec screen -dmS "$SESSION_NAME" bash "${BASH_SOURCE[0]}" "$@"
    fi
    trap - SIGINT SIGTERM EXIT
    sys::exec screen -r "$SESSION_NAME"
    exit
  fi
}

sys::clean_mounts() {
  msg::info "Cleaning up temporary mounts..."
  for mp in dev proc sys/firmware/efi/efivars sys; do
    if mountpoint -q "${INSTALL_TARGET:-$DEFAULT_INSTALL_TARGET}/$mp"; then
      sys::exec umount -l "${INSTALL_TARGET:-$DEFAULT_INSTALL_TARGET}/$mp" || msg::error "Operation failed, but the process will continue"
    fi
  done

  for mp in boot/efi boot/efi2 boot; do
    if mountpoint -q "${INSTALL_TARGET:-$DEFAULT_INSTALL_TARGET}/$mp"; then
      sys::exec umount "${INSTALL_TARGET:-$DEFAULT_INSTALL_TARGET}/$mp" || msg::error "Operation failed, but the process will continue"
    fi
  done

  if mountpoint -q "${INSTALL_TARGET:-$DEFAULT_INSTALL_TARGET}"; then
    sys::exec umount "${INSTALL_TARGET:-$DEFAULT_INSTALL_TARGET}" || msg::error "Operation failed, but the process will continue"
  fi
}

sys::cleanup() {
  trap - SIGINT SIGTERM EXIT
  # script cleanup here
  msg::info "System cleanup"
  sys::clean_mounts
  exit
}

sys::msg() {
  echo >&2 -e "${@-}"
}

sys::log() {
  echo "$(date +'%D %T') ${BASH_SOURCE[0]##*/}[$$] ${@-}" >>"${LOG_FILE}"
}

sys::exec() {
  msg::debug "Executing $@"
  "$@" &> >(tee -a "$LOG_FILE")
  return $PIPESTATUS
}

sys::die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg::error "$msg"
  exit "$code"
}

sys::reboot() {
  # Cleanup mounts before exit. However, they can be clean twice if reboot triggers trap of the script
  sys::clean_mounts
  msg::info "Rebooting the system..."
  reboot
}

sys::get_disk_size() {
  local disk="$1"
  lsblk -b -ndo SIZE "$disk" | awk '{ printf "%.0f", $1 / (1024*1024*1024) }'
}

sys::get_var_type() {
  local varname="$1"
  case "$(typeset -p "$varname")" in
  "declare -a"* | "typeset -a"*) echo array ;;
  "declare -A"* | "typeset -A"*) echo hash ;;
  "declare -- "* | "typeset "$varname* | $varname=*) echo scalar ;;
  esac
}

sys::get_part_name() {
  local disk="$1"
  local num="$2"
  if [[ "$disk" =~ /dev/nvme[0-9]* ]] || [[ "$disk" =~ /dev/md[0-9]* ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

sys::gen_uuid() {
  blkid -s UUID -o value "$1"
}

sys::wait_udev() {
  sys::exec udevadm trigger
  sys::exec udevadm settle
}

sys::swap_off() {
  msg::info "Disabling swap on all devices "
  sys::exec swapoff -a || sys::die "Operation failed"
}

sys::bcache_off() {
  msg::info "Stopping all bcache volumes"
  for f in /sys/fs/bcache/*/stop; do
    [[ -e "$f" ]] || continue
    msg::info "Stopping bcache $f"
    echo 1 >"$f" || msg::error "Error stopping bcache $f"
  done
}

sys::lvm_off() {
  msg::info "Deactivating LVM"
  while read lv; do
    msg::info "Deactivating LV $lv"
    sys::exec lvchange -an "$lv" || sys::die "Operation failed"
  done < <(lvs --reportformat json | jq -r '.report[].lv[]|select(.lv_attr[4:5]=="a")|"\(.vg_name)/\(.lv_name)"')

  while read vg; do
    msg::info "Deactivating VG $vg"
    vgchange -an "$vg" || sys::die "Operation failed"
  done < <(vgs --reportformat json | jq -r '.report[].vg[].vg_name')
}

sys::devmapper_off() {
  msg::info 'Removing all device-mapper devices'
  [ -x "$(command -v dmsetup)" ] && {
    sys::exec dmsetup remove_all || msg::error "Error removing all device-mapper devices"
  }
}

sys::mdraid_off() {
  msg::info "Stopping all MD RAIDs"
  while read _ array _; do
    msg::info "Stopping MD array $array"
    sys::exec mdadm -S "$array" || sys::die "Operation failed"
  done < <(mdadm -D -s)
}

sys::clear_parts() {
  if [ -b "${1-}" ]; then
    msg::info "Clearing ${1} partitions and MBR/GPT"
    sys::exec dd if=/dev/zero of="$1" bs=1M count=10 status=none || sys::die "Operation failed"
    sys::exec wipefs -a "$1" || sys::die "Operation failed"
    sys::exec sgdisk -Z "$1" || sys::die "Operation failed"
    sys::exec partprobe || msg::error "partprobe failed"
  else
    msg::error "Device ${1-} is not a block device"
  fi
}

sys::init() {
  # Use prefix to avoid overlapping with env variables
  declare -g -A DI_LOG_LEVELS=([debug]=4 [info]=3 [warn]=2 [error]=1)
  # Default level is "debug"
  DI_LOG_LEVEL="debug"
  # Output everything to both log and stdout
  #exec &> >(tee -a "$LOG_FILE")

  # Setup colors
  if [[ -t 2 ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
  # Default values
  CONFIG_FILE="hetzner-debian-installer.conf.bash"
  LOG_FILE="hetzner-debian-installer-$(date +%Y%m%d.%H.%M.%S).log"
  SESSION_NAME="debian_install"

  # Lookup for disks and fail if none. Try to find disks for RAID.
  DISKS=($(lsblk -ndo NAME,TYPE | awk '$2 == "disk" { print "/dev/" $1 }'))

  [ "${#DISKS[@]}" -eq 0 ] && sys::die "No disks found"

  declare -A SIZE_MAP
  DEFAULT_PART_DRIVE1=""
  DEFAULT_PART_DRIVE2=""

  for disk in "${DISKS[@]}"; do
    size=$(sys::get_disk_size "$disk")
    if [ -z "$size" ]; then
      msg::warn "Could not get size for $disk"
      continue
    fi

    if [[ -n "${SIZE_MAP[$size]:-}" ]]; then
      DEFAULT_PART_DRIVE1="${SIZE_MAP[$size]}"
      DEFAULT_PART_DRIVE2="$disk"
    else
      SIZE_MAP[$size]="$disk"
    fi
  done

  # No matching pair found
  DEFAULT_PART_DRIVE1="${DEFAULT_PART_DRIVE1:-$DISKS[0]}"

  DEFAULT_PART_USE_RAID="${DEFAULT_PART_DRIVE2:+yes}"
  DEFAULT_PART_RAID_LEVEL="1"
  DEFAULT_PART_BOOT_RAID="/dev/md0"
  DEFAULT_PART_ROOT_RAID="/dev/md1"
  DEFAULT_PART_BOOT_SIZE="512M"
  DEFAULT_PART_EFI_SIZE="512M"
  DEFAULT_PART_ROOT_FS="ext4"
  DEFAULT_PART_BOOT_FS="ext3"
  DEFAULT_PART_EFI_FS="fat32"

  DEFAULT_DEBIAN_RELEASE="stable"
  DEFAULT_DEBIAN_MIRROR="http://deb.debian.org/debian"
  DEFAULT_INSTALL_TARGET="/mnt"
  DEFAULT_DEBOOTSTRAP_INCLUDE="apt,bash,dpkg,ca-certificates,openssl,openssh-server,mdadm,wget,curl,sudo,e2fsprogs,iproute2,ifupdown2,vim,rsync"

  DEFAULT_NETWORK_IFACE="$(ip route | awk '/default/ {print $5}' | head -n1)"
  DEFAULT_NETWORK_CIDR="$(ip -o -f inet addr show "$DEFAULT_NETWORK_IFACE" | awk '{print $4}')"
  DEFAULT_NETWORK_IP="${DEFAULT_NETWORK_CIDR%%/*}"
  DEFAULT_NETWORK_CIDR_PREFIX="${DEFAULT_NETWORK_CIDR##*/}"
  DEFAULT_NETWORK_MASK="$(sys::cidr_to_netmask "$DEFAULT_NETWORK_CIDR_PREFIX")"
  DEFAULT_NETWORK_GATEWAY="$(ip route | awk '/default/ {print $3}' | head -n1)"
  DEFAULT_NETWORK_DNS="8.8.8.8 1.1.1.1"

  DEFAULT_SYSTEM_HOSTNAME="debian-server"
  DEFAULT_SYSTEM_SUDO_USER="admin"
  DEFAULT_SYSTEM_USER_PASSWORD_HASH=""
}

### LOGGING FUNCTIONS ###

msg::info() {
  sys::log "I: $@"
  [ ${DI_LOG_LEVELS[$DI_LOG_LEVEL]} -ge ${DI_LOG_LEVELS[${FUNCNAME#*::}]} ] || return 0
  sys::msg "${YELLOW}I: $@${NOFORMAT}"
}

msg::error() {
  sys::log "E: $@"
  [ ${DI_LOG_LEVELS[$DI_LOG_LEVEL]} -ge ${DI_LOG_LEVELS[${FUNCNAME#*::}]} ] || return 0
  sys::msg "${RED}E: $@${NOFORMAT}"
}

msg::warn() {
  sys::log "W: $@"
  [ ${DI_LOG_LEVELS[$DI_LOG_LEVEL]} -ge ${DI_LOG_LEVELS[${FUNCNAME#*::}]} ] || return 0
  sys::msg "${PURPLE}W: $@${NOFORMAT}"
}

msg::debug() {
  sys::log "D: $@"
  [ ${DI_LOG_LEVELS[$DI_LOG_LEVEL]} -ge ${DI_LOG_LEVELS[${FUNCNAME#*::}]} ] || return 0
  sys::msg "${CYAN}D: $@${NOFORMAT}"
}

msg::success() {
  sys::msg "${GREEN}I: $@${NOFORMAT}"
  sys::log "I: $@"
}

### INTERACTION FUNCTIONS ###

input::prompt() {
  local prompt="$1"
  local validator="${2-}"
  local default="${3-}"
  local nullable="${4-}"
  local input

  while true; do
    if [ -n "$default" ]; then
      read -r -p "$prompt [$default]: " input
    else
      read -r -p "$prompt: " input
    fi

    if [ -z "$input" ] && [ -n "$default" ] && [ -z "$nullable" ]; then
      input="$default"
    fi

    if [ -z "$input" ] && [ -z "$nullable" ]; then
      msg::warn "Value can't be empty. Try again."
      continue
    fi

    if [ -n "$validator" ]; then
      if [[ ! "$input" =~ $validator ]]; then
        msg::warn "Value validation error. Try again"
        continue
      fi
    fi

    echo "$input"
    break
  done
}

### CONFIGURE FUNCTIONS ###

disks::cfg() {
  local force_config
  msg::info "[Configuring] Disks and RAID"

  msg::info "Detected disks:"
  for disk in "${DISKS[@]}"; do
    msg::info "- $disk ($(sys::get_disk_size $disk)GB)"
  done

  # If we already detected that we can use RAID then check for the first and second disk. If PART_DRIVE2 is set but PART_DRIVE1 is not set then assume nothing is set
  if [ "$DEFAULT_PART_USE_RAID" = "yes" ]; then
    if [ -n "${PART_DRIVE1:-}" ] && [ -z "${PART_DRIVE2:-}" ]; then
      msg::warn "There are two disks $DEFAULT_PART_DRIVE1 and $DEFAULT_PART_DRIVE2 of the same size found but only $PART_DRIVE1 is set in the config $CONFIG_FILE"
      DEFAULT_PART_USE_RAID=$(input::prompt "Do you want to build RAID with disks $DEFAULT_PART_DRIVE1 and ${DEFAULT_PART_DRIVE2}? (yes/no)" "" "$DEFAULT_PART_USE_RAID")
      if [ "$DEFAULT_PART_USE_RAID" = "yes" ]; then
        PART_DRIVE1=$DEFAULT_PART_DRIVE1
        PART_DRIVE2=$DEFAULT_PART_DRIVE2
        PART_USE_RAID="yes"
        PART_RAID_LEVEL="$DEFAULT_PART_RAID_LEVEL"
      else
        msg::info "Continue with single mode disk ($PART_DRIVE1)"
        PART_USE_RAID=""
        PART_RAID_LEVEL=""
        DEFAULT_PART_USE_RAID=""
      fi
    elif [ -n "${PART_DRIVE1:-}" ] && [ -n "${PART_DRIVE2:-}" ]; then
      if [ "$PART_DRIVE1" != "$DEFAULT_PART_DRIVE1" ] || [ "$PART_DRIVE2" != "$DEFAULT_PART_DRIVE2" ]; then
        msg::warn "Disks $PART_DRIVE1 and $PART_DRIVE2 from the config do not match found system disks of the same size $DEFAULT_PART_DRIVE1 and $DEFAULT_PART_DRIVE2"
        force_config=$(input::prompt "Do you want to build RAID with disks $PART_DRIVE1 and $PART_DRIVE2 from the config? (yes/no)")
        if [ "$force_config" != "yes" ]; then
          PART_DRIVE1=$(input::prompt "Primary disk" "" "$DEFAULT_PART_DRIVE1")
          PART_DRIVE2=$(input::prompt "Secondary disk" "" "$DEFAULT_PART_DRIVE2")
          PART_DRIVE1_SIZE=$(sys::get_disk_size "$PART_DRIVE1")
          PART_DRIVE2_SIZE=$(sys::get_disk_size "$PART_DRIVE2")
        else
          PART_DRIVE1_SIZE=$(sys::get_disk_size "$PART_DRIVE1")
          PART_DRIVE2_SIZE=$(sys::get_disk_size "$PART_DRIVE2")
        fi

        if [ -n "$PART_DRIVE1_SIZE" ] && [ -n "$PART_DRIVE2_SIZE" ]; then
          if [ "$PART_DRIVE1_SIZE" -ne "$PART_DRIVE2_SIZE" ]; then
            msg::warn "Disk sizes do not match ($PART_DRIVE1: ${PART_DRIVE1_SIZE}GB, $PART_DRIVE2: ${PART_DRIVE2_SIZE}GB). RAID may waste space or fail."
          fi
        else
          sys::die "Can't get disk sizes"
        fi

        PART_USE_RAID="yes"
        PART_RAID_LEVEL="$DEFAULT_PART_RAID_LEVEL"
      else
        PART_USE_RAID="yes"
        PART_RAID_LEVEL="$DEFAULT_PART_RAID_LEVEL"
      fi
    else
      msg::info "There are two disks $DEFAULT_PART_DRIVE1 and $DEFAULT_PART_DRIVE2 of the same size found"
      DEFAULT_PART_USE_RAID=$(input::prompt "Do you want to build RAID with disks $DEFAULT_PART_DRIVE1 and ${DEFAULT_PART_DRIVE2}? (yes/no)" "" "$DEFAULT_PART_USE_RAID")
      if [ "$DEFAULT_PART_USE_RAID" = "yes" ]; then
        PART_DRIVE1=$DEFAULT_PART_DRIVE1
        PART_DRIVE2=$DEFAULT_PART_DRIVE2
        PART_USE_RAID="yes"
        PART_RAID_LEVEL="$DEFAULT_PART_RAID_LEVEL"
      else
        msg::info "Continue with single mode disk ($DEFAULT_PART_DRIVE1)"
        PART_DRIVE1=$DEFAULT_PART_DRIVE1
        PART_DRIVE2=""
        PART_USE_RAID=""
        PART_RAID_LEVEL=""
        DEFAULT_PART_USE_RAID=""
      fi
    fi
  else
    if [ -n "${PART_DRIVE1:-}" ] && [ -n "${PART_DRIVE2:-}" ]; then
      msg::warn "No disks of the same size found in system but disks $PART_DRIVE1 and $PART_DRIVE2 are set in the config"
      force_config=$(input::prompt "Do you want to build RAID with disks $PART_DRIVE1 and $PART_DRIVE2 from config? (yes/no)")
      if [ "$force_config" != "yes" ]; then
        msg::info "Continue with single mode disk"
        PART_DRIVE1=$(input::prompt "Primary disk" "" "$DEFAULT_PART_DRIVE1")
        PART_DRIVE2=""
        PART_USE_RAID=""
        PART_RAID_LEVEL=""
      else
        PART_DRIVE1_SIZE=$(sys::get_disk_size "$PART_DRIVE1")
        PART_DRIVE2_SIZE=$(sys::get_disk_size "$PART_DRIVE2")
        if [ "$PART_DRIVE1_SIZE" -ne "$PART_DRIVE2_SIZE" ]; then
          msg::warn "Disk sizes do not match ($PART_DRIVE1: ${PART_DRIVE1_SIZE}GB, $PART_DRIVE2: ${PART_DRIVE2_SIZE}GB). RAID may waste space or fail."
        fi
        PART_USE_RAID="yes"
        PART_RAID_LEVEL="$DEFAULT_PART_RAID_LEVEL"
      fi
    else
      : ${PART_DRIVE1:=$(input::prompt "Primary disk" "" "$DEFAULT_PART_DRIVE1")}
    fi
  fi

  msg::info "[Configuring] Filesystem and partition sizes"

  : ${PART_BOOT_SIZE:=$(input::prompt "Boot partition size" "" "$DEFAULT_PART_BOOT_SIZE")}
  : ${PART_BOOT_FS:=$(input::prompt "Boot filesystem type" "" "$DEFAULT_PART_BOOT_FS")}
  : ${PART_ROOT_FS:=$(input::prompt "Root filesystem type" "" "$DEFAULT_PART_ROOT_FS")}
}

debian::cfg() {
  msg::info "[Configuring] Debian base system"

  : ${DEBIAN_RELEASE:=$(input::prompt "Debian release (stable, testing, sid)" "" "$DEFAULT_DEBIAN_RELEASE")}
  : ${DEBIAN_MIRROR:=$(input::prompt "Debian mirror URL" "" "$DEFAULT_DEBIAN_MIRROR")}
  : ${INSTALL_TARGET:=$(input::prompt "Installation target" "" "$DEFAULT_INSTALL_TARGET")}
}

net::cfg() {
  msg::info "[Configuring] Network parameters"

  : ${NETWORK_IFACE:=$(input::prompt "Enter network interface name" "" "$DEFAULT_NETWORK_IFACE")}
  if [ "$NETWORK_IFACE" != "$DEFAULT_NETWORK_IFACE" ]; then
    DEFAULT_NETWORK_CIDR="$(ip -o -f inet addr show "$NETWORK_IFACE" | awk '{print $4}')"
    if [ -n "$DEFAULT_NETWORK_CIDR" ]; then
      DEFAULT_NETWORK_IP="${DEFAULT_NETWORK_CIDR%%/*}"
      DEFAULT_NETWORK_CIDR_PREFIX="${DEFAULT_NETWORK_CIDR##*/}"
      DEFAULT_NETWORK_MASK="$(sys::cidr_to_netmask "$DEFAULT_NETWORK_CIDR_PREFIX")"
      DEFAULT_NETWORK_GATEWAY=""
    else
      DEFAULT_NETWORK_IP=""
      DEFAULT_NETWORK_CIDR_PREFIX=""
      DEFAULT_NETWORK_MASK=""
      DEFAULT_NETWORK_GATEWAY=""
    fi
  fi
  : ${NETWORK_IP:=$(input::prompt "Enter static IP for the interface $NETWORK_IFACE (e.g., 192.168.1.2)" "" "$DEFAULT_NETWORK_IP")}
  : ${NETWORK_MASK:=$(input::prompt "Enter netmask (e.g., 255.255.255.0)" "" "$DEFAULT_NETWORK_MASK")}
  : ${NETWORK_GATEWAY:=$(input::prompt "Enter default gateway (e.g., 192.168.1.1)" "" "$DEFAULT_NETWORK_GATEWAY")}
  : ${NETWORK_DNS:=$(input::prompt "Enter DNS servers (space-separated)" "" "$DEFAULT_NETWORK_DNS")}
}

boot::cfg() {
  msg::info "[Configuring] Bootloader parameters"
}

os::cfg() {
  msg::info "[Configuring] Initial system settings"
  local pwd1
  local pwd2

  : ${SYSTEM_HOSTNAME:=$(input::prompt "Enter hostname" "" "$DEFAULT_SYSTEM_HOSTNAME")}
  : ${SYSTEM_SUDO_USER:=$(input::prompt "Enter username for sudo access" "" "$DEFAULT_SYSTEM_SUDO_USER")}

  if [ ! -v "SYSTEM_USER_PASSWORD_HASH" ] || [ -z "$SYSTEM_USER_PASSWORD_HASH" ]; then
    while true; do
      pwd1=$(input::prompt "Enter password for user '$SYSTEM_SUDO_USER'")
      pwd2=$(input::prompt "Confirm password")
      if [ "$pwd1" != "$pwd2" ]; then
        msg::warn "Passwords do not match. Try again."
      else
        break
      fi
    done
    SYSTEM_USER_PASSWORD_HASH=$(openssl passwd -6 "$pwd1")
  fi
}

### RUN FUNCTIONS ###

disks::run() {
  msg::info "[Running] Partitioning disks according to the configuration"

  [ ! -b "$PART_DRIVE1" ] && sys::die "Primary disk $PART_DRIVE1 not found"

  if [ "$PART_USE_RAID" = "yes" ]; then
    [ ! -b "${PART_DRIVE2:-}" ] && sys::die "Secondary disk $PART_DRIVE2 not found"
    msg::info "Go with RAID ${PART_RAID_LEVEL} level mode"
  else
    msg::info "Go with single drive ($PART_DRIVE1) mode"
  fi

  # Stop as much as possible
  sys::swap_off
  sys::bcache_off
  sys::lvm_off
  sys::devmapper_off
  sys::mdraid_off

  EFI_END=$(numfmt --from=iec "$DEFAULT_PART_EFI_SIZE")
  BOOT_END=$((EFI_END + $(numfmt --from=iec "$PART_BOOT_SIZE")))
  BOOT_END_HUMAN=$(numfmt --to=iec --suffix=B "$BOOT_END")

  for disk in $PART_DRIVE1 ${PART_DRIVE2:-}; do
    # Clear first disk partitions
    sys::clear_parts "$disk"

    # Prepare disk for regular ESP + RAID partitions
    msg::info "Creating GPT partition table on the $disk..."
    sys::exec parted -s "$disk" mklabel gpt || sys::die "Operation failed"

    msg::info "Creating ESP partition on $disk..."
    sys::exec parted -s "$disk" mkpart ESP "$DEFAULT_PART_EFI_FS" 1MiB "$DEFAULT_PART_EFI_SIZE" || sys::die "Operation failed"
    sys::exec parted -s "$disk" set 1 esp on || sys::die "Operation failed"
    sys::exec parted -s "$disk" set 1 boot on || sys::die "Operation failed"

    msg::info "Creating /boot partition on $disk..."
    sys::exec parted -s "$disk" mkpart primary "$PART_BOOT_FS" "$DEFAULT_PART_EFI_SIZE" "$BOOT_END_HUMAN" || sys::die "Operation failed"

    msg::info "Creating root partition on $disk..."
    sys::exec parted -s "$disk" mkpart primary "$PART_ROOT_FS" "$BOOT_END_HUMAN" 100% || sys::die "Operation failed"
  done

  msg::info "Waiting for the device to be ready"
  sys::wait_udev

  if [ "$PART_USE_RAID" = "yes" ]; then
    EFI_PART1=$(sys::get_part_name "$PART_DRIVE1" 1)
    EFI_PART2=$(sys::get_part_name "$PART_DRIVE2" 1)
    BOOT_RAID_PART1=$(sys::get_part_name "$PART_DRIVE1" 2)
    BOOT_RAID_PART2=$(sys::get_part_name "$PART_DRIVE2" 2)
    ROOT_RAID_PART1=$(sys::get_part_name "$PART_DRIVE1" 3)
    ROOT_RAID_PART2=$(sys::get_part_name "$PART_DRIVE2" 3)

    msg::info "Clearing RAID superblocks on disks..."
    sys::exec mdadm --zero-superblock --force "$DEFAULT_PART_BOOT_RAID" || msg::error "Operation failed, but the installation will continue"
    sys::exec mdadm --zero-superblock --force "$DEFAULT_PART_ROOT_RAID" || msg::error "Operation failed, but the installation will continue"

    msg::info "Creating RAID array for /boot partition..."
    sys::exec mdadm --create --verbose $DEFAULT_PART_BOOT_RAID --level="$PART_RAID_LEVEL" --raid-devices=2 --run "$BOOT_RAID_PART1" "$BOOT_RAID_PART2" || sys::die "Operation failed"

    msg::info "Creating RAID array for root partition..."
    sys::exec mdadm --create --verbose $DEFAULT_PART_ROOT_RAID --level="$PART_RAID_LEVEL" --raid-devices=2 --run "$ROOT_RAID_PART1" "$ROOT_RAID_PART2" || sys::die "Operation failed"

    msg::info "Speeding up RAID synchronization by setting 500 MB/s values for /proc/sys/dev/raid/speed_limit_min and /proc/sys/dev/raid/speed_limit_max"
    echo 500000 >/proc/sys/dev/raid/speed_limit_min
    echo 500000 >/proc/sys/dev/raid/speed_limit_max

    msg::info "Waiting for the device to be ready"
    sys::wait_udev

    BOOT_PART="$DEFAULT_PART_BOOT_RAID"
    ROOT_PART="$DEFAULT_PART_ROOT_RAID"
  else
    EFI_PART1=$(sys::get_part_name "$PART_DRIVE1" 1)
    EFI_PART2=""
    BOOT_PART=$(sys::get_part_name "$PART_DRIVE1" 2)
    ROOT_PART=$(sys::get_part_name "$PART_DRIVE1" 3)
  fi

  msg::info "Formatting partitions..."
  for part in $EFI_PART1 ${EFI_PART2:-}; do
    if [ "$DEFAULT_PART_EFI_FS" = "fat32" ]; then
      sys::exec mkfs.vfat -F32 "$part" || sys::die "Operation failed"
    elif [ "$DEFAULT_PART_EFI_FS" = "fat16" ]; then
      sys::exec mkfs.vfat -F16 "$part" || sys::die "Operation failed"
    else
      sys::die "Not supported ESP filesystem: $DEFAULT_PART_EFI_FS"
    fi
  done

  sys::exec mkfs."$PART_BOOT_FS" "$BOOT_PART" || sys::die "Operation failed"
  sys::exec mkfs."$PART_ROOT_FS" "$ROOT_PART" || sys::die "Operation failed"

  msg::success "Disk partitioning and formatting completed"
}

debian::run() {
  msg::info "[Running] Preparing for Debian base system installation..."

  msg::info "Cleaning up any mounts in $INSTALL_TARGET..."
  sys::exec umount -R "$INSTALL_TARGET" || true
  sys::exec mkdir -p "$INSTALL_TARGET"

  msg::info "Mounting root partition to $INSTALL_TARGET..."
  sys::exec mount "$ROOT_PART" "$INSTALL_TARGET" || sys::die "Operation failed"

  msg::info "Starting debootstrap installation (Debian $DEBIAN_RELEASE)..."
  sys::exec debootstrap --verbose --resolve-deps --variant=minbase --include="$DEFAULT_DEBOOTSTRAP_INCLUDE" --arch=amd64 "$DEBIAN_RELEASE" "$INSTALL_TARGET" "$DEBIAN_MIRROR" &&
    msg::success "Debian base system installed successfully into $INSTALL_TARGET" ||
    sys::die "Operation failed"

  msg::info "Creating /boot, /proc, /sys and /dev inside $INSTALL_TARGET..."
  sys::exec mkdir -p "$INSTALL_TARGET"/{boot,proc,sys,dev} || sys::die "Operation failed"

  msg::info "Mounting boot partition to $INSTALL_TARGET/boot..."
  sys::exec mount "$BOOT_PART" "$INSTALL_TARGET/boot" || sys::die "Operation failed"

  msg::info "Creating /efi inside mounted $INSTALL_TARGET/boot..."
  sys::exec mkdir -p "$INSTALL_TARGET"/boot/efi || sys::die "Operation failed"
  [ "$PART_USE_RAID" = "yes" ] && { sys::exec mkdir -p "$INSTALL_TARGET"/boot/efi2 || sys::die "Operation failed"; }

  msg::info "Mounting ESP partition to $INSTALL_TARGET/boot/efi..."
  sys::exec mount "$EFI_PART1" "$INSTALL_TARGET/boot/efi" || sys::die "Operation failed"
  [ "$PART_USE_RAID" = "yes" ] && { sys::exec mount "$EFI_PART2" "$INSTALL_TARGET/boot/efi2" || sys::die "Operation failed"; }

  msg::info "Mounting /proc, /sys, /sys/firmware/efi/efivars and /dev inside $INSTALL_TARGET..."
  for mp in /proc /sys /sys/firmware/efi/efivars /dev; do
    sys::exec mount --rbind "$mp" "${INSTALL_TARGET}${mp}" || sys::die "Operation failed"
  done
}

net::run() {
  msg::info "[Running] Configuring network..."

  local ifaces_conf="$INSTALL_TARGET/etc/network/interfaces"
  local resolv_conf="$INSTALL_TARGET/etc/resolv.conf"

  sys::exec mkdir -p "$(dirname "$ifaces_conf")" || sys::die "Operation failed"
  echo "# Generated by hetzner-debian-installer" >"$ifaces_conf" || sys::die "Operation failed"

  msg::info "Setting up static network configuration..."
  # Static
  sys::exec cat <<-EOF >>"$ifaces_conf" || sys::die "Operation failed"
auto lo
iface lo inet loopback

auto $NETWORK_IFACE
iface $NETWORK_IFACE inet static
    address $NETWORK_IP
    netmask $NETWORK_MASK
    gateway $NETWORK_GATEWAY
EOF
  msg::info "Writing DNS servers to resolv.conf..."
  echo "# Generated by hetzner-debian-installer" >"$resolv_conf" || sys::die "Operation failed"
  for ns in $NETWORK_DNS; do
    echo "nameserver $ns" >>"$resolv_conf" || sys::die "Operation failed"
  done

  msg::success "Network configuration completed"
}

boot::run() {
  msg::info "[Running] Installing GRUB bootloader and Linux kernel..."

  msg::info "Installing initramfs-tools, systemd, systemd-sysv, linux-image-amd64 and grub-efi packages..."
  sys::exec chroot "$INSTALL_TARGET" <<-EOF || sys::die "Operation failed"
    set -e
    export HOME=/root
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y initramfs-tools
    apt-get install -y systemd systemd-sysv
    apt-get install -y linux-image-amd64 grub-efi
EOF

  msg::info "Installing GRUB on $EFI_PART1..."
  sys::exec chroot "$INSTALL_TARGET" <<-EOF || sys::die "Operation failed"
set -e
export HOME=/root
export DEBIAN_FRONTEND=noninteractive
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy --removable
EOF

  sys::exec chroot "$INSTALL_TARGET" update-grub || sys::die "Operation failed"

  if [ "$PART_USE_RAID" = "yes" ]; then
    msg::info "Installing GRUB on $EFI_PART2..."
    sys::exec chroot "$INSTALL_TARGET" <<-EOF || sys::die "Operation failed"
set -e
export HOME=/root
export DEBIAN_FRONTEND=noninteractive
grub-install --target=x86_64-efi --efi-directory=/boot/efi2 --bootloader-id=debian --recheck --no-floppy --removable --no-nvram
EOF
  fi

  msg::info "Force kernel to use classic interfaces names via GRUB config..."
  sys::exec chroot "$INSTALL_TARGET" sed -i 's/GRUB_CMDLINE_LINUX="[^"]*/& net.ifnames=0 biosdevname=0/' /etc/default/grub || sys::die "Operation failed"

  if [ "$PART_USE_RAID" = "yes" ]; then
    msg::info "Creating GRUB hook to sync ESP partitions"
    sys::exec cat <<-EOF >"$INSTALL_TARGET/etc/grub.d/90_copy_to_boot_efi2" || sys::die "Operation failed"
#!/bin/sh
# https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition
set -e

if mountpoint --quiet --nofollow /boot/efi; then
    mount /boot/efi2 || :
    rsync --times --recursive --delete /boot/efi/ /boot/efi2/
    # Being FAT it is even better when not mounted, won't be damaged in case of computer crash or power outage.
    # Ref: https://forums.debian.net/viewtopic.php?p=759692&sid=ff62e9207a064b027f041d2cd0a612a4#p759692
    umount /boot/efi2
fi
exit 0
EOF
  fi

  msg::info "Updating GRUB config..."
  sys::exec chroot "$INSTALL_TARGET" update-grub || sys::die "Operation failed"

  msg::success "GRUB installation completed"
}

os::run() {
  msg::info "[Running] Applying initial system configuration..."

  msg::info "Generating /etc/fstab"
  sys::exec cat <<-EOF >"$INSTALL_TARGET/etc/fstab" || sys::die "Operation failed"
UUID=$(sys::gen_uuid $ROOT_PART) / ext4 defaults 0 1
UUID=$(sys::gen_uuid $BOOT_PART) /boot ext3 defaults 0 2
UUID=$(sys::gen_uuid $EFI_PART1) /boot/efi vfat umask=0077,errors=remount-ro,nofail 0 1
EOF

  [ "$PART_USE_RAID" = "yes" ] && {
    echo "UUID=$(sys::gen_uuid $EFI_PART2) /boot/efi2 vfat umask=0077,errors=remount-ro,nofail,noauto 0 1" >>"$INSTALL_TARGET/etc/fstab" || sys::die "Operation failed"
  }

  msg::info "Setting hostname to $SYSTEM_HOSTNAME"
  echo "$SYSTEM_HOSTNAME" >"$INSTALL_TARGET/etc/hostname" || sys::die "Operation failed"
  echo "127.0.1.1 $SYSTEM_HOSTNAME" >>"$INSTALL_TARGET/etc/hosts" || sys::die "Operation failed"

  msg::info "Creating user $SYSTEM_SUDO_USER"
  sys::exec chroot "$INSTALL_TARGET" useradd -m -s /bin/bash "$SYSTEM_SUDO_USER" || sys::die "Operation failed"

  msg::info "Setting password for $SYSTEM_SUDO_USER"
  echo "$SYSTEM_SUDO_USER:$SYSTEM_USER_PASSWORD_HASH" | chroot "$INSTALL_TARGET" chpasswd -e || sys::die "Operation failed"

  msg::info "Adding $SYSTEM_SUDO_USER to sudo group"
  sys::exec chroot "$INSTALL_TARGET" usermod -aG sudo "$SYSTEM_SUDO_USER" || sys::die "Operation failed"

  msg::info "Disabling root SSH login"
  echo "PermitRootLogin no" >"$INSTALL_TARGET/etc/ssh/sshd_config.d/90-PermitRootLogin.conf" || sys::die "Operation failed"

  if [ "$PART_USE_RAID" = "yes" ]; then
    msg::info "Updating GRUB config to sync ESP partitions..."
    # Make it executable only at this stage when fstab is populated
    sys::exec chmod a+rx "$INSTALL_TARGET/etc/grub.d/90_copy_to_boot_efi2" || sys::die "Operation failed"
    sys::exec chroot "$INSTALL_TARGET" update-grub || sys::die "Operation failed"
  fi

  msg::success "Initial system configuration completed"
}

### CONFIGURATION FUNCTIONS ###

cfg::load() {
  # Load config file if exists
  if [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ]; then
    msg::info "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
  else
    msg::info "No configuration file found, proceeding interactively."
  fi
}

cfg::dump() {
  msg::info "\n \
  ====== Configuration Summary ====== \n \
  Primary disk:            $PART_DRIVE1 \n \
  Secondary disk:          ${PART_DRIVE2:-none} \n \
  Use RAID:                ${PART_USE_RAID:-no} (Level: ${PART_RAID_LEVEL:-none}) \n \
  Boot size (filesystem):  $PART_BOOT_SIZE (${PART_BOOT_FS}) \n \
  Root filesystem:         $PART_ROOT_FS \n \
  Debian release (mirror): $DEBIAN_RELEASE (${DEBIAN_MIRROR}) \n \
  Network interface:       $NETWORK_IFACE \n \
  IP address:              $NETWORK_IP \n \
  Network mask:            $NETWORK_MASK \n \
  Default gateway:         $NETWORK_GATEWAY \n \
  DNS servers:             ${NETWORK_DNS[*]} \n \
  Hostname:                $SYSTEM_HOSTNAME \n \
  Sudo user:               $SYSTEM_SUDO_USER \n \
  ==================================="
}

cfg::confirm() {
  cfg::dump

  : ${CONFIRM:=$(input::prompt "Start installation with these settings? (yes/no)")}

  if [ "$CONFIRM" != "yes" ]; then
    sys::die "Installation cancelled by user."
  fi
}

cfg::save() {
  msg::info "Saving confirmed configuration to the $CONFIG_FILE"
  {
    echo "# === Auto-generated configuration ==="
    for varname in PART_DRIVE1 PART_DRIVE2 PART_USE_RAID PART_RAID_LEVEL PART_BOOT_SIZE PART_ROOT_FS PART_BOOT_FS \
      DEBIAN_RELEASE DEBIAN_MIRROR INSTALL_TARGET \
      NETWORK_IFACE NETWORK_IP NETWORK_MASK NETWORK_GATEWAY NETWORK_DNS \
      SYSTEM_HOSTNAME SYSTEM_SUDO_USER SYSTEM_USER_PASSWORD_HASH; do
      [ -v "$varname" ] && declare -p "$varname"
    done

  } >"$CONFIG_FILE" || sys::die "Operation failed"
  # Dirty hack. Otherwise bash won't make them global (it does not print -g even for global vars)
  sys::exec sed -i 's/^declare /declare -g /' "$CONFIG_FILE"
}

install::cleanup() {
  msg::info "Copying $CONFIG_FILE to $INSTALL_TARGET/root..."
  sys::exec cp -a "$CONFIG_FILE" "$INSTALL_TARGET/root/"
  msg::info "Copying $LOG_FILE to $INSTALL_TARGET/root..."
  sys::exec cp -a "$LOG_FILE" "$INSTALL_TARGET/root/"
}

### Entrypoints ###
install::cfg() {
  disks::cfg
  debian::cfg
  net::cfg
  boot::cfg
  os::cfg
}

install::run() {
  disks::run
  debian::run
  net::run
  boot::run
  os::run
}

main() {
  sys::init
  cfg::load
  sys::tmux
  install::cfg
  cfg::confirm
  cfg::save
  install::run
  install::cleanup
  sys::reboot
}

main "$@"
