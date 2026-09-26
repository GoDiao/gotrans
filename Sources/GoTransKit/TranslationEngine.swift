import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

public actor TranslationEngine: TranslationService {
    private let settings: AppSettings
    private let promptProvider: (any TranslationPromptProvider)?
    private var modelContextTokens = 4096
    private var model: ModelContainer?
    private var llamaRuntime: LlamaRuntime?
    private var lastGeneration: Task<Void, Never>?
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    private var acceptingGeneration = true
    private let detector = LanguageDetector()
    private var resolvedTuning: EngineTuning?
    /// 当前活跃模型的 catalog 条目。prompt 策略、通用处理准入、架构注册各读它的一个属性，
    /// 三者互不蕴含。未加载时的取值不可达——translate 与 process 都先要求模型已就绪。
    private var activeEntry: ModelCatalogEntry?

    private var activeUsesSystemPrompt: Bool { activeEntry?.usesSystemPrompt ?? true }
    private var activeAllowsGeneralProcessing: Bool {
        activeEntry.map(\.purpose.allowsGeneralProcessing) ?? true
    }

    /// 上一次生成的速度（生成 token 数 / 生成耗时），供 UI 观察性能；nil 表示尚无生成。
    public private(set) var lastTokensPerSecond: Double?

    /// 设置页展示用（actor 属性，外部 await 访问）
    public var currentTuning: EngineTuning? { resolvedTuning }

    /// 是否有生成正在排队或进行（去抖用：避免热键连按在串行队列里堆积，导致可见浮窗长时间挨饿）
    public var isGenerating: Bool { !generationTasks.isEmpty }

    public init(settings: AppSettings, promptProvider: (any TranslationPromptProvider)? = nil) {
        self.settings = settings
        self.promptProvider = promptProvider
    }

    public var isReady: Bool { model != nil || llamaRuntime != nil }

    /// 加载指定 ResolvedModel（按 entry.repo 下载/加载，按 entry.architecture 分发）。
    /// 所有既有调用方（EngineController / EngineHolder / CLI）继续使用旧签名，两者互不影响。
    /// - Parameter resolved: 已解析的模型条目 + 调优参数（由 ActiveModelResolver 产出）。
    /// - Parameter cacheDirectory: 非 nil 时走自研 ModelDownloader（iOS/CLI）；nil 时走 macOS 默认目录。
    ///   两者都是：新快照完整则本地加载，否则自研下载器下载后加载。
    /// - Parameter modelSource: 可选固定下载源；nil 时 Hugging Face 优先、失败自动回退 ModelScope。
    /// - Parameter useCPU: spike 用；true 时切 MLX 全局默认设备到 CPU。
    /// - Parameter progress: 下载进度回调。
    public func load(
        resolved: ResolvedModel,
        cacheDirectory: URL? = nil,
        modelSource: ModelSource? = nil,
        useCPU: Bool = false,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws {
        if useCPU {
            MLX.Device.setDefault(device: MLX.Device(.cpu))
            GTLog.info("[spike-cpu] MLX device set to CPU")
        }
        resolvedTuning = resolved.tuning
        activeEntry = resolved.entry
        GTLog.info("load(resolved:) entry=\(resolved.entry.id) repo=\(resolved.entry.repo) " +
                   "purpose=\(resolved.entry.purpose.rawValue)")

        let repo = resolved.entry.repo
        let base = cacheDirectory ?? Self.defaultModelDirectory()
        let snapshotDir = ModelDownloader.snapshotDirectory(in: base, repo: repo)

        if case .llamaGGUF(let quantization) = resolved.entry.backend {
            if !ModelDownloader.isComplete(snapshotDir, for: resolved.entry) {
                _ = try await ModelDownloader.download(
                    entry: resolved.entry,
                    from: modelSource,
                    into: base,
                    progress: progress
                )
            }
            guard let fileURL = ModelDownloader.modelFileURL(
                in: snapshotDir, for: resolved.entry) else {
                throw TranslationError.modelNotSupported("模型目录缺少固定 GGUF 文件信息")
            }
            let runtime = LlamaRuntime()
            try await runtime.load(fileURL: fileURL, quantization: quantization)
            try await runtime.warmup()
            model = nil
            llamaRuntime = runtime
            acceptingGeneration = true
            GTLog.info("llama model loaded+warmed: \(resolved.entry.id)")
            return
        }

        if !ModelDownloader.isComplete(snapshotDir, for: resolved.entry) {
            _ = try await ModelDownloader.download(
                entry: resolved.entry, from: modelSource, into: base, progress: progress)
        }

        let loaded: ModelContainer
        switch resolved.entry.architecture {
        case .builtIn:
            loaded = try await loadModelContainer(
                from: snapshotDir,
                using: #huggingFaceTokenizerLoader()
            )
        case .hunyuan:
            // 混元架构不在 Swift MLXLLM 内置类型表，加载前注册自定义类型（幂等）。
            await registerHunyuanIfNeeded()
            loaded = try await loadModelContainer(from: snapshotDir, using: #huggingFaceTokenizerLoader())
        }

        try await finishLoading(loaded, label: resolved.entry.repo)
    }

    /// 传给 chat template 的 kwargs，用来关掉模板的思考分支。
    ///
    /// Qwen3.5 两款的 `chat_template.jinja` 默认开着 think（`enable_thinking is defined and
    /// enable_thinking is false` 才是关），不传这个参数的话每次划词都会先思考一轮、推理过程
    /// 直接流进浮窗（D26）。上游把 `additionalContext` 当 kwargs 传进
    /// `tokenizer.applyChatTemplate`（`LLMModelFactory.swift:495`），是支持的路径不是绕路。
    ///
    /// `process()` 那条本可以不传——文本助手正是 think 更有用的地方——但它目前零生产调用方
    /// （D3 把入口推后了），留一个没人见过的分歧行为不如先统一。D3 的入口回来时这条要重新问
    /// 用户，那才是真正的产品决策时点（D27，临时决定）。
    private static let templateContext: [String: any Sendable] = ["enable_thinking": false]

    /// 预热 + 置 ready + 回收缓冲。两个 load 入口共用。
    private func finishLoading(_ container: ModelContainer, label: String) async throws {
        // 预热：首次生成触发 Metal 内核编译（冷启可超 30s，曾致首单超时 500）。
        // 在置 ready 前用 1-token 生成把编译做完，用户首单即快。
        let warmup = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 1))
        _ = try? await warmup.respond(to: "hi")
        let directory = try await container.modelDirectory
        let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        let textConfiguration = configuration?["text_config"] as? [String: Any] ?? configuration
        modelContextTokens = textConfiguration?["max_position_embeddings"] as? Int ?? 4096
        model = container
        llamaRuntime = nil
        acceptingGeneration = true
        // 预热（1-token 生成）留下的临时缓冲在置 ready 后立即回收，让初始空闲态就精简；
        // 权重已在 model 中常驻，clearCache 不动它。
        MLX.Memory.clearCache()
        GTLog.info("mlx model loaded+warmed: \(label), " +
                   "active(权重)\(MLX.Memory.activeMemory >> 20)MB cache\(MLX.Memory.cacheMemory >> 20)MB")
    }

    public func translate(_ text: String, target: String?) async throws -> TranslationStreamResult {
        guard acceptingGeneration, model != nil || llamaRuntime != nil else {
            throw TranslationError.modelNotLoaded
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyInput }

        let maxChars = resolvedTuning?.maxInputChars ?? settings.maxInputChars
        let truncated = trimmed.count > maxChars
        let input = truncated ? String(trimmed.prefix(maxChars)) : trimmed
        let plan = detector.plan(for: input, target: target, settings: settings)
        let request = TranslationPromptRequest(text: input, detected: plan.detected,
                                               target: plan.target,
                                               usesSystemPrompt: activeUsesSystemPrompt)
        let composed = try promptProvider?.prompt(for: request) ?? request.defaultPrompt
        let prompt = composed.user
        let maxTokens = resolvedTuning?.maxTokens ?? 2048
        if let llamaRuntime {
            try await llamaRuntime.validatePrompt(prompt, maxTokens: maxTokens)
            guard acceptingGeneration, self.llamaRuntime === llamaRuntime else {
                throw TranslationError.modelNotLoaded
            }
            return makeLlamaTranslation(
                runtime: llamaRuntime,
                prompt: prompt,
                detected: plan.detected,
                target: plan.target,
                truncated: truncated,
                maxTokens: maxTokens
            )
        }
        guard let model else { throw TranslationError.modelNotLoaded }
        // Gemma 用固定系统指令；Hy-MT2 按推荐只发 user 指令（无 system）。
        // 先 capture 到局部，避免下面的 Task 闭包访问 actor 隔离的状态。
        let instructions = activeUsesSystemPrompt ? composed.system : nil
        let contextTokens = modelContextTokens
        let inputTokens = try await model.perform { context in
            var messages: [Chat.Message] = []
            if let instructions { messages.append(.system(instructions)) }
            messages.append(.user(prompt))
            let prepared = try await context.processor.prepare(
                input: UserInput(chat: messages, additionalContext: Self.templateContext))
            return prepared.text.tokens.size
        }
        try TranslationPromptBudget.validate(inputTokens: inputTokens, outputTokens: maxTokens,
                                             contextTokens: contextTokens)
        guard acceptingGeneration, self.model === model else { throw TranslationError.modelNotLoaded }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let generationID = UUID()
        let previous = lastGeneration
        let generationTask = Task {
            await previous?.value  // 串行：GPU 单飞，等上一个生成自然结束
            defer { self.generationFinished(id: generationID) }
            do {
                try Task.checkCancellation()
                // 每次翻译一次性会话：无历史、系统指令固定
                // 翻译是确定性任务：默认温度 0.6 的采样随机性会偶尔走到「复述原文/跑偏」，
                // 降到 0.1（近贪心）让模型确定性遵循翻译指令。repetitionPenalty 抑制小模型复读。
                let session = ChatSession(
                    model,
                    instructions: instructions,
                    generateParameters: GenerateParameters(
                        maxTokens: maxTokens, temperature: 0.1, repetitionPenalty: 1.1),
                    additionalContext: Self.templateContext
                )
                for try await item in session.streamDetails(to: prompt, images: [], videos: []) {
                    try Task.checkCancellation()
                    switch item {
                    case .chunk(let text):
                        continuation.yield(text)
                    case .info(let info):
                        lastTokensPerSecond = info.tokensPerSecond
                        GTLog.info("mlx gen: \(info.generationTokenCount) tok, " +
                            String(format: "%.2fs, %.1f tok/s", info.generateTime, info.tokensPerSecond))
                    case .toolCall:
                        break
                    }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                GTLog.error("generation failed: \(error)")
                continuation.finish(throwing: error)
            }
        }
        generationTasks[generationID] = generationTask
        lastGeneration = generationTask
        continuation.onTermination = { @Sendable [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancelGeneration(id: generationID) }
        }
        return TranslationStreamResult(
            detected: plan.detected, target: plan.target, truncated: truncated, chunks: stream
        )
    }

    private func makeLlamaTranslation(
        runtime: LlamaRuntime,
        prompt: String,
        detected: String,
        target: String,
        truncated: Bool,
        maxTokens: Int
    ) -> TranslationStreamResult {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let generationID = UUID()
        let previous = lastGeneration
        let generationTask = Task {
            await previous?.value
            defer { self.generationFinished(id: generationID) }
            do {
                try Task.checkCancellation()
                let metrics = try await runtime.generate(
                    userPrompt: prompt,
                    maxTokens: maxTokens,
                    onChunk: { continuation.yield($0) }
                )
                lastTokensPerSecond = metrics.tokensPerSecond
                GTLog.info("llama gen: \(metrics.generatedTokens) tok, " +
                    String(
                        format: "first %.2fs total %.2fs %.1f tok/s",
                        metrics.firstTokenSeconds,
                        metrics.totalSeconds,
                        metrics.tokensPerSecond
                    ))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                GTLog.error("llama generation failed: \(error)")
                continuation.finish(throwing: error)
            }
        }
        generationTasks[generationID] = generationTask
        lastGeneration = generationTask
        continuation.onTermination = { @Sendable [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancelGeneration(id: generationID) }
        }
        return TranslationStreamResult(
            detected: detected,
            target: target,
            truncated: truncated,
            chunks: stream
        )
    }

    /// 一次性 process 会话：按 instruction 处理 text，返回聚合结果。
    /// 复用串行队列、maxTokens 与翻译相同的 temperature/repetitionPenalty。
    /// 输入按 resolvedTuning.maxInputChars 截断；不走 LanguageDetector。
    public func process(_ text: String, instruction: String) async throws -> String {
        guard acceptingGeneration, model != nil || llamaRuntime != nil else {
            throw TranslationError.modelNotLoaded
        }
        // 通用文本处理只在通用模型（Gemma）上可靠；Hy-MT2 是翻译专用，喂任意指令易出烂结果，
        // 直接拒绝而非静默跑偏（采纳 Codex 审查）。
        guard activeAllowsGeneralProcessing else {
            throw TranslationError.modelNotSupported("当前为翻译专用模型，不支持通用文本处理，请切换到 Gemma")
        }
        guard let model else { throw TranslationError.modelNotLoaded }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyInput }

        let maxChars = resolvedTuning?.maxInputChars ?? settings.maxInputChars
        let input = trimmed.count > maxChars ? String(trimmed.prefix(maxChars)) : trimmed
        let prompt = PromptBuilder.processUserPrompt(text: input, instruction: instruction)
        let maxTokens = resolvedTuning?.maxTokens ?? 2048
        let instructions = activeUsesSystemPrompt ? PromptBuilder.processSystemPrompt : nil

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let generationID = UUID()
        let previous = lastGeneration
        let generationTask = Task {
            await previous?.value
            defer { self.generationFinished(id: generationID) }
            do {
                try Task.checkCancellation()
                let session = ChatSession(
                    model,
                    instructions: instructions,
                    generateParameters: GenerateParameters(
                        maxTokens: maxTokens, temperature: 0.1, repetitionPenalty: 1.1),
                    additionalContext: Self.templateContext
                )
                for try await item in session.streamDetails(to: prompt, images: [], videos: []) {
                    try Task.checkCancellation()
                    switch item {
                    case .chunk(let text):
                        continuation.yield(text)
                    case .info(let info):
                        lastTokensPerSecond = info.tokensPerSecond
                        GTLog.info("mlx process: \(info.generationTokenCount) tok, " +
                            String(format: "%.2fs, %.1f tok/s", info.generateTime, info.tokensPerSecond))
                    case .toolCall:
                        break
                    }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                GTLog.error("process generation failed: \(error)")
                continuation.finish(throwing: error)
            }
        }
        generationTasks[generationID] = generationTask
        lastGeneration = generationTask
        continuation.onTermination = { @Sendable [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancelGeneration(id: generationID) }
        }
        var out = ""
        for try await chunk in stream { out += chunk }
        try Task.checkCancellation()
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelGeneration(id: UUID) {
        generationTasks[id]?.cancel()
    }

    private func generationFinished(id: UUID) {
        generationTasks[id] = nil
        // 队列真正排空才回收：连续/排队生成（含 API 串行链）中途任务表不为空，
        // 故不会清掉马上要复用的缓冲、不抖动。clearCache 只把没人引用的空闲缓冲池
        // （上一轮 KV cache/激活那部分工作余量）还给系统，不碰被 model 强引用的权重。
        if generationTasks.isEmpty, model != nil {
            let beforeMB = MLX.Memory.cacheMemory >> 20
            MLX.Memory.clearCache()
            GTLog.info("mlx idle reclaim: cache \(beforeMB)MB→\(MLX.Memory.cacheMemory >> 20)MB, " +
                       "active(权重)\(MLX.Memory.activeMemory >> 20)MB")
        }
    }

    /// 暴露默认模型目录给 App 层（EngineController.deleteModel / installedModels 用）
    public static func defaultModelBase() -> URL { defaultModelDirectory() }

    /// 卸载当前模型并回收工作余量缓冲（切换模型前调用）。
    /// 权重被 model 强引用；置 nil 后 ARC 释放，clearCache 再回收空闲缓冲池余量。
    public func unload() async {
        acceptingGeneration = false
        let hadMLXModel = model != nil
        let tasks = Array(generationTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        generationTasks.removeAll()
        lastGeneration = nil
        model = nil
        if let llamaRuntime {
            await llamaRuntime.unload()
            self.llamaRuntime = nil
        }
        if hadMLXModel {
            MLX.Memory.clearCache()
        }
        GTLog.info("translation model unloaded (switch)")
    }

    /// macOS 默认模型目录：~/Library/Application Support/GoTrans/models（自动建目录）
    private static func defaultModelDirectory() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoTrans/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
