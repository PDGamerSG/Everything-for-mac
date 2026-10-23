import AppKit
import Foundation
import EverythingCore
import EverythingIPC

@MainActor
final class EverythingAppDelegate: NSObject, NSApplicationDelegate {
    let engine: AppEngine
    let windowController: SearchWindowController
    let showWindow: Bool
    private var menuController: MainMenuController!
    init(engine: AppEngine, showWindow: Bool) {
        self.engine = engine; self.windowController = SearchWindowController(engine: engine); self.showWindow = showWindow
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MainActor.assumeIsolated { MainMenuController(engine: engine, primaryWindow: windowController) }
        menuController.install()
        if showWindow { windowController.showWindow(nil) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "es" {
                let query = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                windowController.showWindow(nil)
                windowController.setSearch(query.removingPercentEncoding ?? query)
            } else if url.pathExtension.lowercased() == "efu" {
                if let list = try? FileList.read(url) {
                    _ = list.load(into: engine.index, label: url.deletingPathExtension().lastPathComponent)
                    try? engine.save()
                    windowController.showWindow(nil)
                }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { engine.stop() }
}

let app = NSApplication.shared
let commandLine: AppCommandLine
do {
    commandLine = try AppCommandLine.parse(CommandLine.arguments)
    if commandLine.help { print("Usage: Everything [-search text] [-startup] [-no-window] [-no-auto-index] [-rescan|-rescan-all] [-save] [-exit] [-toggle-window] [-instance name] [-url es:query]"); exit(0) }
    if commandLine.version { print(everythingVersion); exit(0) }
    AppPaths.instanceName = commandLine.instance
} catch {
    fputs("Everything: \(error)\n", stderr)
    exit(2)
}
let instanceRunning = IPCClient.isRunning(path: SocketPath.path(instance: commandLine.instance))
if instanceRunning {
    let forwarded: IPCRequest?
    if commandLine.exit {
        forwarded = IPCRequest(kind: .exit)
    } else if let search = commandLine.search {
        var request = IPCRequest(kind: .command); request.args = ["search", search]; forwarded = request
    } else if commandLine.toggle {
        var request = IPCRequest(kind: .command); request.args = ["toggle"]; forwarded = request
    } else if commandLine.save {
        forwarded = IPCRequest(kind: .saveDB)
    } else if commandLine.rescan || commandLine.rescanAll {
        forwarded = IPCRequest(kind: .rescanAll)
    } else {
        forwarded = nil
    }
    if let forwarded { _ = try? IPCClient(instance: commandLine.instance).send(forwarded) }
    exit(0)
}
if commandLine.exit { exit(0) }
let engine = AppEngine()
do {
    try engine.start(scan: !commandLine.noAutoIndex)
    if commandLine.rescan || commandLine.rescanAll { engine.rebuild() }
    if commandLine.save { try engine.save() }
} catch {
    fputs("Everything: \(error)\n", stderr)
    exit(1)
}
engine.service.onExit = { [weak engine] in
    engine?.stop()
    NSApp.terminate(nil)
}
let appDelegate = MainActor.assumeIsolated { EverythingAppDelegate(engine: engine, showWindow: !commandLine.startup && !commandLine.noWindow) }
if let search = commandLine.search { MainActor.assumeIsolated { appDelegate.windowController.setSearch(search) } }
engine.service.onCommand = { args in
    guard let command = args.first?.lowercased() else { return .failure("missing command") }
    Task { @MainActor in
        switch command {
        case "search":
            appDelegate.windowController.showWindow(nil)
            if args.count > 1 { appDelegate.windowController.setSearch(args.dropFirst().joined(separator: " ")) }
        case "toggle":
            if appDelegate.windowController.window?.isVisible == true { appDelegate.windowController.close() }
            else { appDelegate.windowController.showWindow(nil) }
        default: break
        }
    }
    return .value(true)
}
app.delegate = appDelegate
app.setActivationPolicy(commandLine.startup || commandLine.noWindow ? .accessory : .regular)
signal(SIGTERM) { _ in NSApplication.shared.terminate(nil) }
signal(SIGINT) { _ in NSApplication.shared.terminate(nil) }
app.run()
