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
        Text("Running sessions follow in about 30s")
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

    private func title(for profile: Profile) -> String {
        var title = profile.name
        if let email = profile.email { title += "  ·  \(email)" }
        if let plan = profile.plan { title += " (\(plan))" }
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
