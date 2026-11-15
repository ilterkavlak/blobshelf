import AppKit
import CryptoKit
import Foundation
import Observation
import BlobshelfCore

@MainActor @Observable
final class AppModel {
    static let maxConcurrentTransfers = 4

    private(set) var config = AppConfig()
    private(set) var sessions: [UUID: BucketSession] = [:]
    private(set) var transfers: [Transfer] = []
    private(set) var jobStatus: [UUID: JobStatus] = [:]
    var selection: SidebarItem? = .backups
    var alert: String?

    private let store = ConfigStore()
    private let keychain = Keychain(service: AppPaths.bundleID)
    private let engine = BackupEngine(manifestsDir: AppPaths.manifests, skipping: AppPaths.ownState)
    private var watchers: [UUID: FolderWatcher] = [:]
    private var scoped: [UUID: (bookmark: Data, url: URL)] = [:]
    private var lastAttempt: [UUID: Date] = [:]
    private var timer: Timer?
    private var queue: [Transfer] = []
    private var queueHead = 0
    private var runningTransfers = 0
    private var allocator = LocalPathAllocator()
    private var downloadsPlanning = 0

    init() {
        Self.clearPreviews()
        do {
            config = try store.load()
        } catch {
            // Keep the unreadable file instead of overwriting it with an empty config on the next save.
            let url = store.url
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
            alert = "Your settings could not be read and were set aside: \(error.localizedDescription)"
        }
        for bucket in config.buckets {
            if let token = try? keychain.read(account: bucket.bucketID), let decoded = BlobToken(token) {
                sessions[bucket.id] = makeSession(bucket, token: token, decoded: decoded)
            }
        }
        if let first = config.buckets.first { selection = .bucket(first.id) }
        startScheduler()
    }

    private func makeSession(_ bucket: BucketConfig, token: String, decoded: BlobToken) -> BucketSession {
        let provider = CredentialProvider(fetcher: CredentialsAPI(token: token))
        let drive = DriveService(client: S3Client(credentials: provider), token: decoded,
                                 publicHostSuffix: CredentialsAPI.publicHostSuffix)
        return BucketSession(config: bucket, drive: drive)
    }

    private func save() {
        do {
            try store.save(config)
        } catch {
            alert = "Could not save settings: \(error.localizedDescription)"
        }
    }

    // MARK: Buckets

    func addBucket(name: String, token rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = BlobToken(token) else { throw BlobError.invalidToken }
        // Adding a bucket that is already here replaces its token (e.g. after rotation), keeping its backups.
        let existing = config.buckets.first { $0.bucketID == decoded.bucketID }
        let bucket = existing ?? BucketConfig(name: name.isEmpty ? decoded.bucketID : name, bucketID: decoded.bucketID)
        let session = makeSession(bucket, token: token, decoded: decoded)
        session.info = try await session.drive.client.credentials.credentials()
        try keychain.save(token, account: decoded.bucketID)
        if existing == nil {
            config.buckets.append(bucket)
            save()
        }
        sessions[bucket.id] = session
        selection = .bucket(bucket.id)
        refreshJobAccess()
        tick()
    }

    func removeBucket(_ id: UUID) {
        guard let bucket = config.buckets.first(where: { $0.id == id }) else { return }
        if let job = config.jobs.first(where: { $0.bucketRef == id }) {
            alert = "“\(bucket.name)” is the destination of the backup of “\(job.name)”. Remove that backup first."
            return
        }
        keychain.delete(account: bucket.bucketID)
        config.buckets.removeAll { $0.id == id }
        sessions[id] = nil
        Self.clearPreviews(of: bucket.bucketID)
        if selection == .bucket(id) { selection = .backups }
        save()
    }

    func bucketName(_ id: UUID) -> String {
        config.buckets.first { $0.id == id }?.name ?? "missing bucket"
    }

    // MARK: Transfers

    var activeTransferCount: Int { transfers.filter { !$0.isFinished }.count }

    var failedTransfers: [Transfer] {
        transfers.filter { if case .failed = $0.state { true } else { false } }
    }

    /// `releasing`: URLs from an open panel, whose sandbox access is given up once the uploads finish.
    func upload(_ urls: [URL], to session: BucketSession, prefix: String, releasing: [URL] = []) {
        guard session.canWrite else {
            alert = "This bucket is read-only."
            releasing.forEach { $0.stopAccessingSecurityScopedResource() }
            return
        }
        let drive = session.drive
        let browser = session.browser
        Task {
            let plan = await Task.detached { DriveService.uploadPlan(for: urls, into: prefix) }.value
            let done = Countdown(plan.count) { releasing.forEach { $0.stopAccessingSecurityScopedResource() } }
            enqueue(plan.map { entry in
                let key = entry.key
                let finish = { @MainActor in
                    browser.scheduleReload()
                    done.tick()
                }
                guard let file = entry.file else {
                    return Transfer(kind: .upload, name: DriveService.name(of: key), detail: key,
                                    work: { _ in try await drive.client.putData(Data(), key: key) }, onFinish: finish)
                }
                return Transfer(kind: .upload, name: file.lastPathComponent, detail: key,
                                work: { progress in try await drive.upload(file, key: key, progress: progress) },
                                onFinish: finish)
            })
        }
    }

    /// Downloads files and whole folders into `directory` (an open-panel URL whose access is given
    /// up when the downloads finish). Local paths come from one shared allocator, so neither this
    /// batch nor one planned concurrently can pick a path another download already holds.
    func download(_ items: [DriveItem], from session: BucketSession, to directory: URL) {
        let drive = session.drive
        downloadsPlanning += 1
        Task {
            var batch: [Transfer] = []
            let done = Countdown { directory.stopAccessingSecurityScopedResource() }
            @MainActor func add(_ key: String, _ destination: URL) {
                batch.append(Transfer(kind: .download, name: DriveService.name(of: key), detail: destination.path,
                                      work: { progress in try await drive.download(key, to: destination, progress: progress) },
                                      onFinish: { done.tick() }))
            }
            do {
                for item in items {
                    let root = allocator.top(item.name, in: directory)
                    if !item.isFolder {
                        add(item.key, root)
                        continue
                    }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    for object in try await drive.keys(of: item) {
                        let rel = String(object.key.dropFirst(item.key.count))
                        if object.key.hasSuffix("/") {
                            if let dir = allocator.directory(rel, under: root) {
                                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            }
                        } else if let destination = allocator.file(rel, under: root) {
                            add(object.key, destination)
                        }
                    }
                }
            } catch {
                alert = error.localizedDescription
            }
            done.start(batch.count)
            downloadsPlanning -= 1
            enqueue(batch)
        }
    }

    func cancel(_ transfer: Transfer) {
        if transfer.state == .queued {
            transfer.state = .cancelled
            transfer.onFinish()
        } else {
            transfer.task?.cancel()
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.isFinished }
    }

    private func enqueue(_ batch: [Transfer]) {
        transfers += batch
        queue += batch
        pump()
    }

    private func pump() {
        while runningTransfers < Self.maxConcurrentTransfers && queueHead < queue.count {
            let transfer = queue[queueHead]
            queueHead += 1
            guard transfer.state == .queued else { continue }
            runningTransfers += 1
            transfer.state = .running
            transfer.task = Task {
                do {
                    try await transfer.work { done, total in
                        Task { @MainActor in
                            transfer.done = done
                            transfer.total = total
                        }
                    }
                    transfer.state = .done
                } catch {
                    transfer.state = Self.isCancellation(error) ? .cancelled : .failed(error.localizedDescription)
                }
                transfer.onFinish()
                runningTransfers -= 1
                pump()
            }
        }
        if queueHead == queue.count {
            queue = []
            queueHead = 0
        }
        // Once nothing is planned or pending, every chosen path exists on disk (or was abandoned),
        // so the allocator can forget its reservations.
        if downloadsPlanning == 0 && runningTransfers == 0 && queue.isEmpty {
            allocator = LocalPathAllocator()
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: Preview

    /// Downloads a read-only copy of a file into the preview cache, or returns nil if its bucket was
    /// removed meanwhile. Read-only, so an editor asks for Save As instead of saving into a cache
    /// that is cleared. Each key gets its own directory, so "a" and "a/b", or keys differing only in
    /// case, never compete for the same local path.
    func previewFile(_ item: DriveItem, in session: BucketSession) async throws -> URL? {
        var safeName = item.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if ["", ".", ".."].contains(safeName) { safeName = "file" }
        let url = Self.previews(of: session.config.bucketID).appending(path: Self.digest(item.key)).appending(path: safeName)
        try? FileManager.default.removeItem(at: url)
        try await session.drive.download(item.key, to: url)
        guard sessions[session.id] === session else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return nil
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }

    /// Opened files are plain copies of bucket contents; none outlive the app or their bucket.
    static func clearPreviews(of bucketID: String? = nil) {
        try? FileManager.default.removeItem(at: bucketID.map(previews(of:)) ?? AppPaths.preview)
    }

    /// Hashed, because bucket ids and keys come from outside and must never act as path segments.
    private static func previews(of bucketID: String) -> URL {
        AppPaths.preview.appending(path: digest(bucketID))
    }

    private static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Backups

    func saveJob(_ job: BackupJob) throws {
        var job = job
        job.remotePrefix = BackupJob.normalizedPrefix(job.remotePrefix)
        try BackupJob.validate(job, among: config.jobs)
        if sessions[job.bucketRef]?.info?.isPublic == true { throw BackupJobError.publicBucket }
        let isNew: Bool
        if let i = config.jobs.firstIndex(where: { $0.id == job.id }) {
            isNew = false
            if config.jobs[i].remotePrefix != job.remotePrefix || config.jobs[i].bucketRef != job.bucketRef {
                try? FileManager.default.removeItem(at: engine.manifestURL(for: config.jobs[i]))
            }
            config.jobs[i] = job
        } else {
            isNew = true
            config.jobs.append(job)
        }
        save()
        refreshJobAccess()
        if isNew || job.enabled { lastAttempt[job.id] = nil }
        tick()
    }

    func removeJob(_ id: UUID) {
        jobStatus[id]?.task?.cancel()
        jobStatus[id] = nil
        config.jobs.removeAll { $0.id == id }
        let manifests = (try? FileManager.default.contentsOfDirectory(at: AppPaths.manifests, includingPropertiesForKeys: nil)) ?? []
        for url in manifests where url.lastPathComponent.hasPrefix(id.uuidString) {
            try? FileManager.default.removeItem(at: url)
        }
        save()
        refreshJobAccess()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = config.jobs.firstIndex(where: { $0.id == id }) else { return }
        config.jobs[i].enabled = enabled
        save()
        refreshJobAccess()
        if enabled { trigger(id) } else { jobStatus[id]?.task?.cancel() }
    }

    func backUpAllNow() {
        for job in config.jobs where job.enabled { trigger(job.id) }
    }

    enum SyncState {
        case syncing, attention, upToDate, paused, notSetUp

        var symbol: String {
            switch self {
            case .syncing: "arrow.triangle.2.circlepath.icloud"
            case .attention: "exclamationmark.icloud"
            case .upToDate: "checkmark.icloud"
            case .paused: "pause.circle"
            case .notSetUp: "icloud"
            }
        }
    }

    var syncState: SyncState {
        if jobStatus.values.contains(where: \.running) || activeTransferCount > 0 { return .syncing }
        let enabled = config.jobs.filter(\.enabled)
        if enabled.contains(where: { $0.lastError != nil }) || !failedTransfers.isEmpty { return .attention }
        if config.jobs.isEmpty { return .notSetUp }
        if enabled.isEmpty { return .paused }
        return .upToDate
    }

    var backupSummary: String {
        if let (id, status) = jobStatus.first(where: { $0.value.running }),
           let job = config.jobs.first(where: { $0.id == id }) {
            return "Backing up \(job.name)… " + (status.progress.map(Self.describe) ?? "")
        }
        let failing = config.jobs.filter { $0.enabled && $0.lastError != nil }.count
        if failing > 0 { return failing == 1 ? "1 backup needs attention" : "\(failing) backups need attention" }
        if activeTransferCount > 0 { return "\(activeTransferCount) transfer(s) in progress" }
        if !failedTransfers.isEmpty { return "\(failedTransfers.count) transfer(s) failed" }
        if config.jobs.isEmpty { return "No backups set up" }
        if !config.jobs.contains(where: \.enabled) { return "Backups are paused" }
        return "Everything is backed up"
    }

    static func describe(_ progress: BackupProgress) -> String {
        switch progress {
        case .scanning: "scanning"
        case let .uploading(done, total): total == 0 ? "nothing to upload" : "\(done) of \(total) files"
        }
    }

    private func startScheduler() {
        refreshJobAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func tick() {
        let now = Date()
        for job in config.jobs where job.enabled {
            if let last = lastAttempt[job.id], now.timeIntervalSince(last) < Double(job.intervalMinutes) * 60 { continue }
            trigger(job.id)
        }
    }

    static let noAccess = "Blobshelf can no longer read this folder. Edit the backup and choose the folder again."

    /// Opens the security-scoped bookmark of every enabled job (keeping already-open ones, so a
    /// running backup never loses access mid-run), closes the rest, and restarts the folder watchers.
    private func refreshJobAccess() {
        var changed = false
        for i in config.jobs.indices {
            let job = config.jobs[i]
            if let open = scoped[job.id], !job.enabled || open.bookmark != job.bookmark {
                open.url.stopAccessingSecurityScopedResource()
                scoped[job.id] = nil
            }
            guard job.enabled, let bookmark = job.bookmark, scoped[job.id] == nil else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource()
            else {
                config.jobs[i].lastError = Self.noAccess
                changed = true
                continue
            }
            var current = bookmark
            if stale, let fresh = try? BackupJob.makeBookmark(url) {
                current = fresh
                config.jobs[i].bookmark = fresh
                changed = true
            }
            if url.path != job.localPath {
                config.jobs[i].localPath = url.path
                changed = true
            }
            scoped[job.id] = (current, url)
        }
        for id in scoped.keys where !config.jobs.contains(where: { $0.id == id }) {
            scoped[id]?.url.stopAccessingSecurityScopedResource()
            scoped[id] = nil
        }
        if changed { save() }

        watchers.values.forEach { $0.stop() }
        watchers = [:]
        for job in config.jobs where job.enabled {
            let id = job.id
            let watcher = FolderWatcher(path: job.localPath, ignoring: AppPaths.ownState) { [weak self] in
                Task { @MainActor in self?.trigger(id) }
            }
            watcher.start()
            watchers[id] = watcher
        }
    }

    func trigger(_ id: UUID) {
        guard var job = config.jobs.first(where: { $0.id == id }), job.enabled else { return }
        if jobStatus[id]?.running == true {
            jobStatus[id]?.rerun = true
            return
        }
        lastAttempt[id] = Date()
        if job.bookmark != nil && scoped[id] == nil {
            // The folder may be back (e.g. an external disk was reconnected): try its bookmark again.
            refreshJobAccess()
            guard scoped[id] != nil, let refreshed = config.jobs.first(where: { $0.id == id }) else {
                finish(id, success: false, error: Self.noAccess)
                return
            }
            job = refreshed
        }
        guard let session = sessions[job.bucketRef] else {
            finish(id, success: false, error: "The destination bucket is not available. Add its token again.")
            return
        }
        let engine = self.engine
        let client = session.drive.client
        jobStatus[id] = JobStatus(running: true, progress: .scanning)
        jobStatus[id]?.task = Task {
            var success = false
            var errorText: String?
            do {
                let result = try await engine.run(job, client: client) { progress in
                    Task { @MainActor [weak self] in self?.jobStatus[id]?.progress = progress }
                }
                errorText = result.problem
                success = errorText == nil
            } catch {
                if Self.isCancellation(error) {
                    // A resume while the cancelled run was unwinding asked for a new run.
                    let rerun = jobStatus[id]?.rerun ?? false
                    jobStatus[id] = nil
                    if rerun { trigger(id) }
                    return
                }
                errorText = error.localizedDescription
            }
            finish(id, success: success, error: errorText)
        }
    }

    private func finish(_ id: UUID, success: Bool, error: String?) {
        let rerun = jobStatus[id]?.rerun ?? false
        jobStatus[id] = nil
        if let i = config.jobs.firstIndex(where: { $0.id == id }) {
            if success { config.jobs[i].lastSuccess = Date() }
            config.jobs[i].lastError = error
            save()
        }
        if rerun { trigger(id) }
    }
}
