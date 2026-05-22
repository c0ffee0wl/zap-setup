# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-purpose installer that fetches the latest **Zap** terminal `.deb` from `github.com/zerx-lab/zap`, installs it via `apt`, and writes three opinionated configs (theme, keybindings, settings.toml) targeting Terminator parity — specifically the effective Terminator keymap produced by `/opt/linux-setup/linux-setup.sh`. No build system, no tests; just a Bash script + shared helpers in `linux/common.sh` + three payload files in `linux/configs/`.

The installer assumes a LiteLLM proxy is already running on `127.0.0.1:4000` (LiteLLM setup is **out of scope**). The provider block in `settings.toml` points at that endpoint; the user pastes the API key once via Settings UI (it lives in the OS keyring, not in TOML).

## Common commands

```bash
./linux/setup.sh                       # interactive (default)
./linux/setup.sh --force               # auto-Yes — answers Y to every overwrite prompt
./linux/setup.sh --no                  # auto-No — preserves every existing config
./linux/setup.sh --help

bash -n linux/setup.sh && bash -n linux/common.sh   # syntax check (do this before any edit to either .sh)
```

There are no tests. For end-to-end validation use the script's own re-run behavior: a second run with no upstream changes is a no-op (install step short-circuits on version match, prompts default to **N**).

To verify Zap's settings.toml schema before adding new keys, clone the source and grep:

```bash
git clone --depth 1 https://github.com/zerx-lab/zap /tmp/zap-src
rg -n -t rust 'toml_path:\s*"[^"]+"' /tmp/zap-src/app/src/
```

## Architecture and conventions

### Verbatim lifts from `/opt/linux-setup/linux-setup.sh`

Several blocks are **copied character-for-character** from the linux-setup script, each annotated with `# verbatim from linux-setup.sh:NNN-MMM`. Shared helpers (colors, `log`/`warn`/`error`, `backup_file`, `prompt_yes_no`) live in `linux/common.sh`; the remaining lifts (arg parsing, root + Debian preflight, Phase 0 self-update) live in `linux/setup.sh`. Do **not** refactor or "improve" these — the whole point is that they evolve in lockstep with the upstream helper script. `linux/common.sh` is a hosting location, not a refactoring layer. Carried-over quirks (e.g. `wc -l || echo "0"` printing a one-off `[: 0\n0: integer expected` when the local repo has no upstream) are intentionally preserved.

### Release-asset filter (do not loosen)

The Zap GitHub project publishes releases with the asset name `zap_*_amd64.deb`. Older `warp-terminal-oss_*_amd64.deb` assets pre-date the project rename and must not match — the jq filter in `install_zap_from_github` therefore pins the asset regex to `^zap_.*_amd64\.deb$` and walks `releases?per_page=30` newest-first instead of hitting `/releases/latest`, so a one-off hand-published release or a future re-introduced parallel release line can't trip the installer.

### `__HOME__` template substitution

`linux/configs/settings.toml` contains a literal `__HOME__` token in the theme `path = ...` field. The script renders it through `render_settings()` (a `sed "s|__HOME__|$HOME|g"` pipe) at install time. When adding new TOML keys that need an absolute path, reuse the same placeholder — do not invent a second one.

### Custom-theme selector — name string identity matters

`appearance.themes.theme = { Custom = { name = "...", path = "..." } }` resolves against the in-memory theme registry that Zap builds by scanning `~/.local/share/zap/themes/*.yaml` at startup. The `name` value in `settings.toml` **must match the `name:` field inside the YAML file exactly** — that's the join key. Both `linux/configs/terminator_black_on_white.yaml` and `linux/configs/settings.toml` currently use `Terminator Black on White`; change them together or the theme silently falls back.

### `install_with_prompt` (the only meaningful helper)

```
install_with_prompt SRC DST LABEL [TRANSFORM]
```

Prompts before overwriting (default **N**), creates a timestamped `.backup.YYYY-MM-DD_HH-MM-SS`, then pipes `SRC` through `TRANSFORM` (defaults to `cat`) into `DST` via `install -m 0644 /dev/stdin`. The transform argument is how `settings.toml` gets its `__HOME__` substitution — new config files that need preprocessing should follow the same pattern (define a function, pass its name as the 4th arg).

### Zap install layout (verified against the `.deb`)

```
Package:      zap   (amd64 only; no arm64 .deb is published)
Binary:       /opt/zap/zap-oss
Symlink:      /usr/bin/zap  ← user-facing command
Desktop ID:   dev.zap.Zap
Config dir:   ~/.config/zap/
Themes dir:   ~/.local/share/zap/themes/
```

The `.deb` postinst deliberately does **not** configure an APT repo or trust key, so updates only happen via re-running this installer (which fetches a new .deb if upstream has a newer version). The script also writes `[updates] automatic_updates_enabled = false` to suppress the otherwise-useless in-app update toast.
