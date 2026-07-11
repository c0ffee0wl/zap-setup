#!/bin/bash
#
# Shared utility functions for zap-setup
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# The helpers below were lifted character-for-character from
# /opt/linux-setup/linux-setup.sh — line ranges annotated per block.
# They should evolve in lockstep with that upstream; do not refactor.
# One deliberate exception: apt_get is adapted (sudo env — see its note);
# do not restore the upstream form on a re-sync until upstream adopts the fix.

# Source guard - prevent double-sourcing
[[ -n "${_ZAP_COMMON_SOURCED:-}" ]] && return
_ZAP_COMMON_SOURCED=1

#############################################################################
# Configuration defaults
#############################################################################

# Set by setup.sh's arg parser; default here so prompt_yes_no works even
# when common.sh is sourced before parsing.
: "${FORCE_MODE:=false}"
: "${NO_MODE:=false}"

#############################################################################
# Colors (verbatim from linux-setup.sh:28-37)
#############################################################################

# Colors for output (suppressed when not a TTY or when NO_COLOR is set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

#############################################################################
# Logging (verbatim from linux-setup.sh:131-143)
#############################################################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

#############################################################################
# Backup a file with timestamp, --sudo for root-owned paths
# (verbatim from linux-setup.sh:165-176)
#############################################################################

backup_file() {
    local sudo_cmd=""
    if [ "$1" = "--sudo" ]; then sudo_cmd="sudo"; shift; fi
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.backup.$(date +'%Y-%m-%d_%H-%M-%S')"
        $sudo_cmd cp "$file_path" "$backup_path"
        log "Backed up to: $backup_path"
    fi
}

#############################################################################
# Prompt user with yes/no question (verbatim from linux-setup.sh:285-318)
# Usage: prompt_yes_no "Question?" "Y" (or "N" for default No)
# Returns: 0 for yes, 1 for no
#############################################################################

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

    # In force mode, automatically answer yes
    if [[ "$FORCE_MODE" == "true" ]]; then
        log "Force mode: Auto-answering 'Yes' to: $prompt"
        return 0
    fi

    # In no mode, automatically answer no
    if [[ "$NO_MODE" == "true" ]]; then
        log "No mode: Auto-answering 'No' to: $prompt"
        return 1
    fi

    if [[ "$default" == "Y" ]]; then
        read -p "$prompt (Y/n): " response
        response=${response:-Y}
    else
        read -p "$prompt (y/N): " response
        response=${response:-N}
    fi

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

#############################################################################
# apt-get wrapper (adapted from linux-setup.sh:228-242)
#############################################################################

# apt-get wrapper: in force/no mode run fully non-interactively so debconf
# dialogs, dpkg conffile prompts, and Ubuntu's needrestart menu can't stall
# unattended runs. sudo resets the environment, and setting VAR=val on sudo's
# own command line needs the SETENV sudoers privilege — implied for `ALL`
# rules (stock sudoers), but refused by restricted/managed sudoers (a grant
# narrower than ALL, or NOSETENV) with "you are not allowed to set the
# following environment variables" — so the variables are set by env(1)
# AFTER the privilege boundary instead, which needs no setenv privilege.
# Upstream linux-setup.sh still uses the sudo-command-line form and fails
# the same way under such policies. (A command-whitelist sudoers refuses the
# env form too, but such a policy already breaks this installer's other sudo
# calls — the env form covers the broad-grant-with-setenv-refused case.)
# DPkg::Lock::Timeout makes apt wait for
# the lock instead of aborting when a boot-time apt job (cloud-init,
# apt-daily, unattended-upgrades) still holds it - the classic cloud-init race.
apt_get() {
    if [[ "$FORCE_MODE" == "true" || "$NO_MODE" == "true" ]]; then
        sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
            -o DPkg::Lock::Timeout=300 \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
    else
        sudo apt-get -o DPkg::Lock::Timeout=300 "$@"
    fi
}
