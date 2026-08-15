import AppKit

final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = ProfileStore()
    private let menu = NSMenu()
    private var poll: Timer?
    private var shownName = ""

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "person.crop.circle.badge.checkmark",
                accessibilityDescription: "Claude account")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.menuBarFont(ofSize: 12)
        }
        refreshTitle()
        // The CLI overwrites ~/.router/current in place, so a directory
        // watch misses it. A slow poll is enough for a menu bar label.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    private func refreshTitle() {
        let name = store.current
        guard name != shownName else { return }
        shownName = name
        item.button?.title = " " + name
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = store.current
        for profile in store.profiles() {
            var title = profile.name
            if let email = profile.email { title += "  ·  \(email)" }
            if let plan = profile.plan { title += " (\(plan))" }
            let entry = NSMenuItem(title: title, action: #selector(switchProfile(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = profile.name
            entry.state = profile.name == current ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Applies to new sessions only", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Account…", action: #selector(addAccount), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
        let quit = NSMenuItem(title: "Quit Router", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func switchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        store.select(name)
        refreshTitle()
    }

    @objc private func addAccount() {
        // A .command file in Terminal avoids the AppleScript automation prompt.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", NSHomeDirectory() + "/.router/add.command"]
        try? process.run()
    }
}
