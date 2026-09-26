#:property TargetFramework=net10.0-windows10.0.19041.0
#:property UseWPF=true
#:property PublishAot=false
#:package System.ServiceProcess.ServiceController@10.0.0

// Background Spotify watcher for the status line, run with `dotnet run spotify-watch.cs`.
// Writes the now-playing state to %TEMP%\claude-spotify.txt and exits once the status line has not
// run for 30 seconds (Claude Code closed). Logs its health once a minute to %TEMP%\claude-spotify-watch.log.
//
// Windows calls that reach other processes (the media service, Spotify) run as tasks the main loop only
// checks on: when one hangs, the watcher waits for it instead of piling more calls on top.

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Automation;
using Windows.Media.Control;

var temp = Path.GetTempPath();
var alivePath = Path.Combine(temp, "claude-spotify.alive");

using var mutex = new Mutex(false, @"Local\claude-spotify-watch");
try { if (!mutex.WaitOne(0)) return; }
catch (AbandonedMutexException) { } // previous watcher was killed; we own the mutex now

var log = new HealthLog(Path.Combine(temp, "claude-spotify-watch.log"));
var watcher = new Watcher(Path.Combine(temp, "claude-spotify.txt"));
var heartbeat = Stopwatch.StartNew();
var exitReason = "status line stopped";

// Watchdog on its own thread, so it still acts if a Windows call blocks the main loop
new Thread(() =>
{
    while (true)
    {
        Thread.Sleep(10_000);
        var threads = Process.GetCurrentProcess().Threads.Count;
        string? reason = threads > 150 ? $"{threads} threads"
            : heartbeat.Elapsed.TotalSeconds > 60 ? "main loop blocked for 60s"
            : null;
        if (reason is null) continue;
        log.Write(watcher.Counters, $"exit: {reason}");
        Environment.Exit(1);
    }
}) { IsBackground = true, Name = "watchdog" }.Start();

log.Write(watcher.Counters, "start");
while ((DateTime.UtcNow - File.GetLastWriteTimeUtc(alivePath)).TotalSeconds < 30)
{
    heartbeat.Restart();
    watcher.Tick();
    log.WriteEveryMinute(watcher.Counters);
    Thread.Sleep(250);
}
log.Write(watcher.Counters, $"exit: {exitReason}");
mutex.ReleaseMutex();

sealed class Counters
{
    public int Events, PropsCalls, SlowCalls, Errors;
    public string LastError = "";
    public DateTime? ManagerPendingSince, PropsPendingSince;
}

sealed class Watcher(string cachePath)
{
    static readonly TimeSpan Slow = TimeSpan.FromSeconds(2);
    static readonly TimeSpan Refresh = TimeSpan.FromSeconds(5);

    public Counters Counters { get; } = new();

    GlobalSystemMediaTransportControlsSessionManager? manager;
    Task<GlobalSystemMediaTransportControlsSessionManager>? managerTask;
    DateTime nextManagerTry = DateTime.MinValue;

    GlobalSystemMediaTransportControlsSession? session;
    Task<GlobalSystemMediaTransportControlsSessionMediaProperties>? propsTask;
    GlobalSystemMediaTransportControlsSessionMediaProperties? props;
    GlobalSystemMediaTransportControlsSessionPlaybackStatus status;
    GlobalSystemMediaTransportControlsSessionTimelineProperties? timeline;

    // Set from event threads, read by the main loop
    volatile bool sessionsChanged = true, propsChanged = true, stateChanged = true;
    DateTime nextRefresh = DateTime.MinValue, nextDeviceCheck = DateTime.MinValue;

    readonly DeviceFinder devices = new();
    string device = "";
    string? previous;

    public void Tick()
    {
        var state = "";
        try
        {
            if (EnsureManager())
            {
                // Events keep it current; the periodic refresh covers any event Windows drops
                if (DateTime.UtcNow >= nextRefresh)
                {
                    nextRefresh = DateTime.UtcNow + Refresh;
                    sessionsChanged = propsChanged = stateChanged = true;
                }
                if (sessionsChanged) { sessionsChanged = false; BindSession(); }
                UpdateProps();
                state = BuildState();
            }
        }
        catch (Exception e)
        {
            // Most likely the media service restarted; start over with a new manager
            Fail(e);
            Unbind();
            manager = null;
            nextManagerTry = DateTime.UtcNow + Refresh;
        }
        Write(state);
    }

    bool EnsureManager()
    {
        if (manager is not null) return true;
        if (managerTask is null)
        {
            if (DateTime.UtcNow < nextManagerTry) return false;
            managerTask = GlobalSystemMediaTransportControlsSessionManager.RequestAsync().AsTask();
            Counters.ManagerPendingSince = DateTime.UtcNow;
        }
        if (!managerTask.IsCompleted) { Track(Counters.ManagerPendingSince); return false; }

        var task = managerTask;
        managerTask = null;
        Counters.ManagerPendingSince = null;
        if (!task.IsCompletedSuccessfully) { Fail(task.Exception); nextManagerTry = DateTime.UtcNow + Refresh; return false; }
        manager = task.Result;
        manager.SessionsChanged += (_, _) => { sessionsChanged = true; Interlocked.Increment(ref Counters.Events); };
        sessionsChanged = true;
        return true;
    }

    void BindSession()
    {
        var spotify = manager!.GetSessions().FirstOrDefault(s => s.SourceAppUserModelId.Contains("Spotify", StringComparison.OrdinalIgnoreCase));
        if (spotify?.SourceAppUserModelId == session?.SourceAppUserModelId && spotify is not null) return;
        Unbind();
        session = spotify;
        if (session is null) return;
        session.MediaPropertiesChanged += OnPropsChanged;
        session.PlaybackInfoChanged += OnStateChanged;
        session.TimelinePropertiesChanged += OnStateChanged;
        propsChanged = true;
    }

    void Unbind()
    {
        if (session is not null)
        {
            try
            {
                session.MediaPropertiesChanged -= OnPropsChanged;
                session.PlaybackInfoChanged -= OnStateChanged;
                session.TimelinePropertiesChanged -= OnStateChanged;
            }
            catch { } // the session's process may be gone
        }
        session = null;
        props = null;
        timeline = null;
        propsTask = null;
        Counters.PropsPendingSince = null;
    }

    void OnPropsChanged(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs e) { propsChanged = true; Interlocked.Increment(ref Counters.Events); }
    void OnStateChanged<T>(GlobalSystemMediaTransportControlsSession s, T e) { stateChanged = true; Interlocked.Increment(ref Counters.Events); }

    void UpdateProps()
    {
        if (session is null) return;
        if (propsTask is null && propsChanged)
        {
            propsChanged = false;
            propsTask = session.TryGetMediaPropertiesAsync().AsTask();
            Counters.PropsPendingSince = DateTime.UtcNow;
            Counters.PropsCalls++;
        }
        if (propsTask is null) return;
        if (!propsTask.IsCompleted) { Track(Counters.PropsPendingSince); return; }

        if (propsTask.IsCompletedSuccessfully) props = propsTask.Result;
        else Fail(propsTask.Exception);
        propsTask = null;
        Counters.PropsPendingSince = null;
        stateChanged = true;
    }

    string BuildState()
    {
        if (session is null || string.IsNullOrEmpty(props?.Title)) return "";
        if (stateChanged || timeline is null)
        {
            stateChanged = false;
            status = session.GetPlaybackInfo().PlaybackStatus;
            timeline = session.GetTimelineProperties();
        }

        // Remote device name, empty while this PC plays it. Paused: no sound anywhere, so keep the last value.
        if (DateTime.UtcNow >= nextDeviceCheck)
        {
            nextDeviceCheck = DateTime.UtcNow.AddSeconds(1);
            if (SpotifyAudio.IsPlaying()) device = "";
            else if (status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing) device = devices.Find() ?? device;
        }

        string[] fields =
        [
            status.ToString(),
            props.Artist,
            props.Title,
            ((long)timeline.Position.TotalMilliseconds).ToString(),
            ((long)timeline.EndTime.TotalMilliseconds).ToString(),
            timeline.LastUpdatedTime.ToUnixTimeMilliseconds().ToString(),
            device,
        ];
        return string.Join('\n', fields.Select(f => f.Replace('\r', ' ').Replace('\n', ' ')));
    }

    void Write(string state)
    {
        if (state == previous) return;
        try
        {
            var tmp = cachePath + ".tmp";
            File.WriteAllText(tmp, state);
            File.Move(tmp, cachePath, overwrite: true);
            previous = state;
        }
        catch { } // the status line may be reading it; try again next tick
    }

    void Track(DateTime? since)
    {
        // Count each call once, the moment it has been pending longer than Slow
        if (since is { } s && DateTime.UtcNow - s > Slow && DateTime.UtcNow - s <= Slow + TimeSpan.FromMilliseconds(250))
            Counters.SlowCalls++;
    }

    void Fail(Exception? e)
    {
        Counters.Errors++;
        var inner = e is AggregateException a ? a.InnerException ?? a : e;
        Counters.LastError = $"{inner?.GetType().Name} 0x{inner?.HResult:X8}: {inner?.Message}".ReplaceLineEndings(" ").Trim();
    }
}

// Playing on another device: the Spotify window shows "Playing on <device>". Checked once a second while
// Spotify plays and this PC is silent; the full window search runs at most every 5 seconds.
sealed class DeviceFinder
{
    static readonly Regex Pattern = new(@"^(?:Playing on|Listening on|Spelas upp på|Lyssnar på)\s+(.+)$");
    AutomationElement? element;
    DateTime nextSearch = DateTime.MinValue;

    public string? Find()
    {
        string? name = null;
        if (element is not null) { try { name = element.Current.Name; } catch { element = null; } }
        if ((name is null || !Pattern.IsMatch(name)) && DateTime.UtcNow >= nextSearch)
        {
            nextSearch = DateTime.UtcNow.AddSeconds(5);
            element = Search();
            name = element?.Current.Name;
        }
        return name is not null && Pattern.Match(name) is { Success: true } m ? m.Groups[1].Value : null;
    }

    static AutomationElement? Search()
    {
        foreach (var process in Process.GetProcessesByName("Spotify"))
        {
            using (process)
            {
                if (process.MainWindowHandle == IntPtr.Zero) continue;
                var root = AutomationElement.FromHandle(process.MainWindowHandle);
                foreach (AutomationElement e in root.FindAll(TreeScope.Descendants, Condition.TrueCondition))
                    if (Pattern.IsMatch(e.Current.Name)) return e;
            }
        }
        return null;
    }
}

// Core Audio: is any Spotify process sending sound to an output device on this PC?
static class SpotifyAudio
{
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
    interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        int GetDisplayName(); int SetDisplayName(); int GetIconPath(); int SetIconPath(); int GetGroupingParam();
        int SetGroupingParam(); int RegisterNotification(); int UnregisterNotification(); int GetSessionIdentifier(); int GetSessionInstanceIdentifier();
        [PreserveSig] int GetProcessId(out uint pid);
    }

    static readonly IMMDeviceEnumerator Enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

    // Every COM object is released straight away instead of waiting for the GC
    static void Release(object? o) { if (o is not null) Marshal.ReleaseComObject(o); }

    public static bool IsPlaying()
    {
        var pids = Process.GetProcessesByName("Spotify").Select(p => { using (p) return (uint)p.Id; }).ToHashSet();
        if (pids.Count == 0 || Enumerator.EnumAudioEndpoints(0 /* render */, 1 /* active */, out var devices) != 0) return false;
        try
        {
            devices.GetCount(out var deviceCount);
            var iid = typeof(IAudioSessionManager2).GUID;
            for (var d = 0; d < deviceCount; d++)
            {
                IMMDevice? device = null; object? manager = null; IAudioSessionEnumerator? sessions = null;
                try
                {
                    if (devices.Item(d, out device) != 0) continue;
                    if (device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out manager) != 0) continue;
                    if (((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions) != 0) continue;
                    sessions.GetCount(out var sessionCount);
                    for (var s = 0; s < sessionCount; s++)
                    {
                        if (sessions.GetSession(s, out var session) != 0) continue;
                        try
                        {
                            session.GetProcessId(out var pid);
                            session.GetState(out var state);
                            if (state == 1 /* active */ && pids.Contains(pid)) return true;
                        }
                        finally { Release(session); }
                    }
                }
                finally { Release(sessions); Release(manager); Release(device); }
            }
            return false;
        }
        finally { Release(devices); }
    }
}

// One CSV line a minute, so a slow build-up (and what came before a hang) shows in the log afterwards
sealed class HealthLog(string path)
{
    const long MaxBytes = 2 * 1024 * 1024;
    const string Header = "time,event,threads,handles,private_mb,managed_mb,gcs,spotify_threads,spotify_mb,npsm_threads,npsm_handles,events,props_calls,slow_calls,errors,pending_s,last_error";
    DateTime nextWrite = DateTime.UtcNow.AddMinutes(1);
    int npsmPid;
    DateTime nextNpsmLookup = DateTime.MinValue;

    public void WriteEveryMinute(Counters c)
    {
        if (DateTime.UtcNow < nextWrite) return;
        nextWrite = DateTime.UtcNow.AddMinutes(1);
        // Collect first, so the numbers show what is still held rather than garbage not yet collected.
        // The heap is a few MB, so this takes milliseconds.
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        Write(c, "tick");
    }

    public void Write(Counters c, string what)
    {
        try
        {
            if (File.Exists(path) && new FileInfo(path).Length > MaxBytes) File.Move(path, path + ".old", overwrite: true);
            var me = Process.GetCurrentProcess();
            var (spotifyThreads, spotifyMb) = Spotify();
            var (npsmThreads, npsmHandles) = Npsm();
            var pendingSince = new[] { c.ManagerPendingSince, c.PropsPendingSince }.Min();
            var pending = pendingSince is { } p ? (int)(DateTime.UtcNow - p).TotalSeconds : 0;
            var line = string.Join(',',
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"), what, me.Threads.Count, me.HandleCount, me.PrivateMemorySize64 >> 20, GC.GetTotalMemory(false) >> 20, GC.CollectionCount(0),
                spotifyThreads, spotifyMb, npsmThreads, npsmHandles,
                c.Events, c.PropsCalls, c.SlowCalls, c.Errors, pending, '"' + c.LastError.Replace("\"", "'") + '"');
            var text = new StringBuilder();
            if (!File.Exists(path)) text.AppendLine(Header);
            text.AppendLine(line);
            File.AppendAllText(path, text.ToString());
        }
        catch { } // logging must never take the watcher down
    }

    // The Spotify process with the most threads is the one that hung before
    static (int, long) Spotify()
    {
        var processes = Process.GetProcessesByName("Spotify");
        try
        {
            var top = processes.MaxBy(p => p.Threads.Count);
            return top is null ? (0, 0) : (top.Threads.Count, top.PrivateMemorySize64 >> 20);
        }
        finally { foreach (var p in processes) p.Dispose(); }
    }

    // NPSMSvc is the Windows "now playing" service behind the media API and the keyboard media keys
    (int, int) Npsm()
    {
        if (DateTime.UtcNow >= nextNpsmLookup)
        {
            nextNpsmLookup = DateTime.UtcNow.AddMinutes(10);
            npsmPid = 0;
            foreach (var service in ServiceController.GetServices())
            {
                using (service)
                {
                    if (npsmPid == 0 && service.ServiceName.StartsWith("NPSMSvc_", StringComparison.OrdinalIgnoreCase))
                        npsmPid = ServicePid(service.ServiceName);
                }
            }
        }
        try
        {
            using var p = Process.GetProcessById(npsmPid);
            return (p.Threads.Count, p.HandleCount);
        }
        catch { nextNpsmLookup = DateTime.MinValue; return (0, 0); }
    }

    [DllImport("advapi32", SetLastError = true)] static extern IntPtr OpenSCManagerW(string? machine, string? database, uint access);
    [DllImport("advapi32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
    [DllImport("advapi32", SetLastError = true)] static extern bool QueryServiceStatusEx(IntPtr service, int level, byte[] buffer, int size, out int needed);
    [DllImport("advapi32")] static extern bool CloseServiceHandle(IntPtr handle);

    static int ServicePid(string name)
    {
        var scm = OpenSCManagerW(null, null, 0x0001 /* SC_MANAGER_CONNECT */);
        if (scm == IntPtr.Zero) return 0;
        try
        {
            var service = OpenServiceW(scm, name, 0x0004 /* SERVICE_QUERY_STATUS */);
            if (service == IntPtr.Zero) return 0;
            try
            {
                var buffer = new byte[36]; // SERVICE_STATUS_PROCESS; dwProcessId is at offset 28
                return QueryServiceStatusEx(service, 0, buffer, buffer.Length, out _) ? BitConverter.ToInt32(buffer, 28) : 0;
            }
            finally { CloseServiceHandle(service); }
        }
        finally { CloseServiceHandle(scm); }
    }
}
