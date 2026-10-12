// Port of SimulatedPedal.swift: an in-memory MS-100BT answering identity and the file-system protocol
// byte-for-byte as documented from hardware (lopezchau/zoom-ms100bt-bluetooth docs/PROTOCOL.md), with
// failure injection. Every outbound frame is checked by the real allowlist, like the real transports do.
import 'dart:async';

import 'package:zoom_core/zoom_core.dart';

sealed class _Handle {}

class _Read extends _Handle {
  _Read(this.name, this.pos);
  final String name;
  int pos;
}

class _Write extends _Handle {
  _Write(this.name, this.failing);
  final String name;
  final bool failing;
  final List<int> buf = [];
}

class SimulatedPedal implements PedalTransport {
  final _out = StreamController<List<int>>.broadcast();
  final Map<String, List<int>> files = {};
  int maxFiles = 200;
  int totalBytes = 4143170;
  final List<List<int>> sent = [];

  // Failure injection
  bool corruptNextReadCrc = false;

  /// name → number of upcoming opens whose blocks are rejected.
  final Map<String, int> failWritesFor = {};

  /// Stop answering (lost connection).
  bool silent = false;

  final Map<String, _Handle> _handles = {};
  List<int>? _pendingData;
  List<String> _listing = [];

  static const _notFound = 0xFFFFFFFA;

  @override
  Stream<List<int>> get incoming => _out.stream;

  @override
  Future<void> close() async => _out.close();

  /// File-system writes sent to the pedal.
  List<List<int>> get fileWrites => sent.where((f) => Allowlist.fileSystemAccess(f) == FileSystemAccess.write).toList();

  @override
  Future<void> write(List<int> f) async {
    Allowlist.validate(f);
    sent.add(f);
    if (silent) return;
    if (f.length == 6 && f[1] == 0x7E) {
      _reply([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0x5E, 0x00, 0x01, 0x00, 0x31, 0x2E, 0x33, 0x30, 0xF7]);
      return;
    }
    if (f.length < 7 || f[4] != 0x60) return;
    _handleFS(f.sublist(5, f.length - 1));
  }

  void _reply(List<int> m) => scheduleMicrotask(() => _out.add(m));
  void _status(int v) => _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x03, ...FSCodec.u7x5(v), 0xF7]);
  static String _name(List<int> b) => String.fromCharCodes(b.takeWhile((c) => c != 0));
  static String _key(List<int> h) => h.join(',');

  void _handleFS(List<int> b) {
    switch (b[0]) {
      case 0x02:
        _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x02, ...List.filled(13, 0), ...FSCodec.u7x5(4096), 0xF7]);
      case 0x05:
        final d = _pendingData;
        if (d != null) {
          _pendingData = null;
          _reply(d);
        } else {
          _status(0);
        }
      case 0x09:
        _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x05, 0x00, 0xF7]);
      case 0x29:
        final used = files.values.fold(0, (n, d) => n + d.length);
        _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x29, 0, 0, 0, 0, ...FSCodec.u7x5(totalBytes), ...FSCodec.u7x5(totalBytes - used), 0xF7]);
      case 0x25 || 0x26:
        if (b[0] == 0x25) _listing = files.keys.toList()..sort();
        if (_listing.isEmpty) return _status(_notFound);
        final n = _listing.removeAt(0);
        final field = [...n.codeUnits.take(12), ...List.filled(12 - (n.length < 12 ? n.length : 12), 0)];
        _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, b[0], ...List.filled(8, 0), ...field, 0, 0, 0, ...FSCodec.u7x5(files[n]!.length), 0, 0xF7]);
      case 0x27:
        _status(0);
      case 0x20:
        final n = _name(b.sublist(11));
        final h = n == EffectIndex.fileName ? const [0x54, 0x26, 0x46, 0x28, 0x0E] : const [0, 0, 0, 0, 0];
        if (b[1] == 0x02) {
          if (!files.containsKey(n)) return _status(_notFound);
          _handles[_key(h)] = _Read(n, 0);
        } else {
          final full = !files.containsKey(n) && files.length >= maxFiles;
          var failing = false;
          final k = failWritesFor[n] ?? 0;
          if (k > 0) {
            failWritesFor[n] = k - 1;
            failing = true;
          }
          _handles[_key(h)] = _Write(n, full || failing);
        }
        _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x20, 0, 0, 4, 0, ...h, 0, 0xF7]);
      case 0x22:
        final want = FSCodec.u35(b, 6) ?? 0;
        final h = _handles[_key(b.sublist(1, 6))];
        if (h is! _Read || !files.containsKey(h.name)) return _status(_notFound);
        final data = files[h.name]!;
        final end = h.pos + want < data.length ? h.pos + want : data.length;
        final block = data.sublist(h.pos, end);
        h.pos = end;
        var crc = FSCodec.crc32(block) ^ 0xFFFFFFFF;
        if (corruptNextReadCrc) {
          corruptNextReadCrc = false;
          crc ^= 1;
        }
        _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x22, 0x00, 0xF7]); // short acknowledgement
        _pendingData = [0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x22, 0x01, 0x00, block.length & 0x7F, block.length >> 7,
            ...pack7(block), ...FSCodec.u7x5(crc), 0xF7];
      case 0x23:
        final size = FSCodec.u35(b, 6)!;
        final h = _handles[_key(b.sublist(1, 6))];
        if (h is! _Write) return _status(_notFound);
        if (h.failing) return _status(0xFFFFFFFF); // e.g. the 201st file: open works, first block refused
        h.buf.addAll(unpack7(b.sublist(11, b.length - 5)));
        _reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x23, 0, 0, 4, 0, ...FSCodec.u7x5(size), 0xF7]);
      case 0x21:
        final k = _key(b.sublist(1, 6));
        final h = _handles[k];
        if (h is _Write && !h.failing) files[h.name] = List.of(h.buf);
        _handles.remove(k);
        _status(0);
      case 0x24:
        _status(files.remove(_name(b.sublist(1))) == null ? _notFound : 0);
      default:
        _status(0xFFFFFFFF);
    }
  }
}

List<int> _le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// A minimal but well-formed ZDL: standard 56-byte header, an ELF stub, and the firmware's
/// descriptor table (OnOff, display name, knobs).
List<int> makeZDL({required int category, required int id, required String name,
    List<String> knobs = const ['Gain', 'Tone', 'Level'], int padTo = 0}) {
  List<int> entry(String s, int word3) {
    final e = [...s.codeUnits.take(12), ...List.filled(12 - (s.length < 12 ? s.length : 12), 0), ..._le32(word3)];
    return [...e, ...List.filled(0x30 - e.length, 0)];
  }

  final elf = [0x7F, 0x45, 0x4C, 0x46, ...List.filled(60, 0), ...entry('OnOff', 1), ...entry(name, 0xFFFFFFFF),
    for (final k in knobs) ...entry(k, 2), ...List.filled(0x30, 0)];
  if (padTo > 76 + elf.length) elf.addAll(List.filled(padTo - 76 - elf.length, 0x11));
  final h = [0, 0, 0, 0, ...'SIZE'.codeUnits, ..._le32(8), ..._le32(56), ..._le32(elf.length), ...'INFO'.codeUnits];
  h.addAll(List.filled(76 - h.length, 0));
  h[60] = category;
  h[61] = 1;
  h[64] = id & 0xFF;
  h[65] = id >> 8;
  h.setRange(68, 72, '1.00'.codeUnits);
  return [...h, ...elf];
}

/// A stock-like effect menu with the given categories.
List<int> makeIndex(List<(int, List<String>)> cats, {int size = 4108}) =>
    EffectIndex([for (final c in cats) EffectMenuCategory(c.$1, List.of(c.$2))], size).build();
