import Foundation
import EverythingCore
import EverythingIPC

private func usage() -> String {
    """
    Usage: es [options] [search]
      -csv|-tsv|-txt|-efu|-json|-m3u|-m3u8  output format
      -columns name;path;size                 columns to output
      -sort property [-sort-ascending|-sort-descending]
      -path -regex -case -whole-word -prefix -suffix
      -count N -offset N -timeout MS -db PATH -instance NAME
      -no-result-error -help -version
    """
}

private func makeQuery(_ options: ESOptions) -> IPCQueryParams {
    var q = IPCQueryParams(search: options.search)
    q.matchCase = options.defaults.matchCase
    q.matchWholeWord = options.defaults.matchWholeWords
    q.matchPath = options.defaults.matchPath
    q.matchDiacritics = options.defaults.matchDiacritics
    q.matchPrefix = options.defaults.matchPrefix
    q.matchSuffix = options.defaults.matchSuffix
    q.ignorePunctuation = options.defaults.ignorePunctuation
    q.ignoreWhitespace = options.defaults.ignoreWhitespace
    q.regex = options.defaults.regex
    q.sort = options.sort
    q.ascending = options.ascending
    q.offset = options.offset
    q.count = options.count
    q.columns = options.columns
    q.highlight = options.highlight
    q.filter = options.filter
    return q
}

private func standaloneResult(_ options: ESOptions) throws -> IPCQueryResult {
    let url = URL(fileURLWithPath: options.databasePath ?? AppPaths.databaseFile.path)
    let index = try IndexDB.load(from: url)
    return try EngineService(engine: SearchEngine(index: index)).runQuery(makeQuery(options)).query.unwrapOrThrow("database query failed")
}

private func remoteResult(_ options: ESOptions) throws -> IPCQueryResult {
    let client = IPCClient(instance: options.instance)
    client.timeoutMs = Int32(options.timeoutMs)
    return try client.query(makeQuery(options))
}

private extension Optional {
    func unwrapOrThrow(_ message: String) throws -> Wrapped {
        guard let value = self else { throw ESParseError.usage(message) }
        return value
    }
}

let argv = Array(CommandLine.arguments)
do {
    let options = try ESOptions.parse(argv)
    if options.help { print(usage()); exit(0) }
    if options.version { print(everythingVersion); exit(0) }
    AppPaths.instanceName = options.instance
    let result: IPCQueryResult
    if IPCClient.isRunning(path: SocketPath.path(instance: options.instance)) {
        result = try remoteResult(options)
    } else {
        result = try standaloneResult(options)
    }
    print(ESOutput.render(items: result.items, totalResults: result.totalResults, format: options.format,
                          columns: options.columns, includeHeader: options.includeHeader), terminator: "")
    if options.noResultError && result.totalResults == 0 { exit(9) }
    exit(0)
} catch let error as ESParseError {
    fputs("es: \(error)\n", stderr)
    exit(2)
} catch {
    fputs("es: \(error)\n", stderr)
    exit(3)
}
