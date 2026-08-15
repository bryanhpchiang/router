import AppKit
import Observation

struct Profile: Identifiable, Equatable {
    let name: String
    let email: String?

    var id: String { name }
}

// Reads router state from disk for display. Switching, healing, and the
// sign-in flow go through the CLI, which owns the keychain-swap logic.
@MainActor
@Observable
final class ProfileStore {
    private(set) var current = "main"
    // What the menu bar shows: the account email's local part when known.
    private(set) var currentLabel = "main"
    // Usage summary per profile name, e.g. "5h 4% · 7d 1%".
    private(set) var usage: [String: String] = [:]

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
        let label = labelFor(name)
        if label != currentLabel { currentLabel = label }
    }

    private func labelFor(_ name: String) -> String {
        let email = name == "main" ? mainEmail() : profileEmail(name)
        guard let email, let local = email.split(separator: "@").first else { return name }
        return String(local)
    }

    private func profileEmail(_ name: String) -> String? {
        guard let data = FileManager.default.contents(atPath: profilesFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = json["profiles"] as? [String: [String: Any]] else { return nil }
        return stored[name]?["email"] as? String
    }

    func select(_ name: String) async {
        _ = await Self.runCLI(["use", name])
        refresh()
    }

    func heal() async {
        _ = await Self.runCLI(["heal", "--quiet"])
    }

    func fetchUsage() async {
        guard let data = await Self.runCLI(["usage", "--json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return }
        var next: [String: String] = [:]
        for (name, limits) in json {
            var parts: [String] = []
            if let five = limits["five"] as? Double { parts.append("5h \(Int(five))%") }
            if let week = limits["week"] as? Double { parts.append("7d \(Int(week))%") }
            if !parts.isEmpty { next[name] = parts.joined(separator: " · ") }
        }
        if next != usage { usage = next }
    }

    // Starts a sign-in: the CLI mints the PKCE URL, the browser opens it.
    // A reopen of the window reuses the pending sign-in, so a code the user
    // already copied stays valid and the browser does not open again.
    func beginSignIn() async {
        await signIn(fresh: false)
    }

    func restartSignIn() async {
        await signIn(fresh: true)
    }

    private func signIn(fresh: Bool) async {
        var args = ["auth", "start"]
        if fresh { args.append("--fresh") }
        guard let data = await Self.runCLI(args),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["url"] as? String,
              let url = URL(string: raw) else { return }
        if fresh || (json["fresh"] as? Bool ?? true) {
            NSWorkspace.shared.open(url)
        }
    }

    func redeem(_ code: String) async -> (ok: Bool, message: String) {
        guard let data = await Self.runCLI(["auth", "redeem", code]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "The sign-in failed. Try again.")
        }
        if let error = json["error"] as? String {
            return (false, error)
        }
        guard let name = json["name"] as? String else {
            return (false, "The sign-in failed. Try again.")
        }
        let email = json["email"] as? String
        return (true, "Added \"\(name)\"" + (email.map { " (\($0))" } ?? ""))
    }

    // Fresh from disk on every menu open; the files are tiny.
    func profiles() -> [Profile] {
        var rows = [Profile(name: "main", email: mainEmail())]
        if let data = FileManager.default.contents(atPath: profilesFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = json["profiles"] as? [String: [String: Any]] {
            for name in stored.keys.sorted() {
                rows.append(Profile(name: name, email: stored[name]?["email"] as? String))
            }
        }
        return rows
    }

    nonisolated private static func runCLI(_ args: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.router/bin/router")
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                // Errors also arrive as JSON on stdout; hand back whatever came.
                continuation.resume(returning: out.fileHandleForReading.readDataToEndOfFile())
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    private func readCurrent() -> String {
        guard let raw = try? String(contentsOfFile: currentFile, encoding: .utf8) else { return "main" }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "main" : name
    }

    // While a profile is active, ~/.claude.json carries that profile's email
    // (router patches it so Claude Code's own UI shows the right account).
    // The real login's identity lives in the stash for that window.
    private func mainEmail() -> String? {
        for path in [dir + "/stash-account.json", claudeConfig] {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let account = path == claudeConfig ? json["oauthAccount"] as? [String: Any] : json
            if let email = account?["emailAddress"] as? String { return email }
        }
        return nil
    }
}
