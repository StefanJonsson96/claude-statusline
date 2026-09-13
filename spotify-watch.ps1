# Background Spotify watcher for the status line. Runs in Windows PowerShell 5.1 (WinRT access),
# writes the now-playing state to %TEMP%\claude-spotify.txt, and exits once the status line has not
# run for 30 seconds (Claude Code closed).
# Uses .NET calls only, so it works even when launched from pwsh 7 with its module path.

$mutex = [Threading.Mutex]::new($false, 'Local\claude-spotify-watch')
if (-not $mutex.WaitOne(0)) { exit }

[void][Reflection.Assembly]::Load('System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
$asTask = $null
foreach ($m in [System.WindowsRuntimeSystemExtensions].GetMethods()) {
    if ($m.Name -eq 'AsTask' -and $m.GetParameters().Count -eq 1 -and $m.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1') { $asTask = $m; break }
}
function Await($op, [type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    if ($task.Wait(2000)) { $task.Result } else { throw 'WinRT call timed out' }
}

$managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$propsType   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]

$cache    = [IO.Path]::Combine($env:TEMP, 'claude-spotify.txt')
$previous = $null

$alive = [IO.Path]::Combine($env:TEMP, 'claude-spotify.alive')

while (([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($alive)).TotalSeconds -lt 30) {
    $state = ''
    try {
        # A fresh manager each tick: a long-lived one keeps serving the track it first saw
        $manager = Await ($managerType::RequestAsync()) $managerType
        foreach ($session in $manager.GetSessions()) {
            if ($session.SourceAppUserModelId -notlike '*Spotify*') { continue }
            $props    = Await ($session.TryGetMediaPropertiesAsync()) $propsType
            $timeline = $session.GetTimelineProperties()
            if (-not $props.Title) { break }
            $state = (@(
                $session.GetPlaybackInfo().PlaybackStatus
                $props.Artist
                $props.Title
                [long]$timeline.Position.TotalMilliseconds
                [long]$timeline.EndTime.TotalMilliseconds
                $timeline.LastUpdatedTime.ToUnixTimeMilliseconds()
            ) | ForEach-Object { "$_" -replace '[\r\n]', ' ' }) -join "`n"
            break
        }
    } catch { $state = '' }

    if ($state -ne $previous) {
        $tmp = "$cache.tmp"
        [IO.File]::WriteAllText($tmp, $state)
        if ([IO.File]::Exists($cache)) { [IO.File]::Replace($tmp, $cache, [NullString]::Value) } else { [IO.File]::Move($tmp, $cache) }
        $previous = $state
    }
    [Threading.Thread]::Sleep(250)
}
