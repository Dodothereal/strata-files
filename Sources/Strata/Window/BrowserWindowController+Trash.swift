import AppKit

extension BrowserWindowController {
    /// Go ▸ Trash: your Trash on the startup disk.
    @objc func goTrash(_ sender: Any?) {
        navigate(to: Trash.home)
    }

    /// Go ▸ Connect to Server…: mounts a share (macOS asks for the login), then shows it.
    @objc func connectToServer(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let controller = ConnectToServerController(settings: services.connectionSettings)
        controller.onConnected = { [weak self] mounted in self?.navigate(to: mounted) }
        controller.onServer = { [weak self] server in self?.openServer(server) }
        contentViewController?.presentAsSheet(controller)
    }

    /// Edit… for a saved SFTP server or bucket: the same sheet, filled in.
    func editServer(_ server: RemoteServer) {
        guard let window, window.attachedSheet == nil else { return }
        let controller = ConnectToServerController(editing: server, settings: services.connectionSettings)
        controller.onServer = { [weak self] server in self?.openServer(server) }
        contentViewController?.presentAsSheet(controller)
    }

    /// Connects to `server` (saying so over the folder, with Cancel) and shows where browsing starts: its saved
    /// folder, or where the login starts (a bucket's top).
    func openServer(_ server: RemoteServer) {
        let connecting = Task { [weak self] in
            do {
                let top = try RemoteCopies.prepare(server)
                let backend = try await RemoteSessions.shared.backend(for: server.id)
                var start = server.path ?? ""
                if start.isEmpty { start = try await backend.home() }
                let folder = RemoteCopies.url(forRemotePath: start, top: top)
                guard !Task.isCancelled, let self else { return }
                navigate(to: await RemoteFiles.shared.reveal(folder) ? folder : top)
            } catch {
                guard !Task.isCancelled, let self, let window else { return }
                if case .folder(let shown) = destination { updateNotice(for: shown) }
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t connect to “\(server.name)”", comment: "A server's name")
                alert.informativeText = RemoteFiles.message(for: error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
        split.noticeBar.show(symbol: "network", text: String(localized: "Connecting to “\(server.name)”…", comment: "A server's name"),
                             button: String(localized: "Cancel")) { [weak self] in
            connecting.cancel()
            Task { await RemoteSessions.shared.disconnect(server.id) }
            guard let self, case .folder(let shown) = destination else { return }
            updateNotice(for: shown)
        }
    }
}

extension BrowserWindowController {
    /// Under the toolbar: inside an archive opened as a folder, say so; while a Trash is shown, say when other disks'
    /// Trashes hold something too (each disk keeps its own).
    func updateNotice(for url: URL) {
        if let engine = ContainerCopies.engineFolder(url) {
            return split.noticeBar.show(symbol: "shippingbox",
                                        text: String(localized: "Containers on \(engine.name). Each opens as a read-only copy of its files.",
                                                     comment: "Notice over the Containers folder; placeholder: Docker Desktop, OrbStack…"),
                                        button: String(localized: "Reload", comment: "Button: read a container's folder again")) { [weak self] in
                self?.browser.reloadFolder(nil)
            }
        }
        if let (source, _) = ContainerCopies.copy(containing: url) {
            return split.noticeBar.show(symbol: "shippingbox",
                                        text: String(localized: "Files in “\(source.name)” on \(source.engineName): a read-only copy, read from the container as you browse.",
                                                     comment: "Notice over a container's files; placeholders: the container, then its engine (Docker Desktop, OrbStack…)"),
                                        button: String(localized: "Reload", comment: "Button: read a container's folder again")) { [weak self] in
                self?.browser.reloadFolder(nil)
            }
        }
        if let (server, _) = RemoteCopies.server(containing: url) {
            let kind = server.kind == .s3 ? String(localized: "bucket", comment: "Notice: the kind of server (an S3 bucket)") : "SFTP"
            return split.noticeBar.show(symbol: server.kind == .s3 ? "externaldrive.connected.to.line.below" : "server.rack",
                                        text: String(localized: "On “\(server.name)” (\(kind)), read from the server as you browse. Changes are made on the server.",
                                                     comment: "Notice over a server's files; placeholders: the server's name, then SFTP or “bucket”"),
                                        button: String(localized: "Disconnect", comment: "Button: end the connection to the server")) { [weak self] in
                self?.disconnectServer(server)
            }
        }
        if let (archive, _) = ArchiveCache.archive(containing: url) {
            return split.noticeBar.show(symbol: "archivebox",
                                        text: String(localized: "Inside “\(archive.lastPathComponent)”, a read-only copy. Copy things out to keep them."),
                                        button: String(localized: "Extract All")) { [weak self] in
                self?.browser.extractArchive(archive)
            }
        }
        guard Trash.isTrash(url) else { return split.noticeBar.hide() }
        split.noticeBar.hide()
        Task { [weak self] in
            let others = await Trash.contents().filter { $0.count > 0 && $0.folder.standardizedFileURL != url.standardizedFileURL }
            guard let self, case .folder(let shown) = destination, shown == url, let first = others.first else { return }
            let text: String
            if others.count == 1 {
                text = String(localized: "“\(first.disk)” has \(first.count) more items in its own Trash.", comment: "plural")
            } else {
                let disks = ListFormatter.localizedString(byJoining: others.map {
                    String(localized: "“\($0.disk)” (\($0.count.formatted()))", comment: "A disk and how many items its Trash holds")
                })
                text = String(localized: "Other disks have items in their own Trash: \(disks).", comment: "A list of disks with their item counts")
            }
            split.noticeBar.show(symbol: "externaldrive", text: text,
                                 button: String(localized: "Show “\(first.disk)”", comment: "Button: show that disk's Trash")) { [weak self] in
                self?.navigate(to: first.folder)
            }
        }
    }

    /// A container's folder couldn't be read: say why, over the folder (if it's the one shown).
    @objc func containerCopyProblem(_ notification: Notification) {
        guard case .folder(let shown) = destination, let folder = notification.userInfo?["folder"] as? URL,
              let message = notification.userInfo?["message"] as? String else { return }
        // The folder shown, or one below it (a column, a folder expanded in the list).
        let shownPath = shown.resolvingSymlinksInPath().standardizedFileURL.path, problem = folder.standardizedFileURL.path
        guard problem == shownPath || problem.hasPrefix(shownPath + "/") else { return }
        split.noticeBar.show(symbol: "exclamationmark.triangle", text: message,
                             button: String(localized: "Try Again", comment: "Button: read a container's folder again")) { [weak self] in
            guard let self else { return }
            updateNotice(for: shown)
            browser.reloadFolder(nil)
        }
    }
}

extension BrowserWindowController {
    /// Ends the connection to `server` and forgets its files here; panes showing them go home.
    func disconnectServer(_ server: RemoteServer) {
        Task {
            await RemoteSessions.shared.disconnect(server.id)
            await RemoteFiles.shared.discard(server.id)
            NotificationCenter.default.post(name: .remoteServerDisconnected, object: server.id)
        }
    }
}

extension Notification.Name {
    /// A server's files were let go (`object`: its ID): panes showing them move away.
    static let remoteServerDisconnected = Notification.Name("StrataRemoteServerDisconnected")
}
