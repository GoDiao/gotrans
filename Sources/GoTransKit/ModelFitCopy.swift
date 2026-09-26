import Foundation

/// 档位到界面文案的转换。是**另一个纯函数**，放在 Kit 而不是视图里，照 `PanelGeometry` 的
/// 先例——这样「5.2 GB · 运行约占内存 38% · 合适」这句话本身可单测，而 `App/` 那 4004 行
/// 无测试的现状不被扩大。界面字符串是硬编码中文，本仓库没有本地化基础设施（RULES.md）。
public enum ModelFitCopy {
    /// 字节数的十进制口径，与两份 README 的模型表一致。
    /// 不用 1 MiB / 1 GiB：`README.md` 与 `RULES.md` 写的是十进制，用户在 Hugging Face 上
    /// 看到的也是十进制，两套并用只会让同一个模型出现两个体积。
    ///
    /// **六行都不带「约」**（D18）。此前只有 MB 分支拼「约」，于是「5.2 GB」与「约 462 MB」
    /// 并排——而 MB 分支那两条恰是全表唯一被 revision 钉死、字节精确的条目，会随 `tree/main`
    /// 漂移的是 GB 分支那四条，不确定的标记正好打反了。措辞取齐之后，界面对估算的唯一提示
    /// 落在「运行**约**占内存 X%」那一段上。
    public static func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1_000_000_000 {
            return "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
        }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// 内存容量的二进制口径。装机内存一律按 2^30 报——一台「16 GB」的 Mac，
    /// `hw.memsize` 是 17 179 869 184，按十进制印出来是「17.2 GB」，没人这样称呼自己的机器。
    /// 模型体积走 `formatBytes` 的十进制口径，因为那是 Hugging Face 与两份 README 的口径。
    /// 两个口径各自对应一件不同的东西，不要合并。
    public static func formatMemory(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        return gib < 10
            ? String(format: "%.1f GB", gib)
            : "\(Int(gib.rounded())) GB"
    }

    public static func label(for fit: ModelMemoryFit) -> String {
        switch fit {
        case .comfortable: return "合适"
        case .tight: return "偏紧"
        case .strained: return "吃力"
        }
    }

    /// 磁盘状态在行内的附注。空字符串表示这一行不必说什么。
    ///
    /// 行内只说**这一行与别的行不同**的地方；关于这台机器的事实归头部。
    /// `.insufficient` 是逐条目的——同一台机器上大的放不下、小的放得下，所以要写进行里。
    /// `.unknown` 不是：读不到剩余空间是机器层面的状况，六行会一模一样地重复六遍，
    /// 而头部那行已经写着「磁盘剩余未知」。渲染夹具把这一屏拉出来看过之后改成不写。
    public static func note(for fit: ModelDiskFit) -> String {
        switch fit {
        case .sufficient, .unknown: return ""
        case .insufficient: return "磁盘空间不足"
        }
    }

    /// subtitle 的前两段：体积 · 内存占比。档位单独给出来，是因为设置页要在它前面放一个
    /// 有颜色的指示灯，需要分段着色；命令行不分段，仍用下面那条整串。
    public static func sizeAndShare(for verdict: ModelFitVerdict) -> String {
        "\(formatBytes(verdict.bytesOnDisk)) · 运行约占内存 \(percent(verdict.memoryShare))"
    }

    /// 设置页每行的 subtitle：体积 · 内存占比 · 档位，磁盘有话说时再加一段。
    /// 两条轴都留在这一行里——磁盘不足不会把内存档位挤掉（评审 I19）。
    public static func subtitle(for verdict: ModelFitVerdict) -> String {
        // 与 `sizeAndShare` 共用前两段，免得设置页和命令行各拼一套、日子久了拼出两个样子。
        var parts = [sizeAndShare(for: verdict), label(for: verdict.memory)]
        let diskNote = note(for: verdict.disk)
        if !diskNote.isEmpty { parts.append(diskNote) }
        return parts.joined(separator: " · ")
    }

    /// 「吃力」确认框的正文。摊开数字让用户自己决定，这是它存在的全部理由（D7 三）。
    /// **不放可用内存**（D12）：一个既吓人又不准的数，放在一个本意是「让你敢决定」的对话框
    /// 里是反着用的。
    public static func confirmationMessage(
        for verdict: ModelFitVerdict, displayName: String
    ) -> String {
        "\(displayName) 落盘 \(formatBytes(verdict.bytesOnDisk))，运行时预计占用约 "
            + "\(formatBytes(verdict.estimatedRuntimeBytes))，约为本机内存的 "
            + "\(percent(verdict.memoryShare))。内存占用是估算值，实际可能有出入。仍然下载？"
    }

    /// 磁盘不足时说明原因，并给出还差多少。
    public static func blockedMessage(for verdict: ModelFitVerdict) -> String {
        guard let free = verdict.freeDiskBytes, free < verdict.bytesOnDisk else {
            return "磁盘剩余空间不足，无法下载。"
        }
        return "磁盘剩余 \(formatBytes(free))，这个模型需要 \(formatBytes(verdict.bytesOnDisk))，"
            + "还差 \(formatBytes(verdict.bytesOnDisk - free))。清理后再试。"
    }

    static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}
