#:property TargetFramework=net10.0
#:package HidSharp@2.6.4

// Battery reader for the status line, run with `dotnet run battery.cs`. Asks each supported SteelSeries wireless
// device for its battery level over USB, writes one line per answering device to %TEMP%\claude-battery.txt
// ("headset 87 0": kind, percent, 1 while charging) and exits. SteelSeries GG can keep running alongside it.
//
// The commands come from HeadsetControl (Arctis Nova 7) and rivalcfg (Rival 3 Wireless). A device that doesn't
// answer (the mouse while it is off) keeps its last line; an unplugged device, or the headset when it reports
// itself off, is left out of the file.

using HidSharp;

using var mutex = new Mutex(false, @"Local\claude-battery");
try { if (!mutex.WaitOne(0)) return; }
catch (AbandonedMutexException) { } // previous reader was killed; we own the mutex now

Device[] devices =
[
    // Arctis Nova 7 Gen 2: reply b0 ?? <percent> <state>; state 0 = headset off, 1-2 = charging
    new("headset", 0x227E, [0xB0], reply =>
        reply[0] != 0xB0 ? null
        : reply[3] == 0x00 ? Reading.Off
        : new Reading(reply[2], reply[3] is 0x01 or 0x02)),

    // Rival 3 Wireless (2.4 GHz): reply <percent> ?? <charging>; no reply while the mouse is off
    new("mouse", 0x1830, [0xAA, 0x01], reply => new Reading(reply[0], reply[2] != 0)),
];

var path = Path.Combine(Path.GetTempPath(), "claude-battery.txt");

// The last line written for each device, kept when the device doesn't answer this time
var previous = new Dictionary<string, string>();
try { foreach (var line in File.ReadAllLines(path)) previous[line.Split(' ')[0]] = line; }
catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }

var lines = new List<string>();
foreach (var device in devices)
{
    var r = Read(device);
    if (r is { Percent: >= 0 and <= 100 }) lines.Add($"{device.Kind} {r.Percent} {(r.Charging ? 1 : 0)}");
    else if (r != Reading.Off && r != Reading.Unplugged && previous.TryGetValue(device.Kind, out var last)) lines.Add(last);
}

File.WriteAllLines(path + ".tmp", lines);
File.Move(path + ".tmp", path, overwrite: true);

// Sends the command on the device's vendor interface (USB interface 3) and parses the first reply it accepts.
// The mouse dongle leaves about one query in twelve unanswered, so a device gets three tries.
static Reading? Read(Device device)
{
    var hid = DeviceList.Local.GetHidDevices(0x1038, device.ProductId)
        .FirstOrDefault(d => d.DevicePath.Contains("&mi_03", StringComparison.OrdinalIgnoreCase));
    if (hid is null) return Reading.Unplugged;
    for (var attempt = 0; attempt < 3; attempt++)
    {
        try
        {
            using var stream = hid.Open();
            stream.ReadTimeout = 500;
            var report = new byte[hid.GetMaxOutputReportLength()]; // byte 0 is the report id (0)
            device.Command.CopyTo(report, 1);
            stream.Write(report);

            // Other status reports can arrive on the same interface; skip up to a few that don't parse
            for (var i = 0; i < 5; i++)
            {
                var reply = stream.Read().AsSpan(1).ToArray();
                if (device.Parse(reply) is { } reading) return reading;
            }
        }
        catch (Exception e) when (e is IOException or TimeoutException or UnauthorizedAccessException) { }
    }
    return null;
}

record Reading(int Percent, bool Charging)
{
    public static readonly Reading Off = new(-1, false);
    public static readonly Reading Unplugged = new(-2, false);
}

record Device(string Kind, int ProductId, byte[] Command, Func<byte[], Reading?> Parse);
