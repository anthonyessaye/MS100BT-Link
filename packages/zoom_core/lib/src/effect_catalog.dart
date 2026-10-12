// Port of MS100BTLink/Sources/ZoomCore/EffectCatalog.swift (data in catalog_data.dart).

import 'dart:convert';

import 'catalog_data.dart' as data;
import 'effect_files.dart';

/// One run of display values: an integer run or one literal.
sealed class Segment {
  const Segment();
  int get count;
}

class IntRun extends Segment {
  const IntRun(this.start, this.count);
  final int start;
  @override
  final int count;
}

class TextValue extends Segment {
  const TextValue(this.text);
  final String text;
  @override
  int get count => 1;
}

class CatalogParameter {
  const CatalogParameter(this.name, this.segments, this.defaultRaw);
  final String name;
  final List<Segment> segments;

  /// Factory default raw value.
  final int defaultRaw;

  /// Number of valid raw values (raw value = index into the display list).
  int get valueCount => segments.fold(0, (n, s) => n + s.count);

  /// Display string for a raw value, or null if out of range.
  String? display(int raw) {
    if (raw < 0) return null;
    var i = raw;
    for (final s in segments) {
      switch (s) {
        case IntRun(:final start, :final count):
          if (i < count) return '${start + i}';
          i -= count;
        case TextValue(:final text):
          if (i == 0) return text;
          i -= 1;
      }
    }
    return null;
  }
}

class CatalogEffect {
  const CatalogEffect(this.name, this.parameters);
  final String name;
  final List<CatalogParameter> parameters;
}

abstract final class EffectCatalog {
  static const categories = {
    0x00: 'Thru', 0x01: 'Dynamics', 0x02: 'Filter', 0x03: 'Drive', 0x04: 'Amp',
    0x05: 'Bass Amp', 0x06: 'Modulation', 0x07: 'SFX', 0x08: 'Delay', 0x09: 'Reverb',
    0x0C: 'Bass Drive', 0x0D: 'Bass Preamp',
  };

  static const Set<int> ms100btEffectIds = data.ms100btEffectIds;

  static final Map<int, CatalogEffect> effects = _load();

  /// Built-in effects from the catalog; installed custom effects from their own file's parameter table
  /// (raw values 0…max, the file's defaults), when the table is sane.
  static CatalogEffect? effect(int id) => effects[id] ?? _installedEffect(id);

  static CatalogEffect? _installedEffect(int id) {
    final z = installed[id];
    if (z == null || z.parameterMax.length != z.parameters.length) return null;
    final params = <CatalogParameter>[];
    for (var i = 0; i < z.parameters.length; i++) {
      final max = z.parameterMax[i], def = z.parameterDefault[i];
      if (max < 1 || max > 8191 || def < 0 || def > max) return null; // not a table we understand: no edits
      params.add(CatalogParameter(z.parameters[i], [IntRun(0, max + 1)], def));
    }
    return CatalogEffect(z.displayName, params);
  }

  /// Replaces the installed custom effects (the pedal's own files, from a backup or after a change).
  static void setInstalled(Iterable<ZDLInfo> infos) {
    installed.clear();
    register(infos);
  }

  static bool isInstalledCustom(int id) => !effects.containsKey(id) && installed.containsKey(id);
  static String? name(int id) => effects[id]?.name ?? installed[id]?.displayName;

  /// Effects read from the pedal's own files (downloaded or custom ones), keyed by patch effect ID.
  /// They have names and knob names but no known value ranges.
  static final Map<int, ZDLInfo> installed = {};

  static void register(Iterable<ZDLInfo> infos) {
    for (final z in infos) {
      if (!z.isSharedLibrary) installed[z.patchEffectId] = z;
    }
  }

  static String? category(int id) => categories[(id >> 24) & 0xFF];

  static Map<int, CatalogEffect> _load() {
    final root = jsonDecode(data.catalogJson) as Map<String, dynamic>;
    final out = <int, CatalogEffect>{};
    root.forEach((key, entry) {
      final e = entry as List<dynamic>;
      final params = (e[1] as List<dynamic>).map((p) {
        final pl = p as List<dynamic>;
        final segs = (pl[1] as List<dynamic>).map<Segment>((s) {
          if (s is String) return TextValue(s);
          final r = s as List<dynamic>;
          return IntRun(r[0] as int, r[1] as int);
        }).toList();
        return CatalogParameter(pl[0] as String, segs, pl[2] as int);
      }).toList();
      out[int.parse(key, radix: 16)] = CatalogEffect(e[0] as String, params);
    });
    return out;
  }
}
