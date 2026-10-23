import AppKit
import EverythingCore

/// Main search workspace. It keeps UI state on the main actor and delegates all
/// indexing work to the shared AppEngine/SearchEngine instance.
@MainActor
public final class SearchWindowController: NSWindowController {
    private let engine: AppEngine
    private let contentController: SearchViewController

    public var searchField: NSSearchField? { contentController.searchField }
    public var tableView: NSTableView? { contentController.tableView }

    public init(engine: AppEngine) {
        self.engine = engine
        self.contentController = SearchViewController(engine: engine)
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Everything"
        window.minSize = NSSize(width: 640, height: 360)
        window.contentViewController = contentController
        window.center()
        self.window = window
    }

    public override func showWindow(_ sender: Any?) {
        if window == nil { loadWindow() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func setSearch(_ text: String) { contentController.setSearch(text) }
}

@MainActor
private final class SearchViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let engine: AppEngine
    let searchField = NSSearchField()
    let tableView = NSTableView()
    private let statusField = NSTextField(labelWithString: "Ready")
    private let scrollView = NSScrollView()
    private var result: ResultSet?
    private var querySerial = 0
    private var pendingSearch: DispatchWorkItem?

    init(engine: AppEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "Search Everything"
        searchField.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusField.font = NSFont.systemFont(ofSize: 12)
        statusField.textColor = .secondaryLabelColor
        statusField.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(statusField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.heightAnchor.constraint(equalToConstant: 34),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: statusField.topAnchor, constant: -8),
            statusField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            statusField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            statusField.heightAnchor.constraint(equalToConstant: 18)
        ])
        view = root
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 10, height: 0)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection(_:))
        let columns: [(String, String, CGFloat)] = [("name", "Name", 300), ("path", "Path", 360), ("size", "Size", 100), ("modified", "Date Modified", 170)]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width; column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            tableView.addTableColumn(column)
        }
    }

    func controlTextDidChange(_ notification: Notification) { scheduleSearch() }
    func setSearch(_ text: String) { searchField.stringValue = text; performSearch() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { performSearch(); return true }
        return false
    }

    private func scheduleSearch() {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in DispatchQueue.main.async { self?.performSearch() } }
        pendingSearch = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func performSearch() {
        querySerial += 1
        let serial = querySerial
        let text = searchField.stringValue
        var request = QueryRequest(text: text)
        request.defaults = MatchDefaults()
        request.sort = [SortKey("name")]
        statusField.stringValue = "Searching…"
        let search = engine.search
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = search.search(request)
            DispatchQueue.main.async {
                guard let self, serial == self.querySerial else { return }
                self.result = result
                self.tableView.reloadData()
                self.statusField.stringValue = "\(result.totalBeforeLimit) results  ·  \(result.fileCount) files  ·  \(result.folderCount) folders  ·  \(Int(result.seconds * 1000)) ms"
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { result?.ids.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let result, row < result.ids.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let id = result.ids[row]
        let store = result.context.store
        let text: String
        switch identifier {
        case "name": text = store.name(id)
        case "path": text = result.parentPath(id)
        case "size": text = store.isFolder(id) && !store.trackFolderSize ? "" : SizeFormat.format(store.size(id), standard: .jedec, mode: .auto)
        case "modified": text = DateFormat.format(store.dateModified(id), style: .iso8601)
        default: text = ""
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingMiddle
        cell.font = NSFont.systemFont(ofSize: 13)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let result, tableView.selectedRow >= 0, tableView.selectedRow < result.ids.count else { return }
        statusField.stringValue = result.fullPath(result.ids[tableView.selectedRow])
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        let column = descriptor.key ?? "name"
        var request = QueryRequest(text: searchField.stringValue)
        request.sort = [SortKey(column, ascending: descriptor.ascending)]
        let search = engine.search
        let serial = querySerial + 1
        querySerial = serial
        statusField.stringValue = "Searching…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = search.search(request)
            DispatchQueue.main.async {
                guard let self, serial == self.querySerial else { return }
                self.result = result; tableView.reloadData()
                self.statusField.stringValue = "\(result.totalBeforeLimit) results  ·  \(result.fileCount) files  ·  \(result.folderCount) folders  ·  \(Int(result.seconds * 1000)) ms"
            }
        }
    }

    @objc func openSelection(_ sender: Any?) {
        guard let result, tableView.clickedRow >= 0, tableView.clickedRow < result.ids.count else { return }
        let path = result.fullPath(result.ids[tableView.clickedRow])
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        _ = engine.runHistory.increment(path)
    }
}
