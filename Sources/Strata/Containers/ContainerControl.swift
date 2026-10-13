import AppKit

/// Starting, stopping… containers, and shells in them, the same way from every place that offers it (the context menu,
/// the Inspector, the Compose card, the command palette).
enum ContainerControl {
    /// Does `action` to `containers` (those it applies to). Stopping, restarting or pausing several asks first; what
    /// fails is shown, with the engine's reason.
    static func run(_ action: ContainerAction, on containers: [ContainerInfo], in window: NSWindow?) {
        let targets = containers.filter { action.applies(to: $0.state) && ContainerStore.shared.busy[$0.id] == nil }
        guard !targets.isEmpty else { return NSSound.beep() }
        let go = {
            Task {
                let failures = await ContainerStore.shared.perform(action, on: targets)
                guard !failures.isEmpty else { return }
                let alert = NSAlert()
                alert.messageText = failures.count == 1
                    ? String(localized: "“\(failures[0].name)” couldn’t be changed.", comment: "A container action (start, stop…) failed")
                    : String(localized: "\(failures.count) containers couldn’t be changed.", comment: "plural")
                alert.informativeText = failures.map { failures.count == 1 ? $0.message : "\($0.name): \($0.message)" }.joined(separator: "\n")
                BrowserViewController.present(alert, in: window) { _ in }
            }
        }
        guard targets.count > 1, action == .stop || action == .restart || action == .pause else { return _ = go() }
        let alert = NSAlert()
        alert.messageText = switch action {
        case .stop: String(localized: "Stop \(targets.count) containers?", comment: "plural")
        case .restart: String(localized: "Restart \(targets.count) containers?", comment: "plural")
        default: String(localized: "Pause \(targets.count) containers?", comment: "plural")
        }
        alert.informativeText = ListFormatter.localizedString(byJoining: targets.prefix(8).map(\.name))
            + (targets.count > 8 ? "…" : "")
        alert.addButton(withTitle: title(action))
        alert.addButton(withTitle: String(localized: "Cancel"))
        BrowserViewController.present(alert, in: window) { response in
            if response == .alertFirstButtonReturn { _ = go() }
        }
    }

    static func title(_ action: ContainerAction) -> String {
        switch action {
        case .start: String(localized: "Start", comment: "Container action")
        case .stop: String(localized: "Stop", comment: "Container action")
        case .restart: String(localized: "Restart", comment: "Container action")
        case .pause: String(localized: "Pause", comment: "Container action")
        case .unpause: String(localized: "Resume", comment: "Container action: unpause")
        }
    }

    static func symbol(_ action: ContainerAction) -> String {
        switch action {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .pause: "pause.fill"
        case .unpause: "playpause.fill"
        }
    }

    /// What the container is doing while `action` runs ("Stopping…").
    static func progress(_ action: ContainerAction) -> String {
        switch action {
        case .start: String(localized: "Starting…", comment: "A container being started")
        case .unpause: String(localized: "Resuming…", comment: "A paused container being resumed")
        case .stop: String(localized: "Stopping…", comment: "A container being stopped")
        case .restart: String(localized: "Restarting…", comment: "A container being restarted")
        case .pause: String(localized: "Pausing…", comment: "A container being paused")
        }
    }

    /// The actions that make sense for `containers` together (any of them), in menu order.
    static func actions(for containers: [ContainerInfo]) -> [ContainerAction] {
        ContainerAction.allCases.filter { action in containers.contains { action.applies(to: $0.state) } }
    }

    /// Opens a shell in a running container, in its folder `path`, in your terminal (as `docker exec -it` would).
    @discardableResult
    static func openTerminal(in container: ContainerInfo, at path: String, engine: ContainerEngine) -> Bool {
        guard container.isRunning, ContainerAPI.isContainerID(container.id) else { return false }
        return ProjectActions.openCommandFile(named: "\(container.name) — Terminal", body: terminalScript(id: container.id, path: path, socket: engine.socket))
    }

    /// The `.command` file's script, run by `/bin/sh`: it deletes itself, takes the PATH your login shell sets up (so
    /// `docker` from Homebrew, OrbStack or Docker Desktop is found; the shell only runs a fixed `printenv`, whatever
    /// shell it is), then runs bash, else sh, in the container with `docker` (pointed at the engine Strata shows) or
    /// else `podman`. Every value is quoted for `/bin/sh` on its own; the container ID is hex.
    static func terminalScript(id: String, path: String, socket: String) -> String {
        let shell = "command -v bash >/dev/null 2>&1 && exec bash || exec sh"
        let folder = ShellQuote.quote(path.isEmpty ? "/" : path)
        let host = ShellQuote.quote("unix://" + socket)
        let missing = ShellQuote.quote(String(localized: "Strata needs the docker command for this.", comment: "Shown in Terminal when docker isn't installed"))
        return """
        #!/bin/sh
        # Written by Strata to open a shell in a container. Deletes itself; safe to remove.
        rm -f -- "$0"
        login=$("${SHELL:-/bin/zsh}" -l -i -c '/usr/bin/printenv PATH | /usr/bin/sed "s/^/STRATA_PATH=/"' </dev/null 2>/dev/null | /usr/bin/sed -n 's/^STRATA_PATH=//p' | /usr/bin/tail -n 1)
        PATH="${login:+$login:}$HOME/.orbstack/bin:$HOME/.rd/bin:/opt/homebrew/bin:/usr/local/bin:/opt/podman/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin"
        export PATH
        if command -v docker >/dev/null 2>&1; then
          DOCKER_HOST=\(host) exec docker exec -it -w \(folder) \(id) /bin/sh -c \(ShellQuote.quote(shell))
        elif command -v podman >/dev/null 2>&1; then
          exec podman --url \(host) exec -it -w \(folder) \(id) /bin/sh -c \(ShellQuote.quote(shell))
        fi
        echo \(missing)
        exec "${SHELL:-/bin/zsh}" -l

        """
    }
}
