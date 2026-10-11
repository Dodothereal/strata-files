import Foundation
import FoundationModels

/// A whole-selection transformation ("rename by date taken", "group by year"). The model (or the rules) picks a recipe and
/// Strata expands it over every item deterministically: this scales past what fits in the model's context, and dates,
/// numbering and collisions are computed exactly rather than generated.
nonisolated struct PlanRecipe: Sendable, Hashable {
    enum Action: Sendable, Hashable {
        /// Template tokens: {date} {time} {datetime} {year} {month} {monthname} {day} {name} {n} {camera} {kind} {parent}.
        case rename(template: String, transforms: [NameTransform])
        case move(folder: String)
        case group(by: GroupKey, inside: String?)
        case trash
    }

    enum GroupKey: String, Sendable, CaseIterable { case year, month, day, kind, `extension`, camera }
    enum DateSource: String, Sendable, CaseIterable { case taken, created, modified, best }
    enum NameTransform: String, Sendable, CaseIterable { case lowercase, uppercase, titlecase, spacesToDashes, spacesToUnderscores, removeSpaces }

    var action: Action
    /// Which selected items it applies to (metadata only; empty = all).
    var filter = SearchFilter()
    var dateSource = DateSource.best

    /// "Rename by date taken", "Move into “Archive” — only images named “Screenshot”, modified before Sep 11, 2026".
    var title: String {
        let dateWord: String = switch dateSource {
        case .taken: "date taken"
        case .created: "date created"
        case .modified: "date modified"
        case .best: "date"
        }
        var text: String
        switch action {
        case let .rename(template, transforms):
            let datey = ["{date}", "{time}", "{datetime}", "{year}", "{month}", "{day}"].contains { template.contains($0) }
            if template == "{name}" {
                text = "Rename: " + transforms.map(\.title).joined(separator: ", ")
            } else if datey, template.hasPrefix("{name}") {
                text = "Add the \(dateWord) after each name"
            } else if datey, template.contains("{name}") {
                text = "Add the \(dateWord) before each name"
            } else if datey {
                let withTime = template.contains("{time}") || template.contains("{datetime}")
                text = "Rename by " + (withTime ? dateWord.replacingOccurrences(of: "date", with: "date and time") : dateWord)
            } else if template.hasSuffix(" {n}"), !template.dropLast(4).contains("{") {
                let base = template.dropLast(4)
                text = "Number them “\(base) 01”, “\(base) 02”, …"
            } else {
                text = "Rename to “\(Self.readable(template))”"
            }
            if template != "{name}", !transforms.isEmpty { text += ", " + transforms.map(\.title).joined(separator: ", ") }
        case let .move(folder): text = "Move into “\(folder)”"
        case let .group(key, inside):
            let by: String = switch key {
            case .year, .month, .day: dateSource == .best ? key.rawValue : "\(key.rawValue) (\(dateWord))"
            case .kind: "kind"
            case .extension: "extension"
            case .camera: "camera"
            }
            text = "Group into folders by \(by)" + (inside.map { " inside “\($0)”" } ?? "")
        case .trash: text = "Move to the Trash"
        }
        if let only = Self.describe(filter) { text += " — only \(only)" }
        return text
    }

    /// "{year}-{month} {name}" → "year-month name".
    static func readable(_ template: String) -> String {
        let words = ["{date}": "date", "{time}": "time", "{datetime}": "date time", "{year}": "year", "{month}": "month",
                     "{monthname}": "month name", "{day}": "day", "{name}": "name", "{n}": "number", "{camera}": "camera",
                     "{kind}": "kind", "{parent}": "folder name"]
        return words.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// "images named “Screenshot”, modified before Sep 11, 2026", or nil for no constraints.
    static func describe(_ filter: SearchFilter) -> String? {
        var head: [String] = []
        if !filter.kinds.isEmpty {
            let titles = SearchFilter.Kind.allCases.filter(filter.kinds.contains).map { $0 == .pdf ? "PDFs" : $0.title.lowercased() }
            head.append(titles.joined(separator: " and "))
        }
        if !filter.extensions.isEmpty { head.append(filter.extensions.sorted().map { "." + $0 }.joined(separator: ", ")) }
        if head.isEmpty, !filter.nameContains.isEmpty { head.append("items") }
        if !filter.nameContains.isEmpty { head.append("named " + filter.nameContains.map { "“\($0)”" }.joined(separator: " + ")) }
        var tail: [String] = []
        if let dates = filter.dateDescription { tail.append(dates.prefix(1).lowercased() + dates.dropFirst()) }
        if let min = filter.minSize { tail.append("over " + ByteCountFormatter.string(fromByteCount: min, countStyle: .file)) }
        if let max = filter.maxSize { tail.append("under " + ByteCountFormatter.string(fromByteCount: max, countStyle: .file)) }
        if head.isEmpty, tail.isEmpty { return nil }
        if head.isEmpty { head.append("items") }
        return ([head.joined(separator: " ")] + tail).joined(separator: ", ")
    }
}

nonisolated extension PlanRecipe.NameTransform {
    var title: String {
        switch self {
        case .lowercase: "lowercase"
        case .uppercase: "uppercase"
        case .titlecase: "title case"
        case .spacesToDashes: "spaces → dashes"
        case .spacesToUnderscores: "spaces → underscores"
        case .removeSpaces: "remove spaces"
        }
    }

    func apply(_ name: String) -> String {
        switch self {
        case .lowercase: name.lowercased()
        case .uppercase: name.uppercased()
        case .titlecase: name.capitalized
        case .spacesToDashes: name.split(separator: " ", omittingEmptySubsequences: true).joined(separator: "-")
        case .spacesToUnderscores: name.split(separator: " ", omittingEmptySubsequences: true).joined(separator: "_")
        case .removeSpaces: name.replacingOccurrences(of: " ", with: "")
        }
    }
}

nonisolated enum PlanError: LocalizedError {
    case notUnderstood(suggestions: [String])
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .notUnderstood:
            switch AIModel.status {
            case .available: break
            case .appleIntelligenceNotEnabled:
                return "Strata’s built-in rules don’t cover this request. Turn on Apple Intelligence to plan anything you can describe."
            default:
                return "Strata’s built-in rules don’t cover this request. \(AIModel.explanation ?? "")"
            }
            return "Strata couldn’t turn this request into file operations. Try rephrasing it."
        case .nothingSelected: return "Select the files you want to change first."
        }
    }
}

/// Instruction + selection → validated `Plan`.
nonisolated enum PlanGenerator {
    struct Request: Sendable {
        var instruction: String
        var items: [PlanItem]
        /// The window's folder: new folders and moves stay inside it unless the instruction names another place.
        var baseFolder: URL
        var now = Date()
    }

    static func generate(_ request: Request, allowModel: Bool = true) async throws -> Plan {
        guard !request.items.isEmpty else { throw PlanError.nothingSelected }
        let rules = PlanRules.recipe(for: request.instruction, now: request.now)
        let useModel = allowModel && AIModel.isAvailable && (rules == nil || rules?.fullyUnderstood == false)
        if useModel {
            do {
                let answer = try await ModelPlanner.plan(request)
                switch answer {
                case let .recipe(recipe):
                    return PlanValidator.validate(expanding: recipe, request: request, source: .model)
                case let .explicit(operations, summary):
                    return PlanValidator.validate(operations, request: request, source: .model, interpretation: summary)
                case .unsupported:
                    break
                }
            } catch {
                // Fall through to the rules, if they had an idea.
            }
        }
        if let rules {
            return PlanValidator.validate(expanding: rules.recipe, request: request, source: .rules)
        }
        throw PlanError.notUnderstood(suggestions: suggestions(for: request.items))
    }

    /// Instructions that fit the selection, for the sheet's suggestion buttons.
    static func suggestions(for items: [PlanItem]) -> [String] {
        var result: [String] = []
        let images = items.filter { $0.contentType?.conforms(to: .image) == true }
        if images.contains(where: { $0.captureDate != nil }) { result.append("Rename these photos by date taken") }
        if items.contains(where: { $0.name.hasPrefix("Screenshot") || $0.name.hasPrefix("Screen Shot") }) {
            result.append("Move screenshots older than 30 days into an Archive folder")
        }
        if items.count >= 3 {
            let pdfs = items.filter { $0.contentType?.conforms(to: .pdf) == true }
            result.append(pdfs.count >= 2 ? "Group these PDFs into folders by year" : "Group into folders by year")
        }
        if Set(items.map { $0.ext.lowercased() }).count > 2 { result.append("Group into folders by kind") }
        if items.contains(where: { $0.name.contains(" ") }) { result.append("Lowercase names and replace spaces with dashes") }
        return Array(result.prefix(4))
    }
}

// MARK: - Rules

/// Deterministic instruction → recipe for the common requests. Works without Apple Intelligence.
nonisolated enum PlanRules {
    struct Result {
        let recipe: PlanRecipe
        /// No meaningful words were left unexplained (otherwise the model, when available, gets a say).
        let fullyUnderstood: Bool
    }

    static func recipe(for instruction: String, now: Date = .now) -> Result? {
        let text = instruction.lowercased()
        let dateSource = Self.dateSource(text)
        var filter = itemFilter(instruction, now: now)

        var action: PlanRecipe.Action?
        var explained: [String] = []

        if let group = match(text, "\\b(?:group|sort|organi[sz]e|split|file|arrange|categori[sz]e)\\b.*?\\bby\\s+(year|month|day|date|type|kind|extension|file type|format|camera)") {
            let key: PlanRecipe.GroupKey = switch group[1] {
            case "year": .year
            case "month", "date": .month
            case "day": .day
            case "extension", "format": .extension
            case "camera": .camera
            default: .kind
            }
            let inside = match(instruction, "(?i)\\binside\\s+(?:a\\s+|the\\s+)?(?:folder\\s+(?:called|named)\\s+)?[\"“]?([^\"”]+?)[\"”]?(?:\\s+folder)?\\s*$")?[1]
            action = .group(by: key, inside: inside)
            explained += ["group", "sort", "organize", "organise", "split", "arrange", "into", "folders", "folder", "by", group[1]]
        } else if let transforms = Optional(nameTransforms(text)),
                  text.range(of: "\\b(?:rename|name them|name these)\\b", options: .regularExpression) != nil || !transforms.isEmpty
                    || text.range(of: "\\b(?:add|put|prepend|append|insert)\\b.*\\bdates?\\b", options: .regularExpression) != nil {
            var template = "{name}"
            if text.range(of: "\\b(?:suffix|append|at the end|after the name)\\b", options: .regularExpression) != nil, text.contains("date") {
                template = "{name} {date}"
            } else if text.range(of: "\\b(?:prefix|prepend|in front|before the name|at the start|add|put|insert)\\b", options: .regularExpression) != nil, text.contains("date") {
                template = "{date} {name}"
            } else if text.range(of: "\\bby\\s+(?:the\\s+)?(?:date|day|time|when)|\\b(?:date taken|taken|capture date|creation date|modified date|date created|date modified)\\b|\\bto (?:the )?date", options: .regularExpression) != nil {
                template = dateSource == .taken ? "{date} {time}" : "{date} {name}"
            } else if let sequence = match(instruction, "(?i)\\b(?:to|as)\\s+[\"“]?(.+?)[\"”]?\\s*(?:\\d+\\s*,.*|followed by (?:a )?numbers?|with (?:a )?(?:number|numbers|counter)|sequentially|numbered|in order|\\{n\\}|#)?\\s*$"),
                      transforms.isEmpty {
                let base = sequence[1].trimmingCharacters(in: .whitespaces)
                if !base.isEmpty, base.count < 60 { template = base.contains("{") ? base : base + " {n}" }
            } else if text.range(of: "\\b(?:sequential|number them|numbered|with numbers)\\b", options: .regularExpression) != nil {
                template = "{parent} {n}"
            }
            guard template != "{name}" || !transforms.isEmpty else { return nil }
            action = .rename(template: template, transforms: transforms)
            explained += ["rename", "by", "date", "taken", "to", "as", "prefix", "suffix", "with", "lowercase", "uppercase", "replace",
                          "spaces", "dashes", "underscores", "names", "name", "and", "numbered", "sequentially", "add", "the", "remove",
                          "time", "capture", "created", "modified", "creation", "when"]
        } else if text.range(of: "\\b(?:move|put|archive|file|place|drop)\\b", options: .regularExpression) != nil,
                  let parts = match(instruction, "(?i)^(.*)\\s(?:into|to|in)\\s+(?:an?\\s+|the\\s+|a\\s+new\\s+|my\\s+)?(?:folder\\s+(?:called|named)\\s+)?[\"“]?([^\"”]+?)[\"”]?(?:\\s+folder)?\\s*$"),
                  !parts[2].trimmingCharacters(in: .whitespaces).isEmpty {
            // "move screenshots older than 30 days | into an Archive folder": constraints come from the first part.
            action = .move(folder: parts[2].trimmingCharacters(in: .whitespaces))
            filter = itemFilter(parts[1], now: now)
            explained += ["move", "put", "archive", "file", "place", "into", "to", "in", "folder", "a", "an", "new"]
            explained += parts[2].lowercased().split(separator: " ").map(String.init)
        } else if text.range(of: "^\\s*archive\\b", options: .regularExpression) != nil {
            action = .move(folder: "Archive")
            explained += ["archive"]
        } else if text.range(of: "\\b(?:delete|trash|remove|bin|throw away|get rid of)\\b", options: .regularExpression) != nil {
            action = .trash
            explained += ["delete", "trash", "remove", "bin", "throw", "away", "get", "rid", "of", "move", "to"]
        }
        guard let action else { return nil }

        // Anything left that neither the action nor the item filter explains?
        let interpretation = QueryInterpreter.parse(instruction, now: now)
        let unexplained = interpretation.unrecognized.filter { word in
            !explained.contains(word) && !["these", "those", "them", "all", "photos", "files", "items", "selected", "selection",
                                            "pictures", "images", "folder", "folders", "into", "separate"].contains(word)
        }
        return Result(recipe: PlanRecipe(action: action, filter: filter, dateSource: dateSource), fullyUnderstood: unexplained.isEmpty)
    }

    static func nameTransforms(_ text: String) -> [PlanRecipe.NameTransform] {
        var transforms: [PlanRecipe.NameTransform] = []
        if text.contains("lowercase") || text.contains("lower case") { transforms.append(.lowercase) }
        if text.contains("uppercase") || text.contains("upper case") { transforms.append(.uppercase) }
        if text.contains("title case") || text.contains("capitali") { transforms.append(.titlecase) }
        if text.range(of: "spaces? (?:with|to|into|by) (?:dash|hyphen)", options: .regularExpression) != nil { transforms.append(.spacesToDashes) }
        if text.range(of: "spaces? (?:with|to|into|by) underscore", options: .regularExpression) != nil { transforms.append(.spacesToUnderscores) }
        if text.range(of: "remove (?:the |all )?spaces", options: .regularExpression) != nil { transforms.append(.removeSpaces) }
        return transforms
    }

    /// Which items an instruction is about ("these PDFs", "screenshots older than 30 days"), ignoring its own wording about
    /// destinations ("into folders by year" is not a request for folders).
    static func itemFilter(_ text: String, now: Date) -> SearchFilter {
        var cleaned = text
        for pattern in ["(?i)\\b(?:into|in|to)\\s+(?:separate\\s+|sub|new\\s+)?folders?\\b", "(?i)\\bby\\s+(?:the\\s+)?(?:year|month|day|date|type|kind|extension|file type|format|camera)\\b",
                        "(?i)\\b(?:a|an|the|new)\\s+folder\\s+(?:called|named)\\s+\\S+", "(?i)\\bfolders?\\b(?=\\s+(?:by|for|per))",
                        "(?i)\\b(?:date taken|taken|captured|date created|date modified)\\b"] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        var filter = QueryInterpreter.parse(cleaned, now: now).filter
        filter.keywords = []
        filter.contentQuery = nil
        return filter
    }

    static func dateSource(_ text: String) -> PlanRecipe.DateSource {
        if text.range(of: "\\b(?:date taken|taken|capture|captured|shot|exif|camera date)\\b", options: .regularExpression) != nil { return .taken }
        if text.range(of: "\\b(?:created|creation|date created)\\b", options: .regularExpression) != nil { return .created }
        if text.range(of: "\\b(?:modified|modification|last changed|date modified|edited)\\b", options: .regularExpression) != nil { return .modified }
        return .best
    }

    /// Capture groups of the first match ([0] = whole match).
    static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : (text as NSString).substring(with: m.range(at: $0)) }
    }
}

// MARK: - Model

/// Guided generation: the model either picks a recipe (preferred) or, for small selections and one-off requests, lists
/// explicit operations by item number. Either way the output is constrained by the schema and validated afterwards.
nonisolated enum ModelPlanner {
    enum Answer: Sendable {
        case recipe(PlanRecipe)
        case explicit([ProposedOperation], summary: String)
        case unsupported
    }

    static let maxListedItems = 40

    static func schema() throws -> GenerationSchema {
        let kinds = Schema.choice("ItemKind", SearchFilter.Kind.allCases.map(\.rawValue))
        let match = Schema.object("Match", "Which of the listed items the plan applies to; leave empty for all", [
            Schema.field("kinds", nil, Schema.array(kinds, max: 4)),
            Schema.field("extensions", "Without the dot", Schema.array(Schema.string(), max: 6)),
            Schema.field("nameContains", nil, Schema.array(Schema.string(), max: 3)),
            Schema.field("olderThanDays", nil, Schema.integer(1...36500), optional: true),
            Schema.field("newerThanDays", nil, Schema.integer(1...36500), optional: true),
        ])
        let operation = Schema.object("Operation", nil, [
            Schema.field("item", "The item's number in the list", Schema.integer(1...maxListedItems)),
            Schema.field("op", nil, Schema.choice("OperationKind", ["rename", "move", "trash"])),
            Schema.field("newName", "For rename: the full new name including the extension", Schema.string(), optional: true),
            Schema.field("folder", "For move: destination folder name, relative to the current folder", Schema.string(), optional: true),
        ])
        return try Schema.root(Schema.object("FilePlan", nil, [
            Schema.field("action", "rename/move/group/trash apply one rule to all matching items; explicit lists operations one by one; unsupported if the request isn't about renaming, moving, grouping or deleting files",
                         Schema.choice("PlanAction", ["rename", "move", "group", "trash", "explicit", "unsupported"])),
            Schema.field("template", "For rename: new name pattern without extension, using {date} {time} {year} {month} {day} {name} {n} {camera}",
                         Schema.string(), optional: true),
            Schema.field("dateSource", "Which date {date}, {year} and group-by-date use",
                         Schema.choice("DateSource", PlanRecipe.DateSource.allCases.map(\.rawValue))),
            Schema.field("groupBy", nil, Schema.choice("GroupKey", PlanRecipe.GroupKey.allCases.map(\.rawValue)), optional: true),
            Schema.field("folder", "For move: destination folder; for group: optional parent folder", Schema.string(), optional: true),
            Schema.field("match", nil, match, optional: true),
            Schema.field("operations", "Only for explicit", Schema.array(operation, max: maxListedItems)),
            Schema.field("summary", "One short sentence describing the plan", Schema.string()),
        ]))
    }

    static func listing(_ items: [PlanItem], now: Date) -> String {
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        var lines: [String] = []
        for (index, item) in items.prefix(maxListedItems).enumerated() {
            var parts = ["\(index + 1). \(item.name)", item.isFolder ? "folder" : item.kind]
            if let size = item.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
            if let taken = item.captureDate { parts.append("taken \(taken.formatted(day)) \(taken.formatted(time))") }
            if let created = item.created { parts.append("created \(created.formatted(day))") }
            if let modified = item.modified { parts.append("modified \(modified.formatted(day))") }
            if let camera = item.cameraModel { parts.append("camera \(camera)") }
            lines.append(parts.joined(separator: ", "))
        }
        if items.count > maxListedItems { lines.append("…and \(items.count - maxListedItems) more items like these.") }
        return lines.joined(separator: "\n")
    }

    static func plan(_ request: PlanGenerator.Request) async throws -> Answer {
        let today = request.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let instructions = """
        You plan file operations in a Mac file manager. Today is \(today). The user selected the numbered items below in the folder \
        “\(request.baseFolder.lastPathComponent)” and gave an instruction. Prefer one rule (rename/move/group/trash) that applies to \
        every matching item; use explicit only when items need different treatment. Never invent items. Folder paths are relative \
        to the current folder unless the user named another place.
        """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Items:\n\(listing(request.items, now: request.now))\n\nInstruction: \(request.instruction)"
        let content = try await Deadline.run(25) {
            try await session.respond(to: prompt, schema: try schema(),
                                      options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1200)).content
        }
        return decode(content, items: request.items, now: request.now)
    }

    /// Model output → recipe or explicit operations. Item numbers outside the list are dropped (and so can't touch anything).
    static func decode(_ content: GeneratedContent, items: [PlanItem], now: Date) -> Answer {
        let dateSource = content["dateSource"]?.string.flatMap(PlanRecipe.DateSource.init(rawValue:)) ?? .best
        var filter = SearchFilter()
        if let match = content["match"] {
            filter.kinds = Set(match["kinds"]?.strings.compactMap(SearchFilter.Kind.init(rawValue:)) ?? [])
            filter.extensions = Set((match["extensions"]?.strings ?? []).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
            filter.nameContains = match["nameContains"]?.strings ?? []
            if let days = match["olderThanDays"]?.integer { filter.modifiedBefore = Calendar.current.date(byAdding: .day, value: -days, to: now) }
            if let days = match["newerThanDays"]?.integer { filter.modifiedAfter = Calendar.current.date(byAdding: .day, value: -days, to: now) }
        }
        let folder = content["folder"]?.meaningfulString
        switch content["action"]?.string {
        case "rename":
            guard let template = content["template"]?.meaningfulString else { return .unsupported }
            return .recipe(PlanRecipe(action: .rename(template: template, transforms: []), filter: filter, dateSource: dateSource))
        case "move":
            guard let folder else { return .unsupported }
            return .recipe(PlanRecipe(action: .move(folder: folder), filter: filter, dateSource: dateSource))
        case "group":
            guard let key = content["groupBy"]?.string.flatMap(PlanRecipe.GroupKey.init(rawValue:)) else { return .unsupported }
            return .recipe(PlanRecipe(action: .group(by: key, inside: folder), filter: filter, dateSource: dateSource))
        case "trash":
            return .recipe(PlanRecipe(action: .trash, filter: filter, dateSource: dateSource))
        case "explicit":
            var operations: [ProposedOperation] = []
            for operation in content["operations"]?.array ?? [] {
                guard let number = operation["item"]?.integer, number >= 1, number <= min(items.count, maxListedItems) else { continue }
                let url = items[number - 1].url
                switch operation["op"]?.string {
                case "rename": if let name = operation["newName"]?.meaningfulString { operations.append(.rename(url, to: name)) }
                case "move": if let folder = operation["folder"]?.meaningfulString { operations.append(.move(url, into: folder)) }
                case "trash": operations.append(.trash(url))
                default: break
                }
            }
            return operations.isEmpty ? .unsupported : .explicit(operations, summary: content["summary"]?.meaningfulString ?? "Custom plan")
        default:
            return .unsupported
        }
    }
}

// MARK: - Expansion

/// Recipe × selection → proposed operations (plus items it had to skip, with reasons).
nonisolated enum PlanExpander {
    struct Output {
        var operations: [ProposedOperation] = []
        var skipped: [(item: PlanItem, reason: String)] = []
        var unaffected = 0
    }

    static func expand(_ recipe: PlanRecipe, items: [PlanItem], baseFolder: URL) -> Output {
        var output = Output()
        let matching = items.filter { item in
            recipe.filter.isEmpty || recipe.filter.matches(name: item.name, contentType: item.contentType, isDirectory: item.isFolder,
                                                           size: item.size, modified: item.modified)
        }
        output.unaffected = items.count - matching.count

        switch recipe.action {
        case let .rename(template, transforms):
            let needsDate = ["{date}", "{time}", "{datetime}", "{year}", "{month}", "{monthname}", "{day}"].contains { template.contains($0) }
            var dated: [PlanItem] = []
            for item in matching {
                if needsDate, item.date(recipe.dateSource) == nil {
                    output.skipped.append((item, recipe.dateSource == .taken ? "No date taken in its metadata" : "No date available"))
                } else {
                    dated.append(item)
                }
            }
            // Number in date order (then name), so {n} follows the timeline.
            dated.sort { ($0.date(recipe.dateSource) ?? .distantPast, $0.name) < ($1.date(recipe.dateSource) ?? .distantPast, $1.name) }
            let width = max(2, String(dated.count).count)
            var taken = Self.occupiedNames(for: dated)
            for (index, item) in dated.enumerated() {
                var base = render(template, item: item, index: index + 1, width: width, source: recipe.dateSource)
                for transform in transforms { base = transform.apply(base) }
                base = base.trimmingCharacters(in: .whitespaces)
                let name = unique(base, ext: item.ext, folder: item.url.deletingLastPathComponent(), taken: &taken)
                output.operations.append(.rename(item.url, to: name))
            }
        case let .move(folder):
            output.operations = matching.map { .move($0.url, into: folder) }
        case let .group(key, inside):
            for item in matching.sorted(by: { (groupName($0, key: key, source: recipe.dateSource) ?? "", $0.name) < (groupName($1, key: key, source: recipe.dateSource) ?? "", $1.name) }) {
                // Folders have no kind or extension to sort by: leave them where they are.
                if item.isFolder, key == .kind || key == .extension {
                    output.unaffected += 1
                    continue
                }
                guard let name = groupName(item, key: key, source: recipe.dateSource) else {
                    output.skipped.append((item, key == .camera ? "No camera in its metadata" : "No date available"))
                    continue
                }
                output.operations.append(.move(item.url, into: inside.map { $0 + "/" + name } ?? name))
            }
        case .trash:
            output.operations = matching.map { .trash($0.url) }
        }
        return output
    }

    static func render(_ template: String, item: PlanItem, index: Int, width: Int, source: PlanRecipe.DateSource) -> String {
        let date = item.date(source) ?? item.bestDate ?? Date()
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        let values: [String: String] = [
            "date": format("yyyy-MM-dd"), "time": format("HH.mm.ss"), "datetime": format("yyyy-MM-dd HH.mm.ss"),
            "year": format("yyyy"), "month": format("MM"), "monthname": format("MMMM"), "day": format("dd"),
            "name": item.baseName, "n": String(repeating: "0", count: max(0, width - String(index).count)) + String(index),
            "camera": item.cameraModel ?? "Unknown camera", "kind": item.kind, "parent": item.url.deletingLastPathComponent().lastPathComponent,
        ]
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let token = rest[rest.index(after: open)..<close].lowercased()
            result += values[token] ?? ""
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        // A model may include the extension in the template; it is added back separately.
        if !item.ext.isEmpty, result.lowercased().hasSuffix("." + item.ext.lowercased()) { result.removeLast(item.ext.count + 1) }
        return result
    }

    static func groupName(_ item: PlanItem, key: PlanRecipe.GroupKey, source: PlanRecipe.DateSource) -> String? {
        let date = item.date(source) ?? (source == .taken ? nil : item.bestDate)
        let calendar = Calendar.current
        switch key {
        case .year: return date.map { String(calendar.component(.year, from: $0)) }
        case .month: return date.map { String(format: "%04d-%02d", calendar.component(.year, from: $0), calendar.component(.month, from: $0)) }
        case .day:
            return date.map { String(format: "%04d-%02d-%02d", calendar.component(.year, from: $0), calendar.component(.month, from: $0),
                                     calendar.component(.day, from: $0)) }
        case .extension: return item.isFolder ? "Folders" : item.ext.isEmpty ? "No Extension" : item.ext.uppercased()
        case .camera: return item.cameraModel
        case .kind:
            if item.isFolder { return "Folders" }
            let order: [SearchFilter.Kind] = [.pdf, .image, .movie, .audio, .archive, .spreadsheet, .presentation, .code, .text, .diskImage, .application, .document]
            let kind = order.first { $0.matches(type: item.contentType, isDirectory: false, isPackage: false, extension: item.ext.lowercased()) }
            return kind?.title ?? "Other"
        }
    }

    /// Lowercased names already used in each folder by items that aren't being renamed.
    private static func occupiedNames(for renamed: [PlanItem]) -> [URL: Set<String>] {
        var result: [URL: Set<String>] = [:]
        let renamedPaths = Set(renamed.map { $0.url.path.lowercased() })
        for folder in Set(renamed.map { $0.url.deletingLastPathComponent() }) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            result[folder] = Set(names.filter { !renamedPaths.contains(folder.appending(path: $0).path.lowercased()) }.map { $0.lowercased() })
        }
        return result
    }

    /// "2024-05-12 14.03.22.JPG", then "2024-05-12 14.03.22 2.JPG" for a second photo taken the same second.
    private static func unique(_ base: String, ext: String, folder: URL, taken: inout [URL: Set<String>]) -> String {
        func full(_ base: String) -> String { ext.isEmpty ? base : base + "." + ext }
        var candidate = full(base)
        var counter = 2
        while taken[folder, default: []].contains(candidate.lowercased()) {
            candidate = full("\(base) \(counter)")
            counter += 1
        }
        taken[folder, default: []].insert(candidate.lowercased())
        return candidate
    }
}
