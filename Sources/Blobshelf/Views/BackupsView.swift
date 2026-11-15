import AppKit
import SwiftUI
import BlobshelfCore

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: BackupJob?

    var body: some View {
        Group {
            if model.config.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Backups", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Choose folders on this Mac to back up to a bucket automatically. New and changed files are uploaded when they change and on a schedule.")
                } actions: {
                    Button("Add Backup…") { addJob() }
                        .disabled(model.config.buckets.isEmpty)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.config.jobs) { job in
                            BackupRow(job: job, edit: { editing = job })
                                .padding(14)
                                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                        }
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle("Backups")
        .toolbar {
            ToolbarItemGroup {
                Button("Back Up All Now", systemImage: "arrow.clockwise.icloud") { model.backUpAllNow() }
                    .disabled(model.config.jobs.allSatisfy { !$0.enabled })
                Button("Add Backup", systemImage: "plus") { addJob() }
                    .disabled(model.config.buckets.isEmpty)
            }
        }
        .sheet(item: $editing) { job in
            BackupJobEditor(job: job, isNew: !model.config.jobs.contains { $0.id == job.id })
        }
    }

    private func addJob() {
        guard let bucket = model.config.buckets.first else { return }
        editing = BackupJob(localPath: "", bucketRef: bucket.id, remotePrefix: "")
    }
}

private struct BackupRow: View {
    @Environment(AppModel.self) private var model
    let job: BackupJob
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: FileIcon.folder)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).font(.headline)
                Text(job.localPath).font(.caption).foregroundStyle(.secondary)
                Text("→ \(model.bucketName(job.bucketRef)) / \(job.remotePrefix)")
                    .font(.caption).foregroundStyle(.secondary)
                BackupStatusLine(job: job, status: model.jobStatus[job.id])
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { job.enabled }, set: { model.setEnabled(job.id, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
            Menu {
                Button("Back Up Now") { model.trigger(job.id) }.disabled(!job.enabled)
                Button("Edit…", action: edit)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.localPath)])
                }
                Divider()
                Button("Remove Backup", role: .destructive) { model.removeJob(job.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }
}

/// One backup's state in a line or two; shared by the Backups list and the menu bar panel.
struct BackupStatusLine: View {
    let job: BackupJob
    let status: JobStatus?

    var body: some View {
        Group {
            if let status, status.running {
                if case let .uploading(done, total) = status.progress, total > 0 {
                    ProgressView(value: Double(done), total: Double(total)).controlSize(.small)
                }
                Text("Backing up — " + (status.progress.map(AppModel.describe) ?? ""))
                    .foregroundStyle(.secondary)
            } else if !job.enabled {
                Text("Paused").foregroundStyle(.secondary)
            } else if let error = job.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
            } else if let last = job.lastSuccess {
                Label("Backed up \(last.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Waiting for first backup").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

struct BackupJobEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var job: BackupJob
    let isNew: Bool
    @State private var excludesText = ""
    @State private var error: String?

    init(job: BackupJob, isNew: Bool) {
        _job = State(initialValue: job)
        self.isNew = isNew
        _excludesText = State(initialValue: job.excludes.joined(separator: "\n"))
    }

    private static let intervals = [15, 30, 60, 180, 360, 720, 1440]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Backup" : "Edit Backup").font(.title2.bold())
            Form {
                LabeledContent("Folder") {
                    HStack {
                        Text(job.localPath.isEmpty ? "None" : job.localPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Picker("Bucket", selection: $job.bucketRef) {
                    ForEach(model.config.buckets) { Text($0.name).tag($0.id) }
                }
                if model.sessions[job.bucketRef]?.info?.isPublic == true {
                    Label(BackupJobError.publicBucket.localizedDescription, systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("Destination", text: $job.remotePrefix, prompt: Text("Backups/…/"))
                Picker("Also run every", selection: $job.intervalMinutes) {
                    ForEach(Self.intervals, id: \.self) { minutes in
                        Text(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "hour" : "\(minutes / 60) hours").tag(minutes)
                    }
                }
                Toggle("Back up automatically", isOn: $job.enabled)
                LabeledContent("Exclude") {
                    TextEditor(text: $excludesText)
                        .font(.body.monospaced())
                        .frame(height: 80)
                }
            }
            Text("Files changed on this Mac are uploaded a few seconds after they change. Files deleted here are kept in the bucket. Exclude patterns are shell globs, one per line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.localPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task(id: job.bucketRef) { await model.sessions[job.bucketRef]?.refreshInfo() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The panel grants read-write access; keep only the read-only bookmark made from it.
        defer { url.stopAccessingSecurityScopedResource() }
        let previousDefault = job.localPath.isEmpty ? "" : BackupJob.defaultPrefix(localPath: job.localPath, id: job.id)
        do {
            job.bookmark = try BackupJob.makeBookmark(url)
        } catch {
            self.error = "Could not keep access to this folder: \(error.localizedDescription)"
            return
        }
        job.localPath = url.path
        if job.remotePrefix.isEmpty || job.remotePrefix == previousDefault {
            job.remotePrefix = BackupJob.defaultPrefix(localPath: url.path, id: job.id)
        }
    }

    private func save() {
        job.excludes = excludesText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try model.saveJob(job)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
