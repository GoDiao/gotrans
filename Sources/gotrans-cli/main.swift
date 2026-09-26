import Foundation
import GoTransKit
import GoTransServer

// 重定向到文件/管道时 print 默认块缓冲，"Model ready" 等状态行会滞留不可见
setvbuf(stdout, nil, _IOLBF, 0)

/// 「download: 35% (1.2/3.4 GB)」；字节未知（HF 宏路径）时只打百分比
func printDownloadProgress(_ p: DownloadProgress) {
    let pct = Int(p.fraction * 100)
    if let done = p.completedBytes, let total = p.totalBytes {
        let bytes = String(format: "%.1f/%.1f GB", Double(done) / 1e9, Double(total) / 1e9)
        print("download: \(pct)% (\(bytes))", terminator: "\r")
    } else {
        print("download: \(pct)%", terminator: "\r")
    }
}

// 注意：MLX 的 Metal 着色器无法用 `swift build` 编译，本 CLI 需经 xcodebuild 构建：
//   xcodebuild -scheme gotrans-cli -destination 'platform=macOS' -skipMacroValidation build
let settings = AppSettings.load()
let mode = CommandLine.arguments.dropFirst().first ?? "serve"

switch mode {
case "serve":
    // 模型取自用户在设置里选中的那个，与 app 同源（EngineController.start）。
    // 没选过就不猜：隐式下载几个 G 正是这个项目要消除的东西。
    guard let selectedID = settings.selectedModelID,
          let resolved = ActiveModelResolver.resolve(
            selectedID: selectedID, parameterSettings: settings) else {
        print("尚未选择模型。先在 GoTrans 设置里选一个，或用 gotrans-cli engine-translate <model-id> <cache-dir>。")
        exit(2)
    }
    let engine = TranslationEngine(settings: settings)
    print("Loading \(resolved.entry.displayName)…")
    do {
        try await engine.load(resolved: resolved) { p in
            printDownloadProgress(p)
        }
    } catch {
        print("模型加载失败: \(error)")
        exit(1)
    }
    print("Model ready. Listening on http://127.0.0.1:\(settings.port)")
    let api = APIServer(translator: engine, port: settings.port)
    try await api.run()
case "download":
    // 把指定 catalog 模型下载到指定目录并验证可加载（含预热）。原名 download-e2b，
    // 是 iOS 真机配套、硬编码 E2B 档；iOS 已从仓库删除（RULES.md），档位覆盖也随
    // ModelVariant 一起消失，于是它退化成「按 id 下载到指定目录」这件仍然有用的事。
    // 第三个参数选下载源：hf（HuggingFace）| ms（ModelScope，默认，国内可达且支持断点续传）。
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 2 else {
        print("usage: gotrans-cli download <model-id> <cache-dir> [hf|ms]")
        exit(2)
    }
    guard let resolved = ActiveModelResolver.resolve(
        selectedID: args[0], parameterSettings: settings) else {
        print("unknown model id: \(args[0])")
        exit(2)
    }
    let source: ModelSource
    switch args.count >= 3 ? args[2] : "ms" {
    case "hf": source = .huggingFace
    case "ms": source = .modelScope
    default:
        print("usage: gotrans-cli download <model-id> <cache-dir> [hf|ms]")
        exit(2)
    }
    let engine = TranslationEngine(settings: settings)
    do {
        try await engine.load(
            resolved: resolved,
            cacheDirectory: URL(fileURLWithPath: args[1]),
            modelSource: source
        ) { p in
            printDownloadProgress(p)
        }
        print("\n\(resolved.entry.displayName) 下载完成且已验证可加载（含预热）：\(args[1])")
    } catch {
        print("DOWNLOAD FAILED: \(error)")
        exit(1)
    }
case "fit":
    // 不下载任何模型，就打印这台机器（或任意一台指定的机器）对全表的判定。
    // 全程只读 sysctl 与卷属性，体积是编译进来的常量，因此断网可用（D16）。
    let args = Array(CommandLine.arguments.dropFirst(2))
    let overrides: ModelFitReport.Overrides
    do {
        overrides = try ModelFitReport.parseOverrides(args)
    } catch {
        print((error as? LocalizedError)?.errorDescription ?? "\(error)")
        print("usage: gotrans-cli fit [--ram <GiB>] [--cores <N>] [--disk <GB>] [--json]")
        exit(2)
    }
    let machine = ModelFitReport.apply(overrides, to: MachineProbe.current())
    if args.contains("--json") {
        do {
            print(try ModelFitReport.json(machine: machine))
        } catch {
            print("JSON 输出失败: \(error)")
            exit(1)
        }
    } else {
        print(ModelFitReport.text(machine: machine))
    }
case "hunyuan-spike":
    // Plan A 决策门：注册混元类型 → 从本地目录加载 Hy-MT2 → 跑一次生成，人工核对输出。
    let args = CommandLine.arguments.dropFirst(2)
    guard let dir = args.first else {
        print("usage: gotrans-cli hunyuan-spike <model-dir> [text]")
        exit(2)
    }
    let text = args.dropFirst().first
        ?? "Translate the following Chinese into English:\n今天天气很好，我们一起去公园散步吧。"
    let clock = ContinuousClock()
    do {
        let t0 = clock.now
        print("--- output ---")
        let out = try await hunyuanSpikeTranslate(
            modelDir: URL(fileURLWithPath: dir), text: text)
        print("--- hunyuan-spike done in \(clock.now - t0), \(out.count) chars ---")
    } catch {
        print("HUNYUAN-SPIKE FAILED: \(error)")
        exit(1)
    }
case "engine-translate":
    // Plan C 验证：走正式引擎路径（load(resolved:) + translate）测某 catalog 模型的端到端翻译。
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 2 else {
        print("usage: gotrans-cli engine-translate <model-id> <cache-dir> [text]")
        exit(2)
    }
    guard let resolved = ActiveModelResolver.resolve(
        selectedID: args[0], parameterSettings: settings) else {
        print("unknown model id: \(args[0])")
        exit(2)
    }
    let engine = TranslationEngine(settings: settings)
    do {
        try await engine.load(
            resolved: resolved,
            cacheDirectory: URL(fileURLWithPath: args[1]),
            modelSource: .modelScope
        ) { p in printDownloadProgress(p) }
        let text = args.count >= 3 ? args[2] : "今天天气很好，我们一起去公园散步吧。"
        print("\n--- translate via engine (purpose=\(resolved.entry.purpose.rawValue)) ---")
        let result = try await engine.translate(text, target: nil)
        for try await chunk in result.chunks { print(chunk, terminator: "") }
        print("\n--- engine-translate OK (detected=\(result.detected) target=\(result.target)) ---")
    } catch {
        print("ENGINE-TRANSLATE FAILED: \(error)")
        exit(1)
    }
default:
    print("""
usage: gotrans-cli <command>
  fit [--ram <GiB>] [--cores <N>] [--disk <GB>] [--json]
                                                 打印全表判定，不下载任何东西
  serve                                          默认。按设置里选中的模型起本地 API
  engine-translate <model-id> <cache-dir> [text] 按 id 加载并翻译一次
  download <model-id> <cache-dir> [hf|ms]        下载指定模型到指定目录
  hunyuan-spike <model-dir> [text]               不经引擎，直接跑一次混元生成
""")
    exit(2)
}
