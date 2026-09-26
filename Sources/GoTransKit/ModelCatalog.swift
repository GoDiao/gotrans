import Foundation

/// 模型用途：能不能拿它做通用文本处理，而不只是翻译。
/// 同一个事实有两个消费方——`process()` 的准入，以及设置页要展示的元数据。
/// 它们是不是同一个事实目前是**推断**而不是已验证的等价：`process()` 当前全仓库零调用方
/// （D3 把文本助手入口推后），要等阶段二引入通用模型、入口回来时才真正被检验（评审 Q-b）。
public enum ModelPurpose: String, Sendable {
    case translationOnly
    case generalPurpose

    /// 通用文本处理的准入。`process()` 的那道门就是这一条，抽成属性是为了能脱离已加载的
    /// 引擎单测——`process()` 自身先要求模型就绪，够不到这道门。
    public var allowsGeneralProcessing: Bool { self == .generalPurpose }
}

/// 模型架构：只决定加载前要不要向 MLXLLM 注册它内置类型表里没有的自定义类型。
/// 与用途、prompt 策略无关——一款内置架构的通用模型和一款自定义架构的翻译模型都是合法组合。
enum ModelArchitecture: Sendable, Equatable {
    case builtIn
    case hunyuan
}

enum GGUFQuantization: Sendable, Equatable {
    case stq1_0
    case q2_0c
}

enum ModelBackend: Sendable, Equatable {
    case mlx
    case llamaGGUF(GGUFQuantization)
}

struct SingleFileDistribution: Sendable, Equatable {
    let fileName: String
    let huggingFaceRevision: String
    let modelScopeRevision: String
    let bytes: Int64
    let sha256: String
}

enum ModelDistribution: Sendable, Equatable {
    case repositorySnapshot
    case singleFile(SingleFileDistribution)
}

public struct ModelCatalogEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let repo: String
    public let purpose: ModelPurpose
    /// 发不发 system prompt。Gemma 用 system + user；Hy-MT2（混元）按其推荐格式只发 user
    /// 指令、不用 system（spike 验证：无 system 译文最稳）。
    let usesSystemPrompt: Bool
    let architecture: ModelArchitecture
    /// 落盘体积，Hugging Face tree API 实算值（下载器跳过的 .gitattributes / README.md /
    /// configuration.json 量级可忽略，E2B 实测差 2 163 字节）。
    /// 按 D16 实算是「写代码时做一次」的动作，结果以常量落进仓库；运行时不查 tree API，
    /// 判定路径因此断网可用。代价是上游提交后常量会漂移，应对办法是写入时就准确。
    public let bytesOnDisk: UInt64
    public let defaultMaxTokens: Int
    public let defaultMaxInputChars: Int
    let backend: ModelBackend
    let distribution: ModelDistribution

    init(
        id: String,
        displayName: String,
        repo: String,
        purpose: ModelPurpose,
        usesSystemPrompt: Bool,
        architecture: ModelArchitecture,
        bytesOnDisk: UInt64,
        defaultMaxTokens: Int,
        defaultMaxInputChars: Int,
        backend: ModelBackend = .mlx,
        distribution: ModelDistribution = .repositorySnapshot
    ) {
        self.id = id
        self.displayName = displayName
        self.repo = repo
        self.purpose = purpose
        self.usesSystemPrompt = usesSystemPrompt
        self.architecture = architecture
        self.bytesOnDisk = bytesOnDisk
        self.defaultMaxTokens = defaultMaxTokens
        self.defaultMaxInputChars = defaultMaxInputChars
        self.backend = backend
        self.distribution = distribution
    }
}

public enum ModelCatalog {
    public static let entries: [ModelCatalogEntry] = [
        ModelCatalogEntry(id: "gemma-e4b-4bit", displayName: "Gemma 4 E4B (4-bit)",
            repo: "mlx-community/gemma-4-e4b-it-4bit",
            purpose: .generalPurpose, usesSystemPrompt: true, architecture: .builtIn,
            bytesOnDisk: 5_179_241_512, defaultMaxTokens: 2048, defaultMaxInputChars: 1500),
        ModelCatalogEntry(id: "gemma-e2b-4bit", displayName: "Gemma 4 E2B (4-bit)",
            repo: "mlx-community/gemma-4-e2b-it-4bit",
            purpose: .generalPurpose, usesSystemPrompt: true, architecture: .builtIn,
            bytesOnDisk: 3_583_088_661, defaultMaxTokens: 1024, defaultMaxInputChars: 700),
        ModelCatalogEntry(id: "hymt2-4bit", displayName: "Hy-MT2 1.8B (4-bit · 翻译专用)",
            repo: "mlx-community/Hy-MT2-1.8B-4bit",
            purpose: .translationOnly, usesSystemPrompt: false, architecture: .hunyuan,
            bytesOnDisk: 1_021_371_026, defaultMaxTokens: 1024, defaultMaxInputChars: 1500),
        ModelCatalogEntry(id: "hymt2-8bit", displayName: "Hy-MT2 1.8B (8-bit · 翻译专用)",
            repo: "mlx-community/Hy-MT2-1.8B-8bit",
            purpose: .translationOnly, usesSystemPrompt: false, architecture: .hunyuan,
            bytesOnDisk: 1_916_841_510, defaultMaxTokens: 1024, defaultMaxInputChars: 1500),
        ModelCatalogEntry(
            id: "hymt2-1.25bit",
            displayName: "Hy-MT2 1.8B（1.25-bit · 轻量版）",
            repo: "AngelSlim/Hy-MT2-1.8B-1.25Bit-GGUF",
            purpose: .translationOnly,
            usesSystemPrompt: false,
            architecture: .hunyuan,
            bytesOnDisk: 461_860_800,
            defaultMaxTokens: 1024,
            defaultMaxInputChars: 1500,
            backend: .llamaGGUF(.stq1_0),
            distribution: .singleFile(SingleFileDistribution(
                fileName: "Hy-MT2-1.8B-1.25bit-v2.gguf",
                huggingFaceRevision: "0989912c0cc2d3edeeecd76171d1c7d94ee17255",
                modelScopeRevision: "2d3896c601bb165415669c31e8cf43c2554e7900",
                bytes: 461_860_800,
                sha256: "13a33fc4f72d5c92c439a65fd343696de4ccd0485bca84de2712bc0d8cc4e773"
            ))
        ),
        ModelCatalogEntry(
            id: "hymt2-2bit",
            displayName: "Hy-MT2 1.8B（2-bit · 均衡版）",
            repo: "AngelSlim/Hy-MT2-1.8B-2Bit-GGUF",
            purpose: .translationOnly,
            usesSystemPrompt: false,
            architecture: .hunyuan,
            bytesOnDisk: 600_534_976,
            defaultMaxTokens: 1024,
            defaultMaxInputChars: 1500,
            backend: .llamaGGUF(.q2_0c),
            distribution: .singleFile(SingleFileDistribution(
                fileName: "Hy-MT2-1.8B-2bit-v2.gguf",
                huggingFaceRevision: "2245b9ea2bdd68a67b21b44db9564e7d32fc3bc6",
                modelScopeRevision: "6689e68668273c14fb5a45bd04ffe12e0601077b",
                bytes: 600_534_976,
                sha256: "ae35b1ee4e4a12011e8105d5e7e2bd10f0c4b4e09320367274922184c0831c95"
            ))
        ),
        ModelCatalogEntry(id: "qwen35-4b-4bit", displayName: "Qwen3.5 4B (4-bit)",
            repo: "mlx-community/Qwen3.5-4B-MLX-4bit",
            purpose: .generalPurpose, usesSystemPrompt: true, architecture: .builtIn,
            bytesOnDisk: 3_061_132_920, defaultMaxTokens: 2048, defaultMaxInputChars: 1500),
        ModelCatalogEntry(id: "qwen35-9b-4bit", displayName: "Qwen3.5 9B (4-bit)",
            repo: "mlx-community/Qwen3.5-9B-MLX-4bit",
            purpose: .generalPurpose, usesSystemPrompt: true, architecture: .builtIn,
            bytesOnDisk: 5_977_074_591, defaultMaxTokens: 2048, defaultMaxInputChars: 1500),
    ]

    public static func entry(id: String) -> ModelCatalogEntry? {
        entries.first { $0.id == id }
    }
}
