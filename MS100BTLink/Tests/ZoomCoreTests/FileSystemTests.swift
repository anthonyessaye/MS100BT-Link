import XCTest
@testable import ZoomCore

final class FSCodecTests: XCTestCase {
    func testCRC32MatchesZlib() {
        XCTAssertEqual(FSCodec.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(FSCodec.crc32([UInt8]()), 0)
    }

    func testSevenBitInts() {
        for v: UInt32 in [0, 1, 127, 128, 4096, 0xFFFF_FFFA, 0xFFFF_FFFF] {
            XCTAssertEqual(FSCodec.u35(FSCodec.u7x5(v), 0), v)
            XCTAssertTrue(FSCodec.u7x5(v).allSatisfy { $0 < 0x80 })
        }
        XCTAssertEqual(FSCodec.u7x5(0xFFFF_FFFA), [0x7A, 0x7F, 0x7F, 0x7F, 0x0F]) // "not found", as seen on hardware
    }

    func testNames() {
        XCTAssertTrue(FSCodec.isSafeEffectName("Z_SYN.ZDL"))
        XCTAssertTrue(FSCodec.isSafeEffectName("MemProbe.ZDL"))
        XCTAssertFalse(FSCodec.isSafeEffectName("LongName9.ZDL"))   // 9-char base froze pedals at boot
        XCTAssertFalse(FSCodec.isSafeEffectName("PAIR.DAT"))
        XCTAssertFalse(FSCodec.isSafeEffectName("A B.ZDL"))
        XCTAssertFalse(FSCodec.isSafeEffectName(".ZDL"))
    }
}

final class FileSystemAllowlistTests: XCTestCase {
    func fs(_ body: [UInt8]) -> [UInt8] { Message.fileSystem(deviceID: 0x5E, body: body).bytes }
    func block(_ data: [UInt8], crc: UInt32? = nil, size: Int? = nil) -> [UInt8] {
        fs([0x23, 0, 0, 0, 0, 0] + FSCodec.u7x5(UInt32(size ?? data.count)) + PatchDump.pack7(data)
           + FSCodec.u7x5(crc ?? (FSCodec.crc32(data) ^ 0xFFFF_FFFF)))
    }

    func testVerifiedShapesPass() throws {
        let ok: [[UInt8]] = [
            fs([0x02]), fs([0x05, 0x00]), fs([0x09]), fs([0x27]), fs([0x29, 0, 0, 0, 0, 0]),
            fs([0x25, 0, 0, 0x2A, 0]), fs([0x26, 0, 0, 0x2A, 0]),
            fs([0x20, 0x02] + [UInt8](repeating: 0, count: 9) + Array("HALL.ZDL".utf8) + [0]),
            fs([0x20, 0x01] + [UInt8](repeating: 0, count: 9) + Array("Z_SYN.ZDL".utf8) + [0]),
            fs([0x20, 0x01] + [UInt8](repeating: 0, count: 9) + Array("FLST_SEQ.ZDT".utf8) + [0]),
            fs([0x22, 0, 0, 0, 0, 0] + FSCodec.u7x5(4096)), fs([0x21, 0x54, 0x26, 0x46, 0x28, 0x0E]),
            fs([0x24] + Array("Z_SYN.ZDL".utf8) + [0]),
            block(Array(0..<255).map(UInt8.init)), block([UInt8](repeating: 0xFF, count: 4096)),
        ]
        for f in ok { XCTAssertNoThrow(try Allowlist.validate(f), f.hex) }
        XCTAssertEqual(Allowlist.fileSystemAccess(fs([0x24] + Array("Z_SYN.ZDL".utf8) + [0])), .write)
        XCTAssertEqual(Allowlist.fileSystemAccess(fs([0x20, 0x02] + [UInt8](repeating: 0, count: 9) + Array("HALL.ZDL".utf8) + [0])), .read)
        XCTAssertNil(Allowlist.fileSystemAccess(Message.requestCurrentPatch(deviceID: 0x5E).bytes))
    }

    func testEverythingElseIsRefused() {
        let bad: [(String, [UInt8])] = [
            ("updater FS prepare", fs([0x06])),
            ("BT module", [0xF0, 0x52, 0x00, 0x5E, 0x61, 0x05, 0xF7]),
            ("flash begin", [0xF0, 0x52, 0x00, 0x5E, 0x01, 0xF7]),
            ("wrong listing pattern", fs([0x25, 0, 0, 0x41, 0])),
            ("bad ACK", fs([0x05, 0x01])),
            ("write PAIR.DAT", fs([0x20, 0x01] + [UInt8](repeating: 0, count: 9) + Array("PAIR.DAT".utf8) + [0])),
            ("delete PAIR.DAT", fs([0x24] + Array("PAIR.DAT".utf8) + [0])),
            ("write long name", fs([0x20, 0x01] + [UInt8](repeating: 0, count: 9) + Array("LongName9.ZDL".utf8) + [0])),
            ("write non-ZDL", fs([0x20, 0x01] + [UInt8](repeating: 0, count: 9) + Array("EVIL.BIN".utf8) + [0])),
            ("open junk mode", fs([0x20, 0x03] + [UInt8](repeating: 0, count: 9) + Array("HALL.ZDL".utf8) + [0])),
            ("name without terminator", fs([0x24] + Array("HALL.ZDL".utf8))),
            ("read too big", fs([0x22, 0, 0, 0, 0, 0] + FSCodec.u7x5(4097))),
            ("write wrong CRC", block([1, 2, 3], crc: 12345)),
            ("write size mismatch", block([1, 2, 3], size: 4)),
            ("write too big", block([UInt8](repeating: 1, count: 4097))),
            ("wrong device", [0xF0, 0x52, 0x00, 0x58, 0x60, 0x02, 0xF7]),
        ]
        for (what, f) in bad { XCTAssertThrowsError(try Allowlist.validate(f), what) }
    }
}

final class EffectFileTests: XCTestCase {
    func testZDLHeader() throws {
        let d = makeZDL(category: 0x07, id: 485, name: "DubSiren", knobs: ["Pitch", "Rate", "Level"])
        let z = try XCTUnwrap(ZDLInfo.parse(fileName: "DUBSIREN.ZDL", data: d))
        XCTAssertEqual(z.category, 0x07)
        XCTAssertEqual(z.effectID, 485)
        XCTAssertEqual(z.patchEffectID, 0x0700_01E5)
        XCTAssertEqual(z.displayName, "DubSiren")
        XCTAssertEqual(z.parameters, ["Pitch", "Rate", "Level"])
        XCTAssertEqual(z.version, "1.00")
        XCTAssertFalse(z.truncated)
        XCTAssertTrue(z.hasSafeName)
        XCTAssertTrue(ZDLInfo.parse(fileName: "X.ZDL", data: Array(d.prefix(200)))?.truncated ?? false)
        XCTAssertNil(ZDLInfo.parse(fileName: "X.ZDL", data: [UInt8](repeating: 0, count: 100)))
    }

    func testMenuRoundTripAndEdits() throws {
        let raw = makeIndex([(0x00, [""]), (0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL", "TAPEECHO.ZDL"]), (0x09, ["HALL.ZDL"])])
        var idx = try EffectIndex(data: raw)
        XCTAssertEqual(try idx.build(), raw)
        XCTAssertEqual(idx.allEffects, ["COMP.ZDL", "DELAY.ZDL", "TAPEECHO.ZDL", "HALL.ZDL"])
        XCTAssertEqual(idx.category(of: "HALL.ZDL"), 0x09)
        idx.append("SHATTER.ZDL", to: 0x08)
        idx.remove("COMP.ZDL")
        let edited = try EffectIndex(data: try idx.build())
        XCTAssertEqual(edited.categories.first { $0.id == 0x08 }?.effects, ["DELAY.ZDL", "TAPEECHO.ZDL", "SHATTER.ZDL"])
        XCTAssertNil(edited.category(of: "COMP.ZDL"))
    }

    func testMalformedMenusAreRefused() {
        var raw = makeIndex([(0x01, ["COMP.ZDL"])])
        raw[0] = 0x41 // effect record outside a category
        XCTAssertThrowsError(try EffectIndex(data: raw))
        let unclosed = Array("COMP.ZDL".utf8) // no category marker at all
        XCTAssertThrowsError(try EffectIndex(data: unclosed + [UInt8](repeating: 0, count: 13 - unclosed.count)))
        let big = EffectIndex(categories: [EffectIndex.Category(id: 1, effects: (0..<400).map { "E\($0).ZDL" })], fileSize: 4108)
        XCTAssertThrowsError(try big.build())
    }
}

final class PlanValidatorTests: XCTestCase {
    let index = try! EffectIndex(data: makeIndex([(0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x0F, [])]))
    lazy var files = [PedalFile(name: "COMP.ZDL", size: 9000), PedalFile(name: "DELAY.ZDL", size: 9000),
                      PedalFile(name: "CMN_DRV.ZDL", size: 9000), PedalFile(name: "PAIR.DAT", size: 1024),
                      PedalFile(name: EffectIndex.fileName, size: 4108)]
    lazy var installed: [String: ZDLInfo] = [
        "COMP.ZDL": ZDLInfo.parse(fileName: "COMP.ZDL", data: makeZDL(category: 0x01, id: 1, name: "Comp"))!,
        "DELAY.ZDL": ZDLInfo.parse(fileName: "DELAY.ZDL", data: makeZDL(category: 0x08, id: 1, name: "Delay"))!,
    ]

    func plan(writes: [(String, [UInt8], Bool)] = [], deletes: [String] = [], menu: [(UInt8, [String])]? = nil) -> EffectChangePlan {
        EffectChangePlan(baseIndexCRC: 0, deletes: deletes,
                         writes: writes.map { .init(name: $0.0, data: $0.1, community: $0.2) },
                         newIndex: menu.map { makeIndex($0) })
    }
    func problems(_ p: EffectChangePlan, installed: [String: ZDLInfo]? = nil, files: [PedalFile]? = nil) -> [String] {
        EffectPlanValidator.problems(p, files: files ?? self.files, index: index, installed: installed ?? self.installed)
    }

    func testGoodInstall() {
        let p = plan(writes: [("SHATTER.ZDL", makeZDL(category: 0x08, id: 452, name: "Shatter"), true)],
                     menu: [(0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL", "SHATTER.ZDL"]), (0x0F, [])])
        XCTAssertEqual(problems(p), [])
    }

    func testBackupIsRequired() {
        XCTAssertFalse(EffectPlanValidator.problems(plan(), files: files, index: index, installed: nil).isEmpty)
        XCTAssertFalse(EffectPlanValidator.problems(plan(), files: files, index: index, installed: [:]).isEmpty)
    }

    func testWrongCategoryListingIsRefused() { // this froze an MS-100BT
        let p = plan(writes: [("SHATTER.ZDL", makeZDL(category: 0x08, id: 452, name: "Shatter"), true)],
                     menu: [(0x01, ["COMP.ZDL", "SHATTER.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x0F, [])])
        XCTAssertTrue(problems(p).contains { $0.contains("froze") })
    }

    func testDanglingMenuEntryIsRefused() {
        let p = plan(deletes: ["DELAY.ZDL"], menu: [(0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x0F, [])])
        XCTAssertTrue(problems(p).contains { $0.contains("would not be on the pedal") })
        let noMenu = plan(deletes: ["DELAY.ZDL"])
        XCTAssertFalse(problems(noMenu).isEmpty)
    }

    func testProtectedAndLibrariesAreNeverTouched() {
        XCTAssertFalse(problems(plan(deletes: ["PAIR.DAT"])).isEmpty)
        XCTAssertFalse(problems(plan(deletes: ["CMN_DRV.ZDL"])).isEmpty)
        XCTAssertFalse(problems(plan(writes: [(EffectIndex.fileName, [1], false)])).isEmpty)
    }

    func testRiskyEffectsAreRefused() {
        let cases: [(String, [UInt8], Bool)] = [
            ("LONGNAME9.ZDL", makeZDL(category: 0x08, id: 500, name: "Long"), false),       // unsafe name
            ("BASSDRV.ZDL", makeZDL(category: 0x0D, id: 3, name: "BassDrive"), false),      // not shown by the menu
            ("PEDALWAH.ZDL", makeZDL(category: 0x0B, id: 3, name: "PedalWah"), false),     // needs expression pedal
            ("BIGFX.ZDL", makeZDL(category: 0x08, id: 501, name: "Big", padTo: 33_000), true), // custom too large
            ("TRUNC.ZDL", Array(makeZDL(category: 0x08, id: 502, name: "T").prefix(300)), false),
            ("JUNK.ZDL", [UInt8](repeating: 7, count: 500), false),
        ]
        for c in cases {
            XCTAssertFalse(problems(plan(writes: [c])).isEmpty, c.0)
        }
        // A stock effect above the custom limit is fine (DualRev is 42 KB and works).
        XCTAssertEqual(problems(plan(writes: [("DUAL_REV.ZDL", makeZDL(category: 0x09, id: 9, name: "DualRev", padTo: 42_339), false)],
                                     menu: [(0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x09, ["DUAL_REV.ZDL"]), (0x0F, [])])), [])
    }

    func testEffectIDClash() {
        let p = plan(writes: [("MYDLY.ZDL", makeZDL(category: 0x08, id: 1, name: "MyDelay"), true)],
                     menu: [(0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL", "MYDLY.ZDL"]), (0x0F, [])])
        XCTAssertTrue(problems(p).contains { $0.contains("effect ID") })
        // Same ID in another category is fine (IDs are per category).
        let other = plan(writes: [("MYDYN.ZDL", makeZDL(category: 0x07, id: 1, name: "MySFX"), true)],
                         menu: [(0x01, ["COMP.ZDL"]), (0x07, ["MYDYN.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x0F, [])])
        XCTAssertEqual(problems(other), [])
    }

    func testMissingSharedLibrary() {
        var z = installed["DELAY.ZDL"]!
        z = ZDLInfo(fileName: "NEEDY.ZDL", size: z.size, headerSize: z.headerSize, extendedTag: "", category: 0x03, type: 1,
                    effectID: 77, version: "1.00", truncated: false, displayName: "Needy", parameters: [],
                    imports: ["Fx_DRV_KawaOD_Bass"], exports: [], crc32: 0)
        // The validator parses write data itself, so model the import via `installed` of a staying file instead:
        var inst = installed
        inst["NEEDY.ZDL"] = z
        let p = plan(writes: [("OTHER.ZDL", makeZDL(category: 0x03, id: 78, name: "Other"), false)],
                     menu: [(0x01, ["COMP.ZDL"]), (0x03, ["OTHER.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x0F, [])])
        XCTAssertEqual(problems(p, installed: inst), []) // staying files' imports are not this plan's concern
    }

    func testFileLimit() {
        let many = (0..<199).map { PedalFile(name: "F\($0).ZDL", size: 10) } + [PedalFile(name: EffectIndex.fileName, size: 4108)]
        let p = plan(writes: [("NEW.ZDL", makeZDL(category: 0x08, id: 600, name: "New"), false)])
        XCTAssertTrue(problems(p, files: many).contains { $0.contains("at most 200") })
    }

    func testDuplicateMenuEntry() {
        let p = plan(menu: [(0x01, ["COMP.ZDL", "COMP.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x0F, [])])
        XCTAssertTrue(problems(p).contains { $0.contains("twice") })
    }
}

/// End-to-end: the real engine against the simulated pedal.
@MainActor
final class PedalFileSystemTests: XCTestCase {
    var pedal: SimulatedPedal!
    var session: PedalSession!
    var fs: PedalFileSystem!
    let menu = makeIndex([(0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x0F, [])])

    override func setUp() async throws {
        pedal = SimulatedPedal()
        pedal.files = [
            "COMP.ZDL": makeZDL(category: 0x01, id: 1, name: "Comp"),
            "DELAY.ZDL": makeZDL(category: 0x08, id: 1, name: "Delay", padTo: 9217), // 3 blocks
            "PAIR.DAT": [UInt8](repeating: 0xAB, count: 1024),
            EffectIndex.fileName: menu,
        ]
        session = PedalSession(transport: pedal, log: nil)
        session.open()
        _ = await session.identify(timeout: 1)
        XCTAssertEqual(session.deviceID, 0x5E)
        fs = PedalFileSystem(session: session)
    }

    func testGatesBlockFileAccessOutsideASession() async {
        do { _ = try await fs.listFiles(); XCTFail("listing without a file-system session must be refused") } catch {}
        XCTAssertTrue(pedal.sent.allSatisfy { Allowlist.fileSystemAccess($0) == nil })
    }

    func testReadStateAndFiles() async throws {
        await fs.begin()
        let st = try await fs.readState()
        XCTAssertEqual(Set(st.files.map(\.name)), Set(pedal.files.keys))
        XCTAssertEqual(st.files.first { $0.name == "DELAY.ZDL" }?.size, 9217)
        XCTAssertEqual(st.indexRaw, menu)
        XCTAssertEqual(st.index.allEffects, ["COMP.ZDL", "DELAY.ZDL"])
        XCTAssertEqual(st.maxWriteSize, 4096)
        let delay = try await fs.readFile("DELAY.ZDL", expectedSize: 9217)
        XCTAssertEqual(delay, pedal.files["DELAY.ZDL"])
        XCTAssertTrue(pedal.fileWrites.isEmpty, "reading must not send a single write")
    }

    func testWritesNeedBothLocks() async throws {
        await fs.begin()
        do { try await fs.deleteFile("COMP.ZDL"); XCTFail("delete must be refused while file writes are locked") } catch {}
        session.fileSystemWritesEnabled = true // still refused: editing (writesEnabled) is locked
        do { try await fs.deleteFile("COMP.ZDL"); XCTFail("delete must be refused while editing is locked") } catch {}
        XCTAssertNotNil(pedal.files["COMP.ZDL"])
        XCTAssertTrue(pedal.fileWrites.isEmpty)
    }

    func testCorruptReadIsDetected() async throws {
        await fs.begin()
        pedal.corruptNextReadCRC = true
        do { _ = try await fs.readFile("COMP.ZDL"); XCTFail("bad block CRC must fail") } catch {}
    }

    func testBackup() async throws {
        await fs.begin()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms100bt-backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let st = try await fs.readState()
        let infos = try await fs.backup(to: dir, files: st.files)
        for (n, d) in pedal.files { XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(n)), Data(d), n) }
        XCTAssertEqual(Set(infos.keys), ["COMP.ZDL", "DELAY.ZDL"])
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("MANIFEST.txt"), encoding: .utf8).contains("DELAY.ZDL 9217"))
    }

    func installPlan(_ st: PedalFileState, data: [UInt8], name: String = "SHATTER.ZDL", cat: UInt8 = 0x08) throws -> EffectChangePlan {
        var idx = st.index
        idx.append(name, to: cat)
        return EffectChangePlan(baseIndexCRC: st.indexCRC, deletes: [],
                                writes: [.init(name: name, data: data, community: true)], newIndex: try idx.build())
    }

    func testApplyInstallsAndVerifies() async throws {
        await fs.begin()
        session.writesEnabled = true
        let st = try await fs.readState()
        let shatter = makeZDL(category: 0x08, id: 452, name: "Shatter", padTo: 5770)
        let installed = try await fs.backup(to: tmp(), files: st.files)
        let plan = try installPlan(st, data: shatter)

        try await fs.apply(plan, installed: installed, backupDir: tmp(), dryRun: true)
        XCTAssertTrue(pedal.fileWrites.isEmpty, "dry run sends nothing")

        try await fs.apply(plan, installed: installed, backupDir: tmp(), dryRun: false)
        XCTAssertEqual(pedal.files["SHATTER.ZDL"], shatter)
        let newMenu = try EffectIndex(data: pedal.files[EffectIndex.fileName]!)
        XCTAssertEqual(newMenu.categories.first { $0.id == 0x08 }?.effects, ["DELAY.ZDL", "SHATTER.ZDL"])
        XCTAssertEqual(pedal.files["PAIR.DAT"], [UInt8](repeating: 0xAB, count: 1024))
        XCTAssertFalse(session.fileSystemWritesEnabled, "file writes are locked again after apply")
    }

    func testApplyAbortsIfTheMenuChanged() async throws {
        await fs.begin()
        session.writesEnabled = true
        let st = try await fs.readState()
        let installed = try await fs.backup(to: tmp(), files: st.files)
        let plan = try installPlan(st, data: makeZDL(category: 0x08, id: 452, name: "Shatter"))
        pedal.files[EffectIndex.fileName] = makeIndex([(0x01, ["COMP.ZDL"]), (0x08, ["DELAY.ZDL"]), (0x09, []), (0x0F, [])])
        do { try await fs.apply(plan, installed: installed, backupDir: tmp(), dryRun: false); XCTFail("must abort") } catch {}
        XCTAssertNil(pedal.files["SHATTER.ZDL"])
        XCTAssertTrue(pedal.fileWrites.isEmpty)
    }

    func testRemovalSavesACopyFirst() async throws {
        await fs.begin()
        session.writesEnabled = true
        let st = try await fs.readState()
        let installed = try await fs.backup(to: tmp(), files: st.files)
        var idx = st.index
        idx.remove("COMP.ZDL")
        let dir = tmp()
        let plan = EffectChangePlan(baseIndexCRC: st.indexCRC, deletes: ["COMP.ZDL"], writes: [], newIndex: try idx.build())
        let comp = pedal.files["COMP.ZDL"]
        try await fs.apply(plan, installed: installed, backupDir: dir, dryRun: false)
        XCTAssertNil(pedal.files["COMP.ZDL"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("COMP.ZDL")), Data(comp!))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(EffectIndex.fileName)), Data(menu))
    }

    func testFailedMenuWriteRestoresTheOldMenu() async throws {
        await fs.begin()
        session.writesEnabled = true
        let st = try await fs.readState()
        let installed = try await fs.backup(to: tmp(), files: st.files)
        let plan = try installPlan(st, data: makeZDL(category: 0x08, id: 452, name: "Shatter"))
        pedal.failWritesFor[EffectIndex.fileName] = 1 // the new menu's first block is rejected
        do { try await fs.apply(plan, installed: installed, backupDir: tmp(), dryRun: false); XCTFail("must report the failure") }
        catch { XCTAssertTrue("\(error)".contains("restored"), "\(error)") }
        XCTAssertEqual(pedal.files[EffectIndex.fileName], menu, "the pedal is left with its previous menu")
    }

    func testFullPedalRejectsTheWrite() async throws {
        await fs.begin()
        session.writesEnabled = true
        session.fileSystemWritesEnabled = true
        pedal.maxFiles = pedal.files.count // simulate the 200-file limit
        do { try await fs.writeFile("NEW.ZDL", makeZDL(category: 0x08, id: 9, name: "New")); XCTFail("must fail") } catch {}
        XCTAssertNil(pedal.files["NEW.ZDL"], "no partial file is left behind")
    }

    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ms100bt-test-\(UUID())") }
}

final class InstalledEffectNamingTests: XCTestCase {
    func testCustomEffectGetsItsNameFromThePedalFile() throws {
        let bourj = DecoderTests().bourj
        var e = PatchEdit(try XCTUnwrap(PatchDump.decode(bourj)))
        let custom = try XCTUnwrap(ZDLInfo.parse(fileName: "SHATTER.ZDL", data: makeZDL(category: 0x08, id: 452, name: "Shatter",
                                                                                          knobs: ["Time", "Grain", "Mix"])))
        // A patch slot holding the custom effect (as the pedal would store it).
        var block = Array(e.unpacked[0..<18])
        PatchDump.setBits(&block, from: 1, width: 28, value: Int(custom.patchEffectID))
        e = PatchEdit(PatchDump.decode([0xF0, 0x52, 0x00, 0x5E, 0x28] + PatchDump.pack7(block + Array(e.unpacked[18...])) + [0xF7])!)
        let before = try XCTUnwrap(e.decoded)
        XCTAssertEqual(before.effects[0].displayName, String(format: "unknown %08X", custom.patchEffectID))
        XCTAssertNotNil(before.validationProblem, "an unknown effect is never sent")

        EffectCatalog.register([custom])
        defer { EffectCatalog.installed = [:] }
        let after = try XCTUnwrap(e.decoded)
        XCTAssertEqual(after.effects[0].displayName, "Shatter")
        XCTAssertEqual(after.effects[0].category, "Delay")
        XCTAssertEqual(after.effects[0].parameters.map(\.name), ["Time", "Grain", "Mix"])
        XCTAssertNil(after.validationProblem, "known from the pedal's own file: may be edited and re-sent")
    }
}
