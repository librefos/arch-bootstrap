#!/usr/bin/env bash

# lint.sh - Static checks for the deployment scripts.
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
# Runs shellcheck over every script in the repository, verifies that every
# package name the scripts hand to pacman still exists in the repos, and does
# the same for the dotfiles and PKGBUILD working copies that post_install.sh
# delegates to. Needs no root, no disk, and no emulation.
#
# Usage: ./tests/lint.sh [--strict]
#  (--strict promotes a missing shellcheck from a warning to a failure)

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
readonly REPO_DIR

# The dotfiles and PKGBUILD working copies, the same ones tests/vm.sh stages
# into the guest. They are separate projects that happen to sit here, so their
# findings are reported and not counted: this repository cannot fix them, but
# post_install.sh runs them, so a break there breaks a deployment all the same.
readonly USERLAND_DIR="${ARCH_BOOTSTRAP_USERLAND:-${REPO_DIR}/tmp}"
readonly DOTFILES_DIR="${USERLAND_DIR}/dotfiles"
readonly PKGBUILDS_DIR="${USERLAND_DIR}/pkgbuilds"

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

readonly STRICT="${1:-}"

# Collected rather than fatal, so one run reports every problem it can see
# instead of stopping at the first.
FAILURES=0

#--- Shellcheck ---------------------------------------------------------------

info -s 'Shellcheck'

if ! command -v shellcheck &> /dev/null; then
  if [[ "$STRICT" == '--strict' ]]; then
    info -e 'shellcheck is not installed. Install shellcheck.'
  fi
  info -w 'shellcheck is not installed; skipping. Install shellcheck.'
  info -w 'Re-run with --strict to treat this as a failure.'
else
  # Deliberately globbed rather than listed: a script added to the repository
  # is checked without anyone remembering to add it here. The scratch trees
  # are excluded because tests/vm.sh stages copies of these very scripts into
  # tests/.work, and linting a copy proves nothing twice.
  #
  # tmp/ is excluded by name as well as through USERLAND_DIR. Everything
  # gitignored there belongs to another project, and what this pass covers
  # should not change just because someone pointed USERLAND_DIR elsewhere.
  mapfile -t SCRIPTS < <(
    find "$REPO_DIR" -name '*.sh' -type f \
         -not -path '*/.git/*' \
         -not -path "${REPO_DIR}/tests/.work/*" \
         -not -path "${REPO_DIR}/tests/.cache/*" \
         -not -path "${REPO_DIR}/tmp/*" \
         -not -path "${USERLAND_DIR}/*" \
    | sort
  )
  readonly SCRIPTS

  info -- "Checking ${#SCRIPTS[@]} scripts..."
  if shellcheck --shell=bash --external-sources "${SCRIPTS[@]}"; then
    info -- 'shellcheck: clean.'
  else
    info -w 'shellcheck reported findings.'
    (( ++FAILURES ))
  fi

  # The delegated scripts, checked separately and advisory only. Folding them
  # into the pass above is what happens by accident, and it means a warning in
  # a repository this one does not own fails this one's lint.
  USERLAND_SCRIPTS=()
  if [[ -f "${DOTFILES_DIR}/deploy.sh" ]]; then
    USERLAND_SCRIPTS+=( "${DOTFILES_DIR}/deploy.sh" )
  fi
  if [[ -f "${PKGBUILDS_DIR}/install.sh" ]]; then
    USERLAND_SCRIPTS+=( "${PKGBUILDS_DIR}/install.sh" )
  fi
  readonly USERLAND_SCRIPTS

  if (( ${#USERLAND_SCRIPTS[@]} > 0 )); then
    info -- "Checking ${#USERLAND_SCRIPTS[@]} delegated scripts (advisory)..."
    if shellcheck --shell=bash --external-sources "${USERLAND_SCRIPTS[@]}"; then
      info -- 'shellcheck: delegated scripts clean.'
    else
      info -w 'shellcheck findings in the delegated scripts. Not counted:'
      info -w 'they belong to the dotfiles and pkgbuilds repositories.'
    fi
  fi
fi

#--------------------------------------------------------------- Shellcheck ---
#--- Package Existence --------------------------------------------------------

info -s 'Package Existence'

if ! command -v pacman &> /dev/null; then
  info -e 'pacman is not available; cannot verify package names.'
fi

# A stale sync database will happily resolve a package that upstream dropped
# last week, which is precisely the failure this check exists to catch.
DB_AGE_DAYS=$(( ( $(date +%s) - $(stat --format=%Y /var/lib/pacman/sync/extra.db) ) / 86400 ))
readonly DB_AGE_DAYS
if (( DB_AGE_DAYS > 7 )); then
  info -w "Sync database is ${DB_AGE_DAYS} days old. Run 'pacman -Sy' for a"
  info -w 'meaningful result; this check is only as current as the database.'
fi

# Map every FOO_PKG / FOO_PKGS assignment to its value. Both profiles are
# collected, so a single run covers the desktop and the laptop at once.
declare -A PKG_VARS=()
while IFS='=' read -r name value; do
  PKG_VARS["$name"]+=" $value"
done < <(
  grep --no-filename --only-matching --extended-regexp \
       "^[[:space:]]*(readonly[[:space:]]+)?[A-Z_]*(PKG|PKGS)='[^']*'" \
       "$REPO_DIR"/*.sh \
  | sed --regexp-extended --expression="s/^[[:space:]]*(readonly[[:space:]]+)?//" \
                          --expression="s/'//g"
)

if (( ${#PKG_VARS[@]} == 0 )); then
  info -e 'Found no package variables. The extraction below is out of date.'
fi
info -- "Resolved ${#PKG_VARS[@]} package variables: ${!PKG_VARS[*]}"

# Join backslash continuations, then keep the lines that install packages.
# --clean is excluded because it takes no package arguments, and --remove and
# --query are excluded because they operate on what is already installed.
# Whole-line comments are dropped first: prose that merely mentions pacstrap or
# pacman otherwise parses as an invocation, and every word after the command
# name is then checked as a package. A comment explaining an install line is
# the most natural place in this repository for that to happen.
mapfile -t INSTALL_LINES < <(
  sed --expression=':a' --expression='/\\$/N; s/\\\n//; ta' "$REPO_DIR"/*.sh \
  | grep --invert-match --extended-regexp '^[[:space:]]*#' \
  | grep --extended-regexp '(^|[[:space:]])(pacstrap|pacman[[:space:]]+(--sync|-S))' \
  | grep --invert-match -- '--clean'
)

if (( ${#INSTALL_LINES[@]} == 0 )); then
  info -e 'Found no pacman/pacstrap invocations. The extraction is out of date.'
fi
info -- "Found ${#INSTALL_LINES[@]} install invocations."

declare -A SEEN=()
PACKAGES=()
UNRESOLVED=()

for line in "${INSTALL_LINES[@]}"; do
  # shellcheck disable=SC2086
  for token in $line; do
    case "$token" in
      # The commands themselves, their flags, and pacstrap's target root.
      pacstrap|pacman|/mnt|-*) continue ;;
    esac

    # Expand a variable reference against the map built above. An unknown one
    # is fatal rather than skipped: silently ignoring it would let a whole
    # profile's packages go unchecked without anyone noticing.
    if [[ "$token" == '$'* ]]; then
      var_name="${token#'$'}"
      var_name="${var_name#\{}"
      var_name="${var_name%\}}"

      if [[ -z "${PKG_VARS[$var_name]+set}" ]]; then
        UNRESOLVED+=( "$token" )
        continue
      fi
      # shellcheck disable=SC2206
      expanded=( ${PKG_VARS[$var_name]} )
    else
      expanded=( "$token" )
    fi

    for pkg in "${expanded[@]}"; do
      [[ -z "$pkg" ]] && continue
      if [[ -z "${SEEN[$pkg]+set}" ]]; then
        SEEN["$pkg"]=1
        PACKAGES+=( "$pkg" )
      fi
    done
  done
done

if (( ${#UNRESOLVED[@]} > 0 )); then
  info -w "Unresolved variables in install lines: ${UNRESOLVED[*]}"
  info -e 'Add them to the extraction, or their packages go unchecked.'
fi

info -- "Checking ${#PACKAGES[@]} unique package names..."

# One batch call rather than a loop: pacman names every missing package on
# stderr and exits non-zero, which is exactly the report wanted.
if MISSING=$(pacman --sync --info "${PACKAGES[@]}" 2>&1 >/dev/null); then
  info -- 'All package names resolve.'
else
  printf '%s\n' "$MISSING" >&2
  info -w 'One or more package names no longer exist in the repositories.'
  (( ++FAILURES ))
fi

#-------------------------------------------------------- Package Existence ---
#--- Userland Repositories ----------------------------------------------------

info -s 'Userland Repositories'

# post_install.sh hands the last two steps of a deployment to these: deploy.sh
# stows the dotfiles, and the pkgbuilds install.sh compiles the custom
# packages. Neither lives in this repository, and both can rot independently
# of it, so what is checked here is the contract between them and
# post_install.sh, plus the same package-name rot the section above catches.
if [[ ! -d "$USERLAND_DIR" ]]; then
  info -w "No working copies at ${USERLAND_DIR}; skipping."
  info -w 'Clone dotfiles and pkgbuilds there, or set ARCH_BOOTSTRAP_USERLAND,'
  info -w 'to check them and to let tests/vm.sh install from them.'
else
  # The exact paths post_install.sh probes before it will offer a selection.
  # A rename upstream turns both of its selections into a silent skip, and a
  # deployment that silently installs none of your dotfiles looks like success.
  for entry in "${DOTFILES_DIR}/deploy.sh" "${PKGBUILDS_DIR}/install.sh"; do
    if [[ -f "$entry" ]]; then
      info -- "Found ${entry#"${USERLAND_DIR}/"}."
    else
      info -w "Missing ${entry}. post_install.sh would skip that selection."
      (( ++FAILURES ))
    fi
  done

  # --list is the other half of that contract: post_install.sh calls it to
  # build the prompt, and treats empty output as nothing to offer. Cheap to
  # run, and it exercises each script's argument handling for free.
  if [[ -f "${DOTFILES_DIR}/deploy.sh" ]]; then
    if ! command -v stow &> /dev/null; then
      info -w 'stow is not installed; deploy.sh --list would refuse to run.'
    elif LIST=$(bash "${DOTFILES_DIR}/deploy.sh" --list 2>/dev/null) \
         && [[ -n "$LIST" ]]; then
      info -- "deploy.sh offers: ${LIST}"
    else
      info -w 'deploy.sh --list produced nothing.'
      (( ++FAILURES ))
    fi
  fi

  if [[ -f "${PKGBUILDS_DIR}/install.sh" ]]; then
    if LIST=$(bash "${PKGBUILDS_DIR}/install.sh" --list 2>/dev/null) \
       && [[ -n "$LIST" ]]; then
      info -- "install.sh offers: ${LIST}"
    else
      info -w 'pkgbuilds install.sh --list produced nothing.'
      (( ++FAILURES ))
    fi
  fi

  # Every dependency the custom packages declare, checked the same way the
  # scripts' own package lists are. makepkg --syncdeps resolves these at build
  # time, so a name that no longer exists fails the build inside the VM, an
  # hour into a run, rather than here in a second.
  #
  # Scraped rather than sourced: a lint tool that executes its input to find
  # out what that input needs has a much worse failure mode than one that
  # cannot parse an exotic array. Note the paren-balance walk -- a sed range
  # cannot do this, because /start/,/end/ never ends on the line it starts on,
  # so a single-line depends=() would swallow whatever array came next.
  if compgen -G "${PKGBUILDS_DIR}/*/PKGBUILD" > /dev/null; then
    mapfile -t DEPS < <(
      awk 'FNR == 1                  { collecting = 0 }
           /^(make)?depends=\(/       { collecting = 1 }
           collecting                { print; if (/\)/) collecting = 0 }' \
          "${PKGBUILDS_DIR}"/*/PKGBUILD \
      | grep --only-matching --extended-regexp "'[^']+'" \
      | tr --delete "'" \
      | sed --regexp-extended 's/[<>=].*$//' \
      | sort --unique
    )

    if (( ${#DEPS[@]} == 0 )); then
      info -w 'No PKGBUILD dependencies found. The extraction is out of date.'
      (( ++FAILURES ))
    else
      info -- "Checking ${#DEPS[@]} PKGBUILD dependencies..."
      if MISSING=$(pacman --sync --info "${DEPS[@]}" 2>&1 >/dev/null); then
        info -- 'All PKGBUILD dependencies resolve.'
      else
        printf '%s\n' "$MISSING" >&2
        info -w 'A custom package depends on something that no longer exists.'
        (( ++FAILURES ))
      fi
    fi
  else
    info -w "No PKGBUILDs under ${PKGBUILDS_DIR}."
  fi
fi

#---------------------------------------------------- Userland Repositories ---
#--- Summary ------------------------------------------------------------------

info -s 'Summary'

if (( FAILURES > 0 )); then
  info -e "$FAILURES check(s) failed."
fi

info -- 'All checks passed.'

#------------------------------------------------------------------ Summary ---
