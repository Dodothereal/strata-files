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

    static func validate(_ operations: [ProposedOperation], request: PlanGenerator.Request, source: Plan.Source,
                         interpretation: String) -> Plan {
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

        func exclude(_ kind: PlanStep.Kind, _ source: URL?, _ destination: URL?, _ problem: String) {
            excluded.append(PlanStep(id: nextID, kind: kind, source: source, destination: destination, isEnabled: false, problem: problem))
            nextID += 1
        }

        /// Registers a valid change of `item` to `destination`, or excludes it.
        func claim(_ kind: PlanStep.Kind, _ item: PlanItem, _ destination: URL, note: String? = nil) {
            let target = key(destination)
            if claimed.contains(target) {
                exclude(kind, item.url, destination, "Same name as another item in this plan")
            } else if fm.fileExists(atPath: destination.path), target != key(item.url), !vacated.contains(target) {
                exclude(kind, item.url, destination, "Would replace “\(destination.lastPathComponent)”")
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
                guard let item = selection[key(url)] else { exclude(.rename, url, nil, "Not part of the selection"); continue }
                guard touched.insert(key(item.url)).inserted else { exclude(.rename, url, nil, "Already changed by another step"); continue }
                var newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                var note: String?
                if !item.isFolder, !item.ext.isEmpty, (newName as NSString).pathExtension.lowercased() != item.ext.lowercased() {
                    newName += "." + item.ext
                    note = "Kept the .\(item.ext) extension"
                }
                if let problem = nameProblem(newName) { exclude(.rename, url, nil, problem); continue }
                if newName == item.name { unchanged += 1; continue }
                claim(.rename, item, item.url.deletingLastPathComponent().appending(path: newName), note: note)

            case let .move(url, folderText):
                guard let item = selection[key(url)] else { exclude(.move, url, nil, "Not part of the selection"); continue }
                guard touched.insert(key(item.url)).inserted else { exclude(.move, url, nil, "Already changed by another step"); continue }
                let folder: URL
                switch resolveFolder(folderText, base: base, instruction: request.instruction) {
                case let .success(url): folder = url
                case let .failure(problem): exclude(.move, item.url, nil, problem.message); continue
                }
                if key(folder) == key(item.url.deletingLastPathComponent()) { unchanged += 1; continue }
                if item.isFolder, key(folder) == key(item.url) || isInside(folder, item.url) {
                    exclude(.move, item.url, folder, "A folder can’t go inside itself")
                    continue
                }
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    exclude(.move, item.url, folder, "“\(folder.lastPathComponent)” is a file, not a folder")
                    continue
                }
                needFolder(folder)
                claim(.move, item, folder.appending(path: item.name))

            case let .createFolder(text):
                switch resolveFolder(text, base: base, instruction: request.instruction) {
                case let .success(folder):
                    var isDirectory: ObjCBool = false
                    if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
                        if !isDirectory.boolValue { exclude(.createFolder, nil, folder, "A file named “\(folder.lastPathComponent)” exists") }
                    } else {
                        needFolder(folder)
                    }
                case let .failure(problem): exclude(.createFolder, nil, nil, problem.message)
                }

            case let .trash(url):
                guard let item = selection[key(url)] else { exclude(.trash, url, nil, "Not part of the selection"); continue }
                guard touched.insert(key(item.url)).inserted else { exclude(.trash, url, nil, "Already changed by another step"); continue }
                vacated.insert(key(item.url))
                steps.append(PlanStep(id: nextID, kind: .trash, source: item.url, destination: nil))
                nextID += 1
            }
        }

        // A destination inside a selected item that this plan renames, moves or trashes would go missing.
        let changing = steps.compactMap { $0.kind == .createFolder ? nil : $0.source }
        var kept: [PlanStep] = []
        for step in steps {
            if step.kind == .move, let destination = step.destination,
               let changed = changing.first(where: { isInside(destination.deletingLastPathComponent(), $0) || key(destination.deletingLastPathComponent()) == key($0) }),
               changed != step.source {
                excluded.append(PlanStep(id: step.id, kind: step.kind, source: step.source, destination: destination, isEnabled: false,
                                         problem: "“\(changed.lastPathComponent)” is changed by this plan too"))
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
        if name.isEmpty { return "The new name is empty" }
        if name == "." || name == ".." { return "“\(name)” isn’t a valid name" }
        if name.contains("/") { return "Names can’t contain “/”" }
        if name.contains(":") { return "Names can’t contain “:”" }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "The name has invisible characters" }
        if name.hasPrefix(".") { return "Names starting with “.” are hidden" }
        if name.utf8.count > 255 { return "The name is too long" }
        return nil
    }

    struct Problem: Error {
        let message: String
    }

    /// A folder for a move or a new folder: relative to `base`, or a `~`/absolute path that the instruction itself names.
    static func resolveFolder(_ raw: String, base: URL, instruction: String) -> Result<URL, Problem> {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return .failure(Problem(message: "No folder name")) }

        let folder: URL
        if text.hasPrefix("~") || text.hasPrefix("/") {
            folder = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
            let named = instruction.localizedCaseInsensitiveContains(text)
                || instruction.localizedCaseInsensitiveContains(folder.path)
            if !isInside(folder, base), !named {
                return .failure(Problem(message: "Outside “\(base.lastPathComponent)” and not named in your request"))
            }
        } else {
            let components = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.contains(where: { $0 == ".." || $0 == "." }) { return .failure(Problem(message: "Folder paths can’t go up a level")) }
            if let problem = components.lazy.compactMap(nameProblem).first { return .failure(Problem(message: problem)) }
            folder = components.reduce(base) { $0.appending(path: $1, directoryHint: .isDirectory) }.standardizedFileURL
        }
        // Symlinked folders could point anywhere: judge by where the nearest existing ancestor really is.
        var existing = folder
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing = existing.deletingLastPathComponent() }
        let real = existing.resolvingSymlinksInPath()
        let realBase = base.resolvingSymlinksInPath()
        if isInside(folder, base), !(key(real) == key(realBase) || isInside(real, realBase)) {
            return .failure(Problem(message: "“\(existing.lastPathComponent)” links outside “\(base.lastPathComponent)”"))
        }
        return .success(folder)
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        let parent = folder.standardizedFileURL.path.lowercased()
        return path.hasPrefix(parent == "/" ? "/" : parent + "/") && path != parent
    }

    /// Paths compare case-insensitively (APFS default).
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }
}
