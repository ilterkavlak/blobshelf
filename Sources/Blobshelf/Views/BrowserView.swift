import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import BlobshelfCore

enum BrowserLayout: String {
    case list, grid
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let session: BucketSession

    @AppStorage("browserLayout") private var layout = BrowserLayout.list
    @State private var newFolderName = ""
    @State private var creatingFolder = false
    @State private var renaming: DriveItem?
    @State private var renameText = ""
    @State private var deleting: [DriveItem] = []
    @State private var previewURL: URL?
    @State private var opening = false
    @State private var dropTargeted = false

    private var browser: BrowserModel { session.browser }

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            if let info = session.info, info.isReadOnly {
                Banner(text: "This bucket is read-only" + (info.readOnlyReason.map { ": \($0)" } ?? ".") + " You can still download and delete.",
                       systemImage: "lock.fill", tint: .orange)
            }
            if let error = session.infoError {
                Banner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
            }
            if let error = browser.error, !browser.items.isEmpty {
                Banner(text: "Showing the last loaded contents. Refresh failed: \(error)", systemImage: "exclamationmark.icloud", tint: .red)
            }
            breadcrumb
            Group {
                switch layout {
                case .list: table
                case .grid: grid
                }
            }
            .onDeleteCommand { if !browser.selectedItems.isEmpty { deleting = browser.selectedItems } }
            .onKeyPress(.space) { quickLookSelection() }
            .dropDestination(for: URL.self) { urls, _ in
                model.upload(urls, to: session, prefix: browser.prefix)
                return session.canWrite
            } isTargeted: { dropTargeted = $0 }
            .overlay { overlay }
            footer
        }
        .navigationTitle(session.config.name)
        .navigationSubtitle(browser.prefix.isEmpty ? "" : "/" + browser.prefix)
        .searchable(text: $browser.search, placement: .toolbar, prompt: "Search this folder")
        .toolbar { toolbar }
        .task {
            if session.info == nil { await session.refreshInfo() }
            if !browser.loaded { browser.reload() }
        }
        .quickLookPreview($previewURL)
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("Deleted files cannot be recovered. Folders are deleted with everything in them.")
        }
    }

    // MARK: Pieces

    private var breadcrumb: some View {
        HStack(spacing: 2) {
            crumb(session.config.name, systemImage: "externaldrive.fill", prefix: "")
            ForEach(browser.crumbs, id: \.1) { title, prefix in
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                crumb(title, systemImage: "folder.fill", prefix: prefix)
            }
            Spacer()
            if browser.loading || opening { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func crumb(_ title: String, systemImage: String, prefix: String) -> some View {
        Button { browser.go(to: prefix) } label: {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(prefix == browser.prefix ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(prefix == browser.prefix ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var table: some View {
        @Bindable var browser = browser
        return Table(browser.visibleItems, selection: $browser.selection) {
            TableColumn("Name") { item in
                Label {
                    Text(item.name)
                } icon: {
                    Image(nsImage: FileIcon.image(for: item)).resizable().frame(width: 18, height: 18)
                }
            }
            TableColumn("Size") { item in
                Text(item.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 140)
            TableColumn("Modified") { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 240)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: DriveItem.ID.self) { keys in
            contextMenu(items(keys))
        } primaryAction: { keys in
            if let item = items(keys).first { open(item) }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 8)], spacing: 8) {
                ForEach(browser.visibleItems) { item in
                    GridCell(item: item, selected: browser.selection.contains(item.id))
                        .onTapGesture(count: 2) { open(item) }
                        .onTapGesture { select(item) }
                        .contextMenu {
                            let targets = browser.selection.contains(item.id) ? browser.selectedItems : [item]
                            contextMenu(targets)
                        }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { browser.selection = [] }
        .contextMenu { contextMenu([]) }
        .focusable()
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var overlay: some View {
        if dropTargeted && session.canWrite {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(Label("Drop to upload", systemImage: "icloud.and.arrow.up").font(.title3.weight(.medium)))
                .padding(8)
        } else if let error = browser.error, browser.items.isEmpty {
            ContentUnavailableView {
                Label("Could not load this folder", systemImage: "exclamationmark.icloud")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { browser.reload() }
            }
        } else if browser.loaded && !browser.loading && browser.visibleItems.isEmpty {
            if browser.search.isEmpty {
                ContentUnavailableView {
                    Label("This folder is empty", systemImage: "folder")
                } description: {
                    Text(session.canWrite ? "Drag files here or use Upload." : "")
                } actions: {
                    if session.canWrite { Button("Upload…") { chooseUploads() } }
                }
            } else {
                ContentUnavailableView.search(text: browser.search)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let files = browser.items.filter { !$0.isFolder }
            Text("\(browser.items.count - files.count) folders · \(files.count) files · "
                + ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + ($1.size ?? 0) }, countStyle: .file))
            if !browser.selection.isEmpty { Text("\(browser.selection.count) selected") }
            Spacer()
            if let info = session.info {
                Label(info.isPublic ? "Public" : "Private", systemImage: info.isPublic ? "globe" : "lock")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { browser.go(to: DriveService.parent(of: browser.prefix)) }
                .disabled(browser.prefix.isEmpty)
        }
        ToolbarItemGroup {
            Picker("View", selection: $layout) {
                Label("List", systemImage: "list.bullet").tag(BrowserLayout.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            Button("New Folder", systemImage: "folder.badge.plus") { startNewFolder() }
                .disabled(!session.canWrite)
            Button("Upload", systemImage: "icloud.and.arrow.up") { chooseUploads() }
                .disabled(!session.canWrite)
            Button("Download", systemImage: "icloud.and.arrow.down") { chooseDownloadTarget(browser.selectedItems) }
                .disabled(browser.selection.isEmpty)
            Button("Delete", systemImage: "trash") { deleting = browser.selectedItems }
                .disabled(browser.selection.isEmpty)
            Button("Refresh", systemImage: "arrow.clockwise") {
                browser.reload()
                Task { await session.refreshInfo() }
            }
            .keyboardShortcut("r")
        }
    }

    @ViewBuilder
    private func contextMenu(_ items: [DriveItem]) -> some View {
        if items.isEmpty {
            Button("Upload…") { chooseUploads() }.disabled(!session.canWrite)
            Button("New Folder…") { startNewFolder() }.disabled(!session.canWrite)
        } else {
            if items.count == 1, let item = items.first {
                Button("Open") { open(item) }
                if !item.isFolder {
                    Button("Quick Look") { quickLook(item) }
                }
            }
            Button("Download…") { chooseDownloadTarget(items) }
            if items.count == 1, let item = items.first {
                Button("Rename…") {
                    renameText = item.name
                    renaming = item
                }
                .disabled(!session.canWrite)
                if session.info?.isPublic == true && !item.isFolder {
                    Button("Copy Public Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.drive.publicURL(for: item.key).absoluteString, forType: .string)
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = items }
        }
    }

    // MARK: Actions

    private var deleteTitle: String {
        deleting.count == 1 ? "Delete “\(deleting[0].name)”?" : "Delete \(deleting.count) items?"
    }

    private func items(_ keys: Set<DriveItem.ID>) -> [DriveItem] {
        browser.items.filter { keys.contains($0.id) }
    }

    private func select(_ item: DriveItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if browser.selection.contains(item.id) {
                browser.selection.remove(item.id)
            } else {
                browser.selection.insert(item.id)
            }
        } else {
            browser.selection = [item.id]
        }
    }

    private func quickLookSelection() -> KeyPress.Result {
        guard let item = browser.selectedItems.first, !item.isFolder else { return .ignored }
        quickLook(item)
        return .handled
    }

    /// Opens folders in place and documents in their default app. Anything that could run code
    /// (apps, scripts, installers, unknown types) is only ever shown in Quick Look.
    private func open(_ item: DriveItem) {
        if item.isFolder {
            browser.go(to: item.key)
        } else if FileIcon.isSafeToOpen(item) {
            run { if let url = try await model.previewFile(item, in: session) { NSWorkspace.shared.open(url) } }
        } else {
            quickLook(item)
        }
    }

    private func quickLook(_ item: DriveItem) {
        run { previewURL = try await model.previewFile(item, in: session) }
    }

    private func startNewFolder() {
        newFolderName = ""
        creatingFolder = true
    }

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        model.upload(panel.urls, to: session, prefix: browser.prefix, releasing: panel.urls)
    }

    private func chooseDownloadTarget(_ items: [DriveItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        model.download(items, from: session, to: dir)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        let prefix = browser.prefix
        run(reload: true) { try await session.drive.createFolder(named: name, in: prefix) }
    }

    private func rename() {
        guard let item = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard name != item.name else { return }
        run(reload: true) { try await session.drive.rename(item, to: name) }
    }

    private func delete() {
        let items = deleting
        deleting = []
        run(reload: true) { try await session.drive.delete(items) }
    }

    private func run(reload: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        opening = true
        Task {
            do {
                try await action()
            } catch {
                model.alert = error.localizedDescription
            }
            opening = false
            if reload { browser.reload() }
        }
    }
}

private struct GridCell: View {
    let item: DriveItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: FileIcon.image(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(item.isFolder ? " " : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: Color {
        selected ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.06) : .clear
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.12))
    }
}

@MainActor
enum FileIcon {
    static let folder = NSWorkspace.shared.icon(for: .folder)

    static func image(for item: DriveItem) -> NSImage {
        item.isFolder ? folder : NSWorkspace.shared.icon(for: utType(item))
    }

    static func isSafeToOpen(_ item: DriveItem) -> Bool {
        let type = utType(item)
        return type.conforms(to: .content) && !type.conforms(to: .executable) && !type.conforms(to: .script)
    }

    private static func utType(_ item: DriveItem) -> UTType {
        UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
    }
}
