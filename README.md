# zap-setup

Linux installer for the [Zap](https://github.com/zerx-lab/zap) terminal. It fetches the latest `.deb` from upstream, installs it via `apt`, and writes four opinionated configs: a Terminator "Black on White" theme, Terminator-parity keybindings, a `settings.toml` wired to a local [LiteLLM](https://docs.litellm.ai/) proxy, and an `mcp.json` with auth-free documentation MCP servers (Microsoft Learn, DeepWiki).

Runs on Debian and Kali (Bash) as a regular user. amd64 only; Zap publishes no arm64 `.deb`.

## Quick Start

```bash
git clone https://github.com/c0ffee0wl/zap-setup ~/zap-setup
cd ~/zap-setup
export LITELLM_API_KEY=sk-...        # optional: pre-stash in OS keyring
./linux/setup.sh
zap                                  # launch
```

Open Zap. The provider picker shows "LiteLLM (local)" pointing at `http://127.0.0.1:4000/v1/`. If you skipped the `LITELLM_API_KEY` export, the end-of-setup banner tells you to paste the key once via Settings → AI → Agent Providers → LiteLLM (local) → API Key. It lands in the OS keyring (`dev.zap.Zap` / `AgentProviderSecrets`), not in `settings.toml`.

A LiteLLM proxy on `127.0.0.1:4000` is a prerequisite. This repo does not install or configure LiteLLM; see [claude-litellm](https://github.com/c0ffee0wl/claude-litellm) for the sibling installer that does.

## Setup Modes

| Command | What happens |
|---|---|
| `./linux/setup.sh` | Interactive. Prompts (default **N**) before overwriting any existing config in `~/.config/zap/`, `~/.local/share/zap/themes/`, or `~/.zap/` |
| `./linux/setup.sh --force` | Non-interactive, answer **Yes** to every overwrite prompt (aliases: `-f`, `--yes`, `-y`) |
| `./linux/setup.sh --no` | Non-interactive, answer **No**. Preserves every existing config (alias: `-n`) |
| `./linux/setup.sh --help` | Show usage and exit (alias: `-h`) |

## Architecture

```
Zap (GUI terminal) ──► http://127.0.0.1:4000 ──► LiteLLM ──► Azure / Vertex / etc.
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
