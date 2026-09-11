import Foundation

@main struct BrowserCLI {
    static func main() throws {
        setbuf(stdout, nil)
        let engine = BrowserReaper()
        let args = CommandLine.arguments
        if args.contains("--install") {
            try engine.install(wrapper: URL(fileURLWithPath: "build/BrowserLauncher").standardizedFileURL)
            print("Installed command activity tracking. Original binary preserved. Observation starts now.")
            return
        }
        if let i = args.firstIndex(of: "--close-fixture"), i + 2 < args.count {
            let path = args[i + 1]
            guard path.contains("cachecare-test-"), let pid = Int32(args[i + 2]) else { fatalError("fixture only") }
            try engine.sendClose(path, expectedPID: pid); print("Fixture graceful close acknowledged."); return
        }
        let fixtureName: String? = args.firstIndex(of: "--reap-fixture").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if let fixtureName { guard fixtureName.hasPrefix("cachecare-test-") else { fatalError("fixture only") } }
        let now = fixtureName == nil ? Date() : Date().addingTimeInterval(601)
        let report = engine.scan(rows: try processes(), pinned: ["default"], now: now)
        if let error = report.error { print("ERROR: " + error); exit(1) }
        print("Sessions: \(report.sessions.count); idle-eligible: \(report.sessions.filter(\.eligible).count)")
        for item in report.sessions where fixtureName == nil || item.name == fixtureName { print("\(item.name) pid=\(item.browser) \(item.reason)") }
        if let fixtureName {
            guard let item = report.sessions.first(where: { $0.name == fixtureName }) else { throw CareError.message("fixture session not found") }
            print(try engine.close(item, pinned: ["default"], now: now)); return
        }
        if args.contains("--reap") {
            for item in report.sessions.filter(\.eligible).prefix(20) {
                do { print("RESULT \(item.name): " + (try engine.close(item, pinned: ["default"]))) }
                catch { print("SKIP \(item.name): \(error.localizedDescription)") }
            }
        }
    }
}
