import Foundation

/// The words a job shows in the Transfers list and in tooltips.
extension TransferJob {
    /// "Copying 1,204 items to Downloads", "Moved “Report.pdf” to Archive".
    var title: String {
        let done = state == .finished
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : Format.count(sources.count, "item", "items")
        if actionName == "Put Back" { return "\(done ? "Put back" : "Putting back") \(what)" }
        let verb = switch (mode, done) {
        case (.copy, false): "Copying"
        case (.copy, true): "Copied"
        case (.move, false): "Moving"
        case (.move, true): "Moved"
        }
        return "\(verb) \(what) to \(destinationName)"
    }

    var destinationName: String {
        FileManager.default.displayName(atPath: destination.path)
    }

    /// "2.1 GB of 5.4 GB · 84 MB/s · about 40 s left", "Paused", "Done · 3 failed"…
    var statusText: String {
        if isAwaitingDecision { return "Waiting for your decision" }
        switch state {
        case .queued:
            return isWaitingForDisk ? "Waiting for another transfer to this disk" : "Waiting…"
        case .scanning:
            return totalFiles > 0 ? "Preparing · \(Format.count(totalFiles, "item", "items"))" : "Preparing…"
        case .running:
            var parts = [amountText]
            if let throughput, throughput >= 1, totalBytes > 0 { parts.append(TransferFormat.rate(throughput)) }
            if let estimatedTimeRemaining { parts.append(TransferFormat.remaining(estimatedTimeRemaining)) }
            return parts.joined(separator: " · ")
        case .paused:
            return "Paused · \(amountText)"
        case .finished:
            var parts = ["Done"]
            if !failures.isEmpty { parts.append("\(failures.count.formatted()) failed") }
            if skippedCount > 0 { parts.append("\(skippedCount.formatted()) skipped") }
            if failures.isEmpty, options.verify { parts.append("verified") }
            return parts.joined(separator: " · ")
        case .failed:
            if let errorMessage { return errorMessage }
            if failures.count == 1 { return failures[0].message }
            return "Failed · \(failures.count.formatted()) errors"
        case .cancelled:
            return completedItems > 0 ? "Stopped · \(completedItems.formatted()) of \(sources.count.formatted()) done" : "Stopped"
        }
    }

    /// "2.1 GB of 5.4 GB", or item counts when the job is mostly tiny files.
    private var amountText: String {
        let prefix = isVerifying ? "Verifying · " : ""
        if totalBytes < 1_000_000, totalFiles > 1 {
            return prefix + "\(min(completedFiles, totalFiles).formatted()) of \(Format.count(totalFiles, "item", "items"))"
        }
        let done = isVerifying ? verifiedBytes : completedBytes
        return prefix + "\(Format.bytes(min(done, totalBytes))) of \(Format.bytes(totalBytes))"
    }

    /// Up to eight failures, one per line, for a tooltip.
    var failureSummary: String? {
        if let errorMessage { return errorMessage }
        guard !failures.isEmpty else { return nil }
        var lines = failures.prefix(8).map { "\($0.displayName) — \($0.message)" }
        if failures.count > 8 { lines.append("and \((failures.count - 8).formatted()) more") }
        return lines.joined(separator: "\n")
    }

    var symbolName: String {
        mode == .copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard"
    }
}

enum TransferFormat {
    static func rate(_ bytesPerSecond: Double) -> String {
        Format.bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// "a few seconds left", "about 40 s left", "about 3 min left", "about 1 h 20 min left".
    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 55 { return "about \(Int((seconds / 5).rounded()) * 5) s left" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "about \(hours) h left" : "about \(hours) h \(rest) min left"
    }
}
