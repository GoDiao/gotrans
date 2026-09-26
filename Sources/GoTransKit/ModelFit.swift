import Foundation

/// 内存档位。三档，不打分——第一版只回答「装不装得下」，不回答「哪个更好」（D7）。
/// 阈值直接采用 llmfit 的规则（D9），分母是**总内存**，不加固定工作余量：60% 那条线本身
/// 就承担了系统与其他应用的余量。
public enum ModelMemoryFit: String, Sendable, CaseIterable {
    /// 运行时需求 ≤ 总内存的 60%
    case comfortable
    /// 60% < 需求 ≤ 85%
    case tight
    /// > 85%。llmfit 的 Marginal 与 Too Tight 合并到这一档——对用户而言「装得进但很勉强」
    /// 和「根本装不进」要做的事是同一件：看清数字再决定。
    case strained
}

/// 磁盘状态。与内存档位是**两条正交的轴**（D7 四、评审 I19）：磁盘不足的条目仍然有内存档位，
/// 那一行照样把占比显示出来。
public enum ModelDiskFit: String, Sendable, CaseIterable {
    case sufficient
    case insufficient
    /// 剩余空间读不到。缺数据不构成拒绝的理由，因此不拦下载。
    case unknown
}

/// 点下载会发生什么。每个 (内存档位 × 磁盘状态) 组合都必须落到这三个值之一——
/// 没有出口的取值就是这个类型存在的理由。
public enum ModelDownloadAction: String, Sendable, CaseIterable {
    /// 直接开始下载
    case proceed
    /// 先弹一次确认，把数字摊开（D7 三、D11）。仅「吃力」触发，不追加体积阈值。
    case confirmFirst
    /// 不发起下载。只有磁盘算得准，所以只有它能真的拦（D7 三）。
    case blocked
}

/// 一次判定的结果，连同作出该判断所依据的数字，调用方直接渲染而不必重算。
public struct ModelFitVerdict: Sendable, Equatable {
    public let memory: ModelMemoryFit
    public let disk: ModelDiskFit
    /// 落盘体积（catalog 常量，D16）
    public let bytesOnDisk: UInt64
    /// 估算的运行时内存需求。由落盘体积推导，**不是 catalog 字段**（评审 I20）。
    public let estimatedRuntimeBytes: UInt64
    /// 运行时需求 ÷ 总内存
    public let memoryShare: Double
    /// 判定时读到的剩余磁盘空间；nil 表示读不到
    public let freeDiskBytes: UInt64?

    /// 点下载会发生什么。两条轴合流的唯一出口：磁盘说了算在先，内存只警告。
    public var downloadAction: ModelDownloadAction {
        switch disk {
        case .insufficient: return .blocked
        case .sufficient, .unknown:
            return memory == .strained ? .confirmFirst : .proceed
        }
    }

    /// 下载前该不该弹确认框。按 D11 这是验收第 3 条的唯一覆盖方式，所以它必须是独立可测的
    /// 谓词，而不是埋在按钮动作里。
    public var needsConfirmationBeforeDownload: Bool { downloadAction == .confirmFirst }
}

public enum ModelFitEvaluator {
    /// 「落盘体积 → 运行时内存需求」的换算系数。
    ///
    /// **这是一个约定的参考值，不是实测结论**（D15）。取值依据：llama.cpp 侧实测
    /// 721 MB / 573 MiB = 1.26，llmfit 对 Gemma E4B 给出 6.35 / 5.2 = 1.22，取中。
    ///
    /// 局限，写在这里免得下一个人以为它有数据支撑：llmfit 自己的这个比值并不是常数——
    /// 同一次实测里 E2B 是 1.97 / 1.2 = 1.64（评审 I22）。成因是运行时 ≈ 权重 + KV cache，
    /// 而 KV 不随权重等比缩放，所以单一乘数对小模型系统性偏低。MLX 侧则完全没有实测数据。
    ///
    /// 接受这一点的前提是**推荐只提醒、从不阻止下载**（D7、D11）：判错的代价是一条不准的
    /// 提示，不是一次被拦下的操作。**若将来产品语义变成「会阻止」，这个系数必须先被实测取代。**
    static let runtimeMemoryFactor = 1.25

    /// 纯函数：没有初始化器、没有状态、不读单例、不做 I/O，也不联网（D16）。
    /// 因此可全表单测，也可以按一台手边没有的机器计算。
    public static func evaluate(entry: ModelCatalogEntry, machine: MachineProfile)
        -> ModelFitVerdict
    {
        let runtime = UInt64((Double(entry.bytesOnDisk) * runtimeMemoryFactor).rounded())
        let share = Double(runtime) / Double(machine.physicalMemory)
        let memory: ModelMemoryFit
        if share <= 0.60 {
            memory = .comfortable
        } else if share <= 0.85 {
            memory = .tight
        } else {
            memory = .strained
        }
        let disk: ModelDiskFit
        switch machine.freeDiskBytes {
        case .none: disk = .unknown
        case .some(let free): disk = free >= entry.bytesOnDisk ? .sufficient : .insufficient
        }
        return ModelFitVerdict(
            memory: memory,
            disk: disk,
            bytesOnDisk: entry.bytesOnDisk,
            estimatedRuntimeBytes: runtime,
            memoryShare: share,
            freeDiskBytes: machine.freeDiskBytes
        )
    }
}
