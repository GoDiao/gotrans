import Testing
@testable import GoTransKit

struct TranslationPromptTests {
    /// 拆 `ModelFamily` 当时就在表里的六条。这两条用例断言的是「拆分没有改变任何既有条目的
    /// 行为」，所以主语只能是那六条——阶段二加入的模型没有「拆分前」可言，不属于这个论断。
    private let formerlyGemma: Set<String> = ["gemma-e4b-4bit", "gemma-e2b-4bit"]
    private var existedBeforeTheSplit: Set<String> {
        formerlyGemma.union(["hymt2-4bit", "hymt2-8bit", "hymt2-1.25bit", "hymt2-2bit"])
    }

    @Test func defaultProviderKeepsTheExistingModelTemplates() {
        for usesSystemPrompt in [true, false] {
            let request = TranslationPromptRequest(
                text: "Hello", detected: "en", target: "zh-Hans",
                usesSystemPrompt: usesSystemPrompt)
            #expect(request.defaultPrompt.user == PromptBuilder.userPrompt(text: "Hello", target: "zh-Hans"))
            #expect(request.defaultPrompt.system
                == (usesSystemPrompt ? PromptBuilder.systemPrompt : nil))
        }
    }
    /// 拆开 `ModelFamily` 之后，逐条目走一遍真实的 prompt 产出，而不只是断言那个布尔。
    /// 拆分前是 `family == .gemma` 决定发不发 system prompt；结果必须逐条相同（设计风险四）。
    @Test func everyCatalogEntryKeepsItsFormerSystemPromptDecision() {
        for entry in ModelCatalog.entries where existedBeforeTheSplit.contains(entry.id) {
            let request = TranslationPromptRequest(
                text: "Hello", detected: "en", target: "zh-Hans",
                usesSystemPrompt: entry.usesSystemPrompt)
            let expected = formerlyGemma.contains(entry.id) ? PromptBuilder.systemPrompt : nil
            #expect(request.defaultPrompt.system == expected, "\(entry.id)")
        }
    }

    /// 通用处理的准入只看用途这一条轴；翻译专用模型仍然被拒。
    @Test func generalProcessingIsGatedByPurposeAlone() {
        #expect(ModelPurpose.generalPurpose.allowsGeneralProcessing)
        #expect(!ModelPurpose.translationOnly.allowsGeneralProcessing)
        for entry in ModelCatalog.entries where existedBeforeTheSplit.contains(entry.id) {
            #expect(entry.purpose.allowsGeneralProcessing == formerlyGemma.contains(entry.id),
                    "\(entry.id)")
        }
    }

    @Test func contextBudgetIncludesOutputAndAcceptsExactBoundary() throws {
        try TranslationPromptBudget.validate(inputTokens: 3072, outputTokens: 1024, contextTokens: 4096)
        #expect(throws: TranslationError.self) {
            try TranslationPromptBudget.validate(inputTokens: 3073, outputTokens: 1024, contextTokens: 4096)
        }
        #expect(throws: TranslationError.self) {
            try TranslationPromptBudget.validate(inputTokens: Int.max, outputTokens: 1024, contextTokens: 4096)
        }
    }
}
