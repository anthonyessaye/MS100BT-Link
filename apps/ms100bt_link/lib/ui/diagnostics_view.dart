import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import 'widgets.dart';

/// Developer view: connection details, identity, and the raw console. Port of DiagnosticsView.swift.
class DiagnosticsView extends StatefulWidget {
  const DiagnosticsView({super.key, required this.model, required this.onClose, this.inWindow = false});
  final AppModel model;
  final VoidCallback onClose;

  /// In its own window: closed with the window's close button, no Done button.
  final bool inWindow;

  @override
  State<DiagnosticsView> createState() => _DiagnosticsViewState();
}

class _DiagnosticsViewState extends State<DiagnosticsView> {
  AppModel get m => widget.model;
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {})); // the console has no notifier
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          final log = m.session?.log ?? const <String>[];
          final id = m.session?.identity;
          final p = m.patch;
          return Scaffold(
            backgroundColor: AppColors.background,
            appBar: AppBar(
              backgroundColor: AppColors.panel,
              automaticallyImplyLeading: false,
              title: const Text('Diagnostics', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              actions: [if (!widget.inWindow) ...[TextButton(onPressed: widget.onClose, child: const Text('Done')), const SizedBox(width: 8)]],
            ),
            body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 360,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  if (m.hint != null)
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                      child: Text(m.hint!),
                    ),
                  _panel('Device', [
                    _kv('Name', m.device?.name ?? '—'),
                    _kv('Address', m.device?.address ?? '—'),
                    _kv('State', m.busy ?? (m.isConnected ? 'Connected' : 'Not connected')),
                    const SizedBox(height: 10),
                    Wrap(spacing: 10, children: [
                      if (m.isConnected) ...[
                        FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: Colors.blue),
                            onPressed: m.busy == null ? m.resumeAfterFileSystem : null,
                            icon: const Icon(Icons.sync, size: 16),
                            label: const Text('Refresh')),
                        FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: m.disconnect,
                            icon: const Icon(Icons.cancel_outlined, size: 16),
                            label: const Text('Disconnect')),
                      ] else
                        FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: Colors.green),
                            onPressed: m.device == null || m.busy != null ? null : m.connect,
                            icon: const Icon(Icons.wifi_tethering, size: 16),
                            label: const Text('Connect')),
                    ]),
                  ]),
                  _panel('Pedal', [
                    _kv('Device ID', id == null ? '—' : '0x${id.deviceId.toRadixString(16).toUpperCase()}'),
                    _kv('Firmware', id?.version ?? '—'),
                    _kv('Patch', p == null ? '—' : '${p.name ?? '?'} · ${p.tempo ?? '?'} BPM'),
                    _kv('Edit mode', m.session?.editModeActive == true ? 'held' : 'off'),
                    _kv('Writes', m.editingEnabled ? 'unlocked' : 'locked'),
                  ]),
                  _panel('Platform', [for (final e in m.diagnostics.entries) _kv(e.key, '${e.value}')]),
                ]),
              ),
              const VerticalDivider(width: 1, color: AppColors.stroke),
              Expanded(
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                    child: Row(children: [
                      Text('Console · ${log.length} lines', style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      TextButton(
                        onPressed: log.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: log.join('\n'))),
                        child: const Text('Copy'),
                      ),
                    ]),
                  ),
                  Expanded(
                    child: Container(
                      color: Colors.black26,
                      child: log.isEmpty
                          ? const Center(child: Text('Nothing sent or received yet.', style: TextStyle(color: AppColors.dim)))
                          : ListView.builder(
                              controller: _scroll,
                              reverse: true, // newest at the bottom, stays scrolled down
                              padding: const EdgeInsets.all(12),
                              itemCount: log.length,
                              itemBuilder: (_, i) {
                                final line = log[log.length - 1 - i];
                                return SelectableText(line,
                                    style: TextStyle(
                                        fontFamily: 'Menlo', fontSize: 11, color: line.startsWith('→') ? AppColors.accent : AppColors.text));
                              },
                            ),
                    ),
                  ),
                ]),
              ),
            ]),
          );
        },
      );

  Widget _panel(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.panel, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...children,
        ]),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 90, child: Text(k, style: const TextStyle(color: AppColors.dim, fontSize: 12))),
          Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 12))),
        ]),
      );
}
