// Port of PatchDump (Decoders.swift) and PatchEdit (PatchCodec.swift).

import 'effect_catalog.dart';

/// Little-endian bit field: bit n = bit (n % 8) of byte n ~/ 8.
int readBits(List<int> bytes, int start, int width) {
  var v = 0;
  for (var j = 0; j < width; j++) {
    final n = start + j;
    if (n ~/ 8 >= bytes.length) break;
    v |= ((bytes[n ~/ 8] >> (n % 8)) & 1) << j;
  }
  return v;
}

void writeBits(List<int> bytes, int start, int width, int value) {
  for (var j = 0; j < width; j++) {
    final n = start + j;
    if (n ~/ 8 >= bytes.length) return;
    final mask = 1 << (n % 8);
    if ((value >> j) & 1 == 1) {
      bytes[n ~/ 8] |= mask;
    } else {
      bytes[n ~/ 8] &= ~mask & 0xFF;
    }
  }
}

/// Zoom 7-bit unpacking: groups are [msbs, d0…d6]; bit 6-k of msbs is the top bit of dk.
List<int> unpack7(List<int> packed) {
  final out = <int>[];
  var i = 0;
  while (i < packed.length) {
    final msbs = packed[i];
    var k = 0, j = i + 1;
    while (j < packed.length && k < 7) {
      out.add(packed[j] | (((msbs >> (6 - k)) & 1) << 7));
      j++;
      k++;
    }
    i = j;
  }
  return out;
}

/// Inverse of [unpack7].
List<int> pack7(List<int> data) {
  final out = <int>[];
  for (var i = 0; i < data.length; i += 7) {
    final group = data.sublist(i, i + 7 > data.length ? data.length : i + 7);
    var msbs = 0;
    for (var k = 0; k < group.length; k++) {
      if (group[k] & 0x80 != 0) msbs |= 1 << (6 - k);
    }
    out.add(msbs);
    out.addAll(group.map((b) => b & 0x7F));
  }
  return out;
}

class ParameterValue {
  const ParameterValue(this.index, this.name, this.raw, this.display);
  final int index;
  final String name;
  final int raw;

  /// Display string from the catalog; null if `raw` is out of range.
  final String? display;
  String get text => display ?? '?$raw';
}

class EffectSlot {
  const EffectSlot(this.index, this.isOn, this.effectId, this.raw);
  final int index;

  /// Bit 0 of the block's first byte. Null for empty slots.
  final bool? isOn;

  /// Effect ID (0 = empty slot). Category is the top byte.
  final int effectId;
  final List<int> raw;

  bool get isEmpty => effectId == 0;
  String? get name => isEmpty ? null : EffectCatalog.name(effectId);
  String? get category => isEmpty ? null : EffectCatalog.category(effectId);
  String get displayName =>
      isEmpty ? '—' : (name ?? 'unknown ${effectId.toRadixString(16).padLeft(8, '0').toUpperCase()}');

  List<ParameterValue> get parameters {
    if (isEmpty || raw.length != PatchDump.effectBlockSize) return const [];
    final def = EffectCatalog.effect(effectId);
    if (def == null) {
      // Effect known only from the pedal's own file: knob names, raw values.
      final z = EffectCatalog.installed[effectId];
      if (z == null) return const [];
      return [
        for (var i = 0; i < z.parameters.length && i < PatchDump.parameterFields.length; i++)
          ParameterValue(i, z.parameters[i], readBits(raw, PatchDump.parameterFields[i].$1, PatchDump.parameterFields[i].$2),
              '${readBits(raw, PatchDump.parameterFields[i].$1, PatchDump.parameterFields[i].$2)}'),
      ];
    }
    final out = <ParameterValue>[];
    for (var i = 0; i < def.parameters.length && i < PatchDump.parameterFields.length; i++) {
      final f = PatchDump.parameterFields[i];
      final v = readBits(raw, f.$1, f.$2);
      out.add(ParameterValue(i, def.parameters[i].name, v, def.parameters[i].display(v)));
    }
    return out;
  }
}

/// Current-patch dump (`F0 52 00 <id> 28 … F7`, 146 bytes). Bytes 5…144 are 7-bit packed;
/// unpacked (122 bytes): six 18-byte effect blocks, a 3-byte header, a 10-char name.
/// Each block is a little-endian bit stream: bit 0 on/off, bits 1–28 effect ID,
/// P0–P2 13 bits from bit 29, P3–P7 8 bits from bit 68, P8 8 bits at bit 128.
class PatchDump {
  PatchDump._(this.deviceId, this.raw, this.unpacked, this.name, this.effects, this.effectCount, this.tempo,
      this.editSlot);

  static const expectedLength = 146;
  static const effectBlockSize = 18;
  static const effectCount_ = 6;
  static const nameStart = 111, nameEnd = 121;
  static const parameterFields = [(29, 13), (42, 13), (55, 13), (68, 8), (76, 8), (84, 8), (92, 8), (100, 8), (128, 8)];

  final int deviceId;
  final List<int> raw;
  final List<int> unpacked;
  final String? name;
  final List<EffectSlot> effects;
  final int? effectCount;
  final int? tempo;

  /// Effect slot (0…5) the pedal's own screen shows.
  final int? editSlot;

  bool get lengthMatches => raw.length == expectedLength;

  static PatchDump? decode(List<int> m) {
    if (m.length < 6 || m[0] != 0xF0 || m[1] != 0x52 || m[2] != 0x00 || m.last != 0xF7 || m[4] != 0x28) return null;
    final last = m.length - 1;
    final u = 5 < last ? unpack7(m.sublist(5, last)) : <int>[];

    String? name;
    if (nameEnd <= u.length) {
      name = String.fromCharCodes(u.sublist(nameStart, nameEnd).map((c) => c >= 0x20 && c <= 0x7E ? c : 0x3F)).trim();
    }
    final effects = <EffectSlot>[];
    for (var i = 0; i < effectCount_; i++) {
      final lo = i * effectBlockSize;
      final hi = lo + effectBlockSize > u.length ? u.length : lo + effectBlockSize;
      final block = lo < hi ? u.sublist(lo, hi) : <int>[];
      var word = 0;
      for (var k = 0; k < 4 && k < block.length; k++) {
        word |= block[k] << (8 * k);
      }
      final id = block.length >= 4 ? (word >> 1) & 0x0FFFFFFF : 0;
      final on = id == 0 || block.isEmpty ? null : (block[0] & 1) == 1;
      effects.add(EffectSlot(i, on, id, block));
    }
    int? count, tempo, edit;
    if (u.length >= 111) {
      final h0 = u[108], h1 = u[109], h2 = u[110];
      count = (h1 & 0x1C) >> 2;
      tempo = ((h1 & 0xE0) >> 5) + ((h2 & 0x1F) << 3);
      edit = 5 - (((h0 & 0xC0) >> 6) | ((h1 & 0x01) << 2));
    }
    return PatchDump._(m[3], List.unmodifiable(m), List.unmodifiable(u), name, effects, count, tempo, edit);
  }

  /// Why this patch must not be sent, or null if it looks sane.
  String? get validationProblem {
    if (!lengthMatches || unpacked.length != 122) return 'unexpected length ${raw.length}';
    if (name == null || name!.contains('?')) return 'name has unsupported characters';
    for (final e in effects.where((e) => !e.isEmpty)) {
      if (EffectCatalog.effect(e.effectId) == null && EffectCatalog.installed[e.effectId] == null) {
        return 'FX${e.index + 1} has unknown effect ID ${e.effectId.toRadixString(16)}';
      }
      final bad = e.parameters.where((p) => p.display == null);
      if (bad.isNotEmpty) return 'FX${e.index + 1} ${bad.first.name} = ${bad.first.raw} is out of range';
    }
    return null;
  }
}

/// Editable copy of a patch. Mutations work on the unpacked bytes, so anything the decoder
/// doesn't model is carried over unchanged.
class PatchEdit {
  PatchEdit(PatchDump dump)
      : unpacked = List.of(dump.unpacked),
        deviceId = dump.deviceId;

  final List<int> unpacked;
  final int deviceId;

  static const tempoMin = 40, tempoMax = 250;

  List<int> get frame => [0xF0, 0x52, 0x00, deviceId, 0x28, ...pack7(unpacked), 0xF7];
  PatchDump? get decoded => PatchDump.decode(frame);

  int _block(int slot) => slot * PatchDump.effectBlockSize;
  List<int> _slot(int slot) => unpacked.sublist(_block(slot), _block(slot) + PatchDump.effectBlockSize);
  void _setSlot(int slot, List<int> b) => unpacked.setRange(_block(slot), _block(slot) + PatchDump.effectBlockSize, b);

  void setName(String name) {
    final ascii = name.codeUnits.where((c) => c >= 0x20 && c <= 0x7E).take(10).toList();
    while (ascii.length < 10) {
      ascii.add(0x20);
    }
    unpacked.setRange(PatchDump.nameStart, PatchDump.nameEnd, ascii);
  }

  void setTempo(int bpm) {
    final t = bpm.clamp(tempoMin, tempoMax);
    unpacked[109] = (unpacked[109] & 0x1F) | ((t & 0x07) << 5);
    unpacked[110] = (unpacked[110] & 0xE0) | ((t >> 3) & 0x1F);
  }

  void setEditSlot(int slot) {
    final lr = 5 - slot.clamp(0, 5);
    unpacked[108] = (unpacked[108] & 0x3F) | ((lr & 0x3) << 6);
    unpacked[109] = (unpacked[109] & 0xFE) | ((lr & 0x4) >> 2);
  }

  void setOn(int slot, bool on) {
    final b = _slot(slot);
    writeBits(b, 0, 1, on ? 1 : 0);
    _setSlot(slot, b);
  }

  void setParameter(int slot, int index, int raw) {
    if (index >= PatchDump.parameterFields.length) return;
    final f = PatchDump.parameterFields[index];
    final b = _slot(slot);
    writeBits(b, f.$1, f.$2, raw);
    _setSlot(slot, b);
  }

  /// Puts effect `id` in `slot` with default parameters, or empties it (id 0).
  void setEffect(int slot, int id, {bool on = true}) {
    var b = _slot(slot);
    final wasEmpty = readBits(b, 1, 28) == 0;
    if (id == 0 || wasEmpty) b = List.filled(PatchDump.effectBlockSize, 0);
    if (id == 0) {
      b[0] = 0x01;
    } else {
      writeBits(b, 0, 1, on ? 1 : 0);
      writeBits(b, 1, 28, id);
      final params = EffectCatalog.effect(id)?.parameters ?? const [];
      for (var i = 0; i < PatchDump.parameterFields.length; i++) {
        final f = PatchDump.parameterFields[i];
        writeBits(b, f.$1, f.$2, i < params.length ? params[i].defaultRaw : 0);
      }
    }
    _setSlot(slot, b);
    _updateEffectCount();
  }

  void _updateEffectCount() {
    var last = 0;
    for (var s = 0; s < PatchDump.effectCount_; s++) {
      if (readBits(_slot(s), 1, 28) != 0) last = s + 1;
    }
    final count = last < 1 ? 1 : last;
    unpacked[109] = (unpacked[109] & ~0x1C & 0xFF) | ((count & 0x07) << 2);
  }
}
