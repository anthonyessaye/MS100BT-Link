import 'package:material_ui/material_ui.dart';

import '../app_model.dart';
import 'native_ui.dart';

/// The same warning as the Mac app; edits only happen after the user agrees. The unlock is remembered.
Future<bool> ensureUnlocked(BuildContext context, AppModel m) async {
  if (m.editingEnabled) return true;
  if (isMac) {
    // The native app's NSAlert, word for word.
    final r = await NativeUI.alert(
      'Unlock editing?',
      'Changes you make here are sent to the pedal right away.\n\n'
          "• If the pedal's Auto Save is on, they are saved into the patch immediately.\n"
          "• If it's off, they last until you Save or switch patches.\n"
          '• Saving to a slot overwrites it (a backup is required first).\n\n'
          "The app never touches the pedal's firmware.",
      buttons: ['Unlock', 'Cancel'],
      suppression: 'Keep editing unlocked when the app restarts',
      suppressed: m.rememberUnlock,
    );
    if (r.button != 0) return false;
    m.setRememberUnlock(r.suppressed);
    m.setEditing(true);
    return true;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Unlock editing?'),
      content: const Text('Changes you make here are sent to the pedal right away.\n\n'
          '• If the pedal\'s Auto Save is on, they are saved into the patch immediately.\n'
          '• If it\'s off, they last until you save or switch patches.\n\n'
          'The app never touches the pedal\'s firmware. You can lock editing again with the lock button.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unlock')),
      ],
    ),
  );
  if (ok == true) m.setEditing(true);
  return ok == true;
}

Future<bool> confirm(BuildContext context, String title, String text, {String action = 'Continue', bool danger = false}) async {
  if (isMac) return (await NativeUI.alert(title, text, buttons: [action, 'Cancel'], critical: danger)).button == 0;
  if (!context.mounted) return false;
  return await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: danger ? Colors.redAccent : Colors.orange),
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: Colors.redAccent) : null,
            onPressed: () => Navigator.pop(c, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
}

Future<String?> askText(BuildContext context, String title, {String initial = '', String? hint, TextInputType? keyboard}) {
  if (isMac) return NativeUI.prompt(title, initial: initial, placeholder: hint);
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: keyboard,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Informational alert (NSAlert on the Mac).
Future<void> inform(BuildContext context, String title, String text) async {
  if (isMac) {
    await NativeUI.alert(title, text);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(title: Text(title), content: Text(text),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))]),
  );
}

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 5)));
