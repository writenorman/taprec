# Removing the BlackHole setup

`taprec` uses Core Audio taps and needs **none** of this. If you set up the
BlackHole route first, here's what it left behind and how to remove it.

Nothing here is required — BlackHole is inert when unused. Remove it if you want
a clean machine or to stop the extra device cluttering your audio menus.

> Run these one at a time and read what each does. Two of them affect things
> beyond this project.

---

## 1. Check what's actually installed

```bash
brew list --cask 2>/dev/null | grep -i blackhole
brew list 2>/dev/null | grep -E 'switchaudio-osx|blueutil|macos-audio-cli'
ls -d /Library/Audio/Plug-Ins/HAL/BlackHole*.driver 2>/dev/null
```

---

## 2. Delete the Multi-Output Device  *(do this first)*

GUI only — there's no CLI for aggregate devices.

1. Open **Audio MIDI Setup**.
2. Select **Multi-Output Device** in the left sidebar.
3. Click **–** at the bottom-left.

Do this **before** uninstalling the driver. A Multi-Output whose member driver
has vanished can linger as a broken entry in your Sound menu.

If your system output is currently set to the Multi-Output Device, switch it
back to your speakers first:

```bash
# if you still have the CLI installed
macos-audio connect local "Built-in Output"   # or whatever your speakers are called
# or just use System Settings › Sound
```

---

## 3. Uninstall the BlackHole driver

```bash
brew uninstall --cask blackhole-2ch
```

Requires your password — it's removing a system audio driver. Afterwards:

```bash
ls -d /Library/Audio/Plug-Ins/HAL/BlackHole*.driver 2>/dev/null || echo "gone"
```

CoreAudio may keep the device listed until the daemon restarts. Either reboot,
or:

```bash
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```

Audio cuts out for a second or two.

---

## 4. Optional: the helper CLIs

These were installed for the BlackHole route but are independently useful, and
none of them are audio drivers — they're small user-space tools. **Recommended:
keep them.**

| tool | what it does | keep? |
|---|---|---|
| `switchaudio-osx` | switch audio in/output from the CLI | genuinely handy |
| `macos-audio-cli` | wrapper for output switching, volume, Bluetooth | handy |
| `blueutil` | Bluetooth control from the CLI | handy |

If you do want them gone:

```bash
brew uninstall switchaudio-osx
brew uninstall vossenwout/tap/macos-audio-cli
brew uninstall blueutil
```

`ffmpeg` is **required by taprec** — do not remove it.

---

## 5. Restore your audio settings

The BlackHole work changed device sample rates. Those settings are fine to leave
as they are — taprec doesn't care about them, since it doesn't route through any
device. But if you want your original setup back, check each device's **Format**
in Audio MIDI Setup.

The working configuration was simply: every device in the capture path set to
the same rate. 48 kHz is a sensible default for everything, so there is usually
no reason to change it back.

48 kHz is a sensible default for everything, so there's usually no reason to
change it back.

---

## 6. Verify taprec still works

The point of all this is that removing BlackHole should change nothing:

```bash
taprec --check       # should still report the tap works
taprec -t 10         # should still produce exactly 10 seconds
```

If either fails after cleanup, something removed here was load-bearing after
all — reinstall with `brew install --cask blackhole-2ch` and open an issue,
because that would mean taprec has a dependency it shouldn't have.
