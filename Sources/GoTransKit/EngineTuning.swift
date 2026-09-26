import Foundation

/// 引擎的生成参数。由 `ActiveModelResolver` 从 catalog 条目的建议值或用户的手动上限产出。
/// 「该用哪个模型」不在这里——那是用户显式选择的结果，见 `AppSettings.selectedModelID`。
public struct EngineTuning: Sendable, Equatable {
    public let maxTokens: Int       // 单次生成上限
    public let maxInputChars: Int

    public init(maxTokens: Int, maxInputChars: Int) {
        self.maxTokens = maxTokens
        self.maxInputChars = maxInputChars
    }
}
