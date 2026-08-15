import SwiftUI

@main
struct RouterApp: App {
    @State private var store = ProfileStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Label(store.current, systemImage: "person.crop.circle.badge.checkmark")
                .labelStyle(.titleAndIcon)
                .task {
                    // The CLI overwrites ~/.router/current in place, so a
                    // file watch on the directory misses it. A slow poll is
                    // enough for a menu bar label. Every fifth tick also
                    // heals refresh races (a running "main" session can
                    // rewrite the keychain over an active profile).
                    var tick = 0
                    while !Task.isCancelled {
                        store.refresh()
                        if tick % 5 == 0 { await store.heal() }
                        tick += 1
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
        }

        Window("Add Account", id: "add") {
            AddAccountView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
