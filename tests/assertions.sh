#!/usr/bin/env bash

# assertions.sh - Post-condition checks for an installed system.
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
# The load-bearing half of the test suite. The old VM orchestrator booted a
# machine and asked a human to look at it; nothing here asks anyone to look at
# anything. Every claim install.sh makes about the system it produces is
# written down below as something a machine can check.
#
# Deliberately sourceable: the same assertions run against a tree mounted by
# tests/loop.sh, against a VM, or against a real machine, so a claim only ever
# has to be written once.
#
# Usage: ./tests/assertions.sh <root> <profile> [dotfiles] [pkgbuilds]
#  (e.g. ./tests/assertions.sh /mnt amd, or ./tests/assertions.sh / amd)
#
# The trailing two are the selections post_install.sh was given, so the checks
# for the dotfiles and PKGBUILD repositories know what to look for. They
# default to ARCH_BOOTSTRAP_DOTFILE_SELECTION and
# ARCH_BOOTSTRAP_PKGBUILD_SELECTION, which is how tests/vm.sh passes them: the
# run and the checks then read the same string and cannot drift apart.

set -uo pipefail

#--- Assertion Primitives -----------------------------------------------------

PASSED=0
FAILED=0
PENDING=0
SKIPPED=0

# Set while running the checks for changes that PLAN.amd and PLAN.intel
# describe but that have not landed yet. Their failures are reported and then
# forgiven, so a clean tree stays green and the pending list doubles as a
# progress bar for those two plans.
SOFT=''

ok()
{
  printf '  %b[PASS]%b %s\n' "$(tput setaf 2)" "$(tput sgr0)" "$1"
  (( ++PASSED ))
}

no()
{
  if [[ -n "$SOFT" ]]; then
    printf '  %b[PEND]%b %s\n' "$(tput setaf 3)" "$(tput sgr0)" "$1"
    (( ++PENDING ))
  else
    printf '  %b[FAIL]%b %s\n' "$(tput setaf 1)" "$(tput sgr0)" "$1"
    (( ++FAILED ))
  fi
}

nb()
{
  printf '  %b[SKIP]%b %s\n' "$(tput setaf 4)" "$(tput sgr0)" "$1"
  (( ++SKIPPED ))
}

# check <description> <command...>
check()
{
  local description="$1"; shift
  if "$@" &> /dev/null; then ok "$description"; else no "$description"; fi
}

# has <description> <file> <extended-regex>
has()
{
  local description="$1" file="$2" pattern="$3"

  if [[ ! -e "$file" ]]; then
    no "$description (no such file: $file)"
    return
  fi
  if grep --quiet --extended-regexp -- "$pattern" "$file"; then
    ok "$description"
  else
    no "$description"
  fi
}

# lacks <description> <file> <extended-regex>
lacks()
{
  local description="$1" file="$2" pattern="$3"

  if [[ ! -e "$file" ]]; then ok "$description"; return; fi
  if grep --quiet --extended-regexp -- "$pattern" "$file"; then
    no "$description"
  else
    ok "$description"
  fi
}

# readable <path>
# A non-root caller cannot see inside the ESP (dmask=0077) or /root. Without
# this, such a run reports a wall of failures that say nothing about the tree.
readable()
{
  [[ -r "$1" ]] || return 1
  [[ ! -d "$1" || -x "$1" ]] || return 1
  return 0
}

# rotational <root>
# A virtual disk is never rotational, so Btrfs autodetects 'ssd' in a VM
# whatever install.sh passes. The laptop's mount-option claims can therefore
# only be settled on the laptop, exactly as PLAN.intel says.
rotational()
{
  local src
  src=$(findmnt --noheadings --output SOURCE --target "$1" 2>/dev/null | head -1)
  src=${src%%\[*}
  [[ "$(lsblk --noheadings --output ROTA "$src" 2>/dev/null | head -1 | tr -d ' ')" == '1' ]]
}

# mounted <description> <mountpoint> <option-substring>
mounted()
{
  local description="$1" target="$2" option="$3" opts

  opts=$(findmnt --noheadings --output OPTIONS --target "$target" 2>/dev/null | head -1)
  if [[ -z "$opts" ]]; then
    no "$description (nothing mounted at $target)"
    return
  fi
  if [[ "$opts" == *"$option"* ]]; then
    ok "$description"
  else
    no "$description (got: $opts)"
  fi
}

# enabled <root> <unit>
# Reads the symlink farm directly rather than calling systemctl, so the check
# works against an unbooted tree exactly as it does against a live system.
enabled()
{
  local root="$1" unit="$2"

  if compgen -G "${root}/etc/systemd/system/*.wants/${unit}" > /dev/null \
  || compgen -G "${root}/etc/systemd/system/${unit}"          > /dev/null; then
    ok "$unit is enabled"
  else
    no "$unit is enabled"
  fi
}

# installed <root> <package>
# pacman names each database directory <name>-<pkgver>-<pkgrel>, so the name
# has to be recovered by stripping the last two fields rather than by matching
# a prefix: nothing stops one package's name from being the start of another's.
#
# Matching <name>-[0-9]* instead looks right and is wrong for exactly the
# packages this repository builds. A -git PKGBUILD versions itself as
# r<count>.<hash>, which starts with a letter, so that glob reports every
# custom package as missing however well it built.
installed()
{
  local root="$1" package="$2" dir base

  for dir in "${root%/}"/var/lib/pacman/local/"${package}"-*/; do
    [[ -d "$dir" ]] || continue
    base=$(basename "$dir")
    if [[ "${base%-*-*}" == "$package" ]]; then
      ok "package $package is installed"
      return
    fi
  done

  no "package $package is installed"
}

# absent <root> <package>
# The mirror of installed(). Needed because a positive check cannot catch a
# metapackage regression: linux-firmware depends on linux-firmware-intel, so
# "intel firmware is present" stays true even when the whole ~407 MiB vendor
# set comes back. Only naming the package that must not be there detects it.
absent()
{
  local root="$1" package="$2" dir base

  for dir in "${root%/}"/var/lib/pacman/local/"${package}"-*/; do
    [[ -d "$dir" ]] || continue
    base=$(basename "$dir")
    if [[ "${base%-*-*}" == "$package" ]]; then
      no "package $package is absent"
      return
    fi
  done

  ok "package $package is absent"
}

# stowed <repo> <home> <package>
# Every regular file in a stow package should show up in the home directory as
# a symlink pointing back at the repository. deploy.sh passes --no-folding, so
# directories are real directories and this really is every file, not one
# top-level link standing in for the lot.
#
# Derived from the repository rather than from a list written here, so a
# dotfile added upstream is checked the day it lands.
stowed()
{
  local repo="$1" home="$2" package="$3"
  local dir="${repo}/${package}"
  local file relative target total=0 missing=0

  if [[ ! -d "$dir" ]]; then
    no "dotfile package ${package} exists in the repository"
    return
  fi

  while IFS= read -r -d '' file; do
    (( ++total ))
    relative="${file#"${dir}/"}"
    target="${home}/${relative}"

    if [[ ! -L "$target" ]] \
    || [[ "$(readlink -f "$target")" != "$(readlink -f "$file")" ]]; then
      (( ++missing ))
    fi
  done < <(find "$dir" -type f -print0 2>/dev/null)

  if (( total == 0 )); then
    no "dotfile package ${package} has anything to stow"
  elif (( missing == 0 )); then
    ok "dotfile package ${package} is stowed (${total} files)"
  else
    no "dotfile package ${package} is stowed (${missing} of ${total} missing)"
  fi
}

#----------------------------------------------------- Assertion Primitives ---
#--- Baseline: What install.sh Promises Today ---------------------------------

# Every claim here is one install.sh already makes. These must pass on a clean
# tree; a failure is a regression, not an unimplemented plan.
suite_baseline()
{
  local root="$1" profile="$2" kms pstate ucode
  local -a firmware

  # Firmware is per-profile. Both machines carry realtek, for different
  # reasons: amd for its analog audio, intel for the onboard RTL8168 NIC.
  # What neither may carry is the linux-firmware metapackage, ~407 MiB of
  # vendor blobs for hardware that is not there.
  case "$profile" in
    amd)   kms='amdgpu'; pstate='amd_pstate=active';   ucode='amd-ucode'
           firmware=( linux-firmware-amdgpu linux-firmware-realtek ) ;;
    intel) kms='i915';   pstate='intel_pstate=active'; ucode='intel-ucode'
           firmware=( linux-firmware-intel linux-firmware-realtek ) ;;
    *)     printf 'unknown profile: %s\n' "$profile" >&2; return 1 ;;
  esac

  printf '\n%b== Btrfs layout ==%b\n' "$(tput bold)" "$(tput sgr0)"
  # The subvolumes are mounted at their targets rather than visible as paths
  # under the tree, so ask the filesystem for its list instead of stat()ing.
  local subvols subvol expected
  expected=( '@' '@home' '@cache' '@log' )
  # The swapfile needs a subvolume of its own that snapshots never touch.
  [[ "$profile" == 'intel' ]] && expected+=( '@swap' )

  if ! subvols=$(btrfs subvolume list "$root" 2>/dev/null); then
    nb 'btrfs subvolumes (listing them needs root)'
  else
    for subvol in "${expected[@]}"; do
      if grep --quiet --extended-regexp "path ${subvol}\$" <<< "$subvols"; then
        ok "subvolume $subvol exists"
      else
        no "subvolume $subvol exists"
      fi
    done
  fi

  printf '\n%b== Mount options ==%b\n' "$(tput bold)" "$(tput sgr0)"
  local opt
  if [[ "$profile" == 'amd' ]]; then
    for opt in 'noatime' 'compress=zstd' 'ssd' 'discard=async' 'space_cache=v2'; do
      mounted "root carries $opt" "$root" "$opt"
    done
  else
    for opt in 'noatime' 'compress=zstd:1' 'autodefrag' 'commit=120'; do
      mounted "root carries $opt" "$root" "$opt"
    done

    # Only the real laptop can answer these; see rotational() above.
    if rotational "$root"; then
      check 'root does not claim to be an SSD' \
        bash -c "! findmnt --noheadings --output OPTIONS --target '$root' \
                 | head -1 | grep -qw ssd"
      check 'root does not discard' \
        bash -c "! findmnt --noheadings --output OPTIONS --target '$root' \
                 | head -1 | grep -q discard"
    else
      nb 'absence of ssd/discard (this disk is not rotational; VM or SSD)'
    fi
  fi
  # Anchored, because a bare 'subvol=/@' also matches 'subvol=/@home'.
  check 'root is the @ subvolume' \
    bash -c "findmnt --noheadings --output OPTIONS --target '$root' \
             | head -1 | grep -qE 'subvol=/@(,|\$)'"
  mounted 'home is a separate subvolume' "${root}/home"                  'subvol=/@home'
  mounted 'pacman cache is a separate subvolume' \
          "${root}/var/cache/pacman/pkg" 'subvol=/@cache'
  mounted 'log is a separate subvolume' "${root}/var/log"                'subvol=/@log'
  mounted 'ESP is root-only (fmask)' "${root}/boot" 'fmask=0077'
  mounted 'ESP is root-only (dmask)' "${root}/boot" 'dmask=0077'

  if [[ "$profile" == 'intel' ]]; then
    printf '\n%b== Hibernation swapfile ==%b\n' "$(tput bold)" "$(tput sgr0)"
    mounted 'swap subvolume is mounted' "${root}/swap" 'subvol=/@swap'
    check 'swapfile exists' test -f "${root}/swap/swapfile"
    # A swapfile that is not NOCOW is rejected by the kernel outright.
    check 'swapfile is NOCOW' \
      bash -c "lsattr '${root}/swap/swapfile' 2>/dev/null | cut -c1-20 | grep -q C"
    has 'fstab activates the swapfile' "${root}/etc/fstab" '/swap/swapfile.*swap'
  fi

  printf '\n%b== Locale and identity ==%b\n' "$(tput bold)" "$(tput sgr0)"
  has 'hostname is archlinux'   "${root}/etc/hostname"      '^archlinux$'
  has 'LANG is en_US.UTF-8'     "${root}/etc/locale.conf"   '^LANG=en_US.UTF-8$'
  has 'console keymap is set'   "${root}/etc/vconsole.conf" '^KEYMAP=us$'
  has 'console font is set'     "${root}/etc/vconsole.conf" '^FONT=Lat2-Terminus16$'
  has 'en_US.UTF-8 is generated' "${root}/etc/locale.gen"   '^en_US.UTF-8'
  check 'timezone points at Sao_Paulo' \
    bash -c "readlink '${root}/etc/localtime' | grep -q 'America/Sao_Paulo'"
  check 'resolv.conf points at the stub resolver' \
    bash -c "readlink '${root}/etc/resolv.conf' | grep -q 'stub-resolv.conf'"

  printf '\n%b== initramfs and UKI ==%b\n' "$(tput bold)" "$(tput sgr0)"
  has "MODULES carries $kms and btrfs" \
      "${root}/etc/mkinitcpio.conf" "^MODULES=\($kms btrfs\)"
  has 'HOOKS use sd-encrypt, not encrypt' \
      "${root}/etc/mkinitcpio.conf" '^HOOKS=\(.*sd-encrypt'
  has 'HOOKS use the systemd initramfs' \
      "${root}/etc/mkinitcpio.conf" '^HOOKS=\(base systemd'
  lacks 'HOOKS do not carry the udev hook' \
      "${root}/etc/mkinitcpio.conf" '^HOOKS=\(.*[( ]udev[ )]'
  has 'preset builds a UKI, not a bare initramfs' \
      "${root}/etc/mkinitcpio.d/linux.preset" '^default_uki='
  if readable "${root}/boot"; then
    check 'the UKI was actually built' \
      test -f "${root}/boot/EFI/Linux/arch-linux.efi"
    check 'the fallback UKI was actually built' \
      test -f "${root}/boot/EFI/Linux/arch-linux-fallback.efi"
  else
    nb 'UKI images (the ESP is root-only; re-run as root)'
  fi

  printf '\n%b== Kernel command line ==%b\n' "$(tput bold)" "$(tput sgr0)"
  local cmdline="${root}/etc/cmdline.d/root.conf"
  has 'names the LUKS volume'      "$cmdline" 'rd\.luks\.name=[0-9a-f-]{36}=cryptroot'
  has 'asks systemd to try the TPM' "$cmdline" 'rd\.luks\.options=tpm2-device=auto'
  has 'root is the mapped device'  "$cmdline" 'root=/dev/mapper/cryptroot'
  has 'root is mounted read-write' "$cmdline" '(^| )rw( |$)'
  has 'root is the @ subvolume'    "$cmdline" 'rootflags=subvol=@'
  has "carries $pstate"            "$cmdline" "$pstate"
  # Shared: Arch defaults zswap on, which quietly starves zram.
  has 'disables zswap'             "$cmdline" 'zswap\.enabled=0'
  if [[ "$profile" == 'intel' ]]; then
    has 'disables the watchdog'    "$cmdline" 'nowatchdog'
    has 'enables panel self refresh' "$cmdline" 'i915\.enable_psr=1'
  fi

  printf '\n%b== Bootloader ==%b\n' "$(tput bold)" "$(tput sgr0)"
  if readable "${root}/boot"; then
    check 'systemd-boot is installed on the ESP' \
      test -f "${root}/boot/EFI/systemd/systemd-bootx64.efi"
    has 'loader defaults to the UKI' \
        "${root}/boot/loader/loader.conf" '^default arch-linux.efi$'
    has 'loader editor is disabled' \
        "${root}/boot/loader/loader.conf" '^editor no$'
  else
    nb 'bootloader (the ESP is root-only; re-run as root)'
  fi

  printf '\n%b== Packages ==%b\n' "$(tput bold)" "$(tput sgr0)"
  local package
  for package in base linux "$ucode" btrfs-progs cryptsetup tpm2-tss sbctl \
                 systemd-ukify "${firmware[@]}"; do
    installed "$root" "$package"
  done

  # Nothing should ever pull the catch-all firmware set. On intel that is the
  # regression this profile actually had; on amd it would be just as wrong.
  absent "$root" 'linux-firmware'

  printf '\n%b== Services and handoff ==%b\n' "$(tput bold)" "$(tput sgr0)"
  enabled "$root" 'systemd-resolved.service'
  if [[ "$profile" == 'amd' ]]; then
    enabled "$root" 'systemd-networkd.service'
    has 'wired network unit requests DHCP' \
        "${root}/etc/systemd/network/20-wired.network" '^DHCP=yes$'
  else
    enabled "$root" 'NetworkManager.service'
    installed "$root" 'networkmanager'
  fi

  printf '\n%b== Encryption ==%b\n' "$(tput bold)" "$(tput sgr0)"
  # fstab must name the mapped device; a bare partition UUID here would mean
  # the root filesystem was never actually encrypted.
  has 'fstab mounts the mapped device' "${root}/etc/fstab" '/dev/mapper/cryptroot'
  local subvol_count
  subvol_count=$(grep --count 'subvol=/@' "${root}/etc/fstab" 2>/dev/null || echo 0)
  if (( subvol_count >= 4 )); then
    ok "fstab carries all four subvolumes ($subvol_count entries)"
  else
    no "fstab carries all four subvolumes (found $subvol_count)"
  fi
}

# The handoff artifacts install.sh leaves for post_install.sh. Valid only on a
# tree that has just been installed: post_install.sh consumes .deploy_profile,
# and neither file is expected to survive the life of the machine. Checking a
# long-lived system for them reports a failure that is really just time passing.
suite_fresh()
{
  local root="$1" profile="$2"

  printf '\n%b== Handoff to post_install.sh ==%b\n' "$(tput bold)" "$(tput sgr0)"
  if readable "${root}/root"; then
    has "profile handoff records $profile" \
        "${root}/root/.deploy_profile" "^${profile}$"
    check 'post_install.sh is staged and executable' \
      test -x "${root}/root/post_install.sh"
  else
    nb 'profile handoff (/root is unreadable; re-run as root)'
  fi
}

#--------------------------------- Baseline: What install.sh Promises Today ---
#--- Phase Two: What post_install.sh Produces ---------------------------------

# What post_install.sh produces. These cannot be checked against a phase-1 VM
# tree, because at that point only install.sh has run: the files below simply
# do not exist yet. They are meaningful against a machine that has completed
# both phases, which is why the entry point runs them only for a live root.
#
# Reported as PEND rather than FAIL: a machine deployed with the older scripts
# is not broken, it is out of date. The list empties once it is redeployed.
suite_post()
{
  local root="$1" profile="$2" governor epp

  SOFT='yes'

  if [[ "$profile" == 'amd' ]]; then
    governor='performance'; epp=''
  else
    governor='powersave';   epp='balance_power'
  fi

  printf '\n%b== CPU scaling ==%b\n' "$(tput bold)" "$(tput sgr0)"
  # cpupower ships this file itself with every option commented out, so its
  # existence proves nothing; only an uncommented GOVERNOR= does. The unit
  # reads cpupower-service.conf, never /etc/default/cpupower.
  has "governor is ${governor}, where cpupower.service reads it" \
      "${root}/etc/default/cpupower-service.conf" "^GOVERNOR=\"?${governor}"
  check 'the ineffective /etc/default/cpupower is gone' \
    bash -c "! test -f '${root}/etc/default/cpupower'"
  if [[ -n "$epp" ]]; then
    has "energy preference is ${epp}" \
        "${root}/etc/default/cpupower-service.conf" "^EPP=\"?${epp}"
  fi

  printf '\n%b== Storage policy ==%b\n' "$(tput bold)" "$(tput sgr0)"
  # Attribute-matched, so it is a harmless no-op on the desktop's NVMe.
  check 'io scheduler policy is explicit' \
    test -f "${root}/etc/udev/rules.d/60-ioschedulers.rules"

  if [[ "$profile" == 'amd' ]]; then
    printf '\n%b== Desktop only ==%b\n' "$(tput bold)" "$(tput sgr0)"
    # The NM610 PRO is DRAM-less; keep its translation layer supplied.
    enabled "$root" 'fstrim.timer'
  else
    printf '\n%b== Laptop only ==%b\n' "$(tput bold)" "$(tput sgr0)"
    check 'wifi runtime power saving' \
      test -f "${root}/etc/modprobe.d/iwlwifi.conf"
    check 'audio runtime power saving' \
      test -f "${root}/etc/modprobe.d/audio_powersave.conf"
    check 'PCI runtime power management' \
      test -f "${root}/etc/udev/rules.d/50-pci_pm.rules"
    has 'dirty writeback is relaxed' \
        "${root}/etc/sysctl.d/99-laptop.conf" '^vm\.dirty_writeback_centisecs'
    has 'zram is capped by resident limit' \
        "${root}/etc/systemd/zram-generator.conf" '^zram-resident-limit'
    has 'lid closes to suspend-then-hibernate' \
        "${root}/etc/systemd/logind.conf.d/laptop.conf" '^HandleLidSwitch=suspend-then-hibernate'
    # Regression guard. logind infers idleness for a tty session from the
    # atime of its TTY, which X never touches, so any sleeping IdleAction
    # here puts the machine away on a fixed interval while it is in use.
    lacks 'no idle action logind cannot measure' \
        "${root}/etc/systemd/logind.conf.d/laptop.conf" \
        '^IdleAction=(suspend|hibernate|hybrid-sleep|poweroff|reboot|halt|kexec)'
    enabled "$root" 'earlyoom.service'
    installed "$root" 'brightnessctl'
    check 'btrfs scrub waits for AC' \
      test -f "${root}/etc/systemd/system/btrfs-scrub.service.d/ac-only.conf"
  fi

  SOFT=''
}

#------------------------------ What post_install.sh Produces (Phase Two) ---
#--- Phase Two: The Userland Repositories -------------------------------------

# What the two delegated scripts leave behind: deploy.sh's symlinks and the
# packages the pkgbuilds install.sh compiled. Until tests/vm.sh could stage
# the working copies, unattended mode selected nothing, so this whole half of
# post_install.sh -- stow's conflict handling, a real makepkg build, and the
# two temporary sudoers rules that exist to let them work -- ran in no test at
# all. It is also the half most likely to break, because it is the half that
# depends on repositories that change independently of this one.
#
# An empty selection reports SKIP, never PASS: nothing was asked for, so
# nothing was proven.
suite_userland()
{
  local root="$1" user="$2" dotfiles="$3" pkgbuilds="$4"
  local home="${root%/}/home/${user}"
  local dir name pkg
  local packages=()

  printf '\n%b== Dotfiles ==%b\n' "$(tput bold)" "$(tput sgr0)"

  if [[ -z "$dotfiles" ]]; then
    nb 'dotfile deployment (no selection given)'
  elif [[ ! -d "${home}/dotfiles" ]]; then
    no "dotfiles repository was fetched to ${home}/dotfiles"
  else
    if [[ "${dotfiles,,}" == 'all' ]]; then
      for dir in "${home}/dotfiles"/*/; do
        name=$(basename "$dir")
        # deploy.sh never stows this one: it is the source of the system-wide
        # policy file, installed with sudo rather than symlinked.
        [[ "$name" == 'firefox-policy' ]] && continue
        packages+=( "$name" )
      done
    else
      IFS=',' read -ra packages <<< "${dotfiles// /}"
    fi

    for pkg in "${packages[@]}"; do
      stowed "${home}/dotfiles" "$home" "$pkg"
    done

    # deploy.sh's only system-wide side effect, and the entire reason
    # post_install.sh grants a temporary passwordless rule for /usr/bin/install.
    if [[ " ${packages[*]} " == *' firefox '* ]]; then
      check 'firefox policies are installed system-wide' \
        test -f "${root%/}/etc/firefox/policies/policies.json"
    fi
  fi

  printf '\n%b== Custom packages ==%b\n' "$(tput bold)" "$(tput sgr0)"

  if [[ -z "$pkgbuilds" ]]; then
    nb 'custom package builds (no selection given)'
  elif [[ ! -d "${home}/pkgbuilds" ]]; then
    no "pkgbuilds repository was fetched to ${home}/pkgbuilds"
  else
    packages=()
    if [[ "${pkgbuilds,,}" == 'all' ]]; then
      for dir in "${home}/pkgbuilds"/*/; do
        [[ -f "${dir}/PKGBUILD" ]] && packages+=( "$(basename "$dir")" )
      done
    else
      IFS=',' read -ra packages <<< "${pkgbuilds// /}"
    fi

    for pkg in "${packages[@]}"; do
      installed "$root" "$pkg"
    done

    # post_install.sh rewrites PKGDEST in makepkg.conf. Nothing else notices if
    # that edit stops taking effect, because a build still succeeds; the
    # packages just land in the build directory instead.
    check 'built packages landed in PKGDEST' \
      bash -c "compgen -G '${root%/}/var/cache/makepkg/packages/*.pkg.tar.*' > /dev/null"
  fi

  printf '\n%b== Temporary privileges ==%b\n' "$(tput bold)" "$(tput sgr0)"

  # Both rules are granted so that deploy.sh and makepkg can call sudo from a
  # non-interactive 'su' session, and both are revoked immediately afterwards.
  # A rule left behind is a passwordless /usr/bin/install or /usr/bin/pacman
  # for the user, which is root by another name. Checked unconditionally: the
  # dangerous case is exactly the one where the run failed partway.
  check 'the temporary dotfiles sudoers rule is gone' \
    bash -c "! test -e '${root%/}/etc/sudoers.d/zz-dotfiles-install'"
  check 'the temporary makepkg sudoers rule is gone' \
    bash -c "! test -e '${root%/}/etc/sudoers.d/zz-makepkg-pacman'"
}

#------------------------------- Phase Two: The Userland Repositories ---
#--- Live-only Checks ---------------------------------------------------------

# Claims that cannot be read off a mounted tree because they only exist once
# the kernel in question is running. The loop harness skips these; a VM or the
# real machine runs them.
suite_live()
{
  local profile="$1"

  printf '\n%b== Running kernel ==%b\n' "$(tput bold)" "$(tput sgr0)"
  check 'zram is active' bash -c "swapon --show=NAME --noheadings | grep -q zram"

  # Pending, not broken: these are the live half of PLAN.amd findings 2 and 3,
  # and they are exactly the two bugs no amount of eyeballing a serial log
  # would ever have surfaced. Both install cleanly and boot cleanly.
  SOFT='yes'

  has 'booted cmdline disables zswap' /proc/cmdline 'zswap\.enabled=0'
  check 'zswap is actually off' \
    bash -c "grep -qx N /sys/module/zswap/parameters/enabled"

  # A virtual CPU exposes no cpufreq policy at all, so there is nothing to
  # read here in a VM. The claim is real but only the hardware can answer it.
  local governor='performance'
  [[ "$profile" == 'intel' ]] && governor='powersave'
  if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    check "live governor is $governor" \
      bash -c "grep -qx '$governor' /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  else
    nb 'live CPU governor (no cpufreq driver; virtual CPU)'
  fi

  SOFT=''
}

#--------------------------------------------------------- Live-only Checks ---
#--- Reporting ----------------------------------------------------------------

report()
{
  printf '\n%b== Summary ==%b\n' "$(tput bold)" "$(tput sgr0)"
  printf '  passed  %d\n' "$PASSED"
  printf '  failed  %d\n' "$FAILED"
  printf '  pending %d  (not yet applied to this system)\n' "$PENDING"
  printf '  skipped %d\n' "$SKIPPED"

  (( FAILED == 0 ))
}

#---------------------------------------------------------------- Reporting ---
#--- Entry Point --------------------------------------------------------------

# Only when run directly. When sourced, the caller drives the suites itself.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ROOT="${1:-}"
  PROFILE="${2:-}"

  # The selections default to the environment, which is how tests/vm.sh hands
  # them over; an argument wins, for checking a machine by hand after the fact.
  DOTFILE_SELECTION="${3:-${ARCH_BOOTSTRAP_DOTFILE_SELECTION:-}}"
  PKGBUILD_SELECTION="${4:-${ARCH_BOOTSTRAP_PKGBUILD_SELECTION:-}}"

  # post_install.sh hardcodes the same name; overridable only so this file
  # never has to be edited to check a machine that does not use it.
  TEST_USER="${ARCH_BOOTSTRAP_USER:-librefos}"

  if [[ -z "$ROOT" || -z "$PROFILE" ]]; then
    printf 'Usage: %s ROOT PROFILE [DOTFILES] [PKGBUILDS]\n' "$0" >&2
    printf '  e.g. %s /mnt amd\n' "$0" >&2
    printf '       %s / amd all st-git,dmenu-git\n' "$0" >&2
    exit 1
  fi

  suite_baseline "$ROOT" "$PROFILE"

  # A freshly installed tree still carries the handoff files; a running system
  # has long since consumed them, but can answer the live questions instead.
  if [[ "$ROOT" == '/' ]]; then
    suite_post "$ROOT" "$PROFILE"
    suite_userland "$ROOT" "$TEST_USER" \
      "$DOTFILE_SELECTION" "$PKGBUILD_SELECTION"
    suite_live "$PROFILE"
  else
    # A phase-one tree: install.sh has run, post_install.sh has not.
    suite_fresh "$ROOT" "$PROFILE"
  fi

  report
fi

#-------------------------------------------------------------- Entry Point ---
