import SwiftUI

struct MenuView: View {
    let store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.profiles()) { profile in
            Toggle(isOn: binding(for: profile.name)) {
                Text(title(for: profile))
            }
        }
        Divider()
        Button("Add Account…") {
            openWindow(id: "add")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("n")
        Button("Quit Router") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // Profiles are identified by the account, so the row is the email,
    // plus the account's usage when it is known.
    private func title(for profile: Profile) -> String {
        var title = profile.email ?? profile.name
        if let usage = store.usage[profile.name] { title += "   \(usage)" }
        return title
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding {
            store.current == name
        } set: { selected in
            if selected {
                Task { await store.select(name) }
            }
        }
    }
}
