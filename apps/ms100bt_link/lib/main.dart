import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_assistant.dart';
import 'app_model.dart';
import 'effect_manager.dart';
import 'midi_control.dart';
import 'ui/home.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {} // settings are then not remembered; everything else works
  runApp(MS100BTLinkApp(prefs: prefs));
}

class MS100BTLinkApp extends StatefulWidget {
  const MS100BTLinkApp({super.key, this.prefs});
  final SharedPreferences? prefs;

  @override
  State<MS100BTLinkApp> createState() => _MS100BTLinkAppState();
}

class _MS100BTLinkAppState extends State<MS100BTLinkApp> {
  late final model = AppModel(prefs: widget.prefs);
  late final effects = EffectManager(model);
  late final ai = AIAssistant(link: model, effects: effects, prefs: widget.prefs);
  late final midi = MidiControl(link: model, prefs: widget.prefs);

  @override
  void dispose() {
    midi.dispose();
    ai.dispose();
    effects.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MS-100BT Link',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: Brightness.dark),
          scaffoldBackgroundColor: AppColors.background,
          useMaterial3: true,
        ),
        home: HomeScreen(model: model, effects: effects, ai: ai, midi: midi),
      );
}
