// Renders the README screenshots into docs/media (demo data; no Bluetooth, no AI provider):
//   ~/development/flutter-main/bin/flutter test test_screens/readme_screenshots_test.dart --update-goldens
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ms100bt_link/ai_assistant.dart';
import 'package:ms100bt_link/app_model.dart';
import 'package:ms100bt_link/bluetooth.dart';
import 'package:ms100bt_link/effect_manager.dart';
import 'package:ms100bt_link/midi_control.dart';
import 'package:ms100bt_link/ui/effect_picker.dart';
import 'package:ms100bt_link/ui/home.dart';
import 'package:ms100bt_link/ui/midi_screen.dart';
import 'package:ms100bt_link/ui/native_ui.dart';
import 'package:zoom_core/zoom_core.dart';

import 'render_test.dart' show app, bourj, loadFonts;

const _names = ['AmerIdiot', 'Bourj', 'Clean Funk', 'LEAD 80s', 'Shimmer', 'Blues Bar', 'Ambient', 'Edge Dly', 'Fuzz Wall', 'Acoustic'];

PatchDump _patch(String name, int tempo, List<(String, bool)> fx) {
  final base = PatchDump.decode(bourj)!;
  final e = PatchAssistant.buildPatch({
    'name': name,
    'tempo': tempo,
    'effects': [for (final (n, on) in fx) {'effect': n, 'on': on}],
  }, base, PatchAssistant.availableIds([base]));
  return e.decoded!;
}

AppModel _model() {
  final m = AppModel()
    ..device = const PairedDevice('00:00:00:00:00:00', 'ZOOM MS-100BT')
    ..patch = _patch('AmerIdiot', 186, [('ZNR', true), ('Booster', false), ('MS 1959', true), ('MonoSynth', true)])
    ..currentSlot = 0
    ..selectedSlot = 3;
  final chains = [
    [('ZNR', true), ('Booster', false), ('MS 1959', true), ('MonoSynth', true)],
    [('Comp', true), ('T Scream', true), ('Room', true)],
    [('Comp', true), ('Phaser', true), ('Room', true)],
    [('Booster', true), ('MS 1959', true), ('Delay', true), ('Hall', true)],
  ];
  for (var n = 0; n < 50; n++) {
    m.slots[n] = _patch(_names[n % _names.length], 120, chains[n % chains.length]);
  }
  return m;
}

Future<void> _size(WidgetTester t, Size logical) async {
  t.view.physicalSize = logical * 2; // crisp at 2x
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
}

void main() {
  setUpAll(loadFonts);
  setUp(() => debugIsMac = true);

  testWidgets('main', (t) async {
    await _size(t, const Size(1280, 820));
    final m = _model();
    final fx = EffectManager(m);
    await t.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: AIAssistant(link: m, effects: fx), midi: MidiControl(link: m))));
    await t.pump(const Duration(seconds: 1));
    await expectLater(find.byType(HomeScreen), matchesGoldenFile('../../../docs/media/main.png'));
  });

  testWidgets('assistant', (t) async {
    await _size(t, const Size(1280, 820));
    final m = _model();
    final fx = EffectManager(m);
    final ai = AIAssistant(link: m, effects: fx)..debugShowAsConfigured();
    final p = _patch('Blues Bar', 92, [('Comp', true), ('T Scream', true), ('Room', true)]);
    ai.proposals[0] = Proposal(0, PatchEdit(p), p);
    ai.items.addAll([
      const ChatItem(ChatKind.user, 'A warm blues crunch with a touch of room reverb'),
      const ChatItem(ChatKind.activity, 'Browsed 20 effects in Drive'),
      const ChatItem(ChatKind.activity, 'Looked up T Scream, Room'),
      const ChatItem(ChatKind.assistant,
          'A light compressor into a Tube Screamer-style drive keeps the crunch touch-sensitive; a small room adds air without washing it out.'),
      const ChatItem(ChatKind.proposal, 'Blues Bar', proposalId: 0),
    ]);
    await t.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: ai, midi: MidiControl(link: m), initialSidebar: Sidebar.assistant)));
    await t.pump(const Duration(seconds: 1));
    await expectLater(find.byType(HomeScreen), matchesGoldenFile('../../../docs/media/assistant.png'));
  });

  testWidgets('effect library', (t) async {
    await _size(t, const Size(980, 660));
    await t.pumpWidget(app(Scaffold(body: EffectPicker(model: _model(), slot: 3))));
    await t.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(EffectPicker), matchesGoldenFile('../../../docs/media/effect-library.png'));
  });

  testWidgets('midi', (t) async {
    await _size(t, const Size(760, 640));
    final midi = MidiControl(link: AppModel());
    for (var i = 0; i < midi.mappings.length; i++) {
      midi.mappings[i]
        ..trigger = MidiTrigger(MidiKind.cc, 1, 80 + i)
        ..behavior = SwitchBehavior.latching;
    }
    midi.lastMessage = 'CC 82 = 127 · ch 1';
    await t.pumpWidget(app(MidiScreen(midi: midi, onClose: () {})));
    await t.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(MidiScreen), matchesGoldenFile('../../../docs/media/midi.png'));
  });

  testWidgets('android', (t) async {
    debugIsMac = false;
    await _size(t, const Size(390, 844));
    final m = _model();
    final fx = EffectManager(m);
    await t.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: AIAssistant(link: m, effects: fx), midi: MidiControl(link: m))));
    await t.pump(const Duration(seconds: 1));
    await expectLater(find.byType(HomeScreen), matchesGoldenFile('../../../docs/media/android.png'));
  });
}
