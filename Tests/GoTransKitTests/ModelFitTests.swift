import Testing
import Foundation
@testable import GoTransKit

@Suite struct ModelFitTests {
    private func machine(gib: UInt64, freeDisk: UInt64? = .max) -> MachineProfile {
        MachineProfile(physicalMemory: gib << 30, performanceCoreCount: 6, freeDiskBytes: freeDisk)
    }
    private func entry(_ id: String) -> ModelCatalogEntry { ModelCatalog.entry(id: id)! }

    /// 全表 × 四个内存规格。这组用例同时是验收第 5 条（CLI 按 8 / 32 / 48 GiB 覆盖计算）的
    /// 自动化版本——CLI 的覆盖参数和这里走的是同一条路径，人工那一遍是在确认接线。
    /// 期望值按「落盘实算 × 1.25 ÷ 总内存」手算，与设计「代入现有 catalog 的结果」一致。
    @Test func tierTableAcrossMachineSizes() {
        let expected: [String: [UInt64: ModelMemoryFit]] = [
            "hymt2-1.25bit": [8: .comfortable, 16: .comfortable, 32: .comfortable, 48: .comfortable],
            "hymt2-2bit":    [8: .comfortable, 16: .comfortable, 32: .comfortable, 48: .comfortable],
            "hymt2-4bit":    [8: .comfortable, 16: .comfortable, 32: .comfortable, 48: .comfortable],
            "hymt2-8bit":    [8: .comfortable, 16: .comfortable, 32: .comfortable, 48: .comfortable],
            "gemma-e2b-4bit": [8: .comfortable, 16: .comfortable, 32: .comfortable, 48: .comfortable],
            // E4B 在 8 GiB 上 75.4%，偏紧
            "gemma-e4b-4bit": [8: .tight, 16: .comfortable, 32: .comfortable, 48: .comfortable],
            "qwen35-4b-4bit": [8: .comfortable, 16: .comfortable, 32: .comfortable, 48: .comfortable],
            // 9B 是全表第一个在真实受支持机型上落「吃力」的条目：8 GiB 上 87.0%（D26）
            "qwen35-9b-4bit": [8: .strained, 16: .comfortable, 32: .comfortable, 48: .comfortable],
        ]
        #expect(Set(expected.keys) == Set(ModelCatalog.entries.map(\.id)))
        for e in ModelCatalog.entries {
            for (gib, fit) in expected[e.id]! {
                let verdict = ModelFitEvaluator.evaluate(entry: e, machine: machine(gib: gib))
                #expect(verdict.memory == fit, "\(e.id) @ \(gib)GiB → \(verdict.memory)")
            }
        }
    }

    /// 设计表里的百分比逐格复核（8 / 16 / 32 GiB，保留一位小数）。
    @Test func memorySharesMatchTheDesignTable() {
        let expected: [String: [UInt64: Double]] = [
            "hymt2-1.25bit": [8: 6.7, 16: 3.4, 32: 1.7],
            "hymt2-2bit":    [8: 8.7, 16: 4.4, 32: 2.2],
            "hymt2-4bit":    [8: 14.9, 16: 7.4, 32: 3.7],
            "hymt2-8bit":    [8: 27.9, 16: 13.9, 32: 7.0],
            "gemma-e2b-4bit": [8: 52.1, 16: 26.1, 32: 13.0],
            "gemma-e4b-4bit": [8: 75.4, 16: 37.7, 32: 18.8],
            "qwen35-4b-4bit": [8: 44.5, 16: 22.3, 32: 11.1],
            "qwen35-9b-4bit": [8: 87.0, 16: 43.5, 32: 21.7],
        ]
        for e in ModelCatalog.entries {
            for (gib, pct) in expected[e.id]! {
                let got = ModelFitEvaluator.evaluate(entry: e, machine: machine(gib: gib))
                    .memoryShare * 100
                #expect(abs(got - pct) < 0.05, "\(e.id) @ \(gib)GiB → \(got)")
            }
        }
    }

    /// 恰好落在 60% 与 85% 上时归哪一档。D9 的写法是 ≤60 合适、60–85 偏紧、>85 吃力，
    /// 所以两条线本身都归上一档。
    @Test func boundariesBelongToTheLowerTier() {
        // 总内存 10e9；落盘 × 1.25 = 运行需求，倒推出恰好命中边界的落盘体积
        let total: UInt64 = 10_000_000_000
        func fit(shareTarget: Double) -> ModelMemoryFit {
            let runtime = Double(total) * shareTarget
            let onDisk = UInt64((runtime / ModelFitEvaluator.runtimeMemoryFactor).rounded())
            let e = ModelCatalogEntry(
                id: "probe", displayName: "probe", repo: "o/r",
                purpose: .translationOnly, usesSystemPrompt: false, architecture: .builtIn,
                bytesOnDisk: onDisk, defaultMaxTokens: 1, defaultMaxInputChars: 1)
            return ModelFitEvaluator.evaluate(
                entry: e,
                machine: MachineProfile(physicalMemory: total, freeDiskBytes: .max)).memory
        }
        #expect(fit(shareTarget: 0.60) == .comfortable)
        #expect(fit(shareTarget: 0.6000001) == .tight)
        #expect(fit(shareTarget: 0.85) == .tight)
        #expect(fit(shareTarget: 0.8500001) == .strained)
    }

    /// 两条轴彼此独立：磁盘不足不会抹掉内存档位，内存吃力也不会改变磁盘判定。
    @Test func memoryAndDiskAreIndependentAxes() {
        let e4b = entry("gemma-e4b-4bit")
        let noRoom = ModelFitEvaluator.evaluate(
            entry: e4b, machine: machine(gib: 32, freeDisk: 1_000_000))
        #expect(noRoom.disk == .insufficient)
        #expect(noRoom.memory == .comfortable)          // 磁盘不足，内存档位照样有值
        #expect(noRoom.memoryShare > 0)

        let tightButRoomy = ModelFitEvaluator.evaluate(
            entry: e4b, machine: machine(gib: 8, freeDisk: .max))
        #expect(tightButRoomy.memory == .tight)
        #expect(tightButRoomy.disk == .sufficient)
    }

    /// 剩余空间读不到时不拦下载——缺数据不构成拒绝的理由。
    @Test func unknownDiskDoesNotBlock() {
        let v = ModelFitEvaluator.evaluate(
            entry: entry("gemma-e4b-4bit"), machine: machine(gib: 16, freeDisk: nil))
        #expect(v.disk == .unknown)
        #expect(v.downloadAction == .proceed)
    }

    /// **每个档位值 × 每个磁盘状态值都有已定义的界面表现与下载行为。**
    /// 没有出口的取值就是这条用例存在的理由。
    @Test func everyAxisCombinationHasARenderingAndADownloadAction() {
        for memory in ModelMemoryFit.allCases {
            #expect(!ModelFitCopy.label(for: memory).isEmpty, "\(memory) 没有文案")
        }
        // 行内只说这一行与别的行不同的地方。`.insufficient` 是逐条目的（同一台机器上大的放不下、
        // 小的放得下），所以必须写进行里；`.sufficient` 与 `.unknown` 不写——前者无话可说，
        // 后者是机器层面的状况，六行重复六遍没有意义，头部已经写着「磁盘剩余未知」。
        #expect(!ModelFitCopy.note(for: .insufficient).isEmpty)
        #expect(ModelFitCopy.note(for: .sufficient).isEmpty)
        #expect(ModelFitCopy.note(for: .unknown).isEmpty)
        var seen: Set<ModelDownloadAction> = []
        for memory in ModelMemoryFit.allCases {
            for disk in ModelDiskFit.allCases {
                let v = ModelFitVerdict(
                    memory: memory, disk: disk, bytesOnDisk: 1_000_000_000,
                    estimatedRuntimeBytes: 1_250_000_000, memoryShare: 0.5,
                    freeDiskBytes: disk == .unknown ? nil : 1)
                seen.insert(v.downloadAction)
                #expect(!ModelFitCopy.subtitle(for: v).isEmpty, "\(memory)/\(disk) 没有 subtitle")
                switch (memory, disk) {
                case (_, .insufficient): #expect(v.downloadAction == .blocked)
                case (.strained, _): #expect(v.downloadAction == .confirmFirst)
                default: #expect(v.downloadAction == .proceed)
                }
            }
        }
        #expect(seen == Set(ModelDownloadAction.allCases), "有下载行为取值从未被任何组合产生")
    }

    /// 「该不该弹确认框」只对「吃力」为真，且不追加落盘体积阈值（D11）。
    @Test func confirmationIsForTheStrainedTierAlone() {
        for memory in ModelMemoryFit.allCases {
            let v = ModelFitVerdict(
                memory: memory, disk: .sufficient, bytesOnDisk: 5_179_241_512,
                estimatedRuntimeBytes: 6_474_051_890, memoryShare: 0.9, freeDiskBytes: .max)
            #expect(v.needsConfirmationBeforeDownload == (memory == .strained), "\(memory)")
        }
        // 本机 16 GiB 上六个条目全是「合适」，确认框一个也不会弹——这正是它必须由单测覆盖的原因
        for e in ModelCatalog.entries {
            let v = ModelFitEvaluator.evaluate(entry: e, machine: machine(gib: 16))
            #expect(!v.needsConfirmationBeforeDownload, "\(e.id)")
        }
    }

    /// 运行时需求是推导值，不是 catalog 字段（评审 I20）。
    @Test func runtimeRequirementIsDerivedNotStored() {
        let labels = Mirror(reflecting: entry("gemma-e4b-4bit")).children.compactMap(\.label)
        #expect(!labels.contains { $0.lowercased().contains("runtime") })
        #expect(labels.contains("bytesOnDisk"))
        let v = ModelFitEvaluator.evaluate(entry: entry("gemma-e4b-4bit"), machine: machine(gib: 16))
        #expect(v.estimatedRuntimeBytes
            == UInt64((Double(5_179_241_512) * ModelFitEvaluator.runtimeMemoryFactor).rounded()))
    }

    /// 文案含体积、内存占比、档位三段；十进制口径与两份 README 一致。
    @Test func subtitleCarriesSizeShareAndTier() {
        let v = ModelFitEvaluator.evaluate(entry: entry("gemma-e4b-4bit"), machine: machine(gib: 16))
        #expect(ModelFitCopy.subtitle(for: v) == "5.2 GB · 运行约占内存 38% · 合适")

        let small = ModelFitEvaluator.evaluate(entry: entry("hymt2-1.25bit"), machine: machine(gib: 16))
        #expect(ModelFitCopy.subtitle(for: small) == "462 MB · 运行约占内存 3% · 合适")

        let noRoom = ModelFitEvaluator.evaluate(
            entry: entry("gemma-e4b-4bit"), machine: machine(gib: 16, freeDisk: 1_000_000_000))
        #expect(ModelFitCopy.subtitle(for: noRoom)
            == "5.2 GB · 运行约占内存 38% · 合适 · 磁盘空间不足")

        // 剩余空间读不到是机器层面的事，行内不重复六遍
        let unknownDisk = ModelFitEvaluator.evaluate(
            entry: entry("gemma-e4b-4bit"), machine: machine(gib: 16, freeDisk: nil))
        #expect(ModelFitCopy.subtitle(for: unknownDisk) == "5.2 GB · 运行约占内存 38% · 合适")
    }

    /// 设置页把档位单独拿出来着色，所以前两段有独立的访问器；它和整串 subtitle 不能各走各的。
    @Test func theSegmentedAccessorAgreesWithTheWholeSubtitle() {
        for entry in ModelCatalog.entries {
            for gib in [UInt64(8), 16, 32] {
                let v = ModelFitEvaluator.evaluate(entry: entry, machine: machine(gib: gib))
                #expect(ModelFitCopy.subtitle(for: v)
                    .hasPrefix(ModelFitCopy.sizeAndShare(for: v) + " · "), "\(entry.id)")
            }
        }
        let v = ModelFitEvaluator.evaluate(entry: entry("gemma-e4b-4bit"), machine: machine(gib: 16))
        #expect(ModelFitCopy.sizeAndShare(for: v) == "5.2 GB · 运行约占内存 38%")
    }

    /// 确认框不出现可用内存这个词（D12），并且摊开了体积与占用。
    @Test func confirmationMessageShowsNumbersAndNoAvailableMemory() {
        let v = ModelFitVerdict(
            memory: .strained, disk: .sufficient, bytesOnDisk: 5_179_241_512,
            estimatedRuntimeBytes: 6_474_051_890, memoryShare: 0.90, freeDiskBytes: .max)
        let msg = ModelFitCopy.confirmationMessage(for: v, displayName: "Gemma 4 E4B (4-bit)")
        #expect(msg.contains("5.2 GB"))
        #expect(msg.contains("6.5 GB"))
        #expect(msg.contains("90%"))
        #expect(!msg.contains("可用内存"))
    }

    /// 磁盘不足的说明要给出还差多少。
    @Test func blockedMessageReportsTheShortfall() {
        let v = ModelFitEvaluator.evaluate(
            entry: entry("gemma-e4b-4bit"), machine: machine(gib: 16, freeDisk: 2_000_000_000))
        #expect(v.downloadAction == .blocked)
        let msg = ModelFitCopy.blockedMessage(for: v)
        #expect(msg.contains("2.0 GB"))
        #expect(msg.contains("5.2 GB"))
        #expect(msg.contains("3.2 GB"))
    }
}
