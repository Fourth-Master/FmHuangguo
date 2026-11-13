import Foundation
import os.log
import Darwin

/// 崩溃 signal handler 使用的预打开 fd（模块级全局，handler 可访问）
fileprivate var crashSignalFD: Int32 = -1

// MARK: - 调试日志（写入 Documents/debug.log，"文件"App 可直接查看）
//
// 用法：DebugLogger.shared.log("...")
// 设置页提供 查看/分享(AirDrop等)/清空。

final class DebugLogger {
    static let shared = DebugLogger()

    /// signal handler 使用的预打开 fd（async-signal-safe 写入）；实例 fd 的静态镜像
    fileprivate static var signalFD: Int32 = -1

    private let fileURL: URL
    private let queue = DispatchQueue(label: "fmhuangguo.debuglog", qos: .utility)
    private let dateFormatter: DateFormatter
    /// 环形上限：超过后整文件截断保留后半
    private let maxBytes = 512 * 1024

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("debug.log")
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss.SSS"
        dateFormatter = df
        _ = fileURL // 确保路径就绪
        rolloverIfNeeded()
    }

    /// 版本变化时自动清空旧日志（比较 CFBundleVersion 构建号，存 UserDefaults）
    private func rolloverIfNeeded() {
        let current = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let last = UserDefaults.standard.string(forKey: "debug_log_build_version")
        guard last != current else { return }
        UserDefaults.standard.set(current, forKey: "debug_log_build_version")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        queue.async { [weak self] in
            guard let self = self else { return }
            let header = "[--] App 更新到 v\(version) (build \(current))，日志已清空 --\n"
            try? header.write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let caller = (file as NSString).lastPathComponent
        let entry = "[\(dateFormatter.string(from: Date()))] [\(caller):\(line)] \(message)\n"
        queue.async { [weak self] in
            guard let self = self else { return }
            self.append(entry)
        }
        // 同步镜像到系统日志便于连 Xcode 时查看
        Logger(subsystem: "com.fmhuangguo.app", category: "debug").info("\(entry, privacy: .public)")
    }

    private func append(_ entry: String) {
        let fm = FileManager.default
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            // 超限截断：保留后半
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes {
                let keep = size / 2
                if let data = try? Data(contentsOf: fileURL) {
                    let tail = data.suffix(keep)
                    try? tail.write(to: fileURL, options: .atomic)
                }
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? entry.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// 读取全部内容（主线程 UI 用）
    func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
    }

    var fileForSharing: URL { fileURL }

    // MARK: 崩溃捕获（NSException + 常见崩溃信号，写入 debug.log）

    /// App 启动时调用一次
    static func installCrashHandler() {
        // 确保 debug.log 存在并预打开 fd（signal handler 里只能用 write）
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent("debug.log").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        crashSignalFD = open(path, O_WRONLY | O_APPEND)

        // ObjC NSException（mpv/MoltenVK/GLES 抛的异常能被抓到并落日志）
        NSSetUncaughtExceptionHandler { exception in
            let text = "\n[CRASH-EXCEPTION] \(exception.name.rawValue): \(exception.reason ?? "-")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            text.withCString { p in
                _ = write(crashSignalFD, p, strlen(p))
            }
        }

        // 崩溃信号（SIGSEGV 等）：async-signal-safe 写入固定文本后恢复默认并重抛
        let signals: [(Int32, String)] = [
            (SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"),
            (SIGILL, "SIGILL"), (SIGFPE, "SIGFPE"), (SIGTRAP, "SIGTRAP"),
        ]
        for (sig, name) in signals {
            signal(sig) { code in
                let msg = "\n[CRASH-SIGNAL \(name)(\(code))] App 异常终止\n"
                msg.withCString { p in
                    _ = write(crashSignalFD, p, strlen(p))
                }
                signal(code, SIG_DFL)
                raise(code)
            }
        }
    }
}
