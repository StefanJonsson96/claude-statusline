# claude-statusline

A PowerShell 7 status line for [Claude Code](https://code.claude.com) on Windows, with a now-playing line for Spotify.

```
📁 my-repo  [branch] main ≡  ☁️ My Subscription  🕐 21:58:56  🧠 ctx: 11%  🔋 5h: 47% (0h50m)  📊 7d: 13% (3d7h)  🔄 cc -r <session id>
[spotify]  KAROL G - LATINA FOREVA 1:42/2:39
```

`[branch]` and `[spotify]` are font icons that only render in the terminal.

## What it shows

**Line 1**

| Icon | Shows |
| --- | --- |
| 📁 | Current folder |
| Nerd Font branch (`U+E0A0`) | Git branch, then `↑n` ahead / `↓n` behind / `≡` in sync with its upstream |
| ☁️ | Default Azure subscription, read from `~/.azure/azureProfile.json` (hidden without the Azure CLI) |
| 🕐 | Time of Claude's last reply |
| 🧠 | Context window used |
| 🔋 | 5-hour usage, with time until reset |
| 📊 | 7-day usage, with time until reset |
| 🔄 | `cc -r <session id>` to resume this conversation |

The usage segments only show for Claude.ai Pro and Max accounts, after the first reply in a session.

`cc` is a PowerShell alias for `claude`. Add it to your profile (`notepad $PROFILE`) or change `cc` in `statusline.ps1`:

```powershell
function cc { claude @args }
```

**Line 2: Spotify** (only while the Spotify desktop app has a track loaded)

Green Spotify logo, `artist - title position/length`, a pause icon when paused, and a speaker icon with the
device name when another device plays it (Spotify Connect, e.g. `[speaker] OTHER-PC`). Nothing is shown when this PC plays it.

It reads what Windows already knows, so there is no Spotify login or API key. That also means it only
gets the first artist and no playlist name.

The device name comes from the "Playing on ..." text in the Spotify window, matched in English and Swedish.
For another app language, add its prefix to `$devicePattern` in `spotify-watch.ps1`. Whether this PC plays it
is detected from Windows audio output, so that part works in any language.

## Requirements

- Windows with [Windows Terminal](https://aka.ms/terminal)
- [PowerShell 7](https://aka.ms/powershell) (`pwsh`) and Windows PowerShell 5.1 (built into Windows)
- Git
- A [Nerd Font](https://www.nerdfonts.com/font-downloads) set as the Windows Terminal font. Tested with CaskaydiaMono Nerd Font.
- Spotify desktop app (optional)

## Install

```powershell
git clone https://github.com/StefanJonsson96/claude-statusline.git
cd claude-statusline
pwsh ./install.ps1
```

Then restart Windows Terminal. Add `-WhatIf` to see what it would change first.

`install.ps1` does three things, backing up each settings file first (`*.bak-<timestamp>`):

1. Installs `fonts/StatuslineIcons.ttf` for your user. No admin needed. Windows Terminal only uses installed
   fonts, so the logo can't be loaded straight from this folder.
2. Sets `statusLine` in `~/.claude/settings.json` to run `statusline.ps1` from this folder, refreshing every second.
3. Adds `Statusline Icons` as a fallback font to the Windows Terminal default profile
   (`"face": "CaskaydiaMono Nerd Font, Statusline Icons"`). It only supplies the Spotify logo; your text font doesn't change.

Because the setting points at this folder, `git pull` updates the status line.

## How the Spotify line works

`statusline.ps1` starts `spotify-watch.ps1` in a hidden Windows PowerShell 5.1 process (PowerShell 7 can't
read the Windows media session). The watcher checks Spotify four times a second, checks which device plays it once a
second, and writes the result to `%TEMP%\claude-spotify.txt`; the status line reads that file and counts the time forward itself. The watcher
exits 30 seconds after the status line stops running.

It seems to use 0.1-0.3% CPU and around 35-40 MB RAM (Intel Core i5-13400F, 10 cores / 16 threads, 32 GB DDR5-4800).
In Task Manager it's the **Windows PowerShell** background process; on the Details tab, turn on the Command line column to spot `spotify-watch.ps1`.

## Alignment

I am on a 1920x1080 full-width Windows Terminal with quake mode, so icons might not be aligned on other setups.
The Spotify logo is nudged to line up with the 📁 emoji; see [fonts/README.md](fonts/README.md) to change that.

## Uninstall

1. Remove `statusLine` from `~/.claude/settings.json`.
2. Remove `, Statusline Icons` from the font face in Windows Terminal settings.
3. Delete `%LOCALAPPDATA%\Microsoft\Windows\Fonts\StatuslineIcons.ttf` and the `Statusline Icons (TrueType)` value under
   `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` (sign out and back in if the file is in use).

## License

Scripts: MIT. Font: SIL Open Font License 1.1, see [fonts/README.md](fonts/README.md).
