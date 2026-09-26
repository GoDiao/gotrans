import AppKit
import SwiftUI
import GoTransKit
import KeyboardShortcuts

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case models
    case integrations
    case extensionSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .models: return "模型"
        case .integrations: return "集成"
        case .extensionSettings: return "扩展"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .integrations: return "point.3.connected.trianglepath.dotted"
        case .extensionSettings: return "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .general
    @State private var settings: AppSettings
    @State private var targetForChineseText: String
    @State private var targetDefaultText: String
    @State private var portText: String
    @State private var targetForChineseError: String?
    @State private var targetDefaultError: String?
    @State private var portError: String?
    @State private var switchBlockMessage: String?
    @State private var pendingModelDeletion: ModelCatalogEntry?
    /// 判定为「吃力」时，下载前的一次确认（D7 三、D11）。仅此一个触发条件，不追加体积阈值。
    @State private var pendingStrainedDownload: ModelCatalogEntry?
    /// 磁盘不足时说明原因的提示。磁盘是唯一算得准的信号，所以只有它能真的拦（D7 三）。
    @State private var diskBlockedMessage: String?
    @State private var installed: [InstalledModel] = []
    @State private var appearanceStore = GTAppearanceStore.shared
    @State private var targetForChineseTask: Task<Void, Never>?
    @State private var targetDefaultTask: Task<Void, Never>?
    @State private var portTask: Task<Void, Never>?

    init() {
        let loaded = AppSettings.load()
#if DEBUG
        _selectedSection = State(initialValue: GTDebugScreenshotFixture.settingsSection ?? .general)
#endif
        _settings = State(initialValue: loaded)
        _targetForChineseText = State(initialValue: loaded.targetForChinese)
        _targetDefaultText = State(initialValue: loaded.targetDefault)
        _portText = State(initialValue: String(loaded.port))
    }

    var body: some View {
        ZStack {
            GTContentBackground()
            TabView(selection: $selectedSection) {
                settingsPage(title: "通用", subtitle: "外观、翻译方向和本机性能配置。") {
                    appearanceSection
                    translationSection
                    performanceSection
                }
                .tabItem { Label(SettingsSection.general.title, systemImage: SettingsSection.general.symbol) }
                .tag(SettingsSection.general)

                settingsPage(title: "模型", subtitle: "下载、切换和管理本地模型。",
                             scrolls: false) {
                    runtimeStatusSection
                    modelSection
                }
                .tabItem { Label(SettingsSection.models.title, systemImage: SettingsSection.models.symbol) }
                .tag(SettingsSection.models)

                settingsPage(title: "集成", subtitle: "本地 API、快捷键和 macOS 服务。") {
                    apiSection
                    shortcutsSection
                }
                .tabItem { Label(SettingsSection.integrations.title, systemImage: SettingsSection.integrations.symbol) }
                .tag(SettingsSection.integrations)

                if let title = AppFeatureRegistry.current.settingsTitle {
                    AppFeatureRegistry.current.settingsView()
                        .tabItem { Label(title, systemImage: "slider.horizontal.3") }
                        .tag(SettingsSection.extensionSettings)
                }
            }
            .padding(.top, GTGlassTokens.Space.s)
        }
        .frame(width: GTGlassTokens.Panel.settingsWidth,
               height: GTGlassTokens.Panel.settingsHeight)
        .background(SettingsWindowReader())
        .gtApplicationAppearance()
        .onAppear(perform: reloadSettings)
        .onChange(of: EngineController.shared.engineStatus) { _, _ in refreshInstalledModels() }
        .onChange(of: EngineController.shared.downloadingModelID) { _, _ in refreshInstalledModels() }
        .onDisappear {
            targetForChineseTask?.cancel()
            targetDefaultTask?.cancel()
            portTask?.cancel()
        }
        .alert("无法切换模型", isPresented: Binding(
            get: { switchBlockMessage != nil },
            set: { if !$0 { switchBlockMessage = nil } }
        )) {
            Button("好") { switchBlockMessage = nil }
        } message: {
            Text(switchBlockMessage ?? "")
        }
        .alert("这个模型可能跑得吃力", isPresented: Binding(
            get: { pendingStrainedDownload != nil },
            set: { if !$0 { pendingStrainedDownload = nil } }
        )) {
            Button("取消", role: .cancel) { pendingStrainedDownload = nil }
            Button("仍然下载") { confirmStrainedDownload() }
        } message: {
            Text(strainedConfirmationMessage)
        }
        .alert("磁盘空间不足", isPresented: Binding(
            get: { diskBlockedMessage != nil },
            set: { if !$0 { diskBlockedMessage = nil } }
        )) {
            Button("好") { diskBlockedMessage = nil }
        } message: {
            Text(diskBlockedMessage ?? "")
        }
        .alert("删除模型？", isPresented: Binding(
            get: { pendingModelDeletion != nil },
            set: { if !$0 { pendingModelDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { pendingModelDeletion = nil }
            Button("删除模型", role: .destructive, action: confirmModelDeletion)
        } message: {
            Text(deletionConfirmationMessage)
        }
    }

    /// - Parameter scrolls: 整页滚动。模型页传 `false`——它把滚动交给模型列表自己，
    ///   让机器读数、引擎状态和「本地模型」标题钉在原位。两层 ScrollView 会抢手势，
    ///   所以这两者只能二选一。
    @ViewBuilder
    private func settingsPage<Content: View>(title: String,
                                             subtitle: String,
                                             scrolls: Bool = true,
                                             @ViewBuilder content: () -> Content) -> some View {
        if scrolls {
            scrollingPage(title: title, subtitle: subtitle, content: content)
        } else {
            pageBody(title: title, subtitle: subtitle, content: content)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func scrollingPage<Content: View>(title: String,
                                              subtitle: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            pageBody(title: title, subtitle: subtitle, content: content)
        }
        .gtSoftScrollEdges()
    }

    private func pageBody<Content: View>(title: String,
                                         subtitle: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: GTGlassTokens.Space.l) {
            HStack(spacing: GTGlassTokens.Space.m) {
                Image(systemName: selectedSection.symbol)
                    .font(.title3.weight(.semibold))
                    .frame(width: GTGlassTokens.Icon.chip, height: GTGlassTokens.Icon.chip)
                    .background {
                        RoundedRectangle(cornerRadius: GTGlassTokens.Radius.control,
                                         style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(GTGlassPalette.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, GTGlassTokens.Space.xs)

            content()
        }
        .padding(GTGlassTokens.Space.xl)
        .frame(maxWidth: GTGlassTokens.Panel.settingsWidth)
    }

    private var appearanceSection: some View {
        GTPanelSection(title: "外观") {
            GTPanelField(label: "主题") {
                Picker("主题", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases, id: \.self) { mode in
                        Text(compactAppearanceName(mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 232)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GTPanelDivider()
            GTPanelField(label: "浮窗译文字号", subtitle: "用于划词与剪贴板翻译结果。") {
                HStack(spacing: GTGlassTokens.Space.s) {
                    Slider(value: translationFontSizeBinding,
                           in: AppSettings.minimumTranslationFontSize
                            ... AppSettings.maximumTranslationFontSize,
                           step: 1)
                        .frame(width: 148)
                        .accessibilityLabel("浮窗译文字号")
                        .accessibilityValue("\(Int(settings.translationFontSize)) 点")

                    Text("\(Int(settings.translationFontSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(GTGlassPalette.secondaryText)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private var translationSection: some View {
        GTPanelSection(title: "翻译", subtitle: "配置会在下次模型加载后用于新的翻译任务。") {
            GTSettingsTextFieldRow(label: "中文翻译为",
                                   prompt: "en",
                                   text: $targetForChineseText,
                                   error: targetForChineseError)
                .onChange(of: targetForChineseText) { _, value in
                    scheduleLanguageSave(value, field: .chinese)
                }
            GTPanelDivider()
            GTSettingsTextFieldRow(label: "其他语言翻译为",
                                   prompt: "zh-Hans",
                                   text: $targetDefaultText,
                                   error: targetDefaultError)
                .onChange(of: targetDefaultText) { _, value in
                    scheduleLanguageSave(value, field: .defaultTarget)
                }
        }
    }

    private var performanceSection: some View {
        GTPanelSection(title: "性能", subtitle: "参数配置不会替你选择或下载模型。") {
            GTPanelToggleRow(title: "自动配置参数",
                             subtitle: autoTuningSubtitle,
                             isOn: persistedBinding(\.autoTuning))
            if !settings.autoTuning {
                GTPanelDivider()
                GTPanelField(label: "生成上限") {
                    numberField("生成上限", value: persistedBinding(\.manualMaxTokens))
                }
                GTPanelDivider()
                GTPanelField(label: "输入上限") {
                    numberField("输入上限", value: persistedBinding(\.maxInputChars))
                }
            }
        }
    }

    private var apiSection: some View {
        GTPanelSection(title: "本地 API", subtitle: "PopClip 等外部工具可通过本地服务调用翻译。") {
            GTPanelToggleRow(title: "启用本地 API",
                             subtitle: apiSubtitle,
                             isOn: Binding(
                                get: { EngineController.shared.settings.apiEnabled },
                                set: { enabled in
                                    settings.apiEnabled = enabled
                                    EngineController.shared.setAPIEnabled(enabled)
                                }
                             ))
            GTPanelDivider()
            GTSettingsTextFieldRow(label: "端口",
                                   subtitle: "修改后在下次 API 启动时生效。",
                                   prompt: "8765",
                                   text: $portText,
                                   error: portError,
                                   usesMonospacedDigits: true)
                .onChange(of: portText) { _, value in schedulePortSave(value) }
        }
    }

    private var shortcutsSection: some View {
        GTPanelSection(title: "快捷键", subtitle: "剪贴板快捷键由 app 管理；划词翻译由 macOS 服务管理。") {
            GTPanelRow(title: "翻译剪贴板", subtitle: "先复制，再按快捷键。") {
                KeyboardShortcuts.Recorder("", name: .translateSelection)
                    .labelsHidden()
            }
            GTPanelDivider()
            GTPanelRow(title: "划词翻译", subtitle: "选中文字后按服务快捷键。") {
                HStack(spacing: GTGlassTokens.Space.s) {
                    Text(Self.serviceShortcutGlyphs)
                        .font(.callout.monospaced().weight(.bold))
                        .foregroundStyle(GTGlassPalette.secondaryText)
                    GTSettingsActionButton(title: "系统设置…") {
                        Self.openServicesShortcutSettings()
                    }
                }
            }
            Text("首次使用若按了没反应，请在系统设置的“键盘快捷键 > 服务”中勾选 Translate with GoTrans。")
                .font(.caption)
                .foregroundStyle(GTGlassPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, GTSettingsControlMetrics.rowVerticalPadding)
        }
    }

    /// 机器读数与引擎状态自成一节。它们不是「本地模型」列表里的条目，和模型行框在同一张卡片里
    /// 会读成「这台机器」也是一个可下载的模型。
    private var runtimeStatusSection: some View {
        GTPanelSection(title: "运行状态") {
            machineSignalsRow
            GTPanelDivider()
            engineStatusRow
        }
    }

    private var modelSection: some View {
        let installedIDs = Set(installed.map(\.id))

        return GTPanelSection(
            title: "本地模型",
            subtitle: "下载后选择使用；Hugging Face 不可用时会自动切换 ModelScope。"
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ModelCatalog.entries) { entry in
                        catalogRow(entry, installedIDs: installedIDs)
                        if entry.id != ModelCatalog.entries.last?.id {
                            GTPanelDivider()
                        }
                    }
                }
            }
            .gtSoftScrollEdges()
        }
    }

    /// 节头部那行「依据」：芯片、性能核数、总内存、磁盘剩余（D12、D14）。
    /// **不显示可用内存**（D12）：`free + inactive` 量的是「不做任何动作就能立刻交出去的量」，
    /// 摆在模型体积旁边会让人得出「装不下」的错误结论，而那正是本机制要消除的劝退信号。
    /// 也不再声明「内存判定是估算」（D17）——那句话由每行的「运行约占内存 X%」承担。
    ///
    /// 放成一行普通 row 而不是塞进 `GTPanelSection` 的头部：那个组件只收 `title` 与
    /// `subtitle` 两个字符串，且被五个设置分节共用，为这一处改它不划算。
    private var machineSignalsRow: some View {
        let machine = EngineController.shared.machineProfile
        var parts: [String] = []
        if let chip = machine.chipName { parts.append(chip) }
        if let cores = machine.performanceCoreCount { parts.append("性能核 \(cores)") }
        parts.append("内存 \(ModelFitCopy.formatMemory(machine.physicalMemory))")
        parts.append(machine.freeDiskBytes.map { "磁盘剩余 " + ModelFitCopy.formatBytes($0) }
            ?? "磁盘剩余未知")
        return GTPanelRow(title: "这台机器", subtitle: parts.joined(separator: " · ")) {
            Image(systemName: "cpu").foregroundStyle(GTGlassPalette.secondaryText)
        }
    }

    @ViewBuilder
    private var engineStatusRow: some View {
        switch EngineController.shared.engineStatus {
        case .needsModel(let message):
            GTPanelRow(title: "请选择模型", subtitle: message) {
                Image(systemName: "arrow.down.circle").foregroundStyle(GTGlassPalette.secondaryText)
            }
        case .ready:
            GTPanelRow(title: "引擎状态", subtitle: "就绪 · \(EngineController.shared.activeModelName)") {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GTGlassPalette.semanticReady)
            }
        case .loading(let message):
            GTPanelRow(title: "引擎状态", subtitle: message) { ProgressView().controlSize(.small) }
        case .downloading(let progress):
            GTPanelRow(title: "引擎状态", subtitle: downloadText(progress)) {
                ProgressView(value: progress.fraction).frame(width: 96)
            }
        case .failed(let message):
            GTPanelRow(title: "引擎状态", subtitle: message) {
                GTSettingsActionButton(title: "重试") {
                    EngineController.shared.reload()
                }
            }
        }
    }

    private var isEngineBusy: Bool {
        switch EngineController.shared.engineStatus {
        case .loading, .downloading: return true
        default: return false
        }
    }

    private var apiSubtitle: String {
        switch EngineController.shared.apiStatus {
        case .disabled: return "已关闭。"
        case .running(let port): return "正在 127.0.0.1:\(port) 监听。"
        case .failed(let message): return message
        }
    }

    private var autoTuningSubtitle: String {
        guard settings.autoTuning else { return "使用下面的手动上限，不改变当前模型。" }
        guard let selectedModelID = settings.selectedModelID,
              let entry = ModelCatalog.entry(id: selectedModelID) else {
            return "选择模型后使用该模型的建议参数。"
        }
        return "\(entry.displayName) · 生成上限 \(entry.defaultMaxTokens) tokens · 输入上限 \(entry.defaultMaxInputChars) 字符。"
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding {
            settings.appearance
        } set: { newValue in
            settings.appearance = newValue
            AppSettings.update { $0.appearance = newValue }
            appearanceStore.set(newValue, persist: false)
        }
    }

    private var translationFontSizeBinding: Binding<Double> {
        Binding {
            settings.translationFontSize
        } set: { newValue in
            let normalized = AppSettings.normalizedTranslationFontSize(newValue)
            settings.translationFontSize = normalized
            AppSettings.update { $0.translationFontSize = normalized }
        }
    }

    private func persistedBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding {
            settings[keyPath: keyPath]
        } set: { value in
            settings[keyPath: keyPath] = value
            AppSettings.update { $0[keyPath: keyPath] = value }
        }
    }

    private func catalogRow(_ entry: ModelCatalogEntry, installedIDs: Set<String>) -> some View {
        let ec = EngineController.shared
        let installed = installedIDs.contains(entry.id)
        // 下载错误优先级不变：有错先显示错。没有错时显示判定——体积 · 内存占比 · 档位，
        // 磁盘有话说时再加一段（两条轴都留在这一行里）。
        let verdict = ec.fitVerdict(for: entry.id)
        let subtitleText: Text = {
            if let error = ec.modelDownloadErrors[entry.id] { return Text(error) }
            guard let verdict else { return Text(ModelFitCopy.formatBytes(entry.bytesOnDisk)) }
            return fitSubtitle(verdict)
        }()
        return modelRow(title: entry.displayName,
                        subtitleText: subtitleText,
                        active: installed && ec.selectedModelID == entry.id,
                        installed: installed,
                        downloading: ec.downloadingModelID == entry.id,
                        downloadProgress: ec.downloadProgress,
                        tps: ec.lastTokensPerSecond[entry.id],
                        switchAction: { trySwitchModel(to: entry.id) },
                        downloadAction: { startDownload(entry) },
                        deleteAction: {
                            pendingModelDeletion = entry
                        })
            .help("模型仓库：\(entry.repo)")
    }

    /// 「体积 · 占比 · ● 档位」，档位前面那个点按档位着色：绿=合适、黄=偏紧、红=吃力。
    /// 颜色只是让人一眼分出层次，含义仍由后面那两个字承担——色盲用户读到的东西不少一分。
    private func fitSubtitle(_ verdict: ModelFitVerdict) -> Text {
        // 指示灯前不放「·」：那是两个挨着的圆点，分隔符的活已经由灯本身干了。
        var text = Text(ModelFitCopy.sizeAndShare(for: verdict) + "\u{2002}")
        text = text + Text(Image(systemName: "circle.fill"))
            .font(.system(size: 7))
            .foregroundColor(indicatorColor(for: verdict.memory))
        text = text + Text(" " + ModelFitCopy.label(for: verdict.memory))
        let diskNote = ModelFitCopy.note(for: verdict.disk)
        if !diskNote.isEmpty { text = text + Text(" · " + diskNote) }
        return text
    }

    private func indicatorColor(for fit: ModelMemoryFit) -> Color {
        switch fit {
        case .comfortable: GTGlassPalette.semanticReady
        case .tight: GTGlassPalette.semanticCaution
        case .strained: GTGlassPalette.semanticRed
        }
    }

    private func modelRow(title: String,
                          subtitleText: Text,
                          active: Bool,
                          installed: Bool = true,
                          downloading: Bool = false,
                          downloadProgress: DownloadProgress? = nil,
                          tps: Double? = nil,
                          switchAction: @escaping () -> Void,
                          downloadAction: (() -> Void)? = nil,
                          deleteAction: (() -> Void)? = nil) -> some View {
        GTPanelRow(title: title, subtitleText: subtitleText) {
            modelTrailingSlot {
                if active {
                    HStack(spacing: GTGlassTokens.Space.s) {
                        if let tps {
                            Text(String(format: "%.1f tok/s", tps))
                                .font(.caption)
                                .foregroundStyle(GTGlassPalette.secondaryText)
                                .monospacedDigit()
                        }
                        GTModelStateBadge()
                        modelOverflowPlaceholder
                    }
                } else if downloading {
                    HStack(spacing: GTGlassTokens.Space.s) {
                        ProgressView(value: downloadProgress?.fraction ?? 0)
                            .frame(width: 92)
                        Text("\(Int((downloadProgress?.fraction ?? 0) * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(GTGlassPalette.secondaryText)
                            .frame(width: 34, alignment: .trailing)
                    }
                } else if installed {
                    HStack(spacing: GTGlassTokens.Space.s) {
                        GTSettingsActionButton(title: "使用",
                                               systemImage: "checkmark",
                                               action: switchAction)
                            .disabled(isEngineBusy)
                        if let deleteAction {
                            GTSettingsDestructiveIconButton(title: "删除模型…",
                                                            action: deleteAction)
                            .disabled(isEngineBusy)
                        } else {
                            modelOverflowPlaceholder
                        }
                    }
                } else if let downloadAction {
                    HStack(spacing: GTGlassTokens.Space.s) {
                        GTSettingsActionButton(title: "下载",
                                               systemImage: "arrow.down",
                                               action: downloadAction)
                            .disabled(EngineController.shared.downloadingModelID != nil)
                        modelOverflowPlaceholder
                    }
                }
            }
        }
    }

    private func modelTrailingSlot<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(width: 216,
                   height: GTSettingsControlMetrics.actionHeight,
                   alignment: .trailing)
    }

    private var modelOverflowPlaceholder: some View {
        Color.clear
            .frame(width: GTSettingsControlMetrics.iconSize,
                   height: GTSettingsControlMetrics.iconSize)
            .accessibilityHidden(true)
    }

    /// 点「下载」之后走哪条路，由判定的 `downloadAction` 一处决定，不在这里重新推导。
    /// 三个取值各自的出口都在内核里定义好了，视图只负责接线。
    private func startDownload(_ entry: ModelCatalogEntry) {
        let ec = EngineController.shared
        guard let verdict = ec.fitVerdict(for: entry.id) else {
            ec.downloadModel(id: entry.id)
            return
        }
        switch verdict.downloadAction {
        case .blocked:
            diskBlockedMessage = ModelFitCopy.blockedMessage(for: verdict)
        case .confirmFirst:
            pendingStrainedDownload = entry
        case .proceed:
            ec.downloadModel(id: entry.id)
        }
    }

    private func confirmStrainedDownload() {
        guard let entry = pendingStrainedDownload else { return }
        pendingStrainedDownload = nil
        EngineController.shared.downloadModel(id: entry.id)
    }

    private var strainedConfirmationMessage: String {
        guard let entry = pendingStrainedDownload,
              let verdict = EngineController.shared.fitVerdict(for: entry.id) else { return "" }
        return ModelFitCopy.confirmationMessage(for: verdict, displayName: entry.displayName)
    }

    private var deletionConfirmationMessage: String {
        guard let entry = pendingModelDeletion else { return "" }
        return "将从本机删除“\(entry.displayName)”。需要时可以重新下载。"
    }

    private func confirmModelDeletion() {
        guard let entry = pendingModelDeletion else { return }
        pendingModelDeletion = nil
        EngineController.shared.deleteModel(id: entry.id)
        refreshInstalledModels()
    }

    private func compactAppearanceName(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    private func reloadSettings() {
#if DEBUG
        GTDebugScreenshotFixture.applyFitFixtureIfRequested()
#endif
        let loaded = AppSettings.load()
        settings = loaded
        targetForChineseText = loaded.targetForChinese
        targetDefaultText = loaded.targetDefault
        portText = String(loaded.port)
        refreshInstalledModels()
        appearanceStore.reloadFromDefaults()
    }

    private func refreshInstalledModels() {
        installed = EngineController.shared.installedModels()
        // 磁盘剩余会变，所以在设置页出现时和一次下载完成后重算，不轮询（设计「设置页」）。
        EngineController.shared.refreshModelFits()
    }

    private enum LanguageField { case chinese, defaultTarget }

    private func scheduleLanguageSave(_ value: String, field: LanguageField) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = trimmed.isEmpty ? "语言代码不能为空。" : nil
        switch field {
        case .chinese:
            targetForChineseTask?.cancel()
            targetForChineseError = error
            guard error == nil else { return }
            targetForChineseTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                settings.targetForChinese = trimmed
                AppSettings.update { $0.targetForChinese = trimmed }
            }
        case .defaultTarget:
            targetDefaultTask?.cancel()
            targetDefaultError = error
            guard error == nil else { return }
            targetDefaultTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                settings.targetDefault = trimmed
                AppSettings.update { $0.targetDefault = trimmed }
            }
        }
    }

    private func schedulePortSave(_ value: String) {
        portTask?.cancel()
        guard let number = Int(value), (1...65535).contains(number) else {
            portError = "请输入 1–65535 之间的端口。"
            return
        }
        portError = nil
        portTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            settings.port = UInt16(number)
            AppSettings.update { $0.port = UInt16(number) }
        }
    }

    private func trySwitchModel(to id: String) {
        Task {
            if let block = await EngineController.shared.switchModel(to: id) {
                switchBlockMessage = block.message
            } else {
                settings.selectedModelID = id
            }
        }
    }

    private func numberField(_ label: String, value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
            .monospacedDigit()
            .frame(width: GTSettingsControlMetrics.compactFieldWidth)
    }

    private func downloadText(_ progress: DownloadProgress) -> String {
        let pct = Int(progress.fraction * 100)
        guard let total = progress.totalBytes, let done = progress.completedBytes else {
            return "下载中 \(pct)%"
        }
        // 分子分母同一个十进制口径。此前这里走的是本文件私有的 `Int64` 重载，它的 MB 分支
        // 按 1 048 576 换算却标注 MB，于是下载的前 1.07 GB 里分子偏小——E4B 下到 5 亿字节
        // 时写「476.8 MB / 5.2 GB」，十进制应是 500 MB（I34，I28 漏掉的那一半）。
        return "下载中 \(pct)% · \(ModelFitCopy.formatBytes(UInt64(max(0, done))))"
            + " / \(ModelFitCopy.formatBytes(UInt64(max(0, total))))"
    }

    static var serviceShortcutGlyphs: String {
        guard let services = Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]],
              let keyEq = services.first?["NSKeyEquivalent"] as? [String: String],
              let def = keyEq["default"] else { return "⌥⌘T" }
        var out = ""
        for ch in def {
            switch ch {
            case "@": out += "⌘"
            case "~": out += "⌥"
            case "$": out += "⇧"
            case "^": out += "⌃"
            default: out += String(ch).uppercased()
            }
        }
        return out
    }

    static func openServicesShortcutSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

private struct SettingsWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowProbe {
        let view = SettingsWindowProbe()
        view.onWindowChange = { window in
            guard let window else { return }
            MainWindowController.shared.registerSettingsWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: SettingsWindowProbe, context: Context) {}
}

@MainActor
private final class SettingsWindowProbe: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
