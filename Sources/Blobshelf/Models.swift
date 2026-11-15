import Foundation
import Observation
import BlobshelfCore

enum SidebarItem: Hashable {
    case bucket(UUID)
    case backups
    case transfers
}

@MainActor @Observable
final class BucketSession {
    let config: BucketConfig
    let drive: DriveService
    let browser: BrowserModel
    var info: BlobCredentials?
    var infoError: String?

    var id: UUID { config.id }
    var canWrite: Bool { info?.isReadOnly != true }

    init(config: BucketConfig, drive: DriveService) {
        self.config = config
        self.drive = drive
        browser = BrowserModel(drive: drive)
    }

    func refreshInfo() async {
        do {
            info = try await drive.client.credentials.credentials()
            infoError = nil
        } catch {
            infoError = error.localizedDescription
        }
    }
}

@MainActor @Observable
final class BrowserModel {
    let drive: DriveService
    private(set) var prefix = ""
    private(set) var items: [DriveItem] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loaded = false
    var selection = Set<DriveItem.ID>()
    var search = ""
    private var loadTask: Task<Void, Never>?
    private var reloadScheduled = false

    init(drive: DriveService) { self.drive = drive }

    var visibleItems: [DriveItem] {
        search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var selectedItems: [DriveItem] { items.filter { selection.contains($0.id) } }

    /// Breadcrumb segments: (title, prefix) from the bucket root down to the current folder.
    var crumbs: [(String, String)] {
        var result: [(String, String)] = []
        var acc = ""
        for part in prefix.split(separator: "/") {
            acc += part + "/"
            result.append((String(part), acc))
        }
        return result
    }

    func go(to prefix: String) {
        self.prefix = prefix
        selection = []
        search = ""
        items = []
        reload()
    }

    func reload() {
        loadTask?.cancel()
        let prefix = self.prefix
        loading = true
        loadTask = Task {
            do {
                let items = try await drive.listFolder(prefix)
                guard !Task.isCancelled else { return }
                self.items = items
                self.error = nil
                self.selection = self.selection.filter { key in items.contains { $0.id == key } }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
            loaded = true
        }
    }

    /// Coalesces the reloads a batch of finished uploads would otherwise trigger one by one.
    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            reloadScheduled = false
            reload()
        }
    }
}

@MainActor @Observable
final class Transfer: Identifiable {
    enum Kind { case upload, download }
    enum State: Equatable {
        case queued, running, done, cancelled
        case failed(String)
    }

    let id = UUID()
    let kind: Kind
    let name: String
    let detail: String
    var done: Int64 = 0
    var total: Int64 = 0
    var state = State.queued
    let work: @Sendable (@escaping ProgressHandler) async throws -> Void
    let onFinish: @MainActor () -> Void
    var task: Task<Void, Never>?

    var isFinished: Bool {
        switch state {
        case .queued, .running: false
        default: true
        }
    }

    init(kind: Kind, name: String, detail: String,
         work: @escaping @Sendable (@escaping ProgressHandler) async throws -> Void,
         onFinish: @escaping @MainActor () -> Void = {}) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.work = work
        self.onFinish = onFinish
    }
}

struct JobStatus {
    var running = false
    var progress: BackupProgress?
    var rerun = false
    var task: Task<Void, Never>?
}
