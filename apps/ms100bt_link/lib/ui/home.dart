import 'package:flutter/material.dart';
import 'package:zoom_core/zoom_core.dart';

import '../app_model.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.model});
  final AppModel model;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    m.refreshDevices();
  }

  /// The same warning as the Mac app; edits only happen after the user agrees.
  Future<bool> ensureUnlocked() async {
    if (m.editingEnabled) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Unlock editing?'),
        content: const Text('Changes you make here are sent to the pedal right away.\n\n'
            '• If the pedal\'s Auto Save is on, they are saved into the patch immediately.\n'
            '• If it\'s off, they last until you save or switch patches.\n\n'
            'The app never touches the pedal\'s firmware.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unlock')),
        ],
      ),
    );
    if (ok == true) m.setEditing(true);
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: _topBar(),
        body: SafeArea(
          child: Column(children: [
            if (m.hint != null) _banner(m.hint!),
            Expanded(child: m.patch == null ? _connect() : _board()),
          ]),
        ),
      ),
    );
  }

  PreferredSizeWidget _topBar() => AppBar(
        backgroundColor: AppColors.panel,
        titleSpacing: 12,
        title: m.patch == null
            ? const Text('MS-100BT Link', style: TextStyle(fontWeight: FontWeight.w800))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: () async { if (await ensureUnlocked()) m.stepPatch(-1); }),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(5)),
                  child: Text(m.currentSlot == null ? '––' : (m.currentSlot! + 1).toString().padLeft(2, '0'),
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontFamily: 'monospace')),
                ),
                const SizedBox(width: 10),
                Flexible(child: Text(m.patch!.name ?? '', overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20))),
                IconButton(icon: const Icon(Icons.chevron_right), onPressed: () async { if (await ensureUnlocked()) m.stepPatch(1); }),
              ]),
        actions: [
          if (m.patch?.tempo != null)
            Padding(padding: const EdgeInsets.only(right: 8),
                child: Center(child: Text('${m.patch!.tempo} BPM', style: const TextStyle(color: AppColors.dim)))),
          IconButton(
            tooltip: m.editingEnabled ? 'Editing unlocked' : 'Locked',
            icon: Icon(m.editingEnabled ? Icons.lock_open : Icons.lock, color: m.editingEnabled ? AppColors.accent : null),
            onPressed: () async => m.editingEnabled ? m.setEditing(false) : await ensureUnlocked(),
          ),
          if (m.isConnected)
            IconButton(tooltip: 'Disconnect', icon: const Icon(Icons.link_off), onPressed: m.disconnect),
        ],
      );

  Widget _banner(String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Icon(Icons.error_outline, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () { m.hint = null; m.refreshDevices(); }),
        ]),
      );

  // MARK: connect

  Widget _connect() {
    final pedals = m.devices;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
          const Icon(Icons.bluetooth_audio, size: 56, color: AppColors.accent),
          const SizedBox(height: 16),
          const Text('Connect your MS-100BT', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('Pair it once in your device\'s Bluetooth settings (on the pedal: knob 1 → MENU → Bluetooth → PAIRING), then connect here.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.dim)),
          const SizedBox(height: 20),
          if (pedals.isEmpty) const Text('No paired devices found.', textAlign: TextAlign.center),
          for (final d in pedals)
            Card(
              color: AppColors.panelRaised,
              child: ListTile(
                selected: m.device?.address == d.address,
                selectedTileColor: AppColors.accent.withValues(alpha: 0.12),
                onTap: () { m.device = d; setState(() {}); },
                leading: Icon(m.device?.address == d.address ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: m.device?.address == d.address ? AppColors.accent : AppColors.dim),
                title: Text(d.name),
                subtitle: Text(d.address, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                trailing: d.looksLikePedal ? const Icon(Icons.music_note, color: AppColors.accent) : null,
              ),
            ),
          const SizedBox(height: 16),
          if (m.busy != null)
            Center(child: Column(children: [const CircularProgressIndicator(), const SizedBox(height: 8), Text(m.busy!)]))
          else
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: m.device == null ? null : m.connect,
              icon: const Icon(Icons.link),
              label: const Text('Connect', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          TextButton.icon(onPressed: m.refreshDevices, icon: const Icon(Icons.refresh), label: const Text('Refresh devices')),
          if (m.diagnostics.isNotEmpty) ...[
            const Divider(height: 32),
            Text('Platform notes', style: Theme.of(context).textTheme.titleSmall),
            for (final e in m.diagnostics.entries)
              Text('${e.key}: ${e.value}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: AppColors.dim)),
          ],
        ]),
      ),
    );
  }

  // MARK: pedalboard

  Widget _board() {
    final p = m.patch!;
    final slot = m.selectedSlot.clamp(0, 5);
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth > 720;
      final stage = _bigPedal(p.effects[slot], wide ? 380 : (c.maxWidth - 48).clamp(260, 380).toDouble());
      return Column(children: [
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Center(child: stage))),
        _chain(p, wide),
      ]);
    });
  }

  Widget _bigPedal(EffectSlot fx, double width) {
    if (fx.isEmpty) {
      return Column(children: [
        const SizedBox(height: 40),
        const Icon(Icons.add_circle_outline, size: 48, color: AppColors.dim),
        Text('Slot ${fx.index + 1} is empty', style: const TextStyle(fontSize: 18, color: AppColors.dim)),
        const SizedBox(height: 12),
        FilledButton(onPressed: () => _pickEffect(fx.index), child: const Text('Choose an effect')),
      ]);
    }
    final def = EffectCatalog.effect(fx.effectId);
    final on = fx.isOn == true;
    return Column(children: [
      ColorFiltered(
        colorFilter: on ? const ColorFilter.mode(Colors.transparent, BlendMode.dst) : _grey,
        child: SizedBox(
          width: width,
          child: PedalBody(
            color: AppColors.category(fx.category),
            radius: 22,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Led(on: on, size: 14),
                  const Spacer(),
                  Text((fx.category ?? '').toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 11, color: Colors.white70)),
                ]),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
                  child: Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 14, children: [
                    for (final v in fx.parameters)
                      Knob(
                        label: v.name, display: v.text, raw: v.raw,
                        count: def?.parameters[v.index].valueCount ?? 0,
                        defaultRaw: def?.parameters[v.index].defaultRaw ?? 0,
                        enabled: m.canInteract,
                        onChanged: (r) async { if (await ensureUnlocked()) m.setParameter(fx.index, v.index, r); },
                      ),
                  ]),
                ),
                const SizedBox(height: 14),
                Text(fx.displayName, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Colors.white)),
                const SizedBox(height: 12),
                Footswitch(onTap: () async { if (await ensureUnlocked()) m.setOn(fx.index, !on); }),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
        onPressed: () => _pickEffect(fx.index),
        icon: const Icon(Icons.swap_horiz),
        label: const Text('Change effect', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
    ]);
  }

  static const _grey = ColorFilter.matrix(<double>[
    0.30, 0.55, 0.15, 0, -10, 0.30, 0.55, 0.15, 0, -10, 0.30, 0.55, 0.15, 0, -10, 0, 0, 0, 1, 0,
  ]);

  Widget _chain(PatchDump p, bool wide) => Container(
        color: Colors.black38,
        padding: const EdgeInsets.fromLTRB(12, 30, 12, 14),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Stack(alignment: Alignment.center, children: [
            Positioned(left: 0, right: 0, top: 50,
                child: Container(height: 6, decoration: BoxDecoration(color: const Color(0xFF3A3A3A), borderRadius: BorderRadius.circular(3)))),
            Row(children: [
              const _Jack('IN'),
              for (final fx in p.effects) ...[const SizedBox(width: 14), _miniPedal(fx)],
              const SizedBox(width: 14),
              const _Jack('OUT'),
            ]),
          ]),
        ),
      );

  Widget _miniPedal(EffectSlot fx) {
    final off = !fx.isEmpty && fx.isOn != true;
    final selected = fx.index == m.selectedSlot;
    return GestureDetector(
      onTap: () { setState(() => m.selectedSlot = fx.index); if (fx.isEmpty) _pickEffect(fx.index); },
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutBack,
        offset: Offset(0, off ? -0.18 : 0), // lifted off the cable: bypassed
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(13),
              border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2)),
          child: ColorFiltered(
            colorFilter: off ? _grey : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
            child: SizedBox(
              width: 86,
              height: 112,
              child: PedalBody(
                color: AppColors.category(fx.category),
                radius: 10,
                empty: fx.isEmpty,
                child: fx.isEmpty
                    ? const Center(child: Icon(Icons.add, color: AppColors.dim))
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                        child: Column(children: [
                          Led(on: fx.isOn == true, size: 8),
                          const SizedBox(height: 6),
                          Text(fx.displayName, textAlign: TextAlign.center, maxLines: 2,
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Colors.white)),
                          const Spacer(),
                          Footswitch(size: 26, onTap: () async { if (await ensureUnlocked()) m.setOn(fx.index, fx.isOn != true); }),
                        ]),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickEffect(int slot) async {
    if (!await ensureUnlocked()) return;
    if (!mounted) return;
    final available = PatchAssistant.availableIds([if (m.patch != null) m.patch!]);
    final byCat = <String, List<(int, String)>>{};
    for (final id in available.toList()..sort()) {
      final n = EffectCatalog.name(id);
      if (n != null) (byCat[EffectCatalog.category(id) ?? 'Other'] ??= []).add((id, n));
    }
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (c, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
          Text('Effects for slot ${slot + 1}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          for (final cat in byCat.keys) ...[
            Padding(padding: const EdgeInsets.only(top: 16, bottom: 6),
                child: Text(cat.toUpperCase(), style: TextStyle(color: AppColors.category(cat), fontWeight: FontWeight.w900, letterSpacing: 1.2))),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (id, name) in byCat[cat]!)
                ActionChip(
                  backgroundColor: AppColors.category(cat).withValues(alpha: 0.8),
                  label: Text(name, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                  onPressed: () => Navigator.pop(c, id),
                ),
            ]),
          ],
          if (m.patch != null && !m.patch!.effects[slot].isEmpty) ...[
            const SizedBox(height: 20),
            TextButton.icon(onPressed: () => Navigator.pop(c, 0), icon: const Icon(Icons.delete_outline), label: Text('Remove effect from slot ${slot + 1}')),
          ],
        ]),
      ),
    );
    if (picked != null) await m.setEffect(slot, picked);
  }
}

class _Jack extends StatelessWidget {
  const _Jack(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Column(children: [
        Container(width: 22, height: 22, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF404040)),
            child: Center(child: Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black)))),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: AppColors.dim)),
      ]);
}
