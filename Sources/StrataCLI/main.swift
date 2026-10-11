import AppKit

// strata — open folders and searches in Strata from a terminal.
//
//   strata                 open the current folder
//   strata <path>…         open folders, or reveal files
//   strata -s <query>      search everywhere (same syntax as the search field)
//   strata -s <query> -i <folder>   search inside a folder

let usage = """
usage: strata [path …]
       strata -s <query> [-i <folder>]

  path          folders open in a window; files are shown selected in their folder
  -s, --search  search the index (ext:pdf, kind:image, size:>10mb, modified:<7d, in:~/Documents …)
  -i, --in      limit the search to a folder
"""

let bundleID = "dev.strata.app"
var arguments = Array(CommandLine.arguments.dropFirst())
var query: String?
var scope: String?
var paths: [String] = []

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-s", "--search":
        guard !arguments.isEmpty else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
        query = arguments.removeFirst()
    case "-i", "--in":
        guard !arguments.isEmpty else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
        scope = arguments.removeFirst()
    default:
        paths.append(argument)
    }
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
func absolute(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
}

guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
    FileHandle.standardError.write(Data("strata: Strata.app isn't installed\n".utf8))
    exit(1)
}

var targets: [URL]
if let query {
    var components = URLComponents()
    components.scheme = "strata"
    components.host = "search"
    components.queryItems = [URLQueryItem(name: "q", value: query)] + (scope.map { [URLQueryItem(name: "in", value: absolute($0).path)] } ?? [])
    targets = [components.url!]
} else {
    targets = (paths.isEmpty ? ["."] : paths).map(absolute)
    for url in targets where !FileManager.default.fileExists(atPath: url.path) {
        FileHandle.standardError.write(Data("strata: \(url.path): no such file or directory\n".utf8))
        exit(1)
    }
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: configuration) { _, error in
    if let error {
        FileHandle.standardError.write(Data("strata: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}
dispatchMain()
