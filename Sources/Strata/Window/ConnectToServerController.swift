import AppKit

/// Go ▸ Connect to Server…: a network share (SMB, AFP, NFS, WebDAV: macOS mounts it and asks for the login itself), an
/// SFTP server (through your Mac's own ssh: your ~/.ssh/config, keys and agent; a password is asked when needed), or an
/// S3 bucket (its secret key goes in your keychain). A server that connects is saved to the sidebar's Servers.
final class ConnectToServerController: NSViewController, NSComboBoxDelegate, NSControlTextEditingDelegate {
    enum Kind: Int { case share, sftp, s3 }

    /// Called with where the share is mounted.
    var onConnected: ((URL) -> Void)?
    /// Called with an SFTP server or bucket once it's connected and saved.
    var onServer: ((RemoteServer) -> Void)?

    /// Editing a saved server: its form, filled in; the kind can't change.
    private let editing: RemoteServer?
    private var kind: Kind

    private let kindPicker = NSSegmentedControl()
    private let address = NSComboBox()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let clearRecents = NSButton(title: String(localized: "Clear Recents", comment: "Button: forget the recently used server addresses"), target: nil, action: nil)
    private let s3Form = NSGridView()
    private let s3Name = NSTextField()
    private let s3Bucket = NSTextField()
    private let s3Region = NSTextField()
    private let s3Endpoint = NSTextField()
    private let s3KeyID = NSTextField()
    private let s3Secret = NSSecureTextField()
    private let s3PathStyle = NSButton(checkboxWithTitle: String(localized: "Path-style addresses (MinIO and most S3-compatible services)"), target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton(title: String(localized: "Connect", comment: "Button: connect to the server"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private var request: ServerConnection.Request?
    private var connecting: Task<Void, Never>?
    private var connectingID: String?

    init(editing server: RemoteServer? = nil) {
        editing = server
        kind = server.map { $0.kind == .s3 ? .s3 : .sftp } ?? Kind(rawValue: Prefs.shared.defaults.integer(forKey: "connectKind")) ?? .share
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: editing == nil ? String(localized: "Connect to Server")
                                    : String(localized: "Edit “\(editing!.name)”", comment: "Sheet title: editing a saved server"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        kindPicker.segmentCount = 3
        kindPicker.setLabel(String(localized: "Network Share", comment: "Connect to Server: SMB, AFP, NFS or WebDAV"), forSegment: 0)
        kindPicker.setLabel("SFTP", forSegment: 1)
        kindPicker.setLabel(String(localized: "S3 Bucket", comment: "Connect to Server: Amazon S3 or an S3-compatible service"), forSegment: 2)
        kindPicker.trackingMode = .selectOne
        kindPicker.selectedSegment = kind.rawValue
        kindPicker.target = self
        kindPicker.action = #selector(kindChanged(_:))
        kindPicker.isHidden = editing != nil

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        address.completes = true
        address.numberOfVisibleItems = 10
        address.delegate = self
        address.setAccessibilityLabel(String(localized: "Server address"))

        buildS3Form()

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
        if editing != nil { connectButton.title = String(localized: "Save", comment: "Button: save the edited server") }
        clearRecents.target = self
        clearRecents.action = #selector(clearRecents(_:))
        clearRecents.bezelStyle = .accessoryBarAction
        clearRecents.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [clearRecents, spacer, spinner, cancelButton, connectButton])
        footer.spacing = 8

        let stack = NSStackView(views: [title, kindPicker, address, s3Form, hint, message, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(14, after: kindPicker)
        stack.setCustomSpacing(16, after: message)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        ThemeStyle.bind(container, to: .content)
        container.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 480),
        ]
        for view in [address, s3Form, hint, message, footer] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        NSLayoutConstraint.activate(constraints)
        view = container
        showKind()
        if let editing { fill(editing) }
        ThemeStyle.refresh(container)
    }

    private func buildS3Form() {
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        s3Name.placeholderString = String(localized: "Optional", comment: "Placeholder: a field that can stay empty")
        s3Bucket.placeholderString = "my-bucket"
        s3Region.placeholderString = "us-east-1"
        s3Endpoint.placeholderString = String(localized: "Amazon S3 for the region", comment: "Placeholder: the endpoint field left empty means AWS")
        s3KeyID.placeholderString = "AKIA…"
        s3Secret.placeholderString = editing == nil ? "" : String(localized: "Unchanged", comment: "Placeholder: the secret key stays as saved")
        for field in [s3Name, s3Bucket, s3Region, s3Endpoint, s3KeyID, s3Secret] { field.delegate = self }
        s3Form.addRow(with: [label(String(localized: "Name", comment: "Field: what the sidebar calls the bucket")), s3Name])
        s3Form.addRow(with: [label(String(localized: "Bucket", comment: "Field: an S3 bucket's name")), s3Bucket])
        s3Form.addRow(with: [label(String(localized: "Region", comment: "Field: an S3 region, like us-east-1")), s3Region])
        s3Form.addRow(with: [label(String(localized: "Endpoint", comment: "Field: the S3 service's host name")), s3Endpoint])
        s3Form.addRow(with: [label(String(localized: "Access Key ID", comment: "Field: the S3 access key's ID")), s3KeyID])
        s3Form.addRow(with: [label(String(localized: "Secret Key", comment: "Field: the S3 secret access key")), s3Secret])
        s3Form.addRow(with: [NSGridCell.emptyContentView, s3PathStyle])
        s3Form.column(at: 0).xPlacement = .trailing
        s3Form.rowSpacing = 6
        s3Form.columnSpacing = 8
    }

    private func fill(_ server: RemoteServer) {
        switch server.kind {
        case .sftp:
            address.stringValue = server.address
        case .s3:
            s3Name.stringValue = server.name
            s3Bucket.stringValue = server.bucket ?? ""
            s3Region.stringValue = server.region ?? ""
            s3Endpoint.stringValue = server.host == Self.awsEndpoint(server.region ?? "") ? "" : server.host + (server.port.map { ":\($0)" } ?? "")
            s3KeyID.stringValue = server.accessKeyID ?? ""
            s3PathStyle.state = server.pathStyle == true ? .on : .off
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusFirstField()
    }

    private func focusFirstField() {
        if kind == .s3 {
            view.window?.makeFirstResponder(editing == nil ? s3Bucket : s3Secret)
        } else {
            view.window?.makeFirstResponder(address)
            address.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func kindChanged(_ sender: NSSegmentedControl) {
        kind = Kind(rawValue: sender.selectedSegment) ?? .share
        Prefs.shared.defaults.set(kind.rawValue, forKey: "connectKind")
        message.isHidden = true
        showKind()
        focusFirstField()
    }

    private func showKind() {
        address.isHidden = kind == .s3
        s3Form.isHidden = kind != .s3
        address.removeAllItems()
        switch kind {
        case .share:
            hint.stringValue = String(localized: "smb://server/share, afp://, nfs:// or a WebDAV https:// address. A server name alone connects with SMB.")
            address.placeholderString = "smb://server/share"
            address.addItems(withObjectValues: ServerConnection.recents)
            if editing == nil { address.stringValue = ServerConnection.recents.first ?? "" }
            clearRecents.isHidden = ServerConnection.recents.isEmpty
        case .sftp:
            hint.stringValue = String(localized: "user@host, a Host from ~/.ssh/config, or sftp://user@host:port/folder. Your SSH keys and agent log in; a password is asked for when one is needed.")
            address.placeholderString = "deploy@example.com"
            let saved = RemoteServers.all.filter { $0.kind == .sftp }.map(\.address)
            address.addItems(withObjectValues: saved + Self.sshConfigHosts().filter { !saved.contains($0) })
            if editing == nil { address.stringValue = "" }
            clearRecents.isHidden = true
        case .s3:
            hint.stringValue = String(localized: "Amazon S3, or an S3-compatible service with its endpoint (Cloudflare R2, Backblaze B2, Wasabi, MinIO…). The secret key is kept in your keychain.")
            clearRecents.isHidden = true
        }
        view.window?.layoutIfNeeded()
    }

    /// The Host names in ~/.ssh/config (not patterns), for picking.
    private static func sshConfigHosts() -> [String] {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf8.count < 1 << 20 else { return [] }
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for host in parts.dropFirst() where !host.contains("*") && !host.contains("?") && !host.hasPrefix("!")
                && RemoteServer.isValidHost(host) && !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }

    private static func awsEndpoint(_ region: String) -> String {
        "s3.\(region).amazonaws.com"
    }

    func controlTextDidChange(_ notification: Notification) {
        message.isHidden = true
    }

    // MARK: - Connecting

    @objc private func connect(_ sender: Any?) {
        guard request == nil, connecting == nil else { return }
        switch kind {
        case .share: connectShare()
        case .sftp: connectSFTP()
        case .s3: connectS3()
        }
    }

    private func connectShare() {
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

    private func connectSFTP() {
        var server: RemoteServer
        switch RemoteServer.sftp(from: address.stringValue) {
        case .success(let parsed): server = parsed
        case .failure(let problem): return show(problem.message)
        }
        // The same login again is the saved server, not a second one.
        if let editing {
            server.id = editing.id
            server.name = editing.name == editing.host ? server.host : editing.name
        } else if let saved = RemoteServers.all.first(where: { $0.kind == .sftp && $0.host == server.host && $0.user == server.user && $0.port == server.port }) {
            server.id = saved.id
            server.name = saved.name
        }
        tryConnecting(server)
    }

    private func connectS3() {
        let bucket = s3Bucket.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let region = s3Region.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var endpoint = s3Endpoint.stringValue.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://"] where endpoint.lowercased().hasPrefix(prefix) { endpoint = String(endpoint.dropFirst(prefix.count)) }
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        var port: Int?
        if let colon = endpoint.lastIndex(of: ":"), !endpoint.hasPrefix("[") {
            port = Int(endpoint[endpoint.index(after: colon)...]) ?? -1
            endpoint = String(endpoint[..<colon])
        }
        let host = endpoint.isEmpty ? Self.awsEndpoint(region) : endpoint
        let name = s3Name.stringValue.trimmingCharacters(in: .whitespaces)
        let server = RemoteServer(id: editing?.id ?? UUID().uuidString, kind: .s3, name: name.isEmpty ? bucket : name, host: host,
                                  port: port, bucket: bucket, region: region,
                                  accessKeyID: s3KeyID.stringValue.trimmingCharacters(in: .whitespaces),
                                  pathStyle: s3PathStyle.state == .on)
        if let problem = server.validate() { return show(problem.message) }
        let secret = s3Secret.stringValue
        if secret.isEmpty, editing == nil || RemoteKeychain.secret(for: server) == nil {
            return show(String(localized: "Type the secret key that goes with the access key ID."))
        }
        let previous = editing.flatMap(RemoteKeychain.secret(for:))
        if !secret.isEmpty, !RemoteKeychain.setSecret(secret, for: server) {
            return show(String(localized: "The secret key couldn’t be saved in your keychain."))
        }
        tryConnecting(server) { connected in
            // A new secret that didn't work isn't kept.
            guard !connected, !secret.isEmpty else { return }
            if let previous { _ = RemoteKeychain.setSecret(previous, for: server) } else { RemoteKeychain.delete(server) }
        }
    }

    /// Connects (and for a bucket, lists its top, so wrong keys show now); saves the server when it works.
    private func tryConnecting(_ server: RemoteServer, then finished: @escaping (Bool) -> Void = { _ in }) {
        // Known to the copies' paths while connecting; saved only once it works.
        RemoteRegistry.update(RemoteServers.all.filter { $0.id != server.id } + [server])
        connectingID = server.id
        setBusy(true)
        let previous = editing
        connecting = Task { [weak self] in
            await RemoteSessions.shared.disconnect(server.id)
            // Edited to reach somewhere else: what was read from the old address isn't this server's.
            if let previous, previous.reachesSomewhereElse(than: server) {
                await RemoteFiles.shared.discard(server.id)
                NotificationCenter.default.post(name: .remoteServerDisconnected, object: server.id)
            }
            do {
                let backend = try await RemoteSessions.shared.backend(for: server.id)
                if server.kind == .s3 { _ = try await backend.list("/") }
                // Stopped meanwhile: nothing is kept (the connection, an unsaved server, a new secret).
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                RemoteServers.save(server)
                finished(true)
                connecting = nil
                setBusy(false)
                dismiss(nil)
                onServer?(server)
            } catch {
                await RemoteSessions.shared.disconnect(server.id)
                RemoteServers.load()
                finished(false)
                guard let self else { return }
                connecting = nil
                setBusy(false)
                if !Task.isCancelled { show(RemoteFiles.message(for: error)) }
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
        if let connecting, let id = connectingID {
            connecting.cancel()
            self.connecting = nil
            Task { await RemoteSessions.shared.disconnect(id) }
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
        kindPicker.isEnabled = !busy
        for field in [s3Name, s3Bucket, s3Region, s3Endpoint, s3KeyID, s3Secret] { field.isEnabled = !busy }
        if busy { message.isHidden = true }
    }

    private func show(_ text: String) {
        message.stringValue = text
        message.isHidden = false
    }
}
