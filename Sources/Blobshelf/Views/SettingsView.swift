import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Open at login", isOn: Binding(get: { status == .enabled }, set: { setLaunchAtLogin($0) }))
            Text("Blobshelf keeps running in the menu bar when its window is closed, so backups continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if status == .requiresApproval {
                HStack {
                    Text("macOS needs your approval in Login Items.").font(.caption)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { status = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
