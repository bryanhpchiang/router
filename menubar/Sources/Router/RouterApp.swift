import SwiftUI

@main
struct RouterApp: App {
    @State private var store = ProfileStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Label(store.currentLabel, systemImage: "person.crop.circle.badge.checkmark")
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
                        if tick % 30 == 0 { await store.fetchUsage() }
                        tick += 1
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
        }

        Window("Add Account", id: "add") {
            AddAccountView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // The app has no Dock icon, so a buried window is unfindable. Keep
        // it above the browser during the sign-in.
        .windowLevel(.floating)
    }
}
