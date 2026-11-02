import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSupport

struct SFTPConnectionFormTests {
    private enum Failure: Error { case login, unexpected }

    nonisolated private final class Backend: RemoteBackend {
        private let closed = Mutex(0)
        var closes: Int { closed.withLock { $0 } }
        var isAlive: Bool { closes == 0 }
        func close() { closed.withLock { $0 += 1 } }
        func home() async throws -> String { "/home/fixture" }
        func list(_ path: String) async throws -> [ListedEntry] { [] }
        func kind(of path: String) async throws -> RemoteItemKind? { .folder }
        func download(_ path: String, to destination: URL, limit: Int64,
                      progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw Failure.unexpected }
        func upload(_ source: URL, to path: String, modified: Date?,
                    progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw Failure.unexpected }
        func makeFolder(_ path: String) async throws { throw Failure.unexpected }
        func rename(_ path: String, to newPath: String) async throws { throw Failure.unexpected }
        func remove(_ path: String) async throws { throw Failure.unexpected }
    }

    private actor Logins {
        struct Call: Sendable, Equatable { let server: RemoteServer; let secret: String? }
        private(set) var calls: [Call] = []
        private(set) var cancelled: [Int: Bool] = [:]
        private var pending: [Int: CheckedContinuation<any RemoteBackend, Error>] = [:]
        private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

        func connect(_ server: RemoteServer, secret: String?) async throws -> any RemoteBackend {
            let index = calls.count
            calls.append(Call(server: server, secret: secret))
            defer { cancelled[index] = Task.isCancelled }
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                let ready = observers.filter { $0.0 <= calls.count }
                observers.removeAll { $0.0 <= calls.count }
                ready.forEach { $0.1.resume() }
            }
        }

        func waitForCalls(_ count: Int) async {
            if calls.count < count { await withCheckedContinuation { observers.append((count, $0)) } }
        }

        func finish(_ index: Int, with backend: Backend) { pending.removeValue(forKey: index)?.resume(returning: backend) }
        func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: Failure.login) }
        nonisolated var connector: RemoteConnector { RemoteConnector { try await self.connect($0, secret: $1) } }
    }

    nonisolated private final class Lookup: Sendable {
        let servers: Mutex<[String: RemoteServer]>
        init(_ servers: [RemoteServer]) { self.servers = Mutex(Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })) }
    }

    private final class Store {
        let lookup: Lookup
        var servers: [RemoteServer]
        var secrets: [String: String]
        var saves: [RemoteServer] = []
        var secretReads = 0

        init(_ servers: [RemoteServer], secrets: [String: String]) {
            self.servers = servers
            self.secrets = secrets
            lookup = Lookup(servers)
        }

        var catalog: RemoteConnectionCatalog {
            RemoteConnectionCatalog(servers: { self.servers }, secret: {
                self.secretReads += 1
                return self.secrets[$0.id]
            }, save: { server, secret in
                if let secret { self.secrets[server.id] = secret }
                if let index = self.servers.firstIndex(where: { $0.id == server.id }) { self.servers[index] = server }
                else { self.servers.append(server) }
                self.lookup.servers.withLock { $0[server.id] = server }
                self.saves.append(server)
            })
        }
    }

    private final class Environment {
        let store: Store
        let logins = Logins()
        let sessions: RemoteSessions
        let connections: RemoteConnections
        let settings: ServerConnectionSettings

        init(_ servers: [RemoteServer] = [], secrets: [String: String] = [:]) throws {
            let store = Store(servers, secrets: secrets)
            self.store = store
            settings = ServerConnectionSettings(preferences: try Prefs.isolated())
            settings.kind = .sftp
            let lookup = store.lookup
            sessions = RemoteSessions(server: { id in lookup.servers.withLock { $0[id] } },
                connect: { _ in throw Failure.unexpected }, changed: { _, _ in })
            connections = RemoteConnections(catalog: store.catalog, sessions: sessions, connector: logins.connector,
                discard: { _ in }, disconnected: { _ in })
        }

        func sheet(editing server: RemoteServer? = nil) -> ConnectToServerController {
            ConnectToServerController(editing: server, settings: settings,
                mounts: ServerMountSession(mounter: ServerMounter { _, _ in
                    Issue.record("An SFTP test tried to mount a network share")
                    return nil
                }), connections: connections, sshHosts: { ["fixture-alias"] })
        }
    }

    private static func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    private struct Form {
        let address: NSComboBox
        let name: NSTextField
        let folder: NSTextField
        let connect: NSButton
        let cancel: NSButton
        let picker: NSSegmentedControl

        init(_ sheet: ConnectToServerController) throws {
            address = try #require(SFTPConnectionFormTests.views(sheet.view, of: NSComboBox.self).first)
            let fields = SFTPConnectionFormTests.views(sheet.view, of: NSTextField.self)
            name = try #require(fields.first { $0.identifier?.rawValue == "sftpName" })
            folder = try #require(fields.first { $0.identifier?.rawValue == "sftpStartFolder" })
            let buttons = SFTPConnectionFormTests.views(sheet.view, of: NSButton.self)
            connect = try #require(buttons.first { $0.action == NSSelectorFromString("connect:") })
            cancel = try #require(buttons.first { $0.action == NSSelectorFromString("cancel:") })
            picker = try #require(SFTPConnectionFormTests.views(sheet.view, of: NSSegmentedControl.self).first)
        }

        func submit() { #expect(connect.sendAction(connect.action, to: connect.target)) }
        func stop() { #expect(cancel.sendAction(cancel.action, to: cancel.target)) }
        func select(_ kind: ServerConnectionSettings.Kind) {
            picker.selectedSegment = kind.rawValue
            #expect(picker.sendAction(picker.action, to: picker.target))
        }
        func selectSaved(_ server: RemoteServer, in sheet: ConnectToServerController) throws {
            let delegate = try #require(address.delegate)
            try #require(delegate === sheet)
            try #require(delegate.responds(to: NSSelectorFromString("comboBoxSelectionDidChange:")))
            let index = try #require(address.objectValues.firstIndex { ($0 as? String) == server.address })
            address.selectItem(at: index)
            delegate.comboBoxSelectionDidChange?(Notification(name: NSComboBox.selectionDidChangeNotification, object: address))
        }
        func expectEnabled(_ enabled: Bool) {
            #expect(address.isEnabled == enabled && name.isEnabled == enabled && folder.isEnabled == enabled)
            #expect(connect.isEnabled == enabled && picker.isEnabled == enabled)
            #expect(cancel.isEnabled)
        }
    }

    private func saved(name: String = "Saved", path: String? = "/old") -> RemoteServer {
        RemoteServer(id: UUID().uuidString, kind: .sftp, name: name, host: "fixture-alias", user: "deploy", port: 2222, path: path)
    }

    private func finish(_ sheet: ConnectToServerController, in environment: Environment, call index: Int = 0) async throws -> RemoteServer {
        let task = try #require(sheet.connecting)
        await environment.logins.waitForCalls(index + 1)
        let proposed = try #require(await environment.logins.calls.last?.server)
        await environment.logins.finish(index, with: Backend())
        await task.value
        #expect(sheet.connecting == nil)
        return proposed
    }

    @Test func newFieldsKeepSSHConfigurationAndLiteralPaths() async throws {
        _ = NSApplication.shared
        let environment = try Environment(), sheet = environment.sheet(), form = try Form(sheet)
        await sheet.readingHosts?.value
        #expect(form.address.objectValues.contains { ($0 as? String) == "fixture-alias" })
        #expect(form.name.accessibilityLabel() == String(localized: "Name"))
        #expect(form.folder.accessibilityLabel() == String(localized: "Start Folder"))
        #expect(form.name.delegate === sheet && form.folder.delegate === sheet)
        form.address.stringValue = "fixture-alias"
        form.name.stringValue = "  Staging 🧪  "
        form.folder.stringValue = "/srv/資料 100%20/#work "
        var delivered: [RemoteServer] = []
        sheet.onServer = { delivered.append($0) }
        form.submit()
        form.expectEnabled(false)
        let server = try await finish(sheet, in: environment)
        form.expectEnabled(true)
        #expect(server.name == "Staging 🧪" && server.path == "/srv/資料 100%20/#work ")
        #expect(server.host == "fixture-alias" && server.user == nil && server.port == nil)
        #expect(server.sshArguments == (try RemoteServer.sftp(from: "fixture-alias").get()).sshArguments)
        #expect(environment.store.servers == [server] && environment.store.saves == [server])
        #expect(environment.store.secretReads == 0 && environment.store.secrets.isEmpty)
        #expect(delivered == [server] && environment.settings.recents.isEmpty)
        await environment.sessions.disconnect(server.id)
    }

    @Test func blankAndExplicitFoldersKeepLegacyAddressSemantics() async throws {
        _ = NSApplication.shared
        let cases: [(String, String, String?)] = [
            ("fixture-alias", "", nil),
            ("sftp://deploy@[2001:db8::1]:2222/legacy%20folder", "", "/legacy folder"),
            ("sftp://fixture-alias/", "", nil),
            ("sftp://fixture-alias/legacy", "/explicit", "/explicit"),
            ("sftp://fixture-alias/legacy", "/", "/"),
            ("fixture-alias", "/" + String(repeating: "x", count: 4095), "/" + String(repeating: "x", count: 4095)),
        ]
        for (address, folder, expected) in cases {
            let environment = try Environment(), sheet = environment.sheet(), form = try Form(sheet)
            form.address.stringValue = address
            form.name.stringValue = " \t\n "
            form.folder.stringValue = folder
            form.submit()
            let server = try await finish(sheet, in: environment)
            let parsed = try RemoteServer.sftp(from: address).get()
            #expect(server.name == parsed.host && server.path == expected)
            #expect(server.host == parsed.host && server.user == parsed.user && server.port == parsed.port)
            #expect(server.sshArguments == parsed.sshArguments)
            await environment.sessions.disconnect(server.id)
        }
    }

    @Test func editingPrefillsSeparateFieldsAndClearingThemKeepsTheID() async throws {
        _ = NSApplication.shared
        for path in ["/saved folder", "/", "/literal%2F資料"] {
            let original = saved(path: path), neighbor = saved(name: "Neighbor")
            let environment = try Environment([original, neighbor], secrets: [neighbor.id: "Synthetic neighbor secret"])
            let sheet = environment.sheet(editing: original), form = try Form(sheet)
            #expect(form.address.stringValue == "sftp://deploy@fixture-alias:2222")
            #expect(form.name.stringValue == original.name && form.folder.stringValue == path)
            #expect(form.picker.isHidden)
            form.address.stringValue = "sftp://deploy@new-fixture:2222"
            form.name.stringValue = ""
            form.folder.stringValue = ""
            form.submit()
            let changed = try await finish(sheet, in: environment)
            #expect(changed.id == original.id && changed.name == "new-fixture" && changed.path == nil)
            #expect(environment.store.servers == [changed, neighbor])
            #expect(environment.store.secrets == [neighbor.id: "Synthetic neighbor secret"])
            let reopened = environment.sheet(editing: changed), reopenedForm = try Form(reopened)
            #expect(reopenedForm.address.stringValue == "sftp://deploy@new-fixture:2222")
            #expect(reopenedForm.name.stringValue == "new-fixture" && reopenedForm.folder.stringValue.isEmpty)
            await environment.sessions.disconnect(changed.id)
            withExtendedLifetime(reopened) {}
        }
    }

    @Test func unchangedEditRoundTripsTheLiteralSavedPathAndName() async throws {
        _ = NSApplication.shared
        let original = saved(name: "資料", path: "/literal%2F/folder "), environment = try Environment([original])
        let sheet = environment.sheet(editing: original), form = try Form(sheet)
        form.submit()
        let server = try await finish(sheet, in: environment)
        #expect(server == original && environment.store.servers == [original])
        await environment.sessions.disconnect(original.id)
    }

    @Test func editingKeepsAutomaticNamesAndLegacyRelativePathsCompatible() async throws {
        _ = NSApplication.shared
        for name in ["fixture-alias", "Custom name"] {
            let original = saved(name: name, path: "legacy folder"), environment = try Environment([original])
            let sheet = environment.sheet(editing: original), form = try Form(sheet)
            #expect(form.folder.stringValue == "/legacy folder")
            form.address.stringValue = "sftp://deploy@new-fixture:2222"
            form.submit()
            let server = try await finish(sheet, in: environment)
            #expect(server.id == original.id && server.path == "/legacy folder")
            #expect(server.name == (name == original.host ? "new-fixture" : name))
            await environment.sessions.disconnect(server.id)
        }
    }

    @Test func reconnectReusesTheSavedIDAndOnlyAnExplicitNameRenamesIt() async throws {
        _ = NSApplication.shared
        for name in ["", " \t ", "Renamed"] {
            let original = saved(), neighbor = saved(name: "Neighbor")
            let environment = try Environment([original, neighbor])
            let sheet = environment.sheet(), form = try Form(sheet)
            form.address.stringValue = original.address
            form.name.stringValue = name
            form.folder.stringValue = "/new"
            form.submit()
            let server = try await finish(sheet, in: environment)
            #expect(server.id == original.id && server.path == "/new")
            #expect(server.name == (name == "Renamed" ? name : original.name))
            #expect(environment.store.servers == [server, neighbor])
            await environment.sessions.disconnect(server.id)
        }
    }

    @Test func savedDropdownPreservesLiteralPathsWhileTypedURLsStillDecode() async throws {
        _ = NSApplication.shared
        for path in ["/literal%2F/folder", "/literal%20/資料 ", "/literal%00/folder", "/"] {
            let original = saved(path: path), environment = try Environment([original])
            let sheet = environment.sheet(), form = try Form(sheet)
            await sheet.readingHosts?.value
            try form.selectSaved(original, in: sheet)
            #expect(form.address.stringValue == "sftp://deploy@fixture-alias:2222")
            #expect(form.name.stringValue == original.name && form.folder.stringValue == path)
            form.submit()
            let server = try await finish(sheet, in: environment)
            #expect(server == original && environment.store.servers == [original])
            await environment.sessions.disconnect(server.id)
        }
        let environment = try Environment(), sheet = environment.sheet(), form = try Form(sheet)
        form.address.stringValue = "sftp://fixture-alias/literal%2F/folder"
        form.submit()
        let server = try await finish(sheet, in: environment)
        #expect(server.path == "/literal//folder")
        await environment.sessions.disconnect(server.id)
    }

    @Test func selectingAnotherSavedServerClearsItsPredecessorsFolder() async throws {
        _ = NSApplication.shared
        let original = saved(path: "/first")
        var withoutPath = saved(name: "No path", path: nil)
        withoutPath.host = "without-path"
        var emptyPath = saved(name: "Empty path", path: "")
        emptyPath.host = "empty-path"
        let environment = try Environment([original, withoutPath, emptyPath])
        let sheet = environment.sheet(), form = try Form(sheet)
        await sheet.readingHosts?.value
        for next in [withoutPath, emptyPath] {
            for selected in [original, next] {
                try form.selectSaved(selected, in: sheet)
                #expect(form.name.stringValue == selected.name)
                #expect(form.folder.stringValue == (selected.path ?? ""))
            }
        }
        form.submit()
        let server = try await finish(sheet, in: environment)
        #expect(server.id == emptyPath.id && server.host == emptyPath.host && server.path == nil)
        #expect(environment.store.servers[0] == original && environment.store.servers[1] == withoutPath)
        await environment.sessions.disconnect(server.id)
    }

    @Test func unrelatedDropdownNotificationsLeaveTheDraftAlone() async throws {
        _ = NSApplication.shared
        let original = saved(), environment = try Environment([original])
        let sheet = environment.sheet(), form = try Form(sheet)
        form.address.stringValue = "other-fixture"
        form.name.stringValue = "Draft"
        form.folder.stringValue = "/draft"
        sheet.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: NSComboBox()))
        #expect(form.address.stringValue == "other-fixture" && form.name.stringValue == "Draft")
        #expect(form.folder.stringValue == "/draft")
        #expect(await environment.logins.calls.isEmpty && environment.store.saves.isEmpty)
    }

    @Test func savedDropdownNotificationsCannotReplaceAnActiveAttempt() async throws {
        _ = NSApplication.shared
        let original = saved()
        var other = saved(name: "Other", path: "/other")
        other.host = "other-fixture"
        let environment = try Environment([original, other]), sheet = environment.sheet(), form = try Form(sheet)
        await sheet.readingHosts?.value
        form.address.stringValue = original.address
        form.name.stringValue = "Draft"
        form.folder.stringValue = "/draft"
        var delivered: [RemoteServer] = []
        sheet.onServer = { delivered.append($0) }
        form.submit()
        let attempt = try #require(sheet.connecting)
        await environment.logins.waitForCalls(1)
        let calls = await environment.logins.calls
        let proposed = try #require(calls.first?.server)
        form.expectEnabled(false)
        try form.selectSaved(other, in: sheet)
        #expect(form.name.stringValue == "Draft" && form.folder.stringValue == "/draft")
        #expect(sheet.connecting != nil && !attempt.isCancelled)
        #expect(await environment.logins.calls == calls)
        #expect(environment.store.saves.isEmpty && delivered.isEmpty)
        form.expectEnabled(false)
        await environment.logins.finish(0, with: Backend())
        await attempt.value
        #expect(sheet.connecting == nil)
        #expect(proposed.id == original.id && proposed.name == "Draft" && proposed.path == "/draft")
        #expect(environment.store.servers == [proposed, other] && environment.store.saves == [proposed])
        #expect(delivered == [proposed])
        #expect(await environment.logins.calls == calls)
        #expect(await environment.logins.cancelled == [0: false])
        form.expectEnabled(true)
        await environment.sessions.disconnect(proposed.id)
    }

    @Test func savedDropdownNotificationsLeaveAnEditingDraftAlone() async throws {
        _ = NSApplication.shared
        let original = saved()
        var other = saved(name: "Other", path: "/other")
        other.host = "other-fixture"
        let environment = try Environment([original, other])
        let sheet = environment.sheet(editing: original), form = try Form(sheet)
        await sheet.readingHosts?.value
        form.name.stringValue = "Editing draft"
        form.folder.stringValue = "/editing-draft"
        try form.selectSaved(other, in: sheet)
        #expect(form.name.stringValue == "Editing draft" && form.folder.stringValue == "/editing-draft")
        #expect(sheet.connecting == nil && form.picker.isHidden)
        #expect(await environment.logins.calls.isEmpty)
        #expect(environment.store.servers == [original, other] && environment.store.saves.isEmpty)
        form.expectEnabled(true)
    }

    @Test func invalidFoldersAreRefusedBeforeConnectingOrSaving() async throws {
        _ = NSApplication.shared
        let original = saved(), environment = try Environment([original])
        let sheet = environment.sheet(editing: original), form = try Form(sheet)
        for invalid in ["relative", "~/work", " ", "/bad\nfolder", "/bad\u{0}folder", "/" + String(repeating: "x", count: 4096)] {
            form.folder.stringValue = invalid
            form.submit()
            #expect(sheet.connecting == nil)
            #expect(await environment.logins.calls.isEmpty)
            #expect(environment.store.servers == [original] && environment.store.saves.isEmpty)
            form.expectEnabled(true)
        }
        form.folder.stringValue = "/repaired"
        form.submit()
        let server = try await finish(sheet, in: environment)
        #expect(server.id == original.id && server.path == "/repaired")
        await environment.sessions.disconnect(server.id)
    }

    @Test func cancellationAndRetryIgnoreLateSuccessAndFailureInBothOrders() async throws {
        _ = NSApplication.shared
        for oldFirst in [true, false] {
            for oldFails in [true, false] {
                let original = saved(), environment = try Environment([original])
                let sheet = environment.sheet(editing: original), form = try Form(sheet)
                var delivered: [RemoteServer] = []
                sheet.onServer = { delivered.append($0) }
                form.name.stringValue = "Old"
                form.folder.stringValue = "/old-proposal"
                form.submit()
                let old = try #require(sheet.connecting)
                await environment.logins.waitForCalls(1)
                // Even direct repeated action delivery cannot start a second request while busy.
                form.submit()
                #expect(await environment.logins.calls.count == 1)
                form.stop()
                form.expectEnabled(true)
                #expect(sheet.connecting == nil)
                #expect(environment.store.servers == [original] && delivered.isEmpty)
                form.name.stringValue = "Current"
                form.folder.stringValue = "/current"
                form.submit()
                let current = try #require(sheet.connecting)
                await environment.logins.waitForCalls(2)
                let oldBackend = Backend(), currentBackend = Backend()
                if oldFirst {
                    if oldFails { await environment.logins.fail(0) }
                    else { await environment.logins.finish(0, with: oldBackend) }
                    await old.value
                    form.expectEnabled(false)
                    #expect(environment.store.servers == [original] && delivered.isEmpty)
                }
                await environment.logins.finish(1, with: currentBackend)
                await current.value
                if !oldFirst {
                    if oldFails { await environment.logins.fail(0) }
                    else { await environment.logins.finish(0, with: oldBackend) }
                    await old.value
                }
                form.expectEnabled(true)
                let server = try #require(environment.store.servers.first)
                #expect(server.id == original.id && server.name == "Current" && server.path == "/current")
                #expect(environment.store.saves == [server] && delivered == [server])
                #expect(oldBackend.closes == (oldFails ? 0 : 1) && currentBackend.closes == 0)
                #expect(await environment.logins.cancelled == [0: true, 1: false])
                await environment.sessions.disconnect(server.id)
            }
        }
    }

    @Test func currentFailurePreservesFieldsAndAllowsAnotherTry() async throws {
        _ = NSApplication.shared
        let original = saved(), environment = try Environment([original])
        let sheet = environment.sheet(editing: original), form = try Form(sheet)
        form.name.stringValue = "Retry"
        form.folder.stringValue = "/retry"
        form.submit()
        let failed = try #require(sheet.connecting)
        await environment.logins.waitForCalls(1)
        await environment.logins.fail(0)
        await failed.value
        form.expectEnabled(true)
        #expect(form.name.stringValue == "Retry" && form.folder.stringValue == "/retry")
        #expect(environment.store.servers == [original] && environment.store.saves.isEmpty)
        form.submit()
        let server = try await finish(sheet, in: environment, call: 1)
        #expect(server.id == original.id && server.name == "Retry" && server.path == "/retry")
        await environment.sessions.disconnect(server.id)
    }

    @Test func releasingTheSheetCancelsOnlyItsRequest() async throws {
        _ = NSApplication.shared
        let original = saved()
        let left = try Environment([original]), right = try Environment([original])
        var sheet: ConnectToServerController? = left.sheet(editing: original)
        weak var weakSheet = sheet
        let form = try Form(sheet!)
        var delivered = 0
        sheet!.onServer = { _ in delivered += 1 }
        form.name.stringValue = "Discarded"
        form.folder.stringValue = "/discarded"
        form.submit()
        let abandoned = try #require(sheet!.connecting)
        await left.logins.waitForCalls(1)
        let otherSheet = right.sheet(editing: original), otherForm = try Form(otherSheet)
        otherForm.name.stringValue = "Other environment"
        otherForm.submit()
        await right.logins.waitForCalls(1)
        sheet = nil
        #expect(weakSheet == nil)
        let late = Backend()
        await left.logins.finish(0, with: late)
        await abandoned.value
        #expect(delivered == 0 && late.closes == 1)
        #expect(left.store.servers == [original] && left.store.saves.isEmpty)
        otherForm.expectEnabled(false)
        let other = try await finish(otherSheet, in: right)
        #expect(other.id == original.id && other.name == "Other environment")
        #expect(await left.logins.cancelled[0] == true)
        #expect(await right.logins.cancelled[0] == false)
        await right.sessions.disconnect(other.id)
    }

    @Test func switchingProtocolsShowsOnlyItsOwnFields() async throws {
        _ = NSApplication.shared
        let environment = try Environment(), sheet = environment.sheet(), form = try Form(sheet)
        form.address.stringValue = "fixture-alias"
        form.name.stringValue = "SFTP name"
        form.folder.stringValue = "/sftp-only"
        #expect(!form.name.isHiddenOrHasHiddenAncestor && !form.folder.isHiddenOrHasHiddenAncestor)
        form.select(.share)
        #expect(form.name.isHiddenOrHasHiddenAncestor && form.folder.isHiddenOrHasHiddenAncestor)
        #expect(!form.address.isHiddenOrHasHiddenAncestor && environment.settings.kind == .share)
        form.select(.s3)
        #expect(form.name.isHiddenOrHasHiddenAncestor && form.folder.isHiddenOrHasHiddenAncestor)
        #expect(form.address.isHiddenOrHasHiddenAncestor && environment.settings.kind == .s3)
        form.select(.sftp)
        #expect(!form.name.isHiddenOrHasHiddenAncestor && !form.folder.isHiddenOrHasHiddenAncestor)
        #expect(form.address.stringValue.isEmpty && form.name.stringValue.isEmpty && form.folder.stringValue.isEmpty)
        #expect(await environment.logins.calls.isEmpty)
        #expect(environment.store.saves.isEmpty && environment.settings.recents.isEmpty)
    }
}
