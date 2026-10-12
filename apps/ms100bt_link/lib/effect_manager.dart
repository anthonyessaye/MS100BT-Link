import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zoom_core/zoom_core.dart';

import 'app_model.dart';
import 'storage.dart';

/// Effects on the pedal: read its files and menu, back everything up, download library effects,
/// and install/remove effects through a validated, backed-up, read-back-verified change plan.
/// Port of the Mac app's EffectManager.
class EffectManager extends ChangeNotifier {
  EffectManager(this.link) {
    _init();
  }

  final AppModel link;

  PedalFileState? state;
  EffectIndex? draft;
  final Map<String, LibraryEffect> pendingAdds = {};
  final Set<String> pendingRemovals = {};

  /// Headers of the pedal's files (from the latest full backup).
  Map<String, ZDLInfo> installed = {};
  Directory? lastFullBackup;
  List<LibraryEffect> library = [];
  String? busy;
  double? progress;
  final List<String> log = [];
  String? alert;
  String? notice;

  Set<String> get onPedal => {...?state?.files.map((f) => f.name)};
  bool get hasChanges =>
      pendingAdds.isNotEmpty || pendingRemovals.isNotEmpty || (draft != null && state != null && !_sameMenu(draft!, state!.index));
  int? get filesAfter {
    final s = state;
    if (s == null) return null;
    return s.files.map((f) => f.name).toSet().difference(pendingRemovals).union(pendingAdds.keys.toSet()).length;
  }

  static bool _sameMenu(EffectIndex a, EffectIndex b) => listEquals(a.build(), b.build());

  void _set(void Function() f) {
    f();
    notifyListeners();
  }

  Future<void> _init() async {
    try {
      await loadLatestBackup();
      await scanLibrary();
    } catch (e) {
      log.add('Library: $e');
    }
    notifyListeners();
  }

  // Backups on disk

  Future<void> loadLatestBackup() async {
    final dirs = (await AppDirs.effectBackups()).listSync().whereType<Directory>()
        .where((d) => d.path.split(Platform.pathSeparator).last.startsWith('full-') && File('${d.path}/MANIFEST.txt').existsSync())
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (dirs.isEmpty) return;
    lastFullBackup = dirs.last;
    installed = {for (final e in await scanEffects(dirs.last, source: 'Backup', community: false)) e.pedalName: e.info};
    _syncCatalog();
  }

  Future<void> scanLibrary() async {
    final root = await AppDirs.effectLibrary();
    final items = <LibraryEffect>[
      ...await scanEffects(Directory('${root.path}/${EffectSource.stock.key}'), source: 'Stock', community: false),
      for (final s in EffectSource.communitySources)
        ...await scanEffects(Directory('${root.path}/${s.key}'), source: 'Community: ${s.owner}', community: true),
      if (lastFullBackup != null) ...await scanEffects(lastFullBackup!, source: 'My pedal backup', community: false),
    ];
    // One entry per pedal file name and content.
    final seen = <String>{};
    library = items.where((e) => seen.add('${e.pedalName}#${e.info.crc32}')).toList()
      ..sort((a, b) => a.info.category != b.info.category
          ? a.info.category.compareTo(b.info.category)
          : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    notifyListeners();
  }

  // Talking to the pedal

  /// Runs `body` in a file-system session (live updates paused, edit mode left), then hands the pedal back.
  Future<void> _withFileSystem(String title, Future<void> Function(PedalFileSystem fs) body) async {
    final session = link.session;
    if (session == null || session.deviceId == null) return _set(() => alert = 'Connect to the pedal first.');
    if (busy != null) return;
    _set(() {
      busy = title;
      progress = null;
    });
    link.pauseForFileSystem();
    final fs = PedalFileSystem(session, log: (s) => _set(() => log.add(s)));
    try {
      await fs.begin();
      await body(fs);
    } catch (e) {
      alert = '$e';
      log.add('ERROR: $e');
    } finally {
      fs.end();
      busy = null;
      progress = null;
      notifyListeners();
      await link.resumeAfterFileSystem();
    }
  }

  Future<void> readPedal() => _withFileSystem("Reading the pedal's effects…", (fs) async {
        final st = await fs.readState(progress: (s) => _set(() => busy = s));
        _adopt(st);
        log.add('Pedal: ${st.files.length}/${EffectPlanValidator.maxFiles} files, ${st.freeBytes ~/ 1024} KB free');
      });

  /// The effects the app (and the assistant) may place in patches: installed files that are in the
  /// pedal's effect menu (all installed files until the menu has been read this session).
  void _syncCatalog() {
    final listed = state?.index.allEffects.toSet();
    EffectCatalog.setInstalled([
      for (final e in installed.entries)
        if (listed == null || listed.contains(e.key)) e.value,
    ]);
  }

  void _adopt(PedalFileState st) {
    state = st;
    draft = st.index.copy();
    pendingAdds.clear();
    pendingRemovals.clear();
    _syncCatalog();
  }

  /// Copies every file on the pedal to this device (several minutes for ~175 files). Read-only.
  Future<void> backupAll() => _withFileSystem('Backing up every file on the pedal…', (fs) async {
        final st = state ?? await fs.readState();
        if (state == null) _adopt(st);
        final dir = Directory('${(await AppDirs.effectBackups()).path}/full-${AppDirs.stamp()}');
        final infos = await fs.backup(st.files, folderSink(dir), progress: (i, n, name) => _set(() {
              busy = 'Backing up $name (${i + 1}/$n)';
              progress = n > 0 ? i / n : null;
            }));
        lastFullBackup = dir;
        installed = infos;
        _syncCatalog();
        await scanLibrary();
        notice = 'Backed up ${st.files.length} files to ${dir.path}';
      });

  // Library downloads

  /// Downloads every .ZDL from a source's GitHub repository into the library folder (files stay on this device).
  Future<void> download(EffectSource source) async {
    if (busy != null) return;
    _set(() => busy = 'Listing ${source.owner}/${source.repo}…');
    final http = HttpClient()..userAgent = 'MS100BT-Link';
    try {
      final tree = await _getJson(http, Uri.parse('https://api.github.com/repos/${source.owner}/${source.repo}/git/trees/HEAD?recursive=1'));
      final files = ((tree['tree'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map((e) => (e['path'] as String? ?? '', e['type'] as String? ?? ''))
          .where((e) =>
              e.$2 == 'blob' &&
              e.$1.toUpperCase().endsWith('.ZDL') &&
              (source.folder.isEmpty || e.$1.startsWith(source.folder)) &&
              (!source.community || (!e.$1.contains('stock_zdls/') && !e.$1.contains('firmware/'))))
          .map((e) => e.$1)
          .toList();
      final dest = Directory('${(await AppDirs.effectLibrary()).path}/${source.key}');
      await dest.create(recursive: true);
      for (var i = 0; i < files.length; i++) {
        final name = files[i].split('/').last;
        _set(() {
          busy = 'Downloading $name (${i + 1}/${files.length})';
          progress = i / files.length;
        });
        if (name.contains('..') || name.isEmpty) continue;
        final target = File('${dest.path}/$name');
        if (target.existsSync()) continue;
        final bytes = await _getBytes(http, Uri.parse('https://raw.githubusercontent.com/${source.owner}/${source.repo}/HEAD/${files[i]}'));
        if (bytes != null) await target.writeAsBytes(bytes);
      }
      await File('${dest.path}/SOURCE.txt')
          .writeAsString('Source: ${source.url}\nDownloaded: ${DateTime.now()}\nNotes: ${source.note}\n');
      await scanLibrary();
      notice = 'Downloaded ${files.length} effects from ${source.label}.';
    } catch (e) {
      alert = 'Download from ${source.owner}/${source.repo} failed: $e';
    } finally {
      http.close();
      busy = null;
      progress = null;
      notifyListeners();
    }
  }

  static Future<Map<String, dynamic>> _getJson(HttpClient http, Uri url) async {
    final req = await http.getUrl(url);
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: url);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  static Future<List<int>?> _getBytes(HttpClient http, Uri url) async {
    final res = await (await http.getUrl(url)).close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final out = BytesBuilder(copy: false);
    await for (final c in res) {
      out.add(c);
    }
    return out.takeBytes();
  }

  // Online catalog: what each source offers, without downloading anything (names and sizes only)

  List<RemoteEffect> remote = [];
  DateTime? remoteAt;
  Future<void>? _remoteLoad;

  /// Loads the cached list, refreshing it from GitHub when missing or older than a week.
  Future<void> ensureRemoteCatalog({bool force = false}) => _remoteLoad ??= _loadRemote(force).whenComplete(() => _remoteLoad = null);

  Future<void> _loadRemote(bool force) async {
    final file = File('${(await AppDirs.effectLibrary()).path}/catalog.json');
    if (!force && remote.isEmpty && file.existsSync()) {
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        remoteAt = DateTime.tryParse(j['at'] as String? ?? '');
        remote = [for (final e in (j['effects'] as List)) RemoteEffect.fromJson(e as Map<String, dynamic>)];
      } catch (_) {}
    }
    if (!force && remoteAt != null && DateTime.now().difference(remoteAt!) < const Duration(days: 7)) return;
    final http = HttpClient()..userAgent = 'MS100BT-Link';
    final out = <RemoteEffect>[];
    try {
      for (final src in EffectSource.all) {
        final tree = await _getJson(http, Uri.parse('https://api.github.com/repos/${src.owner}/${src.repo}/git/trees/HEAD?recursive=1'))
            .timeout(const Duration(seconds: 15));
        for (final e in ((tree['tree'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
          final path = e['path'] as String? ?? '';
          if (e['type'] != 'blob' || !path.toUpperCase().endsWith('.ZDL')) continue;
          if (src.folder.isNotEmpty && !path.startsWith(src.folder)) continue;
          if (src.community && (path.contains('stock_zdls/') || path.contains('firmware/'))) continue;
          final (name, model) = EffectSource.pedalName(path.split('/').last);
          out.add(RemoteEffect(name, model, src.key, (e['size'] as num?)?.toInt() ?? 0));
        }
      }
      remote = out;
      remoteAt = DateTime.now();
      await file.writeAsString(jsonEncode({'at': remoteAt!.toIso8601String(), 'effects': [for (final r in out) r.toJson()]}));
    } catch (e) {
      log.add('Online effect list: $e'); // keep the cached list
    } finally {
      http.close();
      notifyListeners();
    }
  }

  // Editing the plan

  /// Adds an effect to its own category (the one in its file header; anything else froze a pedal).
  void add(LibraryEffect item) {
    final d = draft;
    if (d == null) return _set(() => alert = 'Read the pedal first.');
    final risk = item.risk(onPedal);
    if (risk.blocksInstall) return _set(() => alert = '${item.displayName}: ${risk.label}. It can\'t be installed.');
    if (risk == EffectRisk.installed && installed[item.pedalName]?.crc32 == item.info.crc32) {
      return _set(() => notice = '${item.displayName} is already on the pedal.');
    }
    if (!item.info.isSharedLibrary) d.append(item.pedalName, item.info.category);
    pendingRemovals.remove(item.pedalName);
    pendingAdds[item.pedalName] = item;
    _addDependencies(item);
    notifyListeners();
  }

  /// Adds shared libraries (e.g. CMN_BASS.ZDL) that provide symbols the effect needs.
  void _addDependencies(LibraryEffect item) {
    final available = {
      for (final e in installed.entries)
        if (onPedal.contains(e.key) && !pendingRemovals.contains(e.key)) ...e.value.exports,
      for (final a in pendingAdds.values) ...a.info.exports,
    };
    for (final sym in item.info.imports.where((s) => !available.contains(s))) {
      final providers = library.where((l) => l.info.isSharedLibrary && l.info.exports.contains(sym)).toList();
      final p = providers.where((l) => l.source == item.source).firstOrNull ?? providers.firstOrNull;
      if (p != null) {
        pendingAdds[p.pedalName] = p;
        notice = '${p.pedalName} was added too: ${item.displayName} needs it.';
      } else {
        notice = '${item.displayName} needs $sym, which no library file provides; it will be refused.';
      }
    }
  }

  void remove(String name) {
    final d = draft;
    if (d == null) return;
    if (name.toUpperCase().startsWith('CMN_')) {
      return _set(() => alert = '$name is a shared library other effects need; it can\'t be removed.');
    }
    d.remove(name);
    if (pendingAdds.remove(name) == null && onPedal.contains(name)) pendingRemovals.add(name);
    notifyListeners();
  }

  void discard() => _set(() {
        draft = state?.index.copy();
        pendingAdds.clear();
        pendingRemovals.clear();
      });

  EffectChangePlan makePlan() {
    final s = state, d = draft;
    if (s == null || d == null) throw FSError('Read the pedal first.');
    final writes = (pendingAdds.values.toList()..sort((a, b) => a.pedalName.compareTo(b.pedalName)))
        .map((e) => PlannedWrite(e.pedalName, e.data, community: e.community))
        .toList();
    return EffectChangePlan(
        baseIndexCrc: s.indexCrc,
        deletes: pendingRemovals.toList()..sort(),
        writes: writes,
        newIndex: _sameMenu(d, s.index) ? null : d.build());
  }

  /// Problems found without touching the pedal (shown before the confirmation).
  List<String> planProblems() {
    final s = state;
    if (s == null) return ['Read the pedal first.'];
    try {
      return EffectPlanValidator.problems(makePlan(), files: s.files, index: s.index, installed: installed);
    } catch (e) {
      return ['$e'];
    }
  }

  /// Dry run: re-checks the pedal and validates, sends nothing.
  Future<void> dryRun() => _withFileSystem('Checking the change…', (fs) async {
        await fs.apply(makePlan(), installed: installed, saveCopy: (_, _) async {}, dryRun: true);
        notice = 'Dry run OK: nothing was sent to the pedal.';
      });

  /// Applies the plan. Callers must have shown the risk confirmation and unlocked editing.
  Future<void> apply() async {
    if (!link.editingEnabled) return _set(() => alert = 'Unlock editing first.');
    final dir = Directory('${(await AppDirs.effectBackups()).path}/before-change-${AppDirs.stamp()}');
    await _withFileSystem('Applying effect changes…', (fs) async {
      await fs.apply(makePlan(), installed: installed, saveCopy: folderSink(dir), progress: (what, step, total) => _set(() {
            busy = what;
            progress = total > 0 ? step / total : null;
          }));
      for (final item in pendingAdds.values) {
        installed[item.pedalName] = item.info;
      }
      pendingRemovals.forEach(installed.remove);
      _syncCatalog();
      _adopt(await fs.readState());
      notice = 'All changes applied and verified. Restart the pedal to see them in its menu. '
          'Copies of everything changed are in ${dir.path}.';
    });
  }

  /// For the assistant: effects that exist online but are not downloaded, matching a query (names only).
  List<Map<String, Object>> searchNotDownloaded(String query, {int limit = 25}) {
    final q = query.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final have = {for (final l in library) l.pedalName.toUpperCase()};
    final seen = <String>{};
    final out = <Map<String, Object>>[];
    for (final r in remote) {
      if (have.contains(r.pedalName.toUpperCase()) || !seen.add('${r.pedalName}#${r.sourceKey}')) continue;
      final src = EffectSource.all.firstWhere((s) => s.key == r.sourceKey);
      final hay = '${r.pedalName} ${r.model ?? ''} ${src.label}'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (q.isNotEmpty && !hay.contains(q)) continue;
      out.add({
        'file': r.pedalName,
        if (r.model != null) 'from_pedal': r.model!,
        'source': src.label,
        'size_kb': (r.size / 1024).ceil(),
        'status': 'Not downloaded. Category, knobs and risk are known only after downloading.',
        'how_to_get': 'Effects window > Download effects > ${src.label}, then install it on the pedal',
      });
      if (out.length >= limit) break;
    }
    return out;
  }

  /// For the assistant: library effects (and what is on the pedal) matching a query.
  List<Map<String, Object>> search(String query) {
    final q = query.toLowerCase();
    return library
        .where((e) =>
            q.isEmpty ||
            e.displayName.toLowerCase().contains(q) ||
            e.category.toLowerCase().contains(q) ||
            e.info.parameters.any((p) => p.toLowerCase().contains(q)))
        .take(40)
        .map((e) {
      final r = e.risk(onPedal);
      return <String, Object>{
        'name': e.displayName, 'file': e.pedalName, 'category': e.category, 'source': e.source,
        'knobs': e.info.parameters, 'status': r.label, 'installable': !r.blocksInstall && r != EffectRisk.installed,
      };
    }).toList();
  }
}


/// An effect file a source offers online (from the repository listing; not downloaded).
class RemoteEffect {
  const RemoteEffect(this.pedalName, this.model, this.sourceKey, this.size);
  final String pedalName, sourceKey;
  final String? model; // stock files: the pedal family it comes from (e.g. MS-60B)
  final int size;

  Map<String, Object?> toJson() => {'n': pedalName, 'm': model, 's': sourceKey, 'z': size};
  static RemoteEffect fromJson(Map<String, dynamic> j) =>
      RemoteEffect(j['n'] as String, j['m'] as String?, j['s'] as String, (j['z'] as num?)?.toInt() ?? 0);
}
