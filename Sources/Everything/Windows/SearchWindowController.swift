import AppKit
import EverythingCore

/// Main search workspace. It keeps UI state on the main actor and delegates all
/// indexing work to the shared AppEngine/SearchEngine instance.
@MainActor
public final class SearchWindowController: NSWindowController {
    private let engine: AppEngine
    private let contentController: SearchViewController

    /// Kept public for menu commands and clients that used the original list UI.
    public var searchField: NSSearchField? { contentController.searchField }
    /// The list remains available for compatibility; the default presentation is a grid.
    public var tableView: NSTableView? { contentController.tableView }

    public init(engine: AppEngine) {
        self.engine = engine
        self.contentController = SearchViewController(engine: engine)
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Everything"
        window.minSize = NSSize(width: 680, height: 440)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        window.contentViewController = contentController
        window.center()
        self.window = window
    }

    public override func showWindow(_ sender: Any?) {
        if window == nil { loadWindow() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        searchField?.becomeFirstResponder()
    }

    public func setSearch(_ text: String) { contentController.setSearch(text) }
}

@MainActor
private final class SearchViewController: NSViewController, NSSearchFieldDelegate,
                                          NSTableViewDataSource, NSTableViewDelegate,
                                          NSCollectionViewDataSource, NSCollectionViewDelegate {
    let engine: AppEngine
    let searchField = NSSearchField()
    let tableView = NSTableView()

    private let titleLabel = NSTextField(labelWithString: "Everything")
    private let subtitleLabel = NSTextField(labelWithString: "Fast file search")
    private let queryLabel = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "Ready")
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let modeControl = NSSegmentedControl(labels: ["Grid", "List"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let collectionView = NSCollectionView()
    private let collectionScrollView = NSScrollView()
    private let tableScrollView = NSScrollView()
    private let resultCountLabel = NSTextField(labelWithString: "")
    private var result: ResultSet?
    private var querySerial = 0
    private var pendingSearch: DispatchWorkItem?
    private var activeSearchToken: CancelToken?

    init(engine: AppEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor

        configureHeader()
        configureGrid()
        configureTable()
        configureEmptyState()

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(subtitleLabel)
        header.addSubview(modeControl)
        header.addSubview(searchField)
        header.addSubview(queryLabel)
        header.addSubview(progress)

        root.addSubview(header)
        root.addSubview(collectionScrollView)
        root.addSubview(tableScrollView)
        root.addSubview(emptyStateLabel)
        root.addSubview(statusField)
        root.addSubview(resultCountLabel)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            header.heightAnchor.constraint(equalToConstant: 112),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            subtitleLabel.lastBaselineAnchor.constraint(equalTo: titleLabel.lastBaselineAnchor),
            modeControl.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            modeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 118),
            searchField.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            searchField.heightAnchor.constraint(equalToConstant: 38),
            queryLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            queryLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -8),
            queryLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            progress.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            progress.centerYAnchor.constraint(equalTo: queryLabel.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            collectionScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            collectionScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            collectionScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            collectionScrollView.bottomAnchor.constraint(equalTo: statusField.topAnchor, constant: -10),
            tableScrollView.leadingAnchor.constraint(equalTo: collectionScrollView.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: collectionScrollView.trailingAnchor),
            tableScrollView.topAnchor.constraint(equalTo: collectionScrollView.topAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: collectionScrollView.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: collectionScrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: collectionScrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 40),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
            statusField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            statusField.trailingAnchor.constraint(lessThanOrEqualTo: resultCountLabel.leadingAnchor, constant: -12),
            statusField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            statusField.heightAnchor.constraint(equalToConstant: 18),
            resultCountLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            resultCountLabel.centerYAnchor.constraint(equalTo: statusField.centerYAnchor),
            resultCountLabel.heightAnchor.constraint(equalToConstant: 18)
        ])
        view = root
        updateVisibleMode()
    }

    private func configureHeader() {
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search files and folders…"
        searchField.font = NSFont.systemFont(ofSize: 17)
        searchField.controlSize = .large
        searchField.bezelStyle = .roundedBezel
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.toolTip = "Type a name, path, or Everything query"
        queryLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        queryLabel.textColor = .secondaryLabelColor
        queryLabel.lineBreakMode = .byTruncatingMiddle
        queryLabel.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegment = 0
        modeControl.segmentStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(viewModeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = NSFont.systemFont(ofSize: 12)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.translatesAutoresizingMaskIntoConstraints = false
        resultCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        resultCountLabel.textColor = .secondaryLabelColor
        resultCountLabel.alignment = .right
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureGrid() {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        layout.itemSize = NSSize(width: 150, height: 128)
        collectionView.collectionViewLayout = layout
        collectionView.register(SearchResultCollectionItem.self, forItemWithIdentifier: SearchResultCollectionItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [NSColor(calibratedWhite: 0.095, alpha: 1)]
        collectionView.translatesAutoresizingMaskIntoConstraints = true
        collectionView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        collectionView.autoresizingMask = [.width]
        collectionView.setAccessibilityLabel("Search results")
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(collectionDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)
        collectionScrollView.documentView = collectionView
        collectionScrollView.hasVerticalScroller = true
        collectionScrollView.autohidesScrollers = true
        collectionScrollView.drawsBackground = true
        collectionScrollView.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 1)
        collectionScrollView.borderType = .lineBorder
        collectionScrollView.scrollerStyle = .overlay
        collectionScrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 27
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 10, height: 0)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection(_:))
        tableView.setAccessibilityLabel("Search results list")
        tableView.menu = makeContextMenu()
        let columns: [(String, String, CGFloat)] = [("name", "Name", 300), ("path", "Path", 360),
                                                     ("size", "Size", 100), ("modified", "Date Modified", 170)]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            tableView.addTableColumn(column)
        }
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.borderType = .lineBorder
        tableScrollView.scrollerStyle = .overlay
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureEmptyState() {
        emptyStateLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 2
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openSelection(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelection(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Full Path", action: #selector(copyFullPath(_:)), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
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
        pendingSearch = nil
        activeSearchToken?.cancel()
        querySerial += 1
        let serial = querySerial
        let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = QueryRequest(text: text)
        request.defaults = MatchDefaults()
        request.sort = [SortKey("name")]
        request.count = 2_000
        let token = CancelToken()
        activeSearchToken = token
        let displayedQuery = text.isEmpty ? "all indexed items" : "“\(text)”"
        queryLabel.stringValue = "Query: \(displayedQuery)"
        statusField.stringValue = "Searching \(displayedQuery)…"
        resultCountLabel.stringValue = ""
        emptyStateLabel.isHidden = true
        progress.startAnimation(nil)
        let search = engine.search
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = search.search(request, cancel: token)
            DispatchQueue.main.async {
                guard let self, serial == self.querySerial else { return }
                self.activeSearchToken = nil
                self.result = result
                self.tableView.reloadData()
                self.collectionView.reloadData()
                self.progress.stopAnimation(nil)
                self.updateResultSummary(result, query: text)
            }
        }
    }

    private func updateResultSummary(_ result: ResultSet, query: String) {
        let total = result.totalBeforeLimit
        let noun = total == 1 ? "result" : "results"
        statusField.stringValue = query.isEmpty ? "Showing all indexed items" : "Results for “\(query)”"
        resultCountLabel.stringValue = "\(total.formatted()) \(noun)  ·  \(Int(result.seconds * 1000)) ms"
        if total == 0 {
            emptyStateLabel.stringValue = query.isEmpty ? "No indexed items yet\nStart a scan to populate Everything." : "No results for “\(query)”\nTry a shorter name or a different path."
            emptyStateLabel.isHidden = false
        } else { emptyStateLabel.isHidden = true }
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) { updateVisibleMode() }
    private func updateVisibleMode() {
        let isGrid = modeControl.selectedSegment == 0
        collectionScrollView.isHidden = !isGrid
        tableScrollView.isHidden = isGrid
        emptyStateLabel.isHidden = result?.totalBeforeLimit != 0
    }

    // MARK: Collection view
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { result?.ids.count ?? 0 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SearchResultCollectionItem.identifier, for: indexPath)
        guard let cell = item as? SearchResultCollectionItem, let result, indexPath.item < result.ids.count else { return item }
        let id = result.ids[indexPath.item]
        let store = result.context.store
        cell.configure(name: store.name(id), path: result.fullPath(id), isFolder: store.isFolder(id))
        return cell
    }
    func collectionViewSelectionDidChange(_ notification: Notification) {
        if let path = selectedCollectionPath() { statusField.stringValue = path }
    }
    @objc private func collectionDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        collectionView.selectItems(at: [indexPath], scrollPosition: [])
        openSelection(nil)
    }
    private func selectedCollectionPath() -> String? {
        guard let indexPath = collectionView.selectionIndexPaths.first, let result, indexPath.item < result.ids.count else { return nil }
        return result.fullPath(result.ids[indexPath.item])
    }

    // MARK: Table view compatibility
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
        var request = QueryRequest(text: searchField.stringValue)
        request.sort = [SortKey(descriptor.key ?? "name", ascending: descriptor.ascending)]
        runSearch(request)
    }
    private func runSearch(_ request: QueryRequest) {
        activeSearchToken?.cancel()
        querySerial += 1
        let serial = querySerial
        let token = CancelToken()
        activeSearchToken = token
        progress.startAnimation(nil)
        statusField.stringValue = "Searching…"
        let search = engine.search
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = search.search(request, cancel: token)
            DispatchQueue.main.async {
                guard let self, serial == self.querySerial else { return }
                self.activeSearchToken = nil
                self.result = result
                self.tableView.reloadData()
                self.collectionView.reloadData()
                self.progress.stopAnimation(nil)
                self.updateResultSummary(result, query: request.text)
            }
        }
    }

    // MARK: Actions
    @objc func openSelection(_ sender: Any?) {
        guard let path = selectedPath() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        _ = engine.runHistory.increment(path)
    }
    @objc private func revealSelection(_ sender: Any?) {
        guard let path = selectedPath() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    @objc private func copyFullPath(_ sender: Any?) {
        guard let path = selectedPath() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
    private func selectedPath() -> String? {
        if let path = selectedCollectionPath() { return path }
        guard let result else { return nil }
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < result.ids.count else { return nil }
        return result.fullPath(result.ids[row])
    }
}

@MainActor
private final class SearchResultCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SearchResultCollectionItem")
    private static let iconCache = NSCache<NSString, NSImage>()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let pathField = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 9
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.clear.cgColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameField.textColor = .labelColor
        nameField.alignment = .center
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 2
        nameField.translatesAutoresizingMaskIntoConstraints = false
        pathField.font = NSFont.systemFont(ofSize: 10)
        pathField.textColor = .tertiaryLabelColor
        pathField.alignment = .center
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(iconView)
        root.addSubview(nameField)
        root.addSubview(pathField)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 58),
            iconView.heightAnchor.constraint(equalToConstant: 58),
            nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            nameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            pathField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            pathField.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -7)
        ])
        view = root
    }

    func configure(name: String, path: String, isFolder: Bool) {
        nameField.stringValue = name
        pathField.stringValue = (path as NSString).deletingLastPathComponent
        let key = path as NSString
        let icon = Self.iconCache.object(forKey: key) ?? NSWorkspace.shared.icon(forFile: path)
        Self.iconCache.setObject(icon, forKey: key)
        iconView.image = icon
        iconView.image?.size = NSSize(width: 58, height: 58)
        view.toolTip = path
        view.setAccessibilityLabel("\(isFolder ? "Folder" : "File"): \(name)")
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    private func updateSelectionAppearance() {
        let selected = isSelected
        view.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        view.layer?.borderColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor : NSColor.clear.cgColor
    }
}
