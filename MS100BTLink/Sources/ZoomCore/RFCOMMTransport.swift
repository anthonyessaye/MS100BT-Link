import Foundation
import IOBluetooth

/// RFCOMM to the pedal's Serial Port service, located the same way the official
/// updater does it: SDP UUID16 0x1101 → RFCOMM channel ID → async open.
@MainActor
public final class RFCOMMTransport: NSObject, Transport {
    public weak var delegate: TransportDelegate?
    public let device: IOBluetoothDevice
    public private(set) var channelID: BluetoothRFCOMMChannelID?
    public private(set) var isOpen = false
    private var channel: IOBluetoothRFCOMMChannel?

    public init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    public var displayName: String {
        "\(device.nameOrAddress ?? "?") · RFCOMM ch \(channelID.map { String($0) } ?? "?")"
    }

    public func open() throws {
        guard let uuid = IOBluetoothSDPUUID(uuid16: Discovery.serialPortUUID16),
              let record = device.getServiceRecord(for: uuid) else {
            throw TransportError.noSerialService
        }
        var ch: BluetoothRFCOMMChannelID = 0
        let r = record.getRFCOMMChannelID(&ch)
        guard r == kIOReturnSuccess else { throw TransportError.noRFCOMMChannel(r) }
        channelID = ch

        var opened: IOBluetoothRFCOMMChannel?
        let o = device.openRFCOMMChannelAsync(&opened, withChannelID: ch, delegate: self)
        guard o == kIOReturnSuccess else {
            device.closeConnection()
            throw TransportError.openFailed(o)
        }
        channel = opened
    }

    public func close() {
        let wasOpen = isOpen
        isOpen = false
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
        if device.isConnected() { device.closeConnection() }
        if wasOpen { delegate?.transportDidClose(self) }
    }

    public func send(_ frame: [UInt8]) throws {
        try Allowlist.validate(frame)
        guard isOpen, let channel else { throw TransportError.notOpen }
        let mtu = max(Int(channel.getMTU()), 1)
        var offset = 0
        while offset < frame.count {
            let n = min(mtu, frame.count - offset)
            // Freed in rfcommChannelWriteComplete (the refcon is the buffer itself).
            let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1)
            frame[offset..<(offset + n)].withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: n) }
            let r = channel.writeAsync(buf, length: UInt16(n), refcon: buf)
            guard r == kIOReturnSuccess else {
                buf.deallocate()
                throw TransportError.writeFailed(r)
            }
            offset += n
        }
    }

    // MARK: callbacks (IOBluetooth delivers these on the main run loop)

    private func handleOpenComplete(_ status: IOReturn) {
        if status == kIOReturnSuccess {
            isOpen = true
            delegate?.transportDidOpen(self)
        } else {
            channel = nil
            if device.isConnected() { device.closeConnection() }
            delegate?.transport(self, didFailToOpen: TransportError.openFailed(status))
        }
    }

    private func handleClosed() {
        channel = nil
        guard isOpen else { return }
        isOpen = false
        delegate?.transportDidClose(self)
    }
}

extension RFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    nonisolated public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated { self.handleOpenComplete(error) }
    }

    nonisolated public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { self.delegate?.transport(self, didReceive: bytes) }
    }

    nonisolated public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated { self.handleClosed() }
    }

    nonisolated public func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        refcon?.deallocate()
    }
}
