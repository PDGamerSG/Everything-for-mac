import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let engine = AppEngine()
do {
    try engine.start(scan: !CommandLine.arguments.contains("-no-auto-index"))
} catch {
    fputs("Everything: \(error)\n", stderr)
    exit(1)
}
signal(SIGTERM) { _ in NSApplication.shared.terminate(nil) }
signal(SIGINT) { _ in NSApplication.shared.terminate(nil) }
app.run()
