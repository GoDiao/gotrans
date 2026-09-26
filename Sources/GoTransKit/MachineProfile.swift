import Foundation

/// 判定所需的全部机器事实，一个纯值。探测与判定之间隔着它，于是「按一台手边没有的机器算」
/// 和「单测」走的是同一条路径，不需要为测试再开一个口子。
///
/// **不含可用内存**（D12）。`SystemMemory.available()` 取 free + inactive 页，量的是
/// 「不做任何动作就能立刻交出去的量」，不是一次大分配能拿到的上限——本机实测 3 GB 出头的
/// 同时系统已压缩 7 GB、换出 10 GB 且运行正常，5.2 GB 的 Gemma 在这台机器上加载得动。
/// 把它摆在模型体积旁边只会让人得出「装不下」的错误结论，而那正是本机制要消除的劝退信号。
public struct MachineProfile: Sendable, Equatable {
    /// 物理内存。`ProcessInfo` 保证有值，因此不可空——判定的分母就是它（D9）。
    public let physicalMemory: UInt64
    /// 性能核数。Intel 机型没有 perflevel 键，读不到为 nil。
    public let performanceCoreCount: Int?
    /// 模型目录所在卷的剩余空间。读不到为 nil，此时磁盘闸门不拦——缺数据不构成拒绝的理由。
    public let freeDiskBytes: UInt64?
    /// 芯片名。仅供显示，不参与判定。
    public let chipName: String?

    public init(
        physicalMemory: UInt64,
        performanceCoreCount: Int? = nil,
        freeDiskBytes: UInt64? = nil,
        chipName: String? = nil
    ) {
        self.physicalMemory = physicalMemory
        self.performanceCoreCount = performanceCoreCount
        self.freeDiskBytes = freeDiskBytes
        self.chipName = chipName
    }
}

/// 唯一做 I/O 的一层，把三个 `System*` 辅助的读数拼成 `MachineProfile`，
/// 好让判定内核保持纯净。全部是本机读取，不联网（D16）。
public enum MachineProbe {
    public static func current(modelDirectory: URL = TranslationEngine.defaultModelBase())
        -> MachineProfile
    {
        MachineProfile(
            physicalMemory: SystemMemory.physical(),
            performanceCoreCount: SystemCPU.performanceCoreCount(),
            freeDiskBytes: SystemDisk.freeBytes(at: modelDirectory),
            chipName: SystemCPU.chipName()
        )
    }
}
