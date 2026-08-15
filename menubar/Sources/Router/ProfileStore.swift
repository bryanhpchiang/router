import AppKit
import Observation

struct Profile: Identifiable, Equatable {
    let name: String
    let email: String?
    let plan: String?
    let isToken: Bool

    var id: String { name }
}

// Reads router state from disk for display. Switching, healing, and the
// sign-in flow go through the CLI, which owns the keychain-swap logic.
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

    func select(_ name: String) async {
        _ = await Self.runCLI(["use", name])
        refresh()
    }

    func heal() async {
        _ = await Self.runCLI(["heal", "--quiet"])
    }

    // Starts a sign-in: the CLI mints the PKCE URL, the browser opens it.
    func beginSignIn() async {
        guard let data = await Self.runCLI(["auth", "start"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["url"] as? String,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
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

    private func mainEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: claudeConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }
}
