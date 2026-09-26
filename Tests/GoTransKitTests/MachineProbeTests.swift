import Testing
import Foundation
@testable import GoTransKit

@Suite struct MachineProbeTests {
    /// 性能核数不能大于逻辑核数，也不能是 0。
    /// 不断言具体等于 6：本机是 M1 Pro（6P+2E），但 CI 跑在别的机型上，写死会让 CI 失败。
    /// 「本机读到 6」是一条人工核对项，见任务的完成判据。
    @Test func performanceCoreCountStaysWithinTheLogicalCoreCount() {
        guard let cores = SystemCPU.performanceCoreCount() else {
            // Intel 机型没有 perflevel 键，返回 nil 是约定行为，不是失败。
            return
        }
        #expect(cores >= 1)
        #expect(cores <= ProcessInfo.processInfo.processorCount)
    }

    /// 芯片名要是芯片，不是机型。`hw.model` 的形状是「字母 + 数字,数字」（MacBookPro18,3），
    /// 芯片名不该长成那样。
    @Test func chipNameIsTheChipNotTheModelIdentifier() throws {
        let chip = try #require(SystemCPU.chipName())
        #expect(!chip.isEmpty)
        #expect(chip.range(of: #"^[A-Za-z]+\d+,\d+$"#, options: .regularExpression) == nil,
                "读到的是机型标识而不是芯片名：\(chip)")
    }

    /// 读不到的键返回空值，不崩、不猜。
    @Test func unknownSysctlKeysDegradeToNil() {
        #expect(SystemCPU.sysctlInt("hw.perflevel99.logicalcpu") == nil)
        #expect(SystemCPU.sysctlString("machdep.cpu.no_such_key") == nil)
    }

    /// 磁盘剩余针对给定目录所在的卷，为正且不大于该卷总容量。
    @Test func freeDiskIsPositiveAndNoLargerThanTheVolume() throws {
        let dir = FileManager.default.temporaryDirectory
        let free = try #require(SystemDisk.freeBytes(at: dir))
        let total = try #require(SystemDisk.totalBytes(at: dir))
        #expect(free > 0)
        #expect(free <= total)
    }

    /// 不存在的路径读不出容量，返回空值。
    @Test func missingPathDegradesToNil() {
        let missing = URL(fileURLWithPath: "/no/such/volume/\(UUID().uuidString)")
        #expect(SystemDisk.freeBytes(at: missing) == nil)
    }

    /// 探测出的画像里，物理内存必有值，其余三项各自独立可空。
    @Test func probeFillsPhysicalMemoryAndLeavesTheRestOptional() {
        let profile = MachineProbe.current(modelDirectory: FileManager.default.temporaryDirectory)
        #expect(profile.physicalMemory == ProcessInfo.processInfo.physicalMemory)
        #expect(profile.physicalMemory > 0)
        if let cores = profile.performanceCoreCount { #expect(cores >= 1) }
        if let free = profile.freeDiskBytes { #expect(free > 0) }
    }

    /// D12：画像里不存在可用内存这一项。判定不看它，界面也不显示它。
    /// 这条用 Mirror 钉住字段集合，因为「没有某个字段」无法用普通断言表达。
    @Test func profileCarriesNoAvailableMemory() {
        let labels = Mirror(reflecting: MachineProfile(physicalMemory: 1)).children
            .compactMap(\.label)
        #expect(labels == ["physicalMemory", "performanceCoreCount", "freeDiskBytes", "chipName"])
    }
}

/// 线程数按性能核数推导（调研 P2）。本机 M1 Pro 上新旧公式都得 6，运行时观察不到差异，
/// 所以这条只能由单测证明（设计风险三）。
@Suite struct ThreadCountTests {
    @Test func performanceCoresDriveTheThreadCount() {
        // M4 Max 12P+4E：原公式 min(8, 16-2) = 8，空出四个性能核
        #expect(LlamaRuntime.threadCount(performanceCores: 12, activeProcessors: 16) == 12)
        // M1 基础款 4P+4E：原公式 min(8, 8-2) = 6，超过性能核数
        #expect(LlamaRuntime.threadCount(performanceCores: 4, activeProcessors: 8) == 4)
        // M1 Pro 6P+2E：两者都是 6，本机看不出差异
        #expect(LlamaRuntime.threadCount(performanceCores: 6, activeProcessors: 8) == 6)
    }

    @Test func missingPerformanceCoreCountFallsBackToTheOldFormula() {
        #expect(LlamaRuntime.threadCount(performanceCores: nil, activeProcessors: 8) == 6)
        #expect(LlamaRuntime.threadCount(performanceCores: nil, activeProcessors: 16) == 8)
        #expect(LlamaRuntime.threadCount(performanceCores: nil, activeProcessors: 2) == 2)
    }

    /// 上限 8 是原公式那个近似的产物，随它一起去掉。
    @Test func thereIsNoLongerACeilingOfEight() {
        #expect(LlamaRuntime.threadCount(performanceCores: 24, activeProcessors: 32) == 24)
    }

    /// 下限 2 保留：单核机器上给 1 个线程没有意义。
    @Test func atLeastTwoThreads() {
        #expect(LlamaRuntime.threadCount(performanceCores: 1, activeProcessors: 2) == 2)
    }
}
