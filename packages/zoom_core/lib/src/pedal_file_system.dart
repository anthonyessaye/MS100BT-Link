// Port of PedalFileSystem.swift: the pedal's file system (effects and effect menu) over SysEx 0x60.
// Protocol and engine logic from lopezchau/zoom-ms100bt-bluetooth (MIT, (c) 2026 lopezchau); every operation
// was verified there on an MS-100BT, firmware 1.30. Firmware commands stay blocked by the allowlist.

import 'effect_files.dart';
import 'messages.dart';
import 'patch_dump.dart';
import 'session.dart';

class PedalFile {
  const PedalFile(this.name, this.size);
  final String name;
  final int size;
}

/// Snapshot of the pedal's file system.
class PedalFileState {
  PedalFileState({required this.maxWriteSize, required this.totalBytes, required this.freeBytes, required this.files,
      required this.index, required this.indexRaw});
  final int maxWriteSize, totalBytes, freeBytes;
  final List<PedalFile> files;
  final EffectIndex index;
  final List<int> indexRaw;
  int get indexCrc => FSCodec.crc32(indexRaw);
}

class PlannedWrite {
  const PlannedWrite(this.name, this.data, {required this.community});
  final String name;
  final List<int> data;

  /// Community-built effect (stricter size limit).
  final bool community;
}

/// A change computed by the app: delete some effects, write some, and (usually) a new effect menu.
class EffectChangePlan {
  const EffectChangePlan({required this.baseIndexCrc, this.deletes = const [], this.writes = const [], this.newIndex});

  /// CRC of the menu the plan was computed from; apply aborts if the pedal's menu changed since.
  final int baseIndexCrc;
  final List<String> deletes;
  final List<PlannedWrite> writes;
  final List<int>? newIndex;
}

/// Every safety rule for effect changes, as a pure function (tested without a pedal).
abstract final class EffectPlanValidator {
  static const maxFiles = 200;

  /// [installed]: header info of the pedal's effect files (from a full backup); required.
  /// Returns problems; empty means the plan may run.
  static List<String> problems(EffectChangePlan plan,
      {required List<PedalFile> files, required EffectIndex index, required Map<String, ZDLInfo>? installed}) {
    final p = <String>[];
    final names = files.map((f) => f.name).toSet();
    if (installed == null || installed.isEmpty) {
      return ['Back up every file on the pedal first: the backup is the safety net, and it is needed to check effect IDs and shared libraries.'];
    }

    for (final n in [...plan.deletes, ...plan.writes.map((w) => w.name)]) {
      if (Allowlist.protectedFiles.contains(n.toUpperCase())) p.add('$n is protected and is never changed.');
      if (n == EffectIndex.fileName) p.add("The effect menu is only changed through the plan's new menu.");
    }
    for (final w in plan.writes) {
      if (!FSCodec.isSafeEffectName(w.name)) p.add('${w.name}: only 8.3 .ZDL names are allowed (longer names have frozen pedals at boot).');
    }
    for (final d in plan.deletes) {
      if (d.toUpperCase().startsWith('CMN_')) p.add('$d is a shared library other effects need; it is never deleted.');
    }
    if (plan.writes.map((w) => w.name).toSet().length != plan.writes.length) p.add('The plan writes the same file twice.');

    final writeInfos = <String, ZDLInfo>{};
    for (final w in plan.writes) {
      final z = ZDLInfo.parse(w.name, w.data);
      if (z == null) {
        p.add('${w.name} is not a valid effect file.');
        continue;
      }
      writeInfos[w.name] = z;
      if (z.truncated) p.add('${w.name} is truncated.');
      if (z.category == 0x0B) p.add('${z.displayName} needs an expression pedal, which the MS-100BT does not have.');
      if (z.extendedTag == 'BCAB') p.add('${z.displayName} uses the BCAB header, never tried on an MS-100BT.');
      if (!z.isSharedLibrary && !ZDLCategory.shownOnMS100BT.contains(z.category)) {
        p.add('${z.displayName} is a ${ZDLCategory.name(z.category)} effect, which the MS-100BT menu never shows.');
      }
      if (w.community && z.size > ZDLInfo.customSizeLimit) {
        p.add('${z.displayName} is ${z.size} bytes; custom effects above ${ZDLInfo.customSizeLimit} bytes have frozen pedals.');
      }
    }

    final after = names.difference(plan.deletes.toSet()).union(plan.writes.map((w) => w.name).toSet());
    if (after.length > maxFiles) p.add('The pedal holds at most $maxFiles files; this change needs ${after.length}.');

    final staying = {for (final e in installed.entries) if (after.contains(e.key) && !writeInfos.containsKey(e.key)) e.key: e.value};
    for (final MapEntry(key: n, value: z) in writeInfos.entries) {
      if (z.isSharedLibrary || z.effectId == 0) continue;
      bool same(ZDLInfo o) => o.category == z.category && o.effectId == z.effectId && !o.isSharedLibrary;
      final clash = staying.entries.where((e) => same(e.value)).firstOrNull;
      if (clash != null) {
        p.add('${z.displayName} ($n) uses effect ID ${z.effectId} in ${ZDLCategory.name(z.category)}, already used by ${clash.value.displayName} (${clash.key}).');
      }
      final other = writeInfos.entries.where((e) => e.key != n && same(e.value)).firstOrNull;
      if (other != null) p.add('$n and ${other.key} use the same effect ID.');
    }
    final exports = {...staying.values.expand((z) => z.exports), ...writeInfos.values.expand((z) => z.exports)};
    for (final MapEntry(key: n, value: z) in writeInfos.entries) {
      final missing = z.imports.where((i) => !exports.contains(i)).toList();
      if (missing.isNotEmpty) p.add('$n needs ${missing.join(', ')}, which no file on the pedal or in this change provides.');
    }

    final raw = plan.newIndex;
    if (raw != null) {
      try {
        final idx = EffectIndex.parse(raw);
        if (idx.fileSize != index.fileSize) p.add("The new menu has a different size from the pedal's.");
        final listed = idx.allEffects;
        if (listed.toSet().length != listed.length) p.add('The new menu lists an effect twice.');
        for (final n in listed) {
          if (!after.contains(n)) p.add('The new menu lists $n, which would not be on the pedal.');
        }
        for (final c in idx.categories) {
          for (final n in c.effects.where((e) => e.isNotEmpty)) {
            final z = writeInfos[n] ?? installed[n];
            if (z == null) continue;
            if (z.isSharedLibrary) {
              p.add('$n is a shared library and must not be listed in the menu.');
            } else if (z.category != c.id) {
              p.add('$n is a category ${_h(z.category)} effect but would be listed under ${_h(c.id)}; that froze an MS-100BT.');
            }
          }
        }
      } catch (e) {
        p.add('The new menu is invalid: $e');
      }
    } else if (plan.deletes.any(index.allEffects.contains)) {
      p.add('Deleting a listed effect needs a new menu without it.');
    }
    return p;
  }

  static String _h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
}

class FSError implements Exception {
  FSError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Saves one file somewhere safe (a backup folder on disk, memory in tests).
typedef FileSink = Future<void> Function(String name, List<int> data);

/// File-system operations on a connected pedal, everything through [PedalSession.send]
/// (so through the allowlist and the session's file-system gates).
class PedalFileSystem {
  PedalFileSystem(this.session, {this.log = _noLog, this.timeScale = 1});

  final PedalSession session;
  final void Function(String) log;

  /// Scales every timeout (tests use a small value with the simulator).
  final double timeScale;

  /// 0xFFFFFFFA: "not found / end of list".
  static const notFound = 0xFFFFFFFA;

  static void _noLog(String _) {}

  /// Opens a file-system session: leaves edit mode (file operations run in normal mode, as verified).
  Future<void> begin() async {
    await session.leaveEditMode();
    session.fileSystemEnabled = true;
  }

  void end() {
    session.fileSystemWritesEnabled = false;
    session.fileSystemEnabled = false;
  }

  // Low level

  static bool isFS(List<int> m, int sub, [int? fn]) => m.length >= 7 && m[4] == 0x60 && m[5] == sub && (fn == null || m[6] == fn);
  static bool isStatus(List<int> m) => isFS(m, 0x03);
  static int? statusValue(List<int> m) => isStatus(m) ? FSCodec.u35(m, 6) : null;
  static bool _ok(List<int> m) => statusValue(m) == 0;

  Future<List<List<int>>> transact(List<int> body, {double seconds = 4, required bool Function(List<int>) until}) async {
    final id = session.deviceId;
    if (id == null) throw FSError('No device ID yet (identify first).');
    session.fileSystemInbox.clear();
    await session.send(FileSystemMessage(id, body));
    final deadline = DateTime.now().add(Duration(microseconds: (seconds * timeScale * 1e6).round()));
    while (!session.fileSystemInbox.any(until) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return List.of(session.fileSystemInbox);
  }

  Future<void> ack() async {
    final r = await transact(const [0x05, 0x00], until: isStatus);
    if (!r.any(isStatus)) throw FSError('No reply from the pedal: ACK.');
  }

  Future<void> close(List<int> handle) async {
    try {
      await transact([0x21, ...handle], seconds: 3, until: isStatus);
      await transact(const [0x09], seconds: 2, until: (_) => true);
    } catch (_) {}
  }

  static String _hexHead(List<int> m) => hex(m.take(16));

  // Reads

  Future<int> maxWriteSize() async {
    final r = await transact(const [0x02], until: (m) => isFS(m, 0x04, 0x02) || isStatus(m));
    await ack();
    final m = r.where((m) => isFS(m, 0x04, 0x02)).firstOrNull;
    final v = m == null ? null : FSCodec.u35(m, 20);
    if (v == null || v <= 0) return 4096;
    return v < Allowlist.maxFileBlock ? v : Allowlist.maxFileBlock;
  }

  Future<(int total, int free)> diskUsage() async {
    final r = await transact(const [0x29, 0, 0, 0, 0, 0], until: (m) => isFS(m, 0x04) || isStatus(m));
    final m = r.where((m) => isFS(m, 0x04)).firstOrNull;
    final t = m == null ? null : FSCodec.u35(m, 11), f = m == null ? null : FSCodec.u35(m, 16);
    if (t == null || f == null) throw FSError('No reply from the pedal: disk usage.');
    return (t, f);
  }

  Future<List<PedalFile>> listFiles({void Function(int)? progress}) async {
    final files = <PedalFile>[];
    var op = 0x25, retries = 0;
    while (files.length < EffectPlanValidator.maxFiles + 20) {
      final r = await transact([op, 0x00, 0x00, 0x2A, 0x00], seconds: 3, until: (m) => isFS(m, 0x04) || isStatus(m));
      final m = r.where((m) => isFS(m, 0x04) && m.length > 35).firstOrNull;
      if (m == null) {
        // Only an explicit "end of list" ends the listing; a truncated list would defeat the
        // file-limit check and the pre-delete backup, so a missing reply is retried, then fails.
        if (r.any((m) => statusValue(m) == notFound)) break;
        if (++retries > 3) throw FSError('No reply from the pedal: file listing after ${files.length} files.');
        continue;
      }
      op = 0x26;
      retries = 0;
      final name = String.fromCharCodes(m.sublist(15, 27).takeWhile((b) => b != 0)); // 12-byte field
      if (name.isEmpty || files.any((f) => f.name == name)) break;
      files.add(PedalFile(name, FSCodec.u35(m, 30) ?? 0));
      progress?.call(files.length);
    }
    await transact(const [0x27], seconds: 2, until: isStatus);
    return files;
  }

  Future<List<int>> readFile(String name, {int? expectedSize, int chunk = 4096}) async {
    final r = await transact([0x20, 0x02, ...List.filled(9, 0), ...name.codeUnits, 0x00],
        until: (m) => isFS(m, 0x04, 0x20) || isStatus(m));
    final om = r.where((m) => isFS(m, 0x04, 0x20) && m.length > 16).firstOrNull;
    if (om == null) throw FSError('No reply from the pedal: open $name for reading.');
    final handle = om.sublist(11, 16);
    await ack();

    // Observed: read → short reply; ACK → data message (byte 7 = 01); ACK → status.
    bool isData(List<int> m) => isFS(m, 0x04, 0x22) && m.length >= 17 && m[7] == 0x01;
    final data = <int>[];
    try {
      for (var i = 0; i < 10000; i++) {
        final r1 = await transact([0x22, ...handle, ...FSCodec.u7x5(chunk)], until: (m) => isFS(m, 0x04, 0x22) || isStatus(m));
        var m = r1.where(isData).firstOrNull;
        m ??= (await transact(const [0x05, 0x00], until: (m) => isData(m) || isStatus(m))).where(isData).firstOrNull;
        if (m == null) {
          if (data.isEmpty || (expectedSize != null && data.length < expectedSize)) {
            throw FSError('No reply from the pedal: read $name at ${data.length}.');
          }
          break;
        }
        final length = m[9] | (m[10] << 7);
        await ack();
        if (length == 0) break;
        final block = unpack7(m.sublist(11, m.length - 6)).take(length).toList();
        if (block.length != length || ((FSCodec.u35(m, m.length - 6) ?? 0) ^ 0xFFFFFFFF) != FSCodec.crc32(block)) {
          throw FSError('The pedal rejected block checksum of $name: ${_hexHead(m)}.');
        }
        data.addAll(block);
        if (expectedSize != null && data.length >= expectedSize) break;
        if (length < chunk) break;
      }
    } catch (_) {
      await close(handle);
      rethrow;
    }
    await close(handle);
    if (expectedSize != null && data.length != expectedSize) {
      throw FSError('Verification failed for $name (${data.length} of $expectedSize bytes).');
    }
    return data;
  }

  // Writes (need session.fileSystemWritesEnabled and session.writesEnabled)

  /// Deletes a file. Returns false if it did not exist.
  Future<bool> deleteFile(String name) async {
    final r = await transact([0x24, ...name.codeUnits, 0x00], until: isStatus);
    final m = r.where(isStatus).firstOrNull;
    final v = m == null ? null : statusValue(m);
    if (v == null) throw FSError('No reply from the pedal: delete $name.');
    if (v == notFound) return false;
    if (v != 0) throw FSError('The pedal rejected delete $name: ${_hexHead(m!)}.');
    return true;
  }

  /// delete → open for writing → [write block → ACK]… → close → read back and compare.
  Future<void> writeFile(String name, List<int> data, {int chunk = 4096, void Function(int, int)? progress}) async {
    await deleteFile(name);
    final r1 = await transact([0x20, 0x01, ...List.filled(9, 0), ...name.codeUnits, 0x00],
        until: (m) => isFS(m, 0x04, 0x20) || isStatus(m));
    final om = r1.where((m) => isFS(m, 0x04, 0x20) && m.length > 16).firstOrNull;
    if (om == null) throw FSError('No reply from the pedal: open $name for writing.');
    final handle = om.sublist(11, 16); // not always 00×5: use what the pedal returns
    await ack();
    try {
      var off = 0;
      while (off < data.length) {
        final n = chunk < data.length - off ? chunk : data.length - off;
        final block = data.sublist(off, off + n);
        final body = [0x23, ...handle, ...FSCodec.u7x5(n), ...pack7(block), ...FSCodec.u7x5(FSCodec.crc32(block) ^ 0xFFFFFFFF)];
        final rw = await transact(body, seconds: 6, until: (m) => isFS(m, 0x04, 0x23) || isStatus(m) || isFS(m, 0x05));
        if (rw.isEmpty) throw FSError('No reply from the pedal: write block at $off of $name.');
        final e = rw.where((m) => isStatus(m) && !_ok(m)).firstOrNull;
        if (e != null) throw FSError('The pedal rejected write of $name at $off: ${_hexHead(e)}.');
        final ra = await transact(const [0x05, 0x00], until: (m) => isStatus(m) || isFS(m, 0x04, 0x23));
        final ea = ra.where((m) => isStatus(m) && !_ok(m)).firstOrNull;
        if (ea != null) throw FSError('The pedal rejected ACK of $name at $off: ${_hexHead(ea)}.');
        off += n;
        progress?.call(off, data.length);
      }
    } catch (_) {
      await close(handle);
      rethrow;
    }
    await close(handle);
    final back = await readFile(name, expectedSize: data.length);
    for (var i = 0; i < data.length; i++) {
      if (back[i] != data[i]) throw FSError('Verification failed for $name: what was read back differs from what was written.');
    }
  }

  // High level

  Future<PedalFileState> readState({void Function(String)? progress}) async {
    progress?.call('Reading file-system info');
    final maxWrite = await maxWriteSize();
    final (total, free) = await diskUsage();
    progress?.call('Listing files');
    final files = await listFiles(progress: (n) => progress?.call('Listing files ($n)'));
    progress?.call('Reading the effect menu');
    final size = files.where((f) => f.name == EffectIndex.fileName).firstOrNull?.size;
    final raw = await readFile(EffectIndex.fileName, expectedSize: size);
    return PedalFileState(maxWriteSize: maxWrite, totalBytes: total, freeBytes: free, files: files,
        index: EffectIndex.parse(raw), indexRaw: raw);
  }

  /// Read-only copy of every file into [save], plus MANIFEST.txt (name size crc32). Returns effect headers.
  Future<Map<String, ZDLInfo>> backup(List<PedalFile> files, FileSink save, {void Function(int, int, String)? progress}) async {
    final manifest = StringBuffer('# name size crc32\n');
    final infos = <String, ZDLInfo>{};
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      progress?.call(i, files.length, f.name);
      final d = await readFile(f.name, expectedSize: f.size > 0 ? f.size : null);
      await save(f.name, d);
      manifest.writeln('${f.name} ${d.length} ${FSCodec.crc32(d).toRadixString(16).padLeft(8, '0')}');
      final z = ZDLInfo.parse(f.name, d);
      if (z != null) infos[f.name] = z;
    }
    await save('MANIFEST.txt', manifest.toString().codeUnits);
    progress?.call(files.length, files.length, 'done');
    return infos;
  }

  /// Re-checks the pedal, validates the plan, saves copies of everything it will change (via [saveCopy]),
  /// then deletes, writes (each read back) and writes the new menu (read back). If the menu write fails,
  /// the old menu is written back.
  Future<void> apply(EffectChangePlan plan,
      {required Map<String, ZDLInfo>? installed, required FileSink saveCopy, bool dryRun = false,
      void Function(String, int, int)? progress}) async {
    final files = await listFiles();
    final indexSize = files.where((f) => f.name == EffectIndex.fileName).firstOrNull?.size;
    final oldIndex = await readFile(EffectIndex.fileName, expectedSize: indexSize);
    if (FSCodec.crc32(oldIndex) != plan.baseIndexCrc) {
      throw FSError("Refused: the pedal's effect menu changed since it was read; read the pedal again");
    }
    final problems = EffectPlanValidator.problems(plan, files: files, index: EffectIndex.parse(oldIndex), installed: installed);
    if (problems.isNotEmpty) throw FSError('Refused: ${problems.join(' ')}');
    log('Plan OK: delete ${plan.deletes.length}, write ${plan.writes.length}, menu ${plan.newIndex == null ? 'unchanged' : 'updated'}');
    if (dryRun) {
      log('Dry run: nothing was sent.');
      return;
    }

    // Safety copies: the old menu and every file that will be deleted or overwritten. Never delete without a copy.
    await saveCopy(EffectIndex.fileName, oldIndex);
    final names = files.map((f) => f.name).toSet();
    final toCopy = {...plan.deletes, ...plan.writes.map((w) => w.name).where(names.contains)}.toList()..sort();
    for (final n in toCopy) {
      final d = await readFile(n, expectedSize: files.where((f) => f.name == n).firstOrNull?.size);
      await saveCopy(n, d);
    }

    session.fileSystemWritesEnabled = true;
    try {
      final steps = plan.deletes.length + plan.writes.length + (plan.newIndex == null ? 0 : 1);
      var step = 0;
      for (final n in plan.deletes) {
        progress?.call('Deleting $n', ++step, steps);
        await deleteFile(n);
      }
      for (final w in plan.writes) {
        progress?.call('Writing ${w.name}', ++step, steps);
        await writeFile(w.name, w.data);
        log('Verified ${w.name} (${w.data.length} bytes, CRC32 ${FSCodec.crc32(w.data).toRadixString(16).padLeft(8, '0')})');
      }
      final newIndex = plan.newIndex;
      if (newIndex != null) {
        progress?.call('Writing the effect menu', ++step, steps);
        try {
          await writeFile(EffectIndex.fileName, newIndex);
        } catch (e) {
          log('Menu write failed ($e); restoring the previous menu');
          var restored = false;
          for (var i = 0; i < 3 && !restored; i++) {
            try {
              await writeFile(EffectIndex.fileName, oldIndex);
              restored = true;
            } catch (_) {}
          }
          throw FSError('Refused: writing the new menu failed ($e); ${restored ? 'the previous menu was restored.' : 'restoring the previous menu ALSO failed: keep the pedal on and retry; a copy was saved with the backup.'}');
        }
      }
      progress?.call('All changes applied and verified', steps, steps);
    } finally {
      session.fileSystemWritesEnabled = false;
    }
  }
}
