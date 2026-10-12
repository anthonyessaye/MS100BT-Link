// Parity with Swift PatchAssistantTests.
import 'package:test/test.dart';
import 'package:zoom_core/zoom_core.dart';

import 'zoom_core_test.dart' show bourj;

void main() {
  final base = PatchDump.decode(bourj)!;
  final available = PatchAssistant.availableIds([base]);

  test('builds a patch from a spec', () {
    final edit = PatchAssistant.buildPatch({
      'name': 'Edge Dly', 'tempo': 126,
      'effects': [
        {'effect': 'comp', 'on': true, 'params': {'Sense': 6}},
        {'effect': 'Delay', 'on': true, 'params': {'Time': 357, 'F.B': '35', 'Mix': 40, 'Tail': 'ON'}},
        {'effect': 'Hall', 'on': false},
      ],
    }, base, available);
    final d = edit.decoded!;
    expect(d.name, 'Edge Dly');
    expect(d.tempo, 126);
    expect(d.effects.map((e) => e.displayName).toList(), ['Comp', 'Delay', 'Hall', '—', '—', '—']);
    expect(d.effects.map((e) => e.isOn).toList(), [true, true, false, null, null, null]);
    final delay = {for (final p in d.effects[1].parameters) p.name: p.text};
    expect(delay['Time'], '357');
    expect(delay['Tail'], 'ON');
    expect(d.effectCount, 3);
  });

  test('reports every problem', () {
    try {
      PatchAssistant.buildPatch({
        'name': 'Way too long name',
        'effects': [
          {'effect': 'Flux Capacitor'},
          {'effect': 'Hall', 'params': {'Decay': 99, 'Sparkle': 3}},
        ],
      }, base, available);
      fail('expected failure');
    } on SpecError catch (e) {
      expect(e.problems.length, 4, reason: e.toString());
    }
  });

  test('descriptions', () {
    final hall = PatchAssistant.effectDetails(['hall'], available).first;
    final knobs = hall['knobs'] as List;
    expect((knobs.first as Map)['values'], '1–30');
    expect((knobs.last as Map)['values'], ['OFF', 'ON']);
    expect(PatchAssistant.describe(base)['name'], 'Bourj');
    expect(PatchAssistant.effectList(available, category: 'Reverb'), isNotEmpty);
  });
}
