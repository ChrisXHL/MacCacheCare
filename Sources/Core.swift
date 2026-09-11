import Foundation
import Darwin
import CoreGraphics

func humanBytes(_ n: Int64) -> String {
    if n == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}

enum AutomationPolicy {
    static func pauseReason(pressure: Int, idle: TimeInterval, lowPower: Bool, hot: Bool) -> String? {
        if pressure != 1 { return "内存压力偏高或无法确认" }
        if !idle.isFinite || idle < 300 { return "电脑正在使用，等待闲置 5 分钟" }
        if lowPower { return "低电量模式已开启" }
        if hot { return "电脑温度需要恢复正常" }
        return nil
    }
}
func automaticPauseReason() -> String? {
    var pressure: Int32 = 0; var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 else { return "无法读取内存压力" }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!)
    return AutomationPolicy.pauseReason(pressure: Int(pressure), idle: idle,
        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, hot: ProcessInfo.processInfo.thermalState != .nominal)
}
func trashFile(_ url: URL) throws -> URL {
    var output: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &output)
    guard let output else { throw CareError.message("已移入废纸篓，但系统未返回恢复路径；请在废纸篓中恢复。") }
    return output as URL
}

struct CommandResult { let code: Int32; let output: String; let error: String }
enum CareError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

// No shell expansion. Bounded commands never terminate anything except their own child.
func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> CommandResult {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("cachecare-command-" + UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: dir) }
    let out = dir.appendingPathComponent("out"), err = dir.appendingPathComponent("err")
    fm.createFile(atPath: out.path, contents: nil); fm.createFile(atPath: err.path, contents: nil)
    let oh = try FileHandle(forWritingTo: out), eh = try FileHandle(forWritingTo: err)
    defer { try? oh.close(); try? eh.close() }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, oh.fileDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, eh.fileDescriptor, STDERR_FILENO)
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let spawnResult = posix_spawn(&pid, executable, &actions, nil, &argv, &envp)
    guard spawnResult == 0 else { throw CareError.message("无法启动检查命令（\(spawnResult)），本轮跳过。") }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { break }
        if result < 0 && errno != EINTR { throw CareError.message("无法核对检查命令的退出状态。") }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            Darwin.kill(pid, SIGKILL) // Only the short-lived inspection child created above.
            let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while waitpid(pid, &status, WNOHANG) == 0 && ProcessInfo.processInfo.systemUptime < reapDeadline { Thread.sleep(forTimeInterval: 0.01) }
            throw CareError.message("\(URL(fileURLWithPath: executable).lastPathComponent) 检查超时，本轮跳过。")
        }
        Thread.sleep(forTimeInterval: 0.025)
    }
    let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    let od = try Data(contentsOf: out), ed = try Data(contentsOf: err)
    guard od.count < 16_000_000 && ed.count < 1_000_000 else { throw CareError.message("检查输出过大，本轮跳过。") }
    return CommandResult(code: exitCode, output: String(decoding: od, as: UTF8.self), error: String(decoding: ed, as: UTF8.self))
}

struct ProcessRow: Codable, Identifiable {
    var id: Int32 { pid }
    let pid: Int32; let parent: Int32; let rssKB: Int64; let cpu: Double; let elapsed: String; let path: String
    var ageSeconds: Int {
        let days = elapsed.split(separator: "-")
        let d = days.count == 2 ? (Int(days[0]) ?? 0) : 0
        let parts = String(days.last ?? "0").split(separator: ":").compactMap { Int($0) }
        return d * 86400 + parts.reversed().enumerated().reduce(0) { $0 + $1.element * [1,60,3600][$1.offset] }
    }
    var isAutomation: Bool { path.contains("/.agent-browser/browsers/") }
    var isBrowser: Bool { isAutomation && path.hasSuffix("/MacOS/Google Chrome for Testing") }
}

func processes() throws -> [ProcessRow] {
    var pids = [Int32](repeating: 0, count: 16384)
    let n = carePIDList(&pids, Int32(pids.count))
    guard n > 0 else { throw CareError.message("无法读取完整进程列表，暂停清理。") }
    var rows: [ProcessRow] = []
    for pid in pids.prefix(Int(n)) where pid > 0 {
        var parent: Int32 = 0; var rss: UInt64 = 0; var age: UInt64 = 0
        var path = [CChar](repeating: 0, count: 4096)
        guard carePIDRow(pid, &parent, &rss, &age, &path, Int32(path.count)) == 1 else { continue }
        let days = age / 86400, hours = (age % 86400) / 3600, minutes = (age % 3600) / 60, seconds = age % 60
        let elapsed = (days > 0 ? "\(days)-" : "") + String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        rows.append(ProcessRow(pid: pid, parent: parent, rssKB: Int64(rss), cpu: -1, elapsed: elapsed, path: String(cString: path)))
    }
    guard rows.count > 5 else { throw CareError.message("进程信息不完整，暂停清理。") }
    return rows
}

struct MachineSnapshot: Codable {
    var date = Date(); var pressure = 0; var physical: Int64 = 0; var compressed: Int64 = 0; var wired: Int64 = 0
    var swap: Int64 = 0; var diskFree: Int64 = 0; var rows: [ProcessRow] = []; var error: String?
    var browsers: [ProcessRow] { rows.filter(\.isBrowser).sorted { $0.ageSeconds > $1.ageSeconds } }
    var automationCount: Int { rows.filter(\.isAutomation).count }
    var oldBrowsers: Int { browsers.filter { $0.ageSeconds >= 172800 }.count }
    var pressureName: String { switch pressure { case 1: return "正常"; case 2: return "偏高"; case 4: return "很高"; default: return "待确认" } }
    static func read() -> MachineSnapshot {
        var s = MachineSnapshot()
        do {
            s.rows = try processes()
            var physical: UInt64 = 0, compressed: UInt64 = 0, wired: UInt64 = 0, swap: UInt64 = 0
            var pressure: Int32 = 0
            guard careMetrics(&physical, &compressed, &wired, &swap, &pressure) == 0 else { throw CareError.message("无法读取完整内存指标") }
            s.physical = Int64(physical); s.compressed = Int64(compressed); s.wired = Int64(wired); s.swap = Int64(swap); s.pressure = Int(pressure)
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            s.diskFree = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        } catch { s.error = error.localizedDescription }
        return s
    }
}

struct CacheRule: Identifiable, Codable {
    let id: String; let title: String; let relativePath: String; let owners: [String]
    func active(in rows: [ProcessRow]) -> Bool { rows.contains { row in owners.contains { row.path.localizedCaseInsensitiveContains($0) } } }
    static let defaults: [CacheRule] = [
        .init(id: "chrome", title: "Chrome 文件缓存", relativePath: "Library/Caches/Google/Chrome", owners: ["chrome", "chromium"]),
        .init(id: "edge", title: "Edge 文件缓存", relativePath: "Library/Caches/Microsoft Edge", owners: ["microsoft edge"]),
        .init(id: "figma", title: "Figma 文件缓存", relativePath: "Library/Caches/com.figma.Desktop", owners: ["figma"]),
        .init(id: "vscode", title: "VS Code 文件缓存", relativePath: "Library/Caches/com.microsoft.VSCode", owners: ["visual studio code", "code helper", "/code"]),
        .init(id: "pip", title: "pip 下载缓存", relativePath: "Library/Caches/pip", owners: ["python", "/pip", "/uv", "uvx"]),
        .init(id: "brew", title: "Homebrew 下载缓存", relativePath: "Library/Caches/Homebrew/downloads", owners: ["/brew", "ruby", "/curl", "/wget"]),
        .init(id: "npm", title: "npm 历史日志", relativePath: ".npm/_logs", owners: ["node", "/npm", "/npx", "/bun"])
    ]
}

struct Candidate: Codable, Identifiable {
    var id: String { path }; let ruleID: String; let path: String; let size: Int64
    let inode: UInt64; let device: Int32; let modified: Double; let accessed: Double
}
struct ScanRow: Identifiable, Codable {
    var id: String { rule.id }; let rule: CacheRule; var status: String; var count = 0; var bytes: Int64 = 0
}
struct ScanReport: Codable {
    var date = Date(); var rows: [ScanRow] = []; var candidates: [Candidate] = []; var error: String?
    var bytes: Int64 { candidates.reduce(0) { $0 + $1.size } }
}

struct JournalEntry: Codable, Identifiable {
    var id = UUID().uuidString; var date = Date(); let original: String; var trash: String = ""; let size: Int64
    var state = "pending"; var note = ""
}
struct CleanupResult { var moved = 0; var bytes: Int64 = 0; var skipped = 0; var message = "" }

final class CacheEngine {
    let home: URL
    let rules = CacheRule.defaults
    let fm = FileManager.default
    var journalURL: URL { home.appendingPathComponent("Library/Application Support/MacCacheCare/history.json") }
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home.standardizedFileURL }

    // Every component must be real, beneath the exact allowlist root. Hardlinks are rejected too.
    func candidate(_ url: URL, rule: CacheRule, now: Date = Date()) -> Candidate? {
        let path = url.standardizedFileURL.path
        let root = home.appendingPathComponent(rule.relativePath).standardizedFileURL.path
        guard rules.contains(where: { $0.id == rule.id && $0.relativePath == rule.relativePath }),
              path.hasPrefix(root + "/"), path == url.path,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
              st.st_uid == getuid(), st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { return nil }
        let cutoff = now.timeIntervalSince1970 - 30 * 86400
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let accessed = Double(st.st_atimespec.tv_sec) + Double(st.st_atimespec.tv_nsec) / 1e9
        guard modified < cutoff, accessed < cutoff, Double(st.st_birthtimespec.tv_sec) < cutoff else { return nil }
        // One oversized cache object must not monopolize a background operation.
        guard st.st_size > 0, st.st_size <= 256 * 1024 * 1024 else { return nil }
        return Candidate(ruleID: rule.id, path: path, size: st.st_size, inode: UInt64(st.st_ino), device: st.st_dev, modified: modified, accessed: accessed)
    }

    func scan(rows: [ProcessRow], now: Date = Date()) -> ScanReport {
        var result = ScanReport(); let deadline = Date().addingTimeInterval(8); var examined = 0
        for rule in rules {
            var row = ScanRow(rule: rule, status: "无过期文件")
            let root = home.appendingPathComponent(rule.relativePath)
            if rule.active(in: rows) { row.status = "程序运行中 · 已保护" }
            else if !fm.fileExists(atPath: root.path) { row.status = "目录不存在" }
            else if root.resolvingSymlinksInPath().path != root.path { row.status = "路径含链接 · 已跳过" }
            else if Date() >= deadline || examined >= 12000 { row.status = "扫描限额 · 下次再查" }
            else {
                var failed = false
                let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, _ in failed = true; return false })
                if e == nil { failed = true }
                while let url = e?.nextObject() as? URL {
                    examined += 1
                    if Date() >= deadline || examined >= 12000 { row.status = "部分扫描 · 已达限额"; break }
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { e?.skipDescendants(); continue }
                    if let c = candidate(url, rule: rule, now: now) { result.candidates.append(c); row.count += 1; row.bytes += c.size }
                }
                if failed { row.status = "无法完整读取 · 已跳过"; result.candidates.removeAll { $0.ruleID == rule.id }; row.count = 0; row.bytes = 0 }
                else if row.status == "无过期文件" && row.count > 0 { row.status = "可整理 · 30 天未使用" }
            }
            result.rows.append(row)
        }
        return result
    }

    func history() throws -> [JournalEntry] {
        if !fm.fileExists(atPath: journalURL.path) { return [] }
        return try JSONDecoder().decode([JournalEntry].self, from: Data(contentsOf: journalURL))
    }
    func save(_ entries: [JournalEntry]) throws {
        try fm.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard journalURL.deletingLastPathComponent().resolvingSymlinksInPath().path == journalURL.deletingLastPathComponent().path,
              !fm.fileExists(atPath: journalURL.path) || journalURL.resolvingSymlinksInPath().path == journalURL.path else { throw CareError.message("记录目录异常，停止整理。") }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(entries).write(to: journalURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    // Exit 1 with no output means no open files; warnings, partial output, and timeouts fail closed.
    func ensureClosed(_ paths: [String]) throws {
        let r = try command("/usr/sbin/lsof", ["-nP", "-t", "--"] + paths, timeout: 5)
        guard r.code == 1, r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              r.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CareError.message("文件正被占用，或占用检查不完整；本批次已跳过。")
        }
    }

    func clean(_ report: ScanReport, automatic: Bool, now: Date = Date(),
               readProcesses: () throws -> [ProcessRow] = processes,
               automaticReadiness: () -> String? = automaticPauseReason,
               closedCheck: (([String]) throws -> Void)? = nil,
               move: ((URL) throws -> URL)? = nil) -> CleanupResult {
        var r = CleanupResult()
        do {
            var journal = try history()
            guard journal.count < 5000 else { throw CareError.message("恢复记录已达 5,000 条，暂停整理。") }
            let cap: Int64 = automatic ? 256 * 1024 * 1024 : 1024 * 1024 * 1024
            let deadline = Date().addingTimeInterval(20)
            for rule in rules {
                let items = report.candidates.filter { $0.ruleID == rule.id }.sorted { $0.path < $1.path }
                if items.isEmpty { continue }
                if rule.active(in: try readProcesses()) { r.skipped += items.count; continue }
                for item in items {
                    if automatic, let reason = automaticReadiness() { r.message = "自动整理已暂停：" + reason; return r }
                    if r.moved >= 80 || journal.count >= 5000 || Date() >= deadline || r.bytes + item.size > cap { r.message = "已到单次整理限额，其余留待下次。"; return r }
                    // Recheck owner, file identity, timestamps and open handles immediately before each move.
                    if rule.active(in: try readProcesses()) { r.skipped += 1; continue }
                    let url = URL(fileURLWithPath: item.path)
                    guard let fresh = candidate(url, rule: rule, now: now),
                          fresh.inode == item.inode, fresh.device == item.device,
                          fresh.modified == item.modified, fresh.accessed == item.accessed, fresh.size == item.size else { r.skipped += 1; continue }
                    do { try (closedCheck ?? ensureClosed)([item.path]) } catch { r.skipped += 1; r.message = error.localizedDescription; continue }
                    if rule.active(in: try readProcesses()) { r.skipped += 1; continue }
                    guard let last = candidate(url, rule: rule, now: now), last.inode == item.inode, last.device == item.device,
                          last.modified == item.modified, last.accessed == item.accessed, last.size == item.size else { r.skipped += 1; continue }
                    if automatic, let reason = automaticReadiness() { r.message = "自动整理已暂停：" + reason; return r }
                    var entry = JournalEntry(original: item.path, size: item.size)
                    journal.append(entry); try save(journal) // Cannot mutate files without a durable recovery record.
                    do {
                        let destination: URL
                        if let move { destination = try move(url) }
                        else { destination = try trashFile(url) }
                        entry.trash = destination.path; entry.state = "trashed"
                        r.moved += 1; r.bytes += item.size
                    } catch { entry.state = "needsReview"; entry.note = error.localizedDescription; r.skipped += 1 }
                    journal[journal.count - 1] = entry; try save(journal)
                }
            }
        } catch { r.message = error.localizedDescription }
        if r.message.isEmpty { r.message = "已整理 \(r.moved) 个文件（\(humanBytes(r.bytes))），跳过 \(r.skipped) 个。" }
        return r
    }

    func restoreLast(readProcesses: () throws -> [ProcessRow] = processes) throws -> String {
        var journal = try history()
        guard let i = journal.lastIndex(where: { $0.state == "trashed" }) else { return "没有可恢复的记录。" }
        let entry = journal[i]
        let src = URL(fileURLWithPath: entry.trash), dest = URL(fileURLWithPath: entry.original)
        guard let rule = rules.first(where: { entry.original.hasPrefix(home.appendingPathComponent($0.relativePath).path + "/") }),
              !rule.active(in: try readProcesses()) else { throw CareError.message("相关程序正在运行，暂不恢复。") }
        guard src.path.hasPrefix(home.appendingPathComponent(".Trash").path + "/"), src.resolvingSymlinksInPath().path == src.path,
              dest.path == dest.standardizedFileURL.path, dest.resolvingSymlinksInPath().path == dest.path else { throw CareError.message("恢复路径不符合保护规则。") }
        guard !fm.fileExists(atPath: dest.path) else { throw CareError.message("原位置已有文件，已保留新文件；可在废纸篓中手动取回。") }
        guard fm.fileExists(atPath: src.path) else { throw CareError.message("文件已不在废纸篓中，无法恢复。") }
        var st = stat()
        guard lstat(src.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1,
              st.st_uid == getuid() else { throw CareError.message("恢复对象已变化，已暂停恢复。") }
        guard fm.fileExists(atPath: dest.deletingLastPathComponent().path) else { throw CareError.message("原目录已不存在，已暂停恢复。") }
        try fm.moveItem(at: src, to: dest)
        journal[i].state = "restored"; try save(journal)
        return "已恢复：\(dest.lastPathComponent)"
    }
}
