import AppKit
import SwiftUI

@main
struct BlobshelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Blobshelf", id: "main") {
            ContentView()
                .environment(model)
                .tint(.brand)
                .frame(minWidth: 860, minHeight: 520)
        }
        MenuBarExtra {
            MenuBarPanel().environment(model).tint(.brand)
        } label: {
            Image(systemName: model.syncState.symbol)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView().environment(model).tint(.brand)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` (an unbundled binary) show a Dock icon and take focus like the packaged app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.clearPreviews()
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var addingBucket = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(addingBucket: $addingBucket)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch model.selection {
            case .bucket where model.config.buckets.isEmpty, .backups where model.config.buckets.isEmpty, nil:
                WelcomeView(addBucket: { addingBucket = true })
            case let .bucket(id):
                if let session = model.sessions[id] {
                    // Keyed by the session, so a replaced token gets a freshly loaded browser.
                    BrowserView(session: session).id(ObjectIdentifier(session))
                } else {
                    ContentUnavailableView("Token missing", systemImage: "key.slash",
                                           description: Text("The token for this bucket is not in the Keychain. Use Add Bucket with its token to restore it."))
                }
            case .transfers:
                TransfersView()
            case .backups:
                BackupsView()
            }
        }
        .sheet(isPresented: $addingBucket) { AddBucketSheet() }
        .alert("Blobshelf", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

extension Color {
    static let brand = Color(red: 0.0, green: 0.68, blue: 0.5)
}

struct WelcomeView: View {
    let addBucket: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "icloud.and.arrow.up.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white, Color.brand.gradient)
                .padding(26)
                .background(Color.brand.gradient, in: RoundedRectangle(cornerRadius: 28))
                .shadow(color: .brand.opacity(0.35), radius: 16, y: 6)
            Text("Welcome to Blobshelf").font(.largeTitle.weight(.semibold))
            Text("Browse your Upstash Blob buckets like a drive, and back up folders from this Mac automatically.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(action: addBucket) {
                Label("Add Your First Bucket", systemImage: "plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
