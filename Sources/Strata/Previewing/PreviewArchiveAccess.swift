import AppKit

/// Password and source ownership last only as long as this preview's archive. No credential is persisted.
@MainActor final class PreviewArchiveAccess {
    typealias Reader = @MainActor (PreviewArchiveSource, [String]?, Bool, String?) async throws -> [PreviewArchiveRecord]
    private let reader: Reader
    private(set) var source: PreviewArchiveSource?
    private var password: String?
    var requestPassword: ((String) async -> String?)?
    var cancelPassword: (() -> Void)?

    init(reader: @escaping Reader = { try await PreviewArchiveReader.read($0, member: $1, directory: $2, password: $3) }) {
        self.reader = reader
    }

    func reset(_ source: PreviewArchiveSource? = nil) {
        self.source = source
        password = nil
        cancelPassword?()
    }

    func read(member: [String]? = nil, directory: Bool = false, prompt: Bool = true) async throws -> [PreviewArchiveRecord] {
        guard let source else { throw PreviewArchiveError.unreadable }
        var attempts = 0
        while true {
            try Task.checkCancellation()
            guard self.source === source else { throw CancellationError() }
            do {
                let result = try await reader(source, member, directory, password)
                try Task.checkCancellation()
                guard self.source === source else { throw CancellationError() }
                return result
            }
            catch PreviewArchiveError.password {
                try Task.checkCancellation()
                guard self.source === source else { throw CancellationError() }
                guard prompt else { throw PreviewArchiveError.password }
                password = nil
                guard attempts < 3, let requestPassword else { throw PreviewArchiveError.password }
                attempts += 1
                let answer = await requestPassword(source.chosen.url.lastPathComponent)
                try Task.checkCancellation()
                guard self.source === source, let answer else { throw CancellationError() }
                password = answer
            }
        }
    }
}

@MainActor final class PreviewPasswordPrompt {
    private var alert: NSAlert?
    private var continuation: CheckedContinuation<String?, Never>?

    static func makeAlert(_ name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Archive Password")
        alert.informativeText = String(localized: "Enter the password for “\(name)”.")
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.setAccessibilityLabel(String(localized: "Archive Password"))
        alert.accessoryView = field
        ThemeStyle.bind(alert.window)
        return alert
    }

    func request(_ name: String, in window: NSWindow?) async -> String? {
        guard let window, window.isVisible, continuation == nil, !Task.isCancelled else { return nil }
        let alert = Self.makeAlert(name)
        guard let field = alert.accessoryView as? NSSecureTextField else { return nil }
        self.alert = alert
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                    guard let self, self.alert === alert else { return }
                    let answer = response == .alertFirstButtonReturn ? field.stringValue : nil
                    field.stringValue = ""
                    self.finish(answer)
                }
                alert.window.makeFirstResponder(field)
            }
        } onCancel: {
            Task { @MainActor [weak self, weak alert] in
                guard let self, self.alert === alert else { return }
                cancel()
            }
        }
    }

    func cancel() {
        guard let alert else { return }
        let window = alert.window
        // Detach the continuation first: ending the sheet can synchronously call its completion.
        finish(nil)
        window.sheetParent?.endSheet(window, returnCode: .cancel)
        window.orderOut(nil)
    }

    private func finish(_ value: String?) {
        (alert?.accessoryView as? NSSecureTextField)?.stringValue = ""
        let continuation = continuation
        self.continuation = nil
        alert = nil
        continuation?.resume(returning: value)
    }
}
