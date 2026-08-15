import Foundation

// Reads router state straight from disk. The CLI owns writes that need
// validation (add/remove); a switch is one small file write, so the app
// does it in place for a snappy menu.
struct Profile {
    let name: String
    let email: String?
    let plan: String?
    let isToken: Bool
}

final class ProfileStore {
    private let dir = NSHomeDirectory() + "/.router"
    private var currentFile: String { dir + "/current" }
    private var profilesFile: String { dir + "/profiles.json" }
    private var claudeConfig: String { NSHomeDirectory() + "/.claude.json" }

    var current: String {
        guard let raw = try? String(contentsOfFile: currentFile, encoding: .utf8) else { return "main" }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "main" : name
    }

    func select(_ name: String) {
        try? (name + "\n").write(toFile: currentFile, atomically: true, encoding: .utf8)
    }

    func profiles() -> [Profile] {
        var rows = [Profile(name: "main", email: mainEmail(), plan: nil, isToken: false)]
        if let data = FileManager.default.contents(atPath: profilesFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = json["profiles"] as? [String: [String: Any]] {
            for name in stored.keys.sorted() {
                let p = stored[name] ?? [:]
                rows.append(Profile(
                    name: name,
                    email: p["email"] as? String,
                    plan: p["plan"] as? String,
                    isToken: true))
            }
        }
        return rows
    }

    private func mainEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: claudeConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }
}
