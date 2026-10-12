# Updater static analysis — MS-100BT System v1.30 (Mac)

Source: `https://zoomcorp.com/documents/371/MS-100BT_v1.30_Mac_E_0.zip` (629,460 bytes), extracted to `vendor/updater-mac/`.
Nothing was executed. Analysis: `lipo` (i386 slice), `otool -L/-oV/-tV`, `strings`, a selector-annotation script, and hex inspection of `MAIN.bin`.

Tags: **[Certain]** read directly from code/bytes · **[Likely]** strong inference · **[Guessing]** unverified.

## Bundle contents

| File | What it is |
|---|---|
| `MacOS/MS-100BT Updater` | Universal Mach-O, i386 + ppc7400, Objective-C 1, links IOBluetooth |
| `Resources/bin/MAIN.bin` | Pedal firmware image (496 KB, header `TIPAcYSX…`, mostly uncompressed; contains plain SysEx templates) |
| `Resources/bin/zdl/LINESEL.ZDL` | One effect module ("ZOOM EFFECT DLL SYSTEM VER 1.00", embeds an ELF) |

Classes: `SPPCommunication`, `BluetoothManager` (+ `FirmwareUpdate` category), `MIDIHandler` (+ `CRCCalculator`), `BluetoothDeviceInquiry`, UI classes.

## Transport

- **SDP service: UUID16 `0x1101` (Serial Port Profile).** `-[SPPCommunication openConnection:]` calls `[IOBluetoothSDPUUID uuid16:0x1101]` → `getServiceRecordForUUID:` → `getRFCOMMChannelID:` → `openRFCOMMChannelAsync:withChannelID:delegate:`. The channel ID is read from SDP, never hard-coded. **[Certain]**
- The firmware image contains the string `"Serial Port"` twice next to `PAIR.DAT` — very likely the SDP service name the pedal advertises. **[Likely]**
- **No framing.** `sendAsync:` writes the raw message bytes with `writeAsync:length:refcon:`, chunked to `getMTU`. No length prefix, header or checksum. **[Certain]**
- **Inbound is raw SysEx.** `rxDataAnalyze:` appends bytes into a buffer until the last byte is `F7`, requires the first byte to be `F0`, then routes based on the header. **[Certain]**
- CRC32 exists only inside firmware-write payloads (`makeRomWritePacket`, `updateCRC32:`), not as a transport wrapper. **[Certain]**

→ Handoff hypothesis #5 (Zoom SysEx carried as raw bytes over RFCOMM) upgrades from [Guessing] to **[Certain] for the updater path** and **[Likely] for normal operation**.

## Device ID

- Inbound Zoom SysEx (`F0 52 00 <id> …`) is accepted only if `<id>` is **`0x5D` or `0x5E`** (`id - 0x5D <= 1`). **[Certain]**
- The identity reply is accepted only if byte 4 = `02` and byte 6 ∈ {`5D`, `5E`}. Byte 6 is then stored as `connectedDeviceID` and used in every later Zoom message. Any other ID → "Illegal device connected." **[Certain]**
- The firmware hard-codes `F0 52 00 5E 61 xx` templates. **[Certain]** That suggests `0x5E` is the MS-100BT's ID, with `0x5D` as an alternate (another mode or sibling). **[Guessing]** The identity reply settles this; we never need to guess-iterate.
- The firmware also contains `F0 52 00 58 60 xx` templates (`0x58` = MS-50G), which shows shared code with the MS-50G. **[Certain]** This supports layout hypothesis #6 **[Likely]**.

## Identity reply layout

The updater parses `F0 7E 00 06 02 52 <pid> 00 <mode> …`:
- byte 6 = device ID **[Certain]**
- byte 8 = op mode: `0` → mode 0, `1` → mode 1, anything else → `0xFF` **[Certain]**. In mode 1 the updater runs an extra filesystem/Bluetooth handshake before writing. Meaning of the modes: **[Guessing]**, possibly main vs. boot.

The firmware's reply template `F0 7E 00 06 02 52 00 00 00 00 00 00 00 00 F7` (15 bytes) matches the MS-series reply in handoff §5, with version digits at bytes 10–13. **[Likely]** The firmware contains the string `"1.30"`. **[Certain]**

## What the updater sends, in order

Message table from `-[MIDIHandler messageData:withObject:]` plus `executeFirmwareUpdate`:

| # | Bytes | Builder | When |
|---|---|---|---|
| 1 | **`F0 7E 00 06 01 F7`** | `makeUniversalSysEXMessage:1` | **First message after the channel opens — identity request** |
| 2 | `F0 52 00 id 60 06 F7` | filesystem msg, fc 6 | mode 1 only |
| 3 | `F0 52 00 id 61 05 F7` | `makeBluetoothMidiMessage:opCode:5` | mode 1 only |
| 4 | `F0 52 00 id 01 F7` | `makeFlashRWMessage:1` | always, right before erase/write |
| 5–8 | ROM erase (`makeRomEraseMessage`, ranges 0xA0000 / 0x1FD000 / 0x400000 / 0x100000) | | flash erase |
| 9–12 | ROM write packets, 8→7-bit packed, CRC32 | | flash write |
| 13 | `F0 52 00 id 04 F7` | `makeFlashRWMessage:4` | end of flash write |
| 14–19 | `F0 52 00 id 60 …` filesystem ack/unlink/write/open/close | | ZDL (effect) upload |

**[Certain]** for the bytes and order. No confirmation step or pedal-side "update mode" check gates message 4. The `showAlertConnectDeviceOn{Boot,Main}Mode` alerts exist but are never called. **Assume these opcodes act immediately.**

## Opcode map (byte 4 of `F0 52 00 id …`)

| Opcode | Meaning | Source | Status for us |
|---|---|---|---|
| `00` | response/ack (`00 <code>`) | receive parser | inbound only |
| `01` | flash write begin | updater | **FORBIDDEN — firmware path** |
| `04` | flash write end | updater | **FORBIDDEN** |
| `05` | (firmware template) | MAIN.bin | **FORBIDDEN — unknown** |
| `17`, `20`, `21` | (firmware templates) | MAIN.bin | forbidden — unknown |
| `28`/`29`/`32`/`33` | MS-series patch ops | g200kg doc; `32` template in MAIN.bin | `29`, `33` allowed (read); `28`, `32` forbidden |
| `31` | parameter edit | MAIN.bin template | forbidden to send; may arrive inbound |
| `60 xx` | **filesystem** (open/write/close/unlink/ack) | updater | **FORBIDDEN** (resolves the handoff's "0x60 unknown") |
| `61 xx` | **Bluetooth-module functions** | updater + MAIN.bin (`61 01`, `61 05`, `61 08`, `61 0B`) | **FORBIDDEN** |

## Effect on the allowlist

- `F0 7E 00 06 01 F7` is literally the updater's first message, and it is read-only. **It is our safest probe. [Certain]**
- `F0 7E 7F 06 01 F7` (broadcast form): not used by the updater. Keep it as a second try only.
- Opcodes `01`, `04`, `05`, `60`, `61` are now confirmed to belong to the firmware and filesystem path. Hard-block them in the transport gate as well as the general allowlist rule.
- Sending `0x33`/`0x29` (and `0x50`/`0x51`) still relies on the MS-50G doc. **[Likely]**, given the shared code.

## Open questions (answer at the first pedal session)

1. Which device ID comes back, `5D` or `5E`, and what mode byte?
2. Does the SDP record name match "Serial Port"? Is there also an iAP record?
3. Does the pedal send anything unprompted after the channel opens?

## Pedal results — session 1 (2026-10-11)

SDP records for `ZOOM MS-100BT` (ac-3f-a4-10-0e-18), from the macOS cache (the fresh query timed out with `0xE00002D6`):

| Record | RFCOMM ch | Service class | Meaning |
|---|---|---|---|
| "Serial Port" | **2** | `0x1101` | SPP: the updater's channel and ours. Name matches the firmware string. **[Certain]** |
| (unnamed) | 1 | `00000000-DECA-FADE-DECA-DEAFDECACAFF` | Apple iAP over Bluetooth (the iOS app's MFi channel). Claim #8 → **[Certain]**. Never opened by our tools. |

Tier 1 reached.

## Pedal results — session 2 (2026-10-11, app Connect)

| Sent | Reply | Conclusion |
|---|---|---|
| `F0 7E 00 06 01 F7` | `F0 7E 00 06 02 52 5E 00 01 00 31 2E 33 30 F7` (63 ms) | **Device ID 0x5E, mode byte 1, firmware "1.30". [Certain]** Tier 3. |
| `F0 52 00 5E 33 F7` | nothing in 2 s | 0x33 is not answered (at least outside edit mode). |
| `F0 52 00 5E 29 F7` | nothing in 3 s | Plain patch request is not answered. |
| `50` → `29` → `51` | 146-byte `F0 52 00 5E 28 …` | **The patch dump needs edit mode. [Certain]** Tier 4. |

Patch dump: 7-bit packed from byte 5 (groups of 8: MSB byte + 7 data bytes), giving 122 unpacked bytes:
six 18-byte effect blocks (0–107), 3 unknown bytes (108–110), name at 111–120 (`"Bourj"`, space padded). **[Certain]** for the packing and name position.
The MS-50G `EfOn` offsets land on bit 0 of each block's first byte. Those first bytes are `10 10 20 60 60 01`, so on/off is **[Guessing]** until an effect is toggled and re-read.
Mode byte = 1 during normal operation, so "mode 1" is NOT boot mode. **[Certain]**

## Pedal results — session 3 (2026-10-11)

- Patch name "Bourj" matches the pedal screen → **name decoding [Certain] on the MS-100BT. Tier 4 confirmed.**
- Effect 5 was enabled on the pedal, then re-read: the only changed bit in the 122 unpacked bytes was unpacked byte 72 (block 5, byte 0), `60 → 61`. **On/off = bit 0 of each 18-byte block's first byte. [Certain]**
- Empty slots read `01 00 00 00 00 …` (seen in three patches). Bit 0 is set there, so check for empty before reading on/off. **[Likely]**
- Switching patches on the pedal produced **no** inbound bytes, and `0x33` is never answered → the current program number is not available over this link. **[Certain]** for this firmware, outside edit mode.
- Effect type IDs: still undecoded (raw blocks shown). Next candidate: compare blocks against the FX list PDF across patches.

## Effect names (2026-10-11)

- (Superseded below: the mask was an unpacking bug.) **Effect ID** = bits 1–28 of each 18-byte block's first 4 unpacked bytes (little-endian), with bits 14 and 22 masked off. Those two are parameter bits (top bits of bytes 1 and 2 in the MS-50G table): `id = (le32(block[0..3]) >> 1) & 0x0FBFBFFF`. ID 0 = empty slot / THRU. **[Certain]** for the 4 captured patches: every non-empty slot resolved to a catalog name, and the effect-count header field matched the pedal for "Bourj" (5).
- **Names** come from zoom-explorer's MS-50G/60B/70CDR table (MIT, 226 IDs), embedded as `EffectCatalog.swift`. 100 names from the MS-100BT FX-list PDF appear in it, so coverage of the built-in effects is ~complete. **[Likely]**
- **Header** (unpacked 108–110): effect count = `(h1 >> 2) & 7`; tempo = `(h1 >> 5) + ((h2 & 0x1F) << 3)` ("Bourj" = 122 BPM). **[Likely]**, tempo not yet checked against the pedal.
- Decoded: "Bourj" = Booster · Tremolo · Hall · MonoSynth · Z Clean; "Panic" = Chorus · Delay · Z Clean · Tremolo · SlapBackD; "Empty" = T Scream · Hall.

## Correction + parameters (2026-10-11)

- **7-bit unpacking bit order was wrong.** In each group, bit **6-k** of the MSB byte is the top bit of data byte k, not bit k. The old order still decoded names and the on/off bit (neither uses top bits). It corrupted IDs and parameters, which is why bits 14/22 had to be masked. With the fix, every ID resolves unmasked and all 59 parameter values across 4 patches are in range. The MS-50G doc's bit table is consistent with it: P0b2→bit 31, P0b10→39, P1b5→47, P2b0→55, type→byte 0 bit 7. **[Likely]** until the two changed slots below are checked on the pedal.
- Changed by the fix: "Bourj" FX5 = **Z Scream** (`030000F0`), was Z Clean. "Panic" FX1 = **Phaser** (`06000030`), was Chorus. "Bourj" tempo = **126** BPM, was 122. Effect 5's on/off byte is `E0/E1`; the on/off finding is unchanged.
- **Parameters**: P0–P2 are 13 bits from bit 29, P3–P7 are 8 bits from bit 68, P8 is 8 bits at bit 128 (zoom-explorer layout). Names and display values come from its catalog (raw value = index into the value list). "Bourj": Booster Gain 80/Tone 50/Level 100 · Tremolo Depth 98/Rate 46/Level 139/Wave TRI 1 · Hall Decay 28/Tone 5/Mix 63/PreD 49/Level 100/Tail OFF · MonoSynth Synth 46/Dry 100/Level 130/Wave Sine/Tone 6/Speed 99 · Z Scream Gain 60/Tone 50/Level 100. **[Likely]**
- **Confirmed on the pedal (2026-10-11):** "Bourj" FX5 = Z Scream and "Panic" FX1 = Phaser, and the decoded parameter values match the screen. The corrected unpacking (bit 6-k), the effect-ID formula (no mask) and the parameter layout are now **[Certain]** for the MS-100BT. Tempo (126) has not been checked yet.
