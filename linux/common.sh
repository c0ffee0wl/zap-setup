#!/bin/bash
#
# Shared utility functions for zap-setup
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# The helpers below were lifted character-for-character from
# /opt/linux-setup/linux-setup.sh — line ranges annotated per block.
# They should evolve in lockstep with that upstream; do not refactor.

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
# Colors (verbatim from linux-setup.sh:14-19)
#############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#############################################################################
# Logging (label-only coloring; intentional divergence from linux-setup.sh:106-118,
# which colors the whole line — matches ct-kali-llm/claude-litellm common.sh and
# prevents the green from bleeding into message text)
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
# Backup a file with timestamp (verbatim from linux-setup.sh:131-138)
#############################################################################

backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.backup.$(date +'%Y-%m-%d_%H-%M-%S')"
        cp "$file_path" "$backup_path"
        log "Backed up to: $backup_path"
    fi
}

#############################################################################
# Prompt user with yes/no question (verbatim from linux-setup.sh:143-173)
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
