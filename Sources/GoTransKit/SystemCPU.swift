import Foundation
import Darwin

/// sysctl 读数。仓库里没有现成的 sysctl 取值范式可抄——`SystemMemory` 用的是
/// `ProcessInfo` 与 `host_statistics64`，全仓库 Swift 侧此前 `sysctlbyname` 零命中（评审 I7）。
/// 全部是本机读取，不发起任何网络请求（D16）。
public enum SystemCPU {
    /// 性能核数。Apple silicon 的 perflevel 0 是性能层（P 核），Intel 机型没有这套键，
    /// 读不到就返回 nil，由调用方退化，不猜。
    public static func performanceCoreCount() -> Int? {
        guard let value = sysctlInt("hw.perflevel0.logicalcpu"), value > 0 else { return nil }
        return value
    }

    /// 芯片名，例如「Apple M1 Pro」。用 `machdep.cpu.brand_string` 而不是 `hw.model`——
    /// 后者返回的是机型（`MacBookPro18,3`），不是用户要看的芯片。
    public static func chipName() -> String? {
        guard let name = sysctlString("machdep.cpu.brand_string"), !name.isEmpty else { return nil }
        return name
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
