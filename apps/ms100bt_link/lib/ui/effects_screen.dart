import 'package:flutter/material.dart';
import 'package:zoom_core/zoom_core.dart';

import '../app_model.dart';
import '../effect_manager.dart';
import 'dialogs.dart';
import 'native_ui.dart';
import 'widgets.dart';

/// Effects on the pedal (its menu), the library, and the change plan. Port of the Mac Effects window.
class EffectsScreen extends StatefulWidget {
  const EffectsScreen({super.key, required this.model, required this.mgr, this.onClose});
  final AppModel model;
  final EffectManager mgr;

  /// Set when shown as a sheet on the Mac (a Done button instead of a back arrow).
  final VoidCallback? onClose;

  @override
  State<EffectsScreen> createState() => _EffectsScreenState();
}

class _EffectsScreenState extends State<EffectsScreen> {
  EffectManager get mgr => widget.mgr;
  String query = '';
  bool hideBlocked = true;

  @override
  void initState() {
    super.initState();
    mgr.addListener(_surface);
  }

  @override
  void dispose() {
    mgr.removeListener(_surface);
    super.dispose();
  }

  /// Alerts and notices from the manager become dialogs / snack bars.
  void _surface() {
    final a = mgr.alert, n = mgr.notice;
    if (a != null) {
      mgr.alert = null;
      inform(context, 'Effects', a); // NSAlert on the Mac
    }
    if (n != null) {
      mgr.notice = null;
      showMessage(context, n);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: mgr,
    builder: (context, _) => DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.panel,
          automaticallyImplyLeading: widget.onClose == null,
          title: const Text('Effects', style: TextStyle(fontWeight: FontWeight.w800)),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'On the pedal'),
              Tab(text: 'Library'),
            ],
          ),
          actions: [
            IconButton(tooltip: 'Read the pedal', onPressed: mgr.busy == null ? mgr.readPedal : null, icon: const Icon(Icons.refresh)),
            IconButton(tooltip: 'Back up every file', onPressed: mgr.busy == null ? _backup : null, icon: const Icon(Icons.save_alt)),
            if (widget.onClose != null) ...[
              TextButton(onPressed: mgr.busy == null ? widget.onClose : null, child: const Text('Done')),
              const SizedBox(width: 8),
            ],
          ],
        ),
        body: Column(
          children: [
            if (mgr.busy != null) _progress(),
            _summary(),
            Expanded(child: TabBarView(children: [_pedal(), _library()])),
            if (mgr.hasChanges) _changeBar(),
          ],
        ),
      ),
    ),
  );

  Widget _progress() => Container(
    color: AppColors.panelRaised,
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(mgr.busy!, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: mgr.progress, color: AppColors.accent),
      ],
    ),
  );

  Widget _summary() {
    final s = mgr.state;
    final backup = mgr.lastFullBackup;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s == null
                ? 'Read the pedal to see its effects. Reading is safe: nothing is written.'
                : '${s.files.length}/${EffectPlanValidator.maxFiles} files · ${s.freeBytes ~/ 1024} KB free · '
                      '${s.index.allEffects.length} effects in the menu',
            style: const TextStyle(color: AppColors.dim),
          ),
          const SizedBox(height: 2),
          Text(
            backup == null
                ? 'No full backup yet: back up every file before installing or removing effects (several minutes).'
                : 'Last full backup: ${backup.path.split('/').last.replaceFirst('full-', '')} · ${mgr.installed.length} effect files',
            style: TextStyle(color: backup == null ? AppColors.accent : AppColors.dim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _backup() async {
    if (!await confirm(
      context,
      'Back up every file?',
      'Copies every file on the pedal to this device (about 7 minutes for ~175 files). Read-only: nothing is written to the pedal. '
          'Live updates pause meanwhile. Keep the pedal on the AC adapter.',
    )) {
      return;
    }
    await mgr.backupAll();
  }

  // On the pedal: the draft menu, by category.

  Widget _pedal() {
    final d = mgr.draft;
    if (d == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: mgr.busy == null ? mgr.readPedal : null,
          icon: const Icon(Icons.download),
          label: const Text("Read the pedal's effects"),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final c in d.categories.where((c) => c.effects.any((e) => e.isNotEmpty)))
          Card(
            color: AppColors.panel,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ZDLCategory.name(c.id).toUpperCase(),
                    style: TextStyle(color: AppColors.category(ZDLCategory.name(c.id)), fontWeight: FontWeight.w900, letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in c.effects.where((e) => e.isNotEmpty))
                        InputChip(
                          label: Text(mgr.installed[e]?.displayName ?? mgr.pendingAdds[e]?.displayName ?? e),
                          avatar: mgr.pendingAdds.containsKey(e) ? const Icon(Icons.add, size: 16, color: AppColors.accent) : null,
                          onDeleted: e.toUpperCase().startsWith('CMN_') ? null : () => mgr.remove(e),
                          tooltip: e,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (mgr.pendingRemovals.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('To remove: ${(mgr.pendingRemovals.toList()..sort()).join(', ')}', style: const TextStyle(color: Colors.redAccent)),
          ),
      ],
    );
  }

  // Library: downloads and installable effects.

  Widget _library() {
    final onPedal = mgr.onPedal;
    final q = query.toLowerCase();
    final items = mgr.library.where((e) {
      if (q.isNotEmpty &&
          !e.displayName.toLowerCase().contains(q) &&
          !e.category.toLowerCase().contains(q) &&
          !e.pedalName.toLowerCase().contains(q)) {
        return false;
      }
      return !hideBlocked || !e.risk(onPedal).blocksInstall;
    }).toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ExpansionTile(
          title: const Text('Download effects'),
          subtitle: const Text('Files come from their authors on GitHub and stay on this device.'),
          children: [
            for (final s in EffectSource.all)
              ListTile(
                title: Text(s.label),
                subtitle: Text(s.note, style: const TextStyle(fontSize: 12)),
                trailing: IconButton(icon: const Icon(Icons.cloud_download), onPressed: mgr.busy == null ? () => mgr.download(s) : null),
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search the library'),
                onChanged: (v) => setState(() => query = v),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(label: const Text('Installable only'), selected: hideBlocked, onSelected: (v) => setState(() => hideBlocked = v)),
          ],
        ),
        const SizedBox(height: 8),
        if (mgr.library.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('The library is empty. Download a source above.', textAlign: TextAlign.center),
          ),
        for (final e in items) _libraryRow(e, e.risk(onPedal)),
      ],
    );
  }

  Widget _libraryRow(LibraryEffect e, EffectRisk r) => Card(
    color: AppColors.panel,
    child: ListTile(
      leading: Container(width: 6, height: 36, color: AppColors.category(ZDLCategory.name(e.info.category))),
      title: Text('${e.displayName}  ', style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
        '${e.pedalName} · ${e.category} · ${e.source} · ${e.info.size ~/ 1024} KB'
        '${e.info.parameters.isEmpty ? '' : ' · ${e.info.parameters.take(4).join(', ')}'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RiskBadge(r),
          IconButton(
            icon: const Icon(Icons.add_circle),
            color: AppColors.accent,
            onPressed: r.blocksInstall || r == EffectRisk.installed || mgr.draft == null ? null : () => mgr.add(e),
          ),
        ],
      ),
    ),
  );

  // Change plan

  Widget _changeBar() => Container(
    color: AppColors.panelRaised,
    padding: const EdgeInsets.all(12),
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          Expanded(
            child: Text(
              [
                if (mgr.pendingAdds.isNotEmpty) 'Install ${mgr.pendingAdds.length}',
                if (mgr.pendingRemovals.isNotEmpty) 'remove ${mgr.pendingRemovals.length}',
                if (mgr.pendingAdds.isEmpty && mgr.pendingRemovals.isEmpty) 'Menu changed',
                if (mgr.filesAfter != null) '${mgr.filesAfter}/${EffectPlanValidator.maxFiles} files after',
              ].join(' · '),
            ),
          ),
          TextButton(onPressed: mgr.busy == null ? mgr.discard : null, child: const Text('Discard')),
          TextButton(onPressed: mgr.busy == null ? mgr.dryRun : null, child: const Text('Dry run')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
            onPressed: mgr.busy == null ? _confirmApply : null,
            child: const Text('Apply…', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    ),
  );

  Future<void> _confirmApply() async {
    final go = isMac
        ? await showSheet<bool>(context, ConfirmApplyDialog(mgr: mgr, asSheet: true), size: const Size(620, 620))
        : await showDialog<bool>(
            context: context,
            builder: (c) => ConfirmApplyDialog(mgr: mgr),
          );
    if (go != true || !mounted) return;
    if (!await ensureUnlocked(context, widget.model)) return;
    await mgr.apply();
  }
}

class RiskBadge extends StatelessWidget {
  const RiskBadge(this.risk, {super.key});
  final EffectRisk risk;

  @override
  Widget build(BuildContext context) {
    final color = switch (risk) {
      EffectRisk.installed => Colors.blueGrey,
      EffectRisk.verified => Colors.green,
      EffectRisk.low => Colors.teal,
      EffectRisk.community => Colors.orange,
      _ => Colors.redAccent,
    };
    return Tooltip(
      message: risk.label,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 120),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(6)),
        child: Text(
          risk.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// The risk confirmation: shows the plan, the refusals (if any), and needs the box ticked.
class ConfirmApplyDialog extends StatefulWidget {
  const ConfirmApplyDialog({super.key, required this.mgr, this.asSheet = false});
  final EffectManager mgr;

  /// Laid out as a Mac sheet (like the native ConfirmApplySheet) instead of a Material dialog.
  final bool asSheet;

  @override
  State<ConfirmApplyDialog> createState() => _ConfirmApplyDialogState();
}

class _ConfirmApplyDialogState extends State<ConfirmApplyDialog> {
  bool understood = false;

  @override
  Widget build(BuildContext context) {
    final mgr = widget.mgr;
    final problems = mgr.planProblems();
    final adds = mgr.pendingAdds.values.map((e) => '${e.displayName} (${e.source})').toList()..sort();
    final removes = (mgr.pendingRemovals.toList()..sort()).map((n) => mgr.installed[n]?.displayName ?? n).toList();
    if (widget.asSheet) {
      return ColoredBox(
        color: AppColors.panel,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.warning_rounded, color: Colors.orange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Change the effects on your pedal?',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.orange),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(child: SingleChildScrollView(child: _body(problems, adds, removes))),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: problems.isEmpty && understood ? () => Navigator.pop(context, true) : null,
                    child: const Text('Install on pedal'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 36),
      title: const Text('Change the effects on your pedal?'),
      content: SingleChildScrollView(child: _body(problems, adds, removes)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: problems.isEmpty && understood ? () => Navigator.pop(context, true) : null,
          child: const Text('Install on pedal'),
        ),
      ],
    );
  }

  Widget _body(List<String> problems, List<String> adds, List<String> removes) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (adds.isNotEmpty) Text('Install: ${adds.join(', ')}'),
      if (removes.isNotEmpty) Text('Remove: ${removes.join(', ')}'),
      if (adds.isEmpty && removes.isEmpty) const Text('Reorder the effect menu.'),
      const SizedBox(height: 12),
      const Text(
        "This writes files to the pedal's internal storage, which this app normally never touches. The method was "
        "verified on another MS-100BT, and the app checks every rule it knows, but your pedal can't be replaced:\n\n"
        '• A wrong effect or a broken file can make the pedal freeze when you scroll to it (fixed by turning it off and on).\n'
        '• Files with long names have frozen pedals at boot; the app refuses them.\n'
        '• Community effects are built by hobbyists and may not work on the MS-100BT.\n'
        "• Keep the pedal on the AC adapter and don't switch it off until this finishes.\n\n"
        'Before writing, the app saves the old menu and every file it changes or removes to this device, then checks '
        'each written file by reading it back. If writing the new menu fails, it puts the old one back.',
        style: TextStyle(color: AppColors.dim),
      ),
      const SizedBox(height: 12),
      if (problems.isNotEmpty) ...[
        const Text(
          'This change is refused:',
          style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700),
        ),
        for (final p in problems) Text('• $p'),
      ] else
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: understood,
          onChanged: (v) => setState(() => understood = v ?? false),
          title: const Text('I have a backup of my pedal and accept the risk of changing its files.'),
        ),
    ],
  );
}
