#!/bin/bash

# Zap Setup Script
# Installs Zap from the latest GitHub .deb and configures it with
# the Terminator "Black on White" theme + Terminator-style keybindings
# (mirroring /opt/linux-setup/linux-setup.sh's effective Terminator set).
# The AI agent is wired to the public OpenAI provider by default, or to a
# local LiteLLM proxy when one is detected on 127.0.0.1:4000.
#
# Shared helpers (colors / log / backup_file / prompt_yes_no / apt_get) live in
# linux/common.sh — they're lifted verbatim from /opt/linux-setup/linux-setup.sh
# and annotated there. The Phase 0 self-update block below is lifted from there
# too (with a local `cd "$SCRIPT_DIR"` — see its inline comment).

set -eo pipefail

# Deterministic, English command output and locale-independent string handling
# (e.g. the ${renderer,,} lowercasing in the GPU check) regardless of the host
# locale. C.UTF-8 is built into glibc (no locale-gen needed on stock/minimal
# VMs) and preserves UTF-8. Affects only this process, not the system locale.
# (adapted from linux-setup.sh:8-13)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VERSION="0.1"
FORCE_MODE=false
NO_MODE=false

# Show usage information
show_usage() {
    cat << EOF
Zap Setup Script v${VERSION}
Installs Zap from the latest GitHub .deb and configures it to use the public
OpenAI provider by default (or a local LiteLLM proxy when one is detected) plus
Terminator-style keybindings on a Terminator "Black on White" theme.

Usage: $0 [OPTIONS]

Options:
  --force, -f, --yes, -y   Non-interactive, answer 'Yes' to all prompts
  --no, -n                 Non-interactive, answer 'No' to all prompts
  --help, -h               Show this help and exit

Interactive mode (default) prompts before overwriting any existing config in
~/.config/zap/, ~/.local/share/zap/themes/, or ~/.zap/. Backups are timestamped.

Export OPENAI_API_KEY (or LITELLM_API_KEY for the local-proxy path) before
running to stash the provider key in the OS keyring automatically.

EOF
    exit 0
}

# Preserve original args before parsing consumes them via shift.
# Used by self-update (exec "$0") to re-run with the same flags.
# (verbatim from linux-setup.sh:93-95)
ORIGINAL_ARGS=("$@")

# Parse command-line arguments (verbatim subset of linux-setup.sh:97-129)
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

# Check if running as root (verbatim from linux-setup.sh:155-158)
if [[ $EUID -eq 0 ]]; then
    warn "This script should normally not be run as root. Please run as a regular user with sudo privileges."
fi

# Check if we're on a Debian-based system (verbatim from linux-setup.sh:160-163)
if ! grep -qE "(debian|ID_LIKE.*debian)" /etc/os-release 2>/dev/null; then
    error "This script requires a Debian-based Linux distribution. Detected system is not compatible."
fi

# Zap config paths (XDG, matching desktop ID dev.zap.Zap; the Linux project
# dir name is lowercased to "zap" — see the ProjectDirs setup in
# crates/warp_core/src/paths.rs in the upstream source).
CONFIG_DIR="$HOME/.config/zap"
THEMES_DIR="$HOME/.local/share/zap/themes"
# MCP server defs live in a separate JSON file Zap loads at startup.
# Path is derived from the build channel in crates/warp_core/src/paths.rs;
# the OSS channel resolves to `~/.zap/` (NOT `~/.config/zap/`). Deliberately
# NOT namespaced by $WARP_DATA_PROFILE: ChannelState::data_profile()
# (crates/warp_core/src/channel/state.rs) reads that env var only under
# cfg!(debug_assertions), so the release builds this installer fetches always
# read plain `~/.zap/` — mirroring the var here would write the file where
# Zap never looks.
ZAP_HOME_DIR="$HOME/.zap"

# OS-keyring contract — coupled to Zap internals
# (app/src/ai/agent_providers/secrets.rs). The service name is the app ID
# (app_id().to_string() in app/src/bin/zap_oss.rs); the key is the constant
# SECURE_STORAGE_KEY. Changing either will break the keyring write below
# and Zap's read on startup.
ZAP_KEYRING_SERVICE="dev.zap.Zap"
ZAP_KEYRING_KEY="AgentProviderSecrets"
LITELLM_PROVIDER_ID="litellm-local"   # must match providers.id in the litellm block of settings.toml
OPENAI_PROVIDER_ID="openai"           # must match providers.id in the openai block of settings.toml
OPENAI_MODEL_ID="gpt-5.6-terra"       # must match models.id in the openai block of settings.toml

#############################################################################
# PHASE 0: Self-Update (adapted from linux-setup.sh:873-898 — see inline note)
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
    BEHIND=$(git rev-list --count HEAD..@{u} 2>/dev/null) || BEHIND=0

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

# Refresh the APT index at most once per run, and only right before something
# is actually installed — a re-run where everything is current never pays for
# an index refresh, while any install (prereqs here, the Zap .deb in Phase 2)
# still resolves its dependencies against a fresh index.
APT_INDEX_FRESH=false
apt_update_once() {
    if [ "$APT_INDEX_FRESH" = false ]; then
        apt_get update -qq
        APT_INDEX_FRESH=true
    fi
}

# mesa-utils provides glxinfo, used by the 3D-acceleration check below. Skip
# apt entirely when every prerequisite is already installed; the db:Status-Status
# check (not `dpkg -s` or a bare Version read) counts removed-but-config-remains
# packages as missing.
PREREQ_PKGS=(curl jq ca-certificates fonts-firacode libsecret-tools mesa-utils)
missing=()
for p in "${PREREQ_PKGS[@]}"; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = "installed" ] || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    log "Installing prerequisite packages: ${missing[*]}"
    apt_update_once
    apt_get install -y "${missing[@]}"
else
    log "Prerequisite packages already installed (${PREREQ_PKGS[*]})"
fi

#############################################################################
# GPU preflight: warn if 3D acceleration is missing (Zap renders on the GPU)
#############################################################################
# Zap is a Warp OSS fork and draws its window + text through wgpu. Without 3D
# acceleration the GPU is emulated in software (Mesa llvmpipe) and Zap turns
# sluggish — input lag, scroll stutter, high CPU, the odd unpainted window.
# Best-effort and non-blocking; this never aborts the install.
#
# The OpenGL *renderer string* is the only reliable signal, so we read it with
# glxinfo -B (brief block only; mesa-utils, installed in Phase 1) run as the
# invoking user — it needs the user's $DISPLAY, and VMware reports acceleration
# per-user, so it must run as the account that will launch Zap. We flag ONLY a
# known software rasterizer.
# Two deliberate non-checks:
#   - Ignore the "Accelerated: yes/no" line. VMware's host-backed SVGA3D driver
#     reports "Accelerated: no" while 3D is genuinely working, so keying off it
#     would false-positive on every working VMware guest.
#   - Match the whole token "llvmpipe", never a bare "llvm": the accelerated
#     SVGA3D renderer string literally contains "LLVM" (its shader compiler).
# vulkaninfo is deliberately NOT used: VMware exposes no guest Vulkan ICD, so a
# fully accelerated VMware guest shows only lavapipe under Vulkan (false +ve).

check_gpu_acceleration() {
    if ! command -v glxinfo &> /dev/null; then
        warn "glxinfo not found (mesa-utils); skipping the 3D-acceleration check."
        return 0
    fi

    local renderer
    renderer=$(glxinfo -B 2>/dev/null | sed -n 's/.*OpenGL renderer string: //p' | head -n1)
    if [ -z "$renderer" ]; then
        warn "Could not read the OpenGL renderer (no X/Wayland display reachable?); skipping the 3D-acceleration check."
        return 0
    fi

    # Accelerated unless the renderer is a known software rasterizer (see above
    # for why we match the whole token, not a bare "llvm"). Lowercase the string
    # so the match is case-insensitive (covers SWRAST / Software Rasterizer).
    local soft_re='llvmpipe|softpipe|swrast|software rasterizer|lavapipe'
    if [[ ! "${renderer,,}" =~ $soft_re ]]; then
        log "3D acceleration active (renderer: $renderer)"
        return 0
    fi

    # --- Software rendering: warn and explain how to fix -------------------
    local vmware_doc="https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/using-vmware-workstation-pro/configuring-and-managing-virtual-machines/configure-display-settings-for-a-virtual-machine/prepare-a-virtual-machine-to-use-accelerated-3d-graphics.html"
    local vbox_doc="https://www.virtualbox.org/manual/ch03.html#settings-display"

    echo
    warn "3D (GPU) acceleration is NOT active — Zap is rendering in software (renderer: $renderer)."
    echo "    Zap renders on the GPU; in software expect input lag, scroll stutter, high"
    echo "    CPU, and occasional unpainted windows."
    echo

    local virt="unknown"
    if command -v systemd-detect-virt &> /dev/null; then
        virt=$(systemd-detect-virt --vm 2>/dev/null || true)
    fi

    case "$virt" in
        vmware)
            echo "    This is a VMware VM. Enable 3D for the guest:"
            echo "      1. Power off the VM (do not just suspend it)."
            echo "      2. VM -> Settings -> Hardware -> Display -> check 'Accelerate 3D graphics'."
            echo "      3. Make sure open-vm-tools (VMware Tools) is installed in the guest."
            echo "      Docs: $vmware_doc"
            ;;
        oracle)
            echo "    This is a VirtualBox VM. Enable 3D for the guest:"
            echo "      1. Install the Guest Additions in the guest, then power off the VM."
            echo "      2. Settings -> Display -> Screen: Graphics Controller = VMSVGA,"
            echo "         tick 'Enable 3D Acceleration', and give it ~128MB video memory."
            echo "      Docs: $vbox_doc"
            ;;
        none)
            echo "    No virtual machine detected — a real GPU should not fall back to llvmpipe."
            echo "    Your GPU driver / Mesa is likely missing or misconfigured; install the"
            echo "    vendor driver (or mesa for Intel/AMD) and recheck with: glxinfo | grep renderer"
            ;;
        *)
            echo "    If this is a VMware or VirtualBox VM, enable 3D in its display settings:"
            echo "      VMware:     $vmware_doc"
            echo "      VirtualBox: $vbox_doc"
            echo "    Otherwise (bare metal or another hypervisor) update your GPU driver / Mesa."
            ;;
    esac

    echo
    echo "    If acceleration truly isn't available, pin a backend so Zap stops hunting:"
    echo "      WGPU_BACKEND=gl zap"
    echo
}

check_gpu_acceleration

#############################################################################
# PHASE 2: Install Zap from latest GitHub .deb + the update-zap command
#############################################################################

install_zap_from_github() {
    local repo="zerx-lab/zap"
    local pkg="zap"
    local arch="amd64"
    [ "$(dpkg --print-architecture)" = "$arch" ] || error "Zap publishes only amd64 .deb (got: $(dpkg --print-architecture))"

    log "Resolving latest Zap release on github.com/${repo}..."
    local meta tag url latest_ver installed_ver
    # Match claude-litellm's hardened curl (linux/common.sh:42,82): -q (must come
    # first) makes curl ignore the user's ~/.curlrc — security distros like REMnux
    # ship one that forces a malformed IE11 UA + extra headers, tripping
    # Cloudflare's bot challenge (403) — and -A presents a modern browser UA, since
    # UA-filtering CDNs/proxies 403 curl's default. Both the API query and the .deb
    # fetch get them. Timeouts are bounded so a blackholed or stalled host can't
    # hang an unattended run: the API fetch gets a hard cap (safe because
    # --compressed shrinks its ~400 KB of release JSON ~11x), the .deb download
    # a stall-abort (<1 KB/s for 30s) instead of a hard cap so a slow but
    # progressing download is never killed.
    local ua="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
    meta=$(curl -q --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --compressed -fsSL -A "$ua" "https://api.github.com/repos/${repo}/releases?per_page=30")

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

    latest_ver="${tag#[vV]}"   # strip either tag case, like the Windows port's '^[vV]'
    # Status-aware version read: a removed-but-config-remains package still
    # reports a Version, which would wrongly skip the (re)install below.
    installed_ver=$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$pkg" 2>/dev/null || true)
    if [ "${installed_ver%% *}" = "installed" ]; then
        installed_ver="${installed_ver#* }"
    else
        installed_ver=""
    fi
    # "Only if newer": >= (not string equality) so a retracted or reordered
    # upstream release can't silently downgrade a newer installed build.
    if [ -n "$installed_ver" ] && dpkg --compare-versions "$installed_ver" ge "$latest_ver"; then
        log "$pkg $installed_ver already installed (>= latest Zap release $latest_ver)"
        return 0
    fi

    log "Installing $pkg $latest_ver (was: ${installed_ver:-none})"
    # tmp is deliberately NOT local: a set -e abort (e.g. a failed download)
    # exits the shell without running RETURN traps, and by the time the EXIT
    # trap runs a `local` is already out of scope — so cleanup hooks BOTH:
    # RETURN for the normal path, EXIT (which needs the global) for aborts.
    tmp=$(mktemp --suffix=.deb)
    trap 'rm -f "$tmp"' RETURN EXIT
    curl -q --proto '=https' --tlsv1.2 --connect-timeout 10 --speed-limit 1024 --speed-time 30 -fSL --progress-bar -A "$ua" -o "$tmp" "$url"
    # mktemp creates 0600; relax so the _apt sandbox user can read the file
    # (otherwise apt falls back to unsandboxed root fetch and prints a notice).
    chmod 0644 "$tmp"
    apt_update_once
    apt_get install -y "$tmp"
}

install_zap_from_github

# Install the standalone `update-zap` command to /usr/local/bin so the user can
# bump Zap later without re-running this whole installer. The command is
# self-contained (it does not source common.sh) — see linux/update-zap.sh, which
# duplicates the release-walk/version-check on purpose. /usr/local/bin is on the
# default PATH, so `update-zap` works in new shells immediately.
install_update_command() {
    local src="$SCRIPT_DIR/update-zap.sh" dst="/usr/local/bin/update-zap"
    if [ ! -f "$src" ]; then
        # Optional extra — a missing payload must not abort the run between
        # the Zap install and the config phases (same warn-and-continue
        # policy as Phase 6 and the Windows port).
        warn "update-zap payload not found at $src; skipping the update-zap command install."
        return 0
    fi
    if [ -f "$dst" ]; then
        # Default Y: this is our managed command, so a re-run refreshes it. --no
        # preserves an existing copy; --force refreshes it.
        prompt_yes_no "Refresh the update-zap command at $dst?" "Y" \
            || { log "Keeping existing $dst"; return 0; }
    fi
    sudo install -m 0755 "$src" "$dst"
    log "Installed update-zap command: $dst (run: update-zap)"
}

install_update_command

#############################################################################
# PHASE 3: Configure Zap (theme, keybindings, settings.toml)
#############################################################################

log "Configuring Zap..."
mkdir -p "$CONFIG_DIR" "$THEMES_DIR" "$ZAP_HOME_DIR"

# Detect LiteLLM to choose the active provider. The default is the public
# OpenAI provider; a detected LiteLLM proxy overrides it (a local proxy means
# the user is deliberately routing through their own gateway). Treat LiteLLM
# as present if the CLI is on PATH OR a proxy answers on its default port
# 4000 — either signal is enough: the CLI may be installed but not yet
# started, or the proxy may be up from a venv/Docker/systemd whose CLI isn't
# on the login PATH. The probe omits -f so any HTTP response (even 401/404)
# counts as "reachable"; -q comes first to ignore a hostile ~/.curlrc (same
# rationale as the .deb fetch above). curl is guaranteed by Phase 1.
#
# Every provider-specific fact is bound HERE, once: the sentinel token
# render_settings strips, the keyring provider id + env var + key Phase 4
# stashes, the models.id the post-render drift check must find in the
# surviving block, and the Settings-UI name / endpoint host / caveat the
# "Next steps" text shows. Everything after this if/else is branch-free on
# the provider.
if command -v litellm &> /dev/null \
   || curl -q -s -o /dev/null --connect-timeout 2 --max-time 3 "http://127.0.0.1:4000/" 2>/dev/null; then
    STRIP_BLOCK="openai"                     # keep the litellm block
    KEY_PROVIDER_ID="$LITELLM_PROVIDER_ID";  KEY_PROVIDER_LABEL="LiteLLM"
    KEY_PROVIDER_UI_NAME="LiteLLM"           # providers.name in settings.toml
    KEY_ENV_NAME="LITELLM_API_KEY";          API_KEY="${LITELLM_API_KEY:-}"
    # Same model as the openai block, behind the proxy's azure/ routing prefix
    # (deliberate — see the litellm block's comment in configs/settings.toml).
    EXPECT_MODEL_ID="azure/$OPENAI_MODEL_ID"
    VERIFY_HOST="127.0.0.1:4000"
    VERIFY_NOTE='(requires a LiteLLM proxy listening on the default port 4000,
     with the Responses route enabled — both out of scope for this installer)'
    log "LiteLLM detected — using the local LiteLLM provider (instead of the default OpenAI)"
else
    STRIP_BLOCK="litellm"                    # keep the default openai block
    KEY_PROVIDER_ID="$OPENAI_PROVIDER_ID";   KEY_PROVIDER_LABEL="OpenAI"
    KEY_PROVIDER_UI_NAME="OpenAI"            # providers.name in settings.toml
    KEY_ENV_NAME="OPENAI_API_KEY";           API_KEY="${OPENAI_API_KEY:-}"
    EXPECT_MODEL_ID="$OPENAI_MODEL_ID"
    VERIFY_HOST="api.openai.com"
    VERIFY_NOTE="(needs a valid OpenAI API key with access to the
     $OPENAI_MODEL_ID model)"
    log "No local LiteLLM detected — configuring the public OpenAI provider (default)"
fi

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

# settings.toml carries TWO mutually-exclusive provider blocks (litellm + openai)
# plus a __HOME__ placeholder for the absolute theme path. Exactly one provider
# survives: render_settings strips the INACTIVE block ($STRIP_BLOCK, bound at
# detection above) and substitutes __HOME__ in a single sed. The two blocks sit
# back-to-back in the payload (no blank line between the litellm end sentinel
# and the openai begin sentinel), so either strip leaves exactly one blank line
# at the seam. The surviving block's [agents.warp_agent] is the explicit parent
# for the [agents.warp_agent.*] sub-tables that follow, so the output is valid
# TOML.
#
render_settings() {
    sed -e "/# >>> zap-setup $STRIP_BLOCK provider >>>/,/# <<< zap-setup $STRIP_BLOCK provider <<</d" \
        -e "s|__HOME__|$HOME|g"
}

# A sed range whose sentinel doesn't match is a silent no-op that would leave
# BOTH provider tables in place — invalid TOML Zap ignores wholesale, under a
# green "Installed settings" log line. Validate the render up front, against
# one captured render: exactly one [agents.warp_agent] table line must
# survive, and it must carry the models.id bound at detection above (from the
# hand-synced OPENAI_MODEL_ID constant — a drifted constant aborts here, on
# both provider branches). Checked HERE, at top level, so error() aborts
# before install_with_prompt prompts, backs up, or writes anything (inside
# its pipeline, error's message would land in the file).
RENDERED_SETTINGS=$(render_settings < "$SCRIPT_DIR/configs/settings.toml")
[ "$(grep -cx '\[agents\.warp_agent\]' <<<"$RENDERED_SETTINGS")" = 1 ] \
    || error "settings.toml render check failed: stripping the '$STRIP_BLOCK' provider block did not leave exactly one [agents.warp_agent] table (sentinel mismatch?)"
[ "$(grep -cF "id = \"$EXPECT_MODEL_ID\"," <<<"$RENDERED_SETTINGS")" = 1 ] \
    || error "settings.toml render check failed: model id '$EXPECT_MODEL_ID' not found exactly once in the rendered provider block — the OPENAI_MODEL_ID constant drifted from configs/settings.toml (bump the constant and the provider blocks together)"

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
# PHASE 4: Stash the active provider's API key in the OS keyring (if env var set)
#############################################################################
# Zap keeps provider API keys in the Secret Service (libsecret on
# Linux), not in settings.toml — see app/src/ai/agent_providers/secrets.rs.
# The stored value is a single JSON map of every custom provider's key, so
# we read-merge-write to avoid clobbering keys for other providers the
# user may have added via the UI.
#
# Which key we stash follows the provider facts bound at the top of Phase 3
# (KEY_PROVIDER_ID / KEY_ENV_NAME / API_KEY): the LiteLLM proxy key when
# LiteLLM was detected, otherwise the public OpenAI key. The env var is
# optional — with it unset the user pastes the key once via the Settings UI
# instead.
KEYRING_OK=false
if [ -n "$API_KEY" ]; then
    if ! command -v secret-tool &> /dev/null; then
        warn "$KEY_ENV_NAME set but secret-tool missing — install libsecret-tools to enable keyring write"
    else
        existing=$(secret-tool lookup service "$ZAP_KEYRING_SERVICE" key "$ZAP_KEYRING_KEY" 2>/dev/null || true)
        [ -n "$existing" ] || existing='{}'
        # If $existing is not valid JSON, jq exits non-zero and that status
        # becomes the assignment's status — without the `|| true`, `set -e`
        # would kill the whole script right here. Swallow the failure so the
        # guard below can warn and continue: an empty $merged must never
        # reach secret-tool, or it would wipe every other provider's key
        # under the same service.
        merged=$(printf '%s' "$existing" | jq --arg id "$KEY_PROVIDER_ID" --arg k "$API_KEY" '. + {($id): $k}' 2>/dev/null || true)
        if [ -z "$merged" ]; then
            warn "Refusing to write keyring: jq merge produced empty value (existing keyring entry is likely not valid JSON). Other providers' keys preserved."
        elif printf '%s' "$merged" | secret-tool store \
                --label="Zap: $ZAP_KEYRING_KEY" \
                service "$ZAP_KEYRING_SERVICE" \
                key "$ZAP_KEYRING_KEY"; then
            log "Stored $KEY_PROVIDER_LABEL API key in OS keyring (provider id: $KEY_PROVIDER_ID)"
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
    # bare-Super Whisker grab, which ships in the *default* scope on
    # Kali/Xubuntu, so both scopes are probed (custom first, mirroring the
    # reclaim loop above; first hit wins). Scope and value are carried
    # alongside the combo (both are pipe-free, so '|' is a safe separator) so
    # the remediation command targets the right property path.
    found=()
    for combo in '<Super>y' '<Super>a' 'Super_L'; do
        for scope in custom default; do
            action=$(xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/$scope/$combo" 2>/dev/null || true)
            if [ -n "$action" ]; then
                found+=("$scope|$combo|$action")
                break
            fi
        done
    done

    if [ ${#found[@]} -gt 0 ]; then
        echo
        warn "XFCE global shortcuts overlap Zap's keymap — they fire on the desktop"
        warn "and never reach Zap. Remove any you want Zap to own (optional):"
        for entry in "${found[@]}"; do
            scope=${entry%%|*}; entry=${entry#*|}
            combo=${entry%%|*}; action=${entry#*|}
            if [ "$combo" = "Super_L" ]; then
                echo "    Super_L  ->  $action   (Whisker menu)"
                echo "      Keep it on XFCE 4.20+ (tap-vs-hold is handled). On older XFCE it"
                echo "      eats every Super+<letter> chord — remap or remove it:"
            else
                echo "    $combo  ->  $action"
            fi
            echo "      xfconf-query -c xfce4-keyboard-shortcuts -p '/commands/$scope/$combo' -r"
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

# Build the numbered "Next steps" list from the provider facts bound at the
# top of Phase 3 (KEY_PROVIDER_UI_NAME / KEY_PROVIDER_LABEL / KEY_ENV_NAME /
# VERIFY_HOST / VERIFY_NOTE). There is always exactly one provider (OpenAI by
# default, LiteLLM when detected), so the key-paste step (#2) and the AI
# round-trip verification step (#4) are always present — and branch-free.
if [ "$KEYRING_OK" = true ]; then
    KEY_STEP="The $KEY_PROVIDER_LABEL API key is already in the OS keyring — no UI paste needed."
else
    KEY_STEP="Open Settings -> AI -> Agent Providers -> \"$KEY_PROVIDER_UI_NAME\" -> API
     Key and paste your $KEY_PROVIDER_LABEL API key. (The api_key lives in the
     OS keyring, not in settings.toml. To skip this step on next install,
     export $KEY_ENV_NAME before re-running the script.)"
fi
VERIFY_STEP="In a block, type any prompt and check Ctrl-O (block log) shows
     POST $VERIFY_HOST/v1/responses -> 200
     $VERIFY_NOTE."
cat << EOF

Next steps:
  1. Launch:  zap
  2. $KEY_STEP
  3. Verify Settings -> Appearance shows "Terminator Black on White" + Fira
     Code 13.
  4. $VERIFY_STEP
  5. The microsoft-learn and deepwiki MCP servers are registered in
     $ZAP_HOME_DIR/.mcp.json. In the agent panel, confirm both appear in
     the available MCP tools list.

EOF
