import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_assistant.dart';
import 'midi_control.dart';

/// One-time move of the native Swift Mac app's settings, MIDI mappings and AI keys into this app.
/// (Backups and the effect library need no move: the Mac build uses the same folder.)
abstract final class LegacyMac {
  static const _channel = MethodChannel('ms100bt/ui');
  static const _done = 'migratedFromNativeMacApp';

  static Future<void> migrate(SharedPreferences prefs) async {
    if (prefs.getBool(_done) == true) return;
    try {
      final old = await _channel.invokeMapMethod<String, Object?>('legacySettings') ?? const {};
      for (final MapEntry(:key, :value) in old.entries) {
        if (key == 'midiMappings' || prefs.containsKey(key)) continue; // never overwrite this app's own settings
        switch (value) {
          case final bool b:
            await prefs.setBool(key, b);
          case final String s:
            await prefs.setString(key, s);
          case final int i when key == 'rememberUnlock' || key == 'editingUnlocked' || key.endsWith('LoadsPatch') || key == 'aiAutoTry':
            await prefs.setBool(key, i != 0);
          default:
        }
      }
      final json = old['midiMappings'];
      if (json is String && !prefs.containsKey('midiMappings')) {
        final converted = convertMappings(json);
        if (converted.isNotEmpty) await prefs.setString('midiMappings', jsonEncode([for (final m in converted) m.toJson()]));
      }
      const keys = AIAssistant.keys;
      for (final account in ['anthropic', 'openai', 'compatible']) {
        if (await keys.read(key: 'ai.$account') != null) continue;
        final k = await _channel.invokeMethod<String>('legacyKey', {'account': account});
        if (k != null && k.isNotEmpty) await keys.write(key: 'ai.$account', value: k);
      }
      await prefs.setBool(_done, true);
    } catch (_) {
      // Leave the flag unset: the next launch tries again. Nothing of the old app is changed.
    }
  }

  /// The native app's MIDIMapping JSON (Swift Codable) → this app's mappings. Unknown entries are skipped.
  static List<MidiMapping> convertMappings(String json) {
    MidiAction? action(Object? a) {
      if (a is! Map || a.isEmpty) return null;
      final kind = a.keys.first as String;
      final v = (a.values.first as Map?) ?? const {};
      int n(String k) => (v[k] as num?)?.toInt() ?? 0;
      return switch (kind) {
        'toggleEffect' => MidiAction(MidiActionType.toggleEffect, slot: n('slot')),
        'nextPatch' => const MidiAction(MidiActionType.nextPatch),
        'previousPatch' => const MidiAction(MidiActionType.previousPatch),
        'selectPatch' => MidiAction(MidiActionType.selectPatch, slot: n('_0')),
        'parameter' => MidiAction(MidiActionType.parameter, slot: n('slot'), index: n('index')),
        'switchMode' => const MidiAction(MidiActionType.switchMode),
        'nothing' => const MidiAction(MidiActionType.nothing),
        _ => null,
      };
    }

    final out = <MidiMapping>[];
    try {
      for (final raw in jsonDecode(json) as List) {
        final m = raw as Map<String, dynamic>;
        final a = action(m['action']);
        if (a == null) continue;
        final t = m['trigger'];
        out.add(MidiMapping(
          id: m['id'] as String?,
          trigger: t is Map ? MidiTrigger.fromJson(t) : null,
          action: a,
          patchAction: action(m['patchAction']),
          behavior: SwitchBehavior.values.where((b) => b.name == m['behavior']).firstOrNull, // 'auto' → detect again
        ));
      }
    } catch (_) {}
    return out;
  }
}
