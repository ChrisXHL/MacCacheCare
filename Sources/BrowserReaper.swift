import Foundation
import Darwin

struct BrowserSession: Identifiable, Codable {
    var id: String { name }
    let name: String; let daemon: Int32; let browser: Int32
    let pidInode: UInt64; let pidModified: Double
    var lastActivity: Date; var eligible: Bool; var reason: String
}
struct ReapRecord: Identifiable, Codable {
    var id = UUID().uuidString; var date = Date(); let session: String; let browser: Int32; let outcome: String
}
struct ReapReport { var sessions: [BrowserSession] = []; var error: String? }

func temporaryHeadlessProfile(_ args: String, temporaryDirectory: URL) -> URL? {
    let tokens = args.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.contains(where: { $0 == "--headless" || $0.hasPrefix("--headless=") }),
          let value = tokens.first(where: { $0.hasPrefix("--user-data-dir=") }) else { return nil }
    let profile = URL(fileURLWithPath: String(value.dropFirst(16))).standardizedFileURL
    guard profile.lastPathComponent.hasPrefix("agent-browser-chrome-"),
          profile.deletingLastPathComponent().resolvingSymlinksInPath().path == temporaryDirectory.resolvingSymlinksInPath().path,
          profile.resolvingSymlinksInPath().lastPathComponent == profile.lastPathComponent else { return nil }
    return profile
}

final class BrowserReaper {
    let fm = FileManager.default
    private let recordLock = NSLock()
    let idleSeconds: TimeInterval = 600
    // The launcher continues recording activity even while this UI is not running.
    var baseline = Date.distantPast
    var recordsURL: URL { BrowserActivity.directory.deletingLastPathComponent().appendingPathComponent("browser-recovery.json") }
    var socketDir: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent(".agent-browser") }
    func install(wrapper: URL) throws {
        if let current = try? BrowserActivity.read(), try BrowserActivity.hash(URL(fileURLWithPath: current.target)) == current.wrapperHash { return }
        let link = URL(fileURLWithPath: "/opt/homebrew/bin/agent-browser")
        let target = link.resolvingSymlinksInPath()
        guard target.path.hasPrefix(fm.homeDirectoryForCurrentUser.path + "/"), target.lastPathComponent == "agent-browser-darwin-arm64" else { throw CareError.message("无法识别本机 agent-browser 入口，未接入。") }
        let original = URL(fileURLWithPath: target.path + ".cachecare-original")
        if fm.fileExists(atPath: original.path), try BrowserActivity.hash(original) != BrowserActivity.hash(target) { throw CareError.message("存在不同版本的接入备份，需要核对后再接入。") }
        let originalHash = try BrowserActivity.hash(target), wrapperHash = try BrowserActivity.hash(wrapper)
        let config = BrowserIntegration(target: target.path, original: original.path, wrapperHash: wrapperHash, originalHash: originalHash, installed: Date())
        try fm.createDirectory(at: BrowserActivity.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = URL(fileURLWithPath: target.path + ".cachecare-staged")
        guard !fm.fileExists(atPath: staged.path) else { throw CareError.message("接入暂存文件已存在，请核对。") }
        try fm.copyItem(at: wrapper, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // Copy the original first, then atomically replace the entry: there is never a missing launcher.
        if !fm.fileExists(atPath: original.path) { try fm.copyItem(at: target, to: original) }
        guard Darwin.rename(staged.path, target.path) == 0 else { try? fm.removeItem(at: staged); try? fm.removeItem(at: original); throw CareError.message("入口替换失败，原程序保留。") }
        do { try JSONEncoder().encode(config).write(to: BrowserActivity.manifest, options: .atomic) }
        catch { _ = Darwin.rename(original.path, target.path); throw error }
        baseline = Date()
    }
    func uninstall() throws {
        let config = try BrowserActivity.read()
        guard try BrowserActivity.hash(URL(fileURLWithPath: config.target)) == config.wrapperHash,
              try BrowserActivity.hash(URL(fileURLWithPath: config.original)) == config.originalHash else { throw CareError.message("工具版本已变化，未覆盖现有入口。") }
        // Keep the original backup so an already-running launcher can still resolve it.
        let staged = config.target + ".cachecare-restore-" + UUID().uuidString
        try fm.copyItem(atPath: config.original, toPath: staged)
        guard Darwin.rename(staged, config.target) == 0 else { throw CareError.message("撤销接入失败，当前入口保留。") }
        try fm.removeItem(at: BrowserActivity.manifest)
    }
    func integration() throws -> BrowserIntegration {
        let c = try BrowserActivity.read()
        guard try BrowserActivity.hash(URL(fileURLWithPath: c.target)) == c.wrapperHash,
              try BrowserActivity.hash(URL(fileURLWithPath: c.original)) == c.originalHash else { throw CareError.message("agent-browser 入口已变化，自动回收暂停。") }
        return c
    }
    func scan(rows: [ProcessRow], pinned: Set<String>, now: Date = Date()) -> ReapReport {
        var result = ReapReport()
        do {
            let config = try integration()
            let files = try fm.contentsOfDirectory(at: socketDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "pid" }
            let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard BrowserActivity.validSession(name), file.resolvingSymlinksInPath() == file,
                      let pid = Int32((try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
                      let parent = byPID[pid], [config.target, config.original].contains(parent.path),
                      let browser = rows.first(where: { $0.parent == pid && $0.isBrowser }) else { continue }
                var st = stat(); guard lstat(file.path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG else { continue }
                let last = BrowserActivity.lastActivity(name, integration: config, baseline: baseline)
                var reason = "空闲 \(max(0, Int(now.timeIntervalSince(last) / 60))) / 10 分钟"
                var eligible = now.timeIntervalSince(last) >= idleSeconds
                if pinned.contains(name) || name == "default" { eligible = false; reason = "已保留" }
                result.sessions.append(BrowserSession(name: name, daemon: pid, browser: browser.pid, pidInode: UInt64(st.st_ino), pidModified: Double(st.st_mtimespec.tv_sec), lastActivity: last, eligible: eligible, reason: reason))
            }
            result.sessions.sort { $0.name < $1.name }
        } catch { result.error = error.localizedDescription }
        return result
    }
    func readRecords() -> [ReapRecord] { (try? JSONDecoder().decode([ReapRecord].self, from: Data(contentsOf: recordsURL))) ?? [] }
    func log(_ record: ReapRecord) throws {
        recordLock.lock(); defer { recordLock.unlock() }
        var records: [ReapRecord] = []
        if fm.fileExists(atPath: recordsURL.path) { records = try JSONDecoder().decode([ReapRecord].self, from: Data(contentsOf: recordsURL)) }
        records.append(record)
        try JSONEncoder().encode(Array(records.suffix(1000))).write(to: recordsURL, options: .atomic)
    }
    func close(_ item: BrowserSession, pinned: Set<String>, now: Date = Date(), shouldContinue: () -> Bool = { true }) throws -> String {
        let config = try integration()
        guard !pinned.contains(item.name), item.name != "default" else { throw CareError.message("会话已保留") }
        let dir = try BrowserActivity.sessionDir(item.name)
        let initialLease = try BrowserActivity.lock(dir, exclusive: true)
        flock(initialLease, LOCK_UN); Darwin.close(initialLease)
        guard now.timeIntervalSince(BrowserActivity.lastActivity(item.name, integration: config, baseline: baseline)) >= idleSeconds else { throw CareError.message("会话刚有新命令，继续保留") }
        let current = try processes()
        guard current.contains(where: { $0.pid == item.daemon && [config.target, config.original].contains($0.path) }),
              current.contains(where: { $0.pid == item.browser && $0.parent == item.daemon && $0.isBrowser }) else { throw CareError.message("进程身份已变化") }
        var st = stat()
        let pidFile = socketDir.appendingPathComponent(item.name + ".pid")
        guard lstat(pidFile.path, &st) == 0, UInt64(st.st_ino) == item.pidInode, Double(st.st_mtimespec.tv_sec) == item.pidModified,
              Int32((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)) == item.daemon else { throw CareError.message("会话已重新启动") }
        var arguments = [CChar](repeating: 0, count: 65536)
        guard careArguments(item.browser, &arguments, Int32(arguments.count)) > 0,
              let profileURL = temporaryHeadlessProfile(String(cString: arguments), temporaryDirectory: fm.temporaryDirectory) else { throw CareError.message("带界面、持久化浏览器或参数不可读，已保护") }
        let socketPath = socketDir.appendingPathComponent(item.name + ".sock").path
        guard careConnections(item.daemon, socketPath, 0, 1) == 0 else { throw CareError.message("有直接命令或接管连接，或状态不明，已保护") }
        let profile = profileURL.path
        guard let portString = (try? String(contentsOfFile: profile + "/DevToolsActivePort", encoding: .utf8))?.split(separator: "\n").first,
              let port = Int(portString), port > 0, port < 65536 else { throw CareError.message("无法核对浏览器调试连接") }
        guard careConnections(item.browser, "", Int32(port), 0) == 0 else { throw CareError.message("浏览器有外部接管连接或状态不明，已保护") }
        var descendants: Set<Int32> = [item.browser]
        for _ in 0..<8 { let previous = descendants; for row in current where descendants.contains(row.parent) { descendants.insert(row.pid) }; if previous == descendants { break } }
        guard descendants.allSatisfy({ careDownloading($0) == 0 }) else { throw CareError.message("检测到未完成下载或文件检查不完整，已保护") }
        // Inspection does not block new commands. Acquire the exclusive lease only at the final close boundary.
        let lease = try BrowserActivity.lock(dir, exclusive: true)
        defer { flock(lease, LOCK_UN); Darwin.close(lease) }
        guard shouldContinue() else { throw CareError.message("自动回收已暂停") }
        guard now.timeIntervalSince(BrowserActivity.lastActivity(item.name, integration: config, baseline: baseline)) >= idleSeconds else { throw CareError.message("检查期间有新命令，继续保留") }
        try log(ReapRecord(session: item.name, browser: item.browser, outcome: "请求正常退出"))
        var requestError: Error?
        do { try sendClose(socketPath, expectedPID: item.daemon) } catch { requestError = error }
        // Never SIGKILL existing browser processes. Read back whether Chrome actually exited.
        let end = Date().addingTimeInterval(4)
        while Darwin.kill(item.browser, 0) == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        let outcome = Darwin.kill(item.browser, 0) != 0 ? "已回收" : "已请求退出，等待浏览器结束"
        try log(ReapRecord(session: item.name, browser: item.browser, outcome: outcome))
        if outcome != "已回收", let requestError { throw requestError }
        return outcome
    }
    func sendClose(_ path: String, expectedPID: Int32) throws {
        var info = stat(); guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw CareError.message("会话套接字异常") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CareError.message("无法连接会话") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSig: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, 4)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CareError.message("会话路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw CareError.message("会话连接失败") }
        var peer: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, 0, 2, &peer, &length) == 0, peer == expectedPID else { throw CareError.message("套接字所属进程不匹配") }
        let data = Data("{\"id\":\"cachecare-close\",\"action\":\"close\"}\n".utf8)
        let written = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written == data.count else { throw CareError.message("退出请求未完整发送") }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while response.count < 65536 {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }; response.append(contentsOf: buffer.prefix(n))
            if response.contains(10) { break }
        }
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any], object["success"] as? Bool == true else { throw CareError.message("未收到正常退出确认，需要核对进程状态") }
    }
}
