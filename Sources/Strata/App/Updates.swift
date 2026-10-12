import AppKit
import Sparkle
import SwiftUI

/// Updates through Sparkle: Strata ▸ Check for Updates…, and checks in the background if you allow them (Sparkle asks
/// on the second launch; Settings ▸ General changes it). Every update and the list of updates are signed with Strata's
/// key (SUPublicEDKey) and checked before anything is unpacked.
final class Updates {
    static let shared = Updates()

    /// Nil when running outside a signed app bundle (a development build), where there's nothing to update.
    let controller: SPUStandardUpdaterController?

    private init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
            && Bundle.main.bundleURL.pathExtension == "app"
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    var updater: SPUUpdater? { controller?.updater }

    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    func checkNow(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}

/// Settings ▸ General ▸ Updates.
struct UpdatesSection: View {
    @State private var checks = Updates.shared.updater?.automaticallyChecksForUpdates ?? false
    @State private var downloads = Updates.shared.updater?.automaticallyDownloadsUpdates ?? false

    var body: some View {
        Section("Updates") {
            if let updater = Updates.shared.updater {
                Toggle(isOn: Binding(get: { checks }, set: { checks = $0; updater.automaticallyChecksForUpdates = $0 })) {
                    Text("Check for updates automatically")
                    Text("Once a day, Strata asks GitHub whether there’s a newer version.")
                }
                Toggle(isOn: Binding(get: { downloads }, set: { downloads = $0; updater.automaticallyDownloadsUpdates = $0 })) {
                    Text("Download and install updates automatically")
                    Text("Updates install when Strata quits.")
                }
                .disabled(!checks)
                LabeledContent(String(localized: "Version \(Bundle.main.shortVersion)", comment: "Settings: the app's version")) {
                    Button("Check Now") { Updates.shared.checkNow(nil) }
                        .disabled(!Updates.shared.canCheck)
                }
            } else {
                Text("Updates are checked in copies of Strata installed from a release.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Bundle {
    /// "0.2.0".
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
}
