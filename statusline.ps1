# Claude Code status line (PowerShell 7). Reads session JSON on stdin, prints session info plus a Spotify line.
[Console]::InputEncoding  = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$data = [Console]::In.ReadToEnd() | ConvertFrom-Json

$segments = [System.Collections.Generic.List[string]]::new()

# "23% (2h13m)" for a rate-limit window, "88% (3d11h)" once a day or more is left
function Format-Limit($window) {
    $text = "$([math]::Round($window.used_percentage))%"
    if ($window.resets_at) {
        $left = [DateTimeOffset]::FromUnixTimeSeconds([long]$window.resets_at) - [DateTimeOffset]::UtcNow
        if ($left -lt [TimeSpan]::Zero) { $left = [TimeSpan]::Zero }
        $text += if ($left.TotalHours -ge 24) { " ({0}d{1}h)" -f $left.Days, $left.Hours }
                 else { " ({0}h{1:00}m)" -f $left.Hours, $left.Minutes }
    }
    $text
}

# Current folder
$cwd = if ($data.workspace.current_dir) { $data.workspace.current_dir } else { $data.cwd }
if ($cwd) { $segments.Add("`u{1F4C1} $(Split-Path $cwd -Leaf)") }

# Git branch + ahead/behind/in sync
if ($cwd -and (Test-Path $cwd)) {
    $status = git -C $cwd --no-optional-locks status --porcelain=v2 --branch --untracked-files=no 2>$null
    if ($LASTEXITCODE -eq 0 -and $status) {
        $head = ($status | Where-Object { $_ -like '# branch.head *' }) -replace '^# branch.head ', ''
        if ($head -eq '(detached)') { $head = (git -C $cwd rev-parse --short HEAD 2>$null) }
        $git = "`u{E0A0} $head"

        $ab = $status | Where-Object { $_ -like '# branch.ab *' }
        if ($ab -match '\+(\d+) -(\d+)') {
            $ahead, $behind = [int]$Matches[1], [int]$Matches[2]
            $git += ' ' + $(if ($ahead -eq 0 -and $behind -eq 0) { "`u{2261}" } else {
                (@(
                    if ($ahead)  { "`u{2191}$ahead" }
                    if ($behind) { "`u{2193}$behind" }
                ) -join ' ')
            })
        }
        $segments.Add($git)
    }
}

# Azure subscription (read from the az CLI profile, no az call)
$azProfile = Join-Path $HOME '.azure/azureProfile.json'
if (Test-Path $azProfile) {
    $sub = (Get-Content $azProfile -Raw | ConvertFrom-Json).subscriptions | Where-Object isDefault | Select-Object -First 1
    if ($sub) { $segments.Add("`u{2601}`u{FE0F} $($sub.name)") }
}

# Timestamp of last assistant output (from the transcript tail)
$last = $null
if ($data.transcript_path -and (Test-Path $data.transcript_path)) {
    $tail = Get-Content $data.transcript_path -Tail 50
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        if ($tail[$i] -match '"type":"assistant"' -and $tail[$i] -match '"timestamp":"([^"]+)"') {
            $last = ([datetime]::Parse($Matches[1], $null, 'RoundtripKind')).ToLocalTime()
            break
        }
    }
}
if (-not $last) { $last = Get-Date }
$segments.Add("`u{1F550} $($last.ToString('HH:mm:ss'))")

# Context window %
$ctx = $data.context_window.used_percentage
if ($null -ne $ctx) { $segments.Add("`u{1F9E0} ctx: $([math]::Round($ctx))%") }

# 5-hour and 7-day usage % with time until reset
$five = $data.rate_limits.five_hour
if ($null -ne $five.used_percentage) { $segments.Add("`u{1F50B} 5h: $(Format-Limit $five)") }
$week = $data.rate_limits.seven_day
if ($null -ne $week.used_percentage) { $segments.Add("`u{1F4CA} 7d: $(Format-Limit $week)") }

# Resume command
if ($data.session_id) { $segments.Add("`u{1F504} cc -r $($data.session_id)") }

# Spotify now playing (state comes from spotify-watch.ps1, started here when it isn't running)
$watcher = $null
$spotify = $null
$nowPlaying = $null
# Heartbeat: the watcher exits once this file stops being touched (Claude Code closed)
try { [IO.File]::WriteAllBytes((Join-Path $env:TEMP 'claude-spotify.alive'), [byte[]]@()) } catch { }
if ([Threading.Mutex]::TryOpenExisting('Local\claude-spotify-watch', [ref]$watcher)) {
    $watcher.Dispose()
    try { $spotify = [IO.File]::ReadAllText((Join-Path $env:TEMP 'claude-spotify.txt')) -split "`n" } catch { }
}
else {
    # No watcher means the cache is left over from an earlier run; skip it until the new watcher writes
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'spotify-watch.ps1')`""
}
if ($spotify.Count -ge 6) {
    $status, $artist, $title = $spotify[0..2]
    $position, $length, $updated = [long]$spotify[3], [long]$spotify[4], [long]$spotify[5]
    if ($status -eq 'Playing') { $position += [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $updated }
    $position = [math]::Min($position, $length)
    $clock = { param($ms) $t = [TimeSpan]::FromMilliseconds($ms); '{0}:{1:00}' -f [math]::Floor($t.TotalMinutes), $t.Seconds }
    # U+E100 is the Spotify logo from fonts/StatuslineIcons.ttf (Nerd Font U+F1BC nudged to line up with the folder emoji)
    $nowPlaying = "`e[38;2;30;215;96m`u{E100}`e[0m  $artist - $title $(& $clock $position)/$(& $clock $length)$(if ($status -eq 'Paused') { " `u{F04C}" })"
    # Remote device that plays it; the watcher leaves this empty while this PC plays
    if ($spotify.Count -ge 7 -and $spotify[6]) { $nowPlaying += "  `u{F028}  $($spotify[6])" }
}

# Line 1: session info. Line 2: Spotify, on its own row so long titles have room.
Write-Output ($segments -join '  ')
if ($nowPlaying) { Write-Output $nowPlaying }
