import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zoom_core/zoom_core.dart';

import 'bluetooth.dart';
import 'storage.dart';

enum BluetoothProblem { off, permission, blocked }

/// App state: connection, current patch, editing lock, live updates, patch backups. Mirrors the Mac app's LinkModel.
class AppModel extends ChangeNotifier {
  AppModel({this.prefs}) {
    rememberUnlock = prefs?.getBool('rememberUnlock') ?? true;
    editingEnabled = rememberUnlock && (prefs?.getBool('editingUnlocked') ?? false);
    showOnPedalScreen = prefs?.getBool('showOnPedalScreen') ?? true;
    PatchLibrary.latest().then((l) {
      library = l;
      notifyListeners();
    }).catchError((_) {});
  }

  final SharedPreferences? prefs;

  List<PairedDevice> devices = [];
  PairedDevice? device;
  PedalSession? session;
  PatchDump? patch;
  int? currentSlot;
  int selectedSlot = 0;
  bool editingEnabled = false;

  /// Keep editing unlocked when the app restarts (the checkbox in the unlock alert).
  bool rememberUnlock = true;
  bool liveUpdates = true;

  /// Turning an effect on/off also moves the pedal's own display to it.
  bool showOnPedalScreen = true;
  String? busy;
  String? hint;
  String? notice;
  Map<String, Object?> diagnostics = {};

  /// Latest patch backup and patches read this session (slot → patch).
  PatchLibrary? library;
  final Map<int, PatchDump> slots = {};
  int? backupProgress;

  /// A file-system session (Effects) owns the link: live updates and edits pause.
  bool fileSystemActive = false;

  Timer? _poll;
  StreamSubscription<PedalSession>? _changes;
  final Map<String, Timer> _pendingEdits = {};
  Timer? _verify;

  bool get isConnected => session?.identity != null;
  bool get canInteract => isConnected && patch != null && !fileSystemActive;

  /// Why Bluetooth can't be used right now (shown with the matching fix on the connect screen).
  BluetoothProblem? bluetoothProblem;

  /// In-app scan for nearby pedals (Android).
  bool scanning = false;
  List<({String address, String name, bool paired})> nearby = [];
  String? pairing;

  BluetoothProblem? _problemOf(Object e) => switch (e) {
        PlatformException(code: 'bluetooth_off') => BluetoothProblem.off,
        PlatformException(code: 'permission') => BluetoothProblem.permission,
        PlatformException(code: 'permission_blocked') => BluetoothProblem.blocked,
        _ => null,
      };

  Future<void> refreshDevices() async {
    try {
      devices = await BluetoothBridge.pairedDevices();
      device ??= devices.where((d) => d.looksLikePedal).firstOrNull ?? devices.firstOrNull;
      bluetoothProblem = null;
    } catch (e) {
      bluetoothProblem = _problemOf(e);
      if (bluetoothProblem == null) hint = 'Bluetooth: $e';
    }
    try {
      diagnostics = await BluetoothBridge.diagnostics();
    } catch (_) {}
    notifyListeners();
  }

  /// Fixes the current Bluetooth problem: asks again, opens Settings, or asks to turn Bluetooth on.
  Future<void> fixBluetooth() async {
    try {
      switch (bluetoothProblem) {
        case BluetoothProblem.off:
          await BluetoothBridge.enableBluetooth();
          await Future<void>.delayed(const Duration(seconds: 2));
        case BluetoothProblem.blocked:
          await BluetoothBridge.openSettings();
          return; // refreshed when the app comes back (see HomeScreen)
        case BluetoothProblem.permission || null:
          break;
      }
    } catch (_) {}
    await refreshDevices();
  }

  /// Scans for nearby devices; pedals first.
  Future<void> scanForPedals() async {
    if (scanning) return;
    scanning = true;
    nearby = [];
    notifyListeners();
    try {
      final found = await BluetoothBridge.scan();
      bool pedal(String n) => PairedDevice('', n).looksLikePedal;
      nearby = found..sort((a, b) => (pedal(b.name) ? 1 : 0) - (pedal(a.name) ? 1 : 0));
      bluetoothProblem = null;
      if (nearby.isEmpty) hint = 'No devices found. Put the pedal in pairing mode (knob 1 → MENU → Bluetooth → PAIRING) and scan again.';
    } catch (e) {
      bluetoothProblem = _problemOf(e);
      if (bluetoothProblem == null) hint = 'Scan failed: $e';
    }
    scanning = false;
    notifyListeners();
  }

  /// Pairs with a scanned device, then selects it.
  Future<void> pairWith(String address) async {
    pairing = address;
    notifyListeners();
    try {
      final ok = await BluetoothBridge.pair(address);
      if (!ok) hint = 'Pairing did not finish. Check that the pedal is in pairing mode and try again.';
      await refreshDevices();
      if (ok) {
        device = devices.where((d) => d.address == address).firstOrNull ?? device;
        nearby = [];
      }
    } catch (e) {
      bluetoothProblem = _problemOf(e);
      if (bluetoothProblem == null) hint = 'Pairing failed: $e';
    }
    pairing = null;
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
        if (_pendingEdits.isEmpty && !fileSystemActive) patch = s.patch;
        notifyListeners();
      });
      final id = await s.identify();
      if (id == null || !id.isKnownMS100BTId) throw PedalError('No MS-100BT identity reply.');
      busy = 'Reading the patch…';
      notifyListeners();
      patch = await s.readPatch();
      currentSlot = inferSlot();
      if (liveUpdates) await _startLive();
    } catch (e) {
      bluetoothProblem = _problemOf(e);
      if (bluetoothProblem == null) hint = 'Could not connect: $e';
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
      if (busy != null || fileSystemActive || _pendingEdits.isNotEmpty || _verify != null || session == null) return;
      final p = await session!.readPatch(timeout: const Duration(milliseconds: 1500));
      if (p != null && !fileSystemActive) {
        patch = p;
        notifyListeners();
      }
    });
  }

  /// Hands the link to a file-system session (Effects): polling stops; the engine leaves edit mode itself.
  void pauseForFileSystem() {
    _poll?.cancel();
    _verify?.cancel();
    _verify = null;
    fileSystemActive = true;
    notifyListeners();
  }

  Future<void> resumeAfterFileSystem() async {
    fileSystemActive = false;
    final s = session;
    if (s != null) {
      patch = await s.readPatch() ?? patch;
      if (liveUpdates) await _startLive();
    }
    notifyListeners();
  }

  void setEditing(bool on) {
    editingEnabled = on;
    session?.writesEnabled = on;
    prefs?.setBool('editingUnlocked', on && rememberUnlock); // remembered between launches only if asked
    notifyListeners();
  }

  void setRememberUnlock(bool on) {
    rememberUnlock = on;
    prefs?.setBool('rememberUnlock', on);
    prefs?.setBool('editingUnlocked', on && editingEnabled);
  }

  void setShowOnPedalScreen(bool on) {
    showOnPedalScreen = on;
    prefs?.setBool('showOnPedalScreen', on);
    notifyListeners();
  }

  Future<bool> _write(String label, Future<void> Function(PedalSession s) action) async {
    final s = session;
    if (s == null || !editingEnabled || fileSystemActive) return false;
    try {
      await action(s);
      patch = s.patch;
      return true;
    } catch (e) {
      hint = '$label failed: $e';
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _busy(String label, Future<void> Function() body) async {
    busy = label;
    notifyListeners();
    try {
      await body();
    } finally {
      busy = null;
      notifyListeners();
    }
  }

  /// On/off; also moves the pedal's own display to this effect (as on the Mac).
  Future<void> setOn(int slot, bool on) async {
    selectedSlot = slot;
    await _write('FX${slot + 1} on/off', (s) async {
      await s.liveEdit(slot, 0, on ? 1 : 0);
      final cur = s.patch;
      if (showOnPedalScreen && cur != null && cur.editSlot != slot && !cur.effects[slot].isEmpty) {
        await s.sendPatch(PatchEdit(cur)..setEditSlot(slot));
      }
    });
    _scheduleVerify();
  }

  /// Knob change, coalesced so a drag sends at most ~15 edits per second.
  void setParameter(int slot, int index, int raw) {
    final p = patch;
    if (p == null || !editingEnabled || fileSystemActive) return;
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
      if (s == null || expected == null || _pendingEdits.isNotEmpty || fileSystemActive) return;
      final back = await s.readPatch(timeout: const Duration(seconds: 2));
      if (back == null) return;
      patch = back;
      if (!listEquals(back.unpacked, expected.unpacked)) {
        await _write('Resend patch', (s) => s.sendPatch(PatchEdit(expected)));
      }
      notifyListeners();
    });
  }

  Future<void> selectPatch(int n) => _busy('Loading patch ${n + 1}…', () async {
        await _write('Select patch', (s) async {
          final p = await s.selectPatch(n);
          if (p != null) slots[n] = p;
          currentSlot = n;
        });
      });

  Future<void> stepPatch(int delta) =>
      selectPatch(((currentSlot ?? inferSlot() ?? 0) + delta + Allowlist.patchSlots) % Allowlist.patchSlots);

  /// Best guess of the active slot by comparing the current patch with known slots.
  int? inferSlot() {
    final p = patch;
    if (p == null) return null;
    final known = {...?library?.patches, ...slots};
    final exact = known.entries.where((e) => listEquals(e.value.unpacked, p.unpacked)).firstOrNull;
    if (exact != null) return exact.key;
    final byName = known.entries.where((e) => e.value.name == p.name).toList();
    return byName.length == 1 ? byName.first.key : null;
  }

  Future<void> setEffect(int slot, int id) async {
    final p = patch;
    if (p == null) return;
    final e = PatchEdit(p)..setEffect(slot, id, on: p.effects[slot].isOn ?? true);
    if (id != 0) e.setEditSlot(slot);
    await _busy('Sending patch…', () => _write('Change effect', (s) => s.sendPatch(e)));
  }

  /// Sends a complete edited patch (e.g. an AI proposal or a .syx file) and confirms it by reading it back.
  Future<bool> applyEdit(PatchEdit e, String label) async {
    hint = null;
    var ok = false;
    await _busy('$label…', () async => ok = await _write(label, (s) => s.sendPatch(e)));
    return ok && listEquals(patch?.unpacked, e.decoded?.unpacked);
  }

  Future<void> rename(String name) async {
    final p = patch;
    if (p != null) await applyEdit(PatchEdit(p)..setName(name), 'Rename');
  }

  Future<void> setTempo(int bpm) async {
    final p = patch;
    if (p != null) await applyEdit(PatchEdit(p)..setTempo(bpm), 'Set tempo');
  }

  /// Reads all 50 patches into a new backup folder (the pedal steps through every patch).
  Future<void> backupAll() async {
    final s = session;
    if (s == null || !editingEnabled) return;
    backupProgress = 0;
    notifyListeners();
    final start = currentSlot ?? inferSlot();
    await _write('Backup', (s) async {
      final all = await s.readAllPatches(progress: (n, p) {
        backupProgress = n + 1;
        if (p != null) slots[n] = p;
        notifyListeners();
      });
      library = await PatchLibrary.save(all);
      currentSlot = start ?? inferSlot();
      notice = 'Backed up ${all.length} patches.';
      if (all.length < Allowlist.patchSlots) hint = 'Only ${all.length} of 50 patches were read; the backup is incomplete.';
    });
    backupProgress = null;
    notifyListeners();
  }

  /// Stores the active patch into `slot`. The caller confirms; a backup holding that slot is required.
  Future<void> store(int slot) async {
    if (library?.patches[slot] == null) {
      hint = 'Back up all patches first: storing overwrites patch ${slot + 1}.';
      notifyListeners();
      return;
    }
    await _busy('Storing…', () => _write('Store', (s) async {
          await s.storePatch(slot);
          final p = s.patch;
          if (p != null) slots[slot] = p;
          currentSlot = slot;
          notice = 'Stored "${p?.name ?? '?'}" into patch ${slot + 1}.';
        }));
  }

  /// Loads a .syx patch into the edit buffer (not stored until the user stores it).
  Future<void> importPatch(List<int> bytes) async {
    final file = PatchDump.decode(bytes);
    final id = session?.deviceId;
    if (file == null || id == null) {
      hint = 'Not a valid MS-100BT patch file.';
      notifyListeners();
      return;
    }
    final problem = file.validationProblem;
    if (problem != null) {
      hint = 'Patch file refused: $problem';
      notifyListeners();
      return;
    }
    final framed = file.deviceId == id ? file : PatchDump.decode([0xF0, 0x52, 0x00, id, ...file.raw.sublist(4)])!;
    await applyEdit(PatchEdit(framed), 'Load patch file');
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
