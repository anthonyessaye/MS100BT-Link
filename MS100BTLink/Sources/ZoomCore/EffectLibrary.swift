// Library of effect files that can be installed on the pedal. Sources, risk labels and the MS-100BT
// findings come from lopezchau/zoom-ms100bt-bluetooth (MIT, Copyright (c) 2026 lopezchau).
// No Zoom or third-party effect file is bundled: files are downloaded from their authors on request.

import Foundation

/// Where library effects come from.
public struct EffectSource: Hashable, Sendable, Identifiable {
    public let key: String          // folder name under the library directory
    public let label: String
    public let owner: String
    public let repo: String
    public let folder: String       // only .ZDL files under this path ("" = whole repo)
    public let community: Bool
    public let note: String
    public var id: String { key }
    public var url: String { "https://github.com/\(owner)/\(repo)" }

    /// Stock effects from the MS-50G / MS-60B / MS-70CDR / G1on / B1on families (Zoom's files, hosted by repeat98).
    public static let stock = EffectSource(key: "stock", label: "Stock effects (other MultiStomps)", owner: "repeat98",
                                           repo: "ZoomMultistompZDL", folder: "stock_zdls/", community: false,
                                           note: "Zoom's own effect files from other MultiStomp pedals, hosted by repeat98.")
    public static let community: [EffectSource] = [
        EffectSource(key: "matujuice", label: "matujuice effects pack", owner: "matujuice", repo: "zoom-ms-zdl-effects-pack",
                     folder: "dist/", community: true, note: "MIT. WaveFold and DubSiren are confirmed on an MS-100BT."),
        EffectSource(key: "themanro", label: "themanro effects", owner: "themanro", repo: "ZoomMultistompZDL",
                     folder: "dist/", community: true, note: "MIT. Shatter, Galactic, Microloom and Spool are confirmed on an MS-100BT; use one of Galactic / Microloom / Spool per patch."),
        EffectSource(key: "repeat98", label: "repeat98 effects", owner: "repeat98", repo: "ZoomMultistompZDL",
                     folder: "dist/", community: true, note: "Airwindows ports. Tested on MS-70CDR."),
        EffectSource(key: "dustbox", label: "dustbox", owner: "marcfuentes", repo: "dustbox-zdl",
                     folder: "", community: true, note: "MIT. Built with the themanro toolchain."),
        EffectSource(key: "silverst", label: "silverst", owner: "marcfuentes", repo: "silverst-zdl",
                     folder: "", community: true, note: "MIT. Not hardware-measured by the author."),
    ]

    /// Stock-corpus file names carry a model prefix ("MS-60B_SVT.ZDL"); the pedal needs the bare name.
    public static let modelPrefixes = ["MS-60B", "MS-50G", "MS-70CDR", "B1Xon", "G1Xon", "B1on", "G1on"]

    public static func pedalName(for file: String) -> (name: String, model: String?) {
        for p in modelPrefixes where file.hasPrefix(p + "_") { return (String(file.dropFirst(p.count + 1)), p) }
        return (file, nil)
    }
}

public struct LibraryEffect: Identifiable, Hashable, Sendable {
    public enum Risk: Int, Comparable, Sendable {
        case installed, verified, low, community, notShown, untestedHeader, tooBig, needsExpressionPedal, unsafeName, broken
        public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .installed: return "On pedal"
            case .verified: return "Verified on an MS-100BT"
            case .low: return "Low risk"
            case .community: return "Community: untested on an MS-100BT"
            case .notShown: return "Not shown by the MS-100BT menu"
            case .untestedHeader: return "Untested header (BCAB)"
            case .tooBig: return "Too large for a custom effect"
            case .needsExpressionPedal: return "Needs an expression pedal"
            case .unsafeName: return "Name longer than 8.3"
            case .broken: return "Truncated file"
            }
        }

        /// The app refuses to install these (the plan validator enforces the same rules).
        public var blocksInstall: Bool { rawValue >= Risk.notShown.rawValue }
    }

    public let url: URL
    public let pedalName: String
    public let source: String
    public let community: Bool
    public let info: ZDLInfo
    public var id: String { url.path }
    public var displayName: String { info.displayName }
    public var category: String { ZDLCategory.name(info.category) }

    /// Effects confirmed working on an MS-100BT (lopezchau hardware log, 2026-10-08/11).
    public static let verifiedFiles: Set<String> = ["Z_SYN.ZDL", "Z_TRON.ZDL", "SPLITTER.ZDL", "ST_B_GEQ.ZDL", "DUAL_REV.ZDL"]
    public static let verifiedNames: Set<String> = ["WaveFold", "DubSiren", "Shatter", "Galactic", "Microloom", "Spool"]

    public func risk(onPedal: Set<String>) -> Risk {
        if info.truncated { return .broken }
        if !info.hasSafeName { return .unsafeName }
        if onPedal.contains(pedalName) { return .installed }
        if info.category == 0x0B { return .needsExpressionPedal }
        if info.extendedTag == "BCAB" { return .untestedHeader }
        if !ZDLCategory.shownOnMS100BT.contains(info.category) && !info.isSharedLibrary { return .notShown }
        if community && info.size > ZDLInfo.customSizeLimit { return .tooBig }
        if Self.verifiedFiles.contains(pedalName) || (community && Self.verifiedNames.contains(info.displayName)) { return .verified }
        return community ? .community : .low
    }

    /// Scans a folder of .ZDL files.
    public static func scan(folder: URL, source: String, community: Bool) -> [LibraryEffect] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [LibraryEffect] = []
        for case let url as URL in e where url.pathExtension.uppercased() == "ZDL" {
            let (name, model) = EffectSource.pedalName(for: url.lastPathComponent)
            guard name.utf8.count <= 12, let data = try? Data(contentsOf: url),
                  let info = ZDLInfo.parse(fileName: name, data: [UInt8](data)) else { continue }
            out.append(LibraryEffect(url: url, pedalName: name, source: model ?? source, community: community, info: info))
        }
        return out
    }
}
