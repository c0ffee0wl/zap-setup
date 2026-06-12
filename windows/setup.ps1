<#
.SYNOPSIS
    Zap Setup Script (Windows).

.DESCRIPTION
    Installs Zap from the latest GitHub ZapSetup.exe and configures it with the
    built-in Dracula theme + Terminator-style keybindings, a Windows PowerShell
    new-session shell override, the DirectX 12 graphics backend, a bash-style
    Ctrl+D handler for PowerShell, and (optionally) an Azure OpenAI provider
    whose API key is written straight to the place Zap reads it on Windows.

    This is the Windows sibling of linux/setup.sh; the phases mirror that
    script. Shared helpers live in common.ps1.

.PARAMETER Force
    Non-interactive: answer Yes to every overwrite prompt. (Aliases: -f -yes -y)

.PARAMETER No
    Non-interactive: answer No to every overwrite prompt. (Alias: -n)

.PARAMETER Help
    Show usage and exit. (Alias: -h)

.NOTES
    For the Azure provider in non-interactive runs, set the environment
    variables ZAP_AZURE_ENDPOINT and ZAP_AZURE_API_KEY before running.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('f', 'yes', 'y')][switch]$Force,
    [Alias('n')][switch]$No,
    [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'
# Avoid PS 5.1's painfully slow Invoke-WebRequest progress bar on big downloads.
$ProgressPreference = 'SilentlyContinue'
# PowerShell 7.4+ makes a non-zero native exit a terminating error under
# ErrorActionPreference=Stop. We check $LASTEXITCODE on git ourselves (and
# expect non-zero for "no upstream"/"not a repo"), so opt out to match 5.1.
if (Test-Path 'variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}
# GitHub + Azure require TLS 1.2; PS 5.1 on older Windows may not enable it.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Reconstruct the original args so self-update can re-exec with the same flags.
$OriginalArgs = @()
if ($Force) { $OriginalArgs += '-Force' }
if ($No)    { $OriginalArgs += '-No' }
if ($Help)  { $OriginalArgs += '-Help' }

. (Join-Path $PSScriptRoot 'common.ps1')

# Hand the parsed flags to common.ps1's helpers (dot-sourced into this scope).
$script:ZapForceMode = [bool]$Force
$script:ZapNoMode    = [bool]$No

$Version = '0.1'

function Show-Usage {
    @"
Zap Setup Script v$Version (Windows)
Installs Zap from the latest GitHub ZapSetup.exe and configures it with the
built-in Dracula theme, Terminator-style keybindings, a Windows PowerShell
session shell, the DirectX 12 backend, a bash-style Ctrl+D handler, and an
optional Azure OpenAI provider.

Usage: .\setup.ps1 [OPTIONS]

Options:
  -Force, -f, -yes, -y   Non-interactive, answer 'Yes' to all prompts
  -No, -n                Non-interactive, answer 'No' to all prompts
  -Help, -h              Show this help and exit

Interactive mode (default) prompts before overwriting any existing config in
%LOCALAPPDATA%\zap\Zap\config\ or %USERPROFILE%\.zap\. Backups are timestamped.

For the Azure provider without prompts, set ZAP_AZURE_ENDPOINT and
ZAP_AZURE_API_KEY before running.
"@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

#############################################################################
# Constants - Zap Windows layout (verified against the Zap source).
#############################################################################

$Repo             = 'zerx-lab/zap'
# Pin to the renamed asset; older releases shipped OpenWarpSetup.exe.
$AssetRegex       = '^ZapSetup\.exe$'
# Inno Setup AppId for the OSS channel -> per-user uninstall key (DisplayVersion).
$UninstallKeyName = 'zap-oss_is1'
# Per-user (HKCU) first, then all-users (HKLM) and 32-bit-view fallbacks.
$UninstallRegKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$UninstallKeyName",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$UninstallKeyName",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$UninstallKeyName"
)

$ConfigsDir = Join-Path $PSScriptRoot 'configs'

# directories::ProjectDirs::from("dev","zap","Zap") on Windows:
#   config_local_dir = %LOCALAPPDATA%\zap\Zap\config   (settings.toml, keybindings)
#   state_dir->data_local_dir = %LOCALAPPDATA%\zap\Zap\data  (DPAPI secrets file)
$ConfigDir = Join-Path $env:LOCALAPPDATA 'zap\Zap\config'
$StateDir  = Join-Path $env:LOCALAPPDATA 'zap\Zap\data'

# .mcp.json lives in the home-relative OSS dir (~/.zap), with a -<profile>
# suffix when WARP_DATA_PROFILE is set (mirrors warp_home_config_dir_name()).
$dataProfile = $env:WARP_DATA_PROFILE
$zapHomeName = if ([string]::IsNullOrEmpty($dataProfile)) { '.zap' } else { ".zap-$dataProfile" }
$ZapHomeDir  = Join-Path $env:USERPROFILE $zapHomeName

# DPAPI secrets store: state_dir\{service}-{key}; JSON map {provider_id: key}.
$SecretsServiceName = 'dev.zap.Zap'
$SecretsKey         = 'AgentProviderSecrets'
$SecretsFile        = Join-Path $StateDir "$SecretsServiceName-$SecretsKey"
$AzureProviderId    = 'azure-openai'

#############################################################################
# Phase 2 helpers - install Zap from GitHub
#############################################################################

function Get-InstalledZapVersion {
    # Read DisplayVersion from the Inno per-user (HKCU) / all-users (HKLM) keys.
    foreach ($k in $UninstallRegKeys) {
        try {
            $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).DisplayVersion
            if ($v) { return [string]$v }
        } catch { }
    }
    return $null
}

function Get-ZapInstallDir {
    # Where Inno put the program files - InstallLocation from the uninstall key,
    # falling back to the directory of the UninstallString ({app}\unins000.exe).
    foreach ($k in $UninstallRegKeys) {
        try {
            $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
            if ($p.InstallLocation) { return ([string]$p.InstallLocation).TrimEnd('\') }
            if ($p.UninstallString) {
                $d = Split-Path -Parent (([string]$p.UninstallString).Trim('"'))
                if ($d) { return $d.TrimEnd('\') }
            }
        } catch { }
    }
    return $null
}

function Close-SpawnedZap {
    # Close the Zap window the installer's [Run] entry auto-launches, so the
    # installer can finish (or so we don't leave a stray window if it launched
    # Zap detached). Matches a process with a visible main window that started
    # AFTER $After and is either named like 'zap' OR lives under the install
    # dir. The $After gate means a Zap the user already had open is never
    # touched. Records closed PIDs in $Seen so the caller can tell whether
    # anything was closed (and we only log each once).
    param([datetime]$After, [hashtable]$Seen)
    $dir = Get-ZapInstallDir
    $prefix = if ($dir) { $dir.TrimEnd('\') + '\' } else { $null }
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            if ($_.MainWindowHandle -eq [IntPtr]::Zero) { $false }
            elseif ($_.StartTime -le $After) { $false }
            elseif ($_.Name -like 'zap*') { $true }
            elseif ($prefix -and $_.Path -and $_.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $true }
            else { $false }
        } catch { $false }
    } | ForEach-Object {
        if (-not $Seen.ContainsKey($_.Id)) {
            Write-Log "Closing auto-launched Zap '$($_.Name)' (pid $($_.Id)) so the installer can finish."
            $Seen[$_.Id] = $true
        }
        $_.CloseMainWindow() | Out-Null
        Start-Sleep -Milliseconds 300
        if (-not $_.HasExited) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-LatestZapRelease {
    $api = "https://api.github.com/repos/$Repo/releases?per_page=30"
    $headers = @{ 'User-Agent' = 'zap-setup'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    try {
        $releases = Invoke-RestMethod -Uri $api -Headers $headers -Method Get
    } catch {
        Write-Err "Failed to query GitHub releases for $Repo : $($_.Exception.Message)"
    }
    foreach ($r in $releases) {
        if ($r.draft -or $r.prerelease) { continue }
        $asset = $r.assets | Where-Object { $_.name -match $AssetRegex } | Select-Object -First 1
        if ($asset) {
            return [pscustomobject]@{
                Tag     = $r.tag_name
                Url     = $asset.browser_download_url
                Version = ($r.tag_name -replace '^v', '')
            }
        }
    }
    return $null
}

function Install-Zap {
    $rel = Resolve-LatestZapRelease
    if (-not $rel) { Write-Err "No ZapSetup.exe asset found in recent releases of github.com/$Repo" }
    Write-Log "Latest Zap release: $($rel.Tag)"

    $installed = Get-InstalledZapVersion
    # Inno's DisplayVersion may carry a leading 'v' (the release tag does; the
    # de-v'd $rel.Version does not), so normalize both sides before comparing.
    if ($installed -and (($installed -replace '^[vV]', '') -eq ($rel.Version -replace '^[vV]', ''))) {
        Write-Log "Zap $installed already installed (latest release)"
        return
    }
    $was = if ($installed) { $installed } else { 'none' }
    Write-Log "Installing Zap $($rel.Version) (was: $was)"

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ZapSetup-{0}.exe" -f ([guid]::NewGuid().ToString('N')))
    try {
        Write-Log "Downloading $($rel.Url)"
        Invoke-WebRequest -Uri $rel.Url -OutFile $tmp -UseBasicParsing
        Write-Log "Running silent install (per-user, no admin needed)..."
        # Zap's Inno [Run] entry launches the app on completion WITHOUT the
        # 'skipifsilent' flag, so /VERYSILENT still opens Zap. A plain -Wait
        # would then block until the user closes that window (if [Run] also
        # lacks 'nowait'); if [Run] has 'nowait', the installer exits but leaves
        # the window open. We handle both: start without waiting, and keep
        # closing the spawned Zap (Close-SpawnedZap) both WHILE the installer is
        # alive and for a short grace window after it exits (to catch a detached
        # launch whose window appears just after exit). [Run] is the last phase,
        # after all [Files] are copied, so closing it loses nothing.
        $proc = Start-Process -FilePath $tmp `
            -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru
        $startedAt  = Get-Date
        $deadline   = (Get-Date).AddMinutes(5)
        $closedPids = @{}
        while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
            Close-SpawnedZap -After $startedAt -Seen $closedPids
            Start-Sleep -Milliseconds 500
        }
        if (-not $proc.HasExited) {
            # Files are already installed; stop waiting on the installer (it is
            # blocked on a Zap window we could not match) and move on.
            Write-Warn "Installer did not exit within 5 min; ending its wait (Zap is already installed)."
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $proc.WaitForExit(10000) | Out-Null
        }
        # Grace window for the detached-launch case: the installer exited but Zap
        # may pop up a moment later. Stop as soon as we have closed something.
        $graceEnd = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $graceEnd -and $closedPids.Count -eq 0) {
            Close-SpawnedZap -After $startedAt -Seen $closedPids
            Start-Sleep -Milliseconds 500
        }
        if ($closedPids.Count -eq 0) {
            Write-Warn "No auto-launched Zap window was detected to close; if one is open you can close it manually."
        }
        # The uninstall key is authoritative: [Run] is the last phase, so a
        # registered version means success even if force-closing the spawned Zap
        # (or ending the installer above) made the process report a non-zero code.
        $exit = $null
        try { if ($proc.HasExited) { $exit = $proc.ExitCode } } catch { }
        if (-not (Get-InstalledZapVersion)) {
            $detail = if ($null -ne $exit) { "exit code $exit" } else { "no exit code available" }
            Write-Err "Zap did not register an install ($detail)."
        }
        Write-Log "Zap installed."
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

#############################################################################
# Phase 4 helper - bash-style Ctrl+D handler in the PowerShell profiles
#############################################################################

function Set-CtrlDHandlers {
    $begin = '# >>> zap-setup ctrl-d >>>'
    $end   = '# <<< zap-setup ctrl-d <<<'

    # Single-quoted here-string: written verbatim into the profile, no PS
    # interpolation of $line/$cursor here.
    $body = @'
# Bash-style Ctrl+D: exit only on an EMPTY prompt; otherwise delete the char
# under the cursor. Zap forwards Ctrl+D to the PTY as EOT (end-of-transmission);
# bash exits on it, PowerShell does not, so we replicate it here. Managed by
# zap-setup - content between the markers is regenerated on each run.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Chord 'Ctrl+d' -ScriptBlock {
        $line = ''; $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ([string]::IsNullOrEmpty($line)) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert('exit')
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::DeleteChar()
        }
    }
}
'@
    $block = "$begin`r`n$body`r`n$end"

    # Documents may be redirected (e.g. OneDrive); GetFolderPath honors that.
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $targets = @()
    # Windows PowerShell 5.1 - always (it is the configured session shell).
    $targets += (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
    # PowerShell 7+ - only if pwsh is installed.
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $targets += (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
    }

    foreach ($profilePath in $targets) {
        $existing = ''
        if (Test-Path -LiteralPath $profilePath) {
            $existing = [System.IO.File]::ReadAllText($profilePath)
            Backup-File $profilePath
        }
        # Strip any previous zap-setup block (inclusive) so re-runs replace it.
        $pattern = [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
        $existing = [regex]::Replace($existing, $pattern, '',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $existing = $existing.TrimEnd("`r", "`n")
        if ($existing.Length -gt 0) { $existing += "`r`n`r`n" }
        Write-FileUtf8NoBom -Path $profilePath -Content ($existing + $block + "`r`n")
        Write-Log "Configured Ctrl+D handler in: $profilePath"
    }
}

#############################################################################
# Phase 5 helpers - Azure opt-in (dialogs, endpoint probe, TOML, DPAPI)
#############################################################################

function Show-ZapInputDialog {
    # Modern WinForms input box: visual styles on, Segoe UI, padded layout, a
    # real window icon. Returns the entered text, or '' if cancelled/closed.
    # -Secret masks the input. Falls back to the console if WinForms is missing
    # (e.g. a headless host), mirroring the old per-function fallbacks.
    param(
        [string]$Title,
        [string]$Prompt,
        [switch]$Secret
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

        $form = New-Object System.Windows.Forms.Form
        $form.Text            = $Title
        $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9.75)
        $form.ClientSize      = New-Object System.Drawing.Size(460, 150)
        $form.StartPosition   = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MinimizeBox     = $false
        $form.MaximizeBox     = $false
        $form.TopMost         = $true
        $form.ShowInTaskbar   = $false
        try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path) } catch { }

        $label = New-Object System.Windows.Forms.Label
        $label.Text     = $Prompt
        $label.Location = New-Object System.Drawing.Point(16, 16)
        $label.Size     = New-Object System.Drawing.Size(428, 48)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(16, 70)
        $tb.Size     = New-Object System.Drawing.Size(428, 26)
        if ($Secret) { $tb.UseSystemPasswordChar = $true }

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text         = 'OK'
        $ok.Size         = New-Object System.Drawing.Size(86, 30)
        $ok.Location     = New-Object System.Drawing.Point(262, 110)
        $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text         = 'Cancel'
        $cancel.Size         = New-Object System.Drawing.Size(86, 30)
        $cancel.Location     = New-Object System.Drawing.Point(358, 110)
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

        $form.Controls.AddRange(@($label, $tb, $ok, $cancel))
        $form.AcceptButton = $ok
        $form.CancelButton = $cancel
        $form.Add_Shown({ $form.Activate(); $tb.Focus() })

        if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $tb.Text }
        return ''
    } catch {
        if ($Secret) {
            $secure = Read-Host $Prompt -AsSecureString
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        return (Read-Host $Prompt)
    }
}

function Read-DialogText {
    param([string]$Title, [string]$Prompt)
    return (Show-ZapInputDialog -Title $Title -Prompt $Prompt)
}

function Read-DialogSecret {
    param([string]$Title, [string]$Prompt)
    return (Show-ZapInputDialog -Title $Title -Prompt $Prompt -Secret)
}

function Test-AzureEndpoint {
    # Returns 'ok' (route reachable + key accepted/validated), 'auth' (route
    # there, 401/403), 'notfound' (404), or 'other' (network/unknown).
    param([string]$BaseUrl, [string]$Key)
    $url = $BaseUrl + 'models'
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get `
            -Headers @{ Authorization = "Bearer $Key" } -UseBasicParsing -TimeoutSec 15
        if ([int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 300) { return 'ok' }
        return 'other'
    } catch {
        $status = $null
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($status -eq 404) { return 'notfound' }
        if ($status -eq 400) { return 'ok' }   # route exists; our probe body/path was just rejected
        if ($status -eq 401 -or $status -eq 403) { return 'auth' }
        return 'other'
    }
}

function Resolve-AzureBaseUrl {
    # Normalize whatever was pasted down to scheme+host, append /openai/v1/, and
    # probe. cognitiveservices hosts get openai.azure.com / services.ai.azure.com
    # fallbacks because the v1 route is documented on those hosts.
    param([string]$Endpoint, [string]$Key)

    $raw = $Endpoint.Trim()
    if ($raw -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $raw = "https://$raw" }
    try { $uri = [System.Uri]$raw } catch { Write-Err "Could not parse the Azure endpoint: $Endpoint" }
    $scheme = $uri.Scheme
    $hostName = $uri.Host
    $build = { param($h) "{0}://{1}/openai/v1/" -f $scheme, $h }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($hostName)
    if ($hostName -match '^(.*?)\.cognitiveservices\.azure\.com$') {
        $res = $Matches[1]
        $candidates.Add("$res.openai.azure.com")
        $candidates.Add("$res.services.ai.azure.com")
    }

    foreach ($h in $candidates) {
        $candidate = & $build $h
        switch (Test-AzureEndpoint -BaseUrl $candidate -Key $Key) {
            'ok'   { Write-Log "Azure endpoint verified: $candidate"; return $candidate }
            'auth' {
                Write-Warn "Azure endpoint $candidate is reachable but the key was rejected (401/403). Using it anyway - fix the key/role in the Azure portal."
                return $candidate
            }
            'notfound' { Write-Warn "v1 route not served on host '$h' (404)."; continue }
            default    { Write-Warn "Could not verify host '$h' (network/other)."; continue }
        }
    }
    $fallback = & $build $candidates[0]
    Write-Warn "Endpoint probing was inconclusive; writing '$fallback' - verify it in Zap."
    return $fallback
}

function Add-AzureProviderToSettings {
    param([string]$SettingsPath, [string]$BaseUrl)
    $begin = '# >>> zap-setup azure provider >>>'
    $end   = '# <<< zap-setup azure provider <<<'

    # Multi-line inline-table array form Zap's own serializer writes (keys
    # alphabetical, trailing commas) so the first in-app save makes no diff.
    $providerBlock = @"
$begin
[agents.warp_agent]
providers = [
  {
    api_type = "open_ai",
    base_url = "$BaseUrl",
    id = "$AzureProviderId",
    kind = "open_ai_compatible",
    models = [
      {
        audio = false,
        context_window = 400000,
        id = "gpt-5.4-mini",
        image = true,
        max_output_tokens = 128000,
        name = "GPT-5.4 Mini",
        pdf = true,
        reasoning = true,
      },
    ],
    name = "Azure OpenAI",
  },
]
$end
"@

    $content = ''
    if (Test-Path -LiteralPath $SettingsPath) { $content = [System.IO.File]::ReadAllText($SettingsPath) }
    $pattern = [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    $content = [regex]::Replace($content, $pattern, '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $content = $content.TrimEnd("`r", "`n")
    Write-FileUtf8NoBom -Path $SettingsPath -Content ($content + "`r`n`r`n" + $providerBlock + "`r`n")
    Write-Log "Injected Azure provider into settings.toml"
}

function Write-AzureKeyToDpapi {
    param([string]$Key)
    # Windows PowerShell 5.1 needs System.Security loaded for ProtectedData;
    # on PowerShell 7+ the type ships in a separate, already-available assembly
    # and this name may not resolve - tolerate that and rely on the type below.
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
    $dir = Split-Path -Parent $SecretsFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Read-merge the existing map so other providers' keys are not clobbered
    # (mirrors the Linux Phase 4 jq merge).
    $map = @{}
    if (Test-Path -LiteralPath $SecretsFile) {
        try {
            $enc = [System.IO.File]::ReadAllBytes($SecretsFile)
            $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $obj = [System.Text.Encoding]::UTF8.GetString($dec) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
        } catch {
            Write-Warn "Existing secrets file could not be read; it will be replaced. ($($_.Exception.Message))"
            $map = @{}
        }
    }
    $map[$AzureProviderId] = $Key

    $json = $map | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    # CurrentUser scope + null entropy = exactly what Zap's CryptProtectData uses.
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($SecretsFile, $protected)
    Write-Log "Wrote API key to the DPAPI store: $SecretsFile"
}

function Invoke-AzureOptIn {
    # Returns $true if Azure was configured, else $false.
    $envEndpoint = $env:ZAP_AZURE_ENDPOINT
    $envKey      = $env:ZAP_AZURE_API_KEY
    $endpoint = $null; $key = $null

    if ($envKey) {
        if (-not $envEndpoint) {
            Write-Warn "ZAP_AZURE_API_KEY is set but ZAP_AZURE_ENDPOINT is not - skipping Azure setup."
            return $false
        }
        $endpoint = $envEndpoint; $key = $envKey
        Write-Log "Using Azure endpoint/key from environment variables."
    }
    elseif ($script:ZapNoMode) { return $false }
    elseif ($script:ZapForceMode) {
        Write-Warn "Force mode without ZAP_AZURE_ENDPOINT/ZAP_AZURE_API_KEY - skipping Azure provider setup."
        return $false
    }
    elseif (-not [Environment]::UserInteractive) { return $false }
    else {
        if (-not (Confirm-YesNo "Pre-configure Azure as the AI provider?" 'N')) { return $false }
        $endpoint = Read-DialogText -Title 'Azure endpoint' `
            -Prompt 'Paste your Azure resource endpoint (e.g. https://my-resource.cognitiveservices.azure.com/):'
        if ([string]::IsNullOrWhiteSpace($endpoint)) { Write-Warn "No endpoint entered - skipping Azure setup."; return $false }
        $key = Read-DialogSecret -Title 'Azure API key' -Prompt 'Paste your Azure OpenAI API key:'
        if ([string]::IsNullOrWhiteSpace($key)) { Write-Warn "No API key entered - skipping Azure setup."; return $false }
    }

    $baseUrl = Resolve-AzureBaseUrl -Endpoint $endpoint -Key $key
    Add-AzureProviderToSettings -SettingsPath (Join-Path $ConfigDir 'settings.toml') -BaseUrl $baseUrl
    Write-AzureKeyToDpapi -Key $key
    $script:AzureBaseUrl = $baseUrl
    return $true
}

function Add-ClaudeMarketplace {
    # Zap is a Warp OSS fork, and warpdotdev/claude-code-warp ships the 'warp'
    # plugin that wires Claude Code into the terminal. When the 'claude' CLI is
    # on PATH we register the marketplace and install the plugin via claude's
    # own command line. claude enforces any managed strictKnownMarketplaces
    # policy itself and exits non-zero when a foreign marketplace is prohibited,
    # so each call is wrapped to swallow that failure (PowerShell 7 turns a
    # native non-zero exit into a terminating error under
    # ErrorActionPreference='Stop', hence the try/catch + $LASTEXITCODE check -
    # the same 5.1-safe idiom Phase 0 uses). Re-running is safe: 'marketplace
    # add' replaces the same-named entry and 'install' is a no-op when the
    # plugin is already installed.
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
    Write-Log "Detected claude CLI - registering the claude-code-warp plugin marketplace"

    $marketAdded = $false
    try {
        & claude plugin marketplace add warpdotdev/claude-code-warp
        if ($LASTEXITCODE -eq 0) { $marketAdded = $true }
    } catch { }
    if (-not $marketAdded) {
        Write-Warn "Could not add the claude-code-warp marketplace (a managed claude policy may prohibit foreign marketplaces) - skipping"
        return
    }

    $pluginInstalled = $false
    try {
        & claude plugin install warp@claude-code-warp
        if ($LASTEXITCODE -eq 0) { $pluginInstalled = $true }
    } catch { }
    if ($pluginInstalled) {
        Write-Log "Installed the warp plugin (warp@claude-code-warp)"
    } else {
        Write-Warn "Added the marketplace but installing warp@claude-code-warp failed - install it later with /plugin"
    }
}

#############################################################################
# PHASE 0: Self-update (mirror of setup.sh:104-132)
#############################################################################

Write-Log "Checking for script updates..."
if (Get-Command git -ErrorAction SilentlyContinue) {
    Push-Location $PSScriptRoot
    try {
        git rev-parse --git-dir 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Git repository detected, checking for updates..."
            git fetch origin 2>$null
            $behind = @(git rev-list 'HEAD..@{u}' 2>$null).Count
            if ($behind -gt 0) {
                Write-Log "Updates found! Pulling latest changes..."
                git pull --ff-only
                # Don't re-exec on a failed pull - that would loop (still behind).
                if ($LASTEXITCODE -ne 0) { Write-Err "git pull --ff-only failed; resolve manually and re-run." }
                Write-Log "Re-executing updated script..."
                & $PSCommandPath @OriginalArgs
                exit $LASTEXITCODE
            } else {
                Write-Log "Script is up to date"
            }
        } else {
            Write-Warn "Not running from a git repository. Self-update disabled."
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Warn "git not found on PATH. Self-update disabled."
}

#############################################################################
# PHASE 1: Preflight
#############################################################################

# ConPTY requires Windows 10 build 18362+ (matches the Inno installer MinVersion).
$build = [int][System.Environment]::OSVersion.Version.Build
if ($build -lt 18362) {
    Write-Err "Zap requires Windows 10 build 18362 or newer (ConPTY). Detected build: $build"
}
$principal = New-Object System.Security.Principal.WindowsPrincipal(
    [System.Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn "Running elevated. A per-user install does not need admin; consider a normal user."
}

#############################################################################
# PHASE 2: Install Zap from latest GitHub ZapSetup.exe
#############################################################################

Install-Zap

#############################################################################
# PHASE 3: Configure Zap (settings, keybindings, MCP)
#############################################################################

Write-Log "Configuring Zap..."
New-Item -ItemType Directory -Path $ConfigDir  -Force | Out-Null
New-Item -ItemType Directory -Path $ZapHomeDir -Force | Out-Null

# The Windows settings.toml has no home-relative tokens, so no transform.
Install-WithPrompt -Src (Join-Path $ConfigsDir 'settings.toml') `
    -Dst (Join-Path $ConfigDir 'settings.toml') -Label 'settings (theme + shell + graphics)'
Install-WithPrompt -Src (Join-Path $ConfigsDir 'keybindings.yaml') `
    -Dst (Join-Path $ConfigDir 'keybindings.yaml') -Label 'keybindings'
Install-WithPrompt -Src (Join-Path $ConfigsDir 'mcp.json') `
    -Dst (Join-Path $ZapHomeDir '.mcp.json') -Label 'MCP servers (microsoft-learn, deepwiki)'

#############################################################################
# PHASE 4: bash-style Ctrl+D handler for PowerShell
#############################################################################

Set-CtrlDHandlers

#############################################################################
# PHASE 5: Optional Azure provider + DPAPI key write
#############################################################################

$script:AzureBaseUrl = $null
$azureConfigured = Invoke-AzureOptIn

#############################################################################
# PHASE 6: Register the Warp/Zap Claude Code plugin marketplace (if claude present)
#############################################################################

Add-ClaudeMarketplace

#############################################################################
# Done
#############################################################################

Write-Host ''
Write-Log "Zap setup complete."
if ($azureConfigured) {
    $keyStep = "Azure OpenAI is configured and its API key is already in the DPAPI store ($($script:AzureBaseUrl)) - no UI paste needed."
} else {
    $keyStep = 'No AI provider was configured. Add one via Settings -> AI -> Agent Providers (or re-run and accept the Azure prompt, or set ZAP_AZURE_ENDPOINT/ZAP_AZURE_API_KEY).'
}

@"

Next steps:
  1. Launch Zap from the Start menu (or run: zap-oss).
  2. $keyStep
  3. Settings -> Appearance shows the Dracula theme; new tabs open Windows PowerShell.
  4. Restart your PowerShell session (or run: . `$PROFILE) so the Ctrl+D handler
     loads, then press Ctrl+D on an empty prompt to close the pane.
  5. The microsoft-learn and deepwiki MCP servers are registered in
     $ZapHomeDir\.mcp.json (confirm both appear in the agent panel; if missing,
     check that `$env:WARP_DATA_PROFILE is unset - it changes the dir Zap reads).
"@ | Write-Host
