import SwiftUI

struct AddAccountView: View {
    let store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var succeeded = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Claude Account")
                .font(.headline)
            Text("The sign-in page is open in your browser. Use a private window for a different account. Approve, copy the code, and paste it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Paste the code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button(busy ? "Adding" : "Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || code.isEmpty || succeeded)
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(succeeded ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if succeeded {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Open the sign-in page again") {
                    Task { await store.restartSignIn() }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            code = ""
            succeeded = false
            message = nil
            await store.beginSignIn()
        }
    }

    private func submit() {
        guard !busy, !code.isEmpty else { return }
        busy = true
        message = nil
        Task {
            let result = await store.redeem(code)
            succeeded = result.ok
            message = result.message
            busy = false
        }
    }
}
