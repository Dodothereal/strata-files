import CoreServices
import Foundation

/// A folder-level FSEvents subscription. Events arrive on a private serial queue, batched by `latency`.
nonisolated final class FSEventsStream: @unchecked Sendable {
    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
        let id: FSEventStreamEventId

        /// Changes under `path` weren't itemized (too many, or events were dropped): re-check the whole subtree.
        var mustScanSubdirectories: Bool {
            let flags = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped
            return self.flags & FSEventStreamEventFlags(flags) != 0
        }

        /// The journal can't be trusted any more (a watched root moved, or event ids wrapped): rebuild.
        var invalidatesIndex: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0
        }

        var isHistoryDone: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.strata.fsevents", qos: .utility)
    /// Receives each batch of events. Set before `start`.
    var handler: (@Sendable ([Event]) -> Void)?

    /// Starts watching `paths`, replaying everything since `since` (or only new changes when `nil`).
    func start(paths: [String], since: FSEventStreamEventId?, latency: TimeInterval = 0.4) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let me = Unmanaged<FSEventsStream>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, list.count) {
                events.append(Event(path: list[index], flags: flags[index], id: ids[index]))
            }
            me.handler?(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    static var currentEventID: FSEventStreamEventId { FSEventsGetCurrentEventId() }
}
