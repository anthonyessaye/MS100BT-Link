import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// True on the Mac build, which behaves like the native Mac app (alerts, sheets, menus, window).
bool get isMac => debugIsMac ?? (!kIsWeb && Platform.isMacOS);

/// Tests force the Mac or the phone/tablet behaviour (they run on a Mac host).
@visibleForTesting
bool? debugIsMac;

/// Native macOS pieces (MainFlutterWindow.swift, UIBridge).
abstract final class NativeUI {
  static const _channel = MethodChannel('ms100bt/ui');

  /// NSAlert. Returns the index of the button pressed and the state of the optional checkbox.
  static Future<({int button, bool suppressed})> alert(String title, String text,
      {List<String> buttons = const ['OK'], String? suppression, bool suppressed = false, bool critical = false}) async {
    final r = await _channel.invokeMapMethod<String, Object?>('alert', {
      'title': title, 'text': text, 'buttons': buttons, 'suppression': suppression, 'suppressed': suppressed, 'critical': critical,
    });
    return (button: (r?['button'] as int?) ?? -1, suppressed: r?['suppressed'] == true);
  }

  /// Native NSMenu below [anchor] (a widget's context). Returns the chosen item's id.
  static Future<String?> menu(BuildContext anchor, List<NativeMenuItem> items) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final at = box == null ? Offset.zero : box.localToGlobal(Offset(0, box.size.height + 4));
    return _channel.invokeMethod<String>('menu', {
      'x': at.dx,
      'y': at.dy,
      'items': [for (final i in items) i.toMap()],
    });
  }

  static Future<void> showBluetoothMIDI() => _channel.invokeMethod<void>('bluetoothMIDI');

  /// Menu-bar commands (Window → Effects, MIDI Control, Diagnostics).
  static void onMenu(void Function(String id) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'menu' && call.arguments is String) handler(call.arguments as String);
    });
  }
}

/// A macOS-style sheet: slides down from the top of the window, dims the window behind it.
Future<T?> showSheet<T>(BuildContext context, Widget child, {Size size = const Size(980, 640)}) => showGeneralDialog<T>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) {
        final screen = MediaQuery.sizeOf(context);
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 28),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: size.width.clamp(320, screen.width - 32),
                height: size.height.clamp(240, screen.height - 48),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 12))],
                ),
                child: child,
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, -0.08), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: FadeTransition(opacity: anim, child: child),
      ),
    );

class NativeMenuItem {
  const NativeMenuItem(this.id, this.title, {this.checked = false, this.enabled = true}) : separator = false;
  const NativeMenuItem.separator()
      : id = '',
        title = '',
        checked = false,
        enabled = false,
        separator = true;
  final String id, title;
  final bool checked, enabled, separator;
  Map<String, Object> toMap() => {'id': id, 'title': title, 'checked': checked, 'enabled': enabled, 'separator': separator};
}
