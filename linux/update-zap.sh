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

# Deterministic, English command output regardless of the host locale.
# C.UTF-8 is built into glibc and preserves UTF-8. Affects only this process.
# (adapted from linux-setup.sh:8-13)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# --- Minimal logging (mirrors linux/common.sh; copied so this stays standalone)
# Colors suppressed when not a TTY or when NO_COLOR is set (as in common.sh).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# apt-get wrapper with a lock timeout so a boot-time apt job (apt-daily,
# unattended-upgrades) holding the lock delays rather than fails the update.
# Copied from linux/common.sh's apt_get (adapted from linux-setup.sh:228-242;
# the sudo env form is required — see the note in common.sh) — keep in sync.
# FORCE_MODE/NO_MODE are pinned false (this script has no unattended mode,
# and pinning stops an exported env var from silently switching apt to
# conffile-forcing mode), so the interactive branch always runs.
FORCE_MODE=false
NO_MODE=false
apt_get() {
    if [[ "$FORCE_MODE" == "true" || "$NO_MODE" == "true" ]]; then
        sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
            -o DPkg::Lock::Timeout=300 \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
    else
        sudo apt-get -o DPkg::Lock::Timeout=300 "$@"
    fi
}

# Refresh the APT index once before the install so the .deb's dependencies
# resolve against fresh lists. Copied from setup.sh — keep in sync (the
# once-guard is degenerate here with a single install site, but keeping the
# same shape keeps the twin install functions line-identical).
APT_INDEX_FRESH=false
apt_update_once() {
    if [ "$APT_INDEX_FRESH" = false ]; then
        apt_get update -qq
        APT_INDEX_FRESH=true
    fi
}

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

    # Defensive: setup.sh installs these, but the standalone command may run on a
    # system where they were removed. Checked BEFORE the first dpkg use (the
    # arch check below) so a missing tool gets this diagnostic, not a garbled
    # command-not-found message.
    for tool in curl jq dpkg dpkg-query; do
        command -v "$tool" &> /dev/null || error "Required tool '$tool' not found (install curl, jq and dpkg)."
    done

    [ "$(dpkg --print-architecture)" = "$arch" ] || error "Zap publishes only amd64 .deb (got: $(dpkg --print-architecture))"

    log "Resolving latest Zap release on github.com/${repo}..."
    local meta tag url latest_ver installed_ver
    # Hardened curl: -q (first) ignores a hostile ~/.curlrc; -A presents a modern
    # browser UA so UA-filtering CDNs don't 403. Bounded timeouts: hard cap on
    # the API fetch (safe because --compressed shrinks its release JSON ~11x),
    # stall-abort (not a hard cap) on the .deb download so a slow but
    # progressing download is never killed. (Mirrors setup.sh.)
    local ua="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
    meta=$(curl -q --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --compressed -fsSL -A "$ua" "https://api.github.com/repos/${repo}/releases?per_page=30")

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

    log "Updating $pkg $latest_ver (was: ${installed_ver:-none})"
    # tmp is deliberately NOT local: a set -e abort (e.g. a failed download)
    # exits the shell without running RETURN traps, and by the time the EXIT
    # trap runs a `local` is already out of scope — so cleanup hooks BOTH:
    # RETURN for the normal path, EXIT (which needs the global) for aborts.
    tmp=$(mktemp --suffix=.deb)
    trap 'rm -f "$tmp"' RETURN EXIT
    curl -q --proto '=https' --tlsv1.2 --connect-timeout 10 --speed-limit 1024 --speed-time 30 -fSL --progress-bar -A "$ua" -o "$tmp" "$url"
    # mktemp creates 0600; relax so the _apt sandbox user can read the file.
    chmod 0644 "$tmp"
    apt_update_once
    apt_get install -y "$tmp"
    log "Zap updated to $latest_ver."
}

update_zap_from_github
