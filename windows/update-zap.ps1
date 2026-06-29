<#
.SYNOPSIS
    Update the Zap terminal to the latest GitHub release, but only if newer.

.DESCRIPTION
    Checks github.com/zerx-lab/zap for the newest ZapSetup.exe release and runs
    its silent per-user installer only when it is newer than what is installed.
    When Zap is already current it logs a message and exits without changes.

    Self-contained on purpose: the installed copy (under
    %LOCALAPPDATA%\zap-setup\bin) must work even after the cloned zap-setup repo
    is gone, so it does NOT dot-source common.ps1. The GitHub release walk, asset
    filter, version short-circuit and the spawned-window close dance below are
    deliberately COPIED from Install-Zap (and its helpers) in setup.ps1 - keep
    the two in sync. See CLAUDE.md ("Install mechanism" / "Release-asset filter").

.PARAMETER Help
    Show usage and exit. (Alias: -h)

.NOTES
    Pure ASCII, no BOM (CLAUDE.md "windows/*.ps1 must be pure ASCII"). The
    asset regex must stay byte-identical to setup.ps1's $AssetRegex.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'
# Avoid PS 5.1's slow Invoke-WebRequest progress bar on big downloads.
$ProgressPreference = 'SilentlyContinue'
# GitHub requires TLS 1.2; PS 5.1 on older Windows may not enable it.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Show-Usage {
    @"
update-zap - update Zap to the latest GitHub release (only if newer)

Usage: update-zap [-Help]

Checks github.com/zerx-lab/zap for the newest ZapSetup.exe release and installs
it silently (per-user, no admin) only when it is newer than the installed
version. When Zap is already current it prints a message and exits.

Options:
  -Help, -h   Show this help and exit
"@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }

# --- Minimal logging (mirrors common.ps1; copied so this stays standalone) ---
function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -ForegroundColor Green
}
function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}
function Write-Err {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

#############################################################################
# Constants - Zap Windows layout (copied from setup.ps1; keep in sync).
#############################################################################

$Repo             = 'zerx-lab/zap'
# Pin to the renamed asset; older releases shipped OpenWarpSetup.exe.
# MUST stay byte-identical to setup.ps1's $AssetRegex.
$AssetRegex       = '^ZapSetup\.exe$'
# Inno Setup AppId for the OSS channel -> per-user uninstall key (DisplayVersion).
$UninstallKeyName = 'zap-oss_is1'
$UninstallRegKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$UninstallKeyName",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$UninstallKeyName",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$UninstallKeyName"
)

#############################################################################
# Install helpers - copied from setup.ps1 (keep in sync).
#############################################################################

function Get-InstalledZapVersion {
    foreach ($k in $UninstallRegKeys) {
        try {
            $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).DisplayVersion
            if ($v) { return [string]$v }
        } catch { }
    }
    return $null
}

function Get-ZapInstallDir {
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
    # AFTER $After and is either named like 'zap' OR lives under the install dir.
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

function Update-Zap {
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
    Write-Log "Updating Zap $($rel.Version) (was: $was)"

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ZapSetup-{0}.exe" -f ([guid]::NewGuid().ToString('N')))
    try {
        Write-Log "Downloading $($rel.Url)"
        Invoke-WebRequest -Uri $rel.Url -OutFile $tmp -UseBasicParsing
        Write-Log "Running silent install (per-user, no admin needed)..."
        # Zap's Inno [Run] entry launches the app on completion WITHOUT
        # 'skipifsilent', so /VERYSILENT still opens Zap. Start without waiting and
        # keep closing the spawned window both WHILE the installer is alive and for
        # a short grace window after it exits (catches a detached launch).
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
            Write-Warn "Installer did not exit within 5 min; ending its wait (Zap is already installed)."
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $proc.WaitForExit(10000) | Out-Null
        }
        # Grace window for the detached-launch case.
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
        # made the process report a non-zero code.
        $exit = $null
        try { if ($proc.HasExited) { $exit = $proc.ExitCode } } catch { }
        if (-not (Get-InstalledZapVersion)) {
            $detail = if ($null -ne $exit) { "exit code $exit" } else { "no exit code available" }
            Write-Err "Zap did not register an install ($detail)."
        }
        Write-Log "Zap updated to $($rel.Version)."
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

Update-Zap
