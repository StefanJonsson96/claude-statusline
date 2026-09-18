# Background Spotify watcher for the status line. Runs in Windows PowerShell 5.1 (WinRT access),
# writes the now-playing state to %TEMP%\claude-spotify.txt, and exits once the status line has not
# run for 30 seconds (Claude Code closed).
# Uses .NET calls only, so it works even when launched from pwsh 7 with its module path.

$mutex = [Threading.Mutex]::new($false, 'Local\claude-spotify-watch')
if (-not $mutex.WaitOne(0)) { exit }

[void][Reflection.Assembly]::Load('System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
[void][Reflection.Assembly]::Load('UIAutomationClient, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35')
[void][Reflection.Assembly]::Load('UIAutomationTypes, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35')
$asTask = $null
foreach ($m in [System.WindowsRuntimeSystemExtensions].GetMethods()) {
    if ($m.Name -eq 'AsTask' -and $m.GetParameters().Count -eq 1 -and $m.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1') { $asTask = $m; break }
}
$pending = $null
function Await($op, [type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    if ($task.Wait(2000)) { return $task.Result }
    $script:pending = $task
    throw 'WinRT call timed out'
}

# Core Audio: is any Spotify process sending sound to an output device on this PC?
$audioSource = @'
using System;
using System.Runtime.InteropServices;

public static class SpotifyAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices); }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { [PreserveSig] int GetCount(out int count); [PreserveSig] int Item(int index, out IMMDevice device); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface); }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 { int NotImpl1(); int NotImpl2(); [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions); }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator { [PreserveSig] int GetCount(out int count); [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session); }
    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        int GetDisplayName(); int SetDisplayName(); int GetIconPath(); int SetIconPath(); int GetGroupingParam();
        int SetGroupingParam(); int RegisterNotification(); int UnregisterNotification(); int GetSessionIdentifier(); int GetSessionInstanceIdentifier();
        [PreserveSig] int GetProcessId(out uint pid);
    }

    public static bool IsPlaying(int[] pids) {
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection devices;
        enumerator.EnumAudioEndpoints(0 /* render */, 1 /* active */, out devices);
        int deviceCount; devices.GetCount(out deviceCount);
        Guid iid = typeof(IAudioSessionManager2).GUID;
        for (int d = 0; d < deviceCount; d++) {
            IMMDevice device; devices.Item(d, out device);
            object manager; device.Activate(ref iid, 23, IntPtr.Zero, out manager);
            IAudioSessionEnumerator sessions; ((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions);
            int sessionCount; sessions.GetCount(out sessionCount);
            for (int s = 0; s < sessionCount; s++) {
                IAudioSessionControl2 session; sessions.GetSession(s, out session);
                uint pid; session.GetProcessId(out pid);
                int state; session.GetState(out state);
                if (state == 1 /* active */ && Array.IndexOf(pids, (int)pid) >= 0) return true;
            }
        }
        return false;
    }
}
'@
$compiler = [System.CodeDom.Compiler.CompilerParameters]::new()
$compiler.GenerateInMemory = $true
$audio = [Microsoft.CSharp.CSharpCodeProvider]::new().CompileAssemblyFromSource($compiler, $audioSource).CompiledAssembly.GetType('SpotifyAudio')

# Playing on another device: the Spotify window shows "Playing on <device>".
# Non-English prefixes build the a-ring from its code so this file stays ASCII (PS 5.1 reads it as ANSI).
$aRing = [char]0xE5
$devicePattern = "^(?:Playing on|Listening on|Spelas upp p$aRing|Lyssnar p$aRing)\s+(.+)$"
function Find-RemoteDevice {
    foreach ($process in [Diagnostics.Process]::GetProcessesByName('Spotify')) {
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) { continue }
        $root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        foreach ($element in $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
            if ($element.Current.Name -match $devicePattern) { return $element }
        }
    }
}

$managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$propsType   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]

$cache    = [IO.Path]::Combine($env:TEMP, 'claude-spotify.txt')
$alive    = [IO.Path]::Combine($env:TEMP, 'claude-spotify.alive')
$previous = $null
$device   = ''
$deviceElement = $null
$nextDeviceSearch = [DateTime]::MinValue
$tick     = 0

while (([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($alive)).TotalSeconds -lt 30) {
    $state = ''
    try {
        if ($pending -and -not $pending.IsCompleted) { throw 'previous WinRT call still pending' }
        $pending = $null
        # A fresh manager each tick: a long-lived one keeps serving the track it first saw
        $manager = Await ($managerType::RequestAsync()) $managerType
        foreach ($session in $manager.GetSessions()) {
            if ($session.SourceAppUserModelId -notlike '*Spotify*') { continue }
            $props    = Await ($session.TryGetMediaPropertiesAsync()) $propsType
            $timeline = $session.GetTimelineProperties()
            if (-not $props.Title) { break }
            $status = $session.GetPlaybackInfo().PlaybackStatus

            # Remote device name, empty while this PC plays it. Paused: no sound anywhere, so keep the last value.
            # Checked once a second (every 4th tick) to keep CPU low.
            if (($tick++ % 4) -eq 0) {
                $pids = [int[]]@([Diagnostics.Process]::GetProcessesByName('Spotify') | ForEach-Object { $_.Id })
                if ($audio::IsPlaying($pids)) {
                    $device = ''
                    $deviceElement = $null
                }
                elseif ("$status" -eq 'Playing') {
                    $name = $null
                    if ($deviceElement) { try { $name = $deviceElement.Current.Name } catch { $deviceElement = $null } }
                    if ($name -notmatch $devicePattern -and [DateTime]::UtcNow -ge $nextDeviceSearch) {
                        $nextDeviceSearch = [DateTime]::UtcNow.AddSeconds(5)
                        $deviceElement = Find-RemoteDevice
                        if ($deviceElement) { $name = $deviceElement.Current.Name }
                    }
                    if ($name -match $devicePattern) { $device = $Matches[1] }
                }
            }

            $state = (@(
                $status
                $props.Artist
                $props.Title
                [long]$timeline.Position.TotalMilliseconds
                [long]$timeline.EndTime.TotalMilliseconds
                $timeline.LastUpdatedTime.ToUnixTimeMilliseconds()
                $device
            ) | ForEach-Object { "$_" -replace '[\r\n]', ' ' }) -join "`n"
            break
        }
    } catch { $state = '' }

    if ($state -ne $previous) {
        try {
            $tmp = "$cache.tmp"
            [IO.File]::WriteAllText($tmp, $state)
            if ([IO.File]::Exists($cache)) { [IO.File]::Replace($tmp, $cache, [NullString]::Value) } else { [IO.File]::Move($tmp, $cache) }
            $previous = $state
        } catch { }
    }
    [Threading.Thread]::Sleep(250)
}
