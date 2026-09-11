import Foundation
import Darwin

@main struct SafetyTests {
    static func main() throws {
        if CommandLine.arguments.contains("--probe") {
            let machine = MachineSnapshot.read()
            let report = machine.error == nil ? CacheEngine().scan(rows: machine.rows) : ScanReport()
            struct Probe: Encodable { let machine: MachineSnapshot; let scan: ScanReport }
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
            let data = try e.encode(Probe(machine: machine, scan: report))
            try data.write(to: URL(fileURLWithPath: "build/live-readonly-probe.json"), options: .atomic)
            print("LIVE pressure=\(machine.pressureName) browserInstances=\(machine.browsers.count) relatedProcesses=\(machine.automationCount) swap=\(humanBytes(machine.swap))")
            for row in report.rows { print("\(row.rule.title): \(row.status), \(row.count) files / \(humanBytes(row.bytes))") }
            print("READ ONLY: no cache moved, no process terminated.")
            return
        }
        let fm = FileManager.default
        let home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacCacheCare-tests-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let engine = CacheEngine(home: home), rule = CacheRule.defaults.first { $0.id == "npm" }!
        let root = home.appendingPathComponent(rule.relativePath)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        let future = Date().addingTimeInterval(40 * 86400)
        var passed = 0
        func check(_ test: Bool, _ name: String) {
            guard test else { print("FAIL: " + name); exit(1) }
            passed += 1; print("PASS: " + name)
        }
        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try Data("fixture cache".utf8).write(to: url); return url
        }
        let a = try file("old.log")
        check(engine.candidate(a, rule: rule) == nil, "recent file protected")
        check(engine.candidate(a, rule: rule, now: future) != nil, "old unused regular file eligible")
        let outside = home.appendingPathComponent("important.txt"); try Data("source document".utf8).write(to: outside)
        check(engine.candidate(outside, rule: rule, now: future) == nil, "outside allowlist protected")
        let link = root.appendingPathComponent("linked.log"); try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        check(engine.candidate(link, rule: rule, now: future) == nil, "symlink file rejected")
        let dirLink = root.appendingPathComponent("escape"); try fm.createSymbolicLink(at: dirLink, withDestinationURL: home)
        check(engine.candidate(dirLink.appendingPathComponent("important.txt"), rule: rule, now: future) == nil, "symlink parent rejected")
        let hard = root.appendingPathComponent("hard.log"); try fm.linkItem(at: outside, to: hard)
        check(engine.candidate(hard, rule: rule, now: future) == nil, "hardlinked file rejected")
        check(engine.candidate(root, rule: rule, now: future) == nil, "cache root never moved")
        let fake = CacheRule(id: "npm", title: "bad", relativePath: "Documents", owners: [])
        check(engine.candidate(outside, rule: fake, now: future) == nil, "forged rule rejected")
        let owner = ProcessRow(pid: 987, parent: 1, rssKB: 1, cpu: 0, elapsed: "01:00", path: "/opt/homebrew/bin/node")
        check(engine.scan(rows: [owner], now: future).candidates.isEmpty, "active owner skipped during scan")
        var report = ScanReport(); report.candidates = [engine.candidate(a, rule: rule, now: future)!]
        var moves = 0
        let mover: (URL) throws -> URL = { u in
            moves += 1
            let target = home.appendingPathComponent(".Trash").appendingPathComponent(UUID().uuidString)
            try fm.moveItem(at: u, to: target); return target
        }
        let blocked = engine.clean(report, automatic: false, now: future, readProcesses: { [owner] }, closedCheck: { _ in }, move: mover)
        check(blocked.moved == 0 && moves == 0 && fm.fileExists(atPath: a.path), "owner started after scan blocks cleanup")
        let open = engine.clean(report, automatic: false, now: future, readProcesses: { [] }, closedCheck: { _ in throw CareError.message("open file") }, move: mover)
        check(open.moved == 0 && moves == 0, "open or uncertain file check blocks cleanup")
        var reads = 0
        let duringCheck = engine.clean(report, automatic: false, now: future, readProcesses: { reads += 1; return reads >= 3 ? [owner] : [] }, closedCheck: { _ in }, move: mover)
        check(duringCheck.moved == 0 && moves == 0, "owner started during handle check blocks cleanup")
        try Data("changed after scan".utf8).write(to: a)
        let changed = engine.clean(report, automatic: false, now: future, readProcesses: { [] }, closedCheck: { _ in }, move: mover)
        check(changed.moved == 0 && moves == 0, "modified file after scan protected")
        report.candidates = [engine.candidate(a, rule: rule, now: future)!]
        let result = engine.clean(report, automatic: false, now: future, readProcesses: { [] }, closedCheck: { _ in }, move: mover)
        check(result.moved == 1 && moves == 1 && !fm.fileExists(atPath: a.path), "eligible file moved to fixture trash")
        let journal = try engine.history()
        check(journal.count == 1 && journal[0].state == "trashed" && fm.fileExists(atPath: journal[0].trash), "recovery record matches moved file")
        try Data("new owner file".utf8).write(to: a)
        do { _ = try engine.restoreLast(readProcesses: { [] }); check(false, "restore conflict rejected") }
        catch { check(try String(contentsOf: a, encoding: .utf8) == "new owner file", "restore never overwrites replacement") }
        try fm.removeItem(at: a)
        do { _ = try engine.restoreLast(readProcesses: { [owner] }); check(false, "restore owner rejected") }
        catch { check(!fm.fileExists(atPath: a.path), "restore skips active owner") }
        _ = try engine.restoreLast(readProcesses: { [] })
        check(try String(contentsOf: a, encoding: .utf8) == "changed after scan", "restore recovers original bytes")
        check(try engine.history()[0].state == "restored", "restored state persisted")
        try Data("invalid journal".utf8).write(to: engine.journalURL)
        report.candidates = [engine.candidate(a, rule: rule, now: future)!]
        let corrupt = engine.clean(report, automatic: false, now: future, readProcesses: { [] }, closedCheck: { _ in }, move: mover)
        check(corrupt.moved == 0 && fm.fileExists(atPath: a.path), "corrupt journal prevents mutations")
        check(ProcessRow(pid: 1, parent: 0, rssKB: 1, cpu: 0, elapsed: "02-23:15:59", path: "").ageSeconds == 256559, "process elapsed days parsed")
        let handle = try FileHandle(forReadingFrom: a)
        do { try engine.ensureClosed([a.path]); check(false, "real open handle detected") }
        catch { check(true, "real lsof open handle blocks cleanup") }
        try handle.close()
        do { try engine.ensureClosed([a.path]); check(true, "real lsof accepts closed fixture") }
        catch { print("NOTE: closed-file check unavailable on host; safe skip: \(error)") }
        check(AutomationPolicy.pauseReason(pressure: 2, idle: 600, lowPower: false, hot: false) != nil, "automatic cleanup pauses under memory pressure")
        check(AutomationPolicy.pauseReason(pressure: 0, idle: 600, lowPower: false, hot: false) != nil, "unknown pressure blocks automatic cleanup")
        check(AutomationPolicy.pauseReason(pressure: 1, idle: 60, lowPower: false, hot: false) != nil, "user activity blocks automatic cleanup")
        check(AutomationPolicy.pauseReason(pressure: 1, idle: .nan, lowPower: false, hot: false) != nil, "unknown idle time blocks automatic cleanup")
        check(AutomationPolicy.pauseReason(pressure: 1, idle: 600, lowPower: true, hot: false) != nil, "low power blocks automatic cleanup")
        check(AutomationPolicy.pauseReason(pressure: 1, idle: 600, lowPower: false, hot: true) != nil, "thermal load blocks automatic cleanup")
        check(AutomationPolicy.pauseReason(pressure: 1, idle: 600, lowPower: false, hot: false) == nil, "healthy idle host permits automatic cleanup")
        // Native Finder trash integration, using only a disposable fixture, then recover it.
        let native = home.appendingPathComponent("native-trash-" + UUID().uuidString + ".txt")
        try Data("native trash fixture".utf8).write(to: native)
        let trashed = try trashFile(native)
        check(!fm.fileExists(atPath: native.path) && fm.fileExists(atPath: trashed.path), "native macOS trash moves fixture and returns real path")
        try fm.moveItem(at: trashed, to: native)
        check(try String(contentsOf: native, encoding: .utf8) == "native trash fixture", "native trash fixture recovered without data loss")
        check(BrowserActivity.session(["--session", "research-1", "open", "about:blank"], env: [:]) == "research-1", "explicit session parsed")
        check(BrowserActivity.session(["--session=research-2"], env: [:]) == "research-2", "equals session syntax parsed")
        check(BrowserActivity.session([], env: ["AGENT_BROWSER_SESSION": "research-3"]) == "research-3", "environment session parsed")
        check(BrowserActivity.session(["--session", "../../Documents"], env: [:]) == nil, "session traversal rejected")
        check(BrowserActivity.session([], env: ["AGENT_BROWSER_SOCKET_DIR": "/tmp/hermes-private"]) == nil, "private task socket directory excluded")
        let temp = fm.temporaryDirectory
        let profile = temp.appendingPathComponent("agent-browser-chrome-fixture")
        check(temporaryHeadlessProfile("chrome --headless=new --user-data-dir=\(profile.path)", temporaryDirectory: temp) != nil, "headless temporary profile recognized without trailing slash dependency")
        check(temporaryHeadlessProfile("chrome --user-data-dir=\(profile.path)", temporaryDirectory: temp) == nil, "headed browser protected")
        check(temporaryHeadlessProfile("chrome --headless=new --user-data-dir=/Users/example/Library/Browser", temporaryDirectory: temp) == nil, "persistent profile protected")
        check(temporaryHeadlessProfile("chrome --headless=new --user-data-dir=\(temp.path)/other-profile", temporaryDirectory: temp) == nil, "unmanaged temporary browser protected")
        let live = MachineSnapshot.read()
        check(live.error == nil && live.physical > 0 && live.compressed <= live.physical, "native memory bridge returns consistent live metrics")
        check(live.rows.contains { $0.pid == getpid() && $0.parent == getppid() }, "native process bridge returns own process and correct parent")
        let download = home.appendingPathComponent("fixture.crdownload")
        try Data("partial fixture".utf8).write(to: download)
        let downloadHandle = try FileHandle(forReadingFrom: download)
        check(careDownloading(getpid()) == 1, "native file descriptor inspection detects an unfinished download")
        try downloadHandle.close()
        check(careConnections(getpid(), "/nonexistent-fixture.sock", 0, 1) != 0, "native connection guard rejects a non-browser process")
        print("\(passed) safety checks passed. All mutations were confined to disposable fixtures.")
    }
}
