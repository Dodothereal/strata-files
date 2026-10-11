import AppKit
import FoundationModels

/// The on-device Apple Intelligence model: whether it can be used right now, and how to explain it when it can't.
/// Every AI feature checks this first and falls back to deterministic behaviour (rules, key sentences) or hides itself.
nonisolated enum AIModel {
    enum Status: Sendable, Equatable {
        case available
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unsupportedLanguage
        /// Switched off for testing (`STRATA_AI_DISABLED=1`).
        case disabled
    }

    static var status: Status {
        if ProcessInfo.processInfo.environment["STRATA_AI_DISABLED"] == "1" { return .disabled }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return model.supportsLocale() ? .available : .unsupportedLanguage
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .modelNotReady
        }
    }

    static var isAvailable: Bool { status == .available }

    /// Tokens the model can see at once (instructions, prompt and response together).
    static var contextSize: Int { SystemLanguageModel.default.contextSize }

    /// One sentence for UI, or nil when the model is available.
    static var explanation: String? {
        switch status {
        case .available: nil
        case .deviceNotEligible: "This Mac doesn’t support Apple Intelligence."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use this."
        case .modelNotReady: "Apple Intelligence is still getting ready. Try again in a little while."
        case .unsupportedLanguage: "Apple Intelligence doesn’t support your Mac’s language yet."
        case .disabled: "Apple Intelligence features are turned off."
        }
    }

    /// A short phrase for captions: what to do (or why not) when the model isn't available.
    static var shortStatus: String {
        switch status {
        case .available: "Apple Intelligence · On this Mac"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .deviceNotEligible: "Apple Intelligence isn’t available on this Mac"
        case .modelNotReady: "Apple Intelligence is getting ready"
        case .unsupportedLanguage: "Apple Intelligence doesn’t support this language yet"
        case .disabled: "Apple Intelligence is turned off"
        }
    }

    /// Whether opening System Settings can fix it.
    static var canOpenSettings: Bool { status == .appleIntelligenceNotEnabled }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    @MainActor static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// A short label for where a result came from.
    static let onDeviceLabel = "Apple Intelligence"
}

/// Turns FoundationModels errors into a sentence for the UI.
nonisolated enum AIErrorText {
    static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return "The document is too long for the on-device model."
            case .assetsUnavailable: return "Apple Intelligence isn’t ready yet. Try again in a little while."
            case .guardrailViolation, .refusal: return "The on-device model declined this request."
            case .unsupportedLanguageOrLocale: return "This language isn’t supported by the on-device model."
            case .rateLimited, .concurrentRequests: return "The on-device model is busy. Try again in a moment."
            case .decodingFailure, .unsupportedGuide: return "The on-device model returned something unexpected."
            @unknown default: return error.localizedDescription
            }
        }
        if error is CancellationError { return "Cancelled." }
        return error.localizedDescription
    }
}

/// Wording helpers usable off the main actor (`Format` is main-actor isolated).
nonisolated enum AIText {
    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}
