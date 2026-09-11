import Foundation
import Darwin
import CryptoKit

enum ActivityError: LocalizedError {
    case busy
    var errorDescription: String? { "命令正在执行或计时锁不可用，继续保留" }
}

struct BrowserIntegration: Codable {
    let target: String
    let original: String
    let wrapperHash: String
    let originalHash: String
    let installed: Date
}

enum BrowserActivity {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacCacheCare/browser-activity") }
    static var manifest: URL { directory.appendingPathComponent("integration.json") }
    static func hash(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    static func validSession(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil
    }
    static func session(_ args: [String], env: [String: String]) -> String? {
        var name = env["AGENT_BROWSER_SESSION"] ?? "default"
        for (i, arg) in args.enumerated() {
            if arg == "--session", i + 1 < args.count { name = args[i + 1] }
            if arg.hasPrefix("--session=") { name = String(arg.dropFirst(10)) }
        }
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-browser").path
        if let socket = env["AGENT_BROWSER_SOCKET_DIR"], URL(fileURLWithPath: socket).standardizedFileURL.path != expected { return nil }
        return validSession(name) ? name : nil
    }
    static func read() throws -> BrowserIntegration { try JSONDecoder().decode(BrowserIntegration.self, from: Data(contentsOf: manifest)) }
    static func sessionDir(_ session: String) throws -> URL {
        guard validSession(session) else { throw NSError(domain: "BrowserActivity", code: 1) }
        let dir = directory.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard dir.resolvingSymlinksInPath().path == dir.path else { throw NSError(domain: "BrowserActivity", code: 2) }
        return dir
    }
    static func lock(_ dir: URL, exclusive: Bool) throws -> Int32 {
        let fd = Darwin.open(dir.appendingPathComponent("lease").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: "BrowserActivity", code: 3) }
        if flock(fd, exclusive ? (LOCK_EX | LOCK_NB) : LOCK_SH) != 0 { Darwin.close(fd); throw ActivityError.busy }
        return fd
    }
    static func touch(_ dir: URL) throws {
        let fd = Darwin.open(dir.appendingPathComponent("heartbeat").path, O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: "BrowserActivity", code: 5) }
        defer { Darwin.close(fd) }
        guard futimes(fd, nil) == 0 else { throw NSError(domain: "BrowserActivity", code: 6) }
    }
    static func lastActivity(_ name: String, integration: BrowserIntegration, baseline: Date) -> Date {
        let p = directory.appendingPathComponent(name).appendingPathComponent("heartbeat")
        let attrs = try? FileManager.default.attributesOfItem(atPath: p.path)
        return max(max(integration.installed, baseline), attrs?[.modificationDate] as? Date ?? integration.installed)
    }
}
