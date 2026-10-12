import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `MS100BTLinkApp --screenshots <dir>` renders README screenshots with demo data, then quits.
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots"), i + 1 < CommandLine.arguments.count {
            Screenshots.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Leave edit mode (0x51) and close the channel before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = LinkModel.shared, model.isOpen else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MS100BTLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = LinkModel()
    @StateObject private var midi = MIDIControl()
    @StateObject private var ai = AIAssistant()

    init() { Self.migrateSettings() }

    /// v0.1 shipped as `local.ms100btlink.app`; settings live per bundle ID, so copy them once.
    private static func migrateSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromLocalID"),
              let old = UserDefaults(suiteName: "local.ms100btlink.app") else { return }
        for key in ["midiMappings", "midiPCLoadsPatch", "midiMode", "midiMappingsV2", "editingUnlocked", "rememberUnlock"]
        where d.object(forKey: key) == nil {
            if let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
        d.set(true, forKey: "migratedFromLocalID")
    }

    var body: some Scene {
        WindowGroup("MS-100BT Link") {
            MainView()
                .environmentObject(model)
                .environmentObject(midi)
                .environmentObject(ai)
                .frame(minWidth: 1040, minHeight: 660)
                .preferredColorScheme(.dark)
                .onAppear { midi.model = model; ai.link = model }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .windowArrangement) {
                OpenDiagnosticsButton()
            }
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView().environmentObject(model)
        }
    }
}

struct OpenDiagnosticsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Diagnostics") { openWindow(id: "diagnostics") }
            .keyboardShortcut("d", modifiers: [.command, .option])
    }
}
