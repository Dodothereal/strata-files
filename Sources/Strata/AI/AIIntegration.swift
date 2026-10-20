import AppKit

/// App-wide AI services. Everything runs on this Mac; nothing is sent anywhere.
enum StrataAI {
    /// Content index over ~/Documents, ~/Desktop and ~/Downloads, stored in ~/Library/Application Support/Strata/semantic.
    static let index = SemanticIndex(configuration: SemanticIndex.Configuration(roots: SemanticIndex.standardRoots))

    private static var indexing: Task<Void, Never>?
    private(set) static var progress = SemanticIndexProgress(phase: .done)

    /// Starts a background indexing pass (no-op if one is running). Only roots that can be read without a consent prompt are
    /// indexed, so launching never triggers a wall of privacy dialogs.
    static func startIndexing(onProgress: (@MainActor @Sendable (SemanticIndexProgress) -> Void)? = nil) {
        guard indexing == nil else { return }
        let roots = SemanticIndex.standardRoots.filter { !Privacy.measuringWouldPrompt($0, browsing: Places.home) }
        guard !roots.isEmpty else { return }
        indexing = Task(priority: .utility) {
            await index.setRoots(roots)
            try? await index.update { update in
                Task { @MainActor in
                    progress = update
                    onProgress?(update)
                }
            }
            indexing = nil
        }
    }

    static func stopIndexing() {
        indexing?.cancel()
        indexing = nil
    }

    /// Search results as palette rows ("Content" matches, snippet as subtitle).
    static func paletteItems(for hits: [SemanticHit], open: @escaping (URL) -> Void) -> [PaletteItem] {
        hits.map { hit in
            var subtitle = hit.snippet
            if let page = hit.page {
                subtitle = String(localized: "p. \(page) · \(hit.snippet)",
                                  comment: "Content search result: the PDF page the matching text is on, then the text")
            }
            return PaletteItem(title: hit.title ?? hit.url.lastPathComponent, subtitle: subtitle,
                               icon: IconCache.shared.icon(forPath: hit.url.path), kind: .match,
                               fixedScore: Int(hit.score * 100)) { open(hit.url) }
        }
    }
}

extension BrowserWindowController {
    /// "Ask Strata…": plan-then-execute on the selection (or everything in the folder when nothing is selected).
    @objc func askStrata(_ sender: Any?) {
        presentAskStrata(instruction: nil)
    }

    func presentAskStrata(instruction: String?) {
        guard let window, window.attachedSheet == nil, !browser.isInsideArchive else { return }
        let urls = browser.selectedURLs.isEmpty ? browser.topLevelEntries.map(\.url) : browser.selectedURLs
        guard !urls.isEmpty else { return }
        let folder = location
        PlanSheetController.present(on: window, urls: urls, baseFolder: folder, undoManager: window.undoManager,
                                    instruction: instruction) { [weak self] outcome in
            guard let self, let outcome, !outcome.results.isEmpty else { return }
            browser.reloadFolder(nil)
            // Select what changed, once the reload has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                browser.select(outcome.results.filter { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL })
            }
            Task { for url in outcome.results { await StrataAI.index.refresh(url) } }
        }
    }

    /// Palette commands for the AI features, to append to `commandItems()`.
    func aiPaletteItems() -> [PaletteItem] {
        let subtitle = browser.selectedURLs.isEmpty ? String(localized: "Rename, move or organize everything here")
            : String(localized: "Rename, move or organize the selection")
        return paletteCommand(.askStrata, subtitle: subtitle).map { [$0] } ?? []
    }
}
