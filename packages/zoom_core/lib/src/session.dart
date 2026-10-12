// Port of PedalSession (Swift ZoomCore): one connection to the pedal over any byte transport.

import 'dart:async';

import 'identity.dart';
import 'messages.dart';
import 'patch_dump.dart';
import 'sysex_framer.dart';

/// A byte pipe to the pedal (Bluetooth SPP on Android/macOS, a fake in tests).
/// Implementations must call [Allowlist.validate] before writing; [PedalSession] does too.
abstract class PedalTransport {
  Stream<List<int>> get incoming;
  Future<void> write(List<int> bytes);
  Future<void> close();
}

class WriteLocked implements Exception {
  WriteLocked(this.label);
  final String label;
  @override
  String toString() => 'Write refused (editing is locked): $label';
}

class PedalError implements Exception {
  PedalError(this.message);
  final String message;
  @override
  String toString() => message;
}

class PedalSession {
  PedalSession(this.transport) {
    _sub = transport.incoming.listen(_onBytes);
  }

  final PedalTransport transport;
  late final StreamSubscription<List<int>> _sub;
  final _framer = SysExFramer();

  /// Write lock. Patch select, edits, send and store are refused while false.
  bool writesEnabled = false;
  bool editModeActive = false;

  /// File-system reads (listing, backup) are refused unless a file-system session is open.
  bool fileSystemEnabled = false;

  /// File writes/deletes additionally need this (set only while an approved change plan runs) and [writesEnabled].
  bool fileSystemWritesEnabled = false;

  /// Replies to file-system commands, collected for [PedalFileSystem].
  final List<List<int>> fileSystemInbox = [];

  IdentityReply? identity;
  PatchDump? patch;
  DateTime? _identityAt, _patchAt;
  final _changes = StreamController<PedalSession>.broadcast();
  final List<String> log = [];

  /// Fires whenever identity or the patch changes (including pushes from the pedal).
  Stream<PedalSession> get changes => _changes.stream;
  int? get deviceId => identity?.deviceId;

  Future<void> close() async {
    if (editModeActive) await leaveEditMode();
    await _sub.cancel();
    await transport.close();
    await _changes.close();
  }

  Future<void> send(Message m) async {
    if (m.isWrite && !writesEnabled) throw WriteLocked(m.label);
    switch (Allowlist.fileSystemAccess(m.bytes)) {
      case FileSystemAccess.read when !fileSystemEnabled:
        throw WriteLocked('${m.label} (file-system session closed)');
      case FileSystemAccess.write when !(fileSystemWritesEnabled && writesEnabled && fileSystemEnabled):
        throw WriteLocked('${m.label} (file writes locked)');
      default:
    }
    Allowlist.validate(m.bytes);
    log.add('→ ${hex(m.bytes)}  ${m.label}');
    await transport.write(m.bytes);
  }

  void _onBytes(List<int> bytes) {
    log.add('← ${hex(bytes)}');
    for (final e in _framer.feed(bytes)) {
      if (e is SysEx) {
        final id = IdentityReply.decode(e.bytes);
        if (id != null) {
          identity = id;
          _identityAt = DateTime.now();
          _changes.add(this);
          continue;
        }
        final p = PatchDump.decode(e.bytes);
        if (p != null) {
          patch = p;
          _patchAt = DateTime.now();
          _changes.add(this);
          continue;
        }
        final z = ZoomSysEx.decode(e.bytes);
        if (z != null && z.opcode == 0x60) {
          fileSystemInbox.add(e.bytes);
          continue;
        }
        if (z != null && z.opcode == 0x31 && z.payload.length >= 4 && patch != null) {
          // The pedal reporting a knob/switch change: mirror it locally.
          final edit = PatchEdit(patch!);
          final slot = z.payload[0], param = z.payload[1], value = z.payload[2] | (z.payload[3] << 7);
          if (slot < 6) {
            if (param == 0) edit.setOn(slot, value == 1);
            if (param >= 2) edit.setParameter(slot, param - 2, value);
            patch = edit.decoded ?? patch;
            _changes.add(this);
          }
        }
      }
    }
  }

  Future<T?> waitFor<T>(Duration timeout, T? Function() get) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final v = get();
      if (v != null) return v;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return get();
  }

  T? _fresh<T>(T? v, DateTime? at, DateTime after) => (v != null && at != null && !at.isBefore(after)) ? v : null;

  Future<IdentityReply?> identify({Duration timeout = const Duration(seconds: 2)}) async {
    for (final m in const [IdentityRequest(), IdentityRequestBroadcast()]) {
      final t = DateTime.now();
      await send(m);
      final r = await waitFor(timeout, () => _fresh(identity, _identityAt, t));
      if (r != null) return r;
    }
    return null;
  }

  Future<void> enterEditMode() async {
    final id = deviceId;
    if (id == null || editModeActive) return;
    await send(EditModeOn(id));
    editModeActive = true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  Future<void> leaveEditMode() async {
    final id = deviceId;
    if (id == null || !editModeActive) return;
    await send(EditModeOff(id));
    editModeActive = false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  /// Reads the current patch. The MS-100BT only answers 0x29 in edit mode, so it is bracketed
  /// by 0x50/0x51 unless edit mode is already held.
  Future<PatchDump?> readPatch({Duration timeout = const Duration(seconds: 3)}) async {
    final id = deviceId;
    if (id == null) return null;
    final hold = editModeActive;
    if (!hold) await enterEditMode();
    try {
      final t = DateTime.now();
      await send(RequestCurrentPatch(id));
      return await waitFor(timeout, () => _fresh(patch, _patchAt, t));
    } finally {
      if (!hold) await leaveEditMode();
    }
  }

  /// Live edit (0x31). param 0 = on/off; 2…10 = P0…P8.
  Future<void> liveEdit(int slot, int param, int value) async {
    final id = deviceId;
    if (id == null) throw PedalError('No device ID yet (identify first).');
    await send(ParameterEdit(id, slot, param, value));
    final p = patch;
    if (p != null) {
      final e = PatchEdit(p);
      if (param == 0) {
        e.setOn(slot, value == 1);
      } else {
        e.setParameter(slot, param - 2, value);
      }
      patch = e.decoded ?? patch;
      _changes.add(this);
    }
  }

  /// Sends a whole patch to the edit buffer, then reads it back to confirm.
  Future<PatchDump> sendPatch(PatchEdit edit) async {
    final d = edit.decoded;
    if (d == null) throw PedalError('Refused: patch does not decode');
    final problem = d.validationProblem;
    if (problem != null) throw PedalError('Refused: $problem');
    await send(SendPatch(edit.frame));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final back = await readPatch();
    if (back == null) throw PedalError('Pedal did not confirm: no patch dump after send');
    if (!_eq(back.unpacked, d.unpacked)) throw PedalError('Pedal did not confirm: read-back differs from what was sent');
    return back;
  }

  Future<PatchDump?> selectPatch(int n) async {
    await send(SelectPatch(n));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return readPatch();
  }

  Future<void> storePatch(int slot) async {
    final id = deviceId;
    if (id == null) throw PedalError('No device ID yet (identify first).');
    await send(StorePatch(id, slot));
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
