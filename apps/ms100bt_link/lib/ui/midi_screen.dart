import 'package:material_ui/material_ui.dart';

import '../midi_control.dart';
import 'native_ui.dart';
import 'widgets.dart';

/// MIDI controller mappings: Stomp/Patch modes, Learn, switch type. Port of the Mac MIDISettingsView.
class MidiScreen extends StatelessWidget {
  const MidiScreen({super.key, required this.midi, this.onClose});
  final MidiControl midi;

  /// Set when shown as a sheet on the Mac (a Done button instead of a back arrow).
  final VoidCallback? onClose;

  static final _actions = <MidiAction>[
    for (var i = 0; i < 6; i++) MidiAction(MidiActionType.toggleEffect, slot: i),
    const MidiAction(MidiActionType.previousPatch),
    const MidiAction(MidiActionType.nextPatch),
    for (var i = 0; i < 50; i++) MidiAction(MidiActionType.selectPatch, slot: i),
    for (var s = 0; s < 6; s++)
      for (var k = 0; k < 9; k++) MidiAction(MidiActionType.parameter, slot: s, index: k),
    const MidiAction(MidiActionType.switchMode),
    const MidiAction(MidiActionType.nothing),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: midi,
    builder: (context, _) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.panel,
        automaticallyImplyLeading: onClose == null,
        centerTitle: false,
        title: const Text('MIDI Control', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (isMac)
            TextButton.icon(
              onPressed: () => midi.addMapping(const MidiAction(MidiActionType.toggleEffect)),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add switch'),
            ),
          if (isMac)
            TextButton.icon(
              onPressed: NativeUI.showBluetoothMIDI,
              icon: const Icon(Icons.bluetooth, size: 16),
              label: const Text('Connect Bluetooth MIDI…'),
            ),
          IconButton(tooltip: 'Rescan devices', onPressed: midi.refreshDevices, icon: const Icon(Icons.refresh)),
          if (isMac)
            Builder(
              builder: (c) => IconButton(
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz),
                onPressed: () async {
                  if (await NativeUI.menu(c, const [NativeMenuItem('reset', 'Reset to Default Mappings')]) == 'reset') midi.resetDefaults();
                },
              ),
            )
          else
            PopupMenuButton<String>(
              onSelected: (_) => midi.resetDefaults(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'reset', child: Text('Reset to default mappings'))],
            ),
          if (onClose != null) ...[TextButton(onPressed: onClose, child: const Text('Done')), const SizedBox(width: 8)],
        ],
      ),
      floatingActionButton: isMac
          ? null // on the Mac, Add switch sits in the toolbar
          : FloatingActionButton.extended(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              onPressed: () => midi.addMapping(const MidiAction(MidiActionType.toggleEffect)),
              icon: const Icon(Icons.add),
              label: const Text('Add switch'),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        children: [
          Card(
            color: AppColors.panel,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    midi.devices.isEmpty
                        ? 'No MIDI devices. Connect a controller (USB, or Bluetooth MIDI paired in the system settings).'
                        : 'Devices: ${midi.devices.map((d) => '${d.name}${d.connected ? '' : ' (not connected)'}').join(', ')}',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Last message: ${midi.lastMessage ?? '—'}',
                    style: const TextStyle(color: AppColors.dim, fontFamily: 'monospace', fontSize: 12),
                  ),
                  if (midi.status != null) Text(midi.status!, style: const TextStyle(color: AppColors.accent)),
                  const SizedBox(height: 10),
                  SegmentedButton<ControlMode>(
                    segments: const [
                      ButtonSegment(value: ControlMode.stomp, label: Text('Stomp'), icon: Icon(Icons.power_settings_new)),
                      ButtonSegment(value: ControlMode.patch, label: Text('Patch'), icon: Icon(Icons.library_music)),
                    ],
                    selected: {midi.mode},
                    onSelectionChanged: (s) => midi.setMode(s.first),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: midi.programChangeLoadsPatch,
                    onChanged: midi.setProgramChangeLoadsPatch,
                    title: const Text('Program Change loads the patch'),
                    subtitle: const Text('PC 0–49 loads patch 01–50 (unless a switch is mapped to it).'),
                  ),
                ],
              ),
            ),
          ),
          for (final m in midi.mappings) _row(context, m),
        ],
      ),
    ),
  );

  Widget _row(BuildContext context, MidiMapping m) {
    final learning = midi.learning == m.id;
    return Card(
      color: learning ? AppColors.accent.withValues(alpha: 0.18) : AppColors.panel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    learning ? 'Press the switch on your controller…' : (m.trigger?.label ?? 'Not assigned'),
                    style: TextStyle(fontWeight: FontWeight.w700, color: learning ? AppColors.accent : null),
                  ),
                ),
                TextButton(onPressed: () => midi.learn(m.id), child: Text(learning ? 'Cancel' : 'Learn')),
                IconButton(onPressed: () => midi.remove(m.id), icon: const Icon(Icons.delete_outline, size: 20)),
              ],
            ),
            _picker('In Stomp mode', m.action, (a) => midi.update(m.id, (x) => x.action = a ?? x.action)),
            _picker('In Patch mode', m.patchAction, (a) => midi.update(m.id, (x) => x.patchAction = a), allowSame: true),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 6),
              child: PopupChoice<SwitchBehavior?>(
                label: 'Switch type',
                value: m.behavior,
                items: [(null, 'Detect on next press'), for (final b in SwitchBehavior.values) (b, b.label)],
                onChanged: (b) => midi.update(m.id, (x) => x.behavior = b),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _picker(String label, MidiAction? value, void Function(MidiAction?) onChanged, {bool allowSame = false}) => Padding(
    padding: const EdgeInsets.only(right: 8, top: 6),
    child: PopupChoice<MidiAction?>(
      label: label,
      value: value,
      items: [if (allowSame) (null, 'Same as Stomp mode'), for (final a in _actions) (a, a.label)],
      onChanged: onChanged,
    ),
  );
}
