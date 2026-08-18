import AppKit
import Observation

struct Profile: Identifiable, Equatable {
    let name: String
    let email: String?

    var id: String { name }
}

// One rate limit as the usage endpoint reports it: a percentage of the
// window consumed, and when that window resets.
struct UsageLimit: Equatable {
    let label: String
    let pct: Int
    let reset: Double?

    var text: String {
        guard let reset else { return "\(label) \(pct)%" }
        return "\(label) \(pct)% (\(Self.until(reset)))"
    }

    private static func until(_ epoch: Double) -> String {
        let secs = max(0, Int(epoch - Date().timeIntervalSince1970))
        if secs >= 86400 { return "\(secs / 86400)d" }
        if secs >= 3600 {
            let h = secs / 3600
            let m = (secs % 3600) / 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        if secs >= 60 { return "\(secs / 60)m" }
        return "<1m"
    }
}

struct Usage: Equatable {
    let five: UsageLimit?
    let week: UsageLimit?
    let scoped: [UsageLimit]

    var isEmpty: Bool { five == nil && week == nil && scoped.isEmpty }

    // Every limit the endpoint reported, for the account row.
    var summary: String {
        ([five, week].compactMap { $0 } + scoped).map(\.text).joined(separator: " · ")
    }

    // The menu bar has room for one number. The 5-hour window is the one
    // that stops the next request; the weekly only stands in when the
    // endpoint withheld the session limit.
    var headline: UsageLimit? { five ?? week }
}

// Reads router state from disk for display. Switching, healing, and the
// sign-in flow go through the CLI, which owns the keychain-swap logic.
@MainActor
@Observable
final class ProfileStore {
    private(set) var current = "main"
    // What the menu bar shows: the account email's local part when known.
    private(set) var currentLabel = "main"
    // Limits per profile name, refreshed from `router usage --json`.
    private(set) var usage: [String: Usage] = [:]
    // Observed so the menu picks up an account added while it is open.
    private(set) var profiles: [Profile] = []

    // The menu bar item: account, and how much of its window is spent.
    var menuBarTitle: String {
        guard let headline = usage[current]?.headline else { return currentLabel }
        return "\(currentLabel) \(headline.pct)%"
    }

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
        let rows = readProfiles()
        if rows != profiles { profiles = rows }
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
        var next: [String: Usage] = [:]
        for (name, limits) in json {
            let scoped = limits["scoped"] as? [String: Any] ?? [:]
            let row = Usage(
                five: Self.limit("5h", limits["five"]),
                week: Self.limit("7d", limits["week"]),
                scoped: scoped.keys.sorted().compactMap { Self.limit($0, scoped[$0]) })
            if !row.isEmpty { next[name] = row }
        }
        if next != usage { usage = next }
    }

    private static func limit(_ label: String, _ raw: Any?) -> UsageLimit? {
        guard let limit = raw as? [String: Any], let pct = limit["pct"] as? Double else { return nil }
        return UsageLimit(label: label, pct: Int(pct), reset: limit["reset"] as? Double)
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
        refresh()
        return (true, "Added \"\(name)\"" + (email.map { " (\($0))" } ?? ""))
    }

    // Fresh from disk on every poll tick; the files are tiny.
    private func readProfiles() -> [Profile] {
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
