// Port of FileSystemTests.swift: codecs, allowlist shapes, plan validator, and the engine end-to-end
// against the simulated pedal.
import 'package:test/test.dart';
import 'package:zoom_core/zoom_core.dart';

import 'simulated_pedal.dart';
import 'zoom_core_test.dart' show bourj;

List<int> fs(List<int> body) => FileSystemMessage(0x5E, body).bytes;
List<int> block(List<int> data, {int? crc, int? size}) =>
    fs([0x23, 0, 0, 0, 0, 0, ...FSCodec.u7x5(size ?? data.length), ...pack7(data), ...FSCodec.u7x5(crc ?? (FSCodec.crc32(data) ^ 0xFFFFFFFF))]);
List<int> open(int mode, String name) => fs([0x20, mode, ...List.filled(9, 0), ...name.codeUnits, 0]);

void main() {
  group('FSCodec', () {
    test('CRC-32 matches zlib', () {
      expect(FSCodec.crc32('123456789'.codeUnits), 0xCBF43926);
      expect(FSCodec.crc32(const []), 0);
    });
    test('7-bit ints', () {
      for (final v in [0, 1, 127, 128, 4096, 0xFFFFFFFA, 0xFFFFFFFF]) {
        expect(FSCodec.u35(FSCodec.u7x5(v), 0), v);
        expect(FSCodec.u7x5(v).every((b) => b < 0x80), isTrue);
      }
      expect(FSCodec.u7x5(0xFFFFFFFA), [0x7A, 0x7F, 0x7F, 0x7F, 0x0F]); // "not found", as seen on hardware
    });
    test('names', () {
      expect(FSCodec.isSafeEffectName('Z_SYN.ZDL'), isTrue);
      expect(FSCodec.isSafeEffectName('MemProbe.ZDL'), isTrue);
      expect(FSCodec.isSafeEffectName('LongName9.ZDL'), isFalse); // 9-char base froze pedals at boot
      expect(FSCodec.isSafeEffectName('PAIR.DAT'), isFalse);
      expect(FSCodec.isSafeEffectName('A B.ZDL'), isFalse);
      expect(FSCodec.isSafeEffectName('.ZDL'), isFalse);
    });
  });

  group('file-system allowlist', () {
    test('verified shapes pass', () {
      final ok = [
        fs([0x02]), fs([0x05, 0x00]), fs([0x09]), fs([0x27]), fs([0x29, 0, 0, 0, 0, 0]),
        fs([0x25, 0, 0, 0x2A, 0]), fs([0x26, 0, 0, 0x2A, 0]),
        open(2, 'HALL.ZDL'), open(1, 'Z_SYN.ZDL'), open(1, 'FLST_SEQ.ZDT'),
        fs([0x22, 0, 0, 0, 0, 0, ...FSCodec.u7x5(4096)]), fs([0x21, 0x54, 0x26, 0x46, 0x28, 0x0E]),
        fs([0x24, ...'Z_SYN.ZDL'.codeUnits, 0]),
        block(List.generate(255, (i) => i)), block(List.filled(4096, 0xFF)),
      ];
      for (final f in ok) {
        expect(() => Allowlist.validate(f), returnsNormally, reason: hex(f.take(20)));
      }
      expect(Allowlist.fileSystemAccess(fs([0x24, ...'Z_SYN.ZDL'.codeUnits, 0])), FileSystemAccess.write);
      expect(Allowlist.fileSystemAccess(open(2, 'HALL.ZDL')), FileSystemAccess.read);
      expect(Allowlist.fileSystemAccess(RequestCurrentPatch(0x5E).bytes), isNull);
    });

    test('everything else is refused', () {
      final bad = {
        'updater FS prepare': fs([0x06]),
        'BT module': [0xF0, 0x52, 0x00, 0x5E, 0x61, 0x05, 0xF7],
        'flash begin': [0xF0, 0x52, 0x00, 0x5E, 0x01, 0xF7],
        'wrong listing pattern': fs([0x25, 0, 0, 0x41, 0]),
        'bad ACK': fs([0x05, 0x01]),
        'write PAIR.DAT': open(1, 'PAIR.DAT'),
        'delete PAIR.DAT': fs([0x24, ...'PAIR.DAT'.codeUnits, 0]),
        'write long name': open(1, 'LongName9.ZDL'),
        'write non-ZDL': open(1, 'EVIL.BIN'),
        'open junk mode': open(3, 'HALL.ZDL'),
        'name without terminator': fs([0x24, ...'HALL.ZDL'.codeUnits]),
        'read too big': fs([0x22, 0, 0, 0, 0, 0, ...FSCodec.u7x5(4097)]),
        'write wrong CRC': block([1, 2, 3], crc: 12345),
        'write size mismatch': block([1, 2, 3], size: 4),
        'write too big': block(List.filled(4097, 1)),
        'wrong device': [0xF0, 0x52, 0x00, 0x58, 0x60, 0x02, 0xF7],
      };
      bad.forEach((what, f) => expect(() => Allowlist.validate(f), throwsA(isA<AllowlistViolation>()), reason: what));
    });
  });

  group('effect files', () {
    test('ZDL header', () {
      final d = makeZDL(category: 0x07, id: 485, name: 'DubSiren', knobs: ['Pitch', 'Rate', 'Level']);
      final z = ZDLInfo.parse('DUBSIREN.ZDL', d)!;
      expect(z.category, 0x07);
      expect(z.effectId, 485);
      expect(z.patchEffectId, 0x070001E5);
      expect(z.displayName, 'DubSiren');
      expect(z.parameters, ['Pitch', 'Rate', 'Level']);
      expect(z.version, '1.00');
      expect(z.truncated, isFalse);
      expect(z.hasSafeName, isTrue);
      expect(ZDLInfo.parse('X.ZDL', d.sublist(0, 200))?.truncated, isTrue);
      expect(ZDLInfo.parse('X.ZDL', List.filled(100, 0)), isNull);
    });

    test('menu round trip and edits', () {
      final raw = makeIndex([(0x00, ['']), (0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL', 'TAPEECHO.ZDL']), (0x09, ['HALL.ZDL'])]);
      final idx = EffectIndex.parse(raw);
      expect(idx.build(), raw);
      expect(idx.allEffects, ['COMP.ZDL', 'DELAY.ZDL', 'TAPEECHO.ZDL', 'HALL.ZDL']);
      expect(idx.categoryOf('HALL.ZDL'), 0x09);
      idx
        ..append('SHATTER.ZDL', 0x08)
        ..remove('COMP.ZDL');
      final edited = EffectIndex.parse(idx.build());
      expect(edited.categories.firstWhere((c) => c.id == 0x08).effects, ['DELAY.ZDL', 'TAPEECHO.ZDL', 'SHATTER.ZDL']);
      expect(edited.categoryOf('COMP.ZDL'), isNull);
    });

    test('malformed menus are refused', () {
      final raw = makeIndex([(0x01, ['COMP.ZDL'])]);
      raw[0] = 0x41;
      expect(() => EffectIndex.parse(raw), throwsA(isA<MalformedMenu>()));
      final unclosed = 'COMP.ZDL'.codeUnits;
      expect(() => EffectIndex.parse([...unclosed, ...List.filled(13 - unclosed.length, 0)]), throwsA(isA<MalformedMenu>()));
      final big = EffectIndex([EffectMenuCategory(1, [for (var i = 0; i < 400; i++) 'E$i.ZDL'])], 4108);
      expect(big.build, throwsA(isA<MalformedMenu>()));
    });

    test('library risk labels', () {
      LibraryEffect lib(String file, List<int> d, {bool community = true}) =>
          LibraryEffect.fromFile('/x/$file', file, d, source: 'test', community: community)!;
      expect(lib('MS-60B_SVT.ZDL', makeZDL(category: 0x05, id: 1, name: 'SVT'), community: false).pedalName, 'SVT.ZDL');
      expect(lib('MS-60B_SVT.ZDL', makeZDL(category: 0x05, id: 1, name: 'SVT'), community: false).risk({}), EffectRisk.notShown);
      expect(lib('SHATTER.ZDL', makeZDL(category: 0x08, id: 452, name: 'Shatter')).risk({}), EffectRisk.verified);
      expect(lib('SHATTER.ZDL', makeZDL(category: 0x08, id: 452, name: 'Shatter')).risk({'SHATTER.ZDL'}), EffectRisk.installed);
      expect(lib('NEWFX.ZDL', makeZDL(category: 0x08, id: 600, name: 'NewFx')).risk({}), EffectRisk.community);
      expect(lib('BIGFX.ZDL', makeZDL(category: 0x08, id: 601, name: 'Big', padTo: 33000)).risk({}), EffectRisk.tooBig);
      expect(lib('WAH.ZDL', makeZDL(category: 0x0B, id: 1, name: 'Wah')).risk({}).blocksInstall, isTrue);
      expect(lib('MY.FX.ZDL', makeZDL(category: 0x08, id: 9, name: 'L')).risk({}), EffectRisk.unsafeName);
      expect(LibraryEffect.fromFile('/x', 'LONGNAME9.ZDL', makeZDL(category: 0x08, id: 9, name: 'L'), source: 't', community: true),
          isNull, reason: 'does not fit the 12-byte name field');
    });
  });

  group('plan validator', () {
    final index = EffectIndex.parse(makeIndex([(0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL']), (0x0F, [])]));
    const files = [PedalFile('COMP.ZDL', 9000), PedalFile('DELAY.ZDL', 9000), PedalFile('CMN_DRV.ZDL', 9000),
      PedalFile('PAIR.DAT', 1024), PedalFile(EffectIndex.fileName, 4108)];
    final installed = {
      'COMP.ZDL': ZDLInfo.parse('COMP.ZDL', makeZDL(category: 0x01, id: 1, name: 'Comp'))!,
      'DELAY.ZDL': ZDLInfo.parse('DELAY.ZDL', makeZDL(category: 0x08, id: 1, name: 'Delay'))!,
    };
    EffectChangePlan plan({List<(String, List<int>, bool)> writes = const [], List<String> deletes = const [],
            List<(int, List<String>)>? menu}) =>
        EffectChangePlan(baseIndexCrc: 0, deletes: deletes, writes: [for (final w in writes) PlannedWrite(w.$1, w.$2, community: w.$3)],
            newIndex: menu == null ? null : makeIndex(menu));
    List<String> problems(EffectChangePlan p, {Map<String, ZDLInfo>? inst, List<PedalFile>? f}) =>
        EffectPlanValidator.problems(p, files: f ?? files, index: index, installed: inst ?? installed);

    test('good install', () {
      final p = plan(writes: [('SHATTER.ZDL', makeZDL(category: 0x08, id: 452, name: 'Shatter'), true)],
          menu: [(0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL', 'SHATTER.ZDL']), (0x0F, [])]);
      expect(problems(p), isEmpty);
    });
    test('backup is required', () {
      expect(EffectPlanValidator.problems(plan(), files: files, index: index, installed: null), isNotEmpty);
      expect(EffectPlanValidator.problems(plan(), files: files, index: index, installed: {}), isNotEmpty);
    });
    test('wrong-category listing is refused (this froze an MS-100BT)', () {
      final p = plan(writes: [('SHATTER.ZDL', makeZDL(category: 0x08, id: 452, name: 'Shatter'), true)],
          menu: [(0x01, ['COMP.ZDL', 'SHATTER.ZDL']), (0x08, ['DELAY.ZDL']), (0x0F, [])]);
      expect(problems(p).any((s) => s.contains('froze')), isTrue);
    });
    test('dangling menu entry is refused', () {
      final p = plan(deletes: ['DELAY.ZDL'], menu: [(0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL']), (0x0F, [])]);
      expect(problems(p).any((s) => s.contains('would not be on the pedal')), isTrue);
      expect(problems(plan(deletes: ['DELAY.ZDL'])), isNotEmpty);
    });
    test('protected files and libraries are never touched', () {
      expect(problems(plan(deletes: ['PAIR.DAT'])), isNotEmpty);
      expect(problems(plan(deletes: ['CMN_DRV.ZDL'])), isNotEmpty);
      expect(problems(plan(writes: [(EffectIndex.fileName, [1], false)])), isNotEmpty);
    });
    test('risky effects are refused', () {
      final cases = [
        ('LONGNAME9.ZDL', makeZDL(category: 0x08, id: 500, name: 'Long'), false),
        ('BASSDRV.ZDL', makeZDL(category: 0x0D, id: 3, name: 'BassDrive'), false),
        ('PEDALWAH.ZDL', makeZDL(category: 0x0B, id: 3, name: 'PedalWah'), false),
        ('BIGFX.ZDL', makeZDL(category: 0x08, id: 501, name: 'Big', padTo: 33000), true),
        ('TRUNC.ZDL', makeZDL(category: 0x08, id: 502, name: 'T').sublist(0, 300), false),
        ('JUNK.ZDL', List.filled(500, 7), false),
      ];
      for (final c in cases) {
        expect(problems(plan(writes: [c])), isNotEmpty, reason: c.$1);
      }
      // A stock effect above the custom limit is fine (DualRev is 42 KB and works).
      expect(
          problems(plan(writes: [('DUAL_REV.ZDL', makeZDL(category: 0x09, id: 9, name: 'DualRev', padTo: 42339), false)],
              menu: [(0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL']), (0x09, ['DUAL_REV.ZDL']), (0x0F, [])])),
          isEmpty);
    });
    test('effect-ID clash', () {
      final p = plan(writes: [('MYDLY.ZDL', makeZDL(category: 0x08, id: 1, name: 'MyDelay'), true)],
          menu: [(0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL', 'MYDLY.ZDL']), (0x0F, [])]);
      expect(problems(p).any((s) => s.contains('effect ID')), isTrue);
      final other = plan(writes: [('MYSFX.ZDL', makeZDL(category: 0x07, id: 1, name: 'MySFX'), true)],
          menu: [(0x01, ['COMP.ZDL']), (0x07, ['MYSFX.ZDL']), (0x08, ['DELAY.ZDL']), (0x0F, [])]);
      expect(problems(other), isEmpty);
    });
    test('file limit', () {
      final many = [for (var i = 0; i < 199; i++) PedalFile('F$i.ZDL', 10), const PedalFile(EffectIndex.fileName, 4108)];
      final p = plan(writes: [('NEW.ZDL', makeZDL(category: 0x08, id: 600, name: 'New'), false)]);
      expect(problems(p, f: many).any((s) => s.contains('at most 200')), isTrue);
    });
    test('duplicate menu entry', () {
      final p = plan(menu: [(0x01, ['COMP.ZDL', 'COMP.ZDL']), (0x08, ['DELAY.ZDL']), (0x0F, [])]);
      expect(problems(p).any((s) => s.contains('twice')), isTrue);
    });
  });

  group('engine against the simulated pedal', () {
    late SimulatedPedal pedal;
    late PedalSession session;
    late PedalFileSystem fsys;
    final menu = makeIndex([(0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL']), (0x0F, [])]);

    setUp(() async {
      pedal = SimulatedPedal();
      pedal.files.addAll({
        'COMP.ZDL': makeZDL(category: 0x01, id: 1, name: 'Comp'),
        'DELAY.ZDL': makeZDL(category: 0x08, id: 1, name: 'Delay', padTo: 9217), // 3 blocks
        'PAIR.DAT': List.filled(1024, 0xAB),
        EffectIndex.fileName: menu,
      });
      session = PedalSession(pedal);
      expect((await session.identify(timeout: const Duration(seconds: 1)))?.deviceId, 0x5E);
      fsys = PedalFileSystem(session, timeScale: 0.1);
    });

    Map<String, List<int>> store() => {};
    FileSink into(Map<String, List<int>> m) => (n, d) async => m[n] = List.of(d);

    Future<EffectChangePlan> installPlan(PedalFileState st, List<int> data, {String name = 'SHATTER.ZDL', int cat = 0x08}) async {
      final idx = st.index.copy()..append(name, cat);
      return EffectChangePlan(baseIndexCrc: st.indexCrc, writes: [PlannedWrite(name, data, community: true)], newIndex: idx.build());
    }

    test('gates block file access outside a session', () async {
      await expectLater(fsys.listFiles(), throwsA(isA<WriteLocked>()));
      expect(pedal.sent.every((f) => Allowlist.fileSystemAccess(f) == null), isTrue);
    });

    test('read state and files', () async {
      await fsys.begin();
      final st = await fsys.readState();
      expect(st.files.map((f) => f.name).toSet(), pedal.files.keys.toSet());
      expect(st.files.firstWhere((f) => f.name == 'DELAY.ZDL').size, 9217);
      expect(st.indexRaw, menu);
      expect(st.index.allEffects, ['COMP.ZDL', 'DELAY.ZDL']);
      expect(st.maxWriteSize, 4096);
      expect(await fsys.readFile('DELAY.ZDL', expectedSize: 9217), pedal.files['DELAY.ZDL']);
      expect(pedal.fileWrites, isEmpty, reason: 'reading must not send a single write');
    });

    test('writes need both locks', () async {
      await fsys.begin();
      await expectLater(fsys.deleteFile('COMP.ZDL'), throwsA(isA<WriteLocked>()));
      session.fileSystemWritesEnabled = true; // still refused: editing (writesEnabled) is locked
      await expectLater(fsys.deleteFile('COMP.ZDL'), throwsA(isA<WriteLocked>()));
      expect(pedal.files['COMP.ZDL'], isNotNull);
      expect(pedal.fileWrites, isEmpty);
    });

    test('corrupt read is detected', () async {
      await fsys.begin();
      pedal.corruptNextReadCrc = true;
      await expectLater(fsys.readFile('COMP.ZDL'), throwsA(isA<FSError>()));
    });

    test('lost connection fails instead of returning partial data', () async {
      await fsys.begin();
      pedal.silent = true;
      await expectLater(fsys.listFiles(), throwsA(isA<FSError>()));
    });

    test('backup', () async {
      await fsys.begin();
      final st = await fsys.readState();
      final saved = store();
      final infos = await fsys.backup(st.files, into(saved));
      pedal.files.forEach((n, d) => expect(saved[n], d, reason: n));
      expect(infos.keys.toSet(), {'COMP.ZDL', 'DELAY.ZDL'});
      expect(String.fromCharCodes(saved['MANIFEST.txt']!), contains('DELAY.ZDL 9217'));
    });

    test('apply installs and verifies', () async {
      await fsys.begin();
      session.writesEnabled = true;
      final st = await fsys.readState();
      final shatter = makeZDL(category: 0x08, id: 452, name: 'Shatter', padTo: 5770);
      final installed = await fsys.backup(st.files, into(store()));
      final p = await installPlan(st, shatter);

      await fsys.apply(p, installed: installed, saveCopy: into(store()), dryRun: true);
      expect(pedal.fileWrites, isEmpty, reason: 'dry run sends nothing');

      await fsys.apply(p, installed: installed, saveCopy: into(store()));
      expect(pedal.files['SHATTER.ZDL'], shatter);
      final newMenu = EffectIndex.parse(pedal.files[EffectIndex.fileName]!);
      expect(newMenu.categories.firstWhere((c) => c.id == 0x08).effects, ['DELAY.ZDL', 'SHATTER.ZDL']);
      expect(pedal.files['PAIR.DAT'], List.filled(1024, 0xAB));
      expect(session.fileSystemWritesEnabled, isFalse, reason: 'file writes are locked again after apply');
    });

    test('apply aborts if the menu changed', () async {
      await fsys.begin();
      session.writesEnabled = true;
      final st = await fsys.readState();
      final installed = await fsys.backup(st.files, into(store()));
      final p = await installPlan(st, makeZDL(category: 0x08, id: 452, name: 'Shatter'));
      pedal.files[EffectIndex.fileName] = makeIndex([(0x01, ['COMP.ZDL']), (0x08, ['DELAY.ZDL']), (0x09, []), (0x0F, [])]);
      await expectLater(fsys.apply(p, installed: installed, saveCopy: into(store())), throwsA(isA<FSError>()));
      expect(pedal.files['SHATTER.ZDL'], isNull);
      expect(pedal.fileWrites, isEmpty);
    });

    test('removal saves a copy first', () async {
      await fsys.begin();
      session.writesEnabled = true;
      final st = await fsys.readState();
      final installed = await fsys.backup(st.files, into(store()));
      final idx = st.index.copy()..remove('COMP.ZDL');
      final copies = store();
      final comp = pedal.files['COMP.ZDL'];
      await fsys.apply(EffectChangePlan(baseIndexCrc: st.indexCrc, deletes: ['COMP.ZDL'], newIndex: idx.build()),
          installed: installed, saveCopy: into(copies));
      expect(pedal.files['COMP.ZDL'], isNull);
      expect(copies['COMP.ZDL'], comp);
      expect(copies[EffectIndex.fileName], menu);
    });

    test('failed menu write restores the old menu', () async {
      await fsys.begin();
      session.writesEnabled = true;
      final st = await fsys.readState();
      final installed = await fsys.backup(st.files, into(store()));
      final p = await installPlan(st, makeZDL(category: 0x08, id: 452, name: 'Shatter'));
      pedal.failWritesFor[EffectIndex.fileName] = 1; // the new menu's first block is rejected
      await expectLater(fsys.apply(p, installed: installed, saveCopy: into(store())),
          throwsA(predicate((e) => '$e'.contains('restored'))));
      expect(pedal.files[EffectIndex.fileName], menu, reason: 'the pedal is left with its previous menu');
    });

    test('full pedal rejects the write', () async {
      await fsys.begin();
      session.writesEnabled = true;
      session.fileSystemWritesEnabled = true;
      pedal.maxFiles = pedal.files.length; // simulate the 200-file limit
      await expectLater(fsys.writeFile('NEW.ZDL', makeZDL(category: 0x08, id: 9, name: 'New')), throwsA(isA<FSError>()));
      expect(pedal.files['NEW.ZDL'], isNull, reason: 'no partial file is left behind');
    });
  });

  test('custom effect gets its name from the pedal file', () {
    final dump = PatchDump.decode(bourj)!;
    final custom = ZDLInfo.parse('SHATTER.ZDL', makeZDL(category: 0x08, id: 452, name: 'Shatter', knobs: ['Time', 'Grain', 'Mix']))!;
    final u = List.of(dump.unpacked);
    writeBits(u, 1, 28, custom.patchEffectId); // slot 0's block starts at byte 0
    final frame = [...bourj.sublist(0, 5), ...pack7(u), 0xF7];
    final before = PatchDump.decode(frame)!;
    expect(before.effects[0].displayName, startsWith('unknown'));
    expect(before.validationProblem, isNotNull, reason: 'an unknown effect is never sent');
    EffectCatalog.register([custom]);
    addTearDown(EffectCatalog.installed.clear);
    final after = PatchDump.decode(frame)!;
    expect(after.effects[0].displayName, 'Shatter');
    expect(after.effects[0].category, 'Delay');
    expect(after.effects[0].parameters.map((p) => p.name), ['Time', 'Grain', 'Mix']);
    expect(after.validationProblem, isNull, reason: "known from the pedal's own file: may be edited and re-sent");
  });
}
