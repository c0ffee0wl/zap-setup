#!/bin/bash

# Zap Setup Script
# Installs Zap from the latest GitHub .deb and configures it with
# the Terminator "Black on White" theme + Terminator-style keybindings
# (mirroring /opt/linux-setup/linux-setup.sh's effective Terminator set).
#
# Shared helpers (colors / log / backup_file / prompt_yes_no) live in
# linux/common.sh — they're lifted verbatim from /opt/linux-setup/linux-setup.sh
# and annotated there. The Phase 0 self-update block below is lifted from there
# too (with a local `cd "$SCRIPT_DIR"` — see its inline comment).

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VERSION="0.1"
FORCE_MODE=false
NO_MODE=false

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
~/.config/zap/, ~/.local/share/zap/themes/, or ~/.zap/. Backups are timestamped.

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

# Check if running as root (verbatim from linux-setup.sh:121-123)
if [[ $EUID -eq 0 ]]; then
    warn "This script should normally not be run as root. Please run as a regular user with sudo privileges."
fi

# Check if we're on a Debian-based system (verbatim from linux-setup.sh:126-128)
if ! grep -qE "(debian|ID_LIKE.*debian)" /etc/os-release 2>/dev/null; then
    error "This script requires a Debian-based Linux distribution. Detected system is not compatible."
fi

# Zap config paths (XDG, matching desktop ID dev.zap.Zap; the Linux project
# dir name is lowercased to "zap" — see crates/warp_core/src/paths.rs:243-246
# in the upstream source).
CONFIG_DIR="$HOME/.config/zap"
THEMES_DIR="$HOME/.local/share/zap/themes"
# MCP server defs live in a separate JSON file Zap loads at startup.
# Path is derived from the build channel in crates/warp_core/src/paths.rs;
# the OSS channel resolves to `~/.zap/` (NOT `~/.config/zap/`). A non-empty
# $WARP_DATA_PROFILE shifts the dir to `~/.zap-<profile>/` — warp_home_config_dir_name()
# appends `-<profile>` whenever ChannelState::data_profile() (env::var("WARP_DATA_PROFILE"))
# is Some, so mirror that here or the file lands where Zap won't read it.
ZAP_HOME_DIR="$HOME/.zap${WARP_DATA_PROFILE+-$WARP_DATA_PROFILE}"

# OS-keyring contract — coupled to Zap internals
# (app/src/ai/agent_providers/secrets.rs). The service name is the app ID
# (app_id().to_string() in app/src/bin/zap_oss.rs); the key is the constant
# SECURE_STORAGE_KEY. Changing either will break the keyring write below
# and Zap's read on startup.
ZAP_KEYRING_SERVICE="dev.zap.Zap"
ZAP_KEYRING_KEY="AgentProviderSecrets"
LITELLM_PROVIDER_ID="litellm-local"   # must match providers.id in linux/configs/settings.toml

#############################################################################
# PHASE 0: Self-Update (adapted from linux-setup.sh:483-512 — see inline note)
#############################################################################

log "Checking for script updates..."

# Anchor to this script's own repo before any git op. Under an orchestrator
# (ct-kali-llm Phase 9) the cwd is arbitrary, so a bare `git rev-parse` would
# either disable self-update ("not a git repo") or — if cwd sits in an unrelated
# git tree — fetch/pull THAT repo. `cd "$SCRIPT_DIR"` (git traverses up to the
# repo root) makes every git op below target this repo; re-exec is absolute too.
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
        # Re-exec via $SCRIPT_DIR (absolute) rather than $0 so resolution
        # is independent of the user's invocation cwd and any future `cd`.
        exec "$SCRIPT_DIR/setup.sh" "${ORIGINAL_ARGS[@]}" || error "Failed to re-execute updated script"
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
mkdir -p "$CONFIG_DIR" "$THEMES_DIR" "$ZAP_HOME_DIR"

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

# MCP servers — auth-free URL-based endpoints only. Zap watches this file
# (app/src/ai/mcp/file_mcp_watcher.rs) and picks up changes without a restart.
install_with_prompt \
    "$SCRIPT_DIR/configs/mcp.json" \
    "$ZAP_HOME_DIR/.mcp.json" \
    "MCP servers (microsoft-learn, deepwiki)"

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
        # If $existing is not valid JSON, jq fails inside this $(...) but
        # `set -e` does not propagate command-substitution failures (no
        # `inherit_errexit`), so $merged ends up empty. Guarding below
        # prevents an empty store call from wiping every other provider's
        # key under the same service.
        merged=$(printf '%s' "$existing" | jq --arg id "$LITELLM_PROVIDER_ID" --arg k "$LITELLM_API_KEY" '. + {($id): $k}')
        if [ -z "$merged" ]; then
            warn "Refusing to write keyring: jq merge produced empty value (existing keyring entry is likely not valid JSON). Other providers' keys preserved."
        elif printf '%s' "$merged" | secret-tool store \
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
# PHASE 5: Reclaim Super+Q for Zap; flag other conflicting XFCE shortcuts
#############################################################################
# Zap's keymap (Terminator parity) puts rename-tab on Super+Q (cmd-q) and the
# splits on Super+Y / Super+A. XFCE grabs some Super combos globally — they fire
# on the desktop before the focused app, so the chord never reaches Zap.
# Super+Q has no XFCE default, so if something grabs it we reclaim it
# automatically (mirroring linux-setup.sh). We no longer touch Super+E, so
# XFCE's built-in file-manager shortcut keeps working. The split chords and the
# bare-Super Whisker grab may carry defaults worth keeping, so those are
# reported only. Defaults verified against docs.xfce.org/xfce/xfwm4/keyboard_shortcuts
# (Super_L -> Whisker is the Xubuntu/Kali default and on XFCE < 4.20 it swallows
# every Super+<letter> chord).

if command -v xfconf-query &> /dev/null \
   && xfconf-query -c xfce4-keyboard-shortcuts -l &> /dev/null; then
    # Reclaim Super+Q (cmd-q = rename_active_tab): clear any custom/default
    # binding so the chord reaches Zap. Logged, not silent.
    for scope in custom default; do
        prop="/commands/$scope/<Super>q"
        action=$(xfconf-query -c xfce4-keyboard-shortcuts -p "$prop" 2>/dev/null || true)
        [ -z "$action" ] && continue
        xfconf-query -c xfce4-keyboard-shortcuts -p "$prop" -r 2>/dev/null || true
        log "Cleared XFCE Super+Q shortcut ($scope: $action) so Zap can use it for rename tab"
    done

    # Report (don't touch) the remaining overlaps — they may carry XFCE/user
    # defaults the user wants to keep. The <Super>{y,a} probes mirror the
    # cmd-{y,a} Super bindings in configs/keybindings.yaml (add_down / add_right)
    # — keep this list in sync if those Super bindings change. Super_L is the
    # bare-Super Whisker grab. One lookup each: a non-empty value means the
    # shortcut is bound. Carry the value alongside the combo (key is pipe-free,
    # so '|' is a safe field separator) to avoid a second query.
    found=()
    for combo in '<Super>y' '<Super>a' 'Super_L'; do
        action=$(xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$combo" 2>/dev/null || true)
        [ -n "$action" ] && found+=("$combo|$action")
    done

    if [ ${#found[@]} -gt 0 ]; then
        echo
        warn "XFCE global shortcuts overlap Zap's keymap — they fire on the desktop"
        warn "and never reach Zap. Remove any you want Zap to own (optional):"
        for entry in "${found[@]}"; do
            combo=${entry%%|*}; action=${entry#*|}
            if [ "$combo" = "Super_L" ]; then
                echo "    Super_L  ->  $action   (Whisker menu)"
                echo "      Keep it on XFCE 4.20+ (tap-vs-hold is handled). On older XFCE it"
                echo "      eats every Super+<letter> chord — remap or remove it:"
            else
                echo "    $combo  ->  $action"
            fi
            echo "      xfconf-query -c xfce4-keyboard-shortcuts -p '/commands/custom/$combo' -r"
        done
        echo "    GUI: Settings -> Keyboard -> Application Shortcuts."
        echo "    (xfconf has no undo — the action shown above is what you'd re-add to restore it.)"
    fi
fi

#############################################################################
# PHASE 6: Register the Warp/Zap Claude Code plugin marketplace (if claude present)
#############################################################################
# Zap is a Warp OSS fork, and warpdotdev/claude-code-warp ships the `warp`
# plugin that wires Claude Code into the terminal. If the `claude` CLI is on
# PATH we register the marketplace and install the plugin via claude's own
# command line. claude enforces any managed `strictKnownMarketplaces` policy
# itself and exits non-zero when a foreign marketplace is prohibited, so each
# call sits in an `if` (exempt from `set -e`) and a failure only warns, never
# aborts the installer. Re-running is safe: `marketplace add` replaces the
# same-named entry and `install` is a no-op when the plugin is already there.
if command -v claude &> /dev/null; then
    log "Detected claude CLI — registering the claude-code-warp plugin marketplace"
    if claude plugin marketplace add warpdotdev/claude-code-warp; then
        if claude plugin install warp@claude-code-warp; then
            log "Installed the warp plugin (warp@claude-code-warp)"
        else
            warn "Added the marketplace but 'claude plugin install warp@claude-code-warp' failed — install it later with /plugin"
        fi
    else
        warn "Could not add the claude-code-warp marketplace (a managed claude policy may prohibit foreign marketplaces) — skipping"
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
  5. The microsoft-learn and deepwiki MCP servers are registered in
     $ZAP_HOME_DIR/.mcp.json. In the agent panel, confirm both appear in
     the available MCP tools list (if they're missing, check that
     \$WARP_DATA_PROFILE is unset — it changes the dir Zap reads).

EOF
