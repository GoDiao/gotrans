import Foundation

public struct ResolvedModel: Sendable, Equatable {
    public let entry: ModelCatalogEntry
    public let tuning: EngineTuning
}

public enum ActiveModelResolver {
    public static func resolve(
        selectedID: String,
        parameterSettings: AppSettings = AppSettings()
    ) -> ResolvedModel? {
        guard let entry = ModelCatalog.entry(id: selectedID) else { return nil }
        // 显式选择只决定模型；参数自动配置使用 entry 建议值，关闭后使用用户手动上限。
        let maxTokens = parameterSettings.autoTuning
            ? entry.defaultMaxTokens
            : parameterSettings.manualMaxTokens
        let maxInputChars = parameterSettings.autoTuning
            ? entry.defaultMaxInputChars
            : parameterSettings.maxInputChars
        let tuning = EngineTuning(maxTokens: maxTokens, maxInputChars: maxInputChars)
        return ResolvedModel(entry: entry, tuning: tuning)
    }
}
