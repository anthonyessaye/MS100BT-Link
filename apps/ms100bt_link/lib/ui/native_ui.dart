import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
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

  /// NSAlert with a text field. Returns the text, or null on Cancel.
  static Future<String?> prompt(String title, {String text = '', String initial = '', String? placeholder}) =>
      _channel.invokeMethod<String>('prompt', {'title': title, 'text': text, 'initial': initial, 'placeholder': placeholder});

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
                child: CallbackShortcuts(
                  // Escape cancels a sheet, as on macOS.
                  bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
                  child: Focus(autofocus: true, child: child),
                ),
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

/// A pop-up button: shows the current choice and opens a native NSMenu (like NSPopUpButton) on the Mac,
/// a Material dropdown elsewhere.
class PopupChoice<T> extends StatelessWidget {
  const PopupChoice({super.key, required this.value, required this.items, required this.onChanged, this.label, this.width});
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final String? label;
  final double? width;

  String get _current => items.where((i) => i.$1 == value).firstOrNull?.$2 ?? '—';

  @override
  Widget build(BuildContext context) {
    if (!isMac) {
      return SizedBox(
        width: width,
        child: DropdownButtonFormField<T>(
          key: ValueKey('$label$value'),
          initialValue: items.any((i) => i.$1 == value) ? value : null,
          isExpanded: true,
          menuMaxHeight: 420,
          decoration: InputDecoration(labelText: label, isDense: true),
          items: [for (final (v, t) in items) DropdownMenuItem(value: v, child: Text(t, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => v is T ? onChanged(v) : null,
        ),
      );
    }
    final button = Builder(
      builder: (c) => GestureDetector(
        onTap: () async {
          final id = await NativeUI.menu(c, [
            for (var i = 0; i < items.length; i++) NativeMenuItem('$i', items[i].$2, checked: items[i].$1 == value),
          ]);
          if (id != null) onChanged(items[int.parse(id)].$1);
        },
        child: Container(
          width: width,
          height: 24,
          padding: const EdgeInsets.only(left: 8, right: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF3A3A3C),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: Colors.white12),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 1, offset: Offset(0, 0.5))],
          ),
          child: Row(mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max, children: [
            Flexible(child: Text(_current, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
            const SizedBox(width: 6),
            const Icon(Icons.unfold_more, size: 14, color: Colors.white70),
          ]),
        ),
      ),
    );
    if (label == null) return button;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label:', style: const TextStyle(fontSize: 13, color: Colors.white70)),
      const SizedBox(width: 8),
      Flexible(child: button),
    ]);
  }
}
