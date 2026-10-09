#!/usr/bin/env bash

# post_install.sh - Arch Linux personal post-installation script.
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

set -euo pipefail

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

readonly USERNAME='librefos'

[[ "$EUID" -ne 0 ]] && info -e 'Please run this script as root.'

# Load Hardware Profile from Phase 1
PROFILE=$(cat /root/.deploy_profile 2>/dev/null || echo 'unknown')
readonly PROFILE

# Unattended mode exists so the test harness can drive phase two; see
# tests/vm.sh. It skips the dotfile and PKGBUILD selection prompts, and sets a
# throwaway user password instead of asking for one. It is never set on real
# hardware: the prompts are the point of running this script by hand.
readonly UNATTENDED="${ARCH_BOOTSTRAP_UNATTENDED:-}"
readonly TEST_PASSWORD="${ARCH_BOOTSTRAP_PASSWORD:-}"

# Where the two userland repositories come from, and what unattended mode
# picks out of them. tests/vm.sh points these at the working copies it stages
# into the guest, so a test run exercises the trees sitting on this machine --
# uncommitted changes included -- rather than whatever the remote is serving.
# Left unset, every line below behaves exactly as it does on real hardware.
# https rather than the ssh remote these are developed against: the machine
# being deployed has no key yet, and both repositories are public.
readonly DOTFILES_SRC="${ARCH_BOOTSTRAP_DOTFILES_SRC:-https://github.com/librefos/dotfiles}"
readonly PKGBUILDS_SRC="${ARCH_BOOTSTRAP_PKGBUILDS_SRC:-https://github.com/librefos/pkgbuilds}"

# Unattended mode selected nothing at all until these existed, which meant the
# two most failure-prone steps in this script -- stow's conflict handling and a
# makepkg build -- were the only ones no test ever ran.
readonly DOTFILE_PICK="${ARCH_BOOTSTRAP_DOTFILE_SELECTION:-}"
readonly PKGBUILD_PICK="${ARCH_BOOTSTRAP_PKGBUILD_SELECTION:-}"

case "$PROFILE" in
  amd)
    info -- "Applying AMD configuration..."
    # libva-mesa-driver no longer exists in the repositories. The
    # functionality was not dropped, it moved: radeonsi_drv_video.so is owned
    # by mesa, which is already installed on the same pacman line.
    readonly GPU_PKGS='vulkan-radeon'
    readonly VAAPI_ENV='radeonsi'
    MAKE_THREADS="-j$(nproc)"
    readonly MAKE_THREADS
    # Desktop: pin the governor to performance to minimize latency.
    readonly CPU_GOVERNOR='performance'
    readonly CPU_EPP=''
    readonly ZRAM_SIZE='ram / 2'
    readonly ZRAM_RESIDENT=''
    readonly PROFILE_PKGS=''
    # Desktop: US keyboard driven as US-International for dead-key accents.
    readonly XKB_LAYOUT='us'
    readonly XKB_VARIANT='intl'
    ;;
  intel)
    info -- "Applying Intel Celeron configuration..."
    readonly GPU_PKGS='vulkan-intel intel-media-driver'
    readonly VAAPI_ENV='iHD'
    # -l2.5 makes builds back off under load instead of thrashing 4 GB.
    readonly MAKE_THREADS='-j2 -l2.5'
    # Tiger Lake has HWP, so intel_pstate runs in active mode, where the only
    # valid governors are powersave and performance: schedutil, which this
    # script used to ask for, is not a value the driver accepts at all. Under
    # HWP the powersave pseudo-governor is the dynamic one and behaves much
    # like schedutil; the real performance-versus-battery knob is EPP.
    readonly CPU_GOVERNOR='powersave'
    readonly CPU_EPP='balance_power'
    # 6 GiB of capacity on a 4 GB machine, hard-capped near 2 GiB resident:
    # generous virtual capacity, firm ceiling on real footprint.
    readonly ZRAM_SIZE='ram * 1.5'
    readonly ZRAM_RESIDENT='ram / 2'
    readonly PROFILE_PKGS='earlyoom brightnessctl'
    # Laptop: native Brazilian ABNT2 keyboard.
    readonly XKB_LAYOUT='br'
    readonly XKB_VARIANT=''
    ;;
  *)
    info -e "Hardware profile not found in /root/.deploy_profile. Aborting."
    ;;
esac

#--- Helper Functions ---------------------------------------------------------

interactive_selection()
{
  # 'local -n' creates a bash nameref, this allows the function to directly
  # modify the passed variable from within the local scope.
  local -n _out_var="$1"
  local dir="$2"
  local script="$3"
  local label="$4"
  local verb="$5"
  local unattended_pick="${6:-}"

  # A failed clone -- an offline mirror, a moved repository, or one that needs
  # credentials this machine does not have -- leaves nothing here. The callers
  # already warn, and their comment promises the selection is simply skipped,
  # but without this guard the 'cd' below fails inside a command substitution
  # and set -e aborts the entire post-installation instead.
  if [[ ! -f "${dir}/${script}" ]]; then
    _out_var=""
    return 0
  fi

  local raw_list
  raw_list=$(su --login "$USERNAME" -c "cd $dir && ./$script --list") || raw_list=''

  if [[ -z "$raw_list" ]]; then
    _out_var=""
  elif [[ -n "$UNATTENDED" ]]; then
    # Whatever the harness asked for, unvalidated on purpose: the delegated
    # script already parses the selection and warns about names it does not
    # recognise, and duplicating that here would test this copy of the logic
    # instead of the one that actually runs.
    printf '\nAvailable %s: %s\n' "$label" "$raw_list"
    if [[ -z "$unattended_pick" ]]; then
      printf 'Unattended mode: selecting none.\n'
    else
      printf 'Unattended mode: selecting %s.\n' "$unattended_pick"
    fi
    _out_var="$unattended_pick"
  else
    printf '\nAvailable %s: %s\n' "$label" "$raw_list"
    # Forcing I/O to /dev/tty ensures the prompt appears on the physical screen
    # and captures keyboard input regardless of log redirection.
    printf 'Enter names to %s (comma-separated, or "all") ' "$verb" >/dev/tty
    printf 'or press Enter to skip: ' >/dev/tty
    read -r _out_var </dev/tty
  fi
}

#--------------------------------------------------------- Helper Functions ---
#--- Network Connectivity Check -----------------------------------------------

info -s 'Checking Network Connectivity'

if ! ping -c 1 -W 3 archlinux.org > /dev/null 2>&1; then
  info -w 'No network connectivity detected. Attempting network restart...'

  if [[ "$PROFILE" == 'amd' ]]; then
    systemctl restart systemd-networkd
  elif [[ "$PROFILE" == 'intel' ]]; then
    systemctl restart NetworkManager
  fi
  systemctl restart systemd-resolved

  info -- 'Waiting 5 seconds for DHCP lease...'
  sleep 5

  if ! ping -c 1 -W 3 archlinux.org > /dev/null 2>&1; then
    info -e 'Please fix your network connection manually.'
  fi
fi
info -- 'Network connectivity verified.'

#----------------------------------------------- Network Connectivity Check ---
#--- Mirror Management (Reflector) --------------------------------------------

info -s 'Mirror Management (Reflector)'

pacman --sync --noconfirm reflector

info -- 'Configuring Reflector for optimal South American routing...'
mkdir --parents /etc/xdg/reflector

cat <<EOF > /etc/xdg/reflector/reflector.conf
--save /etc/pacman.d/mirrorlist
--protocol https
--country Brazil,Argentina,Chile,Uruguay
--latest 20
--age 12
--completion-percent 100
--sort rate
--number 10
--connection-timeout 10
--download-timeout 20
EOF

info -- 'Updating mirrorlist for the rest of the installation...'
systemctl start reflector.service

info -- 'Enabling weekly automatic mirror rotation...'
systemctl enable reflector.timer

#-------------------------------------------- Mirror Management (Reflector) ---
#--- User Creation & Credentials ----------------------------------------------

info -s "Creating User ($USERNAME)"

if id "$USERNAME" &>/dev/null; then
  info -w "User $USERNAME already exists. Updating password."
else
  useradd --create-home --groups wheel --shell /bin/bash "$USERNAME"
fi

if [[ -n "$UNATTENDED" ]]; then
  [[ -z "$TEST_PASSWORD" ]] && \
    info -e 'ARCH_BOOTSTRAP_UNATTENDED needs ARCH_BOOTSTRAP_PASSWORD set.'
  info -w "Unattended mode: setting a throwaway password for $USERNAME."
  printf '%s:%s\n' "$USERNAME" "$TEST_PASSWORD" | chpasswd
else
  info -- "Set password for $USERNAME:"
  passwd "$USERNAME"
fi

info -- 'Installing sudo...'
pacman --sync --noconfirm sudo

info -- 'Configuring sudo with atomic creation and validation...'
mkdir --parents /etc/sudoers.d

install --mode 0440 /dev/null /etc/sudoers.d/10-wheel
printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
visudo --check --file /etc/sudoers.d/10-wheel || \
  info -e 'Failed to validate 10-wheel.'

install --mode 0440 /dev/null /etc/sudoers.d/11-editor
printf 'Defaults editor=/usr/bin/vi\n' > /etc/sudoers.d/11-editor
visudo --check --file /etc/sudoers.d/11-editor || \
  info -e 'Failed to validate 11-editor.'

#---------------------------------------------- User Creation & Credentials ---
#--- Configuring makepkg ------------------------------------------------------

info -s 'Configuring makepkg'

# Apply dynamic thread limitation based on hardware profile
sed --in-place \
  --expression 's/-march=[^ ]*/-march=native/g'                                   \
  --expression 's/-mtune=[^ ]*/-mtune=native/g'                                   \
  --expression "/^#MAKEFLAGS=/s/^#MAKEFLAGS=.*/MAKEFLAGS=\"${MAKE_THREADS}\"/"    \
  --expression 's|^#PKGDEST.*|PKGDEST="/var/cache/makepkg/packages"|'             \
  --expression 's|^#SRCDEST.*|SRCDEST="/var/cache/makepkg/sources"|'              \
  --expression 's|^#SRCPKGDEST.*|SRCPKGDEST="/var/cache/makepkg/srcpackages"|'    \
  --expression 's|^#LOGDEST.*|LOGDEST="/var/cache/makepkg/logs"|'                 \
  --expression 's|^#PACKAGER.*|PACKAGER="Thiago C. Silva <librefos@newliber.com>"|' \
  /etc/makepkg.conf

# Stock OPTIONS carries `debug`, so debug symbols are compiled and written to
# disk purely so the cleanup at the end of this script can delete them again.
# The substitutions are idempotent: once rewritten the token is preceded by
# '!', so it no longer matches.
sed --in-place '/^OPTIONS=/s/ debug/ !debug/' /etc/makepkg.conf

if [[ "$PROFILE" == 'intel' ]]; then
  # LTO link steps are memory hungry and can exceed this machine's 4 GB.
  # On the desktop lto is a genuine win that 32 GB absorbs comfortably.
  sed --in-place '/^OPTIONS=/s/ lto/ !lto/' /etc/makepkg.conf
fi

mkdir --parents /var/cache/makepkg/{packages,sources,srcpackages,logs}
chown --recursive "$USERNAME:$USERNAME" /var/cache/makepkg

#------------------------------------------------------ Configuring makepkg ---
#--- Interactive Selections ---------------------------------------------------

info -s 'Interactive Selections'

pacman --sync --noconfirm git base-devel stow

readonly DOTFILES_DIR="/home/$USERNAME/dotfiles"
readonly PKGBUILDS_DIR="/home/$USERNAME/pkgbuilds"

# fetch_repo <source> <destination>
# A remote is cloned. A local directory is copied, because the only thing that
# hands this script a local source is tests/vm.sh, and the tree it stages is
# owned by whoever built the payload image: git refuses to clone from a
# repository whose ownership it does not recognise, and a copy sidesteps that
# without teaching the real path a test-only exception. Copying also picks up
# uncommitted work, which is the point of testing a working copy.
fetch_repo()
{
  local source="$1" destination="$2"

  if [[ -d "$source" ]]; then
    info -- "Copying $source..."
    rm --recursive --force "$destination"
    cp --recursive --no-target-directory "$source" "$destination"
    chown --recursive "$USERNAME:$USERNAME" "$destination"
  else
    su --login "$USERNAME" -c "git clone $source $destination" || true
  fi
}

info -- 'Fetching repositories...'

fetch_repo "$DOTFILES_SRC"  "$DOTFILES_DIR"
fetch_repo "$PKGBUILDS_SRC" "$PKGBUILDS_DIR"

# Guard the chmod so a failed clone (offline mirror, moved repo) cannot abort
# the whole run under 'set -e'. Missing scripts simply skip their selection.
if [[ -f "$DOTFILES_DIR/deploy.sh" ]]; then
  su --login "$USERNAME" -c "chmod +x $DOTFILES_DIR/deploy.sh"
else
  info -w 'dotfiles deploy.sh not found; dotfile selection will be skipped.'
fi

if [[ -f "$PKGBUILDS_DIR/install.sh" ]]; then
  su --login "$USERNAME" -c "chmod +x $PKGBUILDS_DIR/install.sh"
else
  info -w 'pkgbuilds install.sh not found; package selection will be skipped.'
fi

DOTFILE_SELECTION=""
interactive_selection DOTFILE_SELECTION \
  "$DOTFILES_DIR" 'deploy.sh' 'dotfile packages' 'stow' "$DOTFILE_PICK"

PKGBUILD_SELECTION=""
interactive_selection PKGBUILD_SELECTION \
  "$PKGBUILDS_DIR" 'install.sh' 'custom packages' 'build' "$PKGBUILD_PICK"

info -- 'Selections recorded. The rest of the script is automated.'

#--------------------------------------------------- Interactive Selections ---
#--- Security Integration (UFW, TPM2, Secure Boot) ----------------------------

info -s 'Security Integration (UFW, TPM2, Secure Boot)'

info -- 'Installing UFW...'
pacman --sync --noconfirm ufw
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
systemctl enable ufw.service

info -- 'Integrating Secure Boot via sbctl...'
pacman --sync --noconfirm sbctl

# Whether enrollment actually happened. The block below is allowed to skip --
# aborting here would abandon a system that is otherwise fine -- but the final
# summary has to tell the truth about it, because a machine whose UKI is
# unsigned red-screens the moment Secure Boot is switched on.
SECUREBOOT_ENROLLED=''

if sbctl status --json | grep --quiet '"setup_mode": true'; then
  info -- 'System is in Setup Mode. Taking platform ownership...'
  sbctl create-keys
  sbctl enroll-keys --microsoft

  info -- 'Signing Unified Kernel Images and Bootloader...'
  sbctl sign --save /boot/EFI/Linux/arch-linux.efi
  sbctl sign --save /boot/EFI/Linux/arch-linux-fallback.efi
  sbctl sign --save /boot/EFI/systemd/systemd-bootx64.efi

  # The removable-media fallback path. The firmware boots this when no NVRAM
  # entry resolves -- after an NVRAM reset, a boot-order change or a CMOS
  # clear -- and an unsigned copy there is a red screen with no visible cause,
  # on a boot where nothing was touched. bootctl puts it here; sign it too.
  if [[ -f /boot/EFI/BOOT/BOOTX64.EFI ]]; then
    sbctl sign --save /boot/EFI/BOOT/BOOTX64.EFI
  fi

  SECUREBOOT_ENROLLED=1
else
  info -w 'System is NOT in Setup Mode. Secure Boot keys were NOT enrolled'
  info -w 'and nothing has been signed. This is reported again at the end.'
  info -w 'See the Secure Boot section of HACKING for the recovery procedure.'
fi

readonly SECUREBOOT_ENROLLED

info -- 'Deferring TPM 2.0 auto-unlock enrollment to first Secure Boot...'

# Sealing a LUKS key to PCR 7 (the Secure Boot state) is only valid once
# Secure Boot is ACTIVELY enforcing. Because Secure Boot only begins enforcing
# after the next reboot (and may require a manual UEFI toggle), enrolling here
# would bind the key to the Setup-Mode PCR 7 value and break on every boot.
#
# Instead we install a one-shot service that runs on the console at each boot,
# waits until Secure Boot is confirmed active, then enrolls the TPM against
# PCR 7 with a PIN and removes itself. PCR 7 (unlike PCR 0/4) is stable across
# firmware and kernel updates, so auto-unlock keeps working after upgrades.

install --mode 0755 /dev/null /usr/local/sbin/tpm2-enroll.sh
cat <<'ENROLL' > /usr/local/sbin/tpm2-enroll.sh
#!/usr/bin/env bash
# tpm2-enroll.sh - First-boot TPM2 LUKS auto-unlock enrollment (PCR 7 + PIN).
# Installed and enabled by post_install.sh; self-disabling once enrollment
# succeeds.
set -uo pipefail

readonly MARKER='/var/lib/tpm2-enroll.pending'
readonly SERVICE='tpm2-enroll.service'

msg() { printf '\n>>> %s\n' "$*"; }

# PCR 7 sealing is only meaningful while Secure Boot is enforcing. Wait for it.
if ! bootctl status 2>/dev/null | grep --quiet 'Secure Boot: enabled'; then
  msg 'Secure Boot is not enabled yet.'
  msg 'Enable Secure Boot in your UEFI firmware, then reboot.'
  msg 'TPM 2.0 enrollment will retry automatically on the next boot.'
  sleep 5
  exit 0
fi

crypt_dev=$(cryptsetup status cryptroot 2>/dev/null | awk '/device:/ {print $2}')
if [[ -z "${crypt_dev:-}" ]]; then
  msg 'Could not resolve the cryptroot backing device. Retrying next boot.'
  sleep 5
  exit 1
fi

msg "Enrolling TPM 2.0 auto-unlock (PCR 7 + PIN) for ${crypt_dev}."
msg 'Enter your CURRENT LUKS passphrase when asked, then choose a new PIN.'

# --wipe-slot=tpm2 makes re-runs idempotent and self-healing: any stale TPM
# keyslot (e.g. sealed against an earlier Secure Boot state) is replaced.
if systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto \
     --tpm2-pcrs=7 --tpm2-with-pin=yes "$crypt_dev"; then
  msg 'Success. Future boots unlock via the TPM with your PIN only.'
  rm --force "$MARKER"
  systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  sleep 3
else
  msg 'Enrollment failed or was cancelled. It will retry on the next boot.'
  sleep 5
  exit 1
fi
ENROLL

cat <<'UNIT' > /etc/systemd/system/tpm2-enroll.service
[Unit]
Description=First-boot TPM2 LUKS auto-unlock enrollment (PCR 7 + PIN)
ConditionPathExists=/var/lib/tpm2-enroll.pending
# Run late so logins are allowed. Before= alone delays getty@tty1 until this
# oneshot exits, so the passphrase/PIN prompts own the console and a login
# prompt follows naturally. Conflicts=getty@tty1.service must NOT be used:
# it cancels getty's start job for the whole boot, leaving tty1 without a
# login prompt once enrollment finishes.
After=systemd-user-sessions.service
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tpm2-enroll.sh
StandardInput=tty-force
StandardOutput=tty
StandardError=journal+console
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
UNIT

# Marker gates the service via ConditionPathExists; removed on success.
install --mode 0644 /dev/null /var/lib/tpm2-enroll.pending
systemctl enable tpm2-enroll.service

#---------------------------- Security Integration (UFW, TPM2, Secure Boot) ---
#--- Performance Tuning & Graphics --------------------------------------------

info -s 'Performance Tuning & Graphics'

# shellcheck disable=SC2086
pacman --sync --noconfirm mesa $GPU_PKGS xorg-server xorg-xinit \
                          zram-generator cpupower btrfsmaintenance

# Prevent NVMe wear by using zRAM to create a compressed in-memory block device.
cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# zram-size is uncompressed capacity; zram-resident-limit caps the physical
# RAM the device may actually consume. On a 4 GB machine the pairing is the
# point: plenty of virtual capacity without letting it eat the machine.
if [[ -n "$ZRAM_RESIDENT" ]]; then
  printf 'zram-resident-limit = %s\n' "$ZRAM_RESIDENT" \
    >> /etc/systemd/zram-generator.conf
fi

# Tune the VM subsystem for zram-backed swap: aggressively prefer the fast
# compressed RAM device over reclaim, and disable swap readahead (page-cluster
# 0) since zram has no seek penalty to amortize.
cat <<'EOF' > /etc/sysctl.d/99-zram.conf
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

systemctl enable cpupower.service

# cpupower.service reads EnvironmentFile=-/etc/default/cpupower-service.conf,
# and /usr/lib/systemd/scripts/cpupower reads $GOVERNOR, uppercase. Writing
# lowercase `governor` to /etc/default/cpupower, as this script used to, was a
# silent no-op twice over: wrong file, wrong case. The leading '-' on the
# EnvironmentFile means the absent file was never even an error, so the unit
# enabled cleanly and exited 0 while changing nothing.
printf 'GOVERNOR="%s"\n' "$CPU_GOVERNOR" > /etc/default/cpupower-service.conf

# The same file carries EPP, so both knobs live in one place.
if [[ -n "$CPU_EPP" ]]; then
  printf 'EPP="%s"\n' "$CPU_EPP" >> /etc/default/cpupower-service.conf
fi

# Owned by no package and read by nothing. Remove it so a later reader is not
# misled into thinking it is live configuration.
rm --force /etc/default/cpupower

systemctl enable btrfs-scrub.timer btrfs-balance.timer

if [[ "$PROFILE" == 'amd' ]]; then
  # The NM610 PRO is a DRAM-less design leaning on Host Memory Buffer, so
  # keeping its translation layer supplied with free blocks matters more than
  # it would on a DRAM-equipped drive. discard=async covers the common case;
  # the Btrfs wiki notes async discard can safely be used alongside periodic
  # trim, and periodic trim is currently not running at all.
  systemctl enable fstrim.timer
fi

# Attribute-matched, so this is a no-op on the desktop's NVMe, which already
# uses `none`. Written on both machines only so each carries the same explicit
# policy rather than relying on defaults that differ by device class.
cat <<'EOF' > /etc/udev/rules.d/60-ioschedulers.rules
# Rotational disks: BFQ can greatly accelerate application startup.
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
# Non-rotational SATA and SD/MMC.
ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# NVMe: no scheduler at all.
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
EOF


info -- "Configuring X11 keyboard layout (${XKB_LAYOUT}${XKB_VARIANT:+/$XKB_VARIANT})..."
mkdir --parents /etc/X11/xorg.conf.d
cat <<EOF > /etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$XKB_LAYOUT"
    Option "XkbVariant" "$XKB_VARIANT"
EndSection
EOF

if [[ "$PROFILE" == 'intel' ]]; then
  info -- 'Configuring libinput to enable touchpad tapping...'
  mkdir --parents /etc/X11/xorg.conf.d
  cat <<'EOF' > /etc/X11/xorg.conf.d/30-touchpad.conf
Section "InputClass"
    Identifier "touchpad"
    Driver "libinput"
    MatchIsTouchpad "on"
    Option "Tapping" "on"
EndSection
EOF
fi

#-------------------------------------------- Performance Tuning & Graphics ---
#--- Laptop Power Management --------------------------------------------------

# Everything below is intel-only. Implemented as explicit config files rather
# than by adopting TLP, so every setting stays visible in this repository
# instead of living in /etc/tlp.conf.
if [[ "$PROFILE" == 'intel' ]]; then
  info -s 'Laptop Power Management'

  if [[ -n "$PROFILE_PKGS" ]]; then
    # shellcheck disable=SC2086
    pacman --sync --noconfirm $PROFILE_PKGS
  fi

  # Deliberately not iwlmvm power_scheme=3, which the wiki flags as
  # experimental and destabilising.
  cat <<'EOF' > /etc/modprobe.d/iwlwifi.conf
options iwlwifi power_save=1
EOF

  # This can cause an audible pop when playback starts. It is the first file
  # to delete if that shows up.
  cat <<'EOF' > /etc/modprobe.d/audio_powersave.conf
options snd_hda_intel power_save=1 power_save_controller=Y
EOF

  # From Power management#PCI Runtime Power Management. No scsi_host link
  # policy rule: Arch already builds with CONFIG_SATA_MOBILE_LPM_POLICY=3,
  # which sets med_power_with_dipm without any parameter from us.
  cat <<'EOF' > /etc/udev/rules.d/50-pci_pm.rules
ACTION=="add", SUBSYSTEM=="pci", ATTR{power/control}="auto"
ACTION=="add", SUBSYSTEM=="ata_port", ATTR{power/control}="auto"
EOF

  # Paired with commit=120 on the root filesystem: both let the disk stay
  # spun down longer between writes.
  cat <<'EOF' > /etc/sysctl.d/99-laptop.conf
vm.dirty_writeback_centisecs = 6000
EOF

  # Hibernation is the biggest battery lever on a machine that is opened and
  # closed all day. suspend-then-hibernate suspends first and falls through to
  # hibernation once the delay expires, so a quick reopen is still instant.
  #
  # The lid switch is the only trigger, deliberately. IdleAction is pinned to
  # ignore -- its own default, written out so the choice stays visible here
  # instead of being implied by an absent line -- because logind cannot
  # measure idleness on this system. For a session of type tty it derives the
  # idle hint from the atime of the session's TTY, and X started by startx on
  # tty1 reads input from /dev/input/event* through libinput without ever
  # touching /dev/tty1. That atime freezes at the moment of login, so logind
  # concludes the session has been idle ever since. With IdleAction set to a
  # sleep action the machine suspended exactly IdleActionSec after login and
  # every IdleActionSec after that, mid-keystroke, with no way to defer it.
  # The lid switch has no such problem: it is an input event, not an
  # inference.
  #
  # Restoring an idle timeout means measuring idleness where it is actually
  # observable, inside X (xprintidle and a user timer, or a screen locker
  # that owns the policy), never here.
  mkdir --parents /etc/systemd/logind.conf.d /etc/systemd/sleep.conf.d
  cat <<'EOF' > /etc/systemd/logind.conf.d/laptop.conf
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=lock
IdleAction=ignore
EOF

  cat <<'EOF' > /etc/systemd/sleep.conf.d/hibernate.conf
[Sleep]
HibernateDelaySec=30min
EOF

  # Chosen over systemd-oomd, which needs cgroup and PSI configuration for the
  # same job. On 4 GB with a 5400 RPM swap fallback, an unhandled memory spike
  # means a multi-minute unresponsive swap storm. Never kill the session.
  # earlyoom matches on process name. X started via startx runs as 'Xorg', so
  # an anchored '(X|...)$' would not protect it; both spellings are listed.
  # init and systemd are kept from the package's own default as a safety net,
  # since this file replaces EARLYOOM_ARGS wholesale rather than adding to it.
  cat <<'EOF' > /etc/default/earlyoom
EARLYOOM_ARGS="-p --avoid '(^|/)(init|systemd|Xorg|X|dwm|st)$' --prefer '(^|/)firefox'"
EOF
  systemctl enable earlyoom.service

  # btrfsmaintenance already runs scrub at ionice `idle`, so no bandwidth cap
  # is warranted; what is missing is any awareness of battery. Hours of
  # maintenance I/O on a 5400 RPM disk while unplugged is brutal.
  for _unit in btrfs-scrub btrfs-balance; do
    mkdir --parents "/etc/systemd/system/${_unit}.service.d"
    cat <<'EOF' > "/etc/systemd/system/${_unit}.service.d/ac-only.conf"
[Unit]
ConditionACPower=true
EOF
  done

  # At roughly 760 cycles and 75% health on a machine that mostly lives
  # plugged in, capping charge is the highest-value battery item here. The
  # in-kernel samsung-galaxybook driver feature-probes per model, so detect
  # the attribute rather than assuming this model exposes it.
  BAT_THRESHOLD=$(printf '%s\n' /sys/class/power_supply/BAT*/charge_control_end_threshold | head -1)
  readonly BAT_THRESHOLD

  if [[ -e "$BAT_THRESHOLD" ]]; then
    printf 'w %s - - - - 80\n' "$BAT_THRESHOLD" \
      > /etc/tmpfiles.d/battery-threshold.conf
    info -- 'Battery charge capped at 80% on the next boot.'
  else
    info -w 'This model exposes no charge_control_end_threshold; skipping the'
    info -w 'battery charge cap. Nothing else in this script depends on it.'
  fi
fi

#-------------------------------------------------- Laptop Power Management ---
#--- Audio Stack & Hardware Mapping -------------------------------------------

info -s 'Audio Stack & Hardware Mapping'

pacman --sync --noconfirm pipewire pipewire-audio pipewire-pulse pipewire-alsa \
                          wireplumber polkit rtkit alsa-ucm-conf pipewire-jack \
                          alsa-utils

if [[ "$PROFILE" == 'amd' ]]; then
  # Card indices depend on probe order. This machine happens to put the ALC897
  # analog codec at index 1 and HDMI at 0 today, but hardcoding that means a
  # reordered probe silently unmutes the wrong device, and the per-control
  # `|| true` guards ensured nobody would ever notice. Resolve the card by
  # asking which one actually exposes a Master control instead.
  ANALOG_CARD=''
  for _card in /proc/asound/card[0-9]*; do
    _idx="${_card##*card}"
    if amixer --card "$_idx" sget Master &> /dev/null; then
      ANALOG_CARD="$_idx"
      break
    fi
  done
  readonly ANALOG_CARD

  if [[ -z "$ANALOG_CARD" ]]; then
    # Deliberately loud: this is the failure the old hardcoded index hid.
    info -w 'No ALSA card exposes a Master control. Audio left untouched.'
  else
    info -- "Unmuting ALSA analog output on card ${ANALOG_CARD}..."

    # These stay guarded: not every codec exposes every control.
    amixer --card "$ANALOG_CARD" sset Master unmute 100%    >/dev/null 2>&1 || true
    amixer --card "$ANALOG_CARD" sset Headphone unmute 100% >/dev/null 2>&1 || true
    amixer --card "$ANALOG_CARD" sset Speaker unmute 100%   >/dev/null 2>&1 || true
    amixer --card "$ANALOG_CARD" sset PCM unmute 100%       >/dev/null 2>&1 || true

    info -- 'Saving ALSA hardware state across reboots...'
    alsactl store
  fi
else
  info -- 'Skipping manual ALSA manipulation for laptop profile.'
fi

#------------------------------------------- Audio Stack & Hardware Mapping ---
#--- Fonts & Rendering --------------------------------------------------------

info -s 'Fonts & Rendering'

# Terminus (bitmap) already covers st/dwm/dmenu via their PKGBUILD deps. This
# stack handles GUI, web, and emoji rendering for Firefox and any Xft app:
#   fontconfig        owns /etc/fonts and provides fc-cache; the font packages
#                     do not depend on it, so it must be requested explicitly
#   noto-fonts        broad Unicode sans/serif coverage
#   noto-fonts-emoji  color emoji fallback
#   ttf-liberation    metric-compatible Arial/Times/Courier substitutes
pacman --sync --noconfirm fontconfig noto-fonts noto-fonts-emoji ttf-liberation

# System-wide fontconfig defaults. Firefox and GTK resolve their default
# families through fontconfig, so defining them here configures the browser
# without per-app tweaks, and appends color emoji to every fallback chain.
cat <<'EOF' > /etc/fonts/local.conf
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>Liberation Mono</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
</fontconfig>
EOF

fc-cache --force >/dev/null 2>&1 || true

#-------------------------------------------------------- Fonts & Rendering ---
#--- Web Browser (Firefox) ----------------------------------------------------

info -s 'Web Browser (Firefox)'

# The dotfiles force Firefox's file dialogs through the portal; without a
# backend, Open and Save show nothing.
pacman --sync --noconfirm firefox-developer-edition xdg-desktop-portal-gtk

# dwm sets no XDG_CURRENT_DESKTOP, so name the backend explicitly.
mkdir --parents /etc/xdg/xdg-desktop-portal
cat <<'EOF' > /etc/xdg/xdg-desktop-portal/portals.conf
[preferred]
default=gtk
EOF

info -- 'Configuring hardware acceleration via environment variables...'

[[ ! -f /etc/environment ]] && install --mode 0644 /dev/null /etc/environment
# Strip any prior entry first so re-running the script never stacks duplicates.
sed --in-place '/^LIBVA_DRIVER_NAME=/d' /etc/environment
printf 'LIBVA_DRIVER_NAME=%s\n' "$VAAPI_ENV" >> /etc/environment

#---------------------------------------------------- Web Browser (Firefox) ---
#--- Snapper and Automatic Btrfs Snapshots ------------------------------------

info -s 'Snapper and Automatic Btrfs Snapshots'

pacman --sync --noconfirm snapper snap-pac

[[ ! -f /etc/snapper/configs/root ]] && snapper --config root create-config /

if [[ "$PROFILE" == 'intel' ]]; then
  # Every timeline snapshot is write I/O on a 5400 RPM disk. snap-pac's
  # pre/post-pacman pair is the one actually worth its cost, and is untouched.
  readonly SNAP_MIN_AGE_SEC='3600'
  readonly SNAP_KEEP_HOURLY='3'
else
  readonly SNAP_MIN_AGE_SEC='1800'
  readonly SNAP_KEEP_HOURLY='5'
fi
readonly SNAP_KEEP_DAILY='7'
readonly SNAP_KEEP_WEEKLY='2'
readonly SNAP_KEEP_MONTHLY='1'
readonly SNAP_KEEP_YEARLY='0'

sed --in-place \
  --expression "/TIMELINE_MIN_AGE/s/=.*/=\"${SNAP_MIN_AGE_SEC}\"/"        \
  --expression "/TIMELINE_LIMIT_HOURLY/s/=.*/=\"${SNAP_KEEP_HOURLY}\"/"   \
  --expression "/TIMELINE_LIMIT_DAILY/s/=.*/=\"${SNAP_KEEP_DAILY}\"/"     \
  --expression "/TIMELINE_LIMIT_WEEKLY/s/=.*/=\"${SNAP_KEEP_WEEKLY}\"/"   \
  --expression "/TIMELINE_LIMIT_MONTHLY/s/=.*/=\"${SNAP_KEEP_MONTHLY}\"/" \
  --expression "/TIMELINE_LIMIT_YEARLY/s/=.*/=\"${SNAP_KEEP_YEARLY}\"/"   \
  /etc/snapper/configs/root

systemctl enable snapper-timeline.timer snapper-cleanup.timer

#------------------------------------ Snapper and Automatic Btrfs Snapshots ---
#--- Base Documentation Tools -------------------------------------------------

info -s 'Base Documentation Tools'

pacman --sync --noconfirm man-db man-pages texinfo

#----------------------------------------------------- Base Documentation Tools
#--- Dotfiles Deployment ------------------------------------------------------

info -s 'Dotfiles Deployment'

cleanup_sudoers()
{
  rm --force /etc/sudoers.d/zz-dotfiles-install /etc/sudoers.d/zz-makepkg-pacman
}
trap cleanup_sudoers EXIT

if [[ -n "$DOTFILE_SELECTION" ]]; then
  # deploy.sh installs the system-wide Firefox policies via 'sudo install'.
  # Running under 'su' from a root-owned console, sudo cannot read a password
  # from the tty (the device still belongs to root), so grant a temporary
  # passwordless rule for /usr/bin/install, mirroring the makepkg pattern
  # below, and revoke it right after.
  info -- 'Temporarily granting passwordless install access for deploy.sh...'

  install --mode 0440 /dev/null /etc/sudoers.d/zz-dotfiles-install
  printf '%s\n' "${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/install" \
    > /etc/sudoers.d/zz-dotfiles-install
  visudo --check --file /etc/sudoers.d/zz-dotfiles-install || \
    info -e 'Failed to validate zz-dotfiles-install.'

  info -- 'Delegating deployment to deploy.sh...'
  if ! su --login "$USERNAME" -c \
       "cd $DOTFILES_DIR && ./deploy.sh '$DOTFILE_SELECTION'"; then
    info -w 'Dotfiles deployment encountered an error, continuing setup.'
  fi

  info -- 'Revoking passwordless install access...'
  rm --force /etc/sudoers.d/zz-dotfiles-install
else
  info -- 'Skipping dotfile deployment.'
fi

#------------------------------------------------------ Dotfiles Deployment ---
#--- Custom PKGBUILD Compilation ----------------------------------------------

info -s 'Custom PKGBUILD Compilation'

if [[ -n "$PKGBUILD_SELECTION" ]]; then
  info -- 'Temporarily granting passwordless pacman access for makepkg...'

  install --mode 0440 /dev/null /etc/sudoers.d/zz-makepkg-pacman
  printf '%s\n' "${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/pacman" \
    > /etc/sudoers.d/zz-makepkg-pacman
  visudo --check --file /etc/sudoers.d/zz-makepkg-pacman || info -e 'Validation failed.'

  info -- 'Delegating package compilation to install.sh...'

  if ! su --login "$USERNAME" -c "cd $PKGBUILDS_DIR && \\
       ./install.sh '$PKGBUILD_SELECTION'"; then
    info -w 'Package compilation encountered an error, continuing setup.'
  fi

  info -- 'Revoking passwordless pacman access...'
else
  info -- 'Skipping custom package compilation.'
fi

cleanup_sudoers
trap - EXIT

info -- 'Updating man page database...'
mandb --quiet

#---------------------------------------------- Custom PKGBUILD Compilation ---
#--- System Cleanup -----------------------------------------------------------

info -s 'System Cleanup'

ORPHANS=$(pacman --query --deps --unrequired --quiet || true)
readonly ORPHANS
if [[ -n "$ORPHANS" ]]; then
  info -- 'Removing orphaned packages...'
  # shellcheck disable=SC2086
  pacman --remove --nosave --recursive --noconfirm $ORPHANS
fi

DEBUG_PKGS=$(pacman --query --quiet | grep '\-debug$' || true)
readonly DEBUG_PKGS
if [[ -n "$DEBUG_PKGS" ]]; then
  info -- 'Removing -debug packages...'
  # shellcheck disable=SC2086
  pacman --remove --nosave --recursive --noconfirm $DEBUG_PKGS
fi

info -- 'Clearing pacman and user caches...'
pacman --sync --clean --clean --noconfirm

rm --recursive --force "/home/$USERNAME/.cache/"* 2>/dev/null || true
chown --recursive "$USERNAME:$USERNAME" "/home/$USERNAME"

#----------------------------------------------------------- System Cleanup ---
#--- Setup Complete -----------------------------------------------------------

info -s 'Setup Complete'

if [[ -n "$SECUREBOOT_ENROLLED" ]]; then
  info -- 'Next steps for TPM 2.0 auto-unlock (LUKS passphrase-free boot):'
  info -- '  1. Reboot and enter your UEFI firmware setup.'
  info -- '  2. Ensure Secure Boot is ENABLED (keys are signed and enrolled).'
  info -- '  3. On the next boot, a console prompt will ask for your current'
  info -- '     LUKS passphrase and a new PIN, then enrollment finishes itself.'
  info -- '  4. From then on the disk unlocks with your PIN (no passphrase).'
  info -- 'If Secure Boot stays disabled, enrollment safely retries each boot.'
else
  info -w '=============================================================='
  info -w 'SECURE BOOT KEYS WERE NOT ENROLLED.'
  info -w 'The firmware was not in Setup Mode when this script reached that'
  info -w 'step, so no keys were created and nothing was signed.'
  info -w ''
  info -w 'Do NOT enable Secure Boot yet. The UKI is unsigned, and the'
  info -w 'firmware will refuse to boot it -- on some machines with nothing'
  info -w 'more informative than a red screen after the vendor logo.'
  info -w ''
  info -w 'TPM 2.0 enrollment stays queued and will not run until Secure'
  info -w 'Boot is enforcing. Nothing else on this system is affected, and'
  info -w 'the disk still unlocks with the passphrase.'
  info -w ''
  info -w 'Recovery procedure: see the Secure Boot section of HACKING.'
  info -w '=============================================================='
fi
info -- ''
info -- 'You may now reboot into your user account and run startx.'

#----------------------------------------------------------- Setup Complete ---
