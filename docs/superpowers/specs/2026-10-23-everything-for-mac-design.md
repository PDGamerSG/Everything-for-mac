# Everything for Mac — Design Spec

Date: 2026-10-23
Status: approved by default (non-interactive session; user directive: "work on it and don't stop until the project is complete")

## 1. Goal

Build a native macOS application that reproduces voidtools "Everything" (Windows, v1.5 feature set) end to end: instant filename search over a locally-built index of every mounted volume, with Everything's search syntax, result list, filters, bookmarks, history, file lists, duplicates, omissions, journal, HTTP/ETP servers, IPC/SDK and the `es` command-line client.

Everything is closed-source freeware. No source exists to port. This is a clean-room re-implementation from the public documentation (voidtools.com/support/everything/*), adapted to macOS conventions.

## 2. Platform constraints and assumptions

- macOS 14+ (built and tested on macOS 27 / Apple Silicon). Swift 6.4, Swift Package Manager only (no Xcode installed; `.app` bundle assembled by script).
- AppKit for the main UI (NSTableView handles millions of rows; SwiftUI `Table` does not). SwiftUI used for Options panes and small dialogs where convenient.
- Index source: there is no NTFS MFT/USN on macOS. The index is built by a parallel directory walk using `getattrlistbulk(2)` (fastest enumeration on APFS) and kept current with FSEvents (file-level events, per volume). Changes while the app is not running are recovered by FSEvents history replay from the last stored event ID; if the event ID is unavailable (volume remounted, history purged) the volume is rescanned using a "fast rescan" that compares folder modification dates.
- Full Disk Access is required to index protected locations (Mail, Messages, Safari, other users). The app detects missing access and shows a one-time prompt deep-linking to System Settings. Without it, protected folders are indexed as far as permission allows.
- Settings live in `~/Library/Application Support/Everything/` as `Everything.ini` (same key names as Windows where applicable), `Filters.csv`, `Bookmarks.csv`, `Omit Results.csv`, `Search History.csv`, `Run History.csv`, `Everything.db`, `Journal.db`.
- Windows-only concepts are mapped, not dropped: drive letters → volume names/mount points (`/`, `/Volumes/X`); backslash paths → slash paths (the parser accepts both; `replace_backslashes` option on by default); Recycle Bin → Trash; attributes → macOS flags (hidden, immutable/locked, symlink, alias, package/bundle, compressed, quarantined, executable, read-only) with Windows letters mapped where meaningful (`H`, `R`, `D`, `L`, `C`, `S` = system/SIP-protected, `A` = archive bit n/a → not set); Explorer → Finder; NTFS/ReFS/FAT tabs → "Volumes" tab; shell context menu → Finder services + "Open With".
- Plugins: no binary plugin API. The HTTP, ETP/FTP and Everything Server features that are plugins on Windows ship built in. Pinyin modifiers are implemented via CFStringTransform (Mandarin Latin). Windows Property System properties map to Spotlight `MDItem` attributes.

## 3. Architecture

Swift package `EverythingForMac` with these products:

| Target | Kind | Purpose |
|---|---|---|
| `EverythingCore` | library | Index, scanner, FSEvents monitor, DB persistence, query parser + matcher, search engine, sort, properties, file lists, history, journal, omissions, duplicates, settings model. No AppKit. |
| `EverythingIPC` | library | Wire protocol shared by app, `es`, SDK, HTTP: JSON request/response over a Unix domain socket at `~/Library/Application Support/Everything/ipc.sock` (per instance name). |
| `EverythingServers` | library | HTTP server (web UI + JSON API), ETP/FTP server, Everything Server (network index sync). Built on Network.framework (`NWListener`). |
| `Everything` | executable (app) | AppKit application: windows, tabs, menus, results, sidebars, preview, options, menu bar extra, hotkeys, services, URL scheme, EFU association, command-line options. |
| `es` | executable | Command-line client mirroring `es.exe` options; talks IPC; falls back to loading `Everything.db` read-only when the app is not running. |
| `EverythingSDK` | dynamic library + C header | `@_cdecl` exports named `Everything_SetSearch`, `Everything_Query`, … matching the Windows SDK; wraps IPC. |
| `EverythingCoreTests`, `EverythingIPCTests`, `EverythingServersTests` | tests | XCTest. |

Data flow: Scanner → Index (in memory) ⇄ DB file. FSEvents → IndexUpdater → Index + Journal → notifies SearchSessions (live result updates). UI/IPC/HTTP/ETP → SearchEngine.query(QueryRequest) → ResultSet (array of item IDs + per-request sort). Properties not in the index are read lazily from disk (stat / MDItem / content) by a PropertyReader with a bounded thread pool and cache.

### 3.1 Index data model (EverythingCore)

Compact columnar store, append-friendly, one per volume plus folder/file-list roots:

- `names: UTF8 blob`, `nameOffset[Int32]`, `nameLength[UInt16]`
- `lowerNames` folded blob (case-folded, diacritic-stripped ASCII fast path flag) for fast case-insensitive scan
- `parent[Int32]` (index of parent folder item, -1 for roots), `firstChild/nextSibling` for hierarchy functions
- `flags[UInt16]` (isFolder, hidden, symlink, package, locked, compressed, readonly, root, filelist, offline)
- `size[UInt64]`, `dateModified/dateCreated/dateAccessed/dateChanged[Int64 ns since 1970]` (optional columns per Options → Indexes)
- `extensionID[UInt16]` into an extension table (fast `ext:` and extension sort)
- `folderSize[UInt64]` (optional, index folder size)
- per-item `runCount`, `dateRun` in a separate map keyed by full path (Run History)
- `inode[UInt64]` + volume ID (for rename tracking under FSEvents, `file-id:`)
- Fast-sort caches: pre-sorted permutation arrays for name, path, size, date modified, date created, extension (built in background, invalidated on change, rebuilt lazily).

Full path is materialized by walking parents; a per-item `pathHash`-free approach keeps memory ~60 bytes/item + names. Target: 5M items < 600 MB.

DB file: `Everything.db` — header (magic `EVTM`, version), volume table (UUID, mount point, last FSEvents ID, scan time), then columnar sections, LZ4-free (plain) for load speed; written atomically (temp + rename). Autosave on change (debounced 60 s) and on quit.

### 3.2 Scanner and monitor

- `VolumeScanner`: enumerates each mounted volume (`FileManager.mountedVolumeURLs`) honoring Options → Volumes (include, include-only, exclude folders/files, exclude hidden/system). Walks with `getattrlistbulk` requesting name, objtype, size, times, flags, inode. Parallel across top-level directories with a bounded task group. Skips `/System/Volumes/*` firmlink duplicates, `/dev`, `/private/var/vm`, `.Spotlight-V100`, `.fseventsd`, Time Machine snapshots (configurable default exclude list).
- `FolderIndex`: arbitrary folders (incl. network mounts) with rescan schedule (`Update` option: never/startup/interval) and change monitoring via FSEvents or `DispatchSource` fallback.
- `FileListIndex`: EFU lists included in the index, auto-reloaded when the file changes.
- `ChangeMonitor`: one FSEventStream per volume with `kFSEventStreamCreateFlagFileEvents | UseCFTypes | WatchRoot | NoDefer`, `sinceWhen` = stored event ID. Applies create/remove/rename/modify/attribute changes; rename pairs resolved by inode. `kFSEventStreamEventFlagMustScanSubDirs` → rescan that subtree. `kFSEventStreamEventFlagHistoryDone` marks catch-up end. Each applied change appended to `IndexJournal` and `RecentChanges` (`rc:` / `date-recently-changed:`).
- Monitor pause/resume, rescan/rescan-all, force rebuild commands.

### 3.3 Query language (EverythingCore/Query)

Parser produces an AST of `Term`s combined by AND / OR / NOT / groups `< >`, honoring quotes, character entities (`&sp:`, `&vert:`, `&excl:`, `&lt:`, `&gt:`, `&quot:`, `&#n:`, `&#xn:`), precedence option (OR-before-AND default; `and-precedence:` / `or-precedence:`), literal operators option (AND/OR/NOT words), `*` suffix literal mode (`regex*:`), `::` built-in prefix, `?` global prefix, `no-` negation, optional dashes in names, `$property:` substitution.

Matching modes (modifiers, overriding window options): case, diacritics, wholeword, path/`\:`, prefix, suffix, ignorepunctuation, ignorewhitespace, regex (NSRegularExpression, PCRE-compatible subset; `dot-all:`, `multi-line:`, `ungreedy:`, `global:`, `no-fast-regex:`), wildcards (`*`, `?`, `**`, extended `#`, `[ ]`, `[! ]` under `wildcards:`; whole-filename match when wildcards present, option), `whole:`/`wfn:`, `start-with:`/`^:`, `end-with:`/`$:`, `file:`, `folder:`, `len:`, `to-number:`/`#:`, `to-integer:`, `to-string:`, `hex-to-number:`, `soundex:`, `pinyin:`/`py:`/`pyj:`/`pyq:`, `all-strings:`, `multi-string:`, `binary:`, `hex:`, `each-line:`, `no-highlight:`, `from-disk:`, `no-reorder:`, `search-current-results:`, `enable/disable-result-omissions:`, `enable/disable-temp-result-omissions:`, `star-all:`, `no-!:`, `menu-break:`, `menu-separator:`, `and-filter:`/`or-filter:`, `metric:`.

Functions implemented (value grammar: text, number with `< <= = == > >= != !`, ranges `a..b` / `a-b`, size units kb/mb/gb/tb (JEDEC/IEC/metric), dates (ISO 8601 with wildcards, locale, relative `2days`, constants today/yesterday/months/weekdays/mtd/ytd/qtd/unknown, FILETIME/Excel numbers), durations, `;` OR lists, `unknown`):

- Name/path: `name:`, `stem:`, `ext:`, `extension:`, `path:`, `full-path:`, `location:`/`loc:`, `name-length:`/`namelen:`, `full-path-length:`, `parent:`, `parent-name:`, `ancestor:`, `ancestor-name:`, `child:` (+file/folder), `child-count:` (+file/folder), `descendant:` (+file/folder), `descendant-count:`, `sibling:`, `parent-count:`/`depth:`, `empty:`, `root:`, `file:`, `folder:`, `kind:`, `type:`, `perceived-type:`, `volume-label:`, `file-id:`/`frn:`, `parent-file-id:`, `hard-link-count:`, `owner:`.
- Size/dates: `size:`, `size-on-disk:`, `date-modified:`/`dm:`, `date-created:`/`dc:`, `date-accessed:`/`da:`, `date-changed:`, `date-recently-changed:`/`rc:`, `date-run:`, `run-count:`, plus date-part variants `*-date`, `*-day`, `*-day-of-week`/`*dow`, `*-hour`, `*-month`, `*-time`, `*-year` for modified/created/accessed.
- Attributes: `attributes:`/`attr:`/`attrib:` with letters and hex; `ancestor-attributes:`, `child-attributes:`.
- Duplicates: `dupe:`, `unique:`, `distinct:`, `distinct-sort:`, `dupe-count:`, `dupe-from:`, `dupe-min:`, `dupe-max:`.
- Content (slow, from disk, bounded by `content-size-limit`): `content:`, `ansi-content:`, `utf8-content:`, `utf16-content:`, `binary:`, `hex:`, `crc32:`/`crc:`, `crc64:`, `md5:`, `sha1:`, `sha256:`, `character-encoding:`, `content-type:`, `file-signature:`, `first-bytes:`, `last-bytes:`, `system-index:`/`si:` (Spotlight `NSMetadataQuery`).
- Properties from Spotlight (`from-disk` by default, indexable via Options → Properties): image `width:`, `height:`, `dimensions:`, `bit-depth:`, `aspect-ratio:`, `date-taken:`, `camera-maker:`, `camera-model:`, `f-stop:`, `exposure-time:`, `iso-speed:`, `focal-length:`, `latitude:`, `longitude:`, `altitude:`, `orientation:`, `horizontal-resolution:`, `vertical-resolution:`, `lens-model:`, `white-balance:`, `flash-mode:`, `exposure-program:`, `metering-mode:`, `color-space:`; audio/video `length:`/`duration:`, `title:`, `artist:`, `album:`, `album-artist:`, `genre:`, `year:`, `track:`, `composer:`, `comment:`, `audio-bitrate:`, `audio-sample-rate:`, `audio-channels:`, `audio-format:`, `video-bitrate:`, `frame-rate:`/`fps:`, `video-format:`, `total-bitrate:`, `bpm:`, `publisher:`, `producer:`, `director:`, `writer:`, `copyright:`, `description:`, `tags:`/`tag:`, `rating:`, `subtitle:`, `authors:`/`author:`; document `page-count:`, `word-count:`, `line-count:`, `last-author:`, `company:`, `category:`, `subject:`, `software:`, `date-content-created:`; executable/app `version:`, `product-name:`, `product-version:`, `digital-signature-name:` (codesign authority), `is-running:`; archive `container-file-count:`, `container-filenames:` (zip/tar listing); email `from:`, `to:`, `subject:`, `date-sent:`, `date-received:`; shortcut `shortcut-target:` (alias/symlink target), `url:` (.webloc).
- Index/lists: `filelist:`, `filelist-filename:`, `filelist-full-path:`, `exists:`/`file-exists:`/`folder-exists:`, `include-file-list:`, `network-index-host:`.
- Control/UI: `count:`, `max-threads:`, `sort:`, `sort-ascending:`, `sort-descending:`, `sort-mix:`, `folders-first:` (+ascending/descending), `regmatch0:`…`regmatch9:`, `eval:` (arithmetic over properties), `nop:`, `nothing:`, `everything:`, `bookmark:`, `filter:`, `add-columns:`/`addcol:`, `columns:`, `remove-columns:`, `layout:`, `add-layout:`, `remove-layout:`, `preview:`, `thumbnails:`, `details:`, `folders-sidebar:`, `filters-sidebar:`, `bookmarks-sidebar:`, `alternate-row-color:`, `on-top:`, `new-search:`, `and-search:`, `new-results-only:`, `no-new-results:`, `fileexists:`.
- Macros: `audio:`, `doc:`, `exe:`, `image:`/`pic:`, `video:`, `zip:`, plus user macros from filters.

Terms are reordered by estimated cost (index-only first, disk-backed last) unless `no-reorder:`.

### 3.4 Search engine

`SearchEngine.query(QueryRequest) -> ResultSet`. Parallel scan over the index in chunks (one task per core, `max-threads:` honored), candidate filter by index-only predicates, then disk-backed predicates on survivors with cancellation. Sort: fast-sort permutation when available, else parallel sort on materialized keys. `search-current-results:` narrows the previous result set when the new query is a refinement (previous query is a prefix and no operator changes). Highlight ranges computed per visible row (lazy). Result updates: on index change, affected items are re-evaluated against open sessions and the UI patched (insert/remove/update) in real time without re-running the whole query where possible; otherwise re-query.

### 3.5 Application (AppKit)

Window: search field (NSSearchField subclass with history autocomplete, Ctrl+Space, Alt+Down), filter bar (NSPopUpButton), results NSTableView (details) / NSCollectionView (thumbnails M/L/XL, Ctrl+Shift+1/2/3, Ctrl+wheel), status bar (count, selection size, jump-to text, option badges CASE WW PATH DIAC PREFIX SUFFIX REGEX OMIT TEMP OMIT DUPE DISTINCT UNIQUE FILELIST — double-click toggles), sidebars (Folders tree, Filters, Bookmarks), preview pane (`QLPreviewView`), tabs (NSWindow tabbing with per-tab search state), fullscreen, always on top, zoom (Cmd +/-/0), theme Default/Dark/Light, fonts & colors per element/state, alternate row color, mouseover highlight, grid lines, highlighted terms.

Columns: Name, Path, Full Path, Size, Size on Disk, Extension, Type/Kind, Date Modified, Date Created, Date Accessed, Date Changed, Attributes, Date Recently Changed, Run Count, Date Run, Name Length, Full Path Length, Depth, Child Count, Descendant Count, File List Filename, Owner, Dimensions, Length, Title, Artist, Album, Page Count, Version, Regular Expression Match 0–9, Column 0–F (custom from `add-column:`), and any Spotlight property via "Add Columns…" dialog. Header right-click: sort, Search property…, Find <property> duplicates, Add Columns…, Auto-fit, Reset.

Context menu: Open, Open Path (Reveal in Finder), Open With ▸, Quick Look, Open in Terminal, Copy Full Name, Copy Path, Copy Name, Copy (file), Cut, Paste into folder, Move to Trash, Delete Permanently, Rename, Advanced Rename…, Duplicate, Get Info, Omit ▸ (Omit, Omit Extension, Temporary Omit, Temporarily Omit Extension), Set Run Count…, Add to Bookmarks, Services ▸, Share ▸. Item visibility/commands customizable in Options → Context Menu (custom command with `%1`/`$path` substitution).

Menus: File (New Window ⌘N, New Tab ⌘T, Open File List… ⌘O, Close File List, Create File List…, File List Editor…, Export… ⌘S, Close ⌘W, Quit ⌘Q); Edit (Undo ⌘Z, Undo History…, Cut/Copy/Paste, Copy Full Path ⌘⇧C, Select All, Invert Selection, Rename F2/Enter-as-Finder, Advanced Rename…, Move to Trash, Delete); View (Details, Medium/Large/Extra Large Thumbnails, Preview ⌥P, Folders Sidebar, Filters Sidebar, Bookmarks Sidebar, Filter Bar, Status Bar, Menu Bar in Fullscreen, Zoom In/Out/Reset, Always On Top ⌃T, Full Screen, Refresh F5, Reload Icons); Search (Match Case ⌘I, Match Whole Words ⌘B, Match Path ⌘U, Match Diacritics ⌘M, Match Prefix, Match Suffix, Ignore Punctuation, Ignore White-space, Regular Expressions ⌘R, Enable Result Omissions, filters list with shortcuts, Organize Filters… ⌘⇧F, Advanced Search…, Set Current Search as Home, Search Syntax Help); Index (Index Journal…, Recent Changes, Enable Result Omissions, Enable Temporary Result Omissions, Clear Temporary Omissions, Organize Result Omissions…, Rescan Folders, Force Rebuild, Pause Monitoring, Save Database Now, Statistics…); History (Back ⌘[, Forward ⌘], Home ⌥Home, Show All Search History… ⌘H, Clear Search History, Clear Run History); Bookmarks (Add to Bookmarks… ⌘D, Organize Bookmarks… ⌘⇧B, bookmark list); Tools (Find Duplicates…, Connect to ETP Server…, HTTP Server toggle, ETP Server toggle, Import/Export Settings…, Debug ▸ (Console ⌃`, Statistics, Verbose), Options… ⌘,); Window; Help (Search Syntax, Keyboard Shortcuts, Command Line, Check for Updates, About).

Other app features: menu bar extra (status item) with Show/New Window/Toggle/Pause Monitoring/Options/Quit; run in background (window close keeps app); start at login (`SMAppService`); global hotkeys New/Show/Toggle via Carbon `RegisterEventHotKey` (customizable); keyboard shortcut editor (scopes Global/Search Edit/Result List); Finder service "Search Everything…" (NSServices on folders); `es:` URL scheme; `.efu` document type; Dock drop of folder sets `path:` search; drag results to other apps (file promise / file URLs); jump-to typing in results; Enter in search selects most-run result; close window on execute option; single-click open option; Advanced Search dialog (fields for all/any/none words, ext, size, date, location, options); Advanced Rename (Find/Replace, Change Extension, regex, numbering, edit-all-names text); multi-file Copy To / Move To; Undo system for rename/move/trash with Undo History window; Index Journal window (action filter, search, Undo, Delete, Open Path, Copy Full Path, Export); Organize Filters/Bookmarks/Omissions dialogs (add/edit/remove/reorder/import/export CSV); File List Editor window (add/remove items, import, update from disk, remove dupes, save EFU); Find Duplicates dialog (property picker → `dupe:`); Export dialog (CSV/TSV/TXT/EFU/JSON/M3U/M3U8, selection only, columns); Import/Export Settings wizard; Options window with all tabs listed in §2 of the source docs adapted: General, UI, Home, Search, Results, View, Context Menu, Fonts & Colors, Keyboard, History, Indexes, Volumes, Folders, File Lists, Network Indexes, Properties, Exclude, HTTP Server, ETP/FTP Server, Everything Server, Advanced (raw INI editor with search + reset).

Command-line options of the app binary mirror `Everything.exe` where applicable: `-search/-s`, `-search*`, `-filename`, `-path/-p`, `-parent-path`, `-parent`, `-stem`, `-extension`, match toggles, `-regex`, `-filter`, `-bookmark`, `-home`, `-explore`, `-url`, `-sort`, `-sort-ascending/descending`, `-columns/-add-columns/-remove-columns`, `-details/-thumbnails`, `-new-window/-no-new-window`, `-new-tab`, `-toggle-window`, `-close/-close-all`, `-minimize/-maximize/-fullscreen/-on-top`, `-x/-y/-width/-height`, sidebar/preview/status/filter-bar toggles, `-focus-search/-focus-results`, `-instance`, `-first-instance/-no-first-instance`, `-startup`, `-restore-previous-session`, `-config`, `-exit`, `-wait`, `-restart`, `-debug/-verbose/-debug-log`, `-db`, `-read-only`, `-no-db`, `-add-volume/-volumes`, `-add-folder/-folders`, `-add-filelist/-filelists`, `-add-exclude-folder/-exclude-folders`, `-no-auto-index`, `-rescan/-rescan-all`, `-reindex`, `-monitor-pause/-resume`, `-save-db/-save-db-now`, `-filelist`, `-edit`, `-filelist-editor`, `-create-file-list` (+ include/exclude/no-subfolders/no-folders/no-files), `-rename/-copyto/-moveto`, `-connect`, `-install-run-on-system-startup`, `-install-url-protocol`, `-help`. A second launch forwards its arguments to the running instance over IPC.

### 3.6 IPC, `es`, SDK

IPC: newline-delimited JSON over Unix socket. Requests: `query` (search, options, sort, offset, count, request flags, columns), `version`, `isDBLoaded`, `rebuildDB`, `saveDB`, `updateAllFolderIndexes`, `exit`, `runCount get/set/inc`, `journal` (range/watch), `folderSize`, `command` (app command-line forwarding), `subscribe` (live result updates for HTTP/UI sessions).

`es`: implements the documented `es.exe` switch set (search options, sort, display columns, highlight, viewport offset/count, output formats csv/efu/json/m3u/m3u8/tsv/txt, size/date formats, colors, widths, header/footer, double-quote, journal options incl. `-watch`, export options, `-instance`, `-timeout`, `-get-result-count`, `-get-total-size`, `-get-folder-size`, run-count commands, `-save-settings/-clear-settings` (`~/Library/Application Support/Everything/es.ini`), `-version`, `-get-everything-version`, `-exit`, `-save-db`, `-reindex`, `-no-result-error` exit code 9, `-search`, `-search*`, `--`). Exit codes match where documented.

SDK: `libEverythingSDK.dylib` + `Everything.h` with the documented function names (`Everything_SetSearchW/A`, `Everything_QueryW`, `Everything_GetNumResults`, `Everything_GetResultFullPathNameW`, request flags `EVERYTHING_REQUEST_*`, sort constants `EVERYTHING_SORT_*`, error codes `EVERYTHING_ERROR_*`). UTF-16 "W" variants take `UInt16*`. Also a Swift module `EverythingSDK` with a typed client.

### 3.7 Servers

HTTP: `NWListener` HTTP/1.1 (keep-alive, Basic auth, bind interface, port default 8080 since 80 needs root, logging with max size, serve custom pages from `HTTP Server/` folder, allow download toggle). Routes: `/` web UI (search box, drive list, paging, sort links, folder browse, file download), `/?search=&offset=&count=&json=1&sort=&ascending=&case=&wholeword=&path=&regex=&diacritics=&prefix=&suffix=&ignore_punctuation=&ignore_whitespace=&path_column=&size_column=&date_modified_column=&date_created_column=&attributes_column=`; JSON `{"totalResults":N,"results":[{"type":"file","name":"","path":"","size":"","date_modified":""}]}` (dates as FILETIME strings like Windows, plus `date_modified_iso`); `/<full path>` download/browse; `/everything.css`, `/everything.js`.

ETP/FTP: FTP control server (USER, PASS, FEAT, SYST, TYPE, PWD, CWD, CDUP, PASV, EPSV, LIST, NLST, MLSD, SIZE, MDTM, RETR, QUIT, NOOP, OPTS UTF8) rooted at `/` with volumes as top-level dirs; `SITE EVERYTHING` extension with SEARCH/CASE/WHOLE_WORD/PATH/DIACRITICS/PREFIX/SUFFIX/IGNORE_PUNCTUATION/IGNORE_WHITESPACE/REGEX/HIDE_EMPTY_SEARCH_RESULTS/FILTER_SEARCH/FILTER_*/SORT/OFFSET/COUNT/*_COLUMN/QUERY; QUERY streams `200-` lines `RESULT_COUNT_FILE`, `RESULT_COUNT_FOLDER`, `TOTAL_...`, then per result `FILE`/`FOLDER` + `SIZE`/`DATE_MODIFIED`/`PATH` lines, ending `200 End.`. Client: Tools → Connect to ETP Server… creates a remote index tab (search forwarded, results shown, link types: server path / `ftp://` download).

Everything Server (network index): TCP on 14630 with password auth, TLS-less but challenge-response (HMAC-SHA256) — simplification of AES noted; serves full index snapshot (columnar dump) and journal deltas; client keeps a local mirror index with path remapping ("Mount as"), monitors changes.

### 3.8 Testing

- Unit: parser (every operator/modifier/function form), value parsers (dates, sizes, durations, ranges), matcher semantics (case/diacritics/wholeword/prefix/suffix/wildcards/regex/pinyin/soundex), index operations (insert/remove/rename/move, path materialization, hierarchy functions), DB round-trip, EFU/CSV/JSON export-import, sort stability, duplicates/distinct/unique, omissions, journal, run/search history, settings INI round-trip, IPC codec, `es` output formats, HTTP JSON API, FTP/ETP session, SDK C ABI.
- Integration: scan a generated fixture tree (10k items, unicode names, symlinks, packages, hidden), FSEvents live update test (create/rename/move/delete observed within 2 s), fast-rescan after monitor gap, full-volume scan of `/` smoke test with timing, large synthetic index (1M names) search latency benchmark (< 50 ms for substring), HTTP server end-to-end via `curl`, ETP via `nc`/`ftp`, `es` against running app.
- App: build `.app`, launch, drive via `osascript`/accessibility (type search, read status bar), screenshot captures for visual check, menu/shortcut smoke, Options persistence, menu bar extra, hotkey registration, URL scheme, EFU open.

## 4. Out of scope / deliberately adapted

- Binary plugin loading (no API). Windows-specific attributes without macOS analogue (Integrity Stream, No Scrub, Pinned/Unpinned, Recall on Data Access) are accepted by the parser and never match.
- Alternate data streams → extended attributes (`xattr`) with `alternate-data-stream-names:` mapped to xattr names.
- Localization infrastructure ships with English strings; other languages via `.lproj` drop-in.
- Group policy.
