import CoreServices
import Foundation

/// A folder-level FSEvents subscription. Events arrive on a private serial queue, batched by `latency`.
nonisolated package final class FSEventsStream: @unchecked Sendable {
    package struct Event: Sendable {
        package let path: String
        package let flags: FSEventStreamEventFlags
        package let id: FSEventStreamEventId

        package init(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId) {
            self.path = path
            self.flags = flags
            self.id = id
        }

        /// Changes under `path` weren't itemized (too many, or events were dropped): re-check the whole subtree.
        package var mustScanSubdirectories: Bool {
            let flags = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped
            return self.flags & FSEventStreamEventFlags(flags) != 0
        }

        /// The journal can't be trusted any more (a watched root moved, or event ids wrapped): rebuild.
        package var invalidatesIndex: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0
        }

        package var isHistoryDone: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.strata.fsevents", qos: .utility)
    /// Receives each batch of events. Set before `start`.
    package var handler: (@Sendable ([Event]) -> Void)?

    package init() {}

    /// Starts watching `paths`, replaying everything since `since` (or only new changes when `nil`).
    package func start(paths: [String], since: FSEventStreamEventId?, latency: TimeInterval = 0.4) {
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

    package func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    package static var currentEventID: FSEventStreamEventId { FSEventsGetCurrentEventId() }
}
