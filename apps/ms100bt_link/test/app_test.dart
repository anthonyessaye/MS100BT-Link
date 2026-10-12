import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms100bt_link/app_model.dart';
import 'package:ms100bt_link/effect_manager.dart';
import 'package:ms100bt_link/legacy_mac.dart';
import 'package:ms100bt_link/main.dart';
import 'package:ms100bt_link/midi_control.dart';
import 'package:ms100bt_link/ai_assistant.dart';
import 'package:ms100bt_link/ui/assistant_screen.dart';
import 'package:ms100bt_link/ui/effects_screen.dart';
import 'package:ms100bt_link/ui/midi_screen.dart';
import 'package:ms100bt_link/ui/native_ui.dart';
import 'package:ms100bt_link/ui/patches_screen.dart';
import 'package:zoom_core/zoom_core.dart';

void main() {
  setUp(() => debugIsMac = false); // phone/tablet behaviour unless a test says otherwise

  testWidgets('starts on the connect screen without a pedal', (tester) async {
    await tester.pumpWidget(const MS100BTLinkApp());
    await tester.pump();
    expect(find.text('Pair your MS-100BT'), findsOneWidget); // no paired device in tests
    expect(find.byIcon(Icons.lock), findsOneWidget); // compact bar at 800 px: lock + overflow menu
    expect(find.text('Patches'), findsOneWidget); // docked Patches sidebar
  });

  // The 1040 × 660 minimum is checked with real fonts in test_screens (the test font's glyphs are wider).
  testWidgets('Mac: full pill bar in the default window', (tester) async {
    debugIsMac = true;
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MS100BTLinkApp());
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final t in ['Locked', 'Effects', 'AI', 'MIDI', 'STOMP']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
  });

  group('MIDI', () {
    test('parses channel messages and ignores the rest', () {
      final cc = MidiInput.parse([0xB2, 80, 127])!;
      expect((cc.kind, cc.channel, cc.number, cc.value, cc.isPress), (MidiKind.cc, 3, 80, 127, true));
      expect(MidiInput.parse([0x80, 60, 64])!.value, 0); // note-off is a release
      expect(MidiInput.parse([0xC0, 5])!.kind, MidiKind.program);
      expect(MidiInput.parse([0xF0, 0x7E, 0xF7]), isNull);
      expect(MidiInput.parse([0xB0, 1]), isNull);
    });

    test('learn assigns the trigger; a quick release marks the switch momentary', () async {
      final midi = MidiControl(link: AppModel());
      final id = midi.mappings.first.id;
      midi.learn(id);
      midi.receive(MidiInput.parse([0xB0, 80, 127])!);
      expect(midi.mappings.first.trigger?.label, 'CC 80 · ch 1');
      midi.receive(MidiInput.parse([0xB0, 80, 0])!); // release within the window
      expect(midi.mappings.first.behavior, SwitchBehavior.momentary);
    });

    test('a press with no release marks the switch latching', () async {
      final midi = MidiControl(link: AppModel());
      midi.mappings.first.trigger = const MidiTrigger(MidiKind.cc, 1, 81);
      midi.receive(MidiInput.parse([0xB0, 81, 127])!);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(midi.mappings.first.behavior, SwitchBehavior.latching);
    });

    test('presses while disconnected never reach the pedal', () {
      final midi = MidiControl(link: AppModel());
      midi.mappings.first.trigger = const MidiTrigger(MidiKind.cc, 1, 82);
      midi.receive(MidiInput.parse([0xB0, 82, 127])!);
      expect(midi.status, contains("isn't connected"));
    });

    test('mappings survive a save/load round trip', () {
      final m = MidiMapping(
          trigger: const MidiTrigger(MidiKind.note, 2, 60),
          action: const MidiAction(MidiActionType.parameter, slot: 2, index: 4),
          patchAction: const MidiAction(MidiActionType.selectPatch, slot: 9),
          behavior: SwitchBehavior.latching);
      final back = MidiMapping.fromJson(m.toJson().map((k, v) => MapEntry(k, v)));
      expect(back.trigger?.label, m.trigger?.label);
      expect(back.action, m.action);
      expect(back.patchAction, m.patchAction);
      expect(back.behavior, SwitchBehavior.latching);
    });
  });

  testWidgets('the risk dialog refuses a plan without a pedal read', (tester) async {
    final mgr = EffectManager(AppModel());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      return TextButton(onPressed: () => showDialog<bool>(context: c, builder: (_) => ConfirmApplyDialog(mgr: mgr)), child: const Text('open'));
    }))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('This change is refused:'), findsOneWidget);
    final install = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Install on pedal'));
    expect(install.onPressed, isNull, reason: 'install stays disabled while the plan is refused');
  });

  test('effects apply is refused while editing is locked', () async {
    final link = AppModel();
    final mgr = EffectManager(link);
    await mgr.apply();
    expect(mgr.alert, 'Unlock editing first.');
    expect(link.editingEnabled, isFalse);
    expect(Allowlist.protectedFiles, contains('PAIR.DAT'));
  });

  // Every screen renders without layout overflow at phone and desktop sizes (no pedal connected).
  for (final size in const [Size(375, 812), Size(1280, 800)]) {
    testWidgets('screens lay out at ${size.width.toInt()} px', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final link = AppModel();
      final mgr = EffectManager(link);
      final ai = AIAssistant(link: link, effects: mgr);
      final midi = MidiControl(link: link);
      for (final screen in <Widget>[
        PatchesScreen(model: link),
        EffectsScreen(model: link, mgr: mgr),
        AssistantScreen(model: link, ai: ai),
        MidiScreen(midi: midi),
      ]) {
        await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: screen));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: '${screen.runtimeType}');
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('not-downloaded effects: listed by name, downloaded ones excluded, always with how to get them', () {
    final mgr = EffectManager(AppModel())
      ..remote = const [
        RemoteEffect('SHATTER.ZDL', null, 'themanro', 5770),
        RemoteEffect('SHATTER.ZDL', null, 'themanro', 5770), // listed twice in a repo: shown once
        RemoteEffect('WAVEFOLD.ZDL', null, 'matujuice', 9000),
        RemoteEffect('SVT.ZDL', 'MS-60B', 'stock', 20000),
      ];
    final all = mgr.searchNotDownloaded('');
    expect(all.map((e) => e['file']), ['SHATTER.ZDL', 'WAVEFOLD.ZDL', 'SVT.ZDL']);
    expect(all.every((e) => '${e['how_to_get']}'.contains('Download effects')), isTrue);
    expect(all.every((e) => '${e['status']}'.startsWith('Not downloaded')), isTrue);
    expect(mgr.searchNotDownloaded('wave').map((e) => e['file']), ['WAVEFOLD.ZDL']);
    expect(mgr.searchNotDownloaded('ms60b').single['from_pedal'], 'MS-60B');
  });

  testWidgets('phone: Add switch shows a new switch waiting for a press', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final midi = MidiControl(link: AppModel());
    await tester.pumpWidget(MaterialApp(home: MidiScreen(midi: midi)));
    final before = midi.mappings.length;
    await tester.tap(find.text('Add switch'));
    await tester.pumpAndSettle();
    expect(midi.mappings.length, before + 1);
    expect(find.text('Press the switch on your controller…'), findsWidgets);
  });

  test('native Mac app MIDI mappings convert (real export: 8 latching switches)', () {
    const native = r'''[{"trigger":{"channel":1,"kind":"cc","number":80},"action":{"toggleEffect":{"slot":0}},"id":"C82ED464-7ABF-453E-A145-781A24940FB4","patchAction":{"selectPatch":{"_0":0}},"behavior":"latching"},{"trigger":{"channel":1,"kind":"cc","number":81},"action":{"toggleEffect":{"slot":1}},"id":"AA738C92-E02E-4684-9823-9FB197CCFB57","patchAction":{"selectPatch":{"_0":1}},"behavior":"latching"},{"trigger":{"channel":1,"kind":"cc","number":82},"action":{"toggleEffect":{"slot":2}},"id":"C1347E8A-D1B9-42D1-81AD-D8459F1957A3","patchAction":{"selectPatch":{"_0":2}},"behavior":"latching"},{"trigger":{"channel":1,"kind":"cc","number":83},"action":{"toggleEffect":{"slot":3}},"id":"8878A468-0293-4F5F-8C71-08742EBBC2E6","patchAction":{"selectPatch":{"_0":3}},"behavior":"latching"},{"trigger":{"channel":1,"kind":"cc","number":84},"action":{"toggleEffect":{"slot":4}},"id":"6A4AFFC7-4F6D-477F-B09D-35164E5093DA","patchAction":{"selectPatch":{"_0":4}},"behavior":"latching"},{"trigger":{"channel":1,"kind":"cc","number":85},"action":{"toggleEffect":{"slot":5}},"id":"D95CEB0F-9682-4F69-A9AB-A56027EBE6F4","patchAction":{"selectPatch":{"_0":5}},"behavior":"latching"},{"trigger":{"channel":1,"kind":"cc","number":86},"action":{"previousPatch":{}},"id":"4744663A-C0DE-4251-9952-611F1C247C6E","behavior":"latching"},{"trigger":{"channel":1,"kind":"cc","number":87},"action":{"nextPatch":{}},"id":"CD5AF8A3-7A17-42FE-AF35-0A5AB8B1FBB3","behavior":"latching"}]''';
    final m = LegacyMac.convertMappings(native);
    expect(m.length, 8);
    expect(m.first.trigger?.label, 'CC 80 · ch 1');
    expect(m.first.action, const MidiAction(MidiActionType.toggleEffect, slot: 0));
    expect(m.first.patchAction, const MidiAction(MidiActionType.selectPatch, slot: 0));
    expect(m.every((x) => x.behavior == SwitchBehavior.latching), isTrue);
    expect(m.map((x) => x.action.type), containsAll([MidiActionType.nextPatch, MidiActionType.previousPatch]));
    expect(LegacyMac.convertMappings('not json'), isEmpty);
  });

  test('a not-installed effect can never be placed in a proposal', () {
    final base = PatchDump.decode(bourjBytes)!;
    expect(
      () => PatchAssistant.buildPatch({
        'effects': [
          {'effect': 'Shatter'},
        ],
      }, base, PatchAssistant.availableIds([base])),
      throwsA(isA<SpecError>()),
    );
  });
}

final bourjBytes = ('F0 52 00 5E 28 02 10 00 00 06 0A 48 00 00 32 00 00 00 00 00 00 00 00 00 00 00 10 00 00 18 4C 0C 38 00 45 50 01 00 00 00 00 00 '
        '00 00 00 00 00 20 00 00 72 03 14 40 00 1F 00 43 06 00 00 00 00 00 00 00 00 60 00 28 00 4E 05 10 01 41 00 00 60 30 06 00 00 00 00 12 00 '
        '00 60 01 00 06 07 40 48 00 32 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 40 54 0F '
        '42 00 6F 75 72 6A 20 20 20 00 20 20 00 F7')
    .split(' ')
    .map((h) => int.parse(h, radix: 16))
    .toList();
