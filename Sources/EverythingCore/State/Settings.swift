import Foundation

/// Locations of Everything's user data on macOS.
public enum AppPaths {
    public static var instanceName: String = ""

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["EVERYTHING_APP_SUPPORT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Everything", isDirectory: true)
    }

    private static func suffixed(_ name: String, _ ext: String) -> URL {
        let n = instanceName.isEmpty ? name : "\(name)-\(instanceName)"
        return supportDirectory.appendingPathComponent("\(n).\(ext)")
    }

    public static var settingsFile: URL { suffixed("Everything", "ini") }
    public static var databaseFile: URL { suffixed("Everything", "db") }
    public static var journalFile: URL { suffixed("Journal", "db") }
    public static var filtersFile: URL { suffixed("Filters", "csv") }
    public static var bookmarksFile: URL { suffixed("Bookmarks", "csv") }
    public static var omitResultsFile: URL { supportDirectory.appendingPathComponent(instanceName.isEmpty ? "Omit Results.csv" : "Omit Results-\(instanceName).csv") }
    public static var searchHistoryFile: URL { suffixed("Search History", "csv") }
    public static var runHistoryFile: URL { suffixed("Run History", "csv") }
    public static var sessionFile: URL { suffixed("Session", "json") }
    public static var esSettingsFile: URL { supportDirectory.appendingPathComponent("es.ini") }
    public static var httpServerDirectory: URL { supportDirectory.appendingPathComponent("HTTP Server", isDirectory: true) }
    public static var logFile: URL { suffixed("Everything", "log") }
    public static var ipcSocket: URL { suffixed("ipc", "sock") }
    public static var undoLogFile: URL { suffixed("Undo", "json") }
    public static var macrosFile: URL { suffixed("Macros", "csv") }

    public static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}

/// Typed access to Everything.ini. Keys follow Windows Everything names where applicable.
public final class Settings: @unchecked Sendable {
    public private(set) var ini: INIFile
    private let lock = NSLock()
    public var onChange: ((String) -> Void)?

    public init(ini: INIFile = INIFile()) { self.ini = ini }

    public static func load(from url: URL = AppPaths.settingsFile) -> Settings {
        Settings(ini: INIFile.load(url) ?? INIFile())
    }

    public func save(to url: URL = AppPaths.settingsFile) throws {
        lock.lock(); defer { lock.unlock() }
        try ini.write(to: url)
    }

    // MARK: generic access

    public func string(_ key: String) -> String { lock.lock(); defer { lock.unlock() }; return ini[key] ?? Settings.defaults[key] ?? "" }
    public func bool(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ini.bool(key, default: INIFile.parseBool(Settings.defaults[key] ?? "0") ?? false) }
    public func int(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return ini.int(key, default: Int(Settings.defaults[key] ?? "0") ?? 0) }
    public func double(_ key: String) -> Double { lock.lock(); defer { lock.unlock() }; return ini.double(key, default: Double(Settings.defaults[key] ?? "0") ?? 0) }
    public func list(_ key: String) -> [String] { string(key).split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    public func set(_ key: String, _ value: String) { lock.lock(); ini.set(key, value); lock.unlock(); onChange?(key) }
    public func set(_ key: String, _ value: Bool) { set(key, value ? "1" : "0") }
    public func set(_ key: String, _ value: Int) { set(key, String(value)) }
    public func set(_ key: String, _ value: Double) { set(key, String(value)) }
    public func set(_ key: String, list: [String]) { set(key, list.joined(separator: ";")) }
    public func reset(_ key: String) { lock.lock(); ini.remove(key); lock.unlock(); onChange?(key) }
    public func isModified(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ini.has(key) && ini[key] != Settings.defaults[key] }
    public func replace(ini new: INIFile) { lock.lock(); ini = new; lock.unlock(); onChange?("*") }
    public func allKeys() -> [String] { Array(Settings.defaults.keys).sorted() }
    public func defaultValue(_ key: String) -> String { Settings.defaults[key] ?? "" }

    // MARK: default values (every option the UI exposes)

    public static let defaults: [String: String] = [
        // General
        "language": "", "app_data": "1", "check_updates": "1", "run_on_system_startup": "0",
        "folder_context_menu": "0", "url_protocol": "1", "efu_association": "1",
        // UI
        "scale": "100", "run_in_background": "1", "show_tray_icon": "1", "tray_single_click": "0",
        "tray_new_window": "0", "new_window_on_run": "0", "open_searches_in_tabs": "1", "switch_to_new_tab": "1",
        // Home
        "home_match_case": "0", "home_match_whole_word": "0", "home_match_path": "0", "home_match_diacritics": "0",
        "home_match_prefix": "0", "home_match_suffix": "0", "home_ignore_punctuation": "0", "home_ignore_whitespace": "0",
        "home_regex": "0", "home_search": "", "home_use_last_search": "1", "home_filter": "Everything", "home_columns": "name;path;size;date_modified",
        "home_sort": "name", "home_sort_ascending": "1", "home_view": "details", "home_index": "local", "home_file_list": "",
        "home_etp_server": "", "home_link_type": "0", "home_omit_results": "0", "home_folders_first": "0",
        // Search
        "search_as_you_type": "1", "search_delay": "0", "select_search_on_click": "1", "focus_search_on_activate": "1",
        "match_whole_filename_when_using_wildcards": "1", "allow_literal_operators": "0", "replace_forward_slashes": "0",
        "replace_backslashes": "1", "operator_precedence": "0", "hide_empty_search_results": "0", "search_history_enabled": "1",
        // Results
        "clear_selection_on_search": "1", "close_on_execute": "0", "open_path_double_click": "1", "auto_scroll": "1",
        "double_quote_copy": "0", "no_select_extension_on_rename": "1", "sort_date_descending_first": "1",
        "sort_size_descending_first": "1", "full_row_select": "1", "single_click_open": "0", "underline_icon_titles": "0",
        "select_most_run_on_enter": "1",
        // View
        "alternate_row_color": "0", "show_row_mouseover": "1", "highlight_search_terms": "1", "show_selected_item_in_status_bar": "1",
        "show_total_size_in_status_bar": "1", "size_standard": "0", "size_format": "0", "date_format": "0", "grid_lines": "0",
        "dupe_lines": "1", "dupe_line_color": "#FF8000", "dupe_line_dark_color": "#FFA040", "thumbnail_size": "128",
        "show_header": "1", "show_status_bar": "1", "show_filter_bar": "0", "show_folders_sidebar": "0", "show_filters_sidebar": "0",
        "show_bookmarks_sidebar": "0", "show_preview": "0", "always_on_top": "0", "window_title_format": "$s - Everything",
        // Fonts and colors
        "theme": "0", "font_name": "", "font_size": "0", "accent_color": "", "zoom": "100",
        // Keyboard
        "new_window_hotkey": "", "show_window_hotkey": "ctrl+alt+space", "toggle_window_hotkey": "", "keyboard_shortcuts": "",
        // History
        "search_history_keep_days": "0", "always_show_search_suggestions": "0", "search_history_sort": "date",
        "run_history_enabled": "1", "run_history_keep_days": "0",
        // Indexes
        "db_location": "", "multi_user_db": "0", "index_recent_changes": "1", "journal_enabled": "1", "journal_max_size": "1024",
        "index_file_size": "1", "fast_size_sort": "1", "index_folder_size": "0", "index_date_created": "1", "fast_date_created_sort": "0",
        "index_date_modified": "1", "fast_date_modified_sort": "1", "index_date_accessed": "0", "fast_date_accessed_sort": "0",
        "index_attributes": "1", "fast_attributes_sort": "0", "fast_extension_sort": "1", "index_date_changed": "0",
        "db_autosave_interval": "60", "update_in_background": "1",
        // Volumes
        "auto_include_fixed_volumes": "1", "auto_include_removable_volumes": "1", "auto_include_network_volumes": "0",
        "auto_remove_offline_volumes": "1", "volumes": "", "excluded_volumes": "", "volume_include_only": "", "monitor_changes": "1",
        "monitor_buffer_size": "65536", "rescan_on_full_buffer": "1", "fast_rescan": "1", "folder_update_interval": "0",
        // Folders
        "folders": "", "folder_monitor_changes": "1", "folder_rescan_on_startup": "0",
        // File lists
        "file_lists": "", "file_list_monitor": "1",
        // Network indexes
        "network_indexes": "", "network_index_password": "", "network_index_include_only": "", "network_index_mount_as": "", "network_index_monitor": "1",
        // Properties
        "indexed_properties": "", "property_include_folders": "0", "property_include_files": "1", "property_include_only_folders": "",
        "property_exclude_folders": "", "property_include_only_files": "", "property_exclude_files": "", "property_max_size": "0",
        "property_fast_sort": "0", "content_size_limit": "33554432",
        // Exclude
        "exclude_hidden": "0", "exclude_system": "0",
        "exclude_folders": "/dev;/private/var/vm;/System/Volumes/VM;/System/Volumes/Preboot;/System/Volumes/Update;/System/Volumes/xarts;/System/Volumes/iSCPreboot;/System/Volumes/Hardware;*/.fseventsd;*/.Spotlight-V100;*/.DocumentRevisions-V100;*/.TemporaryItems;*/.Trashes;*/.MobileBackups;/private/var/folders/*/*/C;/private/var/db/uuidtext",
        "include_only_files": "", "exclude_files": "",
        // HTTP
        "http_server_enabled": "0", "http_server_bind": "", "http_server_port": "8080", "http_server_username": "", "http_server_password": "",
        "http_server_log_enabled": "0", "http_server_log_file": "", "http_server_log_max_size": "4096", "http_server_home": "",
        "http_server_default_page": "", "http_server_allow_file_download": "1", "http_server_items_per_page": "32", "http_server_strings": "",
        // ETP
        "etp_server_enabled": "0", "etp_server_bind": "", "etp_server_port": "21", "etp_server_username": "", "etp_server_password": "",
        "etp_server_log_enabled": "0", "etp_server_log_file": "", "etp_server_log_max_size": "4096", "etp_server_allow_file_download": "1",
        "etp_server_welcome_message": "Welcome to Everything ETP/FTP", "etp_client_rewrite_patterns": "", "etp_client_rewrite_substitutions": "",
        // Everything server
        "everything_server_enabled": "0", "everything_server_bind": "", "everything_server_port": "14630", "everything_server_users": "",
        "everything_server_include_only": "", "everything_server_snapshot_cache_timeout": "60000", "everything_server_max_snapshots": "8",
        // Context menu
        "context_menu_open": "0", "context_menu_open_path": "0", "context_menu_open_with": "0", "context_menu_quick_look": "0",
        "context_menu_copy_full_path": "0", "context_menu_copy_path": "0", "context_menu_copy_name": "0", "context_menu_copy": "0",
        "context_menu_cut": "0", "context_menu_paste": "0", "context_menu_trash": "0", "context_menu_delete": "1", "context_menu_rename": "0",
        "context_menu_advanced_rename": "0", "context_menu_get_info": "0", "context_menu_omit": "0", "context_menu_run_count": "1",
        "context_menu_bookmark": "0", "context_menu_terminal": "0", "context_menu_services": "0", "context_menu_share": "0",
        "open_command": "", "open_path_command": "", "open_folder_command": "",
        // Advanced
        "debug": "0", "verbose": "0", "debug_log": "0", "max_threads": "0", "instance": "", "ipc_enabled": "1",
        "result_omissions_enabled": "0", "temp_result_omissions_enabled": "0",
        "autocomplete": "1", "jump_to_timeout": "1000", "double_click_path_column": "1", "icon_cache_size": "4096",
        "regex_timeout_ms": "2000", "full_disk_access_prompted": "0", "last_update_check": "0", "window_x": "", "window_y": "",
        "window_width": "900", "window_height": "600", "column_widths": "", "sidebar_width": "200", "preview_width": "300",
        "statistics_last_scan_seconds": "0", "soundex": "0", "pinyin": "0",
    ]
}

// MARK: - Match defaults used by the parser/engine

public struct MatchDefaults: Equatable, Hashable, Codable, Sendable {
    public var matchCase = false
    public var matchWholeWords = false
    public var matchPath = false
    public var matchDiacritics = false
    public var matchPrefix = false
    public var matchSuffix = false
    public var ignorePunctuation = false
    public var ignoreWhitespace = false
    public var regex = false

    public init() {}

    public init(settings: Settings, prefix: String = "home_") {
        matchCase = settings.bool(prefix + "match_case")
        matchWholeWords = settings.bool(prefix + "match_whole_word")
        matchPath = settings.bool(prefix + "match_path")
        matchDiacritics = settings.bool(prefix + "match_diacritics")
        matchPrefix = settings.bool(prefix + "match_prefix")
        matchSuffix = settings.bool(prefix + "match_suffix")
        ignorePunctuation = settings.bool(prefix + "ignore_punctuation")
        ignoreWhitespace = settings.bool(prefix + "ignore_whitespace")
        regex = settings.bool(prefix + "regex")
    }
}

public enum SizeStandard: Int, Codable, Sendable { case jedec = 0, iec = 1, metric = 2 }
public enum SizeFormatMode: Int, Codable, Sendable { case auto = 0, bytes = 1, kb = 2, mb = 3 }
