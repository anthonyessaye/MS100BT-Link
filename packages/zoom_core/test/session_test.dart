// Session tests against a fake pedal that answers like the MS-100BT (verified behaviour).
import 'dart:async';

import 'package:test/test.dart';
import 'package:zoom_core/zoom_core.dart';

import 'zoom_core_test.dart' show bourj;

class FakePedal implements PedalTransport {
  final _out = StreamController<List<int>>.broadcast();
  final List<List<int>> sent = [];
  List<int> current = List.of(bourj);
  bool editMode = false;

  @override
  Stream<List<int>> get incoming => _out.stream;

  @override
  Future<void> write(List<int> b) async {
    Allowlist.validate(b); // the transport-level gate
    sent.add(b);
    if (b.length == 6 && b[1] == 0x7E) {
      scheduleMicrotask(() => _out.add([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0x5E, 0x00, 0x01, 0x00, 0x31, 0x2E, 0x33, 0x30, 0xF7]));
      return;
    }
    if (b[0] == 0xC0) return;
    switch (b[4]) {
      case 0x50:
        editMode = true;
      case 0x51:
        editMode = false;
      case 0x29:
        if (editMode) scheduleMicrotask(() => _out.add(current)); // only answered in edit mode, as on the real pedal
      case 0x28:
        current = List.of(b);
      case 0x31:
        final e = PatchEdit(PatchDump.decode(current)!);
        final v = b[7] | (b[8] << 7);
        if (b[6] == 0) {
          e.setOn(b[5], v == 1);
        } else {
          e.setParameter(b[5], b[6] - 2, v);
        }
        current = e.frame;
    }
  }

  @override
  Future<void> close() async => _out.close();
}

void main() {
  late FakePedal pedal;
  late PedalSession s;

  setUp(() async {
    pedal = FakePedal();
    s = PedalSession(pedal);
    expect((await s.identify())?.deviceId, 0x5E);
  });

  test('reads the patch inside edit mode and leaves it again', () async {
    final p = await s.readPatch();
    expect(p?.name, 'Bourj');
    expect(pedal.editMode, isFalse);
    expect(pedal.sent.map((m) => m.length > 4 ? m[4] : -1), containsAllInOrder([0x50, 0x29, 0x51]));
  });

  test('writes are refused while locked', () async {
    await s.readPatch();
    expect(() => s.liveEdit(0, 0, 1), throwsA(isA<WriteLocked>()));
    expect(() => s.send(const SelectPatch(3)), throwsA(isA<WriteLocked>()));
    expect(pedal.sent.where((m) => Allowlist.isWrite(m)), isEmpty);
  });

  test('live edit and send patch with read-back', () async {
    await s.readPatch();
    s.writesEnabled = true;
    await s.liveEdit(4, 0, 1);
    expect(s.patch!.effects[4].isOn, isTrue);
    final e = PatchEdit(s.patch!)..setName('MyPatch')..setTempo(110);
    final back = await s.sendPatch(e);
    expect(back.name, 'MyPatch');
    expect(back.tempo, 110);
  });

  test('invalid patches never leave the device', () async {
    await s.readPatch();
    s.writesEnabled = true;
    final e = PatchEdit(s.patch!)..setParameter(2, 0, 500);
    expect(() => s.sendPatch(e), throwsA(isA<PedalError>()));
    expect(pedal.sent.where((m) => m.length > 4 && m[4] == 0x28), isEmpty);
  });
}
