#!/usr/bin/env bash

# install.sh - Minimal Arch Linux base system installer.
# Copyright (C) 2026 Thiago C. Silva <librefos@newliber.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Usage: ./install.sh <target-disk> <profile>
#  (e.g. ./install.sh /dev/nvme0n1 amd)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly SCRIPT_DIR

info()
{
  local red green yellow nc

  # set ANSI foreground
  red=$(tput setaf 1)
  green=$(tput setaf 2)
  yellow=$(tput setaf 3)
  nc=$(tput sgr0) # reset to default rendition

  local status="$1" message="$2"

  case $status in
    -w)
      printf '%b[WARN]%b %b\n' "$yellow" "$nc" "$message" >&2
      ;;
    -e)
      printf '%b[ERROR]%b %b\n' "$red" "$nc" "$message" >&2
      exit 1
      ;;
    -s)
      printf '\n%b==>%b %b\n' "$green" "$nc" "$message" >&2
      ;;
    *)
      printf '%b[INFO]%b %b\n' "$green" "$nc" "$message" >&2
      ;;
  esac
}

#--- Pre-installation ---------------------------------------------------------

info -s 'Pre-installation'

readonly HOSTNAME='archlinux'
readonly TIMEZONE='America/Sao_Paulo'
readonly KEYMAP='us'
readonly FONT='Lat2-Terminus16'
readonly DISK="${1:-}"
readonly PROFILE="${2:-}"

# Unattended mode exists solely so the test harness can drive this script; see
# tests/loop.sh. It suppresses the destructive-format confirmation, feeds the
# LUKS passphrase from the environment instead of the terminal, leaves the root
# account locked, and stops bootctl from touching the host's EFI variables.
# It is never set on real hardware.
readonly UNATTENDED="${ARCH_BOOTSTRAP_UNATTENDED:-}"
readonly PASSPHRASE="${ARCH_BOOTSTRAP_PASSPHRASE:-}"

if [[ -z "$DISK" || -z "$PROFILE" ]]; then
  info -e "Usage: $0 DISK PROFILE (e.g., $0 /dev/nvme0n1 intel)"
fi

# If the /sys/firmware/efi directory is missing, legacy mode.
[[ ! -d /sys/firmware/efi ]] && info -e 'Booted in BIOS/CSM mode. UEFI is required.'

# Hardware Profile Configuration
case "${PROFILE,,}" in
  amd)
    info -- "Loading AMD Ryzen profile..."
    readonly UCODE_PKG='amd-ucode'
    # realtek is here for the headphones, not for a network card: without it
    # the analog output on this board does not come up. It cost a long time
    # to track down, so it is pinned to the profile that needs it rather
    # than left in the shared pacstrap line where it looks incidental.
    readonly FW_PKG='linux-firmware-amdgpu linux-firmware-realtek'
    readonly KMS_MODULE='amdgpu'
    readonly PSTATE_FLAG='amd_pstate=active'
    readonly NET_PKG=''
    # NVMe SSD: ssd allocation heuristics and async discard both apply.
    # noatime        Reduces disk wear by not writing "last accessed" times.
    # compress=zstd  Transparently compress, saving space and speeding I/O.
    # discard=async  Frees unused blocks in the background for SSD health.
    # space_cache=v2 Speeds up block group caching on large modern drives.
    readonly MOUNT_OPTS='noatime,compress=zstd,ssd,discard=async,space_cache=v2'
    readonly EXTRA_CMDLINE=''
    # The desktop has no use for hibernation.
    readonly SWAPFILE_SIZE=''
    ;;
  intel)
    info -- "Loading Intel Celeron profile..."
    readonly UCODE_PKG='intel-ucode'
    # linux-firmware is a metapackage: it owns no files and pulls ten vendor
    # subpackages, ~407 MiB, of which ~267 MiB is firmware for hardware this
    # laptop does not have -- nvidia, atheros, mediatek, broadcom, cirrus,
    # radeon and amdgpu among them. The intel subpackage alone carries the
    # i915 GuC/HuC/DMC blobs, the iwlwifi Wi-Fi firmware and the ibt-* Intel
    # Bluetooth firmware, which is the whole of what Tiger Lake needs.
    # realtek is here for the onboard RTL8111/8168 (rev 15) Ethernet: r8169
    # loads rtl_nic/rtl8168h-2.fw from this package. The Realtek part in the
    # audio path is an HDA codec, which needs no firmware file -- the reason
    # this profile carries realtek is the NIC, not the sound.
    #
    # No sof-firmware: snd_intel_dspcfg selects the legacy HDA path on this
    # machine (/proc/asound/cards reports 'HDA Intel PCH', snd_hda_intel in
    # use, snd_sof_pci_intel_tgl loaded but at usecount 0), so the 43 MiB of
    # Sound Open Firmware would sit unused.
    readonly FW_PKG='linux-firmware-intel linux-firmware-realtek'
    readonly KMS_MODULE='i915'
    readonly PSTATE_FLAG='intel_pstate=active'
    readonly NET_PKG='networkmanager'
    # A 5400 RPM SATA disk is the opposite machine. Dropping ssd lets Btrfs
    # autodetect rotational instead of being told to assume seek-free
    # allocation; dropping discard=async because a hard disk has no TRIM.
    # zstd:1 rather than the default 3, since compression is still a win when
    # bytes across the bottleneck are the constraint but level 3 is an
    # avoidable tax on a 1.8 GHz part with no turbo. autodefrag targets exactly
    # the small-random-write fragmentation CoW produces on rotational media.
    # commit=120 aggregates writes so the disk wakes less often, at the cost of
    # up to two minutes of writes at risk on power loss.
    readonly MOUNT_OPTS='noatime,compress=zstd:1,autodefrag,commit=120'
    # PSR1, not PSR2. Drop i915.enable_psr=1 if the panel flickers.
    readonly EXTRA_CMDLINE='nowatchdog i915.enable_psr=1'
    # 6 GiB covers a 4 GB hibernation image with headroom.
    readonly SWAPFILE_SIZE='6g'
    ;;
  *)
    info -e "Invalid profile '$PROFILE'. Must be 'amd' or 'intel'."
    ;;
esac

if [[ -n "$UNATTENDED" ]]; then
  [[ -z "$PASSPHRASE" ]] && \
    info -e 'ARCH_BOOTSTRAP_UNATTENDED needs ARCH_BOOTSTRAP_PASSPHRASE set.'
  info -w "Unattended mode: wiping $DISK without confirmation."
else
  info -- "This script will permanently wipe all data on $DISK."
  printf 'Proceed with destructive formatting? (y/N): ' >/dev/tty
  read -r input </dev/tty
  [[ "${input,,}" != 'y' ]] && info -e 'Installation aborted by user.'
fi

#--------------------------------------------------------- Pre-installation ---
#--- Preparing Environment & Partitioning -------------------------------------

info -s "Preparing Environment & Partitioning ($DISK)"

# If the system clock is significantly out of sync, certificates validation
# will fail, and the installation will break.
timedatectl set-ntp true

[[ ! -b "$DISK" ]] && info -e "Target block device $DISK does not exist."

swapoff --all                          || true
umount --recursive /mnt    2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

cleanup()
{
  info -w 'Execution aborted. Unmounting filesystems and closing LUKS...'
  umount --recursive /mnt    2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wipefs --all "$DISK"

# Destroy old filesystem signatures and create a modern GPT layout.
# uefi  Tags the 1G partition as an EFI System Partition.
# linux Tags the rest of the drive as a standard Linux filesystem.
sfdisk --wipe always --wipe-partitions always "$DISK" <<EOF
label: gpt
size=1G, type=uefi
size=+,  type=linux
EOF

# Detect the drive type (e.g., /dev/sda1, /dev/nvme0p1).
if [[ "$DISK" == *'nvme'* ]] || [[ "$DISK" == *'mmcblk'* ]]; then
  readonly PART_EFI="${DISK}p1" PART_ROOT="${DISK}p2"
else
  readonly PART_EFI="${DISK}1" PART_ROOT="${DISK}2"
fi

#------------------------------------- Preparing Environment & Partitioning ---
#--- LUKS2 Encryption & Formatting --------------------------------------------

info -s 'LUKS2 Encryption & Formatting'

# Format bootloader partition (ESP) to FAT32.
mkfs.fat -F 32 "$PART_EFI"

info -- "Initializing LUKS2 container on $PART_ROOT..."
if [[ -n "$UNATTENDED" ]]; then
  # --key-file - reads the passphrase from stdin; --batch-mode suppresses the
  # interactive "YES" confirmation luksFormat otherwise demands on a tty.
  printf '%s' "$PASSPHRASE" \
    | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$PART_ROOT"

  # Unlock and open the encrypted partition to expose the mapped device.
  printf '%s' "$PASSPHRASE" \
    | cryptsetup open --key-file - "$PART_ROOT" cryptroot
else
  cryptsetup luksFormat --type luks2 "$PART_ROOT"

  # Unlock and open the encrypted partition to expose the mapped device.
  cryptsetup open "$PART_ROOT" cryptroot
fi

info -- 'Formatting mapped LUKS partition as Btrfs...'
mkfs.btrfs -f /dev/mapper/cryptroot

#-------------------------------------------- LUKS2 Encryption & Formatting ---
#--- Creating Subvolumes & Mounting -------------------------------------------

info -s 'Creating Subvolumes & Mounting'

mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log

# Hibernation needs disk swap: systemd refuses to hibernate to zram, and a
# swapfile has to sit on its own subvolume that is never snapshotted.
if [[ -n "$SWAPFILE_SIZE" ]]; then
  info -- 'Creating @swap subvolume for the hibernation swapfile...'
  btrfs subvolume create /mnt/@swap
fi

umount /mnt

# Mount root first so we can create the directories for the other mount points.
mount --options "${MOUNT_OPTS},subvol=@" /dev/mapper/cryptroot /mnt
mkdir --parents /mnt/{boot,root,home,var/cache/pacman/pkg,var/log}

# Mount the remaining subvolumes.
mount --options "${MOUNT_OPTS},subvol=@home"  /dev/mapper/cryptroot /mnt/home
mount --options "${MOUNT_OPTS},subvol=@cache" /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount --options "${MOUNT_OPTS},subvol=@log"   /dev/mapper/cryptroot /mnt/var/log

if [[ -n "$SWAPFILE_SIZE" ]]; then
  mkdir --parents /mnt/swap
  # Deliberately not passing nodatacow here. Btrfs applies mount options per
  # filesystem, not per subvolume, so this mount inherits the compression and
  # commit settings above and a nodatacow here would be silently ignored. The
  # requirement is real but it is a per-file attribute: mkswapfile below sets
  # NOCOW on the swapfile itself, which also disables compression for it.
  mount --options noatime,subvol=@swap /dev/mapper/cryptroot /mnt/swap

  info -- "Creating a ${SWAPFILE_SIZE} swapfile for hibernation..."
  # mkswapfile sets NOCOW and preallocates, covering the Btrfs swapfile
  # requirements that a plain fallocate would not.
  btrfs filesystem mkswapfile --size "$SWAPFILE_SIZE" --uuid clear \
    /mnt/swap/swapfile

  # genfstab reads /proc/swaps, so the swapfile has to be active for the swap
  # line to reach the new fstab at all.
  swapon /mnt/swap/swapfile
fi

# Ensure that only the root user can read or write to the bootloader files.
mount --options fmask=0077,dmask=0077 "$PART_EFI" /mnt/boot

# Save the chosen profile for Phase 2
echo "$PROFILE" > /mnt/root/.deploy_profile

# Prevents crashing if the file is missing or if the script was executed from a
# different working directory.
if [[ -f "$SCRIPT_DIR/post_install.sh" ]]; then
  info -- "Copying post_install.sh from $SCRIPT_DIR..."
  cp "$SCRIPT_DIR/post_install.sh" /mnt/root/
  chmod +x /mnt/root/post_install.sh
elif [[ -f "./post_install.sh" ]]; then
  info -- "Copying post_install.sh from current working directory..."
  cp "./post_install.sh" /mnt/root/
  chmod +x /mnt/root/post_install.sh
else
  info -w "post_install.sh not found. Transfer it manually after reboot."
fi

#------------------------------------------- Creating Subvolumes & Mounting ---
#--- Bootstrapping Base System ------------------------------------------------

info -s 'Bootstrapping Base System'

info -- 'Optimizing mirrorlist (South America, HTTPS, 100% sync, < 12h)...'
reflector \
  --country Brazil,Argentina,Chile,Uruguay \
  --protocol https                         \
  --age 12                                 \
  --completion-percent 100                 \
  --latest 20                              \
  --sort rate                              \
  --number 10                              \
  --connection-timeout 10                  \
  --download-timeout 20                    \
  --save /etc/pacman.d/mirrorlist

sed --in-place '/^#ParallelDownloads/s/#//' /etc/pacman.conf

mkdir --parents /mnt/etc
printf 'LANG=en_US.UTF-8\n' > /mnt/etc/locale.conf
printf '%s\n' "${HOSTNAME}" > /mnt/etc/hostname
cat <<EOF                   > /mnt/etc/vconsole.conf
KEYMAP=$KEYMAP
FONT=$FONT
EOF

# shellcheck disable=SC2086
pacstrap -K /mnt base linux $FW_PKG $NET_PKG \
                 $UCODE_PKG btrfs-progs cryptsetup tpm2-tss sbctl systemd-ukify

genfstab -U /mnt > /mnt/etc/fstab

# The swapfile only had to be active long enough for genfstab to see it in
# /proc/swaps. Left on, it holds /mnt/swap busy and the final `umount -R /mnt`
# fails. The VM harness never notices, because the guest powers straight off.
if [[ -n "$SWAPFILE_SIZE" ]]; then
  swapoff /mnt/swap/swapfile
fi

#------------------------------------------------ Bootstrapping Base System ---
#--- System Configuration (Chroot) --------------------------------------------

info -s 'System Configuration (Chroot)'

# Capture the UUID of the raw encrypted partition for the bootloader.
LUKS_UUID="$(blkid -s UUID -o value "$PART_ROOT")"
readonly LUKS_UUID

# Prevent the host shell from expanding variables and inject only the specific
# variables we need into the isolated environment.
arch-chroot /mnt /usr/bin/env \
  TIMEZONE="$TIMEZONE" KEYMAP="$KEYMAP" FONT="$FONT" HOSTNAME="$HOSTNAME" \
  LUKS_UUID="$LUKS_UUID" KMS_MODULE="$KMS_MODULE" PSTATE_FLAG="$PSTATE_FLAG" \
  PROFILE="$PROFILE" UNATTENDED="$UNATTENDED" EXTRA_CMDLINE="$EXTRA_CMDLINE" \
/bin/bash <<'CHROOT'
set -euo pipefail

ln --symbolic --force "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

sed --in-place '/^#en_US.UTF-8/s/#//' /etc/locale.gen
locale-gen

if [[ "$PROFILE" == 'amd' ]]; then
  mkdir --parents /etc/systemd/network
  cat <<'NET' > /etc/systemd/network/20-wired.network
[Match]
Name=en*

[Network]
DHCP=yes
IPv6PrivacyExtensions=kernel

[DHCPv4]
RouteMetric=10
NET
  systemctl enable systemd-networkd
elif [[ "$PROFILE" == 'intel' ]]; then
  systemctl enable NetworkManager
fi
systemctl enable systemd-resolved

# 'base' provides the initramfs skeleton and an emergency rescue shell should
# early boot fail before the root filesystem is mounted.
hooks_str='base systemd autodetect microcode modconf kms keyboard sd-vconsole '
hooks_str+='block sd-encrypt filesystems'

# Inject the dynamic KMS module based on hardware profile
sed --in-place \
  --expression "/^MODULES=/s/(.*)/($KMS_MODULE btrfs)/" \
  --expression "/^HOOKS=/s/(.*)/(${hooks_str})/"   \
  /etc/mkinitcpio.conf

grep --quiet "^MODULES=($KMS_MODULE btrfs)" /etc/mkinitcpio.conf || exit 1
grep --quiet '^HOOKS=(.*sd-encrypt' /etc/mkinitcpio.conf || exit 1

mkdir --parents /etc/cmdline.d

# Inject the dynamic CPU scaling parameter. rd.luks.options=tpm2-device=auto
# tells systemd-cryptsetup to try the TPM2 token before falling back to the
# passphrase, enabling seamless auto-unlock once the TPM key is enrolled.
cmdline="rd.luks.name=${LUKS_UUID}=cryptroot rd.luks.options=tpm2-device=auto "
cmdline+="root=/dev/mapper/cryptroot rw rootflags=subvol=@ $PSTATE_FLAG"

# Arch builds the kernel with CONFIG_ZSWAP_DEFAULT_ON=y. Left enabled, zswap
# intercepts pages before zram ever sees them, so the tuned zram device sits
# almost empty behind a cache nobody asked for. Shared by both profiles.
cmdline+=" zswap.enabled=0"

[[ -n "$EXTRA_CMDLINE" ]] && cmdline+=" $EXTRA_CMDLINE"

printf '%s\n' "$cmdline" > /etc/cmdline.d/root.conf

cat <<'PRESET' > /etc/mkinitcpio.d/linux.preset
ALL_config='/etc/mkinitcpio.conf'
ALL_kver='/boot/vmlinuz-linux'
PRESETS=('default' 'fallback')

default_uki='/boot/EFI/Linux/arch-linux.efi'
default_options=''

fallback_uki='/boot/EFI/Linux/arch-linux-fallback.efi'
fallback_options='-S autodetect'
PRESET

mkdir --parents /boot/EFI/Linux
mkinitcpio --allpresets

# Under the loop-device harness the ESP is a partition on a disk image mapped
# into the host's own running system, so writing EFI variables would add a boot
# entry to the HOST's NVRAM pointing at a file that is about to be deleted.
if [[ -n "$UNATTENDED" ]]; then
  bootctl install --variables=no
else
  bootctl install
fi

cat <<'LOADER' > /boot/loader/loader.conf
default arch-linux.efi
timeout 0
console-mode 0
editor no
LOADER

CHROOT

info -- 'Configuring DNS stub resolver...'
rm --force /mnt/etc/resolv.conf
ln --symbolic --force /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

if [[ -n "$UNATTENDED" ]]; then
  info -w 'Unattended mode: leaving the root account locked.'
else
  info -- 'Assign root password:'
  arch-chroot /mnt passwd root
fi

trap - EXIT

info -- '==> OS Installation Complete.'
info -- 'Preparing for Phase 2: Post-Installation...'

if [[ -f '/mnt/root/post_install.sh' ]]; then
  info -- 'You can now reboot into your new system, login as root,'
  info -- 'and run /root/post_install.sh'
else
  info -w 'post_install.sh not found in the new /root. Transfer manually.'
fi
info -- 'You can now umount -R /mnt and reboot.'

#-------------------------------------------- System Configuration (Chroot) ---
