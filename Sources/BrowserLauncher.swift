import Foundation
import Darwin

private var forwardedPID: Int32 = 0
private func forwardSignal(_ sig: Int32) { if forwardedPID > 0 { Darwin.kill(forwardedPID, sig) } }

// A command-lifetime shared lease protects even long-running CLI operations.
// stdin, stdout, stderr, environment, working directory and exit code pass through unchanged.
@main struct BrowserLauncher {
    static func main() {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let original = executable + ".cachecare-original"
        let args = Array(CommandLine.arguments.dropFirst())
        var fd: Int32 = -1
        var directory: URL?
        if let name = BrowserActivity.session(args, env: ProcessInfo.processInfo.environment) {
            do {
                let dir = try BrowserActivity.sessionDir(name)
                fd = try BrowserActivity.lock(dir, exclusive: false)
                try BrowserActivity.touch(dir); directory = dir
            } catch {
                // Preserve CLI functionality, but invalidate reclamation if tracking cannot be trusted.
                try? FileManager.default.removeItem(at: BrowserActivity.manifest)
            }
        }
        defer { if let directory { try? BrowserActivity.touch(directory) }; if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd) } }
        do {
            var argv = ([original] + args).map { strdup($0) } + [nil]
            var envp = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var pid: pid_t = 0
            let result = posix_spawn(&pid, original, nil, nil, &argv, &envp)
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
            forwardedPID = pid
            signal(SIGINT, forwardSignal); signal(SIGTERM, forwardSignal); signal(SIGHUP, forwardSignal)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 { if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) } }
            if let directory { try BrowserActivity.touch(directory) }
            if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 }
            exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        } catch {
            FileHandle.standardError.write(Data("轻缓存启动转发失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
