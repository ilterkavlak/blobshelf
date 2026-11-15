import SwiftUI

struct AddBucketSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an Upstash Blob Bucket").font(.title2.bold())
            Text("Paste the bucket token from the Upstash console. It is stored in your Keychain.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("Optional, e.g. Photos"))
                SecureField("Token", text: $token)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func add() {
        working = true
        error = nil
        Task {
            do {
                try await model.addBucket(name: name.trimmingCharacters(in: .whitespaces), token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
