import AppKit

/// The Inspector's cards for a container's files: the container (image, state, ports…) and its mounts, each mount
/// opening where it is in the container or, for a folder of this Mac, there.
final class ContainerInspectorView: NSView {
    /// Shows a folder (in the container's files, or on this Mac).
    var onOpen: ((URL) -> Void)?
    private let stack = NSStackView()
    private var shown: Shown?

    private struct Shown: Equatable {
        let source: ContainerSource
        let top: URL
        let container: ContainerInfo?
        let busy: ContainerAction?
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The container whose files these are (nil hides the cards). Rebuilt only when something shown changed.
    func configure(_ copy: (source: ContainerSource, top: URL)?) {
        let next = copy.map { Shown(source: $0.source, top: $0.top, container: ContainerStore.shared.container(id: $0.source.id),
                                    busy: ContainerStore.shared.busy[$0.source.id]) }
        isHidden = next == nil
        guard next != shown else { return }
        shown = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let next else { return }
        addCard(containerCard(next))
        if let mounts = mountsCard(next) { addCard(mounts) }
    }

    private func addCard(_ card: InspectorCard) {
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func containerCard(_ shown: Shown) -> InspectorCard {
        let rows = InspectorRows()
        let state: NSTextField
        if let container = shown.container {
            var list: [(String, String)] = [
                (String(localized: "Image", comment: "Inspector row: a container's image"), container.image),
                (String(localized: "Status", comment: "Inspector row: a container's state (“Up 3 hours”)"), container.status),
                (String(localized: "Engine", comment: "Inspector row: Docker Desktop, OrbStack, Colima…"), shown.source.engineName),
            ]
            if !container.ports.isEmpty {
                list.append((String(localized: "Ports", comment: "Inspector row: a container's published ports"), Self.ports(container.ports)))
            }
            if let created = container.created {
                list.append((String(localized: "Created", comment: "Inspector row: creation date"), Format.longDate(created)))
            }
            list.append((String(localized: "ID", comment: "Inspector row: a container's short ID"), container.shortID))
            rows.setText(list)
            state = shown.busy.map { Self.small(ContainerControl.progress($0), color: .systemOrange) } ?? Self.stateLabel(container)
            let buttons = actions(container, busy: shown.busy)
            let content = NSStackView(views: [rows, buttons])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 10
            rows.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            return InspectorCard(id: "container", title: shown.source.name, symbol: "shippingbox", content: content, accessory: state)
        } else {
            rows.setText([(String(localized: "Engine", comment: "Inspector row: Docker Desktop, OrbStack, Colima…"), shown.source.engineName)])
            state = Self.small(String(localized: "Not available", comment: "Inspector: the container is gone, or its engine isn't running"),
                               color: .secondaryLabelColor)
        }
        return InspectorCard(id: "container", title: shown.source.name, symbol: "shippingbox", content: rows, accessory: state)
    }

    private func mountsCard(_ shown: Shown) -> InspectorCard? {
        guard let mounts = shown.container?.mounts, !mounts.isEmpty else { return nil }
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for mount in mounts.sorted(by: { $0.destination < $1.destination }) {
            let row = MountRow(mount, top: shown.top) { [weak self] url in self?.onOpen?(url) }
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let count = Self.small(mounts.count.formatted(), color: .secondaryLabelColor)
        return InspectorCard(id: "containerMounts", title: String(localized: "Mounts", comment: "Inspector section: a container's mounted folders and volumes"),
                             symbol: "externaldrive.connected.to.line.below", content: content, accessory: count)
    }

    /// Start, Stop, Restart, Pause or Resume (what applies) and Terminal; a spinner while an action runs.
    private func actions(_ container: ContainerInfo, busy: ContainerAction?) -> NSView {
        if let busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView(views: [spinner, Self.small(ContainerControl.progress(busy), color: .secondaryLabelColor)])
            row.spacing = 6
            return row
        }
        var buttons: [NSView] = ContainerAction.allCases.filter { $0.applies(to: container.state) }.map { action in
            ActionButton(ContainerControl.title(action), symbol: ContainerControl.symbol(action)) { [weak self] in
                ContainerControl.run(action, on: [container], in: self?.window)
            }
        }
        let terminal = ActionButton(String(localized: "Terminal", comment: "Inspector button: a shell in the container"), symbol: "terminal") {
            guard let engine = ContainerStore.shared.engine, ContainerControl.openTerminal(in: container, at: "/", engine: engine) else { return NSSound.beep() }
        }
        terminal.isEnabled = container.isRunning
        terminal.toolTip = String(localized: "Open a shell in the container, in your terminal", comment: "Inspector: tooltip on Terminal")
        buttons.append(terminal)
        // A narrow Inspector wraps them onto another line.
        let row = FlowView(spacing: 6, lineSpacing: 6)
        buttons.forEach(row.add)
        return row
    }

    /// "8080 → 80/tcp, 5432/tcp": the Mac's port, then the container's.
    static func ports(_ ports: [ContainerPort]) -> String {
        var seen = Set<String>()
        return ports.compactMap { port -> String? in
            let text = port.hostPort.map { "\($0) → \(port.containerPort)/\(port.proto)" } ?? "\(port.containerPort)/\(port.proto)"
            return seen.insert(text).inserted ? text : nil
        }.joined(separator: ", ")
    }

    static func stateLabel(_ container: ContainerInfo) -> NSTextField {
        switch container.state {
        case .running: small(String(localized: "Running", comment: "Container state"), color: .systemGreen)
        case .paused: small(String(localized: "Paused", comment: "Container state"), color: .systemOrange)
        case .restarting: small(String(localized: "Restarting", comment: "Container state"), color: .systemOrange)
        default: small(String(localized: "Not Running", comment: "Container state: stopped, exited or created"), color: .secondaryLabelColor)
        }
    }

    static func small(_ text: String, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

/// A mount: where it is in the container (opens it), and where it comes from.
private final class MountRow: NSView {
    init(_ mount: ContainerMount, top: URL, open: @escaping (URL) -> Void) {
        super.init(frame: .zero)
        let inside = LinkButton(mount.destination, font: .monospacedSystemFont(ofSize: 12, weight: .regular)) {
            open(ContainerCopies.url(forContainerPath: mount.destination, top: top))
        }
        inside.toolTip = String(localized: "Show it in the container", comment: "Inspector, Mounts: tooltip on a mount's path in the container")
        var details: [NSView] = []
        switch mount.kind {
        case .bind:
            let source = URL(fileURLWithPath: mount.source)
            let text = String(localized: "from \(Format.tildePath(source))", comment: "Inspector, Mounts: the Mac folder a container mounts")
            if mount.source.hasPrefix("/"), FileManager.default.fileExists(atPath: mount.source) {
                let link = LinkButton(text, font: .systemFont(ofSize: 11)) { open(source) }
                link.toolTip = String(localized: "Show this folder on your Mac", comment: "Inspector, Mounts: tooltip")
                details.append(link)
            } else {
                details.append(ContainerInspectorView.small(text, color: .secondaryLabelColor))
            }
        case .volume:
            details.append(ContainerInspectorView.small(String(localized: "volume \(mount.name ?? mount.source)", comment: "Inspector, Mounts: a named volume"),
                                                        color: .secondaryLabelColor))
        case .tmpfs:
            details.append(ContainerInspectorView.small(String(localized: "in memory", comment: "Inspector, Mounts: a tmpfs mount"), color: .secondaryLabelColor))
        case .other:
            break
        }
        if !mount.isWritable {
            details.append(ContainerInspectorView.small(String(localized: "read-only", comment: "Inspector, Mounts: the container can't change it"),
                                                        color: .tertiaryLabelColor))
        }
        let detail = NSStackView(views: details)
        detail.orientation = .horizontal
        detail.spacing = 6
        let column = NSStackView(views: [inside] + (details.isEmpty ? [] : [detail]))
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A small button with a symbol that runs a closure.
final class ActionButton: NSButton {
    private let onClick: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        symbolConfiguration = .init(pointSize: 10, weight: .medium)
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick() }
}

/// Text that does something when clicked, styled as a link.
final class LinkButton: NSButton {
    private let onClick: () -> Void

    init(_ title: String, font: NSFont, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.linkColor])
        alignment = .left
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func clicked() { onClick() }
}

/// The Compose card, for a folder `docker compose` runs in: its services, which are running, and their files.
final class ComposeInspectorView: NSView {
    /// Shows a container's files.
    var onOpenContainer: ((String) -> Void)?
    private let stack = NSStackView()
    private var shown: Shown?

    private struct Shown: Equatable {
        let project: String
        let services: [Service]
        let busy: [String]
    }

    struct Service: Equatable {
        let name: String
        /// Its containers (one per replica); none when it hasn't been created.
        let containers: [ContainerInfo]
    }

    static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The folder shown (nil, or a folder without Compose, hides the card).
    func configure(_ folder: URL?) {
        let next = folder.flatMap(Self.compose(in:))
        isHidden = next == nil
        guard next != shown else { return }
        shown = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let next else { return }
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        for service in next.services {
            let row = ServiceRow(service, open: { [weak self] id in self?.onOpenContainer?(id) },
                                 act: { [weak self] action, containers in ContainerControl.run(action, on: containers, in: self?.window) })
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        // The whole project: the containers `docker compose` made (Strata doesn't make missing ones).
        let all = next.services.flatMap(\.containers)
        if !all.isEmpty {
            var buttons: [NSView] = []
            for action in [ContainerAction.start, .stop] where all.contains(where: { action.applies(to: $0.state) }) {
                let title = action == .start ? String(localized: "Start All", comment: "Compose card: start every container of the project")
                    : String(localized: "Stop All", comment: "Compose card: stop every container of the project")
                buttons.append(ActionButton(title, symbol: ContainerControl.symbol(action)) { [weak self] in
                    ContainerControl.run(action, on: all, in: self?.window)
                })
            }
            if !next.busy.isEmpty {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                buttons = [spinner]
            }
            let row = FlowView(spacing: 6, lineSpacing: 6)
            buttons.forEach(row.add)
            content.setCustomSpacing(10, after: content.arrangedSubviews.last!)
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let running = next.services.filter { $0.containers.contains(where: \.isRunning) }.count
        let total = next.services.count
        let accessory = ContainerInspectorView.small(String(localized: "\(running) of \(total) running", comment: "Inspector, Compose: how many services run"),
                                                     color: .secondaryLabelColor)
        let card = InspectorCard(id: "compose", title: "Compose", symbol: "square.stack.3d.up", content: content, accessory: accessory)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The services of the Compose project in `folder`: from its compose file, and the containers `docker compose`
    /// made there. Nil when there's neither.
    /// Compose files' services, by path and modification date (the Inspector refreshes often).
    private static var servicesCache: [String: (modified: Date?, names: [String])] = [:]
    /// Working folders with links resolved, by the path a container gives.
    private static var resolvedCache: [String: String] = [:]

    private static func compose(in folder: URL) -> Shown? {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let containers = ContainerStore.shared.containers.filter { container in
            guard let directory = container.compose?.workingDirectory else { return false }
            let resolved = resolvedCache[directory] ?? URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
            if resolvedCache.count > 500 { resolvedCache.removeAll() }
            resolvedCache[directory] = resolved
            return resolved == real
        }
        let file = fileNames.lazy.map { folder.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard file != nil || !containers.isEmpty else { return nil }
        var names: [String] = []
        if let file {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = servicesCache[file.path], cached.modified == modified {
                names = cached.names
            } else {
                names = serviceNames(in: file)
                if servicesCache.count > 200 { servicesCache.removeAll() }
                servicesCache[file.path] = (modified, names)
            }
        }
        for name in containers.compactMap(\.compose?.service) where !names.contains(name) { names.append(name) }
        let services = names.map { name in
            Service(name: name, containers: containers.filter { $0.compose?.service == name }.sorted { $0.name < $1.name })
        }
        let project = containers.first?.compose?.project ?? folder.lastPathComponent
        let busy = containers.map(\.id).filter { ContainerStore.shared.busy[$0] != nil }
        return Shown(project: project, services: services, busy: busy)
    }

    /// The keys under `services:` in a compose file: enough YAML for the usual layouts (block style, any indent).
    static func serviceNames(in file: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20) else { return [] }
        return serviceNames(String(decoding: data, as: UTF8.self))
    }

    static func serviceNames(_ text: String) -> [String] {
        var names: [String] = []
        var inServices = false
        var indent: Int?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let leading = line.prefix { $0 == " " }.count
            if leading == 0 {
                inServices = trimmed.hasPrefix("services:")
                indent = nil
                continue
            }
            guard inServices else { continue }
            if indent == nil { indent = leading }
            guard leading == indent, let colon = trimmed.firstIndex(of: ":") else { continue }
            var key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let first = key.first, first == key.last, first == "\"" || first == "'" { key = String(key.dropFirst().dropLast()) }
            if !key.isEmpty, key.count <= 200, !key.hasPrefix("<<"), !names.contains(key) { names.append(key) }
            if names.count >= 200 { break }
        }
        return names
    }
}

/// A Compose service: its state, its name, and its containers (each opens its files).
private final class ServiceRow: NSView {
    init(_ service: ComposeInspectorView.Service, open: @escaping (String) -> Void,
         act: @escaping (ContainerAction, [ContainerInfo]) -> Void) {
        super.init(frame: .zero)
        let running = service.containers.contains(where: \.isRunning)
        let dot = NSImageView(image: NSImage(systemSymbolName: running ? "circle.fill" : "circle", accessibilityDescription: nil) ?? NSImage())
        dot.symbolConfiguration = .init(pointSize: 7, weight: .bold)
        dot.contentTintColor = running ? .systemGreen : .tertiaryLabelColor
        dot.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: service.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        var parts: [NSView] = [dot, name]
        if service.containers.isEmpty {
            parts.append(ContainerInspectorView.small(String(localized: "not created", comment: "Inspector, Compose: a service with no container yet"),
                                                      color: .tertiaryLabelColor))
        }
        for container in service.containers {
            let link = LinkButton(container.name, font: .systemFont(ofSize: 11)) { open(container.id) }
            link.toolTip = [container.status, String(localized: "Show its files", comment: "Inspector, Compose: tooltip on a container")]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            parts.append(link)
        }
        let row = NSStackView(views: parts)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // Start or stop this service's containers.
        let action: ContainerAction? = service.containers.isEmpty ? nil : running ? .stop : .start
        var constraints = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let action {
            let button = ActionButton("", symbol: ContainerControl.symbol(action)) { act(action, service.containers) }
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = ContainerControl.title(action)
            button.setAccessibilityLabel(ContainerControl.title(action) + " " + service.name)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            constraints += [
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -6),
            ]
        } else {
            constraints.append(row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(service.name + ", " + (running ? String(localized: "Running", comment: "Container state")
            : service.containers.isEmpty ? String(localized: "not created", comment: "Inspector, Compose: a service with no container yet")
            : String(localized: "Not Running", comment: "Container state: stopped, exited or created")))
    }

    required init?(coder: NSCoder) { fatalError() }
}

