// Port of EffectFiles.swift: CRC/7-bit codecs, the .ZDL header, and the effect menu (FLST_SEQ.ZDT).
// Formats from lopezchau/zoom-ms100bt-bluetooth (MIT, (c) 2026 lopezchau), verified on an MS-100BT.

abstract final class FSCodec {
  static final List<int> _table = List<int>.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  /// Standard CRC-32 (zlib). The pedal transmits `crc32(data) ^ 0xFFFFFFFF`.
  static int crc32(List<int> d) {
    var c = 0xFFFFFFFF;
    for (final b in d) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// 32-bit value as five 7-bit bytes, least significant first.
  static List<int> u7x5(int v) => [for (var i = 0; i < 5; i++) (v >> (7 * i)) & 0x7F];

  static int? u35(List<int> m, int at) {
    if (at < 0 || m.length < at + 5) return null;
    var v = 0;
    for (var i = 0; i < 5; i++) {
      v |= (m[at + i] & 0x7F) << (7 * i);
    }
    return v & 0xFFFFFFFF;
  }

  static final _nameChars = RegExp(r'^[A-Za-z0-9_.\-]{1,12}$');
  static bool isValidName(String n) => _nameChars.hasMatch(n);

  /// 8.3 name ending in .ZDL. Longer base names have frozen pedals at boot.
  static bool isSafeEffectName(String n) {
    final parts = n.split('.');
    return isValidName(n) && parts.length == 2 && parts[0].isNotEmpty && parts[0].length <= 8 && parts[1].toUpperCase() == 'ZDL';
  }
}

abstract final class ZDLCategory {
  static const names = {
    0x01: 'Dynamics', 0x02: 'Filter/EQ', 0x03: 'Drive', 0x04: 'Amp', 0x05: 'Bass Amp',
    0x06: 'Modulation', 0x07: 'SFX', 0x08: 'Delay', 0x09: 'Reverb', 0x0B: 'Pedal',
    0x0C: 'Bass Drive', 0x0D: 'Bass Preamp', 0x0F: 'Shared library',
    0x14: 'Bass Drive (B1Xon)', 0x16: 'Bass Preamp (B1Xon)',
  };
  static const shownOnMS100BT = {0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x08, 0x09};
  static const notShownOnMS100BT = {0x05, 0x0B, 0x0C, 0x0D, 0x14, 0x16};
  static const sharedLibrary = 0x0F;
  static String name(int c) => names[c] ?? 'Category ${c.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}

class ZDLInfo {
  const ZDLInfo({required this.fileName, required this.size, required this.headerSize, required this.extendedTag,
      required this.category, required this.type, required this.effectId, required this.version, required this.truncated,
      required this.displayName, required this.parameters, required this.imports, required this.exports, required this.crc32,
      this.parameterMax = const [], this.parameterDefault = const []});

  final String fileName, extendedTag, version, displayName;
  final int size, headerSize, category, type, effectId, crc32;
  final bool truncated;
  final List<String> parameters, imports, exports;

  /// Per knob, from the file's parameter table: highest raw value and default raw value
  /// (checked against the catalog with the stock COMP.ZDL: Sense 10/6, Tone 10/6, Level 150/100, ATTCK 1/0).
  final List<int> parameterMax, parameterDefault;

  /// The 28-bit ID inside patch data (checked: LINESEL 02/8 = 0x02000008).
  int get patchEffectId => (category << 24) | effectId;
  bool get hasSafeName => FSCodec.isSafeEffectName(fileName);
  bool get isSharedLibrary => category == ZDLCategory.sharedLibrary;

  /// Largest community-built ZDL known to load; stock effects up to 42 KB work.
  static const customSizeLimit = 32126;

  static int _le32(List<int> d, int o) => (o < 0 || o + 4 > d.length) ? 0 : d[o] | d[o + 1] << 8 | d[o + 2] << 16 | d[o + 3] << 24;
  static int _le16(List<int> d, int o) => (o < 0 || o + 2 > d.length) ? 0 : d[o] | d[o + 1] << 8;
  static String _cstring(List<int> d, int o, int max) {
    if (o < 0 || o >= d.length) return '';
    final end = (o + max).clamp(0, d.length);
    final out = <int>[];
    for (var i = o; i < end && d[i] != 0; i++) {
      out.add(d[i]);
    }
    return String.fromCharCodes(out);
  }

  static bool _eq(List<int> d, int at, List<int> want) {
    if (at + want.length > d.length) return false;
    for (var i = 0; i < want.length; i++) {
      if (d[at + i] != want[i]) return false;
    }
    return true;
  }

  static ZDLInfo? parse(String fileName, List<int> d) {
    if (d.length <= 80 || !_eq(d, 4, 'SIZE'.codeUnits) || !_eq(d, 20, 'INFO'.codeUnits)) return null;
    final headerSize = _le32(d, 12), elfSize = _le32(d, 16);
    final elfOff = 20 + headerSize;
    final tag = headerSize > 56 && d.length >= 0x50 ? String.fromCharCodes(d.sublist(0x4C, 0x50)) : '';
    final version = _cstring(d, 68, 4);
    final truncated = elfSize <= 0 || d.length < elfOff + elfSize;
    var imports = <String>[], exports = <String>[];
    if (!truncated && _eq(d, elfOff, const [0x7F, 0x45, 0x4C, 0x46])) {
      final (e, i) = _dynamicSymbols(d.sublist(elfOff, elfOff + elfSize));
      exports = e..sort();
      imports = i..sort();
    }
    final (name, params, maxes, defaults) = _descriptor(d);
    return ZDLInfo(
      fileName: fileName, size: d.length, headerSize: headerSize, extendedTag: tag, category: d[60], type: d[61],
      effectId: d[64] | d[65] << 8, version: version, truncated: truncated,
      displayName: name ?? fileName.replaceAll(RegExp(r'\.ZDL$', caseSensitive: false), ''),
      parameters: params, imports: imports, exports: exports, crc32: FSCodec.crc32(d),
      parameterMax: maxes, parameterDefault: defaults,
    );
  }

  static (String?, List<String>, List<int>, List<int>) _descriptor(List<int> d) {
    final needle = 'OnOff\u0000'.codeUnits;
    for (var off = 0; off + 0x60 <= d.length; off++) {
      if (d[off] == 0x4F && _eq(d, off, needle) && _le32(d, off + 12) == 1 && _le32(d, off + 0x30 + 12) == 0xFFFFFFFF) {
        final name = _cstring(d, off + 0x30, 12);
        final params = <String>[], maxes = <int>[], defaults = <int>[];
        var e = off + 0x60;
        while (e + 0x30 <= d.length && params.length < 16) {
          final p = _cstring(d, e, 12);
          if (p.isEmpty || !RegExp(r'^[A-Za-z]').hasMatch(p) || p.codeUnits.any((c) => c > 0x7E || c < 0x20)) break;
          params.add(p);
          maxes.add(_le32(d, e + 12));
          defaults.add(_le32(d, e + 16));
          e += 0x30;
        }
        return (name.isEmpty ? null : name, params, maxes, defaults);
      }
    }
    return (null, const <String>[], const <int>[], const <int>[]);
  }

  static (List<String>, List<String>) _dynamicSymbols(List<int> elf) {
    final shoff = _le32(elf, 0x20), shentsize = _le16(elf, 0x2E), shnum = _le16(elf, 0x30);
    if (shoff <= 0 || shentsize < 40 || shnum >= 1000 || shoff + shnum * shentsize > elf.length) return (<String>[], <String>[]);
    int sh(int i, int field) => _le32(elf, shoff + i * shentsize + field * 4);
    final defined = <String>{}, undefined = <String>{};
    for (var i = 0; i < shnum; i++) {
      if (sh(i, 1) != 11) continue; // SHT_DYNSYM
      final symOff = sh(i, 4), symSize = sh(i, 5), link = sh(i, 6);
      if (link >= shnum) continue;
      final strOff = sh(link, 4);
      for (var o = symOff; o + 16 <= (symOff + symSize).clamp(0, elf.length); o += 16) {
        final nameOff = _le32(elf, o), shndx = _le16(elf, o + 14);
        if (nameOff > 0) {
          final n = _cstring(elf, strOff + nameOff, 128);
          if (n.isNotEmpty) (shndx == 0 ? undefined : defined).add(n);
        }
      }
    }
    return (defined.toList(), undefined.toList());
  }
}

class EffectMenuCategory {
  EffectMenuCategory(this.id, this.effects);
  final int id;
  final List<String> effects;
}

class MalformedMenu implements Exception {
  MalformedMenu(this.message);
  final String message;
  @override
  String toString() => 'Malformed effect menu: $message';
}

/// FLST_SEQ.ZDT: 13-byte records; `>>>\0`+u32 opens a category, `<<<\0`+u32 closes it; zero padded.
class EffectIndex {
  EffectIndex(this.categories, this.fileSize);

  static const fileName = 'FLST_SEQ.ZDT';
  static const _record = 13;

  final List<EffectMenuCategory> categories;
  final int fileSize;

  factory EffectIndex.parse(List<int> data) {
    final cats = <EffectMenuCategory>[];
    EffectMenuCategory? cur;
    var end = data.length;
    while (end > 0 && data[end - 1] == 0) {
      end--;
    }
    end += (_record - end % _record) % _record;
    for (var off = 0; off + _record <= end && off + _record <= data.length; off += _record) {
      final r = data.sublist(off, off + _record);
      final cat = r[4];
      if (r[0] == 0x3E && r[1] == 0x3E && r[2] == 0x3E && r[3] == 0) {
        if (cur != null) throw MalformedMenu('category not closed at $off');
        cur = EffectMenuCategory(cat, []);
      } else if (r[0] == 0x3C && r[1] == 0x3C && r[2] == 0x3C && r[3] == 0) {
        if (cur == null || cur.id != cat) throw MalformedMenu('unexpected category end at $off');
        cats.add(cur);
        cur = null;
      } else {
        if (cur == null) throw MalformedMenu('effect outside a category at $off');
        cur.effects.add(String.fromCharCodes(r.takeWhile((b) => b != 0)));
      }
    }
    if (cur != null) throw MalformedMenu('last category not closed');
    final idx = EffectIndex(cats, data.length);
    final rebuilt = idx.build();
    for (var i = 0; i < data.length; i++) {
      if (rebuilt[i] != data[i]) throw MalformedMenu('does not round-trip; unknown format');
    }
    return idx;
  }

  List<int> build() {
    final out = <int>[];
    void rec(List<int> prefix) => out.addAll([...prefix, ...List.filled(_record - prefix.length, 0)]);
    for (final c in categories) {
      rec([0x3E, 0x3E, 0x3E, 0, c.id, 0, 0, 0]);
      for (final e in c.effects) {
        if (e.length > 12) throw MalformedMenu('name too long: $e');
        rec(e.codeUnits);
      }
      rec([0x3C, 0x3C, 0x3C, 0, c.id, 0, 0, 0]);
    }
    if (out.length > fileSize) throw MalformedMenu('too big: ${out.length} > $fileSize bytes');
    return [...out, ...List.filled(fileSize - out.length, 0)];
  }

  EffectIndex copy() => EffectIndex([for (final c in categories) EffectMenuCategory(c.id, List.of(c.effects))], fileSize);

  List<String> get allEffects => [for (final c in categories) ...c.effects.where((e) => e.isNotEmpty)];
  int? categoryOf(String name) => categories.where((c) => c.effects.contains(name)).firstOrNull?.id;

  void remove(String name) {
    for (final c in categories) {
      c.effects.removeWhere((e) => e == name);
    }
  }

  void append(String name, int cat) {
    remove(name);
    final c = categories.where((c) => c.id == cat).firstOrNull;
    if (c != null) {
      c.effects.add(name);
    } else {
      categories.add(EffectMenuCategory(cat, [name]));
    }
  }
}
