import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:zoom_core/zoom_core.dart';

import '../ai_assistant.dart';
import '../app_model.dart';
import '../effect_manager.dart';
import '../midi_control.dart';
import 'assistant_screen.dart';
import 'diagnostics_view.dart';
import 'dialogs.dart' as dialogs;
import 'effect_picker.dart';
import 'effects_screen.dart';
import 'midi_screen.dart';
import 'native_ui.dart';
import 'patches_screen.dart';
import 'widgets.dart';

enum Sidebar { patches, assistant }

/// Main window, laid out like the Mac app (MainView.swift): pill top bar, the selected pedal on the
/// stage, the signal chain, a status line, and Patches / AI docked on the right. Phones get the same
/// pieces in a compact bar, with Patches and AI as pages.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.model, required this.effects, required this.ai, required this.midi});
  final AppModel model;
  final EffectManager effects;
  final AIAssistant ai;
  final MidiControl midi;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppModel get m => widget.model;
  Sidebar? sidebar = Sidebar.patches;
  List<String>? _lastChain;
  String? _lastName;

  /// Room to dock Patches / AI on the right.
  bool get wide => MediaQuery.sizeOf(context).width >= 760;

  /// Room for the full pill bar (about 1,100 px); narrower windows get the compact bar.
  /// The Mac always gets it (its window never goes below 1040 px, as in the native app).
  bool get wideBar => isMac || MediaQuery.sizeOf(context).width >= 1100;

  @override
  void initState() {
    super.initState();
    m.refreshDevices();
    m.addListener(_followAction);
    widget.midi.requestUnlock = () async => mounted && await ensureUnlocked();
    widget.midi.start();
    if (isMac) {
      NativeUI.onMenu((id) => switch (id) {
            'effects' => _openEffects(),
            'midi' => _openMidi(),
            'diagnostics' => _openDiagnostics(),
            _ => null,
          });
    }
    // Quitting leaves edit mode (0x51) and closes the link first, as the native app does.
    _exit = AppLifecycleListener(onExitRequested: () async {
      await m.disconnect();
      return AppExitResponse.exit;
    });
  }

  late final AppLifecycleListener _exit;

  @override
  void dispose() {
    _exit.dispose();
    m.removeListener(_followAction);
    super.dispose();
  }

  /// Follow the action: when exactly one pedal changes (on/off or effect) from any source (tap, MIDI,
  /// the pedal itself, the assistant), show it on the stage. Patch switches change several slots and
  /// leave the selection alone. An empty selected slot moves to the first effect.
  void _followAction() {
    final p = m.patch;
    final chain = p?.effects.map((e) => '${e.effectId}:${e.isOn == true}').toList();
    final old = _lastChain;
    if (p != null && chain != null && old != null && old.length == chain.length && p.name == _lastName) {
      final changed = [
        for (var i = 0; i < chain.length; i++)
          if (old[i] != chain[i]) i,
      ];
      if (changed.length == 1 && !p.effects[changed.first].isEmpty) m.selectedSlot = changed.first;
    }
    if (p != null && p.effects[m.selectedSlot.clamp(0, 5)].isEmpty) {
      final first = p.effects.indexWhere((e) => !e.isEmpty);
      if (first >= 0 && (old == null || p.name != _lastName)) m.selectedSlot = first;
    }
    _lastChain = chain;
    _lastName = p?.name;
  }

  Future<bool> ensureUnlocked() => dialogs.ensureUnlocked(context, m);
  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  // On the Mac these are sheets over the main window, as in the native app; elsewhere, pages.
  void _openEffects() => isMac
      ? showSheet<void>(context, Builder(builder: (c) => EffectsScreen(model: m, mgr: widget.effects, onClose: () => Navigator.pop(c))))
      : _push(EffectsScreen(model: m, mgr: widget.effects));
  void _openMidi() => isMac
      ? showSheet<void>(context, Builder(builder: (c) => MidiScreen(midi: widget.midi, onClose: () => Navigator.pop(c))),
          size: const Size(760, 640))
      : _push(MidiScreen(midi: widget.midi));
  void _openDiagnostics() => isMac
      ? showSheet<void>(context, Builder(builder: (c) => DiagnosticsView(model: m, onClose: () => Navigator.pop(c))),
          size: const Size(900, 600))
      : _push(Builder(builder: (c) => DiagnosticsView(model: m, onClose: () => Navigator.pop(c))));

  void _toggle(Sidebar s) {
    if (!wide) {
      _push(s == Sidebar.patches ? PatchesScreen(model: m) : AssistantScreen(model: m, ai: widget.ai));
      return;
    }
    setState(() => sidebar = sidebar == s ? null : s);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([m, widget.midi]),
    builder: (context, _) => Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: AppColors.text),
            child: Column(
              children: [
                wideBar ? _topBar() : _compactBar(),
                const Divider(height: 1, color: AppColors.stroke),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            if (m.hint != null) Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), child: _banner(m.hint!)),
                            if (m.fileSystemActive) const LinearProgressIndicator(color: AppColors.accent), // Effects owns the link
                            Expanded(child: m.patch == null ? _welcome() : _stage()),
                            if (m.patch != null) _chain(),
                            _statusLine(),
                          ],
                        ),
                      ),
                      if (wide && sidebar != null) ...[
                        const VerticalDivider(width: 1, color: AppColors.stroke),
                        SizedBox(
                          width: sidebar == Sidebar.assistant ? 380 : 300,
                          child: sidebar == Sidebar.assistant
                              ? AssistantScreen(model: m, ai: widget.ai, onClose: () => setState(() => sidebar = null))
                              : PatchesPanel(model: m, onClose: () => setState(() => sidebar = null)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  // Top bar

  Widget _topBar() => Container(
    height: 56,
    color: AppColors.panel.withValues(alpha: 0.6),
    padding: EdgeInsets.only(left: isMac ? 80 : 16, right: 16), // room for the window buttons on the Mac
    child: Row(
      children: [
        _connectionPill(),
        const SizedBox(width: 14),
        Expanded(child: Center(child: _patchSwitcher())),
        const SizedBox(width: 14),
        if (m.patch?.tempo != null) ...[
          Pill(icon: Icons.av_timer, label: '${m.patch!.tempo}', tooltip: 'Patch tempo (BPM): click to change', onTap: _tempo),
          const SizedBox(width: 10),
        ],
        _lockPill(),
        const SizedBox(width: 10),
        Pill(icon: Icons.layers_outlined, label: 'Effects', tooltip: 'Install and remove effects on the pedal', onTap: _openEffects),
        const SizedBox(width: 10),
        Pill(
          icon: Icons.auto_awesome,
          label: 'AI',
          active: sidebar == Sidebar.assistant,
          tooltip: 'Tone assistant: describe a sound, get a patch',
          onTap: () => _toggle(Sidebar.assistant),
        ),
        const SizedBox(width: 10),
        _midiPill(),
        const SizedBox(width: 10),
        Pill(
          icon: Icons.view_sidebar_outlined,
          active: sidebar == Sidebar.patches,
          tooltip: 'Patches',
          onTap: () => _toggle(Sidebar.patches),
        ),
      ],
    ),
  );

  Widget _compactBar() => Container(
    color: AppColors.panel.withValues(alpha: 0.6),
    padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
    child: Row(
      children: [
        _connectionPill(compact: true),
        const SizedBox(width: 8),
        Expanded(child: _patchSwitcher()),
        IconButton(
          tooltip: m.editingEnabled ? 'Editing: tap to lock' : 'Locked: tap to unlock',
          onPressed: _toggleLock,
          icon: Icon(m.editingEnabled ? Icons.lock_open : Icons.lock, color: m.editingEnabled ? AppColors.accent : AppColors.text),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) => switch (v) {
            'patches' => _toggle(Sidebar.patches),
            'ai' => _toggle(Sidebar.assistant),
            'effects' => _openEffects(),
            'midi' => _openMidi(),
            'mode' => widget.midi.setMode(widget.midi.mode == ControlMode.stomp ? ControlMode.patch : ControlMode.stomp),
            'tempo' => _tempo(),
            _ => null,
          },
          itemBuilder: (_) => [
            _menuItem('patches', Icons.view_list, 'Patches'),
            _menuItem('ai', Icons.auto_awesome, 'Tone Assistant'),
            _menuItem('effects', Icons.layers_outlined, 'Effects'),
            _menuItem('midi', Icons.piano, 'MIDI'),
            _menuItem('mode', Icons.swap_horiz, 'Footswitch mode: ${widget.midi.mode == ControlMode.stomp ? 'Stomp' : 'Patch'}'),
            if (m.patch?.tempo != null) _menuItem('tempo', Icons.av_timer, 'Tempo ${m.patch!.tempo} BPM'),
          ],
        ),
      ],
    ),
  );

  PopupMenuItem<String> _menuItem(String v, IconData icon, String text) => PopupMenuItem(
    value: v,
    child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(text)]),
  );

  Widget _connectionPill({bool compact = false}) {
    final name = m.device?.name ?? 'No pedal';
    final status = m.busy ?? (m.isConnected ? 'Connected · live' : (m.device == null ? 'Pair your pedal' : 'Tap to connect'));
    final items = [
      if (m.isConnected) ...[
        NativeMenuItem('screen', "Show changed effect on the pedal's screen", checked: m.showOnPedalScreen),
        const NativeMenuItem('reload', 'Reload from pedal'),
        const NativeMenuItem('disconnect', 'Disconnect'),
      ] else ...[
        NativeMenuItem('connect', 'Connect', enabled: m.device != null && m.busy == null),
        for (final d in m.devices) NativeMenuItem('dev:${d.address}', d.name, checked: m.device?.address == d.address),
        const NativeMenuItem('refresh', 'Refresh paired devices'),
      ],
      const NativeMenuItem.separator(),
      const NativeMenuItem('notes', 'Diagnostics…'),
    ];
    Future<void> run(String? v) async {
      switch (v) {
        case null:
          return;
        case 'connect':
          await m.connect();
        case 'disconnect':
          await m.disconnect();
        case 'reload':
          await m.resumeAfterFileSystem();
        case 'screen':
          m.setShowOnPedalScreen(!m.showOnPedalScreen);
        case 'refresh':
          await m.refreshDevices();
        case 'notes':
          _openDiagnostics();
        default:
          if (v.startsWith('dev:')) m.device = m.devices.firstWhere((d) => d.address == v.substring(4));
          setState(() {});
      }
    }

    final pill = Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: compact ? 10 : 5),
        decoration: const ShapeDecoration(color: AppColors.panelRaised, shape: StadiumBorder()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Led(on: m.isConnected, color: m.isConnected ? Colors.green : Colors.grey, size: 9),
            if (!compact) ...[
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(status, style: const TextStyle(fontSize: 11, color: AppColors.dim)),
                ],
              ),
            ],
          ],
        ),
      );
    // On the Mac: a native NSMenu, as in the native app. Elsewhere: a Material popup with the same items.
    if (isMac) {
      return Builder(builder: (c) => GestureDetector(onTap: () async => run(await NativeUI.menu(c, items)), child: pill));
    }
    return PopupMenuButton<String>(
      tooltip: 'Connection',
      onSelected: run,
      itemBuilder: (_) => [
        for (final i in items)
          if (i.separator)
            const PopupMenuDivider()
          else
            CheckedPopupMenuItem(value: i.id, checked: i.checked, enabled: i.enabled, child: Text(i.title)),
      ],
      child: pill,
    );
  }

  Widget _patchSwitcher() {
    final slotText = m.currentSlot == null ? '––' : (m.currentSlot! + 1).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: const ShapeDecoration(color: Color(0x59000000), shape: StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: m.canInteract
                ? () async {
                    if (await ensureUnlocked()) await m.stepPatch(-1);
                  }
                : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Flexible(
            child: InkWell(
              onTap: () => _toggle(Sidebar.patches),
              onLongPress: _rename,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(5)),
                    child: Text(
                      slotText,
                      style: const TextStyle(fontFamily: 'Menlo', fontWeight: FontWeight.w700, fontSize: 13, color: Colors.black),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: wideBar ? 140 : 0),
                      child: Text(
                        m.patch?.name ?? 'Not connected',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: m.canInteract
                ? () async {
                    if (await ensureUnlocked()) await m.stepPatch(1);
                  }
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleLock() async => m.editingEnabled ? m.setEditing(false) : await ensureUnlocked();

  Widget _lockPill() => Pill(
    icon: m.editingEnabled ? Icons.lock_open : Icons.lock,
    label: m.editingEnabled ? 'Editing' : 'Locked',
    active: m.editingEnabled,
    tooltip: m.editingEnabled ? 'Changes are sent to the pedal. Click to lock.' : 'Unlock to change the pedal from this device.',
    onTap: _toggleLock,
  );

  /// MIDI button with the footswitch mode; tap the mode to flip Stomp/Patch.
  Widget _midiPill() {
    final stomp = widget.midi.mode == ControlMode.stomp;
    return Pill(
      icon: Icons.piano,
      label: 'MIDI',
      onTap: _openMidi,
      tooltip: 'MIDI controller settings',
      trailing: Tooltip(
        message: 'Footswitch mode: Stomp toggles effects, Patch loads patches. Tap to switch.',
        child: GestureDetector(
          onTap: () => widget.midi.setMode(stomp ? ControlMode.patch : ControlMode.stomp),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: ShapeDecoration(color: stomp ? const Color(0xFF4D4D4D) : AppColors.accent, shape: const StadiumBorder()),
            child: Text(
              stomp ? 'STOMP' : 'PATCH',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.8, color: stomp ? AppColors.text : Colors.black),
            ),
          ),
        ),
      ),
    );
  }

  // Stage

  Widget _stage() {
    final fx = m.patch!.effects[m.selectedSlot.clamp(0, 5)];
    // Scaled down to fit the window (like SwiftUI), never scrolled or clipped.
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: fx.isEmpty
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add_circle_outline, size: 44, color: AppColors.dim),
                    const SizedBox(height: 14),
                    Text(
                      'Slot ${fx.index + 1} is empty',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.dim),
                    ),
                    const SizedBox(height: 14),
                    Pill(label: 'Choose an effect', active: true, onTap: m.canInteract ? () => _pickEffect(fx.index) : null),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _bigPedal(fx),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _stageButton(Icons.swap_horiz, 'Change effect', true, () => _pickEffect(fx.index)),
                        const SizedBox(width: 10),
                        _stageButton(Icons.delete_outline, 'Remove', false, () async {
                          if (await ensureUnlocked()) await m.setEffect(fx.index, 0);
                        }),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _stageButton(IconData icon, String label, bool primary, VoidCallback onTap) => Material(
    color: primary ? AppColors.accent : AppColors.panelRaised,
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: m.canInteract ? onTap : null,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: primary ? 18 : 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: primary ? Colors.black : AppColors.text),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: primary ? 14 : 13,
                fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
                color: primary ? Colors.black : AppColors.text,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _bigPedal(EffectSlot fx) {
    final on = fx.isOn == true;
    final def = EffectCatalog.effect(fx.effectId);
    final params = fx.parameters;
    // 7–9 knobs: a wider pedal with 5 columns (2 rows) on big screens, so it shrinks less to fit.
    final cols = wide && params.length > 6 ? 5 : params.length.clamp(1, 3);
    final width = wide ? (cols > 3 ? 540.0 : 380.0) : (MediaQuery.sizeOf(context).width - 48).clamp(260.0, 380.0);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: 1,
      child: ColorFiltered(
        colorFilter: saturation(on ? 1 : 0.2, brightness: on ? 0 : -0.06),
        child: SizedBox(
          width: width,
          child: PedalBody(
            color: AppColors.category(fx.category),
            radius: 22,
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Led(on: on, size: 14),
                      const Spacer(),
                      Text(
                        (fx.category ?? '').toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 11, color: Color(0xBFFFFFFF)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                    decoration: BoxDecoration(color: const Color(0x4D000000), borderRadius: BorderRadius.circular(12)),
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final cell = c.maxWidth / cols;
                        return Wrap(
                          runSpacing: 18,
                          children: [
                            for (final p in params)
                              SizedBox(
                                width: cell,
                                child: Center(child: _control(fx, p, def?.parameters.elementAtOrNull(p.index))),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    fx.displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      shadows: [Shadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1))],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Footswitch(
                    size: 54,
                    onTap: m.canInteract
                        ? () async {
                            if (await ensureUnlocked()) await m.setOn(fx.index, !on);
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _control(EffectSlot fx, ParameterValue p, CatalogParameter? def) {
    Future<void> set(int r) async {
      if (await ensureUnlocked()) m.setParameter(fx.index, p.index, r);
    }

    final count = def?.valueCount ?? 0;
    if (def != null && count == 2) {
      return MiniSwitch(
        label: p.name,
        options: [def.display(0) ?? '0', def.display(1) ?? '1'],
        raw: p.raw,
        enabled: m.canInteract,
        onChanged: set,
      );
    }
    return Knob(
      label: p.name,
      display: p.text,
      raw: p.raw,
      count: count,
      defaultRaw: def?.defaultRaw ?? 0,
      size: 62,
      enabled: m.canInteract && def != null, // custom effects: value ranges unknown, shown only
      onChanged: set,
    );
  }

  // Chain

  Widget _chain() {
    final p = m.patch!;
    return Container(
      color: const Color(0x59000000),
      padding: const EdgeInsets.fromLTRB(20, 34, 20, 16),
      child: LayoutBuilder(
        builder: (context, c) {
          const pedalW = 104.0, jackW = 22.0; // 92 + selection border and padding
          final minW = jackW * 2 + 6 * pedalW + 7 * 10;
          final row = SizedBox(
            width: c.maxWidth > minW ? c.maxWidth : minW,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Transform.translate(
                    offset: const Offset(0, -11), // level with the jacks
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF4D4D4D), Color(0xFF1F1F1F)],
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const _Jack('IN'),
                    for (final fx in p.effects) ...[const Spacer(), _miniPedal(fx)],
                    const Spacer(),
                    const _Jack('OUT'),
                  ],
                ),
              ],
            ),
          );
          return c.maxWidth >= minW ? row : SingleChildScrollView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, child: row);
        },
      ),
    );
  }

  Widget _miniPedal(EffectSlot fx) {
    final off = !fx.isEmpty && fx.isOn != true;
    final selected = fx.index == m.selectedSlot;
    return Tooltip(
      message: fx.isEmpty ? 'Empty slot ${fx.index + 1}' : '${fx.displayName} · slot ${fx.index + 1}',
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        onTap: () {
          setState(() => m.selectedSlot = fx.index);
          if (fx.isEmpty && m.canInteract) _pickEffect(fx.index);
        },
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: off ? 1 : 0),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
          builder: (context, t, child) => Transform.translate(
            offset: Offset(0, -22 * t), // lifted off the cable: signal bypasses it
            child: Transform.scale(
              scale: 1 - 0.06 * t,
              child: Opacity(opacity: 1 - 0.2 * t, child: child),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
              boxShadow: off ? const [BoxShadow(color: Color(0x80000000), blurRadius: 10, offset: Offset(0, 14))] : null,
            ),
            child: ColorFiltered(
              colorFilter: saturation(off ? 0.12 : 1, brightness: off ? -0.08 : 0),
              child: SizedBox(
                width: 92,
                height: 118,
                child: PedalBody(
                  color: AppColors.category(fx.category),
                  radius: 10,
                  empty: fx.isEmpty,
                  child: fx.isEmpty
                      ? const Center(child: Icon(Icons.add, color: AppColors.dim))
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                          child: Column(
                            children: [
                              Led(on: fx.isOn == true, size: 8),
                              const SizedBox(height: 6),
                              Text(
                                fx.displayName,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Colors.white),
                              ),
                              const Spacer(),
                              Footswitch(
                                size: 26,
                                onTap: m.canInteract
                                    ? () async {
                                        if (await ensureUnlocked()) await m.setOn(fx.index, fx.isOn != true);
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Status line, banner, welcome

  Widget _statusLine() {
    final midi = widget.midi;
    return Container(
      color: AppColors.panel.withValues(alpha: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 11, color: AppColors.dim),
        child: Row(
          children: [
            if (m.isConnected) ...[
              Icon(Icons.graphic_eq, size: 13, color: AppColors.dim),
              const SizedBox(width: 4),
              Text(m.liveUpdates ? 'Live' : 'Manual refresh'),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  m.editingEnabled ? 'Edits play right away; use Save to keep them' : 'Locked: using a control asks to unlock',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const Spacer(),
            if (midi.lastMessage != null) ...[
              const Icon(Icons.piano, size: 13, color: AppColors.dim),
              const SizedBox(width: 4),
              Text(midi.lastMessage!),
            ],
            if (midi.status != null) ...[
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  midi.status!,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.accent),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _banner(String text) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error, color: AppColors.accent, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
        InkWell(
          onTap: () {
            m.hint = null;
            m.refreshDevices();
          },
          child: const Icon(Icons.close, size: 16, color: AppColors.dim),
        ),
      ],
    ),
  );

  Widget _welcome() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_tethering, size: 48, color: AppColors.accent),
            const SizedBox(height: 18),
            Text(
              m.device == null ? 'Pair your MS-100BT' : 'Connect your MS-100BT',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            Text(
              m.device == null
                  ? "Pair it in this device's Bluetooth settings first (on the pedal: knob 1 → MENU → Bluetooth → pairing)."
                  : 'Turn the pedal on and keep it near this device.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.dim),
            ),
            if (m.devices.length > 1) ...[
              const SizedBox(height: 14),
              DropdownButton<String>(
                value: m.device?.address,
                dropdownColor: AppColors.panelRaised,
                items: [for (final d in m.devices) DropdownMenuItem(value: d.address, child: Text(d.name))],
                onChanged: (a) => setState(() => m.device = m.devices.firstWhere((d) => d.address == a)),
              ),
            ],
            const SizedBox(height: 18),
            if (m.busy != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(m.busy!, style: const TextStyle(fontSize: 13)),
                ],
              )
            else if (m.device == null)
              Pill(label: 'Refresh devices', active: true, onTap: m.refreshDevices)
            else
              Pill(label: 'Connect', active: true, onTap: m.connect),
          ],
        ),
      ),
    ),
  );

  // Actions

  Future<void> _rename() async {
    final p = m.patch;
    if (p == null || !await ensureUnlocked() || !mounted) return;
    final name = await dialogs.askText(context, 'Patch name (up to 10 characters)', initial: p.name?.trim() ?? '');
    if (name != null && name.trim().isNotEmpty) await m.rename(name.trim());
  }

  Future<void> _tempo() async {
    final p = m.patch;
    if (p == null || !await ensureUnlocked() || !mounted) return;
    final t = await dialogs.askText(context, 'Tempo (40–250 BPM)', initial: '${p.tempo ?? 120}', keyboard: TextInputType.number);
    final bpm = int.tryParse(t ?? '');
    if (bpm != null) await m.setTempo(bpm);
  }

  Future<void> _pickEffect(int slot) async {
    if (!await ensureUnlocked() || !mounted) return;
    final picked = await EffectPicker.show(context, m, slot);
    if (picked != null) await m.setEffect(slot, picked);
  }
}

class _Jack extends StatelessWidget {
  const _Jack(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 22,
        height: 22,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF404040)),
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: AppColors.dim),
      ),
    ],
  );
}
