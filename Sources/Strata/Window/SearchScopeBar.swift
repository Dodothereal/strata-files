import AppKit

/// Shown under the toolbar while searching: where to search, how many matches, and saving the search.
final class SearchScopeBar: NSSplitViewItemAccessoryViewController {
    var onScopeChange: ((_ everywhere: Bool) -> Void)?
    var onSave: (() -> Void)?
    /// Match Case was switched (the search's `case:`).
    var onMatchCase: ((Bool) -> Void)?

    private let scope = NSSegmentedControl()
    private let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let save = NSButton()

    override func loadView() {
        scope.segmentStyle = .automatic
        scope.trackingMode = .selectOne
        scope.segmentCount = 2
        scope.setLabel("Everywhere", forSegment: 0)
        scope.selectedSegment = 0
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(scopeChanged)

        matchCase.controlSize = .small
        matchCase.font = .systemFont(ofSize: 11)
        matchCase.target = self
        matchCase.action = #selector(matchCaseChanged)
        matchCase.toolTip = "Names must match the letters’ case and accents exactly (case: in the search)"

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail

        save.bezelStyle = .accessoryBarAction
        save.controlSize = .small
        save.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        save.imagePosition = .imageLeading
        save.title = "Save Search"
        save.target = self
        save.action = #selector(saveClicked)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [scope, matchCase, summary, spacer, save])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 34),
        ])
        view = container
    }

    /// `caseApplies`: off for searches Spotlight or a plain-English reading answers (case means nothing there).
    func configure(folderName: String?, everywhere: Bool, matchCase: Bool, caseApplies: Bool) {
        loadViewIfNeeded()
        setMatchCase(matchCase, applies: caseApplies)
        if let folderName {
            scope.segmentCount = 2
            scope.setLabel("“\(folderName)”", forSegment: 1)
        } else {
            scope.segmentCount = 1
        }
        scope.selectedSegment = everywhere || folderName == nil ? 0 : 1
    }

    func setMatchCase(_ on: Bool, applies: Bool) {
        loadViewIfNeeded()
        matchCase.state = on ? .on : .off
        matchCase.isHidden = !applies && !on
    }

    func setSummary(_ text: String) {
        loadViewIfNeeded()
        summary.stringValue = text
    }

    @objc private func scopeChanged() {
        onScopeChange?(scope.selectedSegment == 0)
    }

    @objc private func matchCaseChanged() {
        onMatchCase?(matchCase.state == .on)
    }

    @objc private func saveClicked() {
        onSave?()
    }
}

/// Searches saved from the scope bar, shown in the sidebar.
nonisolated struct SavedSearch: Codable, Equatable, Sendable {
    var name: String
    var query: String
    var scopePath: String?
}

enum SavedSearches {
    private static let key = "savedSearches"

    static var all: [SavedSearch] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SavedSearch].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: .savedSearchesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let savedSearchesChanged = Notification.Name("StrataSavedSearchesChanged")
}
