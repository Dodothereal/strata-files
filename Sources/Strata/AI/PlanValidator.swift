import Foundation

/// Checks proposed operations against the file system and the selection, deterministically. Nothing the model says is trusted:
/// - only selected items can be renamed, moved or trashed, each at most once;
/// - names must be valid (no “/” or “:”, not hidden, not empty, ≤ 255 bytes) and keep their extension;
/// - nothing is overwritten, and no two items end up with the same name;
/// - new folders and moves stay inside the window's folder, unless the instruction itself names the other place;
/// - a folder can't move into itself, and symlinks can't be used to escape.
/// Invalid operations become excluded steps with a reason, shown in the review sheet.
nonisolated enum PlanValidator {
    static func validate(expanding recipe: PlanRecipe, request: PlanGenerator.Request, source: Plan.Source) -> Plan {
        let expansion = PlanExpander.expand(recipe, items: request.items, baseFolder: request.baseFolder)
        var plan = validate(expansion.operations, request: request, source: source, interpretation: recipe.title)
        let kind: PlanStep.Kind = switch recipe.action {
        case .rename: .rename
        case .move, .group: .move
        case .trash: .trash
        }
        var id = (plan.steps + plan.excluded).map(\.id).max().map { $0 + 1 } ?? 0
        for (item, reason) in expansion.skipped {
            plan.excluded.append(PlanStep(id: id, kind: kind, source: item.url, destination: nil, isEnabled: false, problem: reason))
            id += 1
        }
        // Skipped items were counted as untouched by the operation pass; they're reported as skipped instead.
        plan.unaffected = max(0, plan.unaffected - expansion.skipped.count)
        return plan
    }

    /// `allowChains`: an item may take a name another renamed item gives up (swaps, "1, 2, 3 → 2, 3, 4"); the
    /// executor moves those through temporary names. `keepExtensions`: a new name without the item's extension gets it
    /// back (off when renaming extensions on purpose).
    static func validate(_ operations: [ProposedOperation], request: PlanGenerator.Request, source: Plan.Source,
                         interpretation: String, allowChains: Bool = false, keepExtensions: Bool = true) -> Plan {
        let fm = FileManager.default
        let base = request.baseFolder.standardizedFileURL
        let selection = Dictionary(request.items.map { (key($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        var steps: [PlanStep] = []
        var excluded: [PlanStep] = []
        var touched: Set<String> = []
        var claimed: Set<String> = []
        var vacated: Set<String> = []
        var newFolders: [URL] = []
        var nextID = 0
        var unchanged = 0
        if allowChains {
            for case let .rename(url, _) in operations { vacated.insert(key(url)) }
        }

        func exclude(_ kind: PlanStep.Kind, _ source: URL?, _ destination: URL?, _ problem: String) {
            excluded.append(PlanStep(id: nextID, kind: kind, source: source, destination: destination, isEnabled: false, problem: problem))
            nextID += 1
        }

        /// Registers a valid change of `item` to `destination`, or excludes it.
        func claim(_ kind: PlanStep.Kind, _ item: PlanItem, _ destination: URL, note: String? = nil) {
            let target = key(destination)
            if claimed.contains(target) {
                exclude(kind, item.url, destination, String(localized: "Same name as another item in this plan"))
            } else if TransferEngine.exists(destination), !Self.sameItem(destination, item.url), !vacated.contains(target) {
                // Identity, not spelling: on a case-sensitive disk "Photo.jpg" can be a different file from "photo.jpg".
                exclude(kind, item.url, destination, String(localized: "Would replace “\(destination.lastPathComponent)”"))
            } else {
                claimed.insert(target)
                vacated.insert(key(item.url))
                steps.append(PlanStep(id: nextID, kind: kind, source: item.url, destination: destination, note: note))
                nextID += 1
            }
        }

        func needFolder(_ folder: URL) {
            // Every missing level, outermost first.
            var missing: [URL] = []
            var current = folder
            while !fm.fileExists(atPath: current.path), isInside(current, base) {
                missing.insert(current, at: 0)
                current = current.deletingLastPathComponent()
            }
            for url in missing where !newFolders.contains(url) { newFolders.append(url) }
        }

        for operation in operations {
            switch operation {
            case let .rename(url, name):
                guard let item = selection[key(url)] else { exclude(.rename, url, nil, String(localized: "Not part of the selection")); continue }
                guard touched.insert(key(item.url)).inserted else { exclude(.rename, url, nil, String(localized: "Already changed by another step")); continue }
                var newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                var note: String?
                if keepExtensions, !item.isFolder, !item.ext.isEmpty,
                   (newName as NSString).pathExtension.lowercased() != item.ext.lowercased() {
                    newName += "." + item.ext
                    note = String(localized: "Kept the .\(item.ext) extension")
                }
                if let problem = nameProblem(newName) { exclude(.rename, url, nil, problem); continue }
                if newName == item.name { unchanged += 1; continue }
                claim(.rename, item, item.url.deletingLastPathComponent().appending(path: newName), note: note)

            case let .move(url, folderText):
                guard let item = selection[key(url)] else { exclude(.move, url, nil, String(localized: "Not part of the selection")); continue }
                guard touched.insert(key(item.url)).inserted else { exclude(.move, url, nil, String(localized: "Already changed by another step")); continue }
                let folder: URL
                switch resolveFolder(folderText, base: base, instruction: request.instruction) {
                case let .success(url): folder = url
                case let .failure(problem): exclude(.move, item.url, nil, problem.message); continue
                }
                if key(folder) == key(item.url.deletingLastPathComponent()) { unchanged += 1; continue }
                if item.isFolder, key(folder) == key(item.url) || isInside(folder, item.url) {
                    exclude(.move, item.url, folder, String(localized: "A folder can’t go inside itself"))
                    continue
                }
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    exclude(.move, item.url, folder, String(localized: "“\(folder.lastPathComponent)” is a file, not a folder"))
                    continue
                }
                needFolder(folder)
                claim(.move, item, folder.appending(path: item.name))

            case let .createFolder(text):
                switch resolveFolder(text, base: base, instruction: request.instruction) {
                case let .success(folder):
                    var isDirectory: ObjCBool = false
                    if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
                        if !isDirectory.boolValue { exclude(.createFolder, nil, folder, String(localized: "A file named “\(folder.lastPathComponent)” exists")) }
                    } else {
                        needFolder(folder)
                    }
                case let .failure(problem): exclude(.createFolder, nil, nil, problem.message)
                }

            case let .trash(url):
                guard let item = selection[key(url)] else { exclude(.trash, url, nil, String(localized: "Not part of the selection")); continue }
                guard touched.insert(key(item.url)).inserted else { exclude(.trash, url, nil, String(localized: "Already changed by another step")); continue }
                vacated.insert(key(item.url))
                steps.append(PlanStep(id: nextID, kind: .trash, source: item.url, destination: nil))
                nextID += 1
            }
        }

        // With chains, a name counted as given up must really be: an item whose own change was refused (or that keeps
        // its name) stays, and nothing may land on it. Refusing one change can strand another (its target now stays
        // too), so stranding spreads along chains: one pass over a worklist.
        if allowChains {
            var stepByDestination: [String: Int] = [:]
            for (index, step) in steps.enumerated() {
                if let destination = step.destination { stepByDestination[key(destination)] = index }
            }
            let moving = Set(steps.compactMap(\.source).map(key))
            var staying = operations.compactMap { operation -> String? in
                if case let .rename(url, _) = operation, !moving.contains(key(url)) { return key(url) }
                return nil
            }
            var stranded = Set<Int>()
            while let name = staying.popLast() {
                guard let index = stepByDestination[name], stranded.insert(index).inserted else { continue }
                if let source = steps[index].source { staying.append(key(source)) }
            }
            if !stranded.isEmpty {
                for index in stranded.sorted() {
                    let step = steps[index]
                    excluded.append(PlanStep(id: step.id, kind: step.kind, source: step.source, destination: step.destination,
                                             isEnabled: false,
                                             problem: String(localized: "Would replace “\(step.destination?.lastPathComponent ?? "")”, which keeps its name")))
                }
                steps = steps.enumerated().filter { !stranded.contains($0.offset) }.map(\.element)
            }
        }
        // Nothing is changed inside something this plan also renames, moves or trashes: a destination there would go
        // missing, and an item there would be renamed under a folder that's leaving.
        let changing = Dictionary(steps.compactMap { step in step.kind == .createFolder ? nil : step.source.map { (key($0), $0) } },
                                  uniquingKeysWith: { first, _ in first })
        func changedFolder(holding url: URL, including itself: Bool) -> URL? {
            var current = itself ? url.standardizedFileURL : url.standardizedFileURL.deletingLastPathComponent()
            while current.path != "/", !current.path.isEmpty {
                if let changed = changing[key(current)] { return changed }
                current = current.deletingLastPathComponent()
            }
            return nil
        }
        var kept: [PlanStep] = []
        for step in steps {
            var changed: URL?
            if step.kind == .move, let destination = step.destination {
                changed = changedFolder(holding: destination.deletingLastPathComponent(), including: true)
                if changed == step.source { changed = nil }
            }
            if changed == nil, step.kind == .rename || step.kind == .move, let source = step.source {
                changed = changedFolder(holding: source, including: false)
            }
            if let changed {
                excluded.append(PlanStep(id: step.id, kind: step.kind, source: step.source, destination: step.destination, isEnabled: false,
                                         problem: String(localized: "“\(changed.lastPathComponent)” is changed by this plan too")))
            } else {
                kept.append(step)
            }
        }
        // Folders first, so the moves have somewhere to go.
        let folderSteps = newFolders.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { url -> PlanStep in
            defer { nextID += 1 }
            return PlanStep(id: nextID, kind: .createFolder, source: nil, destination: url)
        }
        let affected = Set(kept.compactMap(\.source).map(key)).union(excluded.compactMap(\.source).map(key))
        return Plan(instruction: request.instruction, source: source, interpretation: interpretation, baseFolder: base,
                    steps: folderSteps + kept, excluded: excluded,
                    unaffected: request.items.filter { !affected.contains(key($0.url)) }.count)
    }

    // MARK: - Rules

    /// Why a file name can't be used, or nil.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return String(localized: "The new name is empty") }
        if name == "." || name == ".." { return String(localized: "“\(name)” isn’t a valid name") }
        if name.contains("/") { return String(localized: "Names can’t contain “/”") }
        if name.contains(":") { return String(localized: "Names can’t contain “:”") }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return String(localized: "The name has invisible characters") }
        if name.hasPrefix(".") { return String(localized: "Names starting with “.” are hidden") }
        if name.utf8.count > 255 { return String(localized: "The name is too long") }
        return nil
    }

    struct Problem: Error {
        let message: String
    }

    /// A folder for a move or a new folder: relative to `base`, or a `~`/absolute path that the instruction itself names.
    static func resolveFolder(_ raw: String, base: URL, instruction: String) -> Result<URL, Problem> {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return .failure(Problem(message: String(localized: "No folder name"))) }

        let folder: URL
        if text.hasPrefix("~") || text.hasPrefix("/") {
            folder = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
            let named = names(instruction, text) || names(instruction, folder.path)
                || names(instruction, (folder.path as NSString).abbreviatingWithTildeInPath)
            if !isInside(folder, base), !named {
                return .failure(Problem(message: String(localized: "Outside “\(base.lastPathComponent)” and not named in your request")))
            }
        } else {
            let components = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.contains(where: { $0 == ".." || $0 == "." }) { return .failure(Problem(message: String(localized: "Folder paths can’t go up a level"))) }
            if let problem = components.lazy.compactMap(nameProblem).first { return .failure(Problem(message: problem)) }
            folder = components.reduce(base) { $0.appending(path: $1, directoryHint: .isDirectory) }.standardizedFileURL
        }
        // Symlinked folders could point anywhere: judge by where the nearest existing ancestor really is.
        var existing = folder
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing = existing.deletingLastPathComponent() }
        let real = existing.resolvingSymlinksInPath()
        let realBase = base.resolvingSymlinksInPath()
        if isInside(folder, base), !(key(real) == key(realBase) || isInside(real, realBase)) {
            return .failure(Problem(message: String(localized: "“\(existing.lastPathComponent)” links outside “\(base.lastPathComponent)”")))
        }
        return .success(folder)
    }

    /// Whether `instruction` names the folder `path` as a whole. Only a mention that ends there counts (at a space, the
    /// end, closing punctuation, or a "/" or full stop with nothing after it): "~/Archive/2024" doesn't name
    /// "~/Archive" above it, nor "~/Archive/20".
    static func names(_ instruction: String, _ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let opening: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "<"]
        let closing: Set<Character> = [",", ";", "!", "?", ")", "]", ">", "\"", "'", "”", "’"]
        var start = instruction.startIndex
        while let found = instruction.range(of: path, options: .caseInsensitive, range: start..<instruction.endIndex) {
            start = instruction.index(after: found.lowerBound)
            if found.lowerBound > instruction.startIndex {
                let before = instruction[instruction.index(before: found.lowerBound)]
                guard before.isWhitespace || opening.contains(before) else { continue }
            }
            let rest = instruction[found.upperBound...].drop { "/.:".contains($0) }
            guard let next = rest.first else { return true }
            if next.isWhitespace || closing.contains(next) { return true }
        }
        return false
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        let parent = folder.standardizedFileURL.path.lowercased()
        return path.hasPrefix(parent == "/" ? "/" : parent + "/") && path != parent
    }

    /// Paths compare case-insensitively (APFS default).
    /// Whether two paths are the same file (device and inode), whatever their spelling.
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        var x = stat(), y = stat()
        return lstat(a.path, &x) == 0 && lstat(b.path, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }
}
