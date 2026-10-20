import AppKit
import SwiftUI

/// Settings ▸ General ▸ Language: the system's choice, or any language Strata comes in (handy for trying a
/// translation). macOS applies it when Strata next starts, so it offers to restart.
struct LanguageSection: View {
    /// The languages in the app (from its Localization files), English first.
    private static let languages: [String] = {
        let shipped = Bundle.main.localizations.filter { $0 != "Base" }
        return shipped.sorted { a, b in a == "en" || (b != "en" && name(a).localizedCaseInsensitiveCompare(name(b)) == .orderedAscending) }
    }()

    @State private var chosen = Prefs.shared.language

    /// "Deutsch (German)": the language in itself, then in the current one.
    static func name(_ code: String) -> String {
        let native = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        let here = Locale.current.localizedString(forIdentifier: code) ?? code
        return native.caseInsensitiveCompare(here) == .orderedSame ? native : "\(native) (\(here))"
    }

    var body: some View {
        Section("Language") {
            Picker("Language", selection: Binding(get: { chosen }, set: { choose($0) })) {
                Text("System Default").tag("")
                ForEach(Self.languages, id: \.self) { code in
                    Text(Self.name(code)).tag(code)
                }
            }
            Text("Translations are made by people who use Strata. Yours is welcome: see Localization/README.md in the source.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func choose(_ code: String) {
        guard code != chosen else { return }
        chosen = code
        Prefs.shared.language = code
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Strata to switch languages?")
        alert.informativeText = String(localized: "The new language is used when Strata starts again.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later", comment: "Alert button: restart Strata later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Self.relaunch()
    }

    /// Opens a fresh copy of Strata, then quits this one (windows come back if Settings says they should).
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
