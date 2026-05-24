# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-purpose installer that fetches the latest **Zap** terminal `.deb` from `github.com/zerx-lab/zap`, installs it via `apt`, and writes four opinionated configs (theme, keybindings, settings.toml, mcp.json) targeting Terminator parity — specifically the effective Terminator keymap produced by `/opt/linux-setup/linux-setup.sh`. No build system, no tests; just a Bash script + shared helpers in `linux/common.sh` + four payload files in `linux/configs/`.

The installer assumes a LiteLLM proxy is already running on `127.0.0.1:4000` (LiteLLM setup is **out of scope**). The provider block in `settings.toml` points at that endpoint; the user pastes the API key once via Settings UI (it lives in the OS keyring, not in TOML).

There is also a **Windows (PowerShell) port** under `windows/` — `setup.ps1` + `common.ps1` + `windows/configs/`. It mirrors the Linux phases but installs `ZapSetup.exe` (Inno Setup) silently, writes to Zap's Windows paths, and differs deliberately: built-in **Dracula** theme (no theme YAML), no font-family override, a `powershell.exe` session-shell override, the `dx_12` graphics backend, a bash-style Ctrl+D PowerShell handler, and an optional **Azure** provider whose key it writes to Zap's DPAPI secrets file. See the "Windows port" section below.

## Common commands

```bash
./linux/setup.sh                       # interactive (default)
./linux/setup.sh --force               # auto-Yes — answers Y to every overwrite prompt
./linux/setup.sh --no                  # auto-No — preserves every existing config
./linux/setup.sh --help

bash -n linux/setup.sh && bash -n linux/common.sh   # syntax check (do this before any edit to either .sh)
```

Windows port (run on Windows; on Linux use `pwsh` only to lint):

```powershell
.\windows\setup.ps1                    # interactive (default)
.\windows\setup.ps1 -Force             # auto-Yes (aliases -f -yes -y)
.\windows\setup.ps1 -No                # auto-No  (alias -n)
.\windows\setup.ps1 -Help

# parse-check (no execution) — do this before any edit to either .ps1:
pwsh -NoProfile -Command '$e=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path windows/setup.ps1),[ref]$null,[ref]$e);$e'
```

Validate any `settings.toml` change with **Zap's own parser** — `toml_edit = "0.25.5"`, NOT Python `tomllib` or the `toml` crate. Zap loads settings via `toml_edit` (`crates/warpui_extras/src/user_preferences/toml_backed.rs`), which accepts the multi-line inline-table-with-trailing-commas form (TOML 1.1) that strict 1.0 parsers reject. A throwaway `cargo` bin depending on `toml_edit = "0.25.5"` that does `s.parse::<toml_edit::DocumentMut>()` is the correct check.

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
MCP file:     ~/.zap/.mcp.json   (OSS channel — NOT under ~/.config/zap/)
```

The `.deb` postinst deliberately does **not** configure an APT repo or trust key, so updates only happen via re-running this installer (which fetches a new .deb if upstream has a newer version). The script also writes `[updates] automatic_updates_enabled = false` to suppress the otherwise-useless in-app update toast.

### MCP servers — separate JSON, not settings.toml

Zap loads MCP server definitions from `~/.zap/.mcp.json` at startup and re-reads the file on change via `app/src/ai/mcp/file_mcp_watcher.rs`. The path is built by `warp_home_mcp_config_file_path()` in `crates/warp_core/src/paths.rs`; the OSS channel directory name is `.zap` (stable/preview use `.warp`). `settings.toml` carries no MCP definitions — the only MCP-adjacent TOML key is the bool `agents.mcp_servers.file_based_mcp_enabled`, which only gates third-party file watchers.

`linux/configs/mcp.json` ships two auth-free URL servers (`microsoft-learn`, `deepwiki`). Schema notes for additions:

- Top-level wrapper is `mcp_servers` (snake_case canonical; `mcpServers` / `servers` are accepted aliases — `app/src/ai/mcp/templatable.rs:71-78`).
- URL/SSE entries use `url` (Zap also accepts the `serverUrl` alias, but use canonical `url` so Zap's own serializer doesn't rewrite-and-diff on first save).
- Each server has exactly one of `command` (stdio) or `url` (HTTP/SSE) — validated in `app/src/ai/agent_sdk/mcp_config.rs`.
- **Do not bundle MCPs that require auth headers.** Zap has no keyring slot for MCP headers, so a token in `headers.Authorization` would land in a world-readable JSON file. Servers like GitHub/Linear/Sentry stay user-added, not bundled.

## Windows port (`windows/`)

`windows/setup.ps1` mirrors `linux/setup.sh` phase-for-phase; `windows/common.ps1` mirrors `common.sh` (`Write-Log`/`Write-Warn`/`Write-Err`, `Backup-File`, `Confirm-YesNo`, `Install-WithPrompt`). `windows/configs/keybindings.yaml` and `windows/configs/mcp.json` are **byte-identical copies** of the Linux payloads (the keymap's `cmd-*` maps to the Win key on Windows); only `windows/configs/settings.toml` is Windows-specific. There is no theme YAML — Dracula is built in.

### `windows/*.ps1` must be pure ASCII (no BOM)

Windows PowerShell 5.1 — the default shell on Windows 10/11 and the configured session shell — reads a BOM-less `.ps1` as the system ANSI codepage (Windows-1252), **not** UTF-8. Any non-ASCII byte then mis-decodes: an em-dash (`—`, UTF-8 `E2 80 94`) becomes the 3-char sequence `â€"`, which corrupts string boundaries and cascades into bogus parser errors (e.g. `Missing statement block in switch statement clause` at every following `function`). PowerShell 7 and Linux `pwsh` default to UTF-8, so the breakage is invisible there.

Rule: keep `windows/setup.ps1` and `windows/common.ps1` **pure ASCII** — use `-` not `—`, `'` not `'`/`'`, `"` not `"`/`"`. ASCII parses identically under both ANSI and UTF-8, so no BOM is needed (and a BOM is deliberately avoided — Zap reads the `windows/configs/*` payloads as UTF-8 and a stray BOM would break those parsers, so don't reach for BOMs as a habit here). This is the one place the repo's house em-dash style is dropped; CLAUDE.md and the Linux `*.sh` files keep their em-dashes. Guard it before any edit to either `.ps1`:

```bash
grep -nP '[^\x00-\x7F]' windows/setup.ps1 windows/common.ps1   # must print nothing
```

### Install mechanism

The Windows asset is **`ZapSetup.exe`** (Inno Setup), not a `.deb`. Older releases shipped `OpenWarpSetup.exe`, so the asset filter pins `^ZapSetup\.exe$` and walks `releases?per_page=30` newest-first — the same anti-rename-trap discipline as the `.deb` filter. Install is silent + per-user (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, `PrivilegesRequired=lowest` → no admin). Version short-circuit reads `DisplayVersion` from the Inno per-user uninstall key `HKCU:\…\Uninstall\zap-oss_is1` (OSS channel `AppId=zap-oss`).

**Do not re-add `-Wait` to the installer `Start-Process`.** Zap's Inno `[Run]` entry auto-launches the app on completion *without* the `skipifsilent` flag (verified empirically — Zap opens during `/VERYSILENT`), so `[Run]` is **not** suppressible from the command line. Whether the installer then *blocks* depends on `[Run]`'s `nowait` flag — which we can't read (the script is in the compressed 6.7.0 setup data, beyond `innoextract`/`7z`), so `Install-Zap` handles **both**: a blocking `[Run]` (a plain `-Wait` would hang until the user closes Zap) and a detached one (installer exits but leaves the window open — the originally observed bug was actually this case). The launch is cosmetic; `[Run]` is the last phase, after all `[Files]` are copied, so closing it loses nothing.

`Install-Zap` starts the installer with `-PassThru` (no `-Wait`) and repeatedly calls **`Close-SpawnedZap`** — both *while* the installer is alive (up to a 5-min ceiling) **and** for a ~30s grace window *after* it exits (to catch a detached launch whose window appears just after exit). `Close-SpawnedZap` matches a process with a visible main window (`MainWindowHandle != [IntPtr]::Zero`), a `StartTime` later than `$startedAt` (captured via `Get-Date` *before* launch — never `$proc.StartTime`, which throws on a fast/elevated process under `ErrorActionPreference='Stop'`), **and** either a `zap*` process name **or** a path under `Get-ZapInstallDir`. The name-or-path OR is deliberate: don't hard-gate the close on `Get-ZapInstallDir` resolving (it can return `$null`), and don't gate on a version-string match (Inno's `DisplayVersion` may carry the tag's leading `v` while `$rel.Version` strips it — the version short-circuit at the top of `Install-Zap` normalizes both with `-replace '^[vV]',''` for the same reason). If the installer never exits, it's `Stop-Process`'d and we proceed (files are already installed). Success is judged by a registered uninstall key, **not** the exit code — force-closing the `[Run]` child must not turn a completed install into a fatal `Write-Err`.

### Windows paths (verified against `crates/warp_core/src/paths.rs`)

Program files (verified against a real per-user install, `PrivilegesRequired=lowest`): `%LOCALAPPDATA%\Programs\Zap\`, main executable `zap-oss.exe` (process name `zap-oss`). This is the dir `Get-ZapInstallDir` resolves and the `zap*` name `Close-SpawnedZap` matches.

`ProjectDirs::from("dev","zap","Zap")` (no lowercasing — that branch is Linux-only):

- `settings.toml`, `keybindings.yaml` → `%LOCALAPPDATA%\zap\Zap\config\` (`config_local_dir()`)
- `.mcp.json` → `%USERPROFILE%\.zap\.mcp.json` (`warp_home_mcp_config_file_path()`, OSS dir `.zap`; `-<profile>` suffix when `WARP_DATA_PROFILE` is set)
- API-key store → `%LOCALAPPDATA%\zap\Zap\data\dev.zap.Zap-AgentProviderSecrets` (`state_dir()` → `data_local_dir()`)

### API keys: DPAPI file, NOT Credential Manager

On Windows Zap stores provider keys in a single **DPAPI-encrypted file** (`crates/warpui_extras/src/secure_storage/windows.rs`), not the Credential Manager. Filename `{service}-{key}` = `dev.zap.Zap-AgentProviderSecrets`; plaintext is `serde_json` of `HashMap<provider_id, api_key>`. Encryption is `CryptProtectData` with **no entropy, flags 0 (CurrentUser scope)** and a cosmetic description that decrypt ignores — so PowerShell writes it with `[System.Security.Cryptography.ProtectedData]::Protect($utf8Bytes, $null, 'CurrentUser')`, no Win32 interop. `Write-AzureKeyToDpapi` read-merge-writes (mirrors the Linux Phase 4 jq merge) so other providers' keys survive.

### `dx_12` — convert_case, not serde

`[system] preferred_graphics_backend = "dx_12"` (with the underscore). `settings.toml` is serialized by the `settings_value::SettingsValue` derive, which uses `convert_case` `Case::Snake` (`crates/settings_value_derive/src/lib.rs`), NOT serde — and convert_case inserts a boundary at the lower→digit transition, so `GraphicsBackend::Dx12` → `dx_12`. The `rename_all="snake_case"` on the enum is `schemars`-only. **For any enum-valued key with digits/acronyms, derive the literal from convert_case (or copy what Zap's GUI writes), never serde's `snake_case`.**

### Azure provider — v1 route only

Zap's genai adapter (`lib/rust-genai/src/adapter/adapters/openai/adapter_shared.rs`) builds the URL as `base_url.join("chat/completions")` and sends auth **only** as `Authorization: Bearer`. So the Azure base_url must be the OpenAI-compatible **v1** form `https://<resource>.<host>/openai/v1/` (Bearer-with-resource-key is the documented OpenAI-SDK pattern). The classic `…/openai/deployments/{name}/chat/completions?api-version=…` route is incompatible — it needs the `api-key` header (→ 401) and a different path shape. The v1 route is documented on `openai.azure.com`/`services.ai.azure.com`; for a pasted `cognitiveservices.azure.com` host the installer probes `…/openai/v1/models` with the key and falls back to the `openai.azure.com`/`services.ai.azure.com` siblings on 404. The injected provider uses the multi-line inline-table `[agents.warp_agent] providers = [ … ]` form (keys alphabetical, trailing commas) Zap's serializer writes; model fields are verified against `AgentProviderModel` (`app/src/settings/ai.rs`).

### Sentinel-delimited injected blocks

The Ctrl+D profile handler (Windows PowerShell 5.1 always; PowerShell 7+ if `pwsh` present) and the Azure provider TOML are each wrapped in `# >>> zap-setup … >>>` / `# <<< zap-setup … <<<` markers and regenerated in place, so re-runs replace rather than duplicate. The Ctrl+D handler is bash-faithful (exit only on an empty prompt) — Zap forwards Ctrl+D to the PTY as EOT and PowerShell, unlike bash, doesn't exit on it.
