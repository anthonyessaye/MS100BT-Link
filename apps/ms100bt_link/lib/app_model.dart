import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zoom_core/zoom_core.dart';

import 'bluetooth.dart';

/// App state: connection, current patch, editing lock, live updates. Mirrors the Mac app's LinkModel.
class AppModel extends ChangeNotifier {
  List<PairedDevice> devices = [];
  PairedDevice? device;
  PedalSession? session;
  PatchDump? patch;
  int? currentSlot;
  int selectedSlot = 0;
  bool editingEnabled = false;
  bool liveUpdates = true;
  String? busy;
  String? hint;
  Map<String, Object?> diagnostics = {};

  Timer? _poll;
  StreamSubscription<PedalSession>? _changes;
  final Map<String, Timer> _pendingEdits = {};
  Timer? _verify;

  bool get isConnected => session?.identity != null;
  bool get canInteract => isConnected && patch != null;

  Future<void> refreshDevices() async {
    try {
      devices = await BluetoothBridge.pairedDevices();
      device ??= devices.where((d) => d.looksLikePedal).firstOrNull ?? devices.firstOrNull;
      diagnostics = await BluetoothBridge.diagnostics();
    } catch (e) {
      hint = 'Bluetooth: $e';
    }
    notifyListeners();
  }

  Future<void> connect() async {
    final d = device;
    if (d == null) {
      hint = 'Pair the pedal in your Bluetooth settings first (pedal: knob 1 → MENU → Bluetooth → PAIRING).';
      notifyListeners();
      return;
    }
    busy = 'Connecting…';
    hint = null;
    notifyListeners();
    try {
      final bridge = await BluetoothBridge.connect(d.address);
      final s = PedalSession(bridge)..writesEnabled = editingEnabled;
      session = s;
      _changes = s.changes.listen((_) {
        if (_pendingEdits.isEmpty) patch = s.patch;
        notifyListeners();
      });
      final id = await s.identify();
      if (id == null || !id.isKnownMS100BTId) throw PedalError('No MS-100BT identity reply.');
      busy = 'Reading the patch…';
      notifyListeners();
      patch = await s.readPatch();
      if (liveUpdates) await _startLive();
    } catch (e) {
      hint = 'Could not connect: $e';
      await disconnect();
    }
    busy = null;
    notifyListeners();
  }

  Future<void> disconnect() async {
    _poll?.cancel();
    await _changes?.cancel();
    final s = session;
    session = null;
    patch = null;
    try {
      await s?.close(); // leaves edit mode (0x51) first
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _startLive() async {
    final s = session;
    if (s == null) return;
    await s.enterEditMode();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (busy != null || _pendingEdits.isNotEmpty || _verify != null || session == null) return;
      final p = await session!.readPatch(timeout: const Duration(milliseconds: 1500));
      if (p != null) {
        patch = p;
        notifyListeners();
      }
    });
  }

  void setEditing(bool on) {
    editingEnabled = on;
    session?.writesEnabled = on;
    notifyListeners();
  }

  Future<void> _write(String label, Future<void> Function(PedalSession s) action) async {
    final s = session;
    if (s == null || !editingEnabled) return;
    try {
      await action(s);
      patch = s.patch;
    } catch (e) {
      hint = '$label failed: $e';
    }
    notifyListeners();
  }

  /// On/off; also moves the pedal's own display to this effect (as on the Mac).
  Future<void> setOn(int slot, bool on) async {
    selectedSlot = slot;
    await _write('FX${slot + 1} on/off', (s) async {
      await s.liveEdit(slot, 0, on ? 1 : 0);
      final cur = s.patch;
      if (cur != null && cur.editSlot != slot && !cur.effects[slot].isEmpty) {
        await s.sendPatch(PatchEdit(cur)..setEditSlot(slot));
      }
    });
    _scheduleVerify();
  }

  /// Knob change, coalesced so a drag sends at most ~15 edits per second.
  void setParameter(int slot, int index, int raw) {
    final p = patch;
    if (p == null || !editingEnabled) return;
    patch = (PatchEdit(p)..setParameter(slot, index, raw)).decoded ?? p;
    notifyListeners();
    final key = '$slot.$index';
    _pendingEdits[key]?.cancel();
    _pendingEdits[key] = Timer(const Duration(milliseconds: 70), () async {
      _pendingEdits.remove(key);
      await _write('FX${slot + 1} knob', (s) => s.liveEdit(slot, index + 2, raw));
      _scheduleVerify();
    });
  }

  /// After edits settle, re-read; if the pedal didn't take an edit, resend the whole patch.
  void _scheduleVerify() {
    _verify?.cancel();
    final expected = patch;
    _verify = Timer(const Duration(milliseconds: 700), () async {
      _verify = null;
      final s = session;
      if (s == null || expected == null || _pendingEdits.isNotEmpty) return;
      final back = await s.readPatch(timeout: const Duration(seconds: 2));
      if (back == null) return;
      patch = back;
      if (!listEquals(back.unpacked, expected.unpacked)) {
        await _write('Resend patch', (s) => s.sendPatch(PatchEdit(expected)));
      }
      notifyListeners();
    });
  }

  Future<void> selectPatch(int n) async {
    busy = 'Loading patch ${n + 1}…';
    notifyListeners();
    await _write('Select patch', (s) async {
      await s.selectPatch(n);
      currentSlot = n;
    });
    busy = null;
    notifyListeners();
  }

  Future<void> stepPatch(int delta) => selectPatch(((currentSlot ?? 0) + delta + 50) % 50);

  Future<void> setEffect(int slot, int id) async {
    final p = patch;
    if (p == null) return;
    final e = PatchEdit(p)..setEffect(slot, id, on: p.effects[slot].isOn ?? true);
    if (id != 0) e.setEditSlot(slot);
    busy = 'Sending patch…';
    notifyListeners();
    await _write('Change effect', (s) => s.sendPatch(e));
    busy = null;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect(); // leaves edit mode and closes the link; no notifications after this point
    super.dispose();
  }
}
