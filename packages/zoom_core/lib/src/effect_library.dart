// Port of EffectLibrary.swift: where installable effect files come from and how risky each one is.
// Sources, risk labels and MS-100BT findings from lopezchau/zoom-ms100bt-bluetooth (MIT, (c) 2026 lopezchau).
// No Zoom or third-party effect file is bundled: files are downloaded from their authors on request.

import 'effect_files.dart';

class EffectSource {
  const EffectSource({required this.key, required this.label, required this.owner, required this.repo,
      required this.folder, required this.community, required this.note});

  final String key, label, owner, repo, note;

  /// Only .ZDL files under this path ("" = whole repo).
  final String folder;
  final bool community;
  String get url => 'https://github.com/$owner/$repo';

  /// Stock effects from the MS-50G / MS-60B / MS-70CDR / G1on / B1on families (Zoom's files, hosted by repeat98).
  static const stock = EffectSource(key: 'stock', label: 'Stock effects (other MultiStomps)', owner: 'repeat98',
      repo: 'ZoomMultistompZDL', folder: 'stock_zdls/', community: false,
      note: "Zoom's own effect files from other MultiStomp pedals, hosted by repeat98.");

  static const communitySources = [
    EffectSource(key: 'matujuice', label: 'matujuice effects pack', owner: 'matujuice', repo: 'zoom-ms-zdl-effects-pack',
        folder: 'dist/', community: true, note: 'MIT. WaveFold and DubSiren are confirmed on an MS-100BT.'),
    EffectSource(key: 'themanro', label: 'themanro effects', owner: 'themanro', repo: 'ZoomMultistompZDL',
        folder: 'dist/', community: true,
        note: 'MIT. Shatter, Galactic, Microloom and Spool are confirmed on an MS-100BT; use one of Galactic / Microloom / Spool per patch.'),
    EffectSource(key: 'repeat98', label: 'repeat98 effects', owner: 'repeat98', repo: 'ZoomMultistompZDL',
        folder: 'dist/', community: true, note: 'Airwindows ports. Tested on MS-70CDR.'),
    EffectSource(key: 'dustbox', label: 'dustbox', owner: 'marcfuentes', repo: 'dustbox-zdl',
        folder: '', community: true, note: 'MIT. Built with the themanro toolchain.'),
    EffectSource(key: 'silverst', label: 'silverst', owner: 'marcfuentes', repo: 'silverst-zdl',
        folder: '', community: true, note: 'MIT. Not hardware-measured by the author.'),
  ];

  static const all = [stock, ...communitySources];

  /// Stock-corpus file names carry a model prefix ("MS-60B_SVT.ZDL"); the pedal needs the bare name.
  static const modelPrefixes = ['MS-60B', 'MS-50G', 'MS-70CDR', 'B1Xon', 'G1Xon', 'B1on', 'G1on'];

  static (String name, String? model) pedalName(String file) {
    for (final p in modelPrefixes) {
      if (file.startsWith('${p}_')) return (file.substring(p.length + 1), p);
    }
    return (file, null);
  }
}

enum EffectRisk {
  installed('On pedal'),
  verified('Verified on an MS-100BT'),
  low('Low risk'),
  community('Community: untested on an MS-100BT'),
  notShown('Not shown by the MS-100BT menu'),
  untestedHeader('Untested header (BCAB)'),
  tooBig('Too large for a custom effect'),
  needsExpressionPedal('Needs an expression pedal'),
  unsafeName('Name longer than 8.3'),
  broken('Truncated file');

  const EffectRisk(this.label);
  final String label;

  /// The app refuses to install these (the plan validator enforces the same rules).
  bool get blocksInstall => index >= EffectRisk.notShown.index;
}

class LibraryEffect {
  const LibraryEffect({required this.path, required this.pedalName, required this.source, required this.community,
      required this.info, required this.data});

  /// Where the file lives locally (identity).
  final String path;
  final String pedalName, source;
  final bool community;
  final ZDLInfo info;
  final List<int> data;

  String get displayName => info.displayName;
  String get category => ZDLCategory.name(info.category);

  /// Effects confirmed working on an MS-100BT (lopezchau hardware log, 2026-10-08/11).
  static const verifiedFiles = {'Z_SYN.ZDL', 'Z_TRON.ZDL', 'SPLITTER.ZDL', 'ST_B_GEQ.ZDL', 'DUAL_REV.ZDL'};
  static const verifiedNames = {'WaveFold', 'DubSiren', 'Shatter', 'Galactic', 'Microloom', 'Spool'};

  /// Builds an entry from a downloaded file, or null if it isn't a usable effect file.
  static LibraryEffect? fromFile(String path, String fileName, List<int> data, {required String source, required bool community}) {
    final (name, model) = EffectSource.pedalName(fileName);
    if (name.length > 12) return null;
    final info = ZDLInfo.parse(name, data);
    if (info == null) return null;
    return LibraryEffect(path: path, pedalName: name, source: model ?? source, community: community, info: info, data: data);
  }

  EffectRisk risk(Set<String> onPedal) {
    if (info.truncated) return EffectRisk.broken;
    if (!info.hasSafeName) return EffectRisk.unsafeName;
    if (onPedal.contains(pedalName)) return EffectRisk.installed;
    if (info.category == 0x0B) return EffectRisk.needsExpressionPedal;
    if (info.extendedTag == 'BCAB') return EffectRisk.untestedHeader;
    if (!ZDLCategory.shownOnMS100BT.contains(info.category) && !info.isSharedLibrary) return EffectRisk.notShown;
    if (community && info.size > ZDLInfo.customSizeLimit) return EffectRisk.tooBig;
    if (verifiedFiles.contains(pedalName) || (community && verifiedNames.contains(info.displayName))) return EffectRisk.verified;
    return community ? EffectRisk.community : EffectRisk.low;
  }
}
