#!/bin/bash

# Zap Setup Script
# Installs Zap from the latest GitHub .deb and configures it with
# the Terminator "Black on White" theme + Terminator-style keybindings
# (mirroring /opt/linux-setup/linux-setup.sh's effective Terminator set).
#
# Helpers (set/colors/log/arg-parse/backup_file/prompt_yes_no/self-update
# Phase 0) are lifted verbatim from /opt/linux-setup/linux-setup.sh — line
# ranges annotated at each block.

set -eo pipefail

VERSION="0.1"
FORCE_MODE=false
NO_MODE=false

# Colors for output (verbatim from linux-setup.sh:14-19)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Show usage information
show_usage() {
    cat << EOF
Zap Setup Script v${VERSION}
Installs Zap from the latest GitHub .deb and configures it to use a local
LiteLLM proxy + Terminator-style keybindings on a Terminator "Black on White"
theme.

Usage: $0 [OPTIONS]

Options:
  --force, -f, --yes, -y   Non-interactive, answer 'Yes' to all prompts
  --no, -n                 Non-interactive, answer 'No' to all prompts
  --help, -h               Show this help and exit

Interactive mode (default) prompts before overwriting any existing config in
~/.config/zap/ or ~/.local/share/zap/themes/. Backups are timestamped.

EOF
    exit 0
}

# Preserve original args before parsing consumes them via shift.
# Used by self-update (exec "$0") to re-run with the same flags.
# (verbatim from linux-setup.sh:72-74)
ORIGINAL_ARGS=("$@")

# Parse command-line arguments (verbatim subset of linux-setup.sh:77-104)
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f|--yes|-y)
            FORCE_MODE=true
            shift
            ;;
        --no|-n)
            NO_MODE=true
            shift
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Logging (verbatim from linux-setup.sh:106-118)
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Check if running as root (verbatim from linux-setup.sh:121-123)
if [[ $EUID -eq 0 ]]; then
    warn "This script should normally not be run as root. Please run as a regular user with sudo privileges."
fi

# Check if we're on a Debian-based system (verbatim from linux-setup.sh:126-128)
if ! grep -qE "(debian|ID_LIKE.*debian)" /etc/os-release 2>/dev/null; then
    error "This script requires a Debian-based Linux distribution. Detected system is not compatible."
fi

# Backup a file with timestamp (verbatim from linux-setup.sh:131-138)
backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.backup.$(date +'%Y-%m-%d_%H-%M-%S')"
        cp "$file_path" "$backup_path"
        log "Backed up to: $backup_path"
    fi
}

# Prompt user with yes/no question (verbatim from linux-setup.sh:143-173)
# Usage: prompt_yes_no "Question?" "Y" (or "N" for default No)
# Returns: 0 for yes, 1 for no
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

# Zap config paths (XDG, matching desktop ID dev.zap.Zap; the Linux project
# dir name is lowercased to "zap" — see crates/warp_core/src/paths.rs:243-246
# in the upstream source).
CONFIG_DIR="$HOME/.config/zap"
THEMES_DIR="$HOME/.local/share/zap/themes"

# OS-keyring contract — coupled to Zap internals
# (app/src/ai/agent_providers/secrets.rs). The service name is the app ID
# (app_id().to_string() in app/src/bin/zap_oss.rs); the key is the constant
# SECURE_STORAGE_KEY. Changing either will break the keyring write below
# and Zap's read on startup.
ZAP_KEYRING_SERVICE="dev.zap.Zap"
ZAP_KEYRING_KEY="AgentProviderSecrets"
LITELLM_PROVIDER_ID="litellm-local"   # must match providers.id in configs/settings.toml

#############################################################################
# PHASE 0: Self-Update (verbatim from linux-setup.sh:483-512)
#############################################################################

log "Checking for script updates..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if git rev-parse --git-dir > /dev/null 2>&1; then
    log "Git repository detected, checking for updates..."

    # Fetch latest changes
    git fetch origin 2>/dev/null || true

    # Count commits we don't have that remote has
    BEHIND=$(git rev-list HEAD..@{u} 2>/dev/null | wc -l || echo "0")

    if [ "$BEHIND" -gt 0 ]; then
        log "Updates found! Pulling latest changes..."
        git pull --ff-only
        log "Re-executing updated script..."
        exec "$0" "${ORIGINAL_ARGS[@]}" || error "Failed to re-execute updated script"
    else
        log "Script is up to date"
    fi
else
    warn "Not running from a git repository. Self-update disabled."
fi

#############################################################################
# PHASE 1: Prerequisite packages
#############################################################################

log "Installing prerequisite packages (curl, jq, ca-certificates, fonts-firacode, libsecret-tools)..."
sudo apt-get update -qq
sudo apt-get install -y curl jq ca-certificates fonts-firacode libsecret-tools

#############################################################################
# PHASE 2: Install Zap from latest GitHub .deb
#############################################################################

install_zap_from_github() {
    local repo="zerx-lab/zap"
    local pkg="zap"
    local arch="amd64"
    [ "$(dpkg --print-architecture)" = "$arch" ] || error "Zap publishes only amd64 .deb (got: $(dpkg --print-architecture))"

    log "Resolving latest Zap release on github.com/${repo}..."
    local meta tag url latest_ver installed_ver tmp
    meta=$(curl --proto '=https' --tlsv1.2 -fsSL "https://api.github.com/repos/${repo}/releases?per_page=30")

    # Walk releases newest-first and pick the first one publishing a
    # zap_*_amd64.deb asset. We prefer this over /releases/latest so that a
    # one-off hand-published release or a future re-introduced parallel
    # release line can't trip the installer. Single jq pass returns tag+url
    # from the SAME release record so they can't drift.
    read -r tag url < <(printf '%s' "$meta" | jq -r --arg pkg "$pkg" '
        [.[] | select(.draft|not) | select(.prerelease|not)
             | . as $r
             | .assets[]
             | select(.name | test("^" + $pkg + "_.*_amd64\\.deb$"))
             | "\($r.tag_name) \(.browser_download_url)"][0] // ""')
    [ -n "$url" ] || error "No zap-branded .deb found in recent releases"

    latest_ver="${tag#v}"
    installed_ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
    if [ "$installed_ver" = "$latest_ver" ]; then
        log "$pkg $installed_ver already installed (latest Zap release)"
        return 0
    fi

    log "Installing $pkg $latest_ver (was: ${installed_ver:-none})"
    tmp=$(mktemp --suffix=.deb)
    trap 'rm -f "$tmp"' RETURN
    curl --proto '=https' --tlsv1.2 -fSL --progress-bar -o "$tmp" "$url"
    # mktemp creates 0600; relax so the _apt sandbox user can read the file
    # (otherwise apt falls back to unsandboxed root fetch and prints a notice).
    chmod 0644 "$tmp"
    sudo apt-get install -y "$tmp"
}

install_zap_from_github

#############################################################################
# PHASE 3: Configure Zap (theme, keybindings, settings.toml)
#############################################################################

log "Configuring Zap..."
mkdir -p "$CONFIG_DIR" "$THEMES_DIR"

install_with_prompt() {
    local src=$1 dst=$2 label=$3 transform=${4:-cat}

    if [ -f "$dst" ]; then
        if prompt_yes_no "Overwrite existing $label at $dst?" "N"; then
            backup_file "$dst"
        else
            log "Keeping existing $label"
            return 0
        fi
    fi
    "$transform" < "$src" | install -m 0644 /dev/stdin "$dst"
    log "Installed $label: $dst"
}

# settings.toml uses __HOME__ as a placeholder for the absolute theme path.
render_settings() { sed "s|__HOME__|$HOME|g"; }

install_with_prompt \
    "$SCRIPT_DIR/configs/terminator_black_on_white.yaml" \
    "$THEMES_DIR/terminator_black_on_white.yaml" \
    "theme (Terminator Black on White)"

install_with_prompt \
    "$SCRIPT_DIR/configs/keybindings.yaml" \
    "$CONFIG_DIR/keybindings.yaml" \
    "keybindings"

install_with_prompt \
    "$SCRIPT_DIR/configs/settings.toml" \
    "$CONFIG_DIR/settings.toml" \
    "settings (font + theme + provider)" \
    render_settings

# Zap spawns login shells per tab, which makes PAM's pam_motd.so
# print /etc/motd on every new tab. An empty ~/.hushlogin tells PAM to
# skip the MOTD for this user — no system files touched.
if [ ! -e "$HOME/.hushlogin" ]; then
    touch "$HOME/.hushlogin"
    log "Created ~/.hushlogin (suppresses per-tab MOTD)"
fi

#############################################################################
# PHASE 4: Stash LiteLLM API key in the OS keyring (only if env var is set)
#############################################################################
# Zap keeps provider API keys in the Secret Service (libsecret on
# Linux), not in settings.toml — see app/src/ai/agent_providers/secrets.rs.
# The stored value is a single JSON map of every custom provider's key, so
# we read-merge-write to avoid clobbering keys for other providers the
# user may have added via the UI.
KEYRING_OK=false
if [ -n "${LITELLM_API_KEY:-}" ]; then
    if ! command -v secret-tool &> /dev/null; then
        warn "LITELLM_API_KEY set but secret-tool missing — install libsecret-tools to enable keyring write"
    else
        existing=$(secret-tool lookup service "$ZAP_KEYRING_SERVICE" key "$ZAP_KEYRING_KEY" 2>/dev/null || true)
        [ -n "$existing" ] || existing='{}'
        merged=$(printf '%s' "$existing" | jq --arg id "$LITELLM_PROVIDER_ID" --arg k "$LITELLM_API_KEY" '. + {($id): $k}')
        if printf '%s' "$merged" | secret-tool store \
                --label="Zap: $ZAP_KEYRING_KEY" \
                service "$ZAP_KEYRING_SERVICE" \
                key "$ZAP_KEYRING_KEY"; then
            log "Stored LiteLLM API key in OS keyring (provider id: $LITELLM_PROVIDER_ID)"
            KEYRING_OK=true
        else
            warn "Failed to write to OS keyring (see secret-tool stderr above — likely a locked collection or missing secret-service daemon)"
        fi
    fi
fi

#############################################################################
# Done
#############################################################################

echo
log "Zap setup complete."
if [ "$KEYRING_OK" = true ]; then
    KEY_STEP="The LiteLLM API key is already in the OS keyring — no UI paste needed."
else
    KEY_STEP='Open Settings -> AI -> Agent Providers -> "LiteLLM (local)" -> API Key
     and paste your LiteLLM master key. (The api_key lives in the OS
     keyring, not in settings.toml. To skip this step on next install,
     export LITELLM_API_KEY before re-running the script.)'
fi
cat << EOF

Next steps:
  1. Launch:  zap
  2. $KEY_STEP
  3. Verify Settings -> Appearance shows "Terminator Black on White" + Fira
     Code 13.
  4. In a block, type any prompt and check Ctrl-O (block log) shows
     POST 127.0.0.1:4000/v1/chat/completions -> 200 (requires a LiteLLM
     proxy listening on the default port 4000 — out of scope for this
     installer).

EOF
