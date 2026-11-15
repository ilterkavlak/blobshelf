import CoreServices
import Foundation

/// Calls `onChange` after files change under `path`. FSEvents coalesces events over `latency`
/// seconds, which debounces bursts such as a large copy into one trigger.
public final class FolderWatcher: @unchecked Sendable {
    private let path: String
    private let ignoring: [String]
    private let onChange: @Sendable () -> Void
    private let latency: TimeInterval
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "FolderWatcher")

    public init(path: String, ignoring: [URL], latency: TimeInterval = 10, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.ignoring = ignoring.map { $0.resolvingSymlinksInPath().path + "/" }
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            if changed.prefix(count).contains(where: { p in !watcher.ignoring.contains { (p + "/").hasPrefix($0) } }) {
                watcher.onChange()
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
