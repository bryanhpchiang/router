import AppKit
import Observation

struct Profile: Identifiable, Equatable {
    let name: String
    let email: String?
    let plan: String?
    let isToken: Bool

    var id: String { name }
}

// Reads router state straight from disk. The CLI owns writes that need
// validation (add/remove); a switch is one small file write, so the app
// does it in place for a snappy menu.
@MainActor
@Observable
final class ProfileStore {
    private(set) var current = "main"

    private let dir = NSHomeDirectory() + "/.router"
    private var currentFile: String { dir + "/current" }
    private var profilesFile: String { dir + "/profiles.json" }
    private var claudeConfig: String { NSHomeDirectory() + "/.claude.json" }

    init() {
        refresh()
    }

    func refresh() {
        let name = readCurrent()
        if name != current { current = name }
    }

    func select(_ name: String) {
        try? (name + "\n").write(toFile: currentFile, atomically: true, encoding: .utf8)
        refresh()
    }

    // Fresh from disk on every menu open; the files are tiny.
    func profiles() -> [Profile] {
        var rows = [Profile(name: "main", email: mainEmail(), plan: nil, isToken: false)]
        if let data = FileManager.default.contents(atPath: profilesFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = json["profiles"] as? [String: [String: Any]] {
            for name in stored.keys.sorted() {
                let entry = stored[name] ?? [:]
                rows.append(Profile(
                    name: name,
                    email: entry["email"] as? String,
                    plan: entry["plan"] as? String,
                    isToken: true))
            }
        }
        return rows
    }

    func addAccount() {
        // A .command file in Terminal avoids the AppleScript automation prompt.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", dir + "/add.command"]
        try? process.run()
    }

    private func readCurrent() -> String {
        guard let raw = try? String(contentsOfFile: currentFile, encoding: .utf8) else { return "main" }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "main" : name
    }

    private func mainEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: claudeConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }
}
