import SwiftUI
import AppKit
import CoreGraphics

private let ink = Color(red: 0.12, green: 0.20, blue: 0.20)
private let accent = Color(red: 0.13, green: 0.43, blue: 0.36)
private let paper = Color(red: 0.96, green: 0.97, blue: 0.955)

final class CareModel: ObservableObject {
    @Published var machine = MachineSnapshot()
    @Published var report = ScanReport()
    @Published var busy = false
    @Published var status = "正在读取这台 Mac 的状态…"
    @Published var history: [JournalEntry] = []
    @Published var automatic = UserDefaults.standard.bool(forKey: "automatic")
    @Published var nextRun = Date().addingTimeInterval(6 * 3600)
    @Published var selectedTab = 0
    @Published var browserReclaim = UserDefaults.standard.bool(forKey: "browserReclaim")
    @Published var browserReport = ReapReport()
    @Published var browserRecords: [ReapRecord] = []
    @Published var pinnedSessions = Set(UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? ["default"])
    private let worker = DispatchQueue(label: "MacCacheCare.worker", qos: .userInitiated)
    private let engine = CacheEngine()
    private let reaper = BrowserReaper()
    private var timer: Timer?

    init() {
        if let date = UserDefaults.standard.object(forKey: "nextRun") as? Date { nextRun = max(date, Date().addingTimeInterval(300)) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        refresh(scan: true)
    }
    func refresh(scan: Bool = false) {
        guard !busy else { return }; busy = true
        if scan { status = "检查进程与缓存白名单…" }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "读取内存与进程状态")
        worker.async {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let snapshot = MachineSnapshot.read()
            var scanned: ScanReport?
            if scan && snapshot.error == nil { scanned = self.engine.scan(rows: snapshot.rows) }
            let records = (try? self.engine.history()) ?? []
            let browsers = self.reaper.scan(rows: snapshot.rows, pinned: self.pinnedSessions)
            let browserRecords = self.reaper.readRecords()
            DispatchQueue.main.async {
                self.machine = snapshot; if let scanned { self.report = scanned }
                self.history = records; self.busy = false
                self.browserReport = browsers; self.browserRecords = browserRecords
                if let error = snapshot.error { self.status = "检查未完成：" + error }
                else if scan { self.status = "扫描完成。可整理 \(humanBytes(self.report.bytes))；运行中的程序已跳过。" }
            }
        }
    }
    func setAutomatic(_ enabled: Bool) {
        automatic = enabled; UserDefaults.standard.set(enabled, forKey: "automatic")
        nextRun = Date().addingTimeInterval(6 * 3600); UserDefaults.standard.set(nextRun, forKey: "nextRun")
        status = enabled ? "自动整理已开启；6 小时后检查，仅在闲置、内存压力正常时执行。" : "自动整理已关闭；每分钟的只读监测继续运行。"
    }
    func tick() {
        if browserReclaim && !busy { reclaimBrowsers(); return }
        if automatic && Date() >= nextRun && !busy {
            if let reason = automaticPauseReason() {
                status = "自动整理等待中：" + reason + "。"
                refresh(); return
            }
            clean(automatically: true)
        } else { refresh() }
    }
    func setBrowserReclaim(_ enabled: Bool) {
        if !enabled {
            browserReclaim = false; UserDefaults.standard.set(false, forKey: "browserReclaim")
            status = "浏览器自动回收已关闭。"; return
        }
        guard !busy else { return }; busy = true
        worker.async {
            do {
                guard let helper = Bundle.main.url(forResource: "BrowserLauncher", withExtension: nil) else { throw CareError.message("缺少命令计时组件") }
                try self.reaper.install(wrapper: helper)
                UserDefaults.standard.set(true, forKey: "browserReclaim")
                DispatchQueue.main.async {
                    self.browserReclaim = true; self.busy = false
                    self.status = "已开启 10 分钟空闲回收；执行中命令、保留会话及普通浏览器受保护。"
                    self.refresh()
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.status = error.localizedDescription } }
        }
    }
    func pin(_ session: String) {
        if pinnedSessions.contains(session) { pinnedSessions.remove(session) } else { pinnedSessions.insert(session) }
        UserDefaults.standard.set(Array(pinnedSessions), forKey: "pinnedSessions")
        refresh()
    }
    func reclaimBrowsers() {
        guard !busy else { return }; busy = true
        status = "检查空闲会话；执行中的命令持有保护锁…"
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "回收空闲自动化浏览器")
        worker.async {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let snapshot = MachineSnapshot.read()
            let pinned = Set(UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? ["default"])
            var report = self.reaper.scan(rows: snapshot.rows, pinned: pinned)
            var closed = 0, skipped = 0
            let deadline = Date().addingTimeInterval(35)
            if snapshot.error == nil && report.error == nil {
                let operations = OperationQueue(); operations.maxConcurrentOperationCount = 3; operations.qualityOfService = .userInitiated
                let resultLock = NSLock()
                for item in report.sessions.filter(\.eligible).prefix(20) {
                    operations.addOperation {
                        guard UserDefaults.standard.bool(forKey: "browserReclaim"), Date() < deadline else { return }
                        let pins = Set(UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? ["default"])
                        do {
                            if try self.reaper.close(item, pinned: pins, shouldContinue: { UserDefaults.standard.bool(forKey: "browserReclaim") }) == "已回收" { resultLock.lock(); closed += 1; resultLock.unlock() }
                        } catch {
                            resultLock.lock(); skipped += 1
                            if let i = report.sessions.firstIndex(where: { $0.name == item.name }) { report.sessions[i].reason = error.localizedDescription; report.sessions[i].eligible = false }
                            resultLock.unlock()
                        }
                    }
                }
                operations.waitUntilAllOperationsAreFinished()
            }
            let after = closed > 0 ? MachineSnapshot.read() : snapshot
            let records = self.reaper.readRecords()
            DispatchQueue.main.async {
                self.machine = after; self.browserReport = report; self.browserRecords = records; self.busy = false
                self.status = report.error ?? snapshot.error ?? "浏览器巡检完成：本轮回收 \(closed) 个，保护或跳过 \(skipped) 个；连续 10 分钟无命令才回收。"
                if closed > 0 { self.browserReport.sessions.removeAll { s in !after.browsers.contains(where: { $0.pid == s.browser }) } }
                // Browser recovery must not starve the independent six-hour disk-cache schedule.
                if self.automatic && Date() >= self.nextRun && automaticPauseReason() == nil { self.clean(automatically: true) }
            }
        }
    }
    func removeBrowserIntegration() {
        guard !busy else { return }; setBrowserReclaim(false); busy = true
        worker.async {
            let message: String
            do { try self.reaper.uninstall(); message = "命令计时接入已撤销，agent-browser 原版入口已恢复。" }
            catch { message = error.localizedDescription }
            DispatchQueue.main.async { self.busy = false; self.status = message; self.refresh() }
        }
    }
    func clean(automatically: Bool = false) {
        guard !busy else { return }; busy = true
        status = automatically ? "自动整理：重新检查使用情况…" : "重新检查进程、文件日期与占用情况…"
        worker.async {
            let snapshot = MachineSnapshot.read()
            if snapshot.error != nil || (automatically && snapshot.pressure != 1) {
                DispatchQueue.main.async {
                    self.machine = snapshot; self.busy = false
                    self.status = "本次未整理：\(snapshot.error ?? "内存压力偏高或无法确认，自动整理已暂停")。"
                    if automatically { self.nextRun = Date().addingTimeInterval(1800); UserDefaults.standard.set(self.nextRun, forKey: "nextRun") }
                }; return
            }
            let scanned = self.engine.scan(rows: snapshot.rows)
            let result = self.engine.clean(scanned, automatic: automatically)
            let records = (try? self.engine.history()) ?? []
            DispatchQueue.main.async {
                self.machine = snapshot; self.report = scanned; self.history = records; self.busy = false
                self.status = result.message + " 文件进入废纸篓后仍占磁盘空间。"
                if automatically { self.nextRun = Date().addingTimeInterval(21600); UserDefaults.standard.set(self.nextRun, forKey: "nextRun") }
                // Keep the scan honest after a mutation; retain the cleanup outcome in the status line.
                if result.moved > 0 { self.report.candidates.removeAll { c in records.contains { $0.original == c.path && $0.state == "trashed" } }
                    for i in self.report.rows.indices {
                        let items = self.report.candidates.filter { $0.ruleID == self.report.rows[i].id }
                        self.report.rows[i].count = items.count; self.report.rows[i].bytes = items.reduce(0) { $0 + $1.size }
                    }
                }
            }
        }
    }
    func restore() {
        guard !busy else { return }; busy = true
        worker.async {
            let message: String
            do { message = try self.engine.restoreLast() } catch { message = error.localizedDescription }
            let entries = (try? self.engine.history()) ?? []
            DispatchQueue.main.async { self.history = entries; self.status = message; self.busy = false }
        }
    }
    func exportReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "轻缓存-诊断.json"; panel.title = "保存本机诊断报告"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        struct Export: Encodable { let machine: MachineSnapshot; let cache: ScanReport; let note: String }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Export(machine: machine, cache: report, note: "只读进程快照；RSS 含共享页，不能相加视为独占内存。报告仅保存本机，不上传。" )).write(to: url, options: .atomic)
            status = "报告已保存：\(url.lastPathComponent)"
        } catch { status = "保存失败：" + error.localizedDescription }
    }
}

struct Metric: View {
    let label: String; let value: String; let detail: String; var warning = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(warning ? Color.orange : ink)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MainView: View {
    @ObservedObject var model: CareModel
    @State var showFiles = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Image(nsImage: NSImage(contentsOf: Bundle.main.url(forResource: "BrandIcon", withExtension: "png")!)!)
                    .resizable().interpolation(.high).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("轻缓存").font(.system(size: 25, weight: .semibold)).foregroundStyle(ink)
                    Text("这台 Mac 的缓存整理与内存巡检").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("重新扫描", systemImage: "arrow.clockwise") { model.refresh(scan: true) }.disabled(model.busy)
            }
            HStack(spacing: 12) {
                Metric(label: "内存压力", value: model.machine.pressureName, detail: "物理内存 \(humanBytes(model.machine.physical))", warning: model.machine.pressure > 1)
                Metric(label: "压缩内存", value: humanBytes(model.machine.compressed), detail: "这是内存占用，不是磁盘缓存")
                Metric(label: "交换空间", value: humanBytes(model.machine.swap), detail: "由 macOS 管理，不手动清除")
                Metric(label: "磁盘可用", value: humanBytes(model.machine.diskFree), detail: "移入废纸篓不等于释放空间")
            }
            if model.machine.browsers.count > 0 {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.exclamationmark").font(.system(size: 22)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(model.machine.browsers.count) 个自动化浏览器仍在后台").font(.system(size: 15, weight: .semibold))
                        Text("共 \(model.machine.automationCount) 个相关进程；\(model.machine.oldBrowsers) 个实例超过 2 天。\(model.browserReclaim ? "已开启 10 分钟无命令回收；执行中的任务受保护。" : "可在进程页开启 10 分钟空闲回收。")")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("查看进程") { model.selectedTab = 1 }
                }.padding(16).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
            Picker("页面", selection: $model.selectedTab) {
                Text("缓存整理").tag(0); Text("自动化进程").tag(1); Text("恢复记录").tag(2)
            }.pickerStyle(.segmented).frame(width: 370)
            Group {
                if model.selectedTab == 0 { cachePanel }
                else if model.selectedTab == 1 { processPanel }
                else { historyPanel }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield").foregroundStyle(accent)
                Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Text(model.machine.date, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary)
            }.frame(minHeight: 30)
        }.padding(26).frame(minWidth: 940, minHeight: 760).background(paper).tint(accent)
            .sheet(isPresented: $showFiles) { fileSheet }
    }
    var cachePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("可整理 \(humanBytes(model.report.bytes))").font(.system(size: 20, weight: .semibold))
                    Text("只处理 30 天未访问、未修改的旧文件；移入废纸篓，可恢复。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看文件") { showFiles = true }.disabled(model.report.candidates.isEmpty)
                Button("移入废纸篓") { model.clean() }.buttonStyle(.borderedProminent).disabled(model.busy || model.report.candidates.isEmpty)
            }
            VStack(spacing: 0) {
                ForEach(model.report.rows) { row in
                    HStack {
                        Image(systemName: row.status.contains("保护") ? "lock.shield" : "folder").foregroundStyle(accent).frame(width: 22)
                        Text(row.rule.title).font(.system(size: 12, weight: .medium)).frame(width: 160, alignment: .leading)
                        Text(row.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if row.count > 0 { Text("\(row.count) 个 · \(humanBytes(row.bytes))").font(.system(size: 11, design: .monospaced)) }
                        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(row.rule.relativePath).path) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("在 Finder 中显示缓存目录")
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                    if row.id != model.report.rows.last?.id { Divider().padding(.horizontal, 14) }
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 12))
            HStack(alignment: .top, spacing: 16) {
                Toggle(isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) })) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动整理").font(.system(size: 13, weight: .semibold))
                        Text("应用运行时每 6 小时检查；闲置 5 分钟且内存压力正常才整理。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if model.automatic { Text("下次检查：\(model.nextRun.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(accent) }
                    }
                }.toggleStyle(.switch)
                Spacer()
                Button("登录时启动设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }.help("在系统登录项中添加轻缓存；本应用不会自行改动启动项")
            }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text("已保护：Codex / OpenAI、飞书与微信数据、项目源码、模型与运行环境、浏览器登录资料、系统缓存和交换文件。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var processPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("任务执行中保留，空闲 10 分钟回收").font(.system(size: 19, weight: .semibold))
                    Text("仅回收无界面、临时资料目录的 agent-browser。普通浏览器、接管连接和下载受保护。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                Button("导出诊断") { model.exportReport() }
            }
            HStack(spacing: 12) {
                Toggle("自动回收浏览器", isOn: Binding(get: { model.browserReclaim }, set: { model.setBrowserReclaim($0) })).toggleStyle(.switch).disabled(model.busy && !model.browserReclaim)
                Text("每分钟检查 · 不必等电脑闲置").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("立即检查回收") { model.reclaimBrowsers() }.disabled(model.busy || !model.browserReclaim)
                Button("撤销命令计时接入") { model.removeBrowserIntegration() }.disabled(model.busy || model.browserReport.error != nil)
            }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
            if let error = model.browserReport.error { Text("尚未接入命令计时，开启开关后开始观察：\(error)").font(.system(size: 11)).foregroundStyle(.secondary) }
            Table(model.machine.browsers) {
                TableColumn("PID") { Text(String($0.pid)).monospacedDigit() }.width(65)
                TableColumn("已运行") { Text($0.elapsed).monospacedDigit() }.width(110)
                TableColumn("CPU") { Text($0.cpu >= 0 ? String(format: "%.1f%%", $0.cpu) : "—") }.width(60)
                TableColumn("RSS（含共享页）") { Text(humanBytes($0.rssKB * 1024)) }.width(130)
                TableColumn("会话 / 回收状态") { row in
                    let session = model.browserReport.sessions.first { $0.browser == row.pid }
                    Text(session.map { "\($0.name) · \($0.reason)" } ?? "未纳入命令计时")
                }
                TableColumn("保留") { row in
                    if let session = model.browserReport.sessions.first(where: { $0.browser == row.pid }) {
                        Button(model.pinnedSessions.contains(session.name) || session.name == "default" ? "已保留" : "保留") { model.pin(session.name) }
                            .disabled(session.name == "default" || model.busy)
                    }
                }.width(65)
            }.frame(minHeight: 180)
            if !model.browserRecords.isEmpty {
                Text("最近回收：" + model.browserRecords.filter { $0.outcome == "已回收" }.suffix(5).map(\.session).joined(separator: "、"))
                    .font(.system(size: 11)).foregroundStyle(accent)
                }
            Text("首次接入先观察满 10 分钟。default 会话默认保留；长时间等待的任务可点“保留”。空闲是回收规则，不代表已确认任务完成。仅请求正常退出，不强杀进程。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    var historyPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("每次整理都有记录").font(.system(size: 19, weight: .semibold))
                    Text("恢复时跳过运行中的程序，并保留原位置的新文件；不会自动清空废纸篓。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复最近一个文件") { model.restore() }.disabled(model.busy || !model.history.contains { $0.state == "trashed" })
                Button("打开废纸篓") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
            }
            if model.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(accent.opacity(0.6))
                    Text("尚未移动任何缓存").font(.system(size: 16, weight: .medium))
                    Text("扫描与内存巡检不会改动你的文件。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 14))
            } else {
                List(model.history.reversed().prefix(200)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(URL(fileURLWithPath: item.original).lastPathComponent).lineLimit(1); Spacer()
                            Text(item.state == "trashed" ? "废纸篓中" : item.state == "restored" ? "已恢复" : "需核对").foregroundStyle(accent) }
                        Text(item.original).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("\(humanBytes(item.size)) · \(item.date.formatted())").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }
    }
    var fileSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("本次扫描的候选文件").font(.title2); Spacer(); Button("关闭") { showFiles = false } }
            Text("整理前会再次检查。这里只展示前 200 项，完整清单可导出诊断查看。")
                .font(.caption).foregroundStyle(.secondary)
            List(model.report.candidates.prefix(200)) { c in
                HStack { Text(c.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(); Text(humanBytes(c.size)).font(.caption) }
            }
            Button("导出完整诊断") { model.exportReport() }
        }.padding(24).frame(width: 850, height: 490)
    }
}

@main struct CacheCareApp: App {
    @StateObject private var model = CareModel()
    var body: some Scene {
        Window("轻缓存", id: "main") { MainView(model: model).preferredColorScheme(.light) }
            .defaultSize(width: 1020, height: 830)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) {
                    Button("下载与更新…") { openReleases() }
                }
            }
        MenuBarExtra("轻缓存", systemImage: "leaf") {
            MenuContent(model: model)
        }
    }
}
struct MenuContent: View {
    @ObservedObject var model: CareModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("内存压力：\(model.machine.pressureName)")
        Text("自动化浏览器：\(model.machine.browsers.count) 个")
        Divider()
        Button("打开轻缓存") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("重新扫描") { model.refresh(scan: true) }.disabled(model.busy)
        Toggle("自动整理", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) }))
        Divider()
        Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
        Button("下载与更新…") { openReleases() }
        Button("退出轻缓存") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private func openReleases() {
    NSWorkspace.shared.open(URL(string: "https://github.com/ChrisXHL/MacCacheCare/releases/latest")!)
}
