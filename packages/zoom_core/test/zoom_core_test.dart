// Parity tests with MS100BTLink/Tests/ZoomCoreTests (same real pedal capture, same expectations).
import 'package:test/test.dart';
import 'package:zoom_core/zoom_core.dart';

/// Real 0x28 dump from an MS-100BT (patch "Bourj", read inside edit mode).
final bourj = 'F0 52 00 5E 28 02 10 00 00 06 0A 48 00 00 32 00 00 00 00 00 00 00 00 00 00 00 10 00 00 18 4C 0C 38 00 45 50 01 00 00 00 00 00 00 00 00 00 00 20 00 00 72 03 14 40 00 1F 00 43 06 00 00 00 00 00 00 00 00 60 00 28 00 4E 05 10 01 41 00 00 60 30 06 00 00 00 00 12 00 00 60 01 00 06 07 40 48 00 32 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 40 54 0F 42 00 6F 75 72 6A 20 20 20 00 20 20 00 F7'.split(' ').map((h) => int.parse(h, radix: 16)).toList();

void main() {
  group('allowlist', () {
    test('built messages are allowed', () {
      for (final id in [0x5D, 0x5E]) {
        for (final m in <Message>[const IdentityRequest(), const IdentityRequestBroadcast(), RequestCurrentPatch(id),
            RequestCurrentProgram(id), EditModeOn(id), EditModeOff(id)]) {
          expect(Allowlist.isAllowed(m.bytes), isTrue, reason: m.label);
        }
      }
    });
    test('firmware and filesystem path is blocked', () {
      for (final f in [
        [0xF0, 0x52, 0x00, 0x5E, 0x01, 0xF7], [0xF0, 0x52, 0x00, 0x5E, 0x04, 0xF7],
        [0xF0, 0x52, 0x00, 0x5E, 0x60, 0x06, 0xF7], [0xF0, 0x52, 0x00, 0x5E, 0x61, 0x05, 0xF7],
      ]) {
        expect(() => Allowlist.validate(f), throwsA(isA<AllowlistViolation>()));
      }
    });
    test('write shapes', () {
      expect(Allowlist.isAllowed(const SelectPatch(49).bytes), isTrue);
      expect(Allowlist.isAllowed(const SelectPatch(50).bytes), isFalse);
      expect(Allowlist.isAllowed([0xC1, 0x01]), isFalse);
      expect(Allowlist.isAllowed(const ParameterEdit(0x5E, 0, 0, 1).bytes), isTrue);
      expect(Allowlist.isAllowed(const ParameterEdit(0x5E, 5, 10, 4000).bytes), isTrue);
      expect(Allowlist.isAllowed(const ParameterEdit(0x5E, 6, 2, 1).bytes), isFalse);
      expect(Allowlist.isAllowed(const ParameterEdit(0x5E, 0, 1, 1).bytes), isFalse);
      expect(Allowlist.isAllowed(const ParameterEdit(0x5E, 0, 0, 2).bytes), isFalse);
      expect(Allowlist.isAllowed(const StorePatch(0x5E, 0).bytes), isTrue);
      expect(Allowlist.isAllowed(const StorePatch(0x5E, 50).bytes), isFalse);
      expect(Allowlist.isAllowed(SendPatch(bourj).bytes), isTrue);
      expect(Allowlist.isAllowed([0xF0, 0x52, 0x00, 0x58, 0x29, 0xF7]), isFalse); // MS-50G ID
    });
  });

  group('framer', () {
    test('sysex across chunks', () {
      final f = SysExFramer();
      expect(f.feed([0xF0, 0x7E, 0x00]), isEmpty);
      expect(f.feed([0x06, 0x02]), isEmpty);
      expect(f.feed([0x52, 0xF7, 0xF0]), [const SysEx([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0xF7])]);
    });
    test('running status and realtime', () {
      final f = SysExFramer();
      expect(f.feed([0xB0, 0x00, 0x01, 0x20, 0x02]),
          [const ChannelMessage([0xB0, 0x00, 0x01]), const ChannelMessage([0xB0, 0x20, 0x02])]);
      expect(f.feed([0xF0, 0x52, 0xF8, 0x00, 0xF7]), [const Realtime(0xF8), const SysEx([0xF0, 0x52, 0x00, 0xF7])]);
    });
  });

  group('identity', () {
    test('MS-100BT reply', () {
      final r = IdentityReply.decode([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0x5E, 0x00, 0x01, 0x00, 0x31, 0x2E, 0x33, 0x30, 0xF7])!;
      expect(r.deviceId, 0x5E);
      expect(r.mode, 1);
      expect(r.version, '1.30');
      expect(r.isKnownMS100BTId, isTrue);
    });
  });

  group('patch', () {
    test('decodes the real dump like the Swift core', () {
      final p = PatchDump.decode(bourj)!;
      expect(p.deviceId, 0x5E);
      expect(p.unpacked.length, 122);
      expect(p.name, 'Bourj');
      expect(p.effects.map((e) => e.effectId).toList(), [0x03000008, 0x06000008, 0x09000010, 0x07000030, 0x030000F0, 0]);
      expect(p.effects.map((e) => e.displayName).toList(), ['Booster', 'Tremolo', 'Hall', 'MonoSynth', 'Z Scream', '—']);
      expect(p.effects.map((e) => e.isOn).toList(), [false, false, false, false, false, null]);
      expect(p.effectCount, 5);
      expect(p.tempo, 126);
      expect(p.editSlot, 4);
      String params(int i) => p.effects[i].parameters.map((v) => '${v.name}=${v.text}').join(' ');
      expect(params(1), 'Depth=98 Rate=46 Level=139 Wave=TRI 1');
      expect(params(2), 'Decay=28 Tone=5 Mix=63 PreD=49 Level=100 Tail=OFF');
      expect(params(3), 'Synth=46 Dry=100 Level=130 Wave=Sine Tone=6 Speed=99');
      expect(p.validationProblem, isNull);
    });
    test('round trip is byte exact', () {
      final p = PatchDump.decode(bourj)!;
      expect(pack7(p.unpacked), bourj.sublist(5, 145));
      expect(PatchEdit(p).frame, bourj);
    });
    test('edits', () {
      final e = PatchEdit(PatchDump.decode(bourj)!)
        ..setName('Test 1')
        ..setTempo(100)
        ..setOn(1, true)
        ..setParameter(2, 0, 0)
        ..setEffect(5, 0x09000010)
        ..setEditSlot(2);
      final d = e.decoded!;
      expect(d.name, 'Test 1');
      expect(d.tempo, 100);
      expect(d.effects[1].isOn, isTrue);
      expect(d.effects[2].parameters[0].text, '1');
      expect(d.effects[5].displayName, 'Hall');
      expect(d.effectCount, 6);
      expect(d.editSlot, 2);
      expect(d.validationProblem, isNull);
      e.setEffect(5, 0);
      e.setEffect(4, 0);
      expect(e.decoded!.effects[4].raw, [0x01, ...List.filled(17, 0)]);
      expect(e.decoded!.effectCount, 4);
    });
    test('effect toggle bit (verified on the pedal)', () {
      final after = List.of(bourj)..[88] |= 0x01;
      final p = PatchDump.decode(after)!;
      expect(p.effects.map((e) => e.isOn).toList(), [false, false, false, false, true, null]);
    });
    test('invalid patches are refused', () {
      final e = PatchEdit(PatchDump.decode(bourj)!)..setParameter(2, 0, 500);
      expect(Allowlist.isAllowed(e.frame), isFalse);
    });
  });

  group('catalog', () {
    test('same data as the Swift catalog', () {
      expect(EffectCatalog.effects.length, 226);
      expect(EffectCatalog.ms100btEffectIds.length, 100);
      final time = EffectCatalog.effect(0x08000008)!.parameters.first;
      expect(time.name, 'Time');
      expect(time.display(0), '1');
      expect(time.display(99999), isNull);
      expect(EffectCatalog.category(0x09000010), 'Reverb');
    });
  });
}
