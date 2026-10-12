import Foundation
import IOBluetooth

/// One SDP service record, flattened for display and logging.
public struct ServiceRecordInfo: Sendable, Identifiable {
    public struct Attribute: Sendable, Identifiable {
        public let id: UInt16
        public let value: String
    }

    public let id = UUID()
    public let name: String?
    public let rfcommChannel: UInt8?
    public let isSerialPort: Bool
    public let attributes: [Attribute]

    public var summary: String {
        var s = "\"\(name ?? "(unnamed)")\""
        if let ch = rfcommChannel { s += " RFCOMM ch \(ch)" }
        if isSerialPort { s += " [Serial Port 0x1101]" }
        return s
    }
}

/// Plain value describing a Bluetooth device, so UI code needn't hold IOBluetoothDevice.
public struct DeviceSummary: Sendable, Identifiable, Hashable {
    public let address: String
    public let name: String
    public let isPaired: Bool
    public let isConnected: Bool
    public var id: String { address }
}

@MainActor
public enum Discovery {
    /// Serial Port Profile — the service the official updater opens.
    public nonisolated static let serialPortUUID16: BluetoothSDPUUID16 = 0x1101

    public static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    public static func looksLikeZoom(_ d: IOBluetoothDevice) -> Bool {
        let n = (d.name ?? "").uppercased()
        return n.contains("MS-100") || n.contains("ZOOM")
    }

    public static func summary(_ d: IOBluetoothDevice) -> DeviceSummary {
        DeviceSummary(address: d.addressString ?? "?", name: d.name ?? "(no name)",
                      isPaired: d.isPaired(), isConnected: d.isConnected())
    }

    /// `nil` → first paired device that looks like the pedal.
    /// `aa-bb-cc-dd-ee-ff` / `aa:bb:…` → that address. Anything else → paired-name substring.
    public static func resolve(_ query: String?) -> IOBluetoothDevice? {
        guard let q = query, !q.isEmpty else {
            return pairedDevices().first(where: looksLikeZoom)
        }
        let isAddress = q.range(of: #"^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
        if isAddress { return IOBluetoothDevice(addressString: q) }
        return pairedDevices().first { ($0.name ?? "").localizedCaseInsensitiveContains(q) }
    }

    // MARK: SDP

    /// Runs a fresh SDP query. Returns the IOReturn status (kIOReturnTimeout if no callback).
    public static func sdpQuery(_ device: IOBluetoothDevice, timeout: TimeInterval = 20) async -> IOReturn {
        await withCheckedContinuation { cont in
            let waiter = SDPWaiter(cont)
            let r = device.performSDPQuery(waiter)
            if r != kIOReturnSuccess { waiter.finish(r); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { waiter.finish(kIOReturnTimeout) }
        }
    }

    public static func serviceRecords(_ device: IOBluetoothDevice) -> [ServiceRecordInfo] {
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        return records.map { rec in
            var ch: BluetoothRFCOMMChannelID = 0
            let hasCh = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
            let attrs = ((rec.sortedAttributes as? [IOBluetoothSDPServiceAttribute]) ?? []).map {
                ServiceRecordInfo.Attribute(id: $0.getID(), value: describe($0.getDataElement()))
            }
            return ServiceRecordInfo(
                name: rec.getServiceName(),
                rfcommChannel: hasCh ? ch : nil,
                isSerialPort: rec.matchesUUID16(Discovery.serialPortUUID16),
                attributes: attrs
            )
        }
    }

    static func describe(_ e: IOBluetoothSDPDataElement?) -> String {
        guard let e else { return "nil" }
        switch e.getTypeDescriptor() {
        case 0: return "nil"
        case 1, 2, 5: return e.getNumberValue()?.stringValue ?? "?"
        case 3:
            guard let u = e.getUUIDValue() else { return "uuid ?" }
            return "uuid " + [UInt8](u as Data).hex
        case 4, 8: return "\"\(e.getStringValue() ?? "")\""
        case 6, 7:
            let items = (e.getArrayValue() as? [IOBluetoothSDPDataElement]) ?? []
            return "[" + items.map(describe).joined(separator: ", ") + "]"
        default: return "type \(e.getTypeDescriptor())"
        }
    }

    // MARK: inquiry / pairing

    /// Classic inquiry for `seconds` (pedal must be in pairing mode to show up).
    public static func inquiry(seconds: UInt8 = 10) async -> [IOBluetoothDevice] {
        await withCheckedContinuation { cont in
            let waiter = InquiryWaiter(cont)
            guard let inq = IOBluetoothDeviceInquiry(delegate: waiter) else { waiter.finish(); return }
            waiter.inquiry = inq
            inq.inquiryLength = seconds
            inq.updateNewDeviceNames = true
            if inq.start() != kIOReturnSuccess { waiter.finish() }
        }
    }

    public static func pair(_ device: IOBluetoothDevice, pin: String = "0000") async -> IOReturn {
        await withCheckedContinuation { cont in
            let waiter = PairWaiter(cont, pin: pin)
            guard let p = IOBluetoothDevicePair(device: device) else { waiter.finish(kIOReturnError); return }
            waiter.pair = p
            p.delegate = waiter
            let r = p.start()
            if r != kIOReturnSuccess { waiter.finish(r) }
        }
    }

    // MARK: serial fallback

    public static func serialNodes() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return all.filter { $0.hasPrefix("cu.") }
            .filter { $0.uppercased().contains("ZOOM") || $0.uppercased().contains("MS-100") || $0.uppercased().contains("MS100") }
            .map { "/dev/" + $0 }
            .sorted()
    }
}

// MARK: - callback adapters (resume their continuation exactly once)

private final class SDPWaiter: NSObject {
    private var cont: CheckedContinuation<IOReturn, Never>?
    private var selfRef: SDPWaiter?
    init(_ c: CheckedContinuation<IOReturn, Never>) { cont = c; super.init(); selfRef = self }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { finish(status) }

    func finish(_ r: IOReturn) {
        cont?.resume(returning: r)
        cont = nil
        selfRef = nil
    }
}

private final class InquiryWaiter: NSObject, IOBluetoothDeviceInquiryDelegate {
    private var cont: CheckedContinuation<[IOBluetoothDevice], Never>?
    private var selfRef: InquiryWaiter?
    var inquiry: IOBluetoothDeviceInquiry?
    init(_ c: CheckedContinuation<[IOBluetoothDevice], Never>) { cont = c; super.init(); selfRef = self }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) { finish() }

    func finish() {
        let found = (inquiry?.foundDevices() as? [IOBluetoothDevice]) ?? []
        cont?.resume(returning: found)
        cont = nil
        inquiry = nil
        selfRef = nil
    }
}

private final class PairWaiter: NSObject, IOBluetoothDevicePairDelegate {
    private var cont: CheckedContinuation<IOReturn, Never>?
    private var selfRef: PairWaiter?
    private let pin: String
    var pair: IOBluetoothDevicePair?
    init(_ c: CheckedContinuation<IOReturn, Never>, pin: String) { cont = c; self.pin = pin; super.init(); selfRef = self }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        var code = BluetoothPINCode()
        let digits = Array(pin.utf8.prefix(16))
        withUnsafeMutableBytes(of: &code.data) { buf in
            for (i, b) in digits.enumerated() { buf[i] = b }
        }
        pair?.replyPINCode(digits.count, pinCode: &code)
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        pair?.replyUserConfirmation(true)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) { finish(error) }

    func finish(_ r: IOReturn) {
        cont?.resume(returning: r)
        cont = nil
        pair = nil
        selfRef = nil
    }
}
