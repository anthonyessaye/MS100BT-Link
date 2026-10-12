# MS-100BT Link

A macOS app for the **Zoom MS-100BT MultiStomp** that connects over Bluetooth. Zoom only shipped an iOS editor for this pedal, and it's long gone.

- **Pedalboard view.** See the current patch as a chain of stompboxes with real knobs.
- **Edit live.** Turn effects on and off, change parameters, swap effects, rename the patch, set its tempo.
- **Patch library.** Back up all 50 patches, load them, save them back, import and export `.syx` files.
- **MIDI control.** Drive the pedal from any MIDI controller, including Bluetooth MIDI footswitches. There's a Stomp mode (toggle effects) and a Patch mode (load patches), and switch assignments are set with Learn.
- **Live updates.** Changes made on the pedal itself show up in the app.

> **Unofficial.** Not affiliated with or endorsed by Zoom Corporation. "Zoom" and "MultiStomp" are trademarks of their owners. The protocol was worked out from Zoom's public firmware updater and community documentation; see [docs/updater-findings.md](docs/updater-findings.md). Editing writes to your pedal: back up first. The app never sends firmware or file-system commands (a hard allowlist in the transport layer blocks them), but use it at your own risk.

## Requirements

- macOS 14 or later
- A Zoom MS-100BT paired over Bluetooth (on the pedal: knob 1 → MENU → Bluetooth → pairing)
- Tested on firmware 1.30

## Install

Download `MS-100BT-Link-v0.1.zip` from [Releases](../../releases), unzip it, and move **MS-100BT Link.app** to Applications. The build is ad-hoc signed, not notarized, so the first launch needs a right-click → **Open** (or System Settings → Privacy & Security → Open Anyway). Allow Bluetooth access when asked.

## Build from source

```bash
cd MS100BTLink
swift test                 # protocol, codec and allowlist tests
./scripts/make-apps.sh     # builds build/MS-100BT Link.app and build/zoomprobe.app
```

More detail (safety allowlist, CLI, MIDI) is in [MS100BTLink/README.md](MS100BTLink/README.md).

## License

[MIT](LICENSE) © 2026 Anthony Essaye ([anthonyessaye@outlook.com](mailto:anthonyessaye@outlook.com)). Reuse it freely.
Bundle identifier: `com.anthonyessaye.ms100bt`.

## Credits

Effect names and parameter tables come from [zoom-explorer](https://github.com/thammer/zoom-explorer) by Thomas Hammer (MIT). See [THIRD_PARTY_NOTICES.md](MS100BTLink/THIRD_PARTY_NOTICES.md). MS-series message reference: [zoom-ms-utility](https://github.com/multistomp/zoom-ms-utility).
