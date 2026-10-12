// Real macOS windows through Flutter's experimental windowing API (Flutter main channel, windowing flag).
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart';
import 'package:material_ui/material_ui.dart';


/// True when the app can open separate native windows (macOS with the windowing flag).
bool get canOpenWindows => isWindowingEnabled;

class _Delegate with WindowControllerDelegate {
  _Delegate(this.onDestroyed);
  final VoidCallback onDestroyed;
  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    onDestroyed();
  }
}

/// Secondary windows (Effects, Diagnostics): one instance each, brought to the front if already open,
/// like SwiftUI `Window(id:)` scenes in the native app.
abstract final class MacWindows {
  static final Map<String, (WindowEntry, WindowController)> _open = {};

  static void open(BuildContext context, String id,
      {required String title, required Size size, required Size minSize, required Widget Function(VoidCallback close) builder}) {
    final existing = _open[id];
    if (existing != null && !existing.$2.isDestroyed) {
      existing.$2.activate();
      return;
    }
    final registry = WindowRegistry.of(context);
    late final WindowEntry entry;
    late final WindowController controller;
    controller = WindowController(
      size: size,
      title: title,
      constraints: BoxConstraints(minWidth: minSize.width, minHeight: minSize.height),
      delegate: _Delegate(() {
        _open.remove(id);
        registry.unregister(entry);
      }),
    );
    entry = WindowEntry(controller: controller, builder: (_) => builder(controller.destroy));
    _open[id] = (entry, controller);
    registry.register(entry);
  }

  /// Runs the app with its main window; closing it calls [onClosed] (the app quits, as the native one does).
  static void run({required String title, required Size size, required Size minSize, required VoidCallback onClosed,
      required WidgetBuilder builder}) {
    final controller = WindowController(
      size: size,
      title: title,
      constraints: BoxConstraints(minWidth: minSize.width, minHeight: minSize.height),
      delegate: _Delegate(onClosed),
    );
    runWidget(WindowManager(initialWindows: [WindowEntry(controller: controller, builder: builder)]));
  }
}
