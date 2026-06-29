#!/bin/bash

# update-zap — update the Zap terminal to the latest GitHub release, but only
# if a newer version is published. Installed to /usr/local/bin/update-zap by
# linux/setup.sh (and runnable straight from the repo as ./linux/update-zap.sh).
#
# Self-contained on purpose: the installed copy must work even after the cloned
# zap-setup repo is gone, so it does NOT source common.sh. The GitHub release
# walk + asset filter + version short-circuit below are deliberately COPIED from
# install_zap_from_github in setup.sh — keep the two in sync. See CLAUDE.md
# ("Release-asset filter (do not loosen)").

set -eo pipefail

# --- Minimal logging (mirrors linux/common.sh; copied so this stays standalone)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

show_usage() {
    cat << EOF
update-zap — update Zap to the latest GitHub release (only if newer)

Usage: update-zap [OPTIONS]

Checks github.com/zerx-lab/zap for the newest zap_*_amd64.deb release and
installs it via apt only when it is newer than the installed package. When Zap
is already current it prints a message and exits without changing anything.

Options:
  --help, -h   Show this help and exit

Needs sudo for the apt install step (you'll be prompted) and the curl, jq and
dpkg tools (installed by linux/setup.sh).
EOF
    exit 0
}

case "${1:-}" in
    --help|-h) show_usage ;;
    "")        ;;
    *)         error "Unknown option '$1' (use --help)" ;;
esac

update_zap_from_github() {
    local repo="zerx-lab/zap"
    local pkg="zap"
    local arch="amd64"
    [ "$(dpkg --print-architecture)" = "$arch" ] || error "Zap publishes only amd64 .deb (got: $(dpkg --print-architecture))"

    # Defensive: setup.sh installs these, but the standalone command may run on a
    # system where they were removed.
    for tool in curl jq dpkg-query; do
        command -v "$tool" &> /dev/null || error "Required tool '$tool' not found (install curl, jq and dpkg)."
    done

    log "Resolving latest Zap release on github.com/${repo}..."
    local meta tag url latest_ver installed_ver tmp
    # Hardened curl: -q (first) ignores a hostile ~/.curlrc; -A presents a modern
    # browser UA so UA-filtering CDNs don't 403. (Mirrors setup.sh.)
    local ua="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
    meta=$(curl -q --proto '=https' --tlsv1.2 -fsSL -A "$ua" "https://api.github.com/repos/${repo}/releases?per_page=30")

    # Walk releases newest-first; pick the first publishing a zap_*_amd64.deb.
    # Single jq pass returns tag+url from the SAME release record so they can't
    # drift. asset filter mirrors install_zap_from_github in setup.sh — keep in
    # sync (CLAUDE.md "Release-asset filter").
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

    log "Updating $pkg $latest_ver (was: ${installed_ver:-none})"
    tmp=$(mktemp --suffix=.deb)
    trap 'rm -f "$tmp"' RETURN
    curl -q --proto '=https' --tlsv1.2 -fSL --progress-bar -A "$ua" -o "$tmp" "$url"
    # mktemp creates 0600; relax so the _apt sandbox user can read the file.
    chmod 0644 "$tmp"
    sudo apt-get install -y "$tmp"
    log "Zap updated to $latest_ver."
}

update_zap_from_github
