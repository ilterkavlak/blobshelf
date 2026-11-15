import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var addingBucket: Bool

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Buckets") {
                ForEach(model.config.buckets) { bucket in
                    Label {
                        Text(bucket.name)
                    } icon: {
                        Image(systemName: model.sessions[bucket.id] == nil ? "exclamationmark.triangle" : "externaldrive")
                    }
                    .tag(SidebarItem.bucket(bucket.id))
                    .contextMenu {
                        Button("Remove from Blobshelf") { model.removeBucket(bucket.id) }
                    }
                }
            }
            Section("Sync") {
                Label("Backups", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.backups)
                Label("Transfers", systemImage: "arrow.up.arrow.down")
                    .badge(model.activeTransferCount)
                    .tag(SidebarItem.transfers)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                addingBucket = true
            } label: {
                Label("Add Bucket", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}
