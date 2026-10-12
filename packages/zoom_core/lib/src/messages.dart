// Port of MS100BTLink/Sources/ZoomCore/Messages.swift. Keep the two in sync.

import 'patch_dump.dart';

String hex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

/// Every message the app can build. Reads are always allowed; writes (`isWrite`)
/// additionally need the session's write lock open. Nothing here touches firmware
/// or the pedal's file system.
sealed class Message {
  const Message();
  List<int> get bytes;
  String get label;
  bool get isWrite => false;

  static List<int> _zoom(int id, int op) => [0xF0, 0x52, 0x00, id, op, 0xF7];
}

/// `F0 7E 00 06 01 F7`: the first message Zoom's own updater sends.
class IdentityRequest extends Message {
  const IdentityRequest();
  @override
  List<int> get bytes => const [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7];
  @override
  String get label => 'identity request';
}

/// `F0 7E 7F 06 01 F7`: broadcast form, fallback only.
class IdentityRequestBroadcast extends Message {
  const IdentityRequestBroadcast();
  @override
  List<int> get bytes => const [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7];
  @override
  String get label => 'identity request (broadcast)';
}

class RequestCurrentPatch extends Message {
  const RequestCurrentPatch(this.deviceId);
  final int deviceId;
  @override
  List<int> get bytes => Message._zoom(deviceId, 0x29);
  @override
  String get label => 'request current patch (0x29)';
}

class RequestCurrentProgram extends Message {
  const RequestCurrentProgram(this.deviceId);
  final int deviceId;
  @override
  List<int> get bytes => Message._zoom(deviceId, 0x33);
  @override
  String get label => 'request current program (0x33)';
}

class EditModeOn extends Message {
  const EditModeOn(this.deviceId);
  final int deviceId;
  @override
  List<int> get bytes => Message._zoom(deviceId, 0x50);
  @override
  String get label => 'edit mode on (0x50)';
}

class EditModeOff extends Message {
  const EditModeOff(this.deviceId);
  final int deviceId;
  @override
  List<int> get bytes => Message._zoom(deviceId, 0x51);
  @override
  String get label => 'edit mode off (0x51)';
}

/// `C0 <pp>`: select patch 0…49.
class SelectPatch extends Message {
  const SelectPatch(this.patch);
  final int patch;
  @override
  List<int> get bytes => [0xC0, patch.clamp(0, 127)];
  @override
  String get label => 'select patch ${patch + 1} (C0)';
  @override
  bool get isWrite => true;
}

/// `F0 52 00 <id> 31 <slot> <param> <lsb> <msb> F7`. param 0 = on/off, 2…10 = P0…P8.
class ParameterEdit extends Message {
  const ParameterEdit(this.deviceId, this.slot, this.param, this.value);
  final int deviceId, slot, param, value;
  @override
  List<int> get bytes =>
      [0xF0, 0x52, 0x00, deviceId, 0x31, slot, param, value & 0x7F, (value >> 7) & 0x7F, 0xF7];
  @override
  String get label => param == 0
      ? 'FX${slot + 1} ${value == 1 ? 'on' : 'off'} (0x31)'
      : 'FX${slot + 1} P${param - 2} = $value (0x31)';
  @override
  bool get isWrite => true;
}

/// A full 146-byte `F0 52 00 <id> 28 … F7` patch for the edit buffer.
class SendPatch extends Message {
  const SendPatch(this.frame);
  final List<int> frame;
  @override
  List<int> get bytes => frame;
  @override
  String get label => 'send patch (0x28)';
  @override
  bool get isWrite => true;
}

/// `F0 52 00 <id> 32 01 00 00 <pp> 00 00 00 00 00 F7`: store into slot pp.
class StorePatch extends Message {
  const StorePatch(this.deviceId, this.slot);
  final int deviceId, slot;
  @override
  List<int> get bytes =>
      [0xF0, 0x52, 0x00, deviceId, 0x32, 0x01, 0x00, 0x00, slot, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7];
  @override
  String get label => 'STORE to patch ${slot + 1} (0x32)';
  @override
  bool get isWrite => true;
}

class AllowlistViolation implements Exception {
  AllowlistViolation(this.frame, this.reason);
  final List<int> frame;
  final String reason;
  @override
  String toString() => 'Blocked outbound frame [${hex(frame)}]: $reason';
}

/// Hard gate every transport applies before any byte leaves the device.
/// Exact shapes only: anything not recognised here is refused.
abstract final class Allowlist {
  static const patchSlots = 50;
  static const knownDeviceIds = {0x5D, 0x5E};
  static const readOpcodes = {0x29, 0x33, 0x50, 0x51};
  static const forbiddenOpcodes = {
    0x01: 'flash write begin (firmware updater)',
    0x04: 'flash write end (firmware updater)',
    0x05: 'unknown, firmware template',
    0x17: 'unknown, firmware template',
    0x20: 'unknown, firmware template',
    0x21: 'unknown, firmware template',
    0x60: 'filesystem access (updater ZDL upload)',
    0x61: 'Bluetooth-module function (updater)',
  };

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Throws [AllowlistViolation] unless `f` is an allowed message.
  static void validate(List<int> f) {
    Never refuse(String why) => throw AllowlistViolation(f, why);
    if (_eq(f, const IdentityRequest().bytes) || _eq(f, const IdentityRequestBroadcast().bytes)) return;

    if (f.length == 2 && f[0] == 0xC0) {
      if (f[1] >= patchSlots) refuse('patch number ${f[1]} out of range');
      return;
    }
    if (f.length < 6 || f[0] != 0xF0 || f[1] != 0x52 || f[2] != 0x00 || f.last != 0xF7) {
      refuse('not an allowlisted message shape');
    }
    final id = f[3], op = f[4];
    final why = forbiddenOpcodes[op];
    if (why != null) refuse('opcode ${op.toRadixString(16)} is forbidden: $why');
    if (!knownDeviceIds.contains(id)) refuse('device ID ${id.toRadixString(16)} is not a known MS-100BT ID');
    if (f.sublist(1, f.length - 1).any((b) => b >= 0x80)) refuse('data byte >= 0x80');

    if (readOpcodes.contains(op)) {
      if (f.length != 6) refuse('read request must be 6 bytes');
    } else if (op == 0x31) {
      if (f.length != 10) refuse('parameter edit must be 10 bytes');
      if (f[5] >= 6) refuse('effect slot ${f[5]} out of range');
      if (!(f[6] == 0 || (f[6] >= 2 && f[6] <= 10))) refuse('parameter number ${f[6]} not allowed');
      if (f[6] == 0 && (f[7] > 1 || f[8] != 0)) refuse('on/off value must be 0 or 1');
    } else if (op == 0x28) {
      if (f.length != PatchDump.expectedLength) refuse('patch must be ${PatchDump.expectedLength} bytes');
      final p = PatchDump.decode(f);
      if (p == null) refuse('patch does not decode');
      final problem = p.validationProblem;
      if (problem != null) refuse('patch failed validation: $problem');
    } else if (op == 0x32) {
      final slot = f.length > 8 ? f[8] : 0;
      final template = [0xF0, 0x52, 0x00, id, 0x32, 0x01, 0x00, 0x00, slot, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7];
      if (!_eq(f, template)) refuse('store must match the documented 15-byte form');
      if (slot >= patchSlots) refuse('patch slot $slot out of range');
    } else {
      refuse('opcode ${op.toRadixString(16)} is not allowlisted');
    }
  }

  static bool isAllowed(List<int> f) {
    try {
      validate(f);
      return true;
    } on AllowlistViolation {
      return false;
    }
  }

  static bool isWrite(List<int> f) {
    if (f.length == 2 && f[0] == 0xC0) return true;
    return f.length > 4 && f[0] == 0xF0 && const {0x28, 0x31, 0x32}.contains(f[4]);
  }
}
