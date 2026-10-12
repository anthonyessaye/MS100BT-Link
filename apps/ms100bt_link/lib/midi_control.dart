import 'dart:async';
import 'dart:convert';

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zoom_core/zoom_core.dart';

import 'app_model.dart';
import 'bluetooth.dart';

enum MidiKind { cc, note, program }

/// One incoming MIDI 1.0 channel message.
class MidiInput {
  const MidiInput(this.kind, this.channel, this.number, this.value);
  final MidiKind kind;
  final int channel; // 1…16
  final int number; // CC#, note#, or program#
  final int value; // CC value / velocity; 127 for program change

  /// Parses one channel-voice message; null for anything else (SysEx, clock…).
  static MidiInput? parse(List<int> d) {
    if (d.isEmpty) return null;
    final status = d[0], ch = (status & 0x0F) + 1;
    return switch (status & 0xF0) {
      0xB0 when d.length >= 3 => MidiInput(MidiKind.cc, ch, d[1] & 0x7F, d[2] & 0x7F),
      0x90 when d.length >= 3 => MidiInput(MidiKind.note, ch, d[1] & 0x7F, d[2] & 0x7F),
      0x80 when d.length >= 3 => MidiInput(MidiKind.note, ch, d[1] & 0x7F, 0),
      0xC0 when d.length >= 2 => MidiInput(MidiKind.program, ch, d[1] & 0x7F, 127),
      _ => null,
    };
  }

  bool get isPress => value >= 64 || (kind == MidiKind.note && value > 0) || kind == MidiKind.program;

  String get label => switch (kind) {
        MidiKind.cc => 'CC $number = $value · ch $channel',
        MidiKind.note => 'Note $number vel $value · ch $channel',
        MidiKind.program => 'Program $number · ch $channel',
      };
}

class MidiTrigger {
  const MidiTrigger(this.kind, this.channel, this.number);
  final MidiKind kind;
  final int channel, number;
  bool matches(MidiInput m) => m.kind == kind && m.channel == channel && m.number == number;
  String get label => switch (kind) {
        MidiKind.cc => 'CC $number · ch $channel',
        MidiKind.note => 'Note $number · ch $channel',
        MidiKind.program => 'PC $number · ch $channel',
      };
  Map<String, Object> toJson() => {'kind': kind.name, 'channel': channel, 'number': number};
  static MidiTrigger? fromJson(Object? j) => j is Map
      ? MidiTrigger(MidiKind.values.byName(j['kind'] as String), j['channel'] as int, j['number'] as int)
      : null;
}

enum MidiActionType { toggleEffect, nextPatch, previousPatch, selectPatch, parameter, switchMode, nothing }

class MidiAction {
  const MidiAction(this.type, {this.slot = 0, this.index = 0});
  final MidiActionType type;
  final int slot; // FX slot or patch number (0-based)
  final int index; // knob index for parameter

  bool get isContinuous => type == MidiActionType.parameter;
  String get label => switch (type) {
        MidiActionType.toggleEffect => 'Toggle FX ${slot + 1}',
        MidiActionType.nextPatch => 'Next patch',
        MidiActionType.previousPatch => 'Previous patch',
        MidiActionType.selectPatch => 'Load patch ${slot + 1}',
        MidiActionType.parameter => 'FX ${slot + 1} knob ${index + 1}',
        MidiActionType.switchMode => 'Switch Stomp/Patch mode',
        MidiActionType.nothing => 'Nothing',
      };
  Map<String, Object> toJson() => {'type': type.name, 'slot': slot, 'index': index};
  static MidiAction? fromJson(Object? j) => j is Map
      ? MidiAction(MidiActionType.values.byName(j['type'] as String), slot: j['slot'] as int? ?? 0, index: j['index'] as int? ?? 0)
      : null;
  @override
  bool operator ==(Object other) => other is MidiAction && other.type == type && other.slot == slot && other.index == index;
  @override
  int get hashCode => Object.hash(type, slot, index);
}

/// How a switch reports presses. Detected once (on the first press after Learn) and saved.
enum SwitchBehavior {
  /// Momentary: high value = press, low value = release (ignored).
  momentary('Momentary (press/release)'),

  /// Latching: every message (high or low) is a press.
  latching('Latching (alternates on/off)');

  const SwitchBehavior(this.label);
  final String label;
}

enum ControlMode { stomp, patch }

class MidiMapping {
  MidiMapping({String? id, this.trigger, required this.action, this.patchAction, this.behavior})
      : id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${_n++}';
  static int _n = 0;
  final String id;
  MidiTrigger? trigger;

  /// What the switch does in Stomp mode.
  MidiAction action;

  /// What it does in Patch mode; null = same as Stomp mode.
  MidiAction? patchAction;

  /// null = detect on the next press.
  SwitchBehavior? behavior;

  MidiAction actionIn(ControlMode m) => m == ControlMode.patch ? (patchAction ?? action) : action;

  Map<String, Object?> toJson() =>
      {'id': id, 'trigger': trigger?.toJson(), 'action': action.toJson(), 'patchAction': patchAction?.toJson(), 'behavior': behavior?.name};
  static MidiMapping fromJson(Map<String, dynamic> j) => MidiMapping(
        id: j['id'] as String?,
        trigger: MidiTrigger.fromJson(j['trigger']),
        action: MidiAction.fromJson(j['action']) ?? const MidiAction(MidiActionType.nothing),
        patchAction: MidiAction.fromJson(j['patchAction']),
        behavior: SwitchBehavior.values.where((b) => b.name == j['behavior']).firstOrNull,
      );
}

/// Listens to MIDI inputs and turns mapped messages into pedal actions. Port of the Mac MIDIControl.
class MidiControl extends ChangeNotifier {
  MidiControl({required this.link, this.prefs}) {
    final saved = prefs?.getString('midiMappings');
    try {
      mappings = saved == null
          ? defaultMappings()
          : (jsonDecode(saved) as List).map((e) => MidiMapping.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      mappings = defaultMappings();
    }
    programChangeLoadsPatch = prefs?.getBool('midiPCLoadsPatch') ?? true;
    mode = ControlMode.values.where((m) => m.name == prefs?.getString('midiMode')).firstOrNull ?? ControlMode.stomp;
  }

  final AppModel link;
  final SharedPreferences? prefs;
  late List<MidiMapping> mappings;
  late bool programChangeLoadsPatch;
  late ControlMode mode;
  List<MidiDevice> devices = [];
  String? learning;
  String? lastMessage;
  String? status;

  /// Set by the UI: asks the user to unlock editing (same dialog as tapping a control), then runs the press.
  Future<bool> Function()? requestUnlock;

  MidiCommand? _midi;
  StreamSubscription<MidiPacket>? _rx;
  StreamSubscription<MidiSetupChange>? _setup;
  final Map<String, DateTime> _detecting = {};
  static const _detectWindow = Duration(milliseconds: 400);

  /// Six switches: FX 1–6 in Stomp mode, patches 01–06 in Patch mode; plus previous/next.
  static List<MidiMapping> defaultMappings() => [
        for (var i = 0; i < 6; i++)
          MidiMapping(action: MidiAction(MidiActionType.toggleEffect, slot: i), patchAction: MidiAction(MidiActionType.selectPatch, slot: i)),
        MidiMapping(action: const MidiAction(MidiActionType.previousPatch)),
        MidiMapping(action: const MidiAction(MidiActionType.nextPatch)),
      ];

  void _save() {
    prefs?.setString('midiMappings', jsonEncode([for (final m in mappings) m.toJson()]));
    prefs?.setBool('midiPCLoadsPatch', programChangeLoadsPatch);
    prefs?.setString('midiMode', mode.name);
    notifyListeners();
  }

  /// Starts listening (wired MIDI on every platform the plugin supports; Bluetooth MIDI devices appear once connected).
  Future<void> start() async {
    if (_midi != null) return;
    try {
      // Android doesn't connect Bluetooth MIDI controllers by itself: the app finds and connects them
      // (see scanBluetoothMidi). macOS does it in Apple's Bluetooth MIDI window.
      final m = Platform.isAndroid ? MidiCommand(bleTransport: UniversalBleMidiTransport()) : MidiCommand();
      _midi = m;
      _rx = m.onMidiPacketReceived?.listen((p) {
        final msg = MidiInput.parse(p.data);
        if (msg != null) receive(msg);
      });
      _setup = m.onMidiSetupChanged?.listen((_) => refreshDevices());
      await refreshDevices();
    } catch (e) {
      status = 'MIDI unavailable: $e';
      notifyListeners();
    }
  }

  /// Lists MIDI devices and connects every input that isn't connected yet.
  Future<void> refreshDevices() async {
    final m = _midi;
    if (m == null) return;
    try {
      devices = (await m.devices) ?? [];
      for (final d in devices.where((d) => !d.connected && d.inputPorts.isNotEmpty)) {
        try {
          await m.connectToDevice(d);
        } catch (_) {}
      }
    } catch (e) {
      status = 'MIDI: $e';
    }
    notifyListeners();
  }

  /// Android: Bluetooth MIDI controllers found by the last scan, and whether a scan is running.
  bool get canScanBluetooth => !kIsWeb && Platform.isAndroid;
  bool scanningBluetooth = false;
  List<MidiDevice> get bluetoothDevices => devices.where((d) => d.type == MidiDeviceType.ble).toList();

  /// Scans 8 s for Bluetooth MIDI controllers (they must be on and not connected to another device).
  Future<void> scanBluetoothMidi() async {
    final m = _midi;
    if (m == null || scanningBluetooth) return;
    scanningBluetooth = true;
    status = null;
    notifyListeners();
    try {
      await BluetoothBridge.ensureScanPermission();
      await m.startBluetooth();
      await m.waitUntilBluetoothIsInitialized();
      await m.startScanningForBluetoothDevices();
      await Future<void>.delayed(const Duration(seconds: 8));
      m.stopScanningForBluetoothDevices();
      devices = (await m.devices) ?? devices;
      if (bluetoothDevices.isEmpty) {
        status = 'No Bluetooth MIDI controllers found. Turn the controller on (not connected to another phone or computer) and scan again.';
      }
    } catch (e) {
      status = 'Bluetooth MIDI: $e';
    }
    scanningBluetooth = false;
    notifyListeners();
  }

  Future<void> connectDevice(MidiDevice d) async {
    try {
      await _midi?.connectToDevice(d);
      devices = (await _midi?.devices) ?? devices;
    } catch (e) {
      status = 'Could not connect to ${d.name}: $e';
    }
    notifyListeners();
  }

  void receive(MidiInput m) {
    lastMessage = m.label;
    final id = learning;
    if (id != null) {
      if (!m.isPress && m.kind != MidiKind.cc) return; // ignore note-offs while learning
      final map = mappings.where((x) => x.id == id).firstOrNull;
      if (map != null) {
        map.trigger = MidiTrigger(m.kind, m.channel, m.number);
        map.behavior = null;
        if (m.kind != MidiKind.program && m.value >= 64) _startDetecting(id); // learn press doubles as detection
      }
      learning = null;
      _save();
      return;
    }
    final hits = mappings.where((x) => x.trigger?.matches(m) == true).toList();
    if (hits.isEmpty && m.kind == MidiKind.program && programChangeLoadsPatch && m.number < Allowlist.patchSlots) {
      _perform(MidiAction(MidiActionType.selectPatch, slot: m.number), m);
      notifyListeners();
      return;
    }
    final modeAtPress = mode; // a mode switch in this batch must not affect the other hits
    for (final h in hits) {
      final action = h.actionIn(modeAtPress);
      if (action.isContinuous || _isPress(m, h)) _perform(action, m);
    }
    notifyListeners();
  }

  /// Whether this message is a footswitch press (vs. the release of a momentary switch).
  bool _isPress(MidiInput m, MidiMapping h) {
    if (m.kind == MidiKind.program) return true;
    final high = m.value >= 64;
    switch (h.behavior) {
      case SwitchBehavior.momentary:
        return high;
      case SwitchBehavior.latching:
        return true;
      case null:
        if (high) {
          _startDetecting(h.id);
          return true;
        }
        final t0 = _detecting[h.id];
        if (t0 != null && DateTime.now().difference(t0) < _detectWindow) {
          _setDetected(h.id, SwitchBehavior.momentary); // quick release of the first press
          return false;
        }
        _setDetected(h.id, SwitchBehavior.latching); // a low value on its own is a latching "off" press
        return true;
    }
  }

  void _startDetecting(String id) {
    if (_detecting.containsKey(id)) return;
    _detecting[id] = DateTime.now();
    Timer(_detectWindow + const Duration(milliseconds: 50), () {
      if (_detecting.containsKey(id)) _setDetected(id, SwitchBehavior.latching); // no release followed the press
    });
  }

  void _setDetected(String id, SwitchBehavior b) {
    _detecting.remove(id);
    final m = mappings.where((x) => x.id == id).firstOrNull;
    if (m != null && m.behavior == null) {
      m.behavior = b;
      _save();
    }
  }

  Future<void> _perform(MidiAction action, MidiInput m) async {
    if (action.type == MidiActionType.switchMode) {
      mode = mode == ControlMode.stomp ? ControlMode.patch : ControlMode.stomp;
      status = null;
      _save();
      return;
    }
    if (action.type == MidiActionType.nothing) return;
    if (!link.canInteract) {
      status = "Received ${m.label}, but the pedal isn't connected.";
      notifyListeners();
      return;
    }
    if (!link.editingEnabled) {
      // Same as tapping a control while locked: ask once, then run this press.
      status = 'Unlock editing to use MIDI control.';
      notifyListeners();
      final ok = await requestUnlock?.call() ?? false;
      if (!ok) return;
    }
    status = null;
    final p = link.patch;
    switch (action.type) {
      case MidiActionType.toggleEffect:
        final fx = p?.effects[action.slot];
        if (fx != null && !fx.isEmpty) await link.setOn(action.slot, fx.isOn != true);
      case MidiActionType.nextPatch:
        await link.stepPatch(1);
      case MidiActionType.previousPatch:
        await link.stepPatch(-1);
      case MidiActionType.selectPatch:
        await link.selectPatch(action.slot);
      case MidiActionType.parameter:
        final fx = p?.effects[action.slot];
        final def = fx == null || fx.isEmpty ? null : EffectCatalog.effect(fx.effectId)?.parameters;
        if (def == null || action.index >= def.length) return;
        final count = def[action.index].valueCount;
        link.setParameter(action.slot, action.index, (m.value / 127 * (count - 1)).round());
      case MidiActionType.switchMode || MidiActionType.nothing:
        break;
    }
  }

  // Editing mappings (UI)

  void addMapping(MidiAction action) {
    final m = MidiMapping(action: action);
    mappings.add(m);
    learning = m.id;
    _save();
  }

  void learn(String id) {
    learning = learning == id ? null : id;
    notifyListeners();
  }

  void remove(String id) {
    mappings.removeWhere((m) => m.id == id);
    _save();
  }

  void update(String id, void Function(MidiMapping m) change) {
    final m = mappings.where((x) => x.id == id).firstOrNull;
    if (m == null) return;
    change(m);
    _detecting.remove(id);
    _save();
  }

  void setMode(ControlMode m) {
    mode = m;
    _save();
  }

  void setProgramChangeLoadsPatch(bool on) {
    programChangeLoadsPatch = on;
    _save();
  }

  void resetDefaults() {
    mappings = defaultMappings();
    _save();
  }

  @override
  void dispose() {
    _rx?.cancel();
    _setup?.cancel();
    super.dispose();
  }
}
