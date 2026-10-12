// Port of MS100BTLink/Sources/ZoomCore/SysExFramer.swift.

/// One complete MIDI message pulled out of the byte stream.
sealed class MidiEvent {
  const MidiEvent();
}

class SysEx extends MidiEvent {
  const SysEx(this.bytes);
  final List<int> bytes;
  @override
  bool operator ==(Object o) => o is SysEx && _listEq(o.bytes, bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
  @override
  String toString() => 'SysEx($bytes)';
}

class ChannelMessage extends MidiEvent {
  const ChannelMessage(this.bytes);
  final List<int> bytes;
  @override
  bool operator ==(Object o) => o is ChannelMessage && _listEq(o.bytes, bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
  @override
  String toString() => 'Channel($bytes)';
}

class CommonMessage extends MidiEvent {
  const CommonMessage(this.bytes);
  final List<int> bytes;
  @override
  bool operator ==(Object o) => o is CommonMessage && _listEq(o.bytes, bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
}

class Realtime extends MidiEvent {
  const Realtime(this.byte);
  final int byte;
  @override
  bool operator ==(Object o) => o is Realtime && o.byte == byte;
  @override
  int get hashCode => byte;
  @override
  String toString() => 'Realtime($byte)';
}

/// Bytes that fit no MIDI framing (e.g. a SysEx cut off by a status byte).
class Stray extends MidiEvent {
  const Stray(this.bytes);
  final List<int> bytes;
  @override
  bool operator ==(Object o) => o is Stray && _listEq(o.bytes, bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
  @override
  String toString() => 'Stray($bytes)';
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Reassembles MIDI messages from an arbitrarily chunked byte stream.
class SysExFramer {
  static const maxSysExLength = 64 * 1024;

  List<int>? _sysex;
  int? _runningStatus;
  List<int> _pending = [];
  int _expectedData = 0;

  List<MidiEvent> feed(List<int> bytes) {
    final out = <MidiEvent>[];
    for (final b in bytes) {
      _feedByte(b, out);
    }
    return out;
  }

  void _feedByte(int b, List<MidiEvent> out) {
    if (b >= 0xF8) {
      out.add(Realtime(b));
      return;
    }
    if (b == 0xF0) {
      if (_sysex != null) out.add(Stray(_sysex!));
      _sysex = [b];
      _runningStatus = null;
      _pending = [];
      return;
    }
    if (b == 0xF7) {
      if (_sysex != null) {
        out.add(SysEx([..._sysex!, b]));
        _sysex = null;
      } else {
        out.add(Stray([b]));
      }
      return;
    }
    if (_sysex != null) {
      if (b < 0x80) {
        if (_sysex!.length < maxSysExLength) _sysex!.add(b);
        return;
      }
      out.add(Stray(_sysex!));
      _sysex = null;
    }
    if (b >= 0x80) {
      _pending = [b];
      if (b >= 0x80 && b <= 0xEF) {
        _runningStatus = b;
        final hi = b & 0xF0;
        _expectedData = (hi == 0xC0 || hi == 0xD0) ? 1 : 2;
      } else if (b == 0xF1 || b == 0xF3) {
        _runningStatus = null;
        _expectedData = 1;
      } else if (b == 0xF2) {
        _runningStatus = null;
        _expectedData = 2;
      } else {
        _runningStatus = null;
        _expectedData = 0;
        out.add(CommonMessage([b]));
        _pending = [];
      }
      return;
    }
    if (_pending.isEmpty) {
      final rs = _runningStatus;
      if (rs == null) {
        out.add(Stray([b]));
        return;
      }
      _pending = [rs];
    }
    _pending.add(b);
    if (_pending.length == _expectedData + 1) {
      final status = _pending[0];
      out.add(status >= 0xF0 ? CommonMessage(_pending) : ChannelMessage(_pending));
      _pending = [];
    }
  }
}
