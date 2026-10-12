import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:zoom_core/zoom_core.dart';

/// Where the app keeps its files (app support folder; nothing leaves the device unless the user exports it).
abstract final class AppDirs {
  static Directory? _root;

  /// On the Mac, the same folder the native app used (~/Library/Application Support/MS100BTLink), so
  /// existing patch backups, effect backups and the effect library carry over; elsewhere the app's own.
  static Future<Directory> root() async {
    if (_root != null) return _root!;
    final own = await getApplicationSupportDirectory();
    if (Platform.isMacOS) {
      final shared = Directory('${own.parent.path}/MS100BTLink');
      await shared.create(recursive: true);
      return _root = shared;
    }
    return _root = own;
  }
  static Future<Directory> sub(String name) async {
    final d = Directory('${(await root()).path}/$name');
    await d.create(recursive: true);
    return d;
  }

  static Future<Directory> patchBackups() => sub('Backups');
  static Future<Directory> effectLibrary() => sub('EffectLibrary');
  static Future<Directory> effectBackups() => sub('EffectBackups');

  static String stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }
}

/// Patch backups: one folder per backup holding `patch-NN.syx` (the raw 146-byte dump), as on the Mac.
class PatchLibrary {
  PatchLibrary(this.folder, this.patches);
  final Directory folder;
  final Map<int, PatchDump> patches;

  bool get isComplete => patches.length == Allowlist.patchSlots;
  String get date => folder.path.split(Platform.pathSeparator).last;
  static String fileName(int slot) => 'patch-${(slot + 1).toString().padLeft(2, '0')}.syx';

  static Future<PatchLibrary> save(Map<int, PatchDump> patches) async {
    final dir = Directory('${(await AppDirs.patchBackups()).path}/${AppDirs.stamp()}');
    await dir.create(recursive: true);
    for (final e in patches.entries) {
      await File('${dir.path}/${fileName(e.key)}').writeAsBytes(e.value.raw);
    }
    return PatchLibrary(dir, patches);
  }

  static Future<PatchLibrary?> latest() async {
    final dirs = (await AppDirs.patchBackups()).listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final d in dirs.reversed) {
      final lib = await load(d);
      if (lib != null) return lib;
    }
    return null;
  }

  static Future<PatchLibrary?> load(Directory dir) async {
    final out = <int, PatchDump>{};
    for (var s = 0; s < Allowlist.patchSlots; s++) {
      final f = File('${dir.path}/${fileName(s)}');
      if (!f.existsSync()) continue;
      final p = PatchDump.decode(await f.readAsBytes());
      if (p != null) out[s] = p;
    }
    return out.isEmpty ? null : PatchLibrary(dir, out);
  }
}

/// Scans a folder of .ZDL files into library entries.
Future<List<LibraryEffect>> scanEffects(Directory dir, {required String source, required bool community}) async {
  if (!dir.existsSync()) return [];
  final out = <LibraryEffect>[];
  await for (final e in dir.list(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.toUpperCase().endsWith('.ZDL')) continue;
    final name = e.path.split(Platform.pathSeparator).last;
    final item = LibraryEffect.fromFile(e.path, name, await e.readAsBytes(), source: source, community: community);
    if (item != null) out.add(item);
  }
  return out;
}

/// Writes files into a folder (for [PedalFileSystem.backup] and safety copies).
/// Names come from the pedal: anything that isn't a plain file name is refused.
FileSink folderSink(Directory dir) => (name, data) async {
      if (name.contains('/') || name.contains(r'\') || name.startsWith('.')) {
        throw FileSystemException('Refusing to save an unusual file name', name);
      }
      await dir.create(recursive: true);
      await File('${dir.path}/$name').writeAsBytes(data, flush: true);
    };
