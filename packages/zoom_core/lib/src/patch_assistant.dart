// Port of PatchAssistant.swift: provider-neutral logic behind the AI patch builder's tools.

import 'effect_catalog.dart';
import 'patch_dump.dart';

class SpecError implements Exception {
  SpecError(this.problems);
  final List<String> problems;
  @override
  String toString() => problems.join('\n');
}

abstract final class PatchAssistant {
  /// The MS-100BT's documented effects plus any effect seen on this pedal.
  static Set<int> availableIds(Iterable<PatchDump> seen) => {
        ...EffectCatalog.ms100btEffectIds,
        for (final p in seen)
          for (final e in p.effects)
            if (!e.isEmpty) e.effectId,
      };

  static List<Map<String, Object>> effectList(Set<int> available, {String? category}) {
    final ids = available.toList()..sort();
    return [
      for (final id in ids)
        if (EffectCatalog.effect(id) case final e?)
          if (category == null || (EffectCatalog.category(id) ?? 'Other').toLowerCase() == category.toLowerCase())
            {'name': e.name, 'category': EffectCatalog.category(id) ?? 'Other', 'knobs': e.parameters.map((p) => p.name).toList()},
    ];
  }

  static List<Map<String, Object>> effectDetails(List<String> names, Set<int> available) => [
        for (final n in names)
          if (lookup(n, available) case final id? when EffectCatalog.effect(id) != null)
            {
              'name': EffectCatalog.effect(id)!.name,
              'category': EffectCatalog.category(id) ?? 'Other',
              'knobs': [
                for (final p in EffectCatalog.effect(id)!.parameters)
                  {'name': p.name, 'values': describeValues(p), 'default': p.display(p.defaultRaw) ?? '${p.defaultRaw}'},
              ],
            }
          else
            {'name': n, 'error': 'Unknown effect. Use list_effects for valid names.'},
      ];

  /// "1–30", ["OFF","ON"], or "1–4000, 𝅘𝅥, …".
  static Object describeValues(CatalogParameter p) {
    final all = [for (var i = 0; i < p.valueCount; i++) p.display(i)!];
    if (all.length <= 16 && all.any((v) => int.tryParse(v) == null)) return all;
    final parts = <String>[];
    var i = 0;
    while (i < all.length) {
      final start = int.tryParse(all[i]);
      if (start != null) {
        var j = i;
        while (j + 1 < all.length && int.tryParse(all[j + 1]) == int.parse(all[j]) + 1) {
          j++;
        }
        parts.add(j > i ? '$start–${all[j]}' : all[i]);
        i = j + 1;
      } else {
        parts.add(all[i]);
        i++;
      }
    }
    if (parts.length > 14) return [...parts.take(12), '… (${all.length} values total)'].join(', ');
    return parts.join(', ');
  }

  static Map<String, Object> describe(PatchDump p, {int? slot}) => {
        'name': p.name ?? '',
        'tempo_bpm': p.tempo ?? 0,
        'effects': [
          for (final e in p.effects)
            if (!e.isEmpty)
              {
                'slot': e.index + 1,
                'effect': e.displayName,
                'category': e.category ?? '',
                'on': e.isOn == true,
                'params': {for (final v in e.parameters) v.name: v.text},
              },
        ],
        if (slot != null) 'memory_slot': slot + 1,
      };

  /// Complete patch from a model's spec, on top of `base`. Effects go into slots 1…n in signal order.
  static PatchEdit buildPatch(Map<String, Object?> spec, PatchDump base, Set<int> available) {
    final problems = <String>[];
    final edit = PatchEdit(base);
    final name = spec['name'];
    if (name is String) {
      final clean = String.fromCharCodes(name.codeUnits.where((c) => c >= 0x20 && c <= 0x7E));
      if (clean.length > 10) problems.add('name "$name" is longer than 10 characters');
      if (clean != name) problems.add('name may only use plain ASCII characters');
      edit.setName(clean);
    }
    final tempo = _number(spec['tempo']);
    if (tempo != null) {
      if (tempo < PatchEdit.tempoMin || tempo > PatchEdit.tempoMax) problems.add('tempo $tempo is outside 40–250 BPM');
      edit.setTempo(tempo);
    }
    final effects = spec['effects'];
    if (effects is! List) throw SpecError([...problems, '"effects" must be a list of 1–6 effects in signal order']);
    if (effects.isEmpty) problems.add('a patch needs at least one effect');
    if (effects.length > 6) problems.add('the MS-100BT has 6 slots; got ${effects.length} effects');
    for (var slot = 0; slot < effects.length && slot < 6; slot++) {
      final fx = effects[slot] as Map<String, Object?>;
      final n = fx['effect'] as String? ?? '?';
      final id = lookup(n, available);
      final def = id == null ? null : EffectCatalog.effect(id);
      if (id == null || def == null) {
        problems.add('slot ${slot + 1}: unknown effect "$n".');
        continue;
      }
      edit.setEffect(slot, id, on: fx['on'] as bool? ?? true);
      final params = (fx['params'] as Map?)?.cast<String, Object?>() ?? const {};
      params.forEach((key, value) {
        final idx = def.parameters.indexWhere((p) => p.name.toLowerCase() == key.toLowerCase());
        if (idx < 0) {
          problems.add('slot ${slot + 1} ${def.name}: no knob named "$key" (knobs: ${def.parameters.map((p) => p.name).join(', ')})');
          return;
        }
        try {
          edit.setParameter(slot, idx, rawFor(value, def.parameters[idx]));
        } on SpecError catch (e) {
          problems.add('slot ${slot + 1} ${def.name} ${def.parameters[idx].name}: ${e.problems.first}');
        }
      });
    }
    for (var slot = effects.length; slot < 6; slot++) {
      edit.setEffect(slot, 0);
    }
    if (problems.isEmpty) {
      final problem = edit.decoded?.validationProblem;
      if (problem != null) problems.add(problem);
    }
    if (problems.isNotEmpty) throw SpecError(problems);
    return edit;
  }

  /// Tweaks knob values or on/off of `base`. Slots are 1–6.
  static PatchEdit adjust(List<Object?> changes, PatchDump base) {
    final problems = <String>[];
    final edit = PatchEdit(base);
    for (final raw in changes) {
      final c = raw is Map ? raw.cast<String, Object?>() : const <String, Object?>{};
      final slotNo = _number(c['slot']);
      if (slotNo == null || slotNo < 1 || slotNo > 6) {
        problems.add('each change needs "slot" 1–6');
        continue;
      }
      final fx = base.effects[slotNo - 1];
      final def = fx.isEmpty ? null : EffectCatalog.effect(fx.effectId);
      if (def == null) {
        problems.add('slot $slotNo is empty; use propose_patch to add effects');
        continue;
      }
      final on = c['on'];
      if (on is bool) edit.setOn(slotNo - 1, on);
      final key = c['param'];
      if (key is String) {
        final idx = def.parameters.indexWhere((p) => p.name.toLowerCase() == key.toLowerCase());
        if (idx < 0) {
          problems.add('slot $slotNo ${def.name}: no knob named "$key"');
          continue;
        }
        try {
          edit.setParameter(slotNo - 1, idx, rawFor(c['value'], def.parameters[idx]));
        } on SpecError catch (e) {
          problems.add('slot $slotNo ${def.name} $key: ${e.problems.first}');
        }
      }
    }
    if (problems.isEmpty) {
      final problem = edit.decoded?.validationProblem;
      if (problem != null) problems.add(problem);
    }
    if (problems.isNotEmpty) throw SpecError(problems);
    return edit;
  }

  static int rawFor(Object? value, CatalogParameter p) {
    final String wanted = switch (value) {
      final bool b => b ? 'ON' : 'OFF',
      final int i => '$i',
      final double d => d == d.roundToDouble() ? '${d.round()}' : '$d',
      final String s => s.trim(),
      _ => throw SpecError(['value missing']),
    };
    for (var i = 0; i < p.valueCount; i++) {
      if (p.display(i)!.toLowerCase() == wanted.toLowerCase()) return i;
    }
    final r = describeValues(p);
    throw SpecError(['"$wanted" is not allowed (values: ${r is List ? r.join(', ') : r})']);
  }

  static int? lookup(String name, Set<int> available) {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final key = norm(name);
    final matches = EffectCatalog.effects.entries.where((e) => norm(e.value.name) == key).map((e) => e.key).toList()..sort();
    for (final id in matches) {
      if (available.contains(id)) return id;
    }
    return null;
  }

  static int? _number(Object? v) => switch (v) { final int i => i, final String s => int.tryParse(s), _ => null };
}
