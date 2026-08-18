import SwiftUI

struct PanelView: View {
    let store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.profiles) { profile in
                AccountRow(
                    profile: profile,
                    isCurrent: store.current == profile.name,
                    usage: store.usage[profile.name]?.summary
                ) {
                    Task { await store.select(profile.name) }
                }
            }
            Divider()
                .padding(.vertical, 6)
            HStack {
                Button("Add Account") {
                    openWindow(id: "add")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: 380)
        .task { await store.fetchUsage() }
    }
}
