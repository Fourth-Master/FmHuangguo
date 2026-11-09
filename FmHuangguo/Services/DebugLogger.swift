import Foundation
import os.log

// MARK: - 调试日志（写入 Documents/debug.log，"文件"App 可直接查看）
//
// 用法：DebugLogger.shared.log("...")
// 设置页提供 查看/分享(AirDrop等)/清空。

final class DebugLogger {
    static let shared = DebugLogger()

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
}
