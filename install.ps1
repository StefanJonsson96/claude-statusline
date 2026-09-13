#Requires -Version 7
<#
.SYNOPSIS
    Installs the Claude Code status line from this folder.
.DESCRIPTION
    1. Installs fonts/StatuslineIcons.ttf for the current user (no admin needed).
    2. Points the statusLine setting in Claude Code's settings.json at statusline.ps1 in this folder.
    3. Adds "Statusline Icons" as a fallback font to the Windows Terminal default profile.
    Every settings file is backed up next to itself before it is changed. Safe to run again.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ClaudeSettings = (Join-Path $HOME '.claude/settings.json'),
    [string[]]$TerminalSettings = @(
        "$env:LOCALAPPDATA/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
        "$env:LOCALAPPDATA/Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json"
        "$env:LOCALAPPDATA/Microsoft/Windows Terminal/settings.json"
    )
)
$ErrorActionPreference = 'Stop'
$fontFamily = 'Statusline Icons'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Backup([string]$path) {
    if ((Test-Path $path) -and $PSCmdlet.ShouldProcess($path, 'Back up')) {
        Copy-Item $path "$path.bak-$stamp"
        Write-Host "  backup: $path.bak-$stamp"
    }
}

function Save-Json($object, [string]$path) {
    if ($PSCmdlet.ShouldProcess($path, 'Write settings')) {
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        $object | ConvertTo-Json -Depth 64 | Set-Content $path -Encoding utf8NoBOM
    }
}

# 1. Icon font, per user
Write-Host "Font: $fontFamily"
$fontSource = Join-Path $PSScriptRoot 'fonts/StatuslineIcons.ttf'
$fontDir    = Join-Path $env:LOCALAPPDATA 'Microsoft/Windows/Fonts'
$fontTarget = Join-Path $fontDir 'StatuslineIcons.ttf'
if ((Test-Path $fontTarget) -and (Get-FileHash $fontTarget).Hash -eq (Get-FileHash $fontSource).Hash) {
    Write-Host '  already installed'
}
elseif ($PSCmdlet.ShouldProcess($fontTarget, 'Install font')) {
    New-Item -ItemType Directory -Force $fontDir | Out-Null
    Copy-Item $fontSource $fontTarget -Force
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -Name "$fontFamily (TrueType)" -Value $fontTarget -PropertyType String -Force | Out-Null
    Add-Type -Namespace StatuslineInstall -Name Native -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
'@
    [void][StatuslineInstall.Native]::AddFontResource($fontTarget)
    $result = [UIntPtr]::Zero
    [void][StatuslineInstall.Native]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$result)
    Write-Host "  installed: $fontTarget"
}

# 2. Claude Code statusLine setting
Write-Host "Claude Code: $ClaudeSettings"
$settings = if ((Test-Path $ClaudeSettings) -and (Get-Content $ClaudeSettings -Raw).Trim()) {
    Get-Content $ClaudeSettings -Raw | ConvertFrom-Json -AsHashtable
} else { [ordered]@{} }
$script = (Join-Path $PSScriptRoot 'statusline.ps1') -replace '\\', '/'
$statusLine = [ordered]@{
    type            = 'command'
    command         = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$script`""
    # Each run takes about half a second (pwsh startup); 1 second leaves no headroom under load
    refreshInterval = 2
}
if ($settings['statusLine']) { Write-Host "  replacing: $($settings['statusLine'] | ConvertTo-Json -Compress)" }
Backup $ClaudeSettings
$settings['statusLine'] = $statusLine
Save-Json $settings $ClaudeSettings
Write-Host "  statusLine -> $script"

# 3. Windows Terminal fallback font
$terminals = @($TerminalSettings | Where-Object { Test-Path $_ })
if (-not $terminals) { Write-Warning "Windows Terminal settings not found. Add '$fontFamily' to your terminal font list yourself." }
foreach ($path in $terminals) {
    Write-Host "Windows Terminal: $path"
    $terminal = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
    if ($terminal['profiles'] -isnot [System.Collections.IDictionary]) {
        Write-Warning "  unexpected profiles layout; add '$fontFamily' to the font face yourself"
        continue
    }
    if (-not $terminal['profiles']['defaults']) { $terminal['profiles']['defaults'] = [ordered]@{} }
    $defaults = $terminal['profiles']['defaults']
    if (-not $defaults['font']) { $defaults['font'] = [ordered]@{} }
    $face = if ($defaults['font']['face']) { $defaults['font']['face'] } else { 'Cascadia Mono' }
    if ($face -match [regex]::Escape($fontFamily)) { Write-Host "  already set: $face"; continue }
    if ($face -notmatch 'Nerd Font') {
        Write-Warning "  default font '$face' is not a Nerd Font; the branch and pause icons need one (see README)"
    }
    Backup $path
    $defaults['font']['face'] = "$face, $fontFamily"
    Save-Json $terminal $path
    Write-Host "  font face -> $face, $fontFamily"
}

Write-Host "`nDone. Restart Windows Terminal so it picks up the new font."
