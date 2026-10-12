import Cocoa
import FlutterMacOS

/// Multi-window app: the engine runs headless and the Flutter framework creates the windows
/// (main window, Effects, Diagnostics), like the native app's SwiftUI scenes.
@main
class AppDelegate: FlutterAppDelegate {
  var engine: FlutterEngine?
  private var pedal: PedalBridge?
  private var ui: UIBridge?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let engine = FlutterEngine(name: "project", project: nil)
    RegisterGeneratedPlugins(registry: engine)
    pedal = PedalBridge(messenger: engine.binaryMessenger)
    ui = UIBridge(messenger: engine.binaryMessenger)
    engine.run(withEntrypoint: nil)
    self.engine = engine
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
