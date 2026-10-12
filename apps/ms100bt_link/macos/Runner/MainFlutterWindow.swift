import Cocoa
import CoreAudioKit
import FlutterMacOS
import IOBluetooth

class MainFlutterWindow: NSWindow {
  private var bridge: PedalBridge?
  private var ui: UIBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Same window as the native app: hidden title bar (the top bar sits under the traffic lights),
    // dark, 1040 × 660 minimum.
    title = "MS-100BT Link"
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    appearance = NSAppearance(named: .darkAqua)
    contentMinSize = NSSize(width: 1040, height: 660)
    setContentSize(NSSize(width: 1280, height: 820))
    center()
    setFrameAutosaveName("MainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    bridge = PedalBridge(messenger: flutterViewController.engine.binaryMessenger)
    ui = UIBridge(messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// Native macOS pieces the Flutter UI asks for, so the Mac build behaves like the native app:
/// NSAlert (with the suppression checkbox), Apple's Bluetooth MIDI window, and menu-bar commands.
final class UIBridge: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var bluetoothMIDI: CABTLEMIDIWindowController?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(name: "ms100bt/ui", binaryMessenger: messenger)
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    DispatchQueue.main.async { self.installMenus() }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "alert":
      let a = NSAlert()
      a.messageText = args["title"] as? String ?? ""
      a.informativeText = args["text"] as? String ?? ""
      a.alertStyle = (args["critical"] as? Bool) == true ? .critical : .warning
      for b in args["buttons"] as? [String] ?? ["OK"] { a.addButton(withTitle: b) }
      if let s = args["suppression"] as? String {
        a.showsSuppressionButton = true
        a.suppressionButton?.title = s
        a.suppressionButton?.state = (args["suppressed"] as? Bool) == true ? .on : .off
      }
      // Deferred so the method call returns to the run loop first; runModal then blocks like the native app.
      DispatchQueue.main.async {
        let r = a.runModal()
        result(["button": r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
                "suppressed": a.suppressionButton?.state == .on])
      }
    case "menu":
      // A native pop-up menu at a point in the Flutter view (top-left origin). Returns the chosen id or nil.
      guard let view = window?.contentView else { return result(nil) }
      let menu = NSMenu()
      menu.autoenablesItems = false
      var chosen: String?
      final class Target: NSObject { var pick: (String) -> Void = { _ in }; @objc func act(_ s: NSMenuItem) { pick(s.representedObject as? String ?? "") } }
      let target = Target()
      target.pick = { chosen = $0 }
      for i in args["items"] as? [[String: Any]] ?? [] {
        if i["separator"] as? Bool == true { menu.addItem(.separator()); continue }
        let item = NSMenuItem(title: i["title"] as? String ?? "", action: #selector(Target.act(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = i["id"] as? String
        item.isEnabled = i["enabled"] as? Bool ?? true
        item.state = (i["checked"] as? Bool) == true ? .on : .off
        menu.addItem(item)
      }
      let x = args["x"] as? Double ?? 0, y = args["y"] as? Double ?? 0
      let point = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
      DispatchQueue.main.async {
        menu.popUp(positioning: nil, at: point, in: view) // returns when the menu closes
        withExtendedLifetime(target) { result(chosen) }
      }
    case "bluetoothMIDI":
      if bluetoothMIDI == nil { bluetoothMIDI = CABTLEMIDIWindowController() }
      bluetoothMIDI?.showWindow(nil)
      bluetoothMIDI?.window?.makeKeyAndOrderFront(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// App name in the app menu, plus the native app's commands (Window → Diagnostics ⌥⌘D) and
  /// Effects / MIDI windows.
  private func installMenus() {
    guard let main = NSApp.mainMenu else { return }
    func rename(_ menu: NSMenu) {
      menu.title = menu.title.replacingOccurrences(of: "APP_NAME", with: "MS-100BT Link")
      for item in menu.items {
        item.title = item.title.replacingOccurrences(of: "APP_NAME", with: "MS-100BT Link")
        if let sub = item.submenu { rename(sub) }
      }
    }
    rename(main)
    guard let windowMenu = main.items.first(where: { $0.submenu?.title == "Window" })?.submenu else { return }
    let at = windowMenu.items.firstIndex(where: { $0.title == "Bring All to Front" }) ?? windowMenu.items.count
    windowMenu.insertItem(NSMenuItem.separator(), at: at)
    let items: [(String, String, NSEvent.ModifierFlags, String)] = [
      ("Effects", "e", [.command, .shift], "effects"),
      ("MIDI Control", "m", [.command, .shift], "midi"),
      ("Diagnostics", "d", [.command, .option], "diagnostics"),
    ]
    for (i, (title, key, mods, id)) in items.enumerated() {
      let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: key)
      item.keyEquivalentModifierMask = mods
      item.representedObject = id
      item.target = self
      windowMenu.insertItem(item, at: at + 1 + i)
    }
  }

  @objc private func menuCommand(_ sender: NSMenuItem) {
    window?.makeKeyAndOrderFront(nil)
    channel.invokeMethod("menu", arguments: sender.representedObject as? String)
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
