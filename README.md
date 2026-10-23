# Everything for Mac

Everything for Mac is a native macOS filename index and search application inspired by Everything 1.5. It builds a local columnar index, watches filesystem changes, and exposes the same search engine through an AppKit workspace, the `es` command line client, a Unix IPC service, an Everything-compatible C SDK, HTTP JSON, ETP/FTP, and an authenticated network-index protocol.

The project targets macOS 14 or newer and uses Swift Package Manager. It requires the Xcode Command Line Tools; a full Xcode installation is not required for the package, tests, or bundle script.

## Build and run

```sh
git clone https://github.com/PDGamerSG/Everything-for-mac.git
cd Everything-for-mac
./scripts/test.sh
./scripts/bundle.sh
./scripts/run-app.sh
```

`./scripts/test.sh` runs the complete serialized Swift Testing suite. Serialization is intentional because the suite exercises loopback servers and shared C ABI state; pass `--parallel` explicitly when stress-testing the scheduler. `bundle.sh` builds the release products, assembles `dist/Everything.app`, copies `Everything`, `es`, and `libEverythingSDK.dylib`, installs the URL/document associations, and applies an ad-hoc signature.

The app stores its database, journal, settings, and history under `~/Library/Application Support/Everything/`. Set `EVERYTHING_APP_SUPPORT` to use another support directory. An instance name (`-instance work`) uses suffixed database, socket, and history files.

## App controls

The application has a native search field and result table with Name, Path, Size, and Date Modified columns. Searches run off the main actor, sorting is asynchronous, double-click opens a result in the default macOS application, and the status bar reports result counts and elapsed time. The menu bar provides New Window, Save Database, Rescan, Search focus, window controls, and a GitHub help entry.

The app accepts Everything-style startup switches:

```text
Everything [-search text] [-startup] [-no-window] [-no-auto-index]
          [-rescan] [-rescan-all] [-save] [-exit]
          [-instance name] [-url es:query] [-help] [-version]
```

Initial volume indexing is performed in the background so IPC and the UI become available immediately. `-no-auto-index` starts without a first-run scan; `-rescan` rebuilds configured roots in the background. Opening an `es:` URL focuses the search window, and opening an `.efu` file imports it as a file-list root.

## `es` command line client

`es` talks to the running app over the Unix socket. When no app is running it loads `Everything.db` directly, so scripts can still query a saved database.

```sh
./scripts/run-app.sh -startup -no-auto-index
./.build/arm64-apple-macosx/debug/es -json -columns 'name;path;size' invoice
./.build/arm64-apple-macosx/debug/es -csv -header -sort size -sort-descending -count 25 report
./.build/arm64-apple-macosx/debug/es -db /tmp/Everything.db -no-result-error "ext:swift"
```

Supported output formats are text, CSV, TSV, EFU, JSON, M3U, and M3U8. Search flags include `-case`, `-whole-word`, `-path`, `-diacritics`, `-prefix`, `-suffix`, `-ignore-punctuation`, `-ignore-whitespace`, and `-regex`. Use `-offset`, `-count`, `-sort`, `-columns`, `-filter`, `-instance`, and `-timeout` to shape a query.

The core parser supports filename terms, path terms, wildcards, quoted phrases, boolean operators, modifiers, regular expressions, size/date ranges, extension and folder functions, duplicate searches, soundex, pinyin, and Everything-compatible property names. Query behavior is shared by the app, `es`, HTTP, ETP, SDK, and network-index consumers.

## HTTP JSON service

Enable the service in `Everything.ini` and restart the app:

```ini
http_server_enabled=1
http_server_bind=127.0.0.1
http_server_port=8080
http_server_username=
http_server_password=
http_server_allow_file_download=1
http_server_items_per_page=32
```

Routes:

```text
GET /json?search=report&columns=name,path,full-path&offset=0&count=50
GET /api/search?q=swift&sort=size&ascending=0
GET /download?path=/Users/me/report.pdf
GET /
```

JSON responses include `totalResults`, `totalFiles`, `totalFolders`, and an array of typed result rows. Basic authentication is required when either credential is configured. Downloads can be disabled and reject `..` traversal segments.

## ETP/FTP service

```ini
etp_server_enabled=1
etp_server_bind=127.0.0.1
etp_server_port=2121
etp_server_username=user
etp_server_password=secret
etp_server_allow_file_download=1
```

The server supports USER/PASS, FEAT, SYST, TYPE, PWD, PASV/EPSV, LIST, MLSD, SITE EVERYTHING SEARCH/QUERY, RETR, NOOP, and QUIT. `RETR` uses a real passive data connection and is controlled by the download flag.

## Network index service

The Everything Server-compatible service uses TCP (default port 14630), an HMAC-SHA256 challenge, filtered snapshots, and journal pulls:

```ini
everything_server_enabled=1
everything_server_bind=127.0.0.1
everything_server_port=14630
everything_server_users=alice:secret;backup:another-secret
everything_server_include_only=/Users/shared;/Volumes/Archive
```

`NetIndexClient` authenticates, mirrors a snapshot under a configured mount path, and applies journal deltas. Include-only prefixes are enforced by the server before data leaves the process.

## IPC and SDK

The app listens on a length-framed JSON Unix socket in the support directory. `EverythingIPC` is the Swift client/server layer used by the app, `es`, HTTP, ETP, and the SDK. `EverythingSDK` builds `libEverythingSDK.dylib` with the Windows-compatible `Everything_*` C ABI and UTF-8/UTF-16 result accessors. The public declarations are in `Sources/EverythingSDK/include/Everything.h`.

## Repository layout

```text
Sources/EverythingCore     index, scanner, journal, parser, matcher, state, exports
Sources/EverythingIPC      Unix socket protocol, client, service adapter
Sources/EverythingServers  HTTP, ETP/FTP, and network-index services
Sources/Everything         AppKit application, engine lifecycle, menus, bundle resources
Sources/es                 command-line parser and output renderers
Sources/EverythingSDK      dynamic C ABI library and header
Tests                      core, IPC, server, SDK, CLI, and app lifecycle tests
scripts                    test, bundle, run, and benchmark entry points
```

The implementation is macOS-specific by design: it uses AppKit, Darwin sockets, FSEvents-compatible monitoring, CommonCrypto, and mounted-volume metadata APIs.
