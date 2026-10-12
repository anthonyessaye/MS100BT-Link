import Foundation
import IOBluetooth
import ZoomCore

let usage = """
zoomprobe — read-only probe for the Zoom MS-100BT (every outbound byte passes the allowlist)

USAGE
  zoomprobe list [--scan [SECONDS]]          paired devices; --scan also runs an inquiry (pedal in pairing mode)
  zoomprobe pair [DEVICE] [--pin 0000]       pair with the pedal (inquiry if not already known)
  zoomprobe sdp [DEVICE]                     fresh SDP query, dump every service record
  zoomprobe connect [DEVICE] [--listen 60]   open RFCOMM, listen passively, then send both identity requests
  zoomprobe probe identity|program|patch|all [DEVICE] [--no-edit-mode]
  zoomprobe allowlist                        print what may be sent, and what is blocked

  DEVICE   name substring or address (aa-bb-cc-dd-ee-ff); default: first paired device named ZOOM/MS-100
  --serial PATH   use a /dev/cu.* node instead of RFCOMM (connect/probe)

  --logs DIR      log directory (default ./logs)

Logs: <logs>/<command>-<timestamp>.jsonl
"""

// MARK: - argument parsing

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        var i = 0
        let valued: Set<String> = ["--listen", "--serial", "--pin", "--scan", "--logs"]
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                if valued.contains(a), i + 1 < argv.count, !argv[i + 1].hasPrefix("--"),
                   a != "--scan" || Int(argv[i + 1]) != nil {
                    options[a] = argv[i + 1]; i += 1
                } else {
                    flags.insert(a)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ f: String) -> Bool { flags.contains(f) || options[f] != nil }
}

// MARK: - output

@MainActor var log: WireLog?

@MainActor func say(_ s: String) {
    print(s)
    log?.note(s)
}

@MainActor func fail(_ s: String) -> Int32 {
    FileHandle.standardError.write(Data(("error: " + s + "\n").utf8))
    log?.note("error: " + s)
    return 1
}

@MainActor func describe(_ d: IOBluetoothDevice) -> String {
    "\(d.name ?? "(no name)")  \(d.addressString ?? "?")  paired=\(d.isPaired())  connected=\(d.isConnected())"
}

@MainActor func resolveDevice(_ args: Args, positionalIndex: Int) -> IOBluetoothDevice? {
    let q = args.positional.count > positionalIndex ? args.positional[positionalIndex] : nil
    return Discovery.resolve(q)
}

@MainActor func noDevice() -> Int32 {
    let paired = Discovery.pairedDevices()
    var msg = "pedal not found among paired devices."
    if paired.isEmpty { msg += " No paired devices." }
    else { msg += " Paired:\n" + paired.map { "  " + describe($0) }.joined(separator: "\n") }
    msg += "\nPut the pedal in pairing mode (knob 1 → MENU → Bluetooth → pairing) and run: zoomprobe pair"
    return fail(msg)
}

// MARK: - commands

@MainActor func cmdList(_ args: Args) async -> Int32 {
    say("Paired devices:")
    let paired = Discovery.pairedDevices()
    if paired.isEmpty { say("  (none)") }
    for d in paired { say("  " + describe(d) + (Discovery.looksLikeZoom(d) ? "   ← pedal?" : "")) }

    let nodes = Discovery.serialNodes()
    say("Serial nodes matching ZOOM/MS-100: " + (nodes.isEmpty ? "(none)" : nodes.joined(separator: ", ")))

    if args.has("--scan") {
        let secs = UInt8(args.options["--scan"].flatMap { Int($0) } ?? 10)
        say("Inquiry for \(secs)s…")
        let found = await Discovery.inquiry(seconds: secs)
        if found.isEmpty { say("  (nothing found)") }
        for d in found { say("  " + describe(d) + (Discovery.looksLikeZoom(d) ? "   ← pedal?" : "")) }
    }
    return 0
}

@MainActor func cmdPair(_ args: Args) async -> Int32 {
    var device = resolveDevice(args, positionalIndex: 1)
    if device == nil {
        say("Not paired yet; scanning 15s (pedal must be in pairing mode)…")
        let found = await Discovery.inquiry(seconds: 15)
        let q = args.positional.count > 1 ? args.positional[1] : nil
        device = found.first { d in
            if let q { return (d.name ?? "").localizedCaseInsensitiveContains(q) || d.addressString == q }
            return Discovery.looksLikeZoom(d)
        }
        for d in found { say("  found: " + describe(d)) }
    }
    guard let device else { return fail("pedal not found in inquiry. Is it in pairing mode?") }
    if device.isPaired() { say("Already paired: " + describe(device)); return 0 }
    say("Pairing with " + describe(device) + " …")
    let r = await Discovery.pair(device, pin: args.options["--pin"] ?? "0000")
    guard r == kIOReturnSuccess else { return fail("pairing failed: \(ioReturnString(r))") }
    say("Paired: " + describe(device))
    return 0
}

@MainActor func printRecords(_ device: IOBluetoothDevice) {
    let records = Discovery.serviceRecords(device)
    say("\(records.count) SDP record(s):")
    for (i, r) in records.enumerated() {
        say("  [\(i)] " + r.summary)
        for a in r.attributes { say(String(format: "        0x%04X = ", a.id) + a.value) }
    }
    if !records.contains(where: \.isSerialPort) {
        say("!! No Serial Port (0x1101) record. Stop condition (handoff §7): the pedal may expose iAP only.")
    }
}

@MainActor func cmdSDP(_ args: Args) async -> Int32 {
    guard let device = resolveDevice(args, positionalIndex: 1) else { return noDevice() }
    say("Device: " + describe(device))
    say("Running SDP query…")
    let r = await Discovery.sdpQuery(device)
    if r != kIOReturnSuccess { say("SDP query status: \(ioReturnString(r)) (showing cached records)") }
    printRecords(device)
    if device.isConnected() { device.closeConnection() }
    return 0
}

/// Builds and opens a session over RFCOMM or `--serial`.
@MainActor func openSession(_ args: Args, positionalIndex: Int) async -> PedalSession? {
    let transport: Transport
    if let path = args.options["--serial"] {
        transport = SerialTransport(path: path)
    } else {
        guard let device = resolveDevice(args, positionalIndex: positionalIndex) else { _ = noDevice(); return nil }
        say("Device: " + describe(device))
        if device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: Discovery.serialPortUUID16)) == nil {
            say("No cached Serial Port record; running SDP query…")
            let r = await Discovery.sdpQuery(device)
            if r != kIOReturnSuccess { say("SDP query status: \(ioReturnString(r))") }
        }
        transport = RFCOMMTransport(device: device)
    }

    let session = PedalSession(transport: transport, log: log)
    session.onEvent = { event in
        switch event {
        case .sent(let b, let label): print("→ \(b.hex)   (\(label))")
        case .received(let b): print("← \(b.hex)")
        case .decoded(_, let d) where d != .other: print("   \(d.summary)")
        case .blocked(let v): print("✋ \(v)")
        case .state(let s): print("[\(s.label)]")
        default: break
        }
    }
    session.open()
    guard await session.waitUntilOpen() else {
        _ = fail("channel did not open: \(session.state.label)")
        session.close()
        return nil
    }
    say("Channel open: \(transport.displayName)")
    return session
}

@MainActor func cmdConnect(_ args: Args) async -> Int32 {
    guard let session = await openSession(args, positionalIndex: 1) else { return 1 }
    let listen = Double(args.options["--listen"] ?? "60") ?? 60
    say("Listening passively for \(Int(listen))s (nothing sent)…")
    await session.sleep(listen)
    say("Passive listen done: \(session.bytesIn) byte(s) received.")

    for (i, m) in [Message.identityRequest, .identityRequestBroadcast].enumerated() {
        if i > 0 { await session.sleep(2) }
        try? session.send(m)
    }
    await session.sleep(3)
    report(session)
    session.close()
    return 0
}

@MainActor func cmdProbe(_ args: Args) async -> Int32 {
    let what = args.positional.count > 1 ? args.positional[1] : ""
    guard ["identity", "program", "patch", "all"].contains(what) else {
        return fail("probe needs one of: identity, program, patch, all")
    }
    guard let session = await openSession(args, positionalIndex: 2) else { return 1 }
    defer { session.close() }
    await session.sleep(0.5)

    guard let id = await session.identify() else {
        say("No identity reply to either form. See handoff §7: next step is a Bluetooth capture (human decision).")
        report(session)
        return 2
    }
    say("Identity: device ID \(id.deviceID.hex), mode \(id.mode), firmware \"\(id.version)\"")
    if !id.isKnownMS100BTID {
        say("!! Device ID \(id.deviceID.hex) is not 5D/5E; the allowlist will refuse Zoom opcodes. Stopping.")
        report(session)
        return 2
    }

    if what == "program" || what == "all" {
        if let p = await session.readProgram() { say("Current program: \(p.displayString)") }
        else { say("No program reply to 0x33.") }
    }
    if what == "patch" || what == "all" {
        if let p = await session.readPatch(allowEditMode: !args.has("--no-edit-mode")) {
            say("Patch dump: \(p.raw.count) bytes" + (p.lengthMatchesMS50G ? " (matches MS-50G 146)" : " (MS-50G layout expects 146 — treat decode as unverified)"))
            say("  name: \"\(p.name ?? "?")\"   ← compare with the pedal screen")
            say("  effects: \(p.effectCount.map(String.init) ?? "?")   tempo: \(p.tempo.map { "\($0) BPM" } ?? "?")")
            for e in p.effects {
                let on = e.isEmpty ? "   " : (e.isOn == true ? "ON " : "off")
                let cat = e.category.map { " (\($0))" } ?? ""
                say("  fx\(e.index + 1) \(on)  \(e.displayName)\(cat)" + (e.isEmpty ? "" : String(format: "   id %08X", e.effectID)))
                if !e.parameters.isEmpty {
                    say("           " + e.parameters.map { "\($0.name) \($0.text)" }.joined(separator: " · "))
                }
            }
        } else {
            say("No 0x28 patch dump received.")
        }
    }
    await session.sleep(0.5)
    report(session)
    return 0
}

@MainActor func report(_ s: PedalSession) {
    say("Summary: tier \(s.tierReached) · \(s.bytesOut) byte(s) sent · \(s.bytesIn) byte(s) received")
    if let url = log?.url { say("Log: \(url.path)") }
}

@MainActor func cmdAllowlist() -> Int32 {
    print("Allowed (exact frames, <id> ∈ {5D, 5E} learned from the identity reply):")
    for m in [Message.identityRequest, .identityRequestBroadcast, .requestCurrentProgram(deviceID: 0x5E),
              .requestCurrentPatch(deviceID: 0x5E), .editModeOn(deviceID: 0x5E), .editModeOff(deviceID: 0x5E)] {
        print("  \(m.bytes.hex)   \(m.label)")
    }
    print("Blocked opcodes (anything else is blocked too):")
    for (op, why) in Allowlist.forbiddenOpcodes.sorted(by: { $0.key < $1.key }) {
        print("  \(op.hex)  \(why)")
    }
    return 0
}

// MARK: - entry

@MainActor func run(_ argv: [String]) async -> Int32 {
    let args = Args(argv)
    guard let cmd = args.positional.first, !args.has("--help") else { print(usage); return 0 }
    if cmd == "allowlist" { return cmdAllowlist() }
    let logDir = args.options["--logs"].map { URL(fileURLWithPath: $0) } ?? WireLog.cliDirectory
    log = try? WireLog(directory: logDir, prefix: cmd)
    log?.note("zoomprobe " + argv.joined(separator: " "))
    switch cmd {
    case "list": return await cmdList(args)
    case "pair": return await cmdPair(args)
    case "sdp": return await cmdSDP(args)
    case "connect": return await cmdConnect(args)
    case "probe": return await cmdProbe(args)
    default: print(usage); return 64
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
Task { @MainActor in
    let code = await run(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
RunLoop.main.run()
