import AppKit

enum ListColumn: String, CaseIterable {
    case modified, created, added, size, kind
    case fileExtension = "extension"
    case dimensions, width, height, duration

    var title: String {
        switch self {
        case .modified: String(localized: "Date Modified")
        case .created: String(localized: "Date Created")
        case .added: String(localized: "Date Added")
        case .size: String(localized: "Size")
        case .kind: String(localized: "Kind")
        case .fileExtension: String(localized: "Extension", comment: "List column: the file name extension")
        case .dimensions: String(localized: "Dimensions", comment: "List column: image or movie dimensions in pixels")
        case .width: String(localized: "Width", comment: "List column: image or movie width in pixels")
        case .height: String(localized: "Height", comment: "List column: image or movie height in pixels")
        case .duration: String(localized: "Duration", comment: "List column: playing time of a movie or audio file")
        }
    }

    var isMedia: Bool { [.dimensions, .width, .height, .duration].contains(self) }
    var ascending: Bool { [.kind, .fileExtension].contains(self) }
    var preferredWidth: CGFloat {
        switch self {
        case .modified, .created, .added: 170
        case .kind: 150
        case .dimensions: 130
        default: 84
        }
    }
    var minWidth: CGFloat {
        switch self {
        case .modified, .created, .added: 110
        case .kind, .dimensions: 80
        default: 60
        }
    }
    var alignment: NSTextAlignment { [.size, .width, .height, .duration].contains(self) ? .right : .left }

    static let initiallyHidden: Set<String> = ["created", "added", "extension", "dimensions", "width", "height", "duration"]

    /// New optional columns start hidden even for someone who already chose their columns in an older release.
    static func hidden(stored: [String]?, known: [String]?) -> Set<String> {
        let previous = Set(known ?? ["modified", "created", "size", "kind"])
        return Set(stored ?? Array(initiallyHidden)).union(initiallyHidden.subtracting(previous))
    }
}
