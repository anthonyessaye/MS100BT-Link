# What the app may send to the pedal

Every outbound frame goes through `Allowlist.validate` (`packages/zoom_core/lib/src/messages.dart`), both in
`PedalSession.send` and again in each platform transport. It accepts exact shapes only; anything else is refused
before a byte leaves the device. `<id>` is 5D or 5E, learned from the identity reply.

| Frame | Purpose | Kind |
|---|---|---|
| `F0 7E 00 06 01 F7` / `F0 7E 7F 06 01 F7` | identity request | read |
| `F0 52 00 <id> 29 F7` / `33 F7` | current patch / program | read |
| `F0 52 00 <id> 50 F7` / `51 F7` | edit mode on / off | mode |
| `C0 <pp>` (pp < 50) | select patch | write |
| `F0 52 00 <id> 31 <slot<6> <0 or 2…10> <lsb> <msb> F7` | live on/off or parameter edit | write |
| 146-byte `F0 52 00 <id> 28 … F7` that decodes with known effects and in-range knob values | send a patch to the edit buffer | write |
| `F0 52 00 <id> 32 01 00 00 <pp> 00 00 00 00 00 F7` | store into slot pp | write |
| `F0 52 00 <id> 60 …` in the exact shapes below | pedal file system (effects and their menu) | read / file write |

File-system shapes (from [lopezchau/zoom-ms100bt-bluetooth](https://github.com/lopezchau/zoom-ms100bt-bluetooth),
verified there on an MS-100BT): info `02`, ACK `05 00`, `09`, disk usage `29 00…`, list `25`/`26 00 00 2A 00`,
end list `27`, open `20 01|02 00×9 <8.3 name> 00`, read `22 <handle> <size ≤ 4096>`, close `21 <handle>`,
delete `24 <name> 00`, write block `23 <handle> <size> <packed data> <crc>` (the size and CRC must match the data).
Only 8.3 `.ZDL` effect files and the effect menu `FLST_SEQ.ZDT` may be opened for writing or deleted; `PAIR.DAT`
never.

## Locks on top of the allowlist

- **Writes** (select, edit, send, store) need the Editing lock open (`PedalSession.writesEnabled`), which the app
  only opens after the unlock warning. Storing needs a backup that holds the slot, and a confirmation.
- **File-system reads** need a file-system session (`fileSystemEnabled`): the Effects window opens one and the live
  connection pauses meanwhile.
- **File-system writes** additionally need `fileSystemWritesEnabled`, which `PedalFileSystem.apply` sets only while
  an approved change plan runs: one that `EffectPlanValidator` passed (backup present, category and effect-ID checks,
  shared libraries, file limit, menu consistency), after the risk confirmation, with copies of everything it changes
  saved first and each written file read back.
- **Firmware and updater commands** (01, 04, 05, 17, 20, 21 as top-level opcodes, the updater's `60 06` and `61 xx`)
  are refused outright.

How the protocol was worked out: [updater-findings.md](updater-findings.md).
