// Renders the main screens to PNGs for a visual check (not part of the normal test run):
//   flutter test test_screens --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms100bt_link/ai_assistant.dart';
import 'package:ms100bt_link/app_model.dart';
import 'package:ms100bt_link/effect_manager.dart';
import 'package:ms100bt_link/midi_control.dart';
import 'package:ms100bt_link/ui/effect_picker.dart';
import 'package:ms100bt_link/ui/home.dart';
import 'package:ms100bt_link/ui/widgets.dart';
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
}

Widget app(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: Brightness.dark),
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      home: home,
    );

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in const [('home_wide', Size(1280, 800)), ('home_phone', Size(390, 844))]) {
    testWidgets(name, (tester) async {
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

  testWidgets('picker', (tester) async {
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = AppModel()..patch = PatchDump.decode(bourj);
    await tester.pumpWidget(app(Scaffold(body: SizedBox(width: 980, height: 660, child: EffectPicker(model: m, slot: 0)))));
    await tester.pump();
    await expectLater(find.byType(EffectPicker), matchesGoldenFile('out/picker.png'));
  });
}
