import Foundation
import os

/// 极简文件日志：GUI app 的 stderr 会被丢弃，引擎错误必须落盘才能事后定位。
/// 同时写 os_log（Console.app 可见）。
public enum GTLog {
    /// 测试进程里没有「用户」，它的日志不该进 app 的诊断通道——文件和 os_log 子系统都算。
    /// 此前两者都是无条件的，测试夹具 `ExplodingTranslator` 的报错因此混进了用户日志
    /// （`translate failed: mldrift buffer allocation failed`，56 行）。
    /// 判据取 XCTest 是否已加载：`swift test` 不设任何 `XCTest*` 环境变量（实测），
    /// 而它和 `xcodebuild test` 都会把这个框架带进测试进程，产品进程则不链接它。
    private static let isTestProcess = NSClassFromString("XCTestCase") != nil

    public static let logFileURL: URL = {
        let base = isTestProcess
            ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/GoTrans/gotrans.log")
    }()

    private static let osLog = Logger(
        subsystem: isTestProcess ? "com.godiao.GoTrans.tests" : "com.godiao.GoTrans.app",
        category: "engine"
    )
    private static let queue = DispatchQueue(label: "com.godiao.log")

    public static func error(_ message: String) { write("ERROR", message) }
    public static func info(_ message: String) { write("INFO", message) }

    private static func write(_ level: String, _ message: String) {
        osLog.log(level: level == "ERROR" ? .error : .info, "\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let dir = logFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: logFileURL)
            }
        }
    }
}
