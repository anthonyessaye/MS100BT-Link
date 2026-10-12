// Port of IdentityReply / ZoomSysEx (Decoders.swift).

import 'messages.dart';

/// `F0 7E <ch> 06 02 52 <id> 00 <mode> 00 <v1> <v2> <v3> <v4> F7`.
class IdentityReply {
  const IdentityReply(this.deviceId, this.mode, this.version);
  final int deviceId;
  final int mode;

  /// ASCII firmware version, e.g. "1.30".
  final String version;

  bool get isKnownMS100BTId => Allowlist.knownDeviceIds.contains(deviceId);

  static IdentityReply? decode(List<int> m) {
    if (m.length < 11 || m.first != 0xF0 || m.last != 0xF7 || m[1] != 0x7E || m[3] != 0x06 || m[4] != 0x02 ||
        m[5] != 0x52) {
      return null;
    }
    final v = m.sublist(10, m.length - 1).where((b) => b >= 0x20 && b <= 0x7E);
    return IdentityReply(m[6], m[8], String.fromCharCodes(v));
  }
}

/// Any Zoom-format SysEx: `F0 52 00 <id> <op> … F7`.
class ZoomSysEx {
  const ZoomSysEx(this.deviceId, this.opcode, this.payload);
  final int deviceId, opcode;
  final List<int> payload;

  static ZoomSysEx? decode(List<int> m) {
    if (m.length < 6 || m[0] != 0xF0 || m[1] != 0x52 || m[2] != 0x00 || m.last != 0xF7) return null;
    return ZoomSysEx(m[3], m[4], m.sublist(5, m.length - 1));
  }
}
