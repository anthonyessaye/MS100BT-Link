# Effect library: analysis and plan

Source reviewed: [lopezchau/zoom-ms100bt-bluetooth](https://github.com/lopezchau/zoom-ms100bt-bluetooth)
(MIT, Swift, macOS). It installs effects on an MS-100BT over the same Bluetooth link we use, and documents every
step as verified on real hardware (firmware 1.30, device ID 0x5E, the same as ours). Status: **plan only.
Nothing here is implemented.** Installing effects needs the owner's explicit go-ahead (see "Decision needed").

## How adding effects works

Effects are files on the pedal: `.ZDL` = a small header + TI C6000 DSP code. The menu is a separate index file,
`FLST_SEQ.ZDT` (13-byte records, grouped by category). Installing an effect means:

1. write the `.ZDL` with the file-system commands (`F0 52 00 5E 60 …`: open/write/close, 4 KB blocks, CRC32 per block),
2. read it back and compare,
3. rewrite `FLST_SEQ.ZDT` with the effect's name under its own category, and read that back too.

These are the **`0x60` file-system commands that our allowlist blocks permanently**. They are not the firmware
commands (`01`, `04`, ROM erase/write); lopezchau never sends those, and neither would we.

Why it works: the MS-100BT is the MS-50G platform (167 of the MS-50G's 173 effects are byte-identical), so effects from
the MS-50G, MS-60B and MS-70CDR, and community-built custom DSP effects, load on it.

Verified on hardware by lopezchau: 28 MS-60B effects (Z-Syn, Z-Tron, Splitter, St Bs GEQ…), DualRev (MS-50G v3, 42 KB),
and six community effects (WaveFold, DubSiren, Shatter, Galactic, Microloom, Spool).

## Known hazards (from their hardware log)

| Hazard | Effect | Mitigation they use |
|---|---|---|
| Effect listed under a category other than its header byte 60 | **Pedal froze** when scrolling to it; recovered with a power cycle | Always list an effect under its own category |
| File name longer than 8.3 | Community reports of **pedals freezing at boot** | Block non-8.3 names |
| Custom ZDL above ~32 KB | Froze an MS-70CDR | Size warning / block for custom effects |
| Bass categories (05, 0B, 0C, 0D, 14, 16) | Installed but never shown by the MS-100BT menu | Hide them |
| 200-file limit | Writes fail past 200 files (no damage) | Count before writing |
| Deleting stock/StompShare effects | Lost for good unless backed up (StompShare is gone) | Back up every file before deleting |
| `PAIR.DAT` | Bluetooth pairing | Never touched |
| All Initialize | Keeps added effects, forgets the Bluetooth pairing | Docs: re-pair |

Their `Apply` aborts if the pedal changed since it was read, checks the 200-file limit, backs up every file it will
delete, writes with read-back verification, and offers a dry run.

## Licensing

- lopezchau's code: MIT, so we may port it with attribution.
- Zoom's stock effects are Zoom's files. Third-party repos host them (repeat98/ZoomMultistompZDL `stock_zdls/`, 830 files),
  and lopezchau downloads them on the user's request, never bundling them. We would do the same.
- Community effects: per-author licenses (mostly MIT). The community linker embeds small pieces of Zoom runtime code,
  so download from each author's repo and show their license; don't redistribute.

## What we can add, by risk

### 1. Read-only (low risk, no new write commands)
These use the file system's *read* path (`60 25/26/27` list, `60 29` free space, `60 20 02 / 22 / 21` read a file).
That's still the blocked `0x60` family, so it needs the allowlist widened to the read sub-commands only.
- **Full file backup**: copy all ~175 files (effects, StompShare effects, the menu) to the Mac. This is the safety net
  for everything else, and the only way to preserve StompShare effects.
- **Installed effects view**: the pedal's real menu by category, sizes, free space, file count (n/200).
- **Name any effect in a patch.** A ZDL header holds its category (byte 60) and a 16-bit ID (bytes 64–65), plus a
  descriptor table with the display name and knob names. **Patch effect ID = (category << 24) | header ID**: checked
  against LINESEL.ZDL (02, 8) = catalog `0x02000008` LineSel [Likely, one sample]. So downloaded/custom effects
  would show their real names and knob names instead of "unknown".

### 2. Effect store (writes, high caution, opt-in)
- Browse a library: stock effects from other MultiStomps + community custom effects, each with risk labels
  (lopezchau's: Low risk / Community / Not shown / Untested header / Too large / Needs expression pedal / Long name).
- Install / remove / reorder with lopezchau's safety rules, behind a **second, separate unlock** plus an automatic full
  file backup first. Dry run by default.

### 3. Library catalog + AI
- A catalog file in this repo (`library/index.json`): effect name, category, knobs, size, header type, source URL,
  license, "confirmed on MS-100BT" flag and risk label. The app fetches the catalog and downloads files from each
  author on demand.
- New assistant tool `search_effect_library(query)`: returns installed effects plus installable ones with risk labels.
  The AI may *suggest* "DualRev isn't on your pedal; it's in the library (verified on MS-100BT)"; installing stays a
  separate, user-confirmed action. The AI never installs.

## Decision needed (owner)

1. Allow the **read-only** file-system commands (backup, installed-effects view, effect naming)? Recommended.
2. Allow **installing effects** (file writes + menu edits) behind a second unlock, with the mitigations above?
   This reverses the earlier "skip custom effects" decision. It's proven on the same pedal model by someone else,
   but the pedal is irreplaceable and boot-time freezes have been reported for bad file names.
