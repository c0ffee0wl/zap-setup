# zap-setup

Linux installer for the [Zap](https://github.com/zerx-lab/zap) terminal. It fetches the latest `.deb` from upstream, installs it via `apt`, and writes four opinionated configs: a Terminator "Black on White" theme, Terminator-parity keybindings, a `settings.toml` wired to a local [LiteLLM](https://docs.litellm.ai/) proxy, and an `mcp.json` with auth-free documentation MCP servers (Microsoft Learn, DeepWiki).

Runs on Debian and Kali (Bash) as a regular user. amd64 only; Zap publishes no arm64 `.deb`.

There's also a Windows (PowerShell) installer under `windows/`; see [Windows](#windows) below.

## Quick Start

```bash
git clone https://github.com/c0ffee0wl/zap-setup ~/zap-setup
cd ~/zap-setup
export LITELLM_API_KEY=sk-...        # optional: pre-stash in OS keyring
./linux/setup.sh
zap                                  # launch
```

Open Zap and you have a working terminal straight away. The AI wiring is optional; Zap is a perfectly good terminal without any of it.

Where it gets good is the built-in LLM integration, and that's really the reason to bother. Setup pre-configures an agent provider named "LiteLLM (local)" aimed at `http://127.0.0.1:4000/v1/`, so if you have a LiteLLM proxy listening on that port, the agent works the moment you add a key. Paste it once via Settings → AI → Agent Providers → LiteLLM (local) → API Key, or export `LITELLM_API_KEY` before running setup and the script stashes it for you. Either way the key lives in the OS keyring (`dev.zap.Zap` / `AgentProviderSecrets`), never in `settings.toml`.

No proxy running? Nothing breaks. The provider just sits idle and the rest of Zap behaves exactly the same until you point it at a live endpoint. This repo doesn't install or configure LiteLLM itself; the sibling [claude-litellm](https://github.com/c0ffee0wl/claude-litellm) installer does, and running the two together is the setup this is built for.

## Setup Modes

| Command | What happens |
|---|---|
| `./linux/setup.sh` | Interactive. Prompts (default **N**) before overwriting any existing config in `~/.config/zap/`, `~/.local/share/zap/themes/`, or `~/.zap/` |
| `./linux/setup.sh --force` | Non-interactive, answer **Yes** to every overwrite prompt (aliases: `-f`, `--yes`, `-y`) |
| `./linux/setup.sh --no` | Non-interactive, answer **No**. Preserves every existing config (alias: `-n`) |
| `./linux/setup.sh --help` | Show usage and exit (alias: `-h`) |

## Architecture

```
Zap (GUI terminal) ──► http://127.0.0.1:4000 ──► LiteLLM ──► Azure / Vertex / etc.  (AI agent; optional)
    │
    ├── ~/.config/zap/settings.toml         (font, theme selector, provider block)
    ├── ~/.config/zap/keybindings.yaml      (Terminator-parity bindings)
    ├── ~/.local/share/zap/themes/terminator_black_on_white.yaml
    ├── ~/.zap/.mcp.json                    (MCP servers: microsoft-learn, deepwiki)
    └── OS keyring  →  service "dev.zap.Zap", key "AgentProviderSecrets"
                       (JSON map of provider-id → api_key)
```

- The custom-theme selector in `settings.toml` (`appearance.themes.theme.custom.name`) must match the `name:` field inside the YAML exactly. Both currently say `Terminator Black on White`. Change them together or Zap silently falls back to the default.
- `settings.toml` ships with a literal `__HOME__` token in the theme path; `render_settings()` substitutes `$HOME` at install time. Reuse this placeholder for any new absolute-path keys.
- MCP servers live in `~/.zap/.mcp.json` (not `~/.config/zap/`), loaded by Zap's `file_mcp_watcher` at startup and on file change. Only auth-free URL endpoints are bundled; Zap has no keyring slot for MCP headers, so tokenized servers (GitHub, Linear, etc.) stay user-added.
- The API key lives in the OS keyring, never in `settings.toml`. The keyring path is coupled to Zap internals (`app/src/ai/agent_providers/secrets.rs`). The Phase 4 keyring write read-merge-writes so it does not clobber keys for other providers added via the UI.
- No APT repo, no auto-updates. The `.deb` postinst skips repo and trust-key configuration on purpose. Updates only happen via re-running this installer; the in-app update toast is disabled (`[updates] automatic_updates_enabled = false`).
- The release filter is pinned. The installer walks `releases?per_page=30` newest-first and picks the first record whose asset name matches `^zap_.*_amd64\.deb$`. Older `warp-terminal-oss_*_amd64.deb` assets and any future parallel release line are ignored.

## Important Files

- `linux/setup.sh`: phases 0-4 (self-update, apt prereqs, .deb fetch, config render + install incl. mcp.json, optional keyring write)
- `linux/common.sh`: shared helpers (colors, logging, `backup_file`, `prompt_yes_no`); blocks lifted verbatim from `/opt/linux-setup/linux-setup.sh` and annotated with their upstream line ranges
- `linux/configs/settings.toml`: font, theme selector, LiteLLM provider entry; uses the `__HOME__` placeholder
- `linux/configs/keybindings.yaml`: Terminator-parity keybindings
- `linux/configs/terminator_black_on_white.yaml`: theme payload (must keep `name: Terminator Black on White`)
- `linux/configs/mcp.json`: MCP server registrations (microsoft-learn, deepwiki); installed to `~/.zap/.mcp.json`

## Idempotency

`setup.sh` is safe to re-run. A second invocation with no upstream changes is a no-op: the `.deb` install short-circuits on version match (`dpkg-query` compares the installed version against the tag from the GitHub release record), and every overwrite prompt defaults to **N**. Existing configs are never replaced without a timestamped backup; in interactive mode the prompt defaults to N, so a no-flag re-run preserves everything. Under `--force` the previous file is still copied to `<path>.backup.YYYY-MM-DD_HH-MM-SS` before the overwrite.

Zap updates are managed by re-running this installer. There is no `apt upgrade` path because the `.deb` postinst does not register an APT repo.

## Windows

A PowerShell sibling installer lives in `windows/`. It fetches the latest `ZapSetup.exe` (Inno Setup) from upstream, installs it silently per-user (no admin), and writes the same opinionated configs adapted for Windows: the built-in **Dracula** theme, the Terminator-parity keybindings, and the `mcp.json` documentation servers. It additionally pins Windows PowerShell 5.1 as the new-session shell and the DirectX 12 graphics backend, installs a bash-style Ctrl+D handler, and can pre-configure Azure OpenAI as the provider, writing the API key straight to where Zap reads it.

Requires Windows 10 build 18362+ (ConPTY). x64.

```powershell
git clone https://github.com/c0ffee0wl/zap-setup $env:USERPROFILE\zap-setup
cd $env:USERPROFILE\zap-setup
.\windows\setup.ps1
```

If you accept the Azure prompt, paste your resource endpoint (e.g. `https://<resource>.cognitiveservices.azure.com/`) and API key. The script normalizes it to the OpenAI-compatible v1 base URL (`…/openai/v1/`), probes it (falling back to the `openai.azure.com` host if the cognitiveservices host doesn't serve the v1 route), writes the provider into `settings.toml`, and stores the key in Zap's DPAPI secrets file, so no Settings-UI paste is needed. Decline, and Zap starts with no provider configured.

### Setup modes

| Command | What happens |
|---|---|
| `.\windows\setup.ps1` | Interactive. Prompts (default **N**) before overwriting any existing config; offers the Azure provider dialog |
| `.\windows\setup.ps1 -Force` | Non-interactive, answer **Yes** to overwrites (aliases: `-f`, `-yes`, `-y`). Azure configured only if `ZAP_AZURE_*` env vars are set |
| `.\windows\setup.ps1 -No` | Non-interactive, answer **No**; skips the Azure step (alias: `-n`) |
| `.\windows\setup.ps1 -Help` | Show usage and exit (alias: `-h`) |

For a non-interactive Azure setup, set `ZAP_AZURE_ENDPOINT` and `ZAP_AZURE_API_KEY` before running.

### Layout

```
%LOCALAPPDATA%\zap\Zap\config\settings.toml      (theme, shell override, providers)
%LOCALAPPDATA%\zap\Zap\config\keybindings.yaml   (Terminator-parity bindings)
%USERPROFILE%\.zap\.mcp.json                      (MCP servers: microsoft-learn, deepwiki)
%LOCALAPPDATA%\zap\Zap\data\dev.zap.Zap-AgentProviderSecrets   (DPAPI-encrypted {provider-id: key})
Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1   (Ctrl+D handler; also Documents\PowerShell\ for pwsh)
```

Windows-specific notes:

- **No Credential Manager.** Zap stores provider API keys as a single DPAPI-encrypted file (`CryptProtectData`, CurrentUser scope, no entropy), not in the Credential Manager. The installer writes it with .NET `ProtectedData.Protect`, read-merging any existing entries so other providers' keys aren't clobbered.
- **Azure must use the v1 route.** Zap's agent adapter only sends `Authorization: Bearer` and appends `chat/completions` to `base_url`, so only the `…/openai/v1/` form works; the classic `…/openai/deployments/{name}/chat/completions?api-version=…` route (which expects the `api-key` header) would return 401.
- **Ctrl+D.** Zap forwards Ctrl+D to the PTY as EOF; bash exits on an empty line, PowerShell does not. The installed handler replicates bash: Ctrl+D on an empty prompt runs `exit` (closing the pane), otherwise deletes the char under the cursor. It is written into both the Windows PowerShell 5.1 profile and (if `pwsh` is installed) the PowerShell 7+ profile.
- **Dracula is built in.** No theme YAML is shipped; `settings.toml` just selects `theme = "dracula"`. The font family is left unset (Zap defaults to its bundled Hack).

Idempotency mirrors the Linux script: a re-run with no upstream change is a no-op (version match via the `zap-oss_is1` uninstall registry key; overwrite prompts default **N**). The Ctrl+D profile block and the Azure provider block are sentinel-delimited (`# >>> zap-setup … >>>`) and regenerated in place, so re-runs replace rather than duplicate them.
