import Foundation

/// `gotrans-cli fit` 的内容层。放在 Kit 而不是 CLI 里，因为 CLI 目标不进单测——
/// 覆盖参数的解析和报告的拼装都在这里，于是「按一台手边没有的机器算」这条路径可以被钉住。
/// 整条路径不联网、不下载（D16）：机器信号来自 sysctl 与卷属性，体积来自编译进来的常量。
public enum ModelFitReport {
    /// 按别的机器计算用的覆盖参数。任一为 nil 表示沿用本机探测值。
    public struct Overrides: Sendable, Equatable {
        public var physicalMemory: UInt64?
        public var performanceCores: Int?
        public var freeDisk: UInt64?

        public init(physicalMemory: UInt64? = nil, performanceCores: Int? = nil,
                    freeDisk: UInt64? = nil) {
            self.physicalMemory = physicalMemory
            self.performanceCores = performanceCores
            self.freeDisk = freeDisk
        }
    }

    public enum OverrideError: Error, Equatable, LocalizedError {
        case missingValue(String)
        case badNumber(String, String)
        case unknownArgument(String)

        public var errorDescription: String? {
            switch self {
            case .missingValue(let flag): "\(flag) 缺少取值"
            case .badNumber(let flag, let text): "\(flag) 的取值无法解析：\(text)"
            case .unknownArgument(let arg): "无法识别的参数：\(arg)"
            }
        }
    }

    /// `--ram` 以 GiB 计（一台「16 GB」的 Mac 就是 16 GiB），`--disk` 以 GB 计
    /// （`df` 和访达显示的都是十进制），`--cores` 是性能核数。
    public static func parseOverrides(_ arguments: [String]) throws -> Overrides {
        var overrides = Overrides()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--json" { index += 1; continue }
            // 先认参数名再取值：反过来的话末尾的未知参数会被报成「缺少取值」，
            // `fit --bogus` 说「--bogus 缺少取值」而不是「无法识别」（I31）。
            guard ["--ram", "--cores", "--disk"].contains(flag) else {
                throw OverrideError.unknownArgument(flag)
            }
            guard index + 1 < arguments.count else { throw OverrideError.missingValue(flag) }
            let raw = arguments[index + 1]
            switch flag {
            case "--ram":
                guard let gib = Double(raw), gib > 0 else { throw OverrideError.badNumber(flag, raw) }
                overrides.physicalMemory = UInt64(gib * 1_073_741_824)
            case "--cores":
                guard let n = Int(raw), n > 0 else { throw OverrideError.badNumber(flag, raw) }
                overrides.performanceCores = n
            case "--disk":
                guard let gb = Double(raw), gb >= 0 else { throw OverrideError.badNumber(flag, raw) }
                overrides.freeDisk = UInt64(gb * 1_000_000_000)
            default:
                throw OverrideError.unknownArgument(flag)   // 上面的 guard 已排除，留作穷尽
            }
            index += 2
        }
        return overrides
    }

    /// 覆盖参数直接构造画像，走的是与设置页、与单测完全相同的那条路径——
    /// 不为「按别的机器算」另开一个口子。
    public static func apply(_ overrides: Overrides, to base: MachineProfile) -> MachineProfile {
        MachineProfile(
            physicalMemory: overrides.physicalMemory ?? base.physicalMemory,
            performanceCoreCount: overrides.performanceCores ?? base.performanceCoreCount,
            freeDiskBytes: overrides.freeDisk ?? base.freeDiskBytes,
            chipName: overrides.physicalMemory == nil && overrides.performanceCores == nil
                ? base.chipName : nil    // 覆盖之后芯片名不再属实，不如不写
        )
    }

    public static func text(
        machine: MachineProfile, entries: [ModelCatalogEntry] = ModelCatalog.entries
    ) -> String {
        // 头部只留机器读数一行。原先还有一句「内存判定是估算：落盘体积 × 1.25……」，
        // 用户在验收走查时判为「太诚实了，没有任何必要」，整句删（D17）。
        // 这不推翻 D15：那份义务欠的是下一个维护者，他读的是 ModelFitEvaluator 上的注释。
        // 界面对估算的提示留在每行的「运行**约**占内存 X%」里。
        var lines: [String] = []
        lines.append("机器：" + machineSummary(machine))
        lines.append("")
        for entry in entries {
            let verdict = ModelFitEvaluator.evaluate(entry: entry, machine: machine)
            lines.append("\(entry.displayName)")
            lines.append("  \(ModelFitCopy.subtitle(for: verdict))")
            lines.append("  下载：\(actionText(verdict.downloadAction))")
        }
        return lines.joined(separator: "\n")
    }

    public static func json(
        machine: MachineProfile, entries: [ModelCatalogEntry] = ModelCatalog.entries
    ) throws -> String {
        var machineObject: [String: Any] = ["physicalMemoryBytes": machine.physicalMemory]
        machineObject["performanceCores"] = machine.performanceCoreCount
        machineObject["freeDiskBytes"] = machine.freeDiskBytes
        machineObject["chip"] = machine.chipName

        let models: [[String: Any]] = entries.map { entry in
            let verdict = ModelFitEvaluator.evaluate(entry: entry, machine: machine)
            return [
                "id": entry.id,
                "displayName": entry.displayName,
                "repo": entry.repo,
                "purpose": entry.purpose.rawValue,
                "bytesOnDisk": verdict.bytesOnDisk,
                "estimatedRuntimeBytes": verdict.estimatedRuntimeBytes,
                "memoryShare": verdict.memoryShare,
                "memoryFit": verdict.memory.rawValue,
                "diskFit": verdict.disk.rawValue,
                "downloadAction": verdict.downloadAction.rawValue,
                "subtitle": ModelFitCopy.subtitle(for: verdict),
            ]
        }
        let root: [String: Any] = [
            "machine": machineObject,
            "runtimeMemoryFactor": ModelFitEvaluator.runtimeMemoryFactor,
            // 消费方要能看出这个系数没有实测支撑（D15）
            "runtimeMemoryFactorIsAgreedReferenceValue": true,
            "models": models,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func machineSummary(_ machine: MachineProfile) -> String {
        var parts = [String]()
        if let chip = machine.chipName { parts.append(chip) }
        if let cores = machine.performanceCoreCount { parts.append("性能核 \(cores)") }
        parts.append("内存 \(ModelFitCopy.formatMemory(machine.physicalMemory))")
        parts.append(machine.freeDiskBytes.map { "磁盘剩余 " + ModelFitCopy.formatBytes($0) }
            ?? "磁盘剩余未知")
        return parts.joined(separator: " · ")
    }

    static func actionText(_ action: ModelDownloadAction) -> String {
        switch action {
        case .proceed: return "直接开始"
        case .confirmFirst: return "先确认一次"
        case .blocked: return "不发起，磁盘空间不足"
        }
    }
}
