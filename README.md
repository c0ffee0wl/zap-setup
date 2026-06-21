# zap-setup

Linux installer for the [Zap](https://github.com/zerx-lab/zap) terminal. It fetches the latest `.deb` from upstream, installs it via `apt`, and writes four opinionated configs: a Terminator "Black on White" theme, Terminator-parity keybindings, a `settings.toml` wired to the public [OpenAI](https://platform.openai.com/) API by default (or a local [LiteLLM](https://docs.litellm.ai/) proxy when one is detected), and an `mcp.json` with auth-free documentation MCP servers (Microsoft Learn, DeepWiki). If the `claude` CLI is installed, it also registers the Warp/Zap Claude Code plugin (`warpdotdev/claude-code-warp`), failing quietly when a managed policy forbids foreign marketplaces.

Runs on Debian and Kali (Bash) as a regular user. amd64 only; Zap publishes no arm64 `.deb`.

There's also a Windows (PowerShell) installer under `windows/`; see [Windows](#windows) below.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Quick Start](#quick-start)
- [Setup Modes](#setup-modes)
- [Architecture](#architecture)
- [Important Files](#important-files)
- [Idempotency](#idempotency)
- [Performance in a VM: enable 3D acceleration](#performance-in-a-vm-enable-3d-acceleration)
- [Windows](#windows)
  - [Setup modes](#setup-modes)
  - [Layout](#layout)
  - [3D acceleration in a VM](#3d-acceleration-in-a-vm)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Quick Start

```bash
git clone https://github.com/c0ffee0wl/zap-setup ~/zap-setup
cd ~/zap-setup
export OPENAI_API_KEY=sk-...         # optional: pre-stash the OpenAI key in the OS keyring
./linux/setup.sh
zap                                  # launch
```

Open Zap and you have a working terminal straight away. The AI wiring is optional; Zap is a perfectly good terminal without any of it.

Where it gets good is the built-in LLM integration, and that's really the reason to bother. By default setup pre-configures an agent provider named "OpenAI" aimed at `https://api.openai.com/v1/` with the `gpt-5.4` model, so the agent works the moment you add a key. Need one? Create it at [platform.openai.com/api-keys](https://platform.openai.com/api-keys). Paste it once via Settings → AI → Agent Providers → OpenAI → API Key, or export `OPENAI_API_KEY` before running setup and the script stashes it for you. Either way the key lives in the OS keyring (`dev.zap.Zap` / `AgentProviderSecrets`), never in `settings.toml`.

Running a local LiteLLM proxy instead? Setup detects it (the `litellm` CLI on `PATH`, or anything answering on `127.0.0.1:4000`) and wires an agent provider named "LiteLLM (local)" aimed at `http://127.0.0.1:4000/v1/` in place of OpenAI. The key works the same way: paste it via Settings → AI → Agent Providers → LiteLLM (local) → API Key, or export `LITELLM_API_KEY` before running. This repo doesn't install or configure LiteLLM itself; the sibling [claude-litellm](https://github.com/c0ffee0wl/claude-litellm) installer does, and running the two together is the setup the LiteLLM path is built for.

## Setup Modes

| Command | What happens |
|---|---|
| `./linux/setup.sh` | Interactive. Prompts (default **N**) before overwriting any existing config in `~/.config/zap/`, `~/.local/share/zap/themes/`, or `~/.zap/` |
| `./linux/setup.sh --force` | Non-interactive, answer **Yes** to every overwrite prompt (aliases: `-f`, `--yes`, `-y`) |
| `./linux/setup.sh --no` | Non-interactive, answer **No**. Preserves every existing config (alias: `-n`) |
| `./linux/setup.sh --help` | Show usage and exit (alias: `-h`) |

## Architecture

```
Zap (GUI terminal) ──► https://api.openai.com/v1/                            (AI agent; default)
    │              └─ or ──► http://127.0.0.1:4000 ──► LiteLLM ──► Azure / Vertex / etc.  (when a proxy is detected)
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

- `linux/setup.sh`: phases 0-6 (self-update, apt prereqs, .deb fetch, config render + install incl. mcp.json, optional keyring write, XFCE Super+Q reclaim, optional Claude Code plugin marketplace when `claude` is present)
- `linux/common.sh`: shared helpers (colors, logging, `backup_file`, `prompt_yes_no`); blocks lifted verbatim from `/opt/linux-setup/linux-setup.sh` and annotated with their upstream line ranges
- `linux/configs/settings.toml`: font, theme selector, and two mutually-exclusive provider blocks (OpenAI default + LiteLLM override); `render_settings` strips one based on LiteLLM detection. Uses the `__HOME__` placeholder
- `linux/configs/keybindings.yaml`: Terminator-parity keybindings
- `linux/configs/terminator_black_on_white.yaml`: theme payload (must keep `name: Terminator Black on White`)
- `linux/configs/mcp.json`: MCP server registrations (microsoft-learn, deepwiki); installed to `~/.zap/.mcp.json`

## Idempotency

`setup.sh` is safe to re-run. A second invocation with no upstream changes is a no-op: the `.deb` install short-circuits on version match (`dpkg-query` compares the installed version against the tag from the GitHub release record), and every overwrite prompt defaults to **N**. Existing configs are never replaced without a timestamped backup; in interactive mode the prompt defaults to N, so a no-flag re-run preserves everything. Under `--force` the previous file is still copied to `<path>.backup.YYYY-MM-DD_HH-MM-SS` before the overwrite.

Zap updates are managed by re-running this installer. There is no `apt upgrade` path because the `.deb` postinst does not register an APT repo.

## Performance in a VM: enable 3D acceleration

Zap renders on the GPU. It's a Warp OSS fork, and Warp draws its window and text through `wgpu` (Vulkan or OpenGL on Linux) instead of on the CPU. On bare metal you never notice. In a VM you do. If the guest has no 3D acceleration the GPU is emulated in software (Mesa's `llvmpipe`), and Zap gets sluggish: input lag while you type, and CPU that climbs trying to keep up. Scrolling stutters, and now and then the window never paints at all. It's the usual reason Zap feels slow in a VM, and you fix it on the host, not in this installer.

The fix is to give the guest a real paravirtual GPU. On VMware Workstation Pro with a Windows host:

1. Power off the VM. The toggle is greyed out while it runs or is suspended.
2. Open VM → Settings → Hardware → Display.
3. Tick **Accelerate 3D graphics**.
4. Set **Graphics memory** to 1 GB or more.
5. Boot the guest and install the VMware tools so the virtual GPU driver loads: `sudo apt install open-vm-tools open-vm-tools-desktop`, then reboot.

The Windows host also needs a current GPU driver and DirectX; `dxdiag` on the host will confirm both. VMware maps the guest's OpenGL onto the host GPU through that.

To check it worked, run `glxinfo | grep "OpenGL renderer"` in the guest. An accelerated guest reports an `SVGA3D` renderer; if you still see `llvmpipe`, the setting didn't take.

When 3D acceleration genuinely isn't available, Zap still starts. Pin a backend so it stops hunting for one: `WGPU_BACKEND=gl zap` (Zap passes `WGPU_BACKEND` straight through to `wgpu`). Rendering stays in software, but it's stable.

## Windows

A PowerShell sibling installer lives in `windows/`. It fetches the latest `ZapSetup.exe` (Inno Setup) from upstream, installs it silently per-user (no admin), and writes the same opinionated configs adapted for Windows: the built-in **Dracula** theme, the Terminator-parity keybindings, and the `mcp.json` documentation servers. It additionally pins Windows PowerShell 5.1 as the new-session shell and the DirectX 12 graphics backend, installs a bash-style Ctrl+D handler, and can pre-configure Azure OpenAI as the provider, writing the API key straight to where Zap reads it. Like the Linux script, it registers the Warp/Zap Claude Code plugin (`warpdotdev/claude-code-warp`) when the `claude` CLI is present.

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

### 3D acceleration in a VM

The same applies on Windows. Zap is GPU-rendered, so a Windows guest with no 3D acceleration falls back to the Microsoft Basic Render Driver, and you get the same lag and CPU drain. On VMware Workstation Pro with a Windows host and a Windows guest:

1. Power off the VM.
2. Open VM → Settings → Hardware → Display, tick **Accelerate 3D graphics**, and set **Graphics memory** to 1 GB or more.
3. Boot the guest and install the full VMware Tools package. It ships the SVGA 3D WDDM driver that Zap renders through. Reboot afterwards.

The Windows host needs a current GPU driver and DirectX, which `dxdiag` will confirm. To check the guest picked it up, run `dxdiag` there too: the Display tab should name the VMware SVGA 3D adapter with Direct3D acceleration enabled rather than the Basic Render Driver.

The installer already sets the backend to DirectX 12 (`system.preferred_graphics_backend = "dx_12"`, a Windows-only key), which is the right choice once real acceleration is in place. If DX12 still struggles in your VM, switch it from Settings → Features → Preferred graphics backend, or set `WGPU_BACKEND` (for example `gl`) before launching.
