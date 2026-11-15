import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.transfers.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down",
                                       description: Text("Uploads and downloads appear here."))
            } else {
                List(model.transfers.reversed()) { transfer in
                    TransferRow(transfer: transfer)
                }
            }
        }
        .navigationTitle("Transfers")
        .toolbar {
            Button("Clear Finished", systemImage: "xmark.circle") { model.clearFinishedTransfers() }
                .disabled(!model.transfers.contains { $0.isFinished })
        }
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).lineLimit(1)
                Text(transfer.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                switch transfer.state {
                case .queued:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: Double(transfer.done), total: Double(max(transfer.total, 1)))
                    Text(progressText).font(.caption).foregroundStyle(.secondary)
                case .done:
                    Label("Done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if !transfer.isFinished {
                Button("Cancel", systemImage: "xmark.circle.fill") { model.cancel(transfer) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var progressText: String {
        let done = ByteCountFormatter.string(fromByteCount: transfer.done, countStyle: .file)
        guard transfer.total > 0 else { return done }
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))"
    }
}
