#if DEBUG
import AppKit
import Foundation
import GoTransKit

/// Deterministic, Debug-only fixtures used to capture App Store screenshots
/// without enabling accessibility automation or changing production behavior.
@MainActor
enum GTDebugScreenshotFixture {
    static let scene: String? = {
        if let environmentValue = ProcessInfo.processInfo.environment["GOTRANS_SCREENSHOT_SCENE"] {
            return environmentValue
        }
        if let defaultsValue = UserDefaults(suiteName: "com.godiao.GoTrans.app")?
            .string(forKey: "debugScreenshotScene"),
           !defaultsValue.isEmpty {
            return defaultsValue
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--screenshot-scene"),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        return arguments[flagIndex + 1]
    }()

    static let mainInput = "真正好的工具不会打断工作，而是在需要时安静地出现。"
    static let mainOutput = "Great tools don’t interrupt your work; they simply appear quietly when needed."
    static let panelOutput = "Great tools don’t interrupt your flow. They simply appear, quietly, when you need them."

    static var isMain: Bool { scene == "main" }
    static var isPanel: Bool { scene == "panel" }

    static var settingsSection: SettingsSection? {
        guard let scene, scene.hasPrefix("settings-") else { return nil }
        return SettingsSection(rawValue: String(scene.dropFirst("settings-".count)))
    }

    /// 判定态的渲染夹具。「偏紧」「吃力」和磁盘不足态在任何一台能装 GoTrans 的机器上都不会
    /// 出现——吃力要求落盘 > 5.84 GB（8 GiB 的 85%），catalog 最大的 E4B 是 5.18 GB，而
    /// `ARCHS: arm64` 排除了 Intel（D19）。不喂一个假画像，就没有人能在用户之前看过它们。
    ///
    /// `GOTRANS_FIT_FIXTURE=tiers | nodisk | unknown-disk`
    static var fitProfile: MachineProfile? {
        switch ProcessInfo.processInfo.environment["GOTRANS_FIT_FIXTURE"] {
        case "tiers":
            // 6 GiB：E4B 落「吃力」、E2B 落「偏紧」、其余「合适」——三档同屏。
            // 芯片名留空，因为内存被覆盖之后它已经不属实了。
            return MachineProfile(physicalMemory: 6 << 30, performanceCoreCount: 6,
                                  freeDiskBytes: 500_000_000_000, chipName: nil)
        case "nodisk":
            // 真实内存 + 只剩 1 GB：四个大条目落「磁盘空间不足」，两个 GGUF 仍然够。
            return MachineProfile(physicalMemory: 16 << 30, performanceCoreCount: 6,
                                  freeDiskBytes: 1_000_000_000, chipName: "Apple M1 Pro")
        case "unknown-disk":
            return MachineProfile(physicalMemory: 16 << 30, performanceCoreCount: 6,
                                  freeDiskBytes: nil, chipName: "Apple M1 Pro")
        default:
            return nil
        }
    }

    @MainActor
    static func applyFitFixtureIfRequested() {
        guard let profile = fitProfile else { return }
        EngineController.shared.overrideMachineProfile(profile)
    }

    private static var didScheduleCapture = false

    static func captureIfRequested(window: NSWindow, matching requestedScene: String) {
        guard scene == requestedScene,
              !didScheduleCapture,
              let outputPath = ProcessInfo.processInfo.environment["GOTRANS_SCREENSHOT_PATH"]
        else { return }
        didScheduleCapture = true

        Task { @MainActor in
            if let appearanceName = ProcessInfo.processInfo.environment["GOTRANS_SCREENSHOT_APPEARANCE"],
               let appearance = NSAppearance(
                named: appearanceName == "light" ? .aqua : .darkAqua
               ) {
                NSApp.appearance = appearance
                window.appearance = appearance
                window.contentView?.appearance = appearance
                window.contentView?.needsDisplay = true
            }
            try? await Task.sleep(for: .seconds(1))
            window.displayIfNeeded()
            guard let contentView = window.contentView else { return }
            var captureView = contentView
            while let superview = captureView.superview {
                captureView = superview
            }
            captureView.layoutSubtreeIfNeeded()
            // 走视图自己的绘制路径，而不是 `layer?.render(in:)` 遍历图层树。后者抓不到
            // TabView 选中态图标的画法，截出来是一块纯白方块（I33）——而这个夹具的用途
            // 正是出 App Store 截图。`bitmapImageRepForCachingDisplay` 自己按 backing
            // scale 配好位图，不必再手搭一个并手动 scaleBy。
            guard let bitmap = captureView.bitmapImageRepForCachingDisplay(
                in: captureView.bounds) else { return }
            captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            NSApp.terminate(nil)
        }
    }
}
#endif
