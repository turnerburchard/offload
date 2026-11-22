import Foundation
import Updater

/// "Ask Claude": answer questions about Offload, and (with the user's OK) change Offload's own source,
/// verify the change independently, commit, and hand back a new build. No UI here so the self-test can
/// drive the whole flow with a fake `claude` script in a throwaway clone.

// MARK: - Environment

public enum AskEnvironment {
    /// GUI apps get a minimal PATH; Claude Code, git, swift and gh live elsewhere.
    public static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        e["PATH"] = (extra + (e["PATH"]?.split(separator: ":").map(String.init) ?? [])).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        e["GIT_TERMINAL_PROMPT"] = "0"
        return e
    }

    public static func findClaude() -> URL? {
        let fm = FileManager.default
        let (status, out) = run(URL(fileURLWithPath: "/usr/bin/env"), ["which", "claude"], cwd: nil)
        let found = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, !found.isEmpty, fm.isExecutableFile(atPath: found) { return URL(fileURLWithPath: found) }
        let home = fm.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// A usable checkout has Package.swift and .git.
    public static func isSourceCheckout(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) && fm.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Runs a tool, returns (exit status, stdout+stderr).
    @discardableResult
    public static func run(_ exe: URL, _ args: [String], cwd: URL?, stdin: String? = nil, onLine: ((String) -> Void)? = nil) -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = exe; p.arguments = args; p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = out; p.standardError = out
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)); try? inPipe.fileHandleForWriting.close() }
        var all = Data(), buf = Data()
        while case let d = out.fileHandleForReading.availableData, !d.isEmpty {
            all.append(d); buf.append(d)
            while let nl = buf.firstIndex(of: 10) {
                onLine?(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self))
                buf.removeSubrange(buf.startIndex...nl)
            }
        }
        if !buf.isEmpty { onLine?(String(decoding: buf, as: UTF8.self)) }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: all, as: UTF8.self))
    }
}

// MARK: - Claude Code, headless

public struct ClaudeCLI: Sendable {
    public enum Mode: Sendable { case ask, build }
    public struct Outcome: Sendable { public let sessionID: String?; public let text: String; public let isError: Bool }

    public let binary: URL
    public init(binary: URL) { self.binary = binary }

    static let askTools = ["Read", "Grep", "Glob"]
    static let buildTools = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"]
    static let buildAllowed = askTools + ["Edit", "Write", "Bash(./build.sh*)", "Bash(.build/*/offload-selftest*)", "Bash(git status*)", "Bash(git diff*)"]

    public static func arguments(mode: Mode, session: String?, systemPrompt: String) -> [String] {
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "dontAsk",
                 "--append-system-prompt", systemPrompt]
        switch mode {
        case .ask: a += ["--tools", askTools.joined(separator: ","), "--allowedTools", askTools.joined(separator: ",")]
        case .build: a += ["--tools", buildTools.joined(separator: ","), "--allowedTools", buildAllowed.joined(separator: ",")]
        }
        if let session { a += ["--resume", session] }
        return a
    }

    /// Prompt goes on stdin (no risk of it being parsed as an option). Events are reported as they stream.
    public func run(_ prompt: String, mode: Mode, session: String?, systemPrompt: String, cwd: URL,
                    onStep: @escaping (String) -> Void, onLog: @escaping (String) -> Void) -> Outcome {
        var sessionID = session, texts: [String] = [], result: String?, isError = false
        let (status, raw) = AskEnvironment.run(binary, Self.arguments(mode: mode, session: session, systemPrompt: systemPrompt),
                                               cwd: cwd, stdin: prompt) { line in
            onLog(line)
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
            if let s = obj["session_id"] as? String { sessionID = s }
            switch obj["type"] as? String {
            case "assistant":
                for c in ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? [] {
                    if c["type"] as? String == "text", let t = c["text"] as? String { texts.append(t) }
                    if c["type"] as? String == "tool_use", let name = c["name"] as? String {
                        onStep(Self.friendlyStep(tool: name, input: c["input"] as? [String: Any] ?? [:]))
                    }
                }
            case "result":
                result = obj["result"] as? String
                isError = (obj["is_error"] as? Bool) ?? false || (obj["subtype"] as? String).map { $0 != "success" } ?? false
            default: break
            }
        }
        let text = result ?? texts.last ?? ""
        if status != 0 && text.isEmpty { onLog(raw) }
        return Outcome(sessionID: sessionID, text: text, isError: isError || (status != 0 && text.isEmpty))
    }

    /// Tool events -> one plain line for the spinner.
    public static func friendlyStep(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read", "Grep", "Glob": return "Reading how Offload works…"
        case "Edit", "Write", "MultiEdit": return "Making the change…"
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            if cmd.contains("offload-selftest") { return "Testing…" }
            if cmd.contains("build.sh") { return "Putting the new version together…" }
            return "Checking the changes…"
        default: return "Working…"
        }
    }
}

// MARK: - Markers in Claude's replies

public enum Marker: String, Sendable { case build = "BUILD", needsOK = "NEEDS_OK", done = "DONE", failed = "FAILED" }

public struct ParsedReply: Sendable, Equatable {
    public let display: String
    public let marker: Marker?
    public let request: String?      // <<REQUEST: …>> short summary of what the user asked for
    public init(display: String, marker: Marker?, request: String?) { self.display = display; self.marker = marker; self.request = request }

    public static func parse(_ text: String) -> ParsedReply {
        var marker: Marker?, request: String?, kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<<REQUEST:"), t.hasSuffix(">>") {
                request = String(t.dropFirst(10).dropLast(2)).trimmingCharacters(in: .whitespaces); continue
            }
            if t.hasPrefix("<<"), t.hasSuffix(">>"), let m = Marker(rawValue: String(t.dropFirst(2).dropLast(2))) { marker = m; continue }
            kept.append(line)
        }
        var display = kept.joined(separator: "\n")
        for m in [Marker.build, .needsOK, .done, .failed] where display.contains("<<\(m.rawValue)>>") {   // marker written inline
            display = display.replacingOccurrences(of: "<<\(m.rawValue)>>", with: ""); marker = marker ?? m
        }
        return ParsedReply(display: display.trimmingCharacters(in: .whitespacesAndNewlines), marker: marker, request: request)
    }
}

// MARK: - The conversation + build pipeline

public final class AskClaude: @unchecked Sendable {
    public enum Result: Sendable, Equatable {
        case answer(String)
        case needsOK(String)                                     // waiting for the user's permission
        case built(version: String, summary: String, message: String)
        case failed(String)
        case refused(String)
        case confirmInstall(String)                              // built + tested, but touches safety code: ask before installing
    }

    public struct Config: @unchecked Sendable {
        public var repo: URL
        public var claude: ClaudeCLI
        public var buildCommand = ["./build.sh"]
        public var testCommand = [".build/release/offload-selftest"]
        public var remote = "origin"
        public var isRunInProgress: () -> Bool = { false }
        /// Self-test PASS counts per commit, outside the repo so Claude's edits can't touch it.
        public var passCountStore = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Offload/ask-pass-counts.json")
        public init(repo: URL, claude: ClaudeCLI) { self.repo = repo; self.claude = claude }
    }

    public var config: Config
    public var onStep: (String) -> Void = { _ in }
    public var onLog: (String) -> Void = { _ in }
    public var onMessage: (String) -> Void = { _ in }         // intermediate bubbles ("Great, I'll add that now.")
    public private(set) var sessionID: String?
    public private(set) var awaitingOK = false
    /// A built + tested change that touches safety code, waiting for "Install it anyway?".
    public private(set) var awaitingInstallOK = false
    /// The user pressed "Yes, go ahead" in the NEEDS_OK flow for the current build (reset per build).
    private var approvedRisky = false
    private var pendingInstall: (summary: String, message: String, version: String, commitMessage: String)?
    private var lastQuestion: String?
    private var pendingSummary: String?

    public init(_ config: Config) { self.config = config }

    static let askPrompt = """
    You are the in-app assistant for Offload, a Mac app that copies photos and videos off camera SD cards to an editing SSD and backup drives, then checks every file. The user is NOT technical.
    Answer in 1–2 short, friendly sentences. Never mention code, files, programming, or how the app is built.
    If Offload can already do what they ask, say how in plain words, naming the buttons or settings they should use.
    If it can't, reply with exactly: "Offload can't do that yet. Want me to add it?" and nothing more.
    If the user clearly says yes to adding something you offered, reply with one short sentence like "Great, I'll add that now.", then on its own line <<REQUEST: a 3–8 word summary of the feature>>, then on its own line <<BUILD>>.
    """

    static let buildPrompt = """
    The user approved the change you offered earlier in this conversation. Implement it in this repository now.
    Follow the existing style. Keep changes minimal. You MUST add or extend checks in Sources/offload-selftest/main.swift for the new behavior.
    Run ./build.sh and then .build/release/offload-selftest until it prints ALL PASSED.
    Do NOT run git commit, git push, or change the VERSION file — the app does that. Never touch .build/.
    If the change would alter copying, MD5 verification, the "safe to wipe" verdict, or the never-overwrite rules (Engine.swift and related safety logic), STOP before changing it: reply with exactly one plain-English sentence asking the user's permission and explaining the risk, then on its own line <<NEEDS_OK>>.
    If the user declines, reply with one short sentence and <<FAILED>> on its own line.
    On success, end with one plain-English sentence describing what's new for the user (no technical words), then <<DONE>> on its own line.
    If you can't do it, end with one plain sentence saying why (no technical words), then <<FAILED>> on its own line.
    """

    // MARK: Conversation

    /// Blocking. Call off the main thread.
    public func send(_ text: String) -> Result {
        if awaitingInstallOK { return .needsOK(Self.riskyQuestion) }
        if awaitingOK { return build(prompt: text, continuing: true) }
        onStep("Thinking…")
        let o = config.claude.run(text, mode: .ask, session: sessionID, systemPrompt: Self.askPrompt, cwd: config.repo, onStep: onStep, onLog: onLog)
        if let s = o.sessionID { sessionID = s }
        guard !o.isError else { return .failed("Sorry, I couldn't get an answer right now. Please try again.") }
        let r = ParsedReply.parse(o.text)
        guard r.marker == .build else { lastQuestion = text; return .answer(r.display) }
        pendingSummary = r.request ?? lastQuestion ?? text
        if !r.display.isEmpty { onMessage(r.display) }
        return build(prompt: "The user said: \"\(text)\". Go ahead and build it now.", continuing: false)
    }

    /// The explicit answer to a NEEDS_OK question (the UI's Yes/No buttons). Only this counts as permission
    /// to change safety code; a typed reply goes to Claude but doesn't set the flag.
    public func answerPermission(_ yes: Bool) -> Result {
        guard awaitingOK else { return .failed("There's nothing waiting for an answer.") }
        if yes { approvedRisky = true }
        return build(prompt: yes ? "Yes, go ahead." : "No, don't do that.", continuing: true)
    }

    func build(prompt: String, continuing: Bool) -> Result {
        if config.isRunInProgress() { return .refused("A copy is running. Ask me again when it's finished.") }
        if !continuing && !status().isEmpty { return .failed("Offload's source folder has unsaved changes, so I can't change it right now.") }
        if !continuing { approvedRisky = false }
        awaitingOK = false
        onStep("Getting started…")
        let o = config.claude.run(prompt, mode: .build, session: sessionID, systemPrompt: Self.buildPrompt, cwd: config.repo, onStep: onStep, onLog: onLog)
        if let s = o.sessionID { sessionID = s }
        let r = ParsedReply.parse(o.text)
        switch r.marker {
        case .needsOK?:
            awaitingOK = true
            return .needsOK(r.display)
        case .done?:
            return verifyAndCommit(summary: pendingSummary ?? "a new feature", message: r.display)
        default:
            discard()
            return .failed(r.marker == .failed && !r.display.isEmpty ? r.display : "Sorry, I couldn't make that change. Nothing was changed.")
        }
    }

    static let riskyQuestion = "This change touches how Offload checks your photos are safe. Install it anyway?"

    /// The app's own check — Claude saying "done" isn't enough.
    func verifyAndCommit(summary: String, message: String, commitMessage: String? = nil, isUndo: Bool = false) -> Result {
        onStep("Double-checking everything still works…")
        guard !status().isEmpty else { discard(); return .failed("I didn't end up changing anything.") }
        guard let current = currentVersion(), let next = Self.bumpPatch(current) else { discard(); return .failed("Sorry, something went wrong. Nothing was changed.") }
        try? (next + "\n").write(to: config.repo.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        onStep("Putting the new version together…")
        guard shell(config.buildCommand).0 == 0 else { discard(); return .failed("The new version didn't come together, so I put everything back the way it was.") }
        onStep("Testing…")
        let (ts, tout) = shell(config.testCommand)
        guard ts == 0, tout.contains("ALL PASSED") else { discard(); return .failed("The change didn't pass Offload's safety checks, so I put everything back the way it was.") }
        // Tests can't quietly disappear: at least as many checks must pass as at the baseline commit.
        let passes = Self.passCount(tout)
        let head = git(["rev-parse", "HEAD"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseline = isUndo ? passCounts()[git(["rev-parse", "HEAD^"]).1.trimmingCharacters(in: .whitespacesAndNewlines)]
                              : passCounts()[head] ?? passCounts()["latest"]
        if let baseline, passes < baseline {
            discard(); return .failed("Some of Offload's safety checks went missing, so I put everything back the way it was.")
        }
        git(["add", "-A"])
        let pending = (summary: summary, message: message, version: next, commitMessage: commitMessage ?? "Ask Claude: \(summary)")
        lastPassCount = passes
        // Safety code changed, or existing checks removed/edited: the user decides, unless they already said yes.
        let risky = isUndo ? !undoRestoresParent() : Self.touchesSafety(names: stagedNames(), selftestDiff: stagedSelftestDiff())
        if risky && !approvedRisky {
            pendingInstall = pending; awaitingInstallOK = true
            return .confirmInstall(Self.riskyQuestion)
        }
        return commit(pending)
    }

    /// "Install it anyway?" — yes commits; no puts the change aside like any failure.
    public func confirmInstall(_ yes: Bool) -> Result {
        guard awaitingInstallOK, let p = pendingInstall else { return .failed("There's nothing waiting to be installed.") }
        awaitingInstallOK = false; pendingInstall = nil
        guard yes else { discard(); return .failed("Okay, I didn't install it. Offload stays as it was.") }
        return commit(p)
    }

    private var lastPassCount = 0

    private func commit(_ p: (summary: String, message: String, version: String, commitMessage: String)) -> Result {
        onStep("Saving…")
        git(["add", "-A"])
        guard git(["commit", "-q", "-m", p.commitMessage]).0 == 0, git(["tag", "v\(p.version)"]).0 == 0 else {
            discard(); return .failed("Sorry, I couldn't save the change. Nothing was changed.")
        }
        var counts = passCounts()
        counts[git(["rev-parse", "HEAD"]).1.trimmingCharacters(in: .whitespacesAndNewlines)] = lastPassCount
        counts["latest"] = lastPassCount
        savePassCounts(counts)
        pendingSummary = nil; approvedRisky = false
        return .built(version: p.version, summary: p.summary, message: p.message)
    }

    // MARK: Safety guard

    static let guardedFiles: Set<String> = ["Sources/OffloadCore/Engine.swift", "Sources/OffloadCore/Card.swift", "build.sh", "Package.swift"]
    static let guardedPrefixes = ["Sources/Updater/", ".github/"]
    static let selftestPath = "Sources/offload-selftest/main.swift"

    /// True if the change touches safety-critical files, or removes/edits an existing `check(` line in the self-test
    /// (adding new checks is fine). `names`: changed paths (renames as delete + add). `selftestDiff`: unified diff of the self-test.
    public static func touchesSafety(names: [String], selftestDiff: String) -> Bool {
        if names.contains(where: { n in guardedFiles.contains(n) || guardedPrefixes.contains { n.hasPrefix($0) } }) { return true }
        return selftestDiff.split(separator: "\n").contains { l in l.hasPrefix("-") && !l.hasPrefix("---") && l.contains("check(") }
    }

    public static func passCount(_ output: String) -> Int {
        output.split(separator: "\n").filter { $0.hasPrefix("PASS ") || $0 == "PASS" }.count
    }

    func stagedNames() -> [String] {
        git(["diff", "--cached", "--name-only", "--no-renames", "HEAD"]).1.split(separator: "\n").map(String.init)
    }
    func stagedSelftestDiff() -> String {
        git(["diff", "--cached", "--no-renames", "-U0", "HEAD", "--", Self.selftestPath]).1
    }
    /// An undo is only trusted if it puts every file (except VERSION) back exactly as it was before the change.
    func undoRestoresParent() -> Bool {
        let diff = git(["diff", "--cached", "--name-only", "HEAD^"]).1.split(separator: "\n").map(String.init)
        return diff.allSatisfy { $0 == "VERSION" }
    }

    func passCounts() -> [String: Int] {
        guard let d = try? Data(contentsOf: config.passCountStore) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: d)) ?? [:]
    }
    func savePassCounts(_ c: [String: Int]) {
        try? FileManager.default.createDirectory(at: config.passCountStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(c).write(to: config.passCountStore, options: .atomic)
    }

    /// Never loses anything: failed changes go to a git stash, not the bin.
    func discard() {
        awaitingOK = false; awaitingInstallOK = false; pendingInstall = nil; approvedRisky = false
        guard !status().isEmpty else { return }
        git(["stash", "push", "-u", "-m", "ask-claude-failed-\(Int(Date().timeIntervalSince1970))"])
    }

    // MARK: Undo

    /// Summary of the last commit if it was made by Ask Claude.
    public func lastChangeSummary() -> String? {
        let subject = git(["log", "-1", "--format=%s"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.hasPrefix("Ask Claude: ") ? String(subject.dropFirst("Ask Claude: ".count)) : nil
    }

    public func undoLastChange() -> Result {
        if awaitingOK || awaitingInstallOK { return .failed("Please answer the question above first.") }
        if config.isRunInProgress() { return .refused("A copy is running. Try again when it's finished.") }
        guard let summary = lastChangeSummary() else { return .failed("There's nothing to undo.") }
        guard status().isEmpty else { return .failed("Offload's source folder has unsaved changes, so I can't undo right now.") }
        guard let current = currentVersion() else { return .failed("Sorry, something went wrong.") }
        onStep("Undoing…")
        guard git(["revert", "--no-commit", "HEAD"]).0 == 0 else { git(["revert", "--abort"]); return .failed("Sorry, I couldn't undo that.") }
        try? (current + "\n").write(to: config.repo.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)   // bumped below
        let r = verifyAndCommit(summary: summary, message: "Undid “\(summary)”.", commitMessage: "Undo Ask Claude: \(summary)", isUndo: true)
        if case .failed = r { return .failed("Sorry, I couldn't undo that. Nothing was changed.") }
        return r
    }

    // MARK: Share

    /// Pushes the branch and the version tag so GitHub makes a release. Uses gh's login (no ssh needed).
    public func push(version: String) -> Bool {
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
        return git(["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
                    "push", config.remote, branch, "v\(version)"]).0 == 0
    }

    // MARK: Helpers

    public static func bumpPatch(_ v: String) -> String? {
        guard let s = SemVer(v) else { return nil }
        return "\(s.major).\(s.minor).\(s.patch + 1)"
    }

    func currentVersion() -> String? {
        (try? String(contentsOf: config.repo.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status() -> String { git(["status", "--porcelain"]).1.trimmingCharacters(in: .whitespacesAndNewlines) }

    @discardableResult
    func git(_ args: [String]) -> (Int32, String) {
        AskEnvironment.run(URL(fileURLWithPath: "/usr/bin/git"), args, cwd: config.repo) { self.onLog($0) }
    }

    func shell(_ cmd: [String]) -> (Int32, String) {
        AskEnvironment.run(URL(fileURLWithPath: "/usr/bin/env"), cmd, cwd: config.repo) { self.onLog($0) }
    }
}

// MARK: - Put a locally built app in place of the running one

public enum LocalInstall {
    /// Copies `built` next to `running` and swaps it in (old app restored on failure).
    /// Returns false (and does nothing) if they're the same bundle.
    @discardableResult
    public static func install(built: URL, replacing running: URL) throws -> Bool {
        if built.resolvingSymlinksInPath().standardizedFileURL == running.resolvingSymlinksInPath().standardizedFileURL { return false }
        let work = try Updater.workDir(near: running)
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = work.appendingPathComponent(running.lastPathComponent)
        let (s, out) = AskEnvironment.run(URL(fileURLWithPath: "/usr/bin/ditto"), [built.path, staged.path], cwd: nil)
        guard s == 0 else { throw UpdateError.swapFailed(out) }
        try Updater.install(staged, replacing: running)
        return true
    }
}
