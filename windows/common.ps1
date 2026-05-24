#
# Shared utility functions for zap-setup (Windows / PowerShell port).
#
# Usage:  . "$PSScriptRoot\common.ps1"
#
# This mirrors linux/common.sh (log / warn / error, backup_file,
# prompt_yes_no, install_with_prompt). The Linux helpers are themselves
# verbatim lifts from /opt/linux-setup/linux-setup.sh; keep the two ports
# behaviourally in lockstep - same prompts, same default-No, same timestamped
# backups, same Force/No mode semantics.

# Source guard - prevent double dot-sourcing.
if ($script:ZapCommonSourced) { return }
$script:ZapCommonSourced = $true

# Mode flags are owned by setup.ps1's arg parser; default here so the helpers
# work even if common.ps1 is dot-sourced standalone. setup.ps1 sets these to
# $true for --force / --no. Dot-sourcing runs in the caller's scope, so these
# script-scoped vars are shared with setup.ps1.
if (-not (Test-Path 'variable:script:ZapForceMode')) { $script:ZapForceMode = $false }
if (-not (Test-Path 'variable:script:ZapNoMode'))    { $script:ZapNoMode    = $false }

#############################################################################
# Logging (mirror of common.sh log/warn/error)
#############################################################################

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Err {
    # Mirrors bash error(): print red and terminate the whole script.
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

#############################################################################
# Backup a file with timestamp (mirror of common.sh backup_file)
#############################################################################

function Backup-File {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "{0}.backup.{1}" -f $Path, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Write-Log "Backed up to: $backup"
    }
}

#############################################################################
# Prompt user with yes/no question (mirror of common.sh prompt_yes_no)
# Returns $true for yes, $false for no.
#############################################################################

function Confirm-YesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('Y', 'N')][string]$Default = 'N'
    )

    if ($script:ZapForceMode) {
        Write-Log "Force mode: Auto-answering 'Yes' to: $Prompt"
        return $true
    }
    if ($script:ZapNoMode) {
        Write-Log "No mode: Auto-answering 'No' to: $Prompt"
        return $false
    }

    $suffix = if ($Default -eq 'Y') { '(Y/n)' } else { '(y/N)' }
    $response = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($response)) { $response = $Default }
    return ($response -match '^[Yy]')
}

#############################################################################
# Write text as UTF-8 WITHOUT a BOM.
#############################################################################
# Zap reads config as UTF-8 and re-serializes on save; a BOM would be treated
# as content and provoke a rewrite-diff. PowerShell 5.1's Out-File/Set-Content
# emit a BOM for UTF-8, so go through .NET directly.

function Write-FileUtf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

#############################################################################
# Deploy a config file with an overwrite prompt (mirror of install_with_prompt)
# Usage: Install-WithPrompt -Src S -Dst D -Label L [-Transform { param($t) ... }]
#############################################################################
# Prompts before overwriting (default No), creates a timestamped backup, then
# writes Src -> Dst (UTF-8 no BOM). The optional -Transform scriptblock is the
# render_settings analogue: it receives the file text and returns the text to
# write.

function Install-WithPrompt {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Dst,
        [Parameter(Mandatory)][string]$Label,
        [scriptblock]$Transform
    )

    if (Test-Path -LiteralPath $Dst -PathType Leaf) {
        if (Confirm-YesNo "Overwrite existing $Label at $Dst?" 'N') {
            Backup-File $Dst
        } else {
            Write-Log "Keeping existing $Label"
            return
        }
    }

    $content = [System.IO.File]::ReadAllText($Src)
    if ($Transform) { $content = & $Transform $content }
    Write-FileUtf8NoBom -Path $Dst -Content $content
    Write-Log "Installed ${Label}: $Dst"
}
