import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_assistant.dart';
import 'app_model.dart';
import 'effect_manager.dart';
import 'mac_windows.dart';
import 'midi_control.dart';
import 'ui/home.dart';
import 'ui/native_ui.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {} // settings are then not remembered; everything else works
  if (isMac && canOpenWindows) {
    // The Mac build: real windows (main, Effects, Diagnostics) sharing one set of models.
    final models = AppModels(prefs);
    MacWindows.run(
      title: 'MS-100BT Link',
      size: const Size(1280, 820),
      minSize: const Size(1040, 660), // the native app's minimum
      onClosed: () async {
        await models.app.disconnect(); // leave edit mode and close the link first, as the native app does
        ServicesBinding.instance.exitApplication(AppExitType.required);
      },
      builder: (_) => appShell(HomeScreen(model: models.app, effects: models.effects, ai: models.ai, midi: models.midi)),
    );
    return;
  }
  runApp(MS100BTLinkApp(prefs: prefs));
}

/// Everything the windows share: connection, effects, assistant, MIDI.
class AppModels {
  AppModels(SharedPreferences? prefs) : app = AppModel(prefs: prefs), prefs = prefs {
    effects = EffectManager(app);
    ai = AIAssistant(link: app, effects: effects, prefs: prefs);
    midi = MidiControl(link: app, prefs: prefs);
  }
  final SharedPreferences? prefs;
  final AppModel app;
  late final EffectManager effects;
  late final AIAssistant ai;
  late final MidiControl midi;

  void dispose() {
    midi.dispose();
    ai.dispose();
    effects.dispose();
    app.dispose();
  }
}

ThemeData appTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: Brightness.dark),
    scaffoldBackgroundColor: AppColors.background,
    useMaterial3: true,
  );
  return isMac ? _macTheme(base) : base;
}

/// The Mac build behaves like a Mac app, not a phone: no ink ripples, the arrow cursor on controls,
/// compact 13-pt controls, small toolbars, bordered fields, slow small tooltips, floating notices.
ThemeData _macTheme(ThemeData base) {
  const radius = BorderRadius.all(Radius.circular(6));
  const arrow = WidgetStatePropertyAll<MouseCursor>(SystemMouseCursors.basic);
  final family = Typography.englishLike2021.merge(base.textTheme).bodyMedium?.fontFamily ?? base.textTheme.bodyMedium?.fontFamily;
  final buttonText = WidgetStatePropertyAll(TextStyle(fontFamily: family, fontSize: 13, fontWeight: FontWeight.w500));
  const buttonShape = WidgetStatePropertyAll<OutlinedBorder>(RoundedRectangleBorder(borderRadius: radius));
  const buttonPadding = WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 4));
  const buttonSize = WidgetStatePropertyAll(Size(0, 28));
  final hover = WidgetStateProperty.resolveWith<Color?>(
    (s) => s.contains(WidgetState.pressed) ? Colors.white24 : (s.contains(WidgetState.hovered) ? Colors.white10 : null),
  );
  ButtonStyle mac(ButtonStyle? s) => (s ?? const ButtonStyle()).copyWith(
    mouseCursor: arrow,
    shape: buttonShape,
    padding: buttonPadding,
    minimumSize: buttonSize,
    textStyle: buttonText,
    overlayColor: hover,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
  );
  final text = Typography.englishLike2021
      .merge(base.textTheme)
      .apply(fontSizeFactor: 0.93, bodyColor: AppColors.text, displayColor: AppColors.text);
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.white10,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.panel,
      toolbarHeight: 44,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true, // macOS window toolbars centre the title
      titleTextStyle: TextStyle(fontFamily: family, fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.text),
      iconTheme: const IconThemeData(size: 18),
      actionsIconTheme: const IconThemeData(size: 18),
    ),
    filledButtonTheme: FilledButtonThemeData(style: mac(base.filledButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: mac(base.textButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: mac(base.outlinedButtonTheme.style)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: mac(base.elevatedButtonTheme.style)),
    iconButtonTheme: IconButtonThemeData(
      style: const ButtonStyle(
        mouseCursor: arrow,
        splashFactory: NoSplash.splashFactory,
        visualDensity: VisualDensity.compact,
      ).copyWith(overlayColor: hover),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Color(0xFF1C1C1E),
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: Colors.white24),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: Colors.white24),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: AppColors.accent, width: 2),
      ),
    ),
    listTileTheme: const ListTileThemeData(dense: true, mouseCursor: arrow, visualDensity: VisualDensity.compact),
    chipTheme: base.chipTheme.copyWith(shape: const RoundedRectangleBorder(borderRadius: radius)),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 900),
      textStyle: TextStyle(fontFamily: family, fontSize: 11, color: Colors.white),
      decoration: BoxDecoration(
        color: const Color(0xEE3A3A3C),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating, // a small floating notice, not a phone strip
      width: 440,
      backgroundColor: const Color(0xF22C2C2E),
      contentTextStyle: TextStyle(fontFamily: family, fontSize: 13, color: AppColors.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Colors.white12),
      ),
      elevation: 8,
    ),
    scrollbarTheme: const ScrollbarThemeData(thickness: WidgetStatePropertyAll(6), radius: Radius.circular(3)),
    dialogTheme: const DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)))),
    popupMenuTheme: const PopupMenuThemeData(mouseCursor: arrow),
    dividerTheme: const DividerThemeData(color: AppColors.stroke, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.macOS: _NoTransition()}),
  );
}

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> a, Animation<double> b, Widget child) => child;
}

/// One window's app shell (each window has its own navigator and overlays).
Widget appShell(Widget home) => MaterialApp(title: 'MS-100BT Link', debugShowCheckedModeBanner: false, theme: appTheme(), home: home);

class MS100BTLinkApp extends StatefulWidget {
  const MS100BTLinkApp({super.key, this.prefs});
  final SharedPreferences? prefs;

  @override
  State<MS100BTLinkApp> createState() => _MS100BTLinkAppState();
}

class _MS100BTLinkAppState extends State<MS100BTLinkApp> {
  late final models = AppModels(widget.prefs);

  @override
  void dispose() {
    models.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => appShell(HomeScreen(model: models.app, effects: models.effects, ai: models.ai, midi: models.midi));
}
