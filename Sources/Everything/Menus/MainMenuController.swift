import AppKit

@MainActor
final class MainMenuController: NSObject {
    private let engine: AppEngine
    private weak var primaryWindow: SearchWindowController?
    private var extraWindows: [SearchWindowController] = []

    init(engine: AppEngine, primaryWindow: SearchWindowController? = nil) {
        self.engine = engine
        self.primaryWindow = primaryWindow
    }

    func install() { NSApp.mainMenu = makeMenu() }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Everything")
        menu.addItem(submenu("File", [
            item("New Window", #selector(newWindow), "n"),
            item("Save Database", #selector(saveDatabase), "s"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
            item("Quit Everything", #selector(NSApplication.terminate(_:)), "q")
        ]))
        menu.addItem(submenu("Edit", [
            item("Undo", #selector(undo), "z"),
            item("Redo", #selector(redo), "Z"),
            .separator(),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Select All", #selector(NSText.selectAll(_:)), "a")
        ]))
        menu.addItem(submenu("Search", [
            item("Focus Search", #selector(focusSearch), "f"),
            item("New Search Window", #selector(newWindow), "n")
        ]))
        menu.addItem(submenu("Index", [
            item("Rescan Indexed Volumes", #selector(rescan), "r"),
            item("Save Database Now", #selector(saveDatabase), "s")
        ]))
        menu.addItem(submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        ]))
        menu.addItem(submenu("Help", [
            item("Everything for Mac on GitHub", #selector(openGitHub), "")
        ]))
        return menu
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for item in items { item.target = self; menu.addItem(item) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command] }
        return item
    }

    @objc private func newWindow() {
        let controller = SearchWindowController(engine: engine)
        extraWindows.append(controller)
        controller.showWindow(nil)
    }

    @objc private func focusSearch() {
        let controller = primaryWindow ?? SearchWindowController(engine: engine)
        if primaryWindow == nil { primaryWindow = controller }
        controller.showWindow(nil)
        if let field = controller.searchField { controller.window?.makeFirstResponder(field) }
    }

    @objc private func saveDatabase() { try? engine.save() }
    @objc private func rescan() { engine.rebuild() }
    @objc private func undo() { NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: self) }
    @objc private func redo() { NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: self) }
    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/PDGamerSG/Everything-for-mac")!)
    }
}
