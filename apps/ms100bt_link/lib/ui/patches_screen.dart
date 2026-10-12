import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zoom_core/zoom_core.dart';

import '../app_model.dart';
import '../storage.dart';
import 'dialogs.dart';
import 'native_ui.dart';
import 'widgets.dart';

/// Patches as a page (phones). On wide screens [PatchList] is docked as the right sidebar, as on the Mac.
class PatchesScreen extends StatelessWidget {
  const PatchesScreen({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.panel,
    appBar: AppBar(backgroundColor: AppColors.panel, title: const Text('Patches')),
    body: SafeArea(child: PatchList(model: model)),
  );
}

/// Sidebar panel with a header and close button (the Mac SidebarView).
class PatchesPanel extends StatelessWidget {
  const PatchesPanel({super.key, required this.model, required this.onClose});
  final AppModel model;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.panel,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              const Text('Patches', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const Spacer(),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 16, color: AppColors.dim),
              ),
            ],
          ),
        ),
        Expanded(child: PatchList(model: model)),
      ],
    ),
  );
}

class PatchList extends StatefulWidget {
  const PatchList({super.key, required this.model});
  final AppModel model;

  @override
  State<PatchList> createState() => _PatchListState();
}

class _PatchListState extends State<PatchList> {
  AppModel get m => widget.model;
  String query = '';

  static const _syx = XTypeGroup(label: 'SysEx patch', extensions: ['syx'], uniformTypeIdentifiers: ['public.data']);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final known = {...?m.library?.patches, ...m.slots};
      final rows = [
        for (var n = 0; n < Allowlist.patchSlots; n++)
          if (query.isEmpty || (known[n]?.name ?? '').toLowerCase().contains(query.toLowerCase())) n,
      ];
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              onChanged: (v) => setState(() => query = v),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search patches',
                isDense: true,
                filled: true,
                fillColor: AppColors.panelRaised,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: rows.length,
              itemBuilder: (context, i) => _row(rows[i], known[rows[i]]),
            ),
          ),
          _footer(),
        ],
      );
    },
  );

  Widget _row(int n, PatchDump? p) {
    final active = m.currentSlot == n;
    return Tooltip(
      message: p == null ? 'Back up to see this patch' : p.effects.where((e) => !e.isEmpty).map((e) => e.displayName).join(' → '),
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: m.canInteract
            ? () async {
                if (await ensureUnlocked(context, m)) await m.selectPatch(n);
              }
            : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          decoration: BoxDecoration(color: active ? Colors.white.withValues(alpha: 0.07) : null, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: active ? AppColors.accent : null, borderRadius: BorderRadius.circular(4)),
                child: Text(
                  (n + 1).toString().padLeft(2, '0'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Menlo',
                    color: active ? Colors.black : AppColors.dim,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p?.name ?? 'Unknown',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p == null ? AppColors.dim : AppColors.text),
                    ),
                    if (p != null) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          for (final fx in p.effects.where((e) => !e.isEmpty))
                            Container(
                              width: 14,
                              height: 6,
                              margin: const EdgeInsets.only(right: 3),
                              decoration: BoxDecoration(
                                color: AppColors.category(fx.category).withValues(alpha: fx.isOn == true ? 1 : 0.4),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer() => Container(
    width: double.infinity,
    color: AppColors.panelRaised,
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m.backupProgress != null) ...[
          Text('Reading patch ${m.backupProgress} of 50…', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: m.backupProgress! / 50, color: AppColors.accent),
        ] else
          Text(
            m.library == null ? 'No backup yet: back up before saving' : 'Last backup ${m.library!.date}',
            style: TextStyle(fontSize: 12, color: m.library == null ? AppColors.accent : AppColors.dim),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity, // so spaceBetween spreads the buttons
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: m.canInteract && m.backupProgress == null ? _backup : null,
                child: const Text('Back up all'),
              ),
              _saveTo(),
            ],
          ),
        ),
        Wrap(
          children: [
            TextButton(
              onPressed: m.patch == null ? null : _export,
              child: const Text('Export patch…', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: m.canInteract ? _import : null,
              child: const Text('Import…', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    ),
  );

  String _slotTitle(int n) => '${(n + 1).toString().padLeft(2, '0')}  ${(m.slots[n] ?? m.library?.patches[n])?.name ?? '—'}';

  /// "Save to…": a native NSMenu on the Mac (as in the native app), a Material popup elsewhere.
  Widget _saveTo() {
    final enabled = m.canInteract && m.library != null;
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text('Save to… ▾', style: TextStyle(color: enabled ? AppColors.text : AppColors.dim)),
    );
    if (isMac) {
      return Builder(
        builder: (c) => GestureDetector(
          onTap: !enabled
              ? null
              : () async {
                  final id = await NativeUI.menu(c, [for (var n = 0; n < Allowlist.patchSlots; n++) NativeMenuItem('$n', _slotTitle(n))]);
                  if (id != null) await _store(int.parse(id));
                },
          child: label,
        ),
      );
    }
    return PopupMenuButton<int>(
      enabled: enabled,
      tooltip: 'Store the current patch into a memory slot',
      onSelected: _store,
      itemBuilder: (_) => [
        for (var n = 0; n < Allowlist.patchSlots; n++)
          PopupMenuItem(value: n, child: Text(_slotTitle(n), style: const TextStyle(fontFamily: 'Menlo', fontSize: 13))),
      ],
      child: label,
    );
  }

  Future<void> _backup() async {
    if (!await ensureUnlocked(context, m) || !mounted) return;
    if (!await confirm(
      context,
      'Back up all 50 patches?',
      'The pedal switches through every patch (about 30 s) and returns to the current one. '
          'Unsaved edits on the pedal are lost if its Auto Save is off.',
    )) {
      return;
    }
    await m.backupAll();
    _notice();
  }

  Future<void> _store(int slot) async {
    final lib = m.library;
    final target = m.slots[slot] ?? lib?.patches[slot];
    if (lib?.patches[slot] == null) {
      showMessage(context, 'Back up all patches first: storing overwrites patch ${slot + 1}.');
      return;
    }
    if (!await ensureUnlocked(context, m) || !mounted) return;
    if (!await confirm(
      context,
      'Overwrite patch ${slot + 1}?',
      'Patch ${slot + 1} "${target?.name ?? '?'}" will be replaced by "${m.patch?.name ?? '?'}". '
          'A copy is in the backup from ${lib!.date}.',
      action: 'Overwrite',
      danger: true,
    )) {
      return;
    }
    await m.store(slot);
    _notice();
  }

  void _notice() {
    final n = m.notice;
    if (n != null && mounted) showMessage(context, n);
    m.notice = null;
  }

  Future<void> _import() async {
    if (!await ensureUnlocked(context, m)) return;
    final f = await openFile(acceptedTypeGroups: const [_syx]);
    if (f != null) await m.importPatch(await f.readAsBytes()); // anything but a valid 146-byte patch is refused
  }

  Future<void> _export() async {
    final p = m.patch;
    if (p == null) return;
    final name = '${(p.name ?? 'patch').trim().replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_')}.syx';
    final data = Uint8List.fromList(p.raw);
    try {
      final loc = await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [_syx]);
      if (loc == null) return;
      await XFile.fromData(data, name: name).saveTo(loc.path);
    } on UnimplementedError {
      // Android has no save panel in file_selector: keep it in the app's Exports folder.
      final dir = await AppDirs.sub('Exports');
      await File('${dir.path}/$name').writeAsBytes(data);
      if (mounted) showMessage(context, 'Saved to ${dir.path}/$name');
    }
  }
}
