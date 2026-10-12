# MS-100BT Link

macOS tools for the Zoom MS-100BT: `zoomprobe` (read-only CLI) and **MS-100BT Link** (SwiftUI viewer + patch editor).
Protocol evidence: [`../docs/updater-findings.md`](../docs/updater-findings.md).

## Safety

Every outbound frame goes through `Allowlist.validate` inside the transport's `send`. It accepts
exact shapes only (`<id>` = 5D/5E, learned from the identity reply):

| Frame | Purpose | Kind |
|---|---|---|
| `F0 7E 00 06 01 F7` / `F0 7E 7F 06 01 F7` | identity request | read |
| `F0 52 00 <id> 29 F7` / `33 F7` | current patch / program | read |
| `F0 52 00 <id> 50 F7` / `51 F7` | edit mode on / off | mode |
| `C0 <pp>` (pp < 50) | select patch | write |
| `F0 52 00 <id> 31 <slot<6> <0 or 2…10> <lsb> <msb> F7` | live on/off or parameter edit | write |
| 146-byte `F0 52 00 <id> 28 … F7` that decodes with known effects and in-range params | send patch to edit buffer | write |
| `F0 52 00 <id> 32 01 00 00 <pp> 00 00 00 00 00 F7` | store into slot pp | write |

Writes were enabled by the owner's decision (2026-10-11) and also need the app's **Editing** lock
open (`PedalSession.writesEnabled`, off at every launch). Storing requires a backup holding
that slot plus a confirmation. Firmware/filesystem opcodes (01, 04, 05, 17, 20, 21, 60, 61) stay
blocked. `zoomprobe` is read-only: it never unlocks writes.

## Build

```bash
swift test                 # framer, decoders, allowlist, log
./scripts/make-apps.sh     # build/MS-100BT Link.app and build/zoomprobe.app
```

Both bundles carry `NSBluetoothAlwaysUsageDescription`. Bluetooth permission belongs to the app that
launches the process, so run the CLI from **Terminal.app** (`.build/release/zoomprobe …`, allow
Terminal's Bluetooth prompt) or through `scripts/zoomprobe …`, which launches the bundle.

## Pedal session runbook (~10 min)

Before: pedal on the AC adapter. Leave the pedal's screen in view.

| Step | You | Command | Milestone |
|---|---|---|---|
| 1 | knob 1 → MENU → Bluetooth → pairing | `zoomprobe pair` | — |
| 2 | approve the Bluetooth prompt | `zoomprobe sdp` | M1 / Tier 1 |
| 3 | — | `zoomprobe connect --listen 60` | M2 / Tier 2 |
| 4 | read the firmware version off the pedal | `zoomprobe probe all` | M3–M4 / Tiers 3–4 |
| 5 | say whether the printed patch name matches the screen | — | layout check |

Stop and power-cycle if the pedal shows an update screen or freezes. Don't repeat the last message.

Logs: `./logs/<command>-<timestamp>.jsonl` (CLI), `~/Library/Logs/MS100BTLink/` (app).

## App

Dark pedalboard UI (`MainView.swift`): the top bar has the connection, the patch switcher (◀ 03 BOURJ ▶),
tempo, the Editing lock, MIDI, and the sidebar toggle. The selected effect is shown large with knobs
(drag up/down, double-click for the default). The signal chain runs below (IN → 6 pedals → OUT; click a
pedal to select it, click its footswitch to toggle it). **Change effect** (⌘E) opens the effect library. The
sidebar holds Patches (load, back up, save to a slot, import/export) or the Tone Assistant. Connection details,
SDP and the raw console are under Window → Diagnostics (⌥⌘D).

Screenshots: `"build/MS-100BT Link.app/Contents/MacOS/MS100BTLinkApp" --screenshots ../docs/media` (launch it via
`open -W -n "build/MS-100BT Link.app" --args --screenshots "$PWD/../docs/media"`) renders the real views with demo
data and touches neither Bluetooth nor any AI provider.

## MIDI control

`MIDIControl.swift` listens to every CoreMIDI source: Bluetooth LE MIDI (pair it from MIDI →
Connect Bluetooth MIDI…), USB, or network. Assignments map CC, note or program change (set with
**Learn**) to: toggle FX 1–6, next/previous patch, load patch n, or a knob (CC value scaled to the
parameter's range). Program Change n can load patch n+1 directly. Assignments are saved in
UserDefaults. MIDI actions are writes, so they need Editing unlocked.

## Tone assistant (AI)

Top bar → **AI**. Describe a sound ("Edge-style dotted-eighth delay") and the assistant proposes a patch.
It works through typed tools (`list_effects`, `get_effect_details`, `get_current_patch`, `list_patches`,
`propose_patch`, `adjust_patch`). It never sends bytes: `PatchAssistant` (ZoomCore) validates every effect
name and knob value against the catalog, and the transport allowlist still applies. A proposal appears
as a card; **Try on pedal** sends it to the edit buffer and reads it back. Saving to a slot stays manual.

Providers (gear icon): Claude via the Messages API (default model `claude-opus-5-5`, adaptive thinking,
effort `medium`, prompt caching, server-side refusal fallback `fallbacks: "default"`), ChatGPT, or any
OpenAI-compatible endpoint (Ollama, OpenRouter, LM Studio). Keys are stored in the macOS Keychain.
Messages and patch data go to the chosen provider.

