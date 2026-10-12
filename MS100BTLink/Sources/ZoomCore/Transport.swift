import Foundation
import IOKit

@MainActor
public protocol TransportDelegate: AnyObject {
    func transportDidOpen(_ transport: Transport)
    func transport(_ transport: Transport, didFailToOpen error: Error)
    func transport(_ transport: Transport, didReceive bytes: [UInt8])
    func transportDidClose(_ transport: Transport)
}

/// A byte pipe to the pedal. Implementations must call `Allowlist.validate`
/// at the top of `send` — that is the hard gate; no other write path exists.
@MainActor
public protocol Transport: AnyObject {
    var delegate: TransportDelegate? { get set }
    var displayName: String { get }
    var isOpen: Bool { get }
    /// Starts opening; completion arrives via the delegate.
    func open() throws
    func close()
    /// Validates `frame` against the allowlist, then writes it. Throws `AllowlistViolation` on refusal.
    func send(_ frame: [UInt8]) throws
}

public enum TransportError: Error, CustomStringConvertible {
    case noSerialService
    case noRFCOMMChannel(IOReturn)
    case openFailed(IOReturn)
    case notOpen
    case writeFailed(IOReturn)
    case serial(String)

    public var description: String {
        switch self {
        case .noSerialService:
            return "The pedal has no Serial Port (UUID 0x1101) SDP record. Run an SDP query first, or check pairing."
        case .noRFCOMMChannel(let r): return "Serial Port record has no RFCOMM channel ID (\(ioReturnString(r)))."
        case .openFailed(let r):
            return "RFCOMM open failed (\(ioReturnString(r))). If this repeats, the macOS Bluetooth stack may need a restart (toggle Bluetooth off/on)."
        case .notOpen: return "Channel is not open."
        case .writeFailed(let r): return "Write failed (\(ioReturnString(r)))."
        case .serial(let s): return s
        }
    }
}

public func ioReturnString(_ r: IOReturn) -> String {
    String(format: "IOReturn 0x%08X", UInt32(bitPattern: r))
}
