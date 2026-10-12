import AppKit

/// Go ▸ Connect to Server…: an address (with recent ones to pick), then macOS's own login window, then the share opens.
final class ConnectToServerController: NSViewController, NSComboBoxDelegate, NSControlTextEditingDelegate {
    /// Called with where the share is mounted.
    var onConnected: ((URL) -> Void)?

    private let address = NSComboBox()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton(title: String(localized: "Connect", comment: "Button: connect to the server"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private var request: ServerConnection.Request?

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Connect to Server"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: String(localized: "smb://server/share, afp://, nfs:// or a WebDAV https:// address. A server name alone connects with SMB."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        address.placeholderString = "smb://server/share"
        address.addItems(withObjectValues: ServerConnection.recents)
        address.completes = true
        address.numberOfVisibleItems = 10
        address.delegate = self
        address.setAccessibilityLabel(String(localized: "Server address"))
        if let last = ServerConnection.recents.first { address.stringValue = last }

        message.font = .systemFont(ofSize: 11)
        message.textColor = .systemRed
        message.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        connectButton.keyEquivalent = "\r"
        let clear = NSButton(title: String(localized: "Clear Recents", comment: "Button: forget the recently used server addresses"), target: self, action: #selector(clearRecents(_:)))
        clear.bezelStyle = .accessoryBarAction
        clear.controlSize = .small
        clear.isHidden = ServerConnection.recents.isEmpty
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [clear, spacer, spinner, cancelButton, connectButton])
        footer.spacing = 8

        let stack = NSStackView(views: [title, address, hint, message, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(16, after: message)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 460),
            address.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        message.isHidden = true
    }

    @objc private func connect(_ sender: Any?) {
        guard request == nil else { return }
        let url: URL
        switch ServerConnection.url(from: address.stringValue) {
        case .success(let parsed): url = parsed
        case .failure(let problem): return show(problem.message)
        }
        let request = ServerConnection.Request()
        self.request = request
        setBusy(true)
        Task { [weak self] in
            let result = await ServerConnection.mount(url, request: request)
            guard let self else { return }
            self.request = nil
            setBusy(false)
            switch result {
            case .success(let mounted):
                ServerConnection.remember(url)
                dismiss(nil)
                onConnected?(mounted)
            case .failure(let problem):
                show(problem.message)
            case nil:
                break
            }
        }
    }

    @objc private func cancel(_ sender: Any?) {
        // Stops a connection under way; the sheet stays for another try. Otherwise it closes.
        if let request {
            request.cancel()
            self.request = nil
            setBusy(false)
            return
        }
        dismiss(nil)
    }

    @objc private func clearRecents(_ sender: NSButton) {
        ServerConnection.clearRecents()
        address.removeAllItems()
        sender.isHidden = true
    }

    private func setBusy(_ busy: Bool) {
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        connectButton.isEnabled = !busy
        address.isEnabled = !busy
        if busy { message.isHidden = true }
    }

    private func show(_ text: String) {
        message.stringValue = text
        message.isHidden = false
    }
}
