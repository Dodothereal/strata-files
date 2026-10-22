import AppKit

/// ssh asks for a password, a key's passphrase or whether to trust a server it hasn't seen before through this program
/// (SSH_ASKPASS) when Strata connects to an SFTP server. Strata marks that with STRATA_ASKPASS and passes the dialog's
/// words in your language (STRATA_ASKPASS_*). The answer goes to ssh on standard output; Cancel exits with 1. Nothing is
/// stored.
///
/// ssh says what kind of question it is in SSH_ASKPASS_PROMPT: "confirm" (allow or not: exit 0 means yes), "none" (a
/// notice, like "touch your security key"; ssh ends it when it's done), or nothing (an answer to type). A server's own
/// login prompts arrive as the last kind, so only ssh's exact host key question gets a Connect button.
@MainActor
func runAskpass(prompt: String, environment: [String: String]) -> Never {
    func text(_ key: String, _ fallback: String) -> String {
        environment["STRATA_ASKPASS_" + key].flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } ?? fallback
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate()

    // What ssh says (the server's prompt, or a host key's fingerprint), as plain text and not too long.
    let shown = String(prompt.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }.prefix(800))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let alert = NSAlert()
    alert.informativeText = shown
    alert.window.level = .floating
    let kind = environment["SSH_ASKPASS_PROMPT"] ?? ""

    if kind == "none" {
        // A notice: shown until ssh is done with it (it ends this program), or dismissed.
        alert.messageText = text("LOGIN_TITLE", "Log in")
        alert.addButton(withTitle: text("HIDE", "OK"))
        alert.runModal()
        exit(0)
    }

    let isHostKeyQuestion = kind.isEmpty && shown.hasSuffix("(yes/no/[fingerprint])?") && shown.contains("fingerprint is")
    if kind == "confirm" || isHostKeyQuestion {
        alert.messageText = isHostKeyQuestion ? text("TRUST_TITLE", "Connect to this server?") : text("LOGIN_TITLE", "Log in")
        if isHostKeyQuestion {
            alert.informativeText = text("TRUST_NOTE", "Strata hasn’t connected to this server from this Mac before.") + "\n\n" + shown
        }
        alert.addButton(withTitle: text("CONNECT", "Connect"))
        alert.addButton(withTitle: text("CANCEL", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
        try? FileHandle.standardOutput.write(contentsOf: Data("yes\n".utf8))
        exit(0)
    }

    alert.messageText = text("LOGIN_TITLE", "Log in")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: text("LOGIN", "Log In"))
    alert.addButton(withTitle: text("CANCEL", "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
    _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
    try? FileHandle.standardOutput.write(contentsOf: Data((field.stringValue + "\n").utf8))
    exit(0)
}
