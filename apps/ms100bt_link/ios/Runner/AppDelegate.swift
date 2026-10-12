import ExternalAccessory
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var bridge: AccessoryBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MS100BTAccessoryBridge") {
      bridge = AccessoryBridge(messenger: registrar.messenger())
    }
  }
}

/// iOS can't open classic Bluetooth serial ports; the MS-100BT's other service is Apple's MFi accessory
/// protocol (iAP, SDP UUID 00000000-DECA-FADE-DECA-DEAFDECACAFF). This bridge is the feasibility test:
/// it lists connected accessories and their protocol names. Opening a session needs that protocol name
/// in Info.plist (UISupportedExternalAccessoryProtocols) and, for the App Store, Zoom's MFi approval.
final class AccessoryBridge: NSObject, FlutterStreamHandler {
  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "ms100bt/bluetooth", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    FlutterEventChannel(name: "ms100bt/bluetooth/rx", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }

  private var accessories: [EAAccessory] { EAAccessoryManager.shared().connectedAccessories }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "pairedDevices":
      result(accessories.map { ["address": String($0.connectionID), "name": $0.name] })
    case "diagnostics":
      var info: [String: Any] = ["platform": "iOS \(UIDevice.current.systemVersion)",
                                 "connected accessories": accessories.count]
      for (i, a) in accessories.enumerated() {
        info["accessory \(i + 1)"] = "\(a.name) · \(a.manufacturer) \(a.modelNumber) · fw \(a.firmwareRevision) · protocols: \(a.protocolStrings.joined(separator: ", "))"
      }
      result(info)
    case "connect":
      result(FlutterError(code: "unsupported",
                          message: "iPhone/iPad can't use the pedal's Bluetooth serial port. The MFi accessory route is being investigated: open Platform notes and send the accessory's protocol names to the developer.",
                          details: nil))
    case "write":
      result(FlutterError(code: "closed", message: "Not connected.", details: nil))
    case "disconnect":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
