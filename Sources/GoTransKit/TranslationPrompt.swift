import Foundation

public struct TranslationPromptRequest: Sendable {
    public let text: String
    public let detected: String
    public let target: String
    public let usesSystemPrompt: Bool

    public init(text: String, detected: String, target: String, usesSystemPrompt: Bool) {
        self.text = text
        self.detected = detected
        self.target = target
        self.usesSystemPrompt = usesSystemPrompt
    }

    public var defaultPrompt: TranslationPrompt {
        TranslationPrompt(system: usesSystemPrompt ? PromptBuilder.systemPrompt : nil,
                          user: PromptBuilder.userPrompt(text: text, target: target))
    }
}

public struct TranslationPrompt: Sendable, Equatable {
    public let system: String?
    public let user: String

    public init(system: String?, user: String) {
        self.system = system
        self.user = user
    }
}

/// Read an immutable customization snapshot synchronously, before a request joins the generation
/// queue. Implementations must be thread-safe; UI changes affect subsequent requests only.
public protocol TranslationPromptProvider: Sendable {
    func prompt(for request: TranslationPromptRequest) throws -> TranslationPrompt?
}

public enum TranslationPromptBudget {
    public static func validate(inputTokens: Int, outputTokens: Int, contextTokens: Int) throws {
        guard inputTokens >= 0, outputTokens > 0, contextTokens > 0,
              outputTokens < contextTokens, inputTokens <= contextTokens - outputTokens else {
            throw TranslationError.promptTooLong
        }
    }
}
