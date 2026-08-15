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
                    // enough for a menu bar label.
                    while !Task.isCancelled {
                        store.refresh()
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
        }
    }
}
