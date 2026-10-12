import Cocoa
import FlutterMacOS
import IOBluetooth

class MainFlutterWindow: NSWindow {
  private var bridge: PedalBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    bridge = PedalBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Byte pipe to the Zoom MS-100BT over Bluetooth RFCOMM (Serial Port, SDP UUID 0x1101), for the
/// shared Dart core. The Dart side validates every outbound frame against the allowlist.
final class PedalBridge: NSObject, FlutterStreamHandler, IOBluetoothRFCOMMChannelDelegate {
  private var sink: FlutterEventSink?
  private var channel: IOBluetoothRFCOMMChannel?
  private var device: IOBluetoothDevice?
  private var pendingConnect: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "ms100bt/bluetooth", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    FlutterEventChannel(name: "ms100bt/bluetooth/rx", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "pairedDevices":
      let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
      result(devices.map { ["address": $0.addressString ?? "", "name": $0.name ?? "?"] })
    case "connect":
      let address = (call.arguments as? [String: Any])?["address"] as? String ?? ""
      connect(address, result)
    case "write":
      guard let data = call.arguments as? FlutterStandardTypedData else { return result(FlutterError(code: "args", message: nil, details: nil)) }
      write([UInt8](data.data), result)
    case "disconnect":
      close(); result(nil)
    case "diagnostics":
      result(["platform": "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func connect(_ address: String, _ result: @escaping FlutterResult) {
    close()
    guard let d = IOBluetoothDevice(addressString: address) else {
      return result(FlutterError(code: "connect", message: "Unknown device", details: nil))
    }
    device = d
    d.performSDPQuery(nil) // refresh records; the cached ones work if this is slow
    guard let uuid = IOBluetoothSDPUUID(uuid16: 0x1101), let record = d.getServiceRecord(for: uuid) else {
      return result(FlutterError(code: "connect", message: "The pedal has no Serial Port service. Is it paired?", details: nil))
    }
    var ch: BluetoothRFCOMMChannelID = 0
    guard record.getRFCOMMChannelID(&ch) == kIOReturnSuccess else {
      return result(FlutterError(code: "connect", message: "No RFCOMM channel in the Serial Port record.", details: nil))
    }
    var opened: IOBluetoothRFCOMMChannel?
    let r = d.openRFCOMMChannelAsync(&opened, withChannelID: ch, delegate: self)
    guard r == kIOReturnSuccess else {
      d.closeConnection()
      return result(FlutterError(code: "connect", message: String(format: "RFCOMM open failed (0x%08X). Turn Bluetooth off and on if this repeats.", r), details: nil))
    }
    channel = opened
    pendingConnect = result
  }

  private func write(_ bytes: [UInt8], _ result: @escaping FlutterResult) {
    guard let channel else { return result(FlutterError(code: "closed", message: "Not connected.", details: nil)) }
    let mtu = max(Int(channel.getMTU()), 1)
    var off = 0
    while off < bytes.count {
      let n = min(mtu, bytes.count - off)
      let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1) // freed in rfcommChannelWriteComplete
      bytes[off..<(off + n)].withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: n) }
      let r = channel.writeAsync(buf, length: UInt16(n), refcon: buf)
      if r != kIOReturnSuccess { buf.deallocate(); return result(FlutterError(code: "write", message: String(format: "0x%08X", r), details: nil)) }
      off += n
    }
    result(nil)
  }

  private func close() {
    channel?.setDelegate(nil)
    channel?.close()
    channel = nil
    if device?.isConnected() == true { device?.closeConnection() }
  }

  // MARK: IOBluetoothRFCOMMChannelDelegate (main run loop)

  func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
    if error == kIOReturnSuccess {
      pendingConnect?(nil)
    } else {
      pendingConnect?(FlutterError(code: "connect", message: String(format: "RFCOMM open failed (0x%08X)", error), details: nil))
      close()
    }
    pendingConnect = nil
  }

  func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
    guard let dataPointer, dataLength > 0 else { return }
    sink?(FlutterStandardTypedData(bytes: Data(bytes: dataPointer, count: dataLength)))
  }

  func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
    channel = nil
  }

  func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
    refcon?.deallocate()
  }
}
