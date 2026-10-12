// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the main screens to PNGs for a visual check (not part of the normal test run):
//   flutter test test_screens --update-goldens
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms100bt_link/ai_assistant.dart';
import 'package:ms100bt_link/app_model.dart';
import 'package:ms100bt_link/effect_manager.dart';
import 'package:ms100bt_link/midi_control.dart';
import 'package:ms100bt_link/ui/effect_picker.dart';
import 'package:ms100bt_link/ui/effects_screen.dart';
import 'package:ms100bt_link/main.dart' show appTheme;
import 'package:ms100bt_link/ui/home.dart';
import 'package:ms100bt_link/ui/midi_screen.dart';
import 'package:ms100bt_link/ui/native_ui.dart';
import 'package:zoom_core/zoom_core.dart';

const fonts = '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts';
final bourj = 'F0 52 00 5E 28 02 10 00 00 06 0A 48 00 00 32 00 00 00 00 00 00 00 00 00 00 00 10 00 00 18 4C 0C 38 00 45 50 01 00 00 00 00 00 00 00 00 00 00 20 00 00 72 03 14 40 00 1F 00 43 06 00 00 00 00 00 00 00 00 60 00 28 00 4E 05 10 01 41 00 00 60 30 06 00 00 00 00 12 00 00 60 01 00 06 07 40 48 00 32 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 40 54 0F 42 00 6F 75 72 6A 20 20 20 00 20 20 00 F7'.split(' ').map((h) => int.parse(h, radix: 16)).toList();

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Black']) {
    roboto.addFont(File('$fonts/Roboto-$w.ttf').readAsBytes().then((b) => b.buffer.asByteData()));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(File('$fonts/MaterialIcons-Regular.otf').readAsBytes().then((b) => b.buffer.asByteData()));
  await icons.load();
  // The Mac's monospace font (slot numbers); a .ttc's first face is Menlo Regular.
  final menlo = File('/System/Library/Fonts/Menlo.ttc');
  if (menlo.existsSync()) {
    final mono = FontLoader('Menlo')..addFont(menlo.readAsBytes().then((b) => b.buffer.asByteData()));
    await mono.load();
  }
}

Widget app(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: home,
    );

void main() {
  setUpAll(loadFonts);

  for (final (name, size, mac) in const [
    ('home_wide', Size(1280, 800), true),
    ('home_mac_min', Size(1040, 660), true),
    ('home_phone', Size(390, 844), false),
  ]) {
    testWidgets(name, (tester) async {
      debugIsMac = mac;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final m = AppModel()
        ..patch = PatchDump.decode(bourj)
        ..currentSlot = 4;
      final fx = EffectManager(m);
      await tester.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: AIAssistant(link: m, effects: fx), midi: MidiControl(link: m))));
      await tester.pump(const Duration(milliseconds: 500));
      await expectLater(find.byType(HomeScreen), matchesGoldenFile('out/$name.png'));
    });
  }

  for (final (name, size) in const [('zsyn_1280x720', Size(1280, 720)), ('zsyn_1000x640', Size(1000, 640))]) {
    testWidgets(name, (tester) async {
      debugIsMac = true;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final zsyn = EffectCatalog.effects.entries.firstWhere((e) => e.value.name == 'Z-Syn').key;
      final m = AppModel()..patch = (PatchEdit(PatchDump.decode(bourj)!)..setEffect(3, zsyn)).decoded;
      m.selectedSlot = 3;
      final fx = EffectManager(m);
      await tester.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: AIAssistant(link: m, effects: fx), midi: MidiControl(link: m))));
      await tester.pump(const Duration(milliseconds: 500));
      await expectLater(find.byType(HomeScreen), matchesGoldenFile('out/$name.png'));
    });
  }

  testWidgets('picker', (tester) async {
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = AppModel()..patch = PatchDump.decode(bourj);
    await tester.pumpWidget(app(Scaffold(body: SizedBox(width: 980, height: 660, child: EffectPicker(model: m, slot: 0)))));
    await tester.pump();
    await expectLater(find.byType(EffectPicker), matchesGoldenFile('out/picker.png'));
  });

  testWidgets('backup_patches', (tester) async {
    debugIsMac = true;
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = AppModel()..patch = PatchDump.decode(bourj);
    for (var n = 0; n < 23; n++) {
      m.slots[n] = (PatchEdit(PatchDump.decode(bourj)!)..setName(['AmerIdiot', 'Bourj', 'Clean Funk', 'LEAD 80s', 'X'][n % 5])).decoded!;
    }
    m.backupProgress = 23;
    m.currentSlot = 22;
    final fx = EffectManager(m);
    await tester.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: AIAssistant(link: m, effects: fx), midi: MidiControl(link: m))));
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(HomeScreen), matchesGoldenFile('out/backup_patches.png'));
  });

  testWidgets('backup_effects', (tester) async {
    debugIsMac = true;
    tester.view.physicalSize = const Size(980, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = AppModel()..patch = PatchDump.decode(bourj);
    final fx = EffectManager(m)
      ..busy = 'Backing up DUAL_REV.ZDL (117/176)'
      ..progress = 117 / 176;
    await tester.pumpWidget(app(EffectsScreen(model: m, mgr: fx, onClose: () {})));
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(EffectsScreen), matchesGoldenFile('out/backup_effects.png'));
  });

  // Every MS-100BT effect in every slot position, as patches stream in during a backup.
  for (final size in const [Size(1040, 660), Size(1280, 820)]) {
    testWidgets('all_effects_${size.width.toInt()}', (tester) async {
      debugIsMac = true;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final m = AppModel()..patch = PatchDump.decode(bourj);
      final fx = EffectManager(m);
      await tester.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: AIAssistant(link: m, effects: fx), midi: MidiControl(link: m))));
      final ids = EffectCatalog.ms100btEffectIds.toList()..sort();
      final problems = <String>[];
      final where = <String>{};
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.toString();
        where.addAll(RegExp(r'(\w+):file:///\S*/lib/(\S+)').allMatches(text).map((x) => '${x[1]} lib/${x[2]}'));
        previous?.call(d);
      };
      addTearDown(() => FlutterError.onError = previous);
      for (var i = 0; i < ids.length; i++) {
        final e = PatchEdit(PatchDump.decode(bourj)!)..setName(['AmerIdiot', 'WWWWWWWWWW', 'x', 'Clean Funk'][i % 4]);
        for (var s = 0; s < 6; s++) {
          e.setEffect(s, ids[(i + s * 17) % ids.length], on: (i + s) % 3 != 0);
        }
        m.patch = e.decoded;
        m.slots[i % 50] = e.decoded!;
        m.currentSlot = i % 50;
        m.backupProgress = i % 50 + 1;
        m.selectedSlot = i % 6;
        m.notifyListeners();
        await tester.pump(const Duration(milliseconds: 50));
        final ex = tester.takeException();
        if (ex != null) problems.add('${EffectCatalog.name(ids[i])} (slot ${i % 6}): $ex');
      }
      await tester.pump(const Duration(seconds: 1));
      expect(problems, isEmpty, reason: 'AT ${where.join(' | ')}\n${problems.take(10).join('\n')}');
    });
  }

  testWidgets('mac_midi', (tester) async {
    debugIsMac = true;
    tester.view.physicalSize = const Size(760, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = AppModel();
    await tester.pumpWidget(app(MidiScreen(midi: MidiControl(link: m), onClose: () {})));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(MidiScreen), matchesGoldenFile('out/mac_midi.png'));
  });

  testWidgets('mac_effects_window', (tester) async {
    debugIsMac = true;
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = AppModel()..patch = PatchDump.decode(bourj);
    final index = EffectIndex([
      EffectMenuCategory(0x01, ['COMP.ZDL', 'RACKCOMP.ZDL']),
      EffectMenuCategory(0x03, ['BOOSTER.ZDL', 'TS_DRIVE.ZDL', 'Z_SCREAM.ZDL']),
      EffectMenuCategory(0x08, ['DELAY.ZDL', 'TAPEECHO.ZDL']),
      EffectMenuCategory(0x09, ['HALL.ZDL', 'ROOM.ZDL']),
    ], 4108);
    final fx = EffectManager(m)
      ..state = PedalFileState(maxWriteSize: 4096, totalBytes: 4143170, freeBytes: 2100000,
          files: [for (final n in index.allEffects) PedalFile(n, 9000), const PedalFile('FLST_SEQ.ZDT', 4108)], index: index, indexRaw: index.build())
      ..draft = index.copy();
    await tester.pumpWidget(app(EffectsScreen(model: m, mgr: fx, onClose: () {}, inWindow: true)));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(EffectsScreen), matchesGoldenFile('out/mac_effects_window.png'));
  });

  for (final state in ['permission', 'scan']) {
    testWidgets('android_$state', (tester) async {
      debugIsMac = false;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final m = AppModel();
      final fx = EffectManager(m);
      await tester.pumpWidget(app(HomeScreen(model: m, effects: fx, ai: AIAssistant(link: m, effects: fx), midi: MidiControl(link: m))));
      await tester.pump(const Duration(milliseconds: 300));
      m.hint = null;
      if (state == 'permission') {
        m.bluetoothProblem = BluetoothProblem.permission;
      } else {
        m.bluetoothProblem = null;
        m.nearby = [
          (address: '00:11:22:33:44:55', name: 'ZOOM MS-100BT', paired: false),
          (address: 'AA:BB:CC:DD:EE:FF', name: 'JBL Flip 5', paired: true),
        ];
      }
      m.notifyListeners();
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(find.byType(HomeScreen), matchesGoldenFile('out/android_$state.png'));
    });
  }

  testWidgets('android_bluetooth_midi', (tester) async {
    debugIsMac = false;
    MidiControl.debugAndroid = true;
    addTearDown(() => MidiControl.debugAndroid = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final midi = MidiControl(link: AppModel());
    midi.bluetoothMidi['AA:BB'] = (name: 'M-VAVE Chocolate', source: 'paired in Android settings');
    midi.bluetoothMidi['CC:DD'] = (name: 'FS-4 BLE', source: 'found nearby');
    midi.bluetoothLog.addAll(['12:00:01 [flutter_midi_command] devices: platform=[] ble=[FS-4 BLE(CC:DD)] => 1 merged']);
    await tester.pumpWidget(app(MidiScreen(midi: midi)));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(MidiScreen), matchesGoldenFile('out/android_bluetooth_midi.png'));
  });
}
