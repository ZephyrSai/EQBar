# EQBar

A system-wide equalizer, spatial audio processor and per-app volume mixer for macOS that lives in the menu bar and stays out of the way.

**[Website](https://zephyrsai.github.io/EQBar/)** · **[Download](https://github.com/ZephyrSai/EQBar/releases/latest)** · by [ZephyrSai](https://github.com/ZephyrSai)

EQBar is a ground-up native rewrite inspired by [eqMac](https://github.com/bitgapp/eqMac) by Roman Kisil, including the features that were Pro-only there. No account, no web views, no third-party dependencies, no audio driver to install.

Measured on an Apple M4 Pro at 96 kHz, with memory as Activity Monitor reports it:

| | |
|---|---|
| App size | ~0.85 MB (1.7 MB universal) |
| Memory, idle | ~10 MB |
| Memory, menu open (any page) | ~21–24 MB, back to ~21 MB after closing |
| Memory, spatial audio on (headphones, medium room) | +17 MB; the cathedral room is the largest at ~60 MB total |
| CPU, nothing playing | ~0.1% |
| CPU, playing through 10-band EQ | ~0.5% |
| Launch to menu bar icon | ~100 ms |

## Features

**Equalizer**
- **Basic**: bass, mid and treble.
- **Advanced**: 10-band graphic EQ with 18 built-in presets.
- **Expert**: unlimited parametric bands. Each band can be peak, low/high shelf, low/high pass, band pass or notch, with frequency, gain and Q.
- Preamp, with optional auto-preamp so boosts can't clip.
- Live spectrum analyzer with the EQ curve drawn over it.
- User presets. Import Equalizer APO / AutoEq `ParametricEQ.txt` files and **eqMac preset exports**, and export to `ParametricEQ.txt`.

**AutoEQ headphone profiles**
- Search the [AutoEq](https://github.com/jaakkopasanen/AutoEq) database (about 9,000 measurements) from the menu bar. One click downloads the correction profile and applies it as an Expert EQ preset you can still tweak.
- The index is fetched only when you open the search, then cached for a week.

**Spatial audio**
- Puts stereo audio on two virtual speakers in front of you, using Apple's spatial audio engine: a high-quality HRTF on headphones, or panning plus room on built-in and external speakers.
- Optional **personalized profile**: uses Apple's newer renderer with your personal spatial audio profile. Its rooms are convolution reverbs that cost about 50–100 MB, so it's off by default.
- Simulated rooms: small, medium and large rooms, chambers, halls, concert halls, cathedral and plate, with an adjustable room amount and speaker angle.
- Headphone crossfeed (bs2b presets) and a stereo width control.

**Volume**
- **One volume control.** 0–100% *is* the device's system volume, the same value as Control Center and the volume keys, and it updates when you change it anywhere else. 100–200% is EQBar's **boost (up to +12 dB)**. Mute is shared with the system.
- Balance, and a peak limiter that stops clipping.
- **Volume keys:**
  - On outputs with their own volume, the keys work as usual, with the normal macOS indicator. Once the device is at 100%, Volume Up continues into EQBar's boost, and Volume Down leaves the boost before handing control back to macOS.
  - On HDMI and DisplayPort outputs, which have no volume, the volume and mute keys control EQBar.
  - Where macOS can't show its own indicator, EQBar shows a small native one under its menu bar icon.
- **Per-app volume mixer** (0–150%, with mute).

**Devices**
- Pick the output device from the menu bar.
- **Output format picker**, like Audio MIDI Setup: choose the device's sample rate and bit depth (for example 2 ch 24-bit Integer, 96 kHz). EQBar follows rate changes automatically.

**Audio Unit plugins**
- Insert any installed AUv2 or AUv3 effect into the chain. You can reorder plugins, bypass them, and open each one's own editor (or a generic one). Plugin state is saved.

## How it works

EQBar uses **Core Audio process taps** (macOS 14.4+) instead of a virtual audio driver.

```
apps ──► process tap (muted at the source while EQBar reads it) ─┐
                                                                 ├─► private aggregate device, clocked by your output
one tap per app with a custom volume ───────────────────────────┘                │
                                                                                  ▼
       mix → plugins → preamp → EQ → spatial → crossfeed → width → volume → limiter → your output device
```

- Nothing is installed into `coreaudiod` and no admin password is needed. If EQBar quits or crashes, the taps disappear and audio plays normally again.
- Taps and output share one clock and one I/O callback, so there's no ring buffer, no drift correction and minimal latency.
- The real-time path never allocates or takes locks. Settings reach the audio thread as immutable snapshots through a lock-free handoff, and old snapshots are freed on the main thread once the audio thread has moved on.
- After a short period of digital silence (longer when a room or plugin tail is still ringing), the I/O callback skips all processing.
- The menu's views are built when you click the icon and thrown away when it closes. The analyzer and the mixer's process polling only run while they're on screen.
- The menu is a plain borderless panel rather than `NSPopover`. On macOS 26 a popover that grows while open briefly allocates ~120 MB of graphics memory, and an open popover costs ~8 MB more.
- EQBar runs with macOS's space-efficient allocator (`MallocSpaceEfficient` in `LSEnvironment`), which saves ~3 MB at idle and ~10 MB once the menu has been used.
- **Only one copy runs at a time.** A second copy (another build, another location) asks whether to keep the running one or replace it, and never touches audio until that's settled. Opening EQBar again from Finder just shows its menu.

## Install

1. Download `EQBar-<version>.zip` from the [latest release](https://github.com/ZephyrSai/EQBar/releases/latest) and unzip it.
2. Move **EQBar.app** to Applications.
3. Open it. The release is a universal build (Apple silicon and Intel) signed ad hoc and not notarized, so macOS blocks the first launch:
   - **macOS 15 and later:** open System Settings → Privacy & Security, scroll down to the message about EQBar and click **Open Anyway**.
   - **macOS 14:** Control-click EQBar.app in Finder, choose **Open**, then **Open** again.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/EQBar.app`
4. Allow **System Audio Recording** when asked, and **Accessibility** if you want the volume keys.

You can also build it yourself in a minute; see [Building](#building).

## Requirements

- macOS 14.4 or later
- The **System Audio Recording** permission. macOS asks on first launch, and you can change it later in System Settings → Privacy & Security → Screen & System Audio Recording. Audio is processed on your Mac and is never recorded or sent anywhere.
- The **Accessibility** permission, for the volume keys. EQBar asks once after the audio permission. If it's still missing, the menu shows an **Allow…** button, and if macOS doesn't pass the grant to the running app, a **Relaunch EQBar** button. EQBar only reacts to the volume and mute keys. You can turn volume keys off in Settings.
- **Settings → Permissions** shows the state of both permissions and opens the right System Settings page.

## Building

You need the Swift toolchain only: the Xcode Command Line Tools are enough, and there's no Xcode project.

```bash
scripts/build-app.sh        # release build → build/EQBar.app (ad-hoc signed)
scripts/test.sh             # unit tests (DSP, parsers, render path, AU hosting)
open build/EQBar.app
```

Options for `build-app.sh`:

| Variable | Default | |
|---|---|---|
| `SIGN_IDENTITY` | `-` (ad-hoc) | e.g. `Developer ID Application: Your Name (TEAMID)` for distribution |
| `BUNDLE_ID` | `io.github.zephyrsai.eqbar` | |
| `VERSION` | `1.0.0` | |
| `UNIVERSAL` | `0` | `1` builds arm64 + x86_64 |

Ad-hoc builds get a new code signature each time, and macOS ties permissions (System Audio Recording, Accessibility) to it, so grants don't survive a rebuild. For day-to-day development, sign with your Apple Development certificate. Permissions then stay granted across rebuilds:

```bash
SIGN_IDENTITY="Apple Development" scripts/build-app.sh
```

 To distribute, sign with Developer ID and notarize (`xcrun notarytool`).

Debug helpers:

- `EQBAR_DEBUG=1` logs launch time and, every 2 s, the engine status and I/O levels.
- `EQBAR_SNAPSHOT=/some/dir` renders every menu page to PNG.
- `EQBAR_MEMTEST=/some/report.txt` drives the app through every feature (all menu pages, spatial rooms, per-app taps, plugins, AutoEQ, 15 open/close cycles) and writes the memory footprint after each step. Settings are restored at the end.

```bash
open --env EQBAR_DEBUG=1 --stderr /tmp/eqbar.log build/EQBar.app
```

## Project layout

```
Sources/
  CAtomics/            acquire/release primitives for the lock-free handoff
  EQBarCore/           everything except UI (unit tested)
    CoreAudio/         devices, formats, processes, permission, property helpers
    Engine/            TapEngine (taps + aggregate + I/O), RenderContext (real-time path), snapshots
    DSP/               biquad EQ, crossfeed, spatial mixer, spectrum, Audio Unit hosting
    Model/             settings, EQ model, presets
    AutoEQ/            AutoEq index/search/download, APO + eqMac importers
    EQBarController    owns settings, engine lifecycle, devices, presets
  EQBar/               AppKit menu bar app (status item, menu panel, pages, single-instance guard)
Tests/EQBarCoreTests/
scripts/
Resources/             Info.plist, entitlements
```

## Known limitations

- **macOS 14.4+ only.** Supporting older versions would need eqMac's virtual driver approach.
- The first time an app's volume moves off 100%, EQBar gives it its own tap, which causes a brief gap in the audio.
- Spatial audio is a stereo-to-virtual-speakers renderer. It doesn't do head tracking.
- AUv3 plugins that only run out of process add their own latency.
- Tapped audio isn't latency-compensated for video sync. The added latency is one I/O buffer, about 5–11 ms.

## Credits

- **[eqMac](https://github.com/bitgapp/eqMac)** by **Roman Kisil** (Nodeful / Bitgapp), Apache 2.0. The original app whose features and design EQBar rebuilds. Thank you, Roman.
- **[AutoEq](https://github.com/jaakkopasanen/AutoEq)** by **Jaakko Pasanen**, MIT. Headphone measurements and correction profiles, downloaded at runtime.
- Robert Bristow-Johnson's *Audio EQ Cookbook* (filter design) and Boris Mikhaylov's **bs2b** (crossfeed).

## License

Copyright 2026 [ZephyrSai](https://github.com/ZephyrSai). Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
