import XCTest
@testable import ZoomCore

final class AllowlistTests: XCTestCase {
    func testEveryBuiltMessageIsAllowed() throws {
        for id: UInt8 in [0x5D, 0x5E] {
            let all: [Message] = [.identityRequest, .identityRequestBroadcast,
                                  .requestCurrentProgram(deviceID: id), .requestCurrentPatch(deviceID: id),
                                  .editModeOn(deviceID: id), .editModeOff(deviceID: id)]
            for m in all { XCTAssertNoThrow(try Allowlist.validate(m.bytes), m.label) }
        }
    }

    func testUpdaterFirstMessageIsOurIdentityRequest() {
        XCTAssertEqual(Message.identityRequest.bytes, [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7])
    }

    func testForbiddenOpcodesAreBlocked() {
        for op in Allowlist.forbiddenOpcodes.keys {
            for id: UInt8 in [0x5D, 0x5E, 0x58] {
                XCTAssertThrowsError(try Allowlist.validate([0xF0, 0x52, 0x00, id, op, 0xF7]), "op \(op.hex)")
            }
        }
    }

    func testUpdaterMessagesAreBlocked() {
        let updater: [[UInt8]] = [
            [0xF0, 0x52, 0x00, 0x5E, 0x60, 0x06, 0xF7], // FS handshake
            [0xF0, 0x52, 0x00, 0x5E, 0x61, 0x05, 0xF7], // BT function
            [0xF0, 0x52, 0x00, 0x5E, 0x01, 0xF7],       // flash write begin
            [0xF0, 0x52, 0x00, 0x5E, 0x04, 0xF7],       // flash write end
        ]
        for f in updater { XCTAssertThrowsError(try Allowlist.validate(f)) }
    }

    func testUnknownOpcodesAndIDsAreBlocked() {
        XCTAssertThrowsError(try Allowlist.validate([0xF0, 0x52, 0x00, 0x5E, 0x2A, 0xF7]))   // unknown op
        XCTAssertThrowsError(try Allowlist.validate([0xF0, 0x52, 0x00, 0x58, 0x29, 0xF7]))   // MS-50G ID
        XCTAssertThrowsError(try Allowlist.validate([0xF0, 0x52, 0x00, 0x5E, 0x29, 0x00, 0xF7])) // extra byte
        XCTAssertThrowsError(try Allowlist.validate([0xC0, 0x40]))                           // patch 65 does not exist
        XCTAssertThrowsError(try Allowlist.validate([]))
    }
}

final class FramerTests: XCTestCase {
    func testSysExSplitAcrossChunks() {
        var f = SysExFramer()
        XCTAssertEqual(f.feed([0xF0, 0x7E, 0x00]), [])
        XCTAssertEqual(f.feed([0x06, 0x02]), [])
        XCTAssertEqual(f.feed([0x52, 0xF7, 0xF0]), [.sysex([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0xF7])])
    }

    func testProgramReplySequence() {
        var f = SysExFramer()
        let ev = f.feed([0xB0, 0x00, 0x00, 0xB0, 0x20, 0x00, 0xC0, 0x05])
        XCTAssertEqual(ev, [.channel([0xB0, 0x00, 0x00]), .channel([0xB0, 0x20, 0x00]), .channel([0xC0, 0x05])])
    }

    func testRunningStatus() {
        var f = SysExFramer()
        XCTAssertEqual(f.feed([0xB0, 0x00, 0x01, 0x20, 0x02]),
                       [.channel([0xB0, 0x00, 0x01]), .channel([0xB0, 0x20, 0x02])])
    }

    func testRealtimeInsideSysEx() {
        var f = SysExFramer()
        XCTAssertEqual(f.feed([0xF0, 0x52, 0xF8, 0x00, 0xF7]), [.realtime(0xF8), .sysex([0xF0, 0x52, 0x00, 0xF7])])
    }

    func testTruncatedSysExAndStrayBytes() {
        var f = SysExFramer()
        XCTAssertEqual(f.feed([0x12, 0xF7]), [.stray([0x12]), .stray([0xF7])])
        XCTAssertEqual(f.feed([0xF0, 0x52, 0xC0, 0x03]), [.stray([0xF0, 0x52]), .channel([0xC0, 0x03])])
    }
}

final class DecoderTests: XCTestCase {
    /// MS-50G identity reply as documented (device 0x58, firmware "3.00").
    let ms50gIdentity: [UInt8] = [0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0x58, 0x00, 0x00, 0x00, 0x33, 0x2E, 0x30, 0x30, 0xF7]

    func testIdentityDecode() throws {
        let r = try XCTUnwrap(IdentityReply.decode(ms50gIdentity))
        XCTAssertEqual(r.deviceID, 0x58)
        XCTAssertEqual(r.mode, 0)
        XCTAssertEqual(r.version, "3.00")
        XCTAssertFalse(r.isKnownMS100BTID)
    }

    func testIdentityDecodeMS100BTShape() throws {
        let m: [UInt8] = [0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0x5E, 0x00, 0x00, 0x00, 0x31, 0x2E, 0x33, 0x30, 0xF7]
        let r = try XCTUnwrap(IdentityReply.decode(m))
        XCTAssertEqual(r.deviceID, 0x5E)
        XCTAssertEqual(r.version, "1.30")
        XCTAssertTrue(r.isKnownMS100BTID)
        XCTAssertEqual(DecodedMessage.decode(.sysex(m)), .identity(r))
    }

    func testIdentityRejectsOtherSysEx() {
        XCTAssertNil(IdentityReply.decode([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]))
        XCTAssertNil(IdentityReply.decode([0xF0, 0x52, 0x00, 0x5E, 0x28, 0xF7]))
    }

    func testProgramInfo() {
        var p = ProgramInfo()
        XCTAssertFalse(p.apply([0xB0, 0x00, 0x00]))
        XCTAssertFalse(p.apply([0xB0, 0x20, 0x01]))
        XCTAssertTrue(p.apply([0xC0, 0x07]))
        XCTAssertEqual(p, ProgramInfo(bankMSB: 0, bankLSB: 1, program: 7))
    }

    func testResponseDecode() {
        let d = DecodedMessage.decode(.sysex([0xF0, 0x52, 0x00, 0x5E, 0x00, 0x00, 0xF7]))
        XCTAssertEqual(d, .response(deviceID: 0x5E, code: 0x00, payload: [0x00]))
    }

    /// Real 0x28 dump from the MS-100BT (session 1, patch "Bourj", read inside edit mode).
    let bourj: [UInt8] = "F0 52 00 5E 28 02 10 00 00 06 0A 48 00 00 32 00 00 00 00 00 00 00 00 00 00 00 10 00 00 18 4C 0C 38 00 45 50 01 00 00 00 00 00 00 00 00 00 00 20 00 00 72 03 14 40 00 1F 00 43 06 00 00 00 00 00 00 00 00 60 00 28 00 4E 05 10 01 41 00 00 60 30 06 00 00 00 00 12 00 00 60 01 00 06 07 40 48 00 32 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 40 54 0F 42 00 6F 75 72 6A 20 20 20 00 20 20 00 F7"
        .split(separator: " ").map { UInt8($0, radix: 16)! }

    func testUnpack7() {
        // msb bit 6 → data byte 0, bit 4 → data byte 2, bit 0 → data byte 6.
        XCTAssertEqual(PatchDump.unpack7([0b0101_0001, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07][...]),
                       [0x81, 0x02, 0x83, 0x04, 0x05, 0x06, 0x87])
        XCTAssertEqual(PatchDump.unpack7([0x40, 0x10, 0x20][...]), [0x90, 0x20]) // short final group
    }

    func testRealPatchDump() throws {
        XCTAssertEqual(bourj.count, 146)
        let p = try XCTUnwrap(PatchDump.decode(bourj))
        XCTAssertEqual(p.deviceID, 0x5E)
        XCTAssertTrue(p.lengthMatchesMS50G)
        XCTAssertEqual(p.unpacked.count, 122)
        XCTAssertEqual(p.name, "Bourj")
        XCTAssertEqual(p.effects.count, 6)
        XCTAssertEqual(p.effects.map(\.raw.count), [18, 18, 18, 18, 18, 18])
        XCTAssertEqual(p.effects.map { $0.raw.first }, [0x10, 0x10, 0x20, 0x60, 0xE0, 0x01])
        XCTAssertEqual(DecodedMessage.decode(.sysex(bourj)), .patch(p))
        // Pedal screen: five effects, all off; slot 6 unused.
        XCTAssertEqual(p.effects.map(\.isEmpty), [false, false, false, false, false, true])
        XCTAssertEqual(p.effects.map(\.isOn), [false, false, false, false, false, nil])
        XCTAssertEqual(p.effects.map(\.effectID), [0x03000008, 0x06000008, 0x09000010, 0x07000030, 0x030000F0, 0])
        XCTAssertEqual(p.effects.map(\.displayName), ["Booster", "Tremolo", "Hall", "MonoSynth", "Z Scream", "—"])
        XCTAssertEqual(p.effects.map(\.category), ["Drive", "Modulation", "Reverb", "SFX", "Drive", nil])
        XCTAssertEqual(p.effectCount, 5)
        XCTAssertEqual(p.tempo, 126)
    }

    func testParameters() throws {
        let p = try XCTUnwrap(PatchDump.decode(bourj))
        func params(_ i: Int) -> String {
            p.effects[i].parameters.map { "\($0.name)=\($0.text)" }.joined(separator: " ")
        }
        XCTAssertEqual(params(0), "Gain=80 Tone=50 Level=100")
        XCTAssertEqual(params(1), "Depth=98 Rate=46 Level=139 Wave=TRI 1")
        XCTAssertEqual(params(2), "Decay=28 Tone=5 Mix=63 PreD=49 Level=100 Tail=OFF")
        XCTAssertEqual(params(3), "Synth=46 Dry=100 Level=130 Wave=Sine Tone=6 Speed=99")
        XCTAssertEqual(params(4), "Gain=60 Tone=50 Level=100")
        XCTAssertTrue(p.effects[5].parameters.isEmpty)
        // Every decoded value is inside its catalog range.
        XCTAssertTrue(p.effects.flatMap(\.parameters).allSatisfy { $0.display != nil })
    }

    func testCatalog() {
        XCTAssertEqual(EffectCatalog.effects.count, 226)
        XCTAssertNil(EffectCatalog.name(for: 0xFFFF_FFFF))
        let delayTime = EffectCatalog.effect(for: 0x08000008)?.parameters.first
        XCTAssertEqual(delayTime?.name, "Time")
        XCTAssertEqual(delayTime?.display(0), "1")
        XCTAssertNil(delayTime?.display(99_999))
    }

    /// Session 2: enabling effect 5 on the pedal flipped packed byte 88 (= unpacked 72) bit 0.
    func testEffectToggleBit() throws {
        var after = bourj
        after[88] |= 0x01
        let p = try XCTUnwrap(PatchDump.decode(after))
        XCTAssertEqual(p.effects.map(\.isOn), [false, false, false, false, true, nil])
        XCTAssertEqual(p.unpacked[72], 0xE1)
    }

    func testShortPatchDoesNotCrash() throws {
        let p = try XCTUnwrap(PatchDump.decode([0xF0, 0x52, 0x00, 0x5E, 0x28, 0x00, 0x01, 0xF7]))
        XCTAssertNil(p.name)
        XCTAssertFalse(p.lengthMatchesMS50G)
        XCTAssertNil(p.effects.first?.isOn) // ID bits all zero → empty slot
        XCTAssertTrue(p.effects[1].isEmpty)
        XCTAssertEqual(p.effects[1].raw, [])
    }
}

final class WireLogTests: XCTestCase {
    func testWritesJSONLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = try WireLog(directory: dir)
        log.record(.tx, Message.identityRequest.bytes, note: "identity request")
        log.note("hello")
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(first?["dir"] as? String, "tx")
        XCTAssertEqual(first?["hex"] as? String, "F0 7E 00 06 01 F7")
        try? FileManager.default.removeItem(at: dir)
    }
}

final class WriteTests: XCTestCase {
    let bourj = DecoderTests().bourj

    func testRoundTripIsByteExact() throws {
        let p = try XCTUnwrap(PatchDump.decode(bourj))
        XCTAssertEqual(PatchDump.pack7(p.unpacked), Array(bourj[5..<145]))
        XCTAssertEqual(PatchEdit(p).frame, bourj)
        XCTAssertNil(p.validationProblem)
        XCTAssertNoThrow(try Allowlist.validate(Message.sendPatch(frame: bourj).bytes))
    }

    func testEditSlot() throws {
        let p = try XCTUnwrap(PatchDump.decode(bourj))
        XCTAssertEqual(p.editSlot, 4) // FX5: the effect last toggled on the pedal before this dump
        for slot in 0..<6 {
            var e = PatchEdit(p)
            e.setEditSlot(slot)
            let d = try XCTUnwrap(e.decoded)
            XCTAssertEqual(d.editSlot, slot)
            XCTAssertEqual(d.tempo, p.tempo)
            XCTAssertEqual(d.effectCount, p.effectCount)
            XCTAssertEqual(d.effects.map(\.raw), p.effects.map(\.raw))
        }
    }

    func testEdits() throws {
        var e = PatchEdit(try XCTUnwrap(PatchDump.decode(bourj)))
        e.setName("Test 1")
        e.setTempo(100)
        e.setOn(slot: 1, true)
        e.setParameter(slot: 2, index: 0, raw: 0)            // Hall Decay → "1"
        e.setEffect(slot: 5, id: 0x09000010)                 // Hall into the empty slot
        let d = try XCTUnwrap(e.decoded)
        XCTAssertEqual(d.name, "Test 1")
        XCTAssertEqual(d.tempo, 100)
        XCTAssertEqual(d.effects[1].isOn, true)
        XCTAssertEqual(d.effects[2].parameters[0].text, "1")
        XCTAssertEqual(d.effects[5].displayName, "Hall")
        XCTAssertEqual(d.effects[5].parameters.map(\.raw),
                       EffectCatalog.effect(for: 0x09000010)!.parameters.map(\.defaultRaw))
        XCTAssertEqual(d.effectCount, 6)
        XCTAssertNil(d.validationProblem)
        // Untouched slots are byte-identical.
        let before = try XCTUnwrap(PatchDump.decode(bourj))
        XCTAssertEqual(d.effects[0].raw, before.effects[0].raw)
        XCTAssertEqual(d.effects[3].raw, before.effects[3].raw)

        e.setEffect(slot: 5, id: 0)
        e.setEffect(slot: 4, id: 0)
        let d2 = try XCTUnwrap(e.decoded)
        XCTAssertTrue(d2.effects[4].isEmpty && d2.effects[5].isEmpty)
        XCTAssertEqual(d2.effects[4].raw, [0x01] + Array(repeating: 0, count: 17))
        XCTAssertEqual(d2.effectCount, 4)
    }

    func testInvalidPatchIsRefused() throws {
        var e = PatchEdit(try XCTUnwrap(PatchDump.decode(bourj)))
        e.setParameter(slot: 2, index: 0, raw: 500)          // Hall Decay has 30 values
        XCTAssertThrowsError(try Allowlist.validate(e.frame))
        var unknown = PatchEdit(try XCTUnwrap(PatchDump.decode(bourj)))
        unknown.setEffect(slot: 0, id: 0x0ABCDEF0)           // not in the catalog
        XCTAssertThrowsError(try Allowlist.validate(unknown.frame))
        var short = bourj; short.remove(at: 50)
        XCTAssertThrowsError(try Allowlist.validate(short))
    }

    func testWriteMessageShapes() {
        XCTAssertNoThrow(try Allowlist.validate(Message.selectPatch(49).bytes))
        XCTAssertThrowsError(try Allowlist.validate(Message.selectPatch(50).bytes))
        XCTAssertThrowsError(try Allowlist.validate([0xC1, 0x01]))  // other MIDI channel
        XCTAssertNoThrow(try Allowlist.validate(Message.parameterEdit(deviceID: 0x5E, slot: 0, param: 0, value: 1).bytes))
        XCTAssertNoThrow(try Allowlist.validate(Message.parameterEdit(deviceID: 0x5E, slot: 5, param: 10, value: 4000).bytes))
        XCTAssertThrowsError(try Allowlist.validate(Message.parameterEdit(deviceID: 0x5E, slot: 6, param: 2, value: 1).bytes))
        XCTAssertThrowsError(try Allowlist.validate(Message.parameterEdit(deviceID: 0x5E, slot: 0, param: 1, value: 1).bytes))
        XCTAssertThrowsError(try Allowlist.validate(Message.parameterEdit(deviceID: 0x5E, slot: 0, param: 0, value: 2).bytes))
        XCTAssertNoThrow(try Allowlist.validate(Message.storePatch(deviceID: 0x5E, slot: 0).bytes))
        XCTAssertThrowsError(try Allowlist.validate(Message.storePatch(deviceID: 0x5E, slot: 50).bytes))
        XCTAssertThrowsError(try Allowlist.validate([0xF0, 0x52, 0x00, 0x5E, 0x32, 0x01, 0x00, 0x00, 0x00, 0xF7]))
        for m in [Message.selectPatch(0), .parameterEdit(deviceID: 0x5E, slot: 0, param: 0, value: 0),
                  .storePatch(deviceID: 0x5E, slot: 0), .sendPatch(frame: bourj)] {
            XCTAssertTrue(m.isWrite)
            XCTAssertTrue(Allowlist.isWrite(m.bytes))
        }
        XCTAssertFalse(Allowlist.isWrite(Message.requestCurrentPatch(deviceID: 0x5E).bytes))
    }

    func testFirmwarePathStillBlocked() {
        for f: [UInt8] in [[0xF0, 0x52, 0x00, 0x5E, 0x01, 0xF7], [0xF0, 0x52, 0x00, 0x5E, 0x04, 0xF7],
                           [0xF0, 0x52, 0x00, 0x5E, 0x60, 0x06, 0xF7], [0xF0, 0x52, 0x00, 0x5E, 0x61, 0x05, 0xF7]] {
            XCTAssertThrowsError(try Allowlist.validate(f))
        }
    }
}

final class PatchAssistantTests: XCTestCase {
    let bourj = DecoderTests().bourj
    var base: PatchDump { PatchDump.decode(bourj)! }
    var available: Set<UInt32> { PatchAssistant.availableIDs(seen: [base]) }

    func testBuildPatchFromSpec() throws {
        let spec: [String: Any] = [
            "name": "Edge Dly", "tempo": 126,
            "effects": [
                ["effect": "comp", "on": true, "params": ["Sense": 6]],
                ["effect": "Delay", "on": true, "params": ["Time": 357, "F.B": "35", "Mix": 40, "Tail": "ON"]],
                ["effect": "Hall", "on": false],
            ],
        ]
        let edit = try PatchAssistant.buildPatch(spec: spec, base: base, available: available).get()
        let d = try XCTUnwrap(edit.decoded)
        XCTAssertEqual(d.name, "Edge Dly")
        XCTAssertEqual(d.tempo, 126)
        XCTAssertEqual(d.effects.map(\.displayName), ["Comp", "Delay", "Hall", "—", "—", "—"])
        XCTAssertEqual(d.effects.map(\.isOn), [true, true, false, nil, nil, nil])
        let delay = Dictionary(uniqueKeysWithValues: d.effects[1].parameters.map { ($0.name, $0.text) })
        XCTAssertEqual(delay["Time"], "357")
        XCTAssertEqual(delay["F.B"], "35")
        XCTAssertEqual(delay["Tail"], "ON")
        XCTAssertEqual(d.effectCount, 3)
        XCTAssertNil(d.validationProblem)
    }

    func testBuildPatchReportsEveryProblem() {
        let spec: [String: Any] = [
            "name": "Way too long name",
            "effects": [
                ["effect": "Flux Capacitor"],
                ["effect": "Hall", "params": ["Decay": 99, "Sparkle": 3]],
            ],
        ]
        guard case .failure(let e) = PatchAssistant.buildPatch(spec: spec, base: base, available: available) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(e.problems.count, 4, e.description)
        XCTAssertTrue(e.description.contains("Flux Capacitor"))
        XCTAssertTrue(e.description.contains("\"99\" is not allowed"))
        XCTAssertTrue(e.description.contains("Sparkle"))
    }

    func testAdjust() throws {
        let edit = try PatchAssistant.adjust([["slot": 3, "param": "mix", "value": 20], ["slot": 1, "on": true]], base: base).get()
        let d = try XCTUnwrap(edit.decoded)
        XCTAssertEqual(d.effects[2].parameters.first { $0.name == "Mix" }?.text, "20")
        XCTAssertEqual(d.effects[0].isOn, true)
        XCTAssertEqual(d.effects[1].raw, base.effects[1].raw) // untouched
        if case .success = PatchAssistant.adjust([["slot": 6, "param": "Mix", "value": 1]], base: base) { XCTFail("slot 6 is empty") }
    }

    func testDescriptions() {
        let hall = PatchAssistant.effectDetails(names: ["hall"], available: available).first!
        XCTAssertEqual(hall["name"] as? String, "Hall")
        let knobs = hall["knobs"] as! [[String: Any]]
        XCTAssertEqual(knobs.first?["values"] as? String, "1–30")
        XCTAssertEqual(knobs.last?["values"] as? [String], ["OFF", "ON"])
        XCTAssertEqual(PatchAssistant.describe(base)["name"] as? String, "Bourj")
        XCTAssertFalse(PatchAssistant.effectList(available: available, category: "Reverb").isEmpty)
        XCTAssertNotNil(PatchAssistant.effectDetails(names: ["nope"], available: available).first?["error"])
    }
}
