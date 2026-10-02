#!/usr/bin/env bash

# vm.sh - Boot the installer in a virtual machine and assert on the result.
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
# Replaces the old test_env.sh. That script hand-assembled a QEMU command line,
# started swtpm itself, copied OVMF_VARS by hand, then printed instructions and
# waited for a human to type commands and read a log. systemd-vmspawn provides
# all of the plumbing as flags, and tests/assertions.sh does the reading, so
# nothing here needs a person watching it.
#
# Nothing runs as root on the host: the installer runs inside the guest, where
# /dev/mapper/cryptroot and the host's mirrorlist, swap and pacman.conf are not
# at risk.
#
# Usage: ./tests/vm.sh [--profile amd|intel] [--interactive] [--keep]
#                      [--dotfiles LIST] [--pkgbuilds LIST] [--userland DIR]

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
readonly REPO_DIR

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

#--- Arguments ----------------------------------------------------------------

PROFILE='amd'
INTERACTIVE=''
KEEP=''
PHASE='both'

# What phase two stows and builds. 'all' and 'none' are passed straight
# through: deploy.sh and the pkgbuilds install.sh both understand 'all', and
# 'none' matches nothing, which is what the harness did before it could
# select anything at all.
#
# The dotfiles default to everything because stowing is seconds of work and
# the conflict handling is the interesting part. The PKGBUILDs do not: 'all'
# here means compiling Emacs and llama.cpp inside a VM. Two suckless builds
# exercise the same makepkg path -- the temporary sudoers rule, PKGDEST, the
# --syncdeps dependency pull -- in a couple of minutes instead of hours.
USERLAND_DIR=''
DOTFILE_PICK='all'
PKGBUILD_PICK='dmenu-git,st-git'

while (( $# > 0 )); do
  case "$1" in
    --profile)     PROFILE="${2:-}"; shift 2 ;;
    --phase)       PHASE="${2:-}"; shift 2 ;;
    --userland)    USERLAND_DIR="${2:-}"; shift 2 ;;
    --dotfiles)    DOTFILE_PICK="${2:-}"; shift 2 ;;
    --pkgbuilds)   PKGBUILD_PICK="${2:-}"; shift 2 ;;
    --interactive) INTERACTIVE='yes'; shift ;;
    --keep)        KEEP='yes'; shift ;;
    -h|--help)
      printf 'Usage: %s [--profile amd|intel] [--phase install|post|both]\n' "$0"
      printf '       %*s [--interactive] [--keep]\n' ${#0} ''
      printf '       %*s [--dotfiles LIST] [--pkgbuilds LIST] [--userland DIR]\n' ${#0} ''
      printf '\n'
      printf 'LIST is comma-separated, or "all", or "none".\n'
      printf 'DIR holds the dotfiles/ and pkgbuilds/ working copies\n'
      printf '(default: tmp/ in this repository).\n'
      exit 0
      ;;
    *) info -e "Unknown argument: $1" ;;
  esac
done

[[ "$DOTFILE_PICK"  == 'none' ]] && DOTFILE_PICK=''
[[ "$PKGBUILD_PICK" == 'none' ]] && PKGBUILD_PICK=''

readonly PROFILE INTERACTIVE KEEP PHASE DOTFILE_PICK PKGBUILD_PICK

case "$PHASE" in
  install|post|both) ;;
  *) info -e "Invalid phase '$PHASE'. Must be install, post or both." ;;
esac

[[ "$PROFILE" != 'amd' && "$PROFILE" != 'intel' ]] && \
  info -e "Invalid profile '$PROFILE'. Must be 'amd' or 'intel'."

# Model the disk each profile actually ships with. This is not cosmetic: the
# two names take different branches of the partition-suffix logic in
# install.sh, so testing both is testing something real.
#   amd    Lexar NM610 PRO NVMe  -> /dev/nvme0n1 -> nvme0n1p1
#   intel  rotational SATA disk  -> /dev/sda     -> sda1
#
# The size differs for a reason that is easy to trip over. intel carves a 6 GiB
# hibernation swapfile out of the disk and pulls the whole linux-firmware
# package rather than the amdgpu subset, so the same 20G that leaves amd
# comfortable leaves intel building packages in what is left. qcow2 is sparse,
# so the larger number costs nothing until it is used.
if [[ "$PROFILE" == 'amd' ]]; then
  readonly DISK_TYPE='nvme' TARGET_DISK='/dev/nvme0n1' DISK_SIZE='20G'
else
  readonly DISK_TYPE='virtio-scsi' TARGET_DISK='/dev/sda' DISK_SIZE='28G'
fi

#---------------------------------------------------------------- Arguments ---
#--- Environment Configuration ------------------------------------------------

readonly CACHE_DIR="${REPO_DIR}/tests/.cache"
readonly WORK_DIR="${REPO_DIR}/tests/.work"
readonly PAYLOAD_DIR="${WORK_DIR}/payload"

# The dotfiles and PKGBUILD working copies. post_install.sh clones both from
# sourcehut when it is left to itself, which tests whatever the remote is
# serving rather than what is on this machine, and puts a network fetch on the
# critical path of every run. Staging the local trees instead is what closes
# the last gap between a test run and a real deployment.
[[ -z "$USERLAND_DIR" ]] && USERLAND_DIR="${REPO_DIR}/tmp"
readonly USERLAND_DIR
readonly DOTFILES_SRC="${USERLAND_DIR}/dotfiles"
readonly PKGBUILDS_SRC="${USERLAND_DIR}/pkgbuilds"
readonly REPO_IMAGE="${WORK_DIR}/repo.img"
readonly REPO_LABEL='ARCHBOOTSTRAP'

# Printed by the guest and read back out of the forwarded journal. Distinctive
# enough that it cannot collide with ordinary installer output.
readonly MARKER='ARCH_BOOTSTRAP_RESULT'

readonly ISO_NAME='archlinux-x86_64.iso'
readonly MIRROR='https://mirror.ufscar.br/archlinux/iso/latest'
readonly ISO="${CACHE_DIR}/${ISO_NAME}"

readonly TARGET_IMAGE="${WORK_DIR}/${PROFILE}-target.qcow2"

# Only ever unlock a disposable disk image, and never leave this repository.
readonly PASSPHRASE='arch-bootstrap-test'
readonly USER_PASSWORD='arch-bootstrap-test'

# Half the host, capped, exactly as the old orchestrator did.
HOST_CORES=$(nproc)
CALC_CORES=$(( HOST_CORES / 2 ))
(( CALC_CORES > 4 )) && CALC_CORES=4
(( CALC_CORES < 1 )) && CALC_CORES=1
readonly VM_CORES="$CALC_CORES"

HOST_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CALC_RAM=$(( HOST_RAM_MB / 2 ))
(( CALC_RAM > 4096 )) && CALC_RAM=4096
(( CALC_RAM < 2048 )) && CALC_RAM=2048
readonly VM_RAM="$CALC_RAM"

for tool in systemd-vmspawn qemu-system-x86_64 qemu-img swtpm curl; do
  command -v "$tool" &> /dev/null || \
    info -e "$tool is not installed. Need: qemu-base, swtpm, curl, systemd."
done

# vmspawn finds the rest itself, but a clear message beats an opaque failure.
[[ -e /dev/kvm ]] || info -w 'No /dev/kvm; the VM will run without acceleration.'

#------------------------------------------------ Environment Configuration ---
#--- Traps & Cleanup ----------------------------------------------------------

cleanup()
{
  trap - EXIT
  if [[ -z "$KEEP" ]]; then
    info -- 'Removing the disposable disk, NVRAM and TPM state...'
    rm --recursive --force "$WORK_DIR"
  else
    info -- "Kept: $WORK_DIR"
  fi
}

trap cleanup    EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

#---------------------------------------------------------- Traps & Cleanup ---
#--- Asset Preparation --------------------------------------------------------

info -s 'Asset Preparation'

mkdir --parents "$CACHE_DIR" "$WORK_DIR"

# --forward-journal appends, and --keep leaves the work directory behind, so a
# run following a kept run would replay the previous guest's transcript ahead
# of its own. The verdict survives that -- marker() reads the last value -- but
# anyone reading the log sees two sets of assertions from two versions of the
# tree and has no way to tell which is current. Start every run with no
# journals; --keep still preserves the disk image, NVRAM and TPM state.
rm --force "${WORK_DIR}"/*.journal

# Phase two boots the disk phase one produced, so it never touches the ISO.
if [[ "$PHASE" == 'post' ]]; then
  info -- 'Phase two only: skipping the ISO.'
elif [[ ! -f "$ISO" ]]; then
  info -- 'Downloading the Arch Linux ISO (~1.6 GB, cached in tests/.cache)...'
  curl --fail --location --progress-bar --output "${ISO}.part" \
       "${MIRROR}/${ISO_NAME}" || info -e 'Failed to download the ISO.'
  mv "${ISO}.part" "$ISO"
else
  info -- 'ISO already cached. Skipping download.'
fi

# The ISO is booted, so it is worth knowing it is the one upstream published.
if [[ "$PHASE" != 'post' ]]; then
info -- 'Verifying the ISO checksum...'
if EXPECTED=$(curl --fail --silent --location "${MIRROR}/sha256sums.txt" 2>/dev/null \
              | awk -v n="$ISO_NAME" '$2 == n {print $1}') && [[ -n "$EXPECTED" ]]; then
  ACTUAL=$(sha256sum "$ISO" | awk '{print $1}')
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    info -e "ISO checksum mismatch. Delete $ISO and re-run."
  fi
  info -- 'Checksum matches.'
else
  info -w 'Could not fetch sha256sums.txt; continuing without verification.'
fi
fi

# The target disk is created by phase one, not here: creating it at this point
# would wipe the installed system out from under a '--phase post' run.

#-------------------------------------------------------- Asset Preparation ---
#--- Guest Automation ---------------------------------------------------------

# The repository reaches the guest as a small ext4 disk rather than a virtiofs
# bind. --bind needs virtiofsd, which has to map a UID range into a user
# namespace; unprivileged it can only get one from systemd-nsresourced, whose
# socket ships disabled, and vmspawn rejects --private-users= unless the VM
# boots from --directory=. mkfs.ext4 -d builds a populated image with no root
# at all, so this route needs nothing enabled and nothing installed.
info -- 'Staging the repository into a disk image...'
rm --recursive --force "$PAYLOAD_DIR"
mkdir --parents "${PAYLOAD_DIR}/tests"
cp "${REPO_DIR}/install.sh" "${REPO_DIR}/post_install.sh" "$PAYLOAD_DIR/"
cp "${REPO_DIR}"/tests/*.sh "${PAYLOAD_DIR}/tests/"

# stage_userland <source> <name> -> 0 if the guest can use a local copy
# Absence is a warning, not an error: without a working copy the guest falls
# back to cloning, which is still a valid run, just a less faithful one.
stage_userland()
{
  local source="$1" name="$2"

  if [[ ! -d "$source" ]]; then
    info -w "No ${name} working copy at ${source}."
    info -w "The guest will clone ${name} from its remote instead."
    return 1
  fi

  mkdir --parents "${PAYLOAD_DIR}/repos"
  cp --recursive "$source" "${PAYLOAD_DIR}/repos/${name}"
  # History is dead weight in a tree post_install.sh copies rather than clones.
  rm --recursive --force "${PAYLOAD_DIR}/repos/${name}/.git"
  info -- "Staged ${name} from ${source}."
  return 0
}

STAGED_DOTFILES=''
STAGED_PKGBUILDS=''
stage_userland "$DOTFILES_SRC"  'dotfiles'  && STAGED_DOTFILES='yes'
stage_userland "$PKGBUILDS_SRC" 'pkgbuilds' && STAGED_PKGBUILDS='yes'
readonly STAGED_DOTFILES STAGED_PKGBUILDS

# What phase two exports before it runs anything. assertions.sh reads the two
# selection variables as well, so what gets checked and what got installed
# cannot drift apart: they are the same string.
GUEST_ENV="export ARCH_BOOTSTRAP_DOTFILE_SELECTION='${DOTFILE_PICK}'
export ARCH_BOOTSTRAP_PKGBUILD_SELECTION='${PKGBUILD_PICK}'"

if [[ -n "$STAGED_DOTFILES" ]]; then
  GUEST_ENV+="
export ARCH_BOOTSTRAP_DOTFILES_SRC='/srv/shared/repos/dotfiles'"
fi
if [[ -n "$STAGED_PKGBUILDS" ]]; then
  GUEST_ENV+="
export ARCH_BOOTSTRAP_PKGBUILDS_SRC='/srv/shared/repos/pkgbuilds'"
fi
readonly GUEST_ENV

# Phase one: partition, encrypt, bootstrap, then assert on the mounted tree.
cat <<GUEST > "${PAYLOAD_DIR}/phase-install.sh"
#!/usr/bin/env bash
# Generated by tests/vm.sh. Runs inside the guest, not on the host.
# Everything it prints is forwarded to the host as part of the guest journal.
set -uo pipefail

printf '\n=== install.sh %s %s ===\n' '$TARGET_DISK' '$PROFILE'
export ARCH_BOOTSTRAP_UNATTENDED=1
export ARCH_BOOTSTRAP_PASSPHRASE='$PASSPHRASE'

if /srv/shared/install.sh '$TARGET_DISK' '$PROFILE'; then
  printf '${MARKER}_INSTALL=0\n'
else
  printf '${MARKER}_INSTALL=%d\n' "\$?"
  printf '\n!!! install.sh failed; skipping assertions.\n'
  exit 0
fi

printf '\n=== assertions.sh /mnt %s ===\n' '$PROFILE'
/srv/shared/tests/assertions.sh /mnt '$PROFILE'
printf '${MARKER}_ASSERT=%d\n' "\$?"

# The installer tells the operator to run 'umount -R /mnt' and reboot, so that
# had better work. Anything install.sh leaves holding the tree open -- an
# active swapfile is the easy way to get this wrong -- shows up here and
# nowhere else, since the guest would otherwise just power off regardless.
printf '\n=== clean unmount ===\n'
umount --recursive /mnt
printf '${MARKER}_UMOUNT=%d\n' "\$?"
GUEST

# Phase two: the installed system, booted for real. This is the only place the
# UKI, sd-boot, the LUKS unlock and post_install.sh are exercised at all.
cat <<GUEST > "${PAYLOAD_DIR}/phase-post.sh"
#!/usr/bin/env bash
# Generated by tests/vm.sh. Runs inside the booted target system.
set -uo pipefail

printf '\n=== post_install.sh (%s) ===\n' '$PROFILE'
export ARCH_BOOTSTRAP_UNATTENDED=1
export ARCH_BOOTSTRAP_PASSWORD='$USER_PASSWORD'
${GUEST_ENV}

if /srv/shared/post_install.sh; then
  printf '${MARKER}_POST=0\n'
else
  printf '${MARKER}_POST=%d\n' "\$?"
  printf '\n!!! post_install.sh failed; skipping assertions.\n'
  exit 0
fi

# Against a live root this runs the baseline, the post_install expectations
# and the running-kernel checks, which is the full set.
printf '\n=== assertions.sh / %s ===\n' '$PROFILE'
/srv/shared/tests/assertions.sh / '$PROFILE'
printf '${MARKER}_POSTASSERT=%d\n' "\$?"
GUEST

chmod +x "${PAYLOAD_DIR}"/*.sh "${PAYLOAD_DIR}"/tests/*.sh

# Sized from the payload rather than fixed: the staged working copies do not
# fit in the 64M the two installers alone needed, and mkfs.ext4 fails outright
# rather than truncating when they do not.
PAYLOAD_MB=$(du --summarize --block-size=1M "$PAYLOAD_DIR" | cut -f1)
readonly IMAGE_MB=$(( PAYLOAD_MB * 2 + 64 ))

rm --force "$REPO_IMAGE"
mkfs.ext4 -q -L "$REPO_LABEL" -d "$PAYLOAD_DIR" "$REPO_IMAGE" "${IMAGE_MB}M" \
  || info -e 'Failed to build the repository image.'

# write_unit <phase-script-basename> <extra-unit-directives>
# systemd-debug-generator picks these up from the credentials vmspawn passes in
# over SMBIOS, so neither the stock ISO nor the installed system is modified to
# run the test. An added unit is inert until something wants it, so the
# drop-in on the default target is what actually pulls it into the boot.
write_unit()
{
  local script="$1" extra="${2:-}"

  cat <<UNIT > "${WORK_DIR}/test.service"
[Unit]
Description=arch-bootstrap automated test (${script})
ConditionPathExists=!/etc/initrd-release
After=network-online.target systemd-timesyncd.service
Wants=network-online.target
${extra}

[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=90min
# info() in both installers calls tput unguarded. A systemd unit has no TTY and
# no TERM, so tput exits 2 and set -e kills the script before it does anything.
Environment=TERM=linux
ExecStartPre=/usr/bin/mkdir --parents /srv/shared
ExecStartPre=/usr/bin/udevadm settle
ExecStartPre=/usr/bin/mount -o ro LABEL=${REPO_LABEL} /srv/shared
ExecStart=/srv/shared/${script}
# Flush before powering off, or the tail of the run never reaches the host.
ExecStopPost=/usr/bin/journalctl --sync
ExecStopPost=/usr/bin/systemctl poweroff --no-block
UNIT

  cat <<'DROPIN' > "${WORK_DIR}/multi-user.dropin"
[Unit]
Wants=arch-bootstrap-test.service
DROPIN
}

#--------------------------------------------------------- Guest Automation ---
#--- VM Orchestration ---------------------------------------------------------

# marker <journal> <suffix> -> the value the guest printed, or empty
marker()
{
  journalctl --file="$1" --output=cat --no-pager 2>/dev/null \
    | grep --only-matching --perl-regexp "${MARKER}_$2=\\K\\d+" | tail -1
}

# run_vm <journal> <extra vmspawn args...>
run_vm()
{
  local journal="$1"; shift

  local args=(
    "--ram=${VM_RAM}M"
    "--cpus=${VM_CORES}"
    '--network-user-mode'

    # Plain UEFI, not the Secure Boot firmware: that variant refuses the
    # unsigned Arch ISO. Secure Boot is enrolled later by post_install.sh,
    # from setup mode, which is why phase two still finds it disabled.
    '--firmware=uefi'
    '--secure-boot=no'
    "--efi-nvram-state=${WORK_DIR}/nvram.fd"

    # swtpm is started and torn down by vmspawn, so neither the socket race the
    # old orchestrator slept through nor the manual OVMF_VARS copy remains.
    '--tpm=yes'
    "--tpm-state=${WORK_DIR}/tpm"

    "--extra-drive=raw:virtio-blk:${REPO_IMAGE}"
    "--forward-journal=${journal}"

    # Results come out of the forwarded journal, never over SSH. Leaving this
    # on means vmspawn generates a throwaway key on every boot, which is one
    # more thing to fail for no benefit -- and it does fail.
    '--pass-ssh-key=no'
    "$@"
  )

  if [[ -n "$INTERACTIVE" ]]; then
    args+=( '--console=interactive' )
  else
    args+=(
      '--console=headless'
      "--load-credential=systemd.extra-unit.arch-bootstrap-test.service:${WORK_DIR}/test.service"
      "--load-credential=systemd.unit-dropin.multi-user.target:${WORK_DIR}/multi-user.dropin"
    )
  fi

  systemd-vmspawn "${args[@]}" || info -w 'vmspawn exited non-zero.'
}

#------------------------------------------------------- VM Orchestration -----
#--- Phase One: Installation --------------------------------------------------

readonly JOURNAL_INSTALL="${WORK_DIR}/phase-install.journal"
readonly JOURNAL_POST="${WORK_DIR}/phase-post.journal"

if [[ "$PHASE" == 'install' || "$PHASE" == 'both' ]]; then
  info -s 'Phase One: Installation'
  info -- "Profile ${PROFILE}, ${VM_CORES} cores, ${VM_RAM}MB RAM, target ${TARGET_DISK}."

  info -- "Creating a fresh ${DISK_SIZE} target disk..."
  rm --force "$TARGET_IMAGE"
  qemu-img create -f qcow2 "$TARGET_IMAGE" "$DISK_SIZE" > /dev/null

  # A pristine NVRAM each time, so a stale boot entry cannot mask a bootloader
  # that was never actually installed.
  rm --force "${WORK_DIR}/nvram.fd"

  write_unit 'phase-install.sh' 'After=pacman-init.service
Wants=pacman-init.service'

  if [[ -z "$INTERACTIVE" ]]; then
    info -- 'Headless. The guest installs, asserts, and powers itself off.'
    info -- 'Several minutes, most of it pacstrap downloading packages.'
  else
    info -- 'Interactive. Inside the guest, mount the repository and run:'
    info -- "  mkdir -p /srv/shared && mount -o ro LABEL=${REPO_LABEL} /srv/shared"
    info -- '  /srv/shared/phase-install.sh'
  fi

  run_vm "$JOURNAL_INSTALL" \
    "--image=${ISO}" '--image-disk-type=scsi-cd' \
    "--extra-drive=qcow2:${DISK_TYPE}:${TARGET_IMAGE}"

  if [[ -z "$INTERACTIVE" ]]; then
    journalctl --file="$JOURNAL_INSTALL" --output=cat --no-pager 2>/dev/null \
      | sed --quiet '/=== assertions.sh/,$p'

    INSTALL_STATUS=$(marker "$JOURNAL_INSTALL" 'INSTALL')
    ASSERT_STATUS=$(marker  "$JOURNAL_INSTALL" 'ASSERT')
    UMOUNT_STATUS=$(marker  "$JOURNAL_INSTALL" 'UMOUNT')

    if [[ -z "$INSTALL_STATUS" ]]; then
      info -w "Inspect: journalctl --file=${JOURNAL_INSTALL}"
      info -e 'The guest never reported back from phase one.'
    fi
    (( INSTALL_STATUS != 0 )) && info -e "install.sh failed (exit ${INSTALL_STATUS})."
    [[ "$ASSERT_STATUS" != '0' ]] && info -e 'Phase one assertions failed.'
    [[ "$UMOUNT_STATUS" != '0' ]] && \
      info -e "'umount -R /mnt' failed in the guest (exit ${UMOUNT_STATUS:-unknown})."

    info -- 'Phase one passed: installed, asserted, unmounted cleanly.'
  fi
fi

#-------------------------------------------------- Phase One: Installation ---
#--- Phase Two: Post-installation ---------------------------------------------

if [[ "$PHASE" == 'post' || "$PHASE" == 'both' ]]; then
  info -s 'Phase Two: Post-installation'

  [[ -f "$TARGET_IMAGE" ]] || \
    info -e "No installed disk at $TARGET_IMAGE. Run --phase install first."

  info -- "Stowing: ${DOTFILE_PICK:-none}. Building: ${PKGBUILD_PICK:-none}."

  write_unit 'phase-post.sh'

  if [[ -z "$INTERACTIVE" ]]; then
    info -- 'Booting the installed system and running post_install.sh.'
    info -- 'Slower than phase one: it installs Xorg, PipeWire and Firefox.'
  else
    info -- 'Interactive. Inside the guest, mount the repository and run:'
    info -- "  mkdir -p /srv/shared && mount -o ro LABEL=${REPO_LABEL} /srv/shared"
    info -- '  /srv/shared/phase-post.sh'
  fi

  # The root filesystem is LUKS2. systemd-cryptsetup reads this credential in
  # the initrd, so the volume opens without anyone typing the passphrase.
  run_vm "$JOURNAL_POST" \
    "--image=${TARGET_IMAGE}" '--image-format=qcow2' \
    "--image-disk-type=${DISK_TYPE}" \
    "--set-credential=cryptsetup.passphrase:${PASSPHRASE}"

  if [[ -z "$INTERACTIVE" ]]; then
    journalctl --file="$JOURNAL_POST" --output=cat --no-pager 2>/dev/null \
      | sed --quiet '/=== assertions.sh/,$p'

    POST_STATUS=$(marker       "$JOURNAL_POST" 'POST')
    POSTASSERT_STATUS=$(marker "$JOURNAL_POST" 'POSTASSERT')

    if [[ -z "$POST_STATUS" ]]; then
      info -w "Inspect: journalctl --file=${JOURNAL_POST}"
      info -e 'The guest never reported back from phase two.'
    fi
    (( POST_STATUS != 0 )) && info -e "post_install.sh failed (exit ${POST_STATUS})."
    [[ "$POSTASSERT_STATUS" != '0' ]] && info -e 'Phase two assertions failed.'

    info -- 'Phase two passed: booted, configured, asserted.'
  fi
fi

#---------------------------------------------- Phase Two: Post-installation ---
