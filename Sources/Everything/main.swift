import AppKit
import Foundation

@MainActor
final class EverythingAppDelegate: NSObject, NSApplicationDelegate {
    let engine: AppEngine
    let windowController: SearchWindowController
    let showWindow: Bool
    init(engine: AppEngine, showWindow: Bool) {
        self.engine = engine; self.windowController = SearchWindowController(engine: engine); self.showWindow = showWindow
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if showWindow { windowController.showWindow(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let engine = AppEngine()
do {
    try engine.start(scan: !CommandLine.arguments.contains("-no-auto-index"))
} catch {
    fputs("Everything: \(error)\n", stderr)
    exit(1)
}
let appDelegate = MainActor.assumeIsolated { EverythingAppDelegate(engine: engine, showWindow: !CommandLine.arguments.contains("-startup")) }
app.delegate = appDelegate
app.setActivationPolicy(CommandLine.arguments.contains("-startup") ? .accessory : .regular)
signal(SIGTERM) { _ in NSApplication.shared.terminate(nil) }
signal(SIGINT) { _ in NSApplication.shared.terminate(nil) }
app.run()
