# Everything for Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native macOS re-implementation of voidtools Everything 1.5: instant filename search over a persistent full-volume index with Everything's query language, UI, servers, IPC, `es` CLI and SDK.

**Architecture:** Swift package with a pure-Swift core (`EverythingCore`: columnar index, getattrlistbulk scanner, FSEvents monitor, DB, query parser/matcher, search engine), an IPC layer (`EverythingIPC`: JSON over Unix socket), servers (`EverythingServers`: HTTP, ETP/FTP, network index), an AppKit app (`Everything`), the `es` CLI, and a C-ABI SDK dylib. Build with `swift build`; bundle `.app` with `scripts/bundle.sh`.

**Tech Stack:** Swift 6.4 (Swift 5 language mode for AppKit ergonomics), Foundation, AppKit, Quartz (QLPreviewView), CoreServices (FSEvents, MDItem), Network.framework, Carbon (hotkeys), ServiceManagement, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-23-everything-for-mac-design.md`

## Global Constraints

- macOS 14+ deployment target; builds with Command Line Tools only (`swift build`, no `xcodebuild`).
- No third-party dependencies.
- Settings directory: `~/Library/Application Support/Everything/`; INI keys follow Windows Everything names where applicable.
- Query syntax must match the spec §3.3 names exactly (dashes optional, `no-` negation).
- Every task ends with `swift build` + `swift test --filter <target>` green and a commit.

---

## File structure

```
Package.swift
Sources/EverythingCore/
  Index/ItemStore.swift         columnar arrays, insert/remove/rename, path materialization
  Index/Index.swift             volumes/roots registry, lookup by path, hierarchy queries
  Index/ExtensionTable.swift
  Index/FastSort.swift          permutation caches
  Index/IndexDB.swift           binary persistence
  Scan/VolumeScanner.swift      getattrlistbulk walk
  Scan/ChangeMonitor.swift      FSEvents stream + apply changes
  Scan/IndexJournal.swift       journal ring + recent changes
  Scan/Volumes.swift            mounted volume discovery, exclusions
  Query/Lexer.swift             tokens: text, quotes, operators, entities
  Query/Parser.swift            AST (Term, Group, And, Or, Not), modifiers & functions
  Query/Values.swift            size/date/duration/number/range parsing
  Query/TextMatcher.swift       case/diacritics/wholeword/prefix/suffix/wildcard/regex/pinyin/soundex
  Query/Functions.swift         function registry → Predicate
  Query/Macros.swift
  Search/Predicate.swift        compiled predicate tree, cost estimate
  Search/SearchEngine.swift     parallel evaluation, sorting, live updates
  Search/ResultSet.swift
  Search/Sorting.swift
  Search/Duplicates.swift
  Properties/PropertyReader.swift  stat/MDItem/content hashes with cache
  Properties/Property.swift     property catalogue (name, aliases, type, column title)
  Properties/ContentSearch.swift
  Lists/FileList.swift          EFU read/write; txt/csv import
  Lists/Export.swift            csv/tsv/txt/efu/json/m3u/m3u8
  State/Settings.swift          INI model + defaults
  State/Filters.swift           Filters.csv
  State/Bookmarks.swift
  State/Omissions.swift
  State/History.swift           search + run history
  State/UndoLog.swift           rename/move/trash undo
  Util/INI.swift, CSV.swift, Paths.swift, SizeFormat.swift, DateFormat.swift, Soundex.swift, Pinyin.swift, Wildcard.swift, Hashes.swift
Sources/EverythingIPC/
  Protocol.swift                request/response Codable types
  IPCServer.swift               Unix socket server (NWListener) dispatching to a QueryService
  IPCClient.swift
  SocketPath.swift
Sources/EverythingServers/
  HTTP/HTTPServer.swift, HTTPRequest.swift, HTTPResponse.swift, WebUI.swift, JSONAPI.swift
  ETP/FTPServer.swift, FTPSession.swift, ETPExtension.swift, ETPClient.swift
  NetIndex/NetIndexServer.swift, NetIndexClient.swift
Sources/Everything/            (app)
  main.swift, AppDelegate.swift, CommandLine.swift
  Engine/AppEngine.swift        owns Index, monitor, settings, history, servers, IPC
  Windows/SearchWindowController.swift, SearchTabState.swift, ResultsTableController.swift, ThumbnailsController.swift, StatusBarView.swift, SearchFieldController.swift, SidebarControllers.swift, PreviewPane.swift
  Menus/MainMenu.swift, ContextMenu.swift, Commands.swift
  Dialogs/OptionsWindow.swift (+ one file per tab), AdvancedSearch.swift, AdvancedRename.swift, OrganizeFilters.swift, OrganizeBookmarks.swift, OrganizeOmissions.swift, FileListEditor.swift, IndexJournalWindow.swift, UndoHistoryWindow.swift, ExportDialog.swift, FindDuplicates.swift, AboutWindow.swift, StatisticsWindow.swift, ConnectETP.swift, ImportExportSettings.swift, ConsoleWindow.swift
  System/StatusItem.swift, Hotkeys.swift, LoginItem.swift, Services.swift, URLScheme.swift, FullDiskAccess.swift
  Resources/Info.plist, Everything.icns, help/*.html, http/*.html,css,js
Sources/es/main.swift (+ Options.swift, Output.swift)
Sources/EverythingSDK/SDK.swift, include/Everything.h
Tests/EverythingCoreTests/*, Tests/EverythingIPCTests/*, Tests/EverythingServersTests/*
scripts/bundle.sh, scripts/run-app.sh, scripts/uitest.sh
```

---

### Task 1: Package skeleton, INI/CSV utils, Settings model

**Files:** `Package.swift`, `Sources/EverythingCore/Util/INI.swift`, `Util/CSV.swift`, `State/Settings.swift`, `Tests/EverythingCoreTests/INITests.swift`, `SettingsTests.swift`.

**Produces:** `struct INIFile { subscript(key) -> String?; func bool/int/string(_:default:); mutating set; static func load(url); func write(to:) }`, `struct CSVTable { headers; rows; static parse(String); render() }`, `final class Settings: @unchecked Sendable` with typed accessors for every option in spec §3.5 (names in INI = snake_case Windows keys, e.g. `match_case`, `search_as_you_type`, `search_delay`, `run_in_background`, `show_tray_icon`, `http_server_enabled`, `http_server_port`, `index_file_size`, `index_date_created`, `exclude_folders`, …) and `static let defaults`.

- [ ] Tests: INI round-trip preserves unknown keys; CSV quoting (`"a,""b"""`); Settings default values; Settings load/save.
- [ ] Commit `feat(core): package skeleton, INI/CSV, settings`.

### Task 2: ItemStore + Index + ExtensionTable

**Files:** `Index/ItemStore.swift`, `Index/Index.swift`, `Index/ExtensionTable.swift`, `Util/Paths.swift`, tests `ItemStoreTests.swift`.

**Produces:**
```swift
public typealias ItemID = Int32
public struct ItemFlags: OptionSet { folder, hidden, symlink, package, locked, compressed, readonly, root, fileList, offline, systemProtected, executable, alias }
public struct ItemRecord { name, parent: ItemID, flags, size: UInt64, dateModified/Created/Accessed/Changed: Int64 (ns epoch, 0 = unknown), inode: UInt64, extID: UInt16 }
public final class ItemStore {
  var count: Int
  func add(_ r: ItemRecord) -> ItemID
  func remove(_ id: ItemID)                // recursive for folders
  func rename(_ id: ItemID, to name: String)
  func move(_ id: ItemID, toParent: ItemID)
  func update(_ id: ItemID, size:dates:flags:)
  func name(_ id) -> Substring (UTF8), lowerName(_ id), fullPath(_ id) -> String, path(_ id) -> String
  func parent(_ id), children(of:) -> [ItemID], isFolder(_ id)
  func find(path: String) -> ItemID?
  func child(of parent: ItemID, named: String) -> ItemID?
  func depth(_ id) -> Int, extensionName(_ id) -> String, stem(_ id) -> String
  func forEachAlive(chunk: Int, _ body: (Range<Int>) -> Void)   // parallel-friendly
  var generation: UInt64                                     // bumped on change
}
public final class Index { roots: [Root]; store: ItemStore; func addRoot(kind: volume/folder/fileList, path:, uuid:) ; lookup(path); lock for readers/writer }
```
Name blob with tombstones + compaction when garbage > 25%.

- [ ] Tests: add/find/fullPath; rename/move updates descendants' paths; remove folder removes subtree; extension table dedupes; compaction keeps IDs stable (IDs are stable slots).
- [ ] Commit.

### Task 3: IndexDB persistence

**Files:** `Index/IndexDB.swift`, tests `IndexDBTests.swift`.

**Produces:** `IndexDB.save(index, to: URL) throws`, `IndexDB.load(from: URL) throws -> Index` with header `EVTM` v1, roots table (kind, path, uuid, lastEventID: UInt64, scanDate), column blobs, CRC32 trailer. Atomic write via temp + `rename`.

- [ ] Tests: round-trip 100k synthetic items identical; corrupted CRC → throws; version mismatch → throws.
- [ ] Commit.

### Task 4: VolumeScanner (getattrlistbulk) + Volumes discovery + exclusions

**Files:** `Scan/Volumes.swift`, `Scan/VolumeScanner.swift`, `State/ExcludeRules.swift`, tests `ScannerTests.swift` (fixture tree generator in `Tests/EverythingCoreTests/Fixtures.swift`).

**Produces:** `Volumes.mounted() -> [VolumeInfo{ name, mountPoint, uuid, fsType, isRemovable, isNetwork, isRoot, capacity }]`, `ExcludeRules { excludeHidden, excludeSystem, excludeFolders:[Pattern], excludeFiles, includeOnlyFiles; func allows(path:name:isFolder:isHidden) }`, `VolumeScanner.scan(root: URL, rules:, into: ItemStore, parent: ItemID, progress: (Int)->Void, cancel: () -> Bool) -> ScanStats`. Parallel across second-level directories with a semaphore (ncpu*2). Skips mount points of other volumes (compare `st_dev`), `/System/Volumes/Data` when scanning `/`, `/dev`, `.fseventsd`, `.Spotlight-V100`, `.DocumentRevisions-V100`, `.TemporaryItems`, `.Trashes`, `/private/var/vm`, `/System/Volumes/{VM,Preboot,Update,xarts,iSCPreboot,Hardware}`, `/Volumes/*` symlink to `/`.

- [ ] Tests: fixture tree (unicode names, hidden, symlink, nested 8 deep, 20k files) scanned → counts match `find`; exclude rules honored; symlink not followed; st_dev boundary not crossed.
- [ ] Commit.

### Task 5: Query lexer/parser/values

**Files:** `Query/Lexer.swift`, `Query/Parser.swift`, `Query/Values.swift`, `Query/AST.swift`, tests `ParserTests.swift`, `ValuesTests.swift`.

**Produces:**
```swift
public indirect enum QueryNode { case and([QueryNode]), or([QueryNode]), not(QueryNode), term(Term), empty }
public struct Term { modifiers: ModifierSet; function: String?; value: String; isQuoted: Bool; literalRest: Bool }
public struct ModifierSet { case: Bool?, diacritics: Bool?, wholeWords: Bool?, path: Bool?, prefix: Bool?, suffix: Bool?, ignorePunct: Bool?, ignoreWS: Bool?, regex: Bool?, wildcards: Bool?(+extended), whole, startWith, endWith, fileOnly, folderOnly, len, toNumber, toInteger, toString, hexToNumber, soundex, pinyin(mode), allStrings, multiString, binary, hex, eachLine, dotAll, multiLine, ungreedy, global, noHighlight, fromDisk, noReorder, searchCurrent, omissions: Bool?, tempOmissions: Bool?, starAll, metric, andFilter/orFilter, menuBreak, menuSeparator, builtin(::), globalPrefix(?) }
public struct ParseOptions { orPrecedence: Bool = true; literalOperators: Bool; replaceBackslashes: Bool; defaults: MatchDefaults }
public func parseQuery(_ s: String, options:) -> ParsedQuery { root: QueryNode; globalModifiers; uiDirectives: [UIDirective] (sort:, columns:, layout:, count:, maxThreads:, dupe mode...) }
Values: parseSize("10mb..50mb", standard:) -> NumRange; parseDate("2026-09", "today", "7days", ">2022", "2025-07-01..2026-06-30") -> DateRange; parseDuration; parseNumberExpr("<=5"); parseList("a;b;c")
```
Entities, quotes, `< >` groups, `|`, `!`, `no-` prefix, dash-insensitivity, `*:` literal suffix, `::`, `?`.

- [ ] Tests (table-driven, ≥80 cases): `abc 123`, `abc|123`, `!abc`, `<a b>|c`, `"a b"`, `&quot:x`, `case:README`, `regex:^foo.*\.txt$`, `ext:cpp;h`, `size:>1gb`, `dm:today`, `date-modified:2026-09-04`, `dmyear:>2022`, `datemodified:` without dash, `nocase:x`, `regex*:a|b`, `?case: a b`, `wfn:*.txt`, `folder: !empty:`, precedence AND/OR both ways, literal operators `a AND b`, `path:"c:\program files\"` backslashes normalized.
- [ ] Commit.

### Task 6: TextMatcher (all match modes) + Wildcard/Soundex/Pinyin

**Files:** `Query/TextMatcher.swift`, `Util/Wildcard.swift`, `Util/Soundex.swift`, `Util/Pinyin.swift`, tests `MatcherTests.swift`.

**Produces:** `struct TextMatcher { init(pattern: String, mode: MatchMode) ; func matches(_ s: Substring/UTF8 bytes) -> Bool; func ranges(in:) -> [Range<Int>] }` with fast paths: ASCII lowercase `memmem` on folded blob; diacritic folding via `String.folding(options:)` precomputed per name when `diacritics=false`; whole-word boundaries; prefix/suffix word boundaries; wildcards compiled to a NFA (supports `*`, `?`, `**`, `#`, `[a-z]`, `[!a-z]`, `\` escape under extended); regex via NSRegularExpression with flags; soundex; pinyin via CFStringTransform; `len:` numeric on UTF-16 count.

- [ ] Tests: 60+ cases incl. `spider-man` with ignorepunct, `spider man` with ignorews, café/cafe diacritics, whole word `cat` vs `cats`, prefix `ab` matches `abc def` not `xab`, `*.txt` whole filename, `**` across separators when path, regex anchors, soundex Robert/Rupert, pinyin `中文` ↔ `zhongwen`/`zw`.
- [ ] Commit.

### Task 7: Predicates, Functions registry, Macros, Properties catalogue

**Files:** `Search/Predicate.swift`, `Query/Functions.swift`, `Query/Macros.swift`, `Properties/Property.swift`, `Properties/PropertyReader.swift`, `Properties/ContentSearch.swift`, `Util/Hashes.swift`, tests `FunctionsTests.swift`, `PropertyReaderTests.swift`.

**Produces:** `protocol Predicate { var cost: Int; func eval(_ ctx: EvalContext, _ id: ItemID) -> Bool }`, `EvalContext { store, index, now, settings, propertyReader, regexCaptures }`, `compile(ParsedQuery, env: CompileEnv{filters, bookmarks, macros, defaults, currentFileList}) -> CompiledQuery { predicate, directives, highlighter }`. `Functions.registry: [String: FunctionSpec{aliases, valueKind, make(Term)->Predicate}]` covering every function in spec §3.3. `PropertyReader.value(_ prop: Property, for path: String) -> PropertyValue?` (stat for size-on-disk/owner/hardlinks; `MDItemCreate` attributes map; codesign authority via `SecStaticCode`; archive listing via `/usr/bin/zipinfo`-free zip central directory parser + tar header parse; email headers parse; `.webloc` plist; alias/symlink target), LRU cache 50k entries. `ContentSearch.matches(path:, matcher:, encoding:, limitBytes:)` and hashes (CRC32, CRC64-ECMA, MD5/SHA1/SHA256 via CommonCrypto) streaming.

- [ ] Tests: each function family on an in-memory store (size ranges, ext lists, date parts, parent/ancestor/child/descendant/sibling, counts, depth, empty, attr letters, dupe/unique/distinct, regmatch capture, count:, sort: directive extraction); PropertyReader on fixture png (dimensions), m4a (duration via MDItem or AVFoundation fallback), zip (container-file-count), text (content:, md5).
- [ ] Commit.

### Task 8: SearchEngine, Sorting, FastSort, Duplicates, ResultSet, live update

**Files:** `Search/SearchEngine.swift`, `Search/Sorting.swift`, `Index/FastSort.swift`, `Search/Duplicates.swift`, `Search/ResultSet.swift`, tests `SearchEngineTests.swift`, `SortTests.swift`, benchmark test with 1M names.

**Produces:**
```swift
public struct QueryRequest { text; match: MatchDefaults; filter: Filter?; sort: [SortKey{ property, ascending }]; foldersFirst: FoldersFirst; offset; count; maxThreads; omissions: Bool; tempOmissions: Bool; fileListScope: FileList?; currentResults: ResultSet? }
public final class ResultSet { ids: [ItemID]; totalFiles; totalFolders; totalSize?; query: CompiledQuery; dupeGroups: [Range<Int>]? ; highlight(id) -> HighlightRanges }
public final class SearchEngine { init(index:, properties:, state: AppState) ; func search(_ req: QueryRequest, cancel: CancelToken) async throws -> ResultSet ; func apply(changes: [IndexChange], to rs: ResultSet) -> ResultDelta }
```
Parallel chunk evaluation via `DispatchQueue.concurrentPerform`; sort via fast-sort permutation (name, path, size, dm, dc, ext, run count, date run, rc) or materialized keys; folders-first; mix option; secondary sort name→path; `dupe:` grouping and dividers; `count:` cap; `search-current-results` refinement.

- [ ] Tests: AND/OR/NOT correctness vs brute force on 10k random names; sort orders; dupe groups; live update: add item matching query → delta.insert; rename out of match → delta.remove; 1M-name benchmark asserts substring search < 150 ms on CI machine (log timing).
- [ ] Commit.

### Task 9: ChangeMonitor (FSEvents), IndexJournal, RecentChanges, fast rescan

**Files:** `Scan/ChangeMonitor.swift`, `Scan/IndexJournal.swift`, `Scan/Rescan.swift`, tests `MonitorTests.swift` (integration, uses temp dir).

**Produces:** `final class ChangeMonitor { init(index:, store:, journal:, settings:) ; func start(root: Root, sinceEventID: UInt64?) ; stop; pause/resume ; var onChanges: ([IndexChange]) -> Void }`, `enum IndexChange { created(ItemID), removed(ItemID, oldPath), renamed(ItemID, oldPath, newPath), moved(...), modified(ItemID), attributesChanged(ItemID) }`, `IndexJournal { entries ring (max KB), append, query(filter:action:range:), export CSV, persist Journal.db, journalID, nextChangeID }`, `Rescan.fast(root:)` comparing folder mtimes; `Rescan.full(root:)`.

- [ ] Tests: create/rename/move/delete/modify in temp dir observed and index updated within 2 s; MustScanSubDirs path rescans; journal records actions with old/new paths; restart with sinceEventID replays missed create.
- [ ] Commit.

### Task 10: File lists (EFU), Export, History, Filters, Bookmarks, Omissions, UndoLog

**Files:** `Lists/FileList.swift`, `Lists/Export.swift`, `State/Filters.swift`, `State/Bookmarks.swift`, `State/Omissions.swift`, `State/History.swift`, `State/UndoLog.swift`, `Util/SizeFormat.swift`, `Util/DateFormat.swift`, tests for each.

**Produces:** `FileList.read(url) -> FileList{ entries[FileListEntry{ path, isFolder, size, dm, dc, attrs }] }`, `.write(to:)` EFU with FILETIME dates and Windows attribute ints; txt/csv import; `Exporter.export(resultSet, format: .csv/.tsv/.txt/.efu/.json/.m3u/.m3u8, columns:, selectionOnly:, to: URL)`; `Filters` default set (Audio/Compressed/Document/Executable/Folder/Picture/Video with macOS-extended extension lists, `exe:` includes app;pkg;dmg;command;sh) + CSV persistence (`Name,Search,Macro,Case,WholeWord,Path,Diacritics,Regex,Key`); `Bookmarks` (`Name,Search,Filter,Sort,Case,WholeWord,Path,Diacritics,Regex,Key,FoldersFirst,...`); `Omissions` permanent (`Omit Results.csv`: Path,Filter,OmitFolders) + temporary set, predicate hook; `SearchHistory` (count, last date, prune by days, autocomplete prefix), `RunHistory` (per full path count + date, inc/set/get, prune); `UndoLog` entries rename/move/trash(with trash URL), `undo(entry)`.

- [ ] Tests: EFU round-trip incl. FILETIME conversion (1601 epoch) and relative paths; export formats exact bytes for a 2-row set; filters CSV round-trip; omissions filter paths and extensions; history prune; undo rename reverts file in temp dir.
- [ ] Commit.

### Task 11: IPC protocol + server + client

**Files:** `Sources/EverythingIPC/*`, tests `IPCTests.swift`.

**Produces:** `enum IPCRequest: Codable { query(QueryParams), version, isDBLoaded, rebuildDB, saveDB, updateAllFolderIndexes, exit, runCountGet(path), runCountSet(path,count), runCountInc(path), journal(JournalParams), folderSize(path), command([String]), subscribe(QueryParams) }`, `IPCResponse`, `QueryParams { search, matchCase, matchWholeWord, matchPath, matchDiacritics, prefix, suffix, ignorePunctuation, ignoreWhitespace, regex, sort, ascending, offset, count, requestFlags: [String] (name,path,fullPath,ext,size,dateModified,dateCreated,dateAccessed,attributes,runCount,dateRun,dateRecentlyChanged,fileListFilename,highlightedName,highlightedPath,highlightedFullPath,+property names) }`, `QueryResult { totalFiles, totalFolders, totalResults, items: [IPCItem{ type, name, path, fullPath?, size?, dates?, attrs?, runCount?, properties: [String:String] }] }`. `protocol QueryService { func handle(_ req: IPCRequest) async -> IPCResponse }`. `IPCServer(path:, service:)` via `NWListener(using: .tcp, on: unix path)` — if NWListener lacks Unix socket support on this OS, fall back to POSIX `socket(AF_UNIX)` + `DispatchSource`. `IPCClient(instance:) { func send(_:) async throws -> IPCResponse ; func isRunning() -> Bool }`. Socket path: `~/Library/Application Support/Everything/ipc[-instance].sock`.

- [ ] Tests: echo service round-trip; 2 MB response framing; client timeout when no server.
- [ ] Commit.

### Task 12: `es` CLI

**Files:** `Sources/es/main.swift`, `Options.swift`, `Output.swift`, tests `ESTests.swift` (tests Output formatting + option parsing; integration test spawns in-process `IPCServer` with fake service).

Implements the full documented switch set (spec §3.6). Output formats csv/efu/json/m3u/m3u8/tsv/txt with header/footer, size/date formats (0–6), highlight (ANSI), viewport, column widths/colors, `-pause`, exit codes (0 ok, 1 error, 2 bad arg, 3 no Everything, 9 no results with flag). `-save-settings` writes `es.ini`. When no app running and `-timeout` elapsed → load `Everything.db` read-only and search in-process (so `es` works standalone).

- [ ] Tests: option parse table; csv quoting; json shape; `-no-result-error` exit 9; standalone DB mode with temp db.
- [ ] Commit.

### Task 13: SDK dylib + header

**Files:** `Sources/EverythingSDK/SDK.swift`, `Sources/EverythingSDK/include/Everything.h`, `Tests/EverythingSDKTests` (C ABI called from Swift test via dlopen).

`@_cdecl` for every function in spec §3.6 with the Windows signatures (BOOL=Int32, DWORD=UInt32, LPCWSTR=UnsafePointer<UInt16>, UTF-8 "A" variants). Request flags/sort/error constants in header identical to Windows values.

- [ ] Tests: Everything_SetSearchW + Everything_QueryW against in-process fake service; result accessors; error code when not running.
- [ ] Commit.

### Task 14: HTTP server + web UI + JSON API

**Files:** `Sources/EverythingServers/HTTP/*`, `Sources/Everything/Resources/http/{index.html,everything.css,everything.js}`, tests `HTTPTests.swift`.

HTTP/1.1 parser (request line, headers, keep-alive, Range for downloads), Basic auth, bind/port, logging with trim, custom page folder override, allow-download flag. Query params per spec; JSON exactly `{"totalResults":N,"results":[...]}`. Web UI: search box, options checkboxes, result table with sort links, paging, folder browse (click folder → `path:` search), file download links, drive list at root. Directory listing for `/<path>/`.

- [ ] Tests: JSON API over loopback; auth 401; download disabled → 403; paging; sort param; path traversal rejected.
- [ ] Commit.

### Task 15: ETP/FTP server + ETP client

**Files:** `Sources/EverythingServers/ETP/*`, tests `ETPTests.swift`.

Control connection commands listed in spec §3.7, PASV/EPSV data connections, LIST (Unix `ls -l` format), MLSD, RETR with download flag, `FEAT` advertising `EVERYTHING`, `SITE EVERYTHING ...` state machine and QUERY response. `ETPClient` for Tools → Connect: performs SITE EVERYTHING SEARCH/QUERY and returns `QueryResult`-like rows; link types.

- [ ] Tests: scripted session via loopback TCP: USER/PASS/FEAT/SITE EVERYTHING SEARCH x/QUERY → results; LIST of `/`; RETR a fixture file; download disabled → 550.
- [ ] Commit.

### Task 16: Network index (Everything Server) server + client

**Files:** `Sources/EverythingServers/NetIndex/*`, tests `NetIndexTests.swift`.

TCP 14630, HMAC-SHA256 challenge auth with per-user password + include-only path prefixes, `SNAPSHOT` (streams IndexDB bytes filtered to allowed roots) and `JOURNAL since id` + `WATCH` push; client mirrors into a `Root(kind: .network)` with path remap (“Mount as”), applies journal deltas.

- [ ] Tests: server/client sync in-process: snapshot then create a file → client index contains it after journal push; wrong password rejected; include-only hides paths.
- [ ] Commit.

### Task 17: App engine + command line + bundle script + launch smoke

**Files:** `Sources/Everything/main.swift`, `AppDelegate.swift`, `CommandLine.swift`, `Engine/AppEngine.swift`, `System/FullDiskAccess.swift`, `Resources/Info.plist`, `scripts/bundle.sh`, `scripts/run-app.sh`.

AppEngine: load settings → load DB (or scan all volumes per settings, in background with progress) → start monitors → start IPC → start enabled servers → autosave timer → save on quit. CommandLine parses `Everything.exe`-style options; if another instance is running, forwards `command` via IPC and exits (unless `-no-first-instance` semantics). `bundle.sh` builds release, assembles `dist/Everything.app` (Contents/MacOS/Everything, es, libEverythingSDK.dylib, Resources, Info.plist with CFBundleURLTypes `es`, CFBundleDocumentTypes `.efu`, NSServices, LSUIElement=false, NSAppleEventsUsageDescription), ad-hoc codesign.

- [ ] Verify: `scripts/run-app.sh -startup` launches without a window, builds DB for `/`, logs timing, IPC `version` responds, `es -get-result-count ""` returns count.
- [ ] Commit.

### Task 18: Search window: search field, results table, status bar, tabs, menus, context menu

**Files:** `Windows/*`, `Menus/*`.

NSTableView with view-based cells, lazy icon loading (NSWorkspace icon cache), highlight attributed strings, columns per spec with header menu, sorting, jump-to typing, Enter opens / Cmd+Enter reveals / Option+Enter Get Info, multi-select, drag source, Delete → Trash, Shift+Delete → permanent (confirm), F2 rename inline, search-as-you-type with delay, history autocomplete, filter bar, status bar badges with double-click toggles, tabs via NSWindow.tabbingMode + per-tab `SearchTabState`, back/forward/home history, all menus with key equivalents from spec, context menu with customizable commands, Open With submenu via `NSWorkspace.urlsForApplications(toOpen:)`, Quick Look panel, Services/Share.

- [ ] Verify via `scripts/uitest.sh`: launches app, uses `osascript` + Accessibility to type a query in the search field, reads result count from status bar, screenshots `dist/screenshots/*.png`.
- [ ] Commit.

### Task 19: Views: thumbnails, preview pane, sidebars (folders/filters/bookmarks), fonts/colors/theme, zoom, fullscreen, on-top

**Files:** `Windows/ThumbnailsController.swift`, `PreviewPane.swift`, `SidebarControllers.swift`, `Appearance.swift`.

- [ ] Verify screenshots for each view; theme switch; preview shows image.
- [ ] Commit.

### Task 20: Dialogs: Options (all tabs), Advanced Search, Advanced Rename, Organize Filters/Bookmarks/Omissions, File List Editor, Index Journal, Undo History, Export, Find Duplicates, Statistics, Console, About, Connect ETP, Import/Export Settings

**Files:** `Dialogs/*`.

Options tabs bind to `Settings` keys; Keyboard tab edits shortcut table (scope Global/Search Edit/Result List) with conflict removal; Advanced tab lists every INI key with filter + reset. Index Journal window with action popup, search box (regex: supported), Undo/Delete/Open Path/Copy Full Path/Export. Advanced Rename modes: find/replace, change extension, regex, numbering, edit all names. Export dialog formats and columns. Find Duplicates: property list → `dupe:` search. File List Editor: table, add files/folders (open panel, drag), import, remove dupes, update from disk, save EFU.

- [ ] Verify each dialog opens via menu (uitest), settings persist to INI and reload.
- [ ] Commit.

### Task 21: System integration: menu bar extra, global hotkeys, login item, Finder service, `es:` URL scheme, EFU open, Dock drop, run-in-background, update check, keyboard shortcut customization runtime

**Files:** `System/*`.

- [ ] Verify: `open "es:foo"` sets search; `open x.efu` opens list; hotkey registered (log); status item menu items; login item toggle via `SMAppService.mainApp`.
- [ ] Commit.

### Task 22: End-to-end tests and release

- [ ] Full `swift test` green; full-volume scan benchmark logged; `es` vs app integration; HTTP via curl; ETP via `nc`; uitest screenshots; `scripts/bundle.sh` produces `dist/Everything.app`; README.md with features, install, syntax reference, keyboard shortcuts, CLI, SDK, HTTP/ETP docs, differences from Windows.
- [ ] Commit `release: Everything for Mac 1.5.0`.
