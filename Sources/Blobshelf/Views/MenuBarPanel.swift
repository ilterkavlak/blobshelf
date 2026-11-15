import AppKit
import SwiftUI
import BlobshelfCore

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    backups
                    transfers
                }
                .padding(14)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.syncState.symbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: model.syncState == .syncing)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Blobshelf").font(.headline)
                Text(model.backupSummary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
    }

    private var tint: Color {
        switch model.syncState {
        case .syncing: .accentColor
        case .attention: .orange
        case .upToDate: .green
        case .paused, .notSetUp: .secondary
        }
    }

    @ViewBuilder
    private var backups: some View {
        if model.config.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Back up folders from this Mac to your buckets automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Set Up a Backup…") { show(.backups) }
            }
        } else {
            section("Backups")
            ForEach(model.config.jobs) { job in
                MenuBackupRow(job: job, status: model.jobStatus[job.id])
            }
        }
    }

    @ViewBuilder
    private var transfers: some View {
        let active = model.transfers.filter { !$0.isFinished }
        if !active.isEmpty {
            section("Transfers")
            ForEach(active.prefix(5)) { transfer in
                VStack(alignment: .leading, spacing: 3) {
                    Label(transfer.name, systemImage: transfer.kind == .upload ? "arrow.up" : "arrow.down")
                        .font(.callout).lineLimit(1)
                    if transfer.state == .running {
                        ProgressView(value: Double(transfer.done), total: Double(max(transfer.total, 1)))
                            .controlSize(.small)
                    } else {
                        Text("Waiting").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if active.count > 5 {
                Button("and \(active.count - 5) more…") { show(.transfers) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        let failed = model.failedTransfers
        if !failed.isEmpty {
            HStack {
                section("Failed")
                Spacer()
                Button("Clear") { model.clearFinishedTransfers() }.buttonStyle(.link).font(.caption)
            }
            ForEach(failed.prefix(3)) { transfer in
                VStack(alignment: .leading, spacing: 2) {
                    Label(transfer.name, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).lineLimit(1)
                    if case let .failed(message) = transfer.state {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if failed.count > 3 {
                Button("Show all in Transfers…") { show(.transfers) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Button("Back Up Now", systemImage: "arrow.clockwise") { model.backUpAllNow() }
                .disabled(!model.config.jobs.contains(where: \.enabled))
            Spacer()
            Button("Open", systemImage: "macwindow") { show(nil) }
            Menu {
                SettingsLink { Text("Settings…") }
                Divider()
                Button("Quit Blobshelf") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func show(_ item: SidebarItem?) {
        if let item { model.selection = item }
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MenuBackupRow: View {
    let job: BackupJob
    let status: JobStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: FileIcon.folder)
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).font(.callout.weight(.medium)).lineLimit(1)
                BackupStatusLine(job: job, status: status)
            }
        }
    }
}
