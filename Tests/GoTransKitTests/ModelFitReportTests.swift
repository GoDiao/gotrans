import Testing
import Foundation
@testable import GoTransKit

@Suite struct ModelFitReportTests {
    private let thisMachine = MachineProfile(
        physicalMemory: 16 << 30, performanceCoreCount: 6,
        freeDiskBytes: 300_000_000_000, chipName: "Apple M1 Pro")

    /// 三个覆盖参数各自生效，且只影响自己那一项。
    @Test func eachOverrideAffectsOnlyItsOwnField() throws {
        let ram = try ModelFitReport.parseOverrides(["--ram", "8"])
        #expect(ram.physicalMemory == 8 << 30)
        #expect(ram.performanceCores == nil)
        #expect(ram.freeDisk == nil)

        let cores = try ModelFitReport.parseOverrides(["--cores", "12"])
        #expect(cores.performanceCores == 12)
        #expect(cores.physicalMemory == nil)

        let disk = try ModelFitReport.parseOverrides(["--disk", "2"])
        #expect(disk.freeDisk == 2_000_000_000)

        let all = try ModelFitReport.parseOverrides(["--ram", "48", "--cores", "16", "--disk", "10"])
        #expect(all.physicalMemory == 48 << 30)
        #expect(all.performanceCores == 16)
        #expect(all.freeDisk == 10_000_000_000)
    }

    /// `--json` 不是覆盖参数，混在里面也不该被当成缺值。
    @Test func theJSONFlagIsNotAnOverride() throws {
        let parsed = try ModelFitReport.parseOverrides(["--json", "--ram", "8", "--json"])
        #expect(parsed.physicalMemory == 8 << 30)
    }

    @Test func badArgumentsAreRejectedRatherThanGuessed() {
        #expect(throws: ModelFitReport.OverrideError.missingValue("--ram")) {
            try ModelFitReport.parseOverrides(["--ram"])
        }
        // I31：末尾的未知参数要报「无法识别」，不是「缺少取值」
        #expect(throws: ModelFitReport.OverrideError.unknownArgument("--bogus")) {
            try ModelFitReport.parseOverrides(["--bogus"])
        }
        #expect(throws: ModelFitReport.OverrideError.badNumber("--cores", "x")) {
            try ModelFitReport.parseOverrides(["--cores", "x"])
        }
        #expect(throws: ModelFitReport.OverrideError.unknownArgument("--memory")) {
            try ModelFitReport.parseOverrides(["--memory", "8"])
        }
    }

    /// 覆盖参数构造出的画像走的是与设置页、与单测完全相同的那条路径。
    @Test func overridesBuildAProfileTheKernelAccepts() throws {
        let overrides = try ModelFitReport.parseOverrides(["--ram", "8"])
        let machine = ModelFitReport.apply(overrides, to: thisMachine)
        #expect(machine.physicalMemory == 8 << 30)
        #expect(machine.performanceCoreCount == 6)          // 未覆盖的沿用本机
        #expect(machine.freeDiskBytes == 300_000_000_000)

        // 8 GiB 上 E4B 是全表唯一一个「偏紧」，与设计表和手算一致
        let e4b = ModelCatalog.entry(id: "gemma-e4b-4bit")!
        #expect(ModelFitEvaluator.evaluate(entry: e4b, machine: machine).memory == .tight)
    }

    /// 内存或核数被覆盖之后，芯片名不再属实，就不写。
    @Test func overridingTheMachineDropsTheChipName() throws {
        let overridden = ModelFitReport.apply(
            try ModelFitReport.parseOverrides(["--ram", "48"]), to: thisMachine)
        #expect(overridden.chipName == nil)
        let diskOnly = ModelFitReport.apply(
            try ModelFitReport.parseOverrides(["--disk", "5"]), to: thisMachine)
        #expect(diskOnly.chipName == "Apple M1 Pro")
    }

    /// 验收第 5 条的自动化版本：8 / 32 / 48 GiB 三档的全表判定，与手算一致。
    @Test func theThreeAcceptanceMachineSizes() throws {
        let expected: [UInt64: [String: ModelMemoryFit]] = [
            8:  ["gemma-e4b-4bit": .tight, "gemma-e2b-4bit": .comfortable,
                 "hymt2-8bit": .comfortable, "hymt2-4bit": .comfortable,
                 "hymt2-2bit": .comfortable, "hymt2-1.25bit": .comfortable,
                 "qwen35-4b-4bit": .comfortable, "qwen35-9b-4bit": .strained],
            32: ["gemma-e4b-4bit": .comfortable, "gemma-e2b-4bit": .comfortable,
                 "hymt2-8bit": .comfortable, "hymt2-4bit": .comfortable,
                 "hymt2-2bit": .comfortable, "hymt2-1.25bit": .comfortable,
                 "qwen35-4b-4bit": .comfortable, "qwen35-9b-4bit": .comfortable],
            48: ["gemma-e4b-4bit": .comfortable, "gemma-e2b-4bit": .comfortable,
                 "hymt2-8bit": .comfortable, "hymt2-4bit": .comfortable,
                 "hymt2-2bit": .comfortable, "hymt2-1.25bit": .comfortable,
                 "qwen35-4b-4bit": .comfortable, "qwen35-9b-4bit": .comfortable],
        ]
        for (gib, table) in expected {
            let machine = ModelFitReport.apply(
                try ModelFitReport.parseOverrides(["--ram", "\(gib)"]), to: thisMachine)
            for entry in ModelCatalog.entries {
                let got = ModelFitEvaluator.evaluate(entry: entry, machine: machine).memory
                #expect(got == table[entry.id], "\(entry.id) @ \(gib)GiB → \(got)")
            }
        }
    }

    /// 文本输出把机器信号、估算声明和全表都带上，且不出现可用内存（D12）。
    @Test func textReportCarriesTheMachineAndEveryEntry() {
        let text = ModelFitReport.text(machine: thisMachine)
        #expect(text.contains("Apple M1 Pro"))
        #expect(text.contains("性能核 6"))
        #expect(!text.contains("可用内存"))
        // D17：头部那句自我限定整句删掉，只留机器读数一行
        #expect(!text.contains("内存判定是估算"))
        #expect(!text.contains("约定的参考值"))
        // 对估算的提示改由每行承担
        #expect(text.contains("运行约占内存"))
        for entry in ModelCatalog.entries {
            #expect(text.contains(entry.displayName), "\(entry.displayName)")
        }
    }

    /// JSON 可被机器读取，字段齐全，每个条目都在。
    @Test func jsonIsParseableAndComplete() throws {
        let data = Data(try ModelFitReport.json(machine: thisMachine).utf8)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let machine = try #require(root["machine"] as? [String: Any])
        #expect(machine["physicalMemoryBytes"] as? UInt64 == 16 << 30)
        #expect(machine["performanceCores"] as? Int == 6)
        #expect(machine["chip"] as? String == "Apple M1 Pro")
        #expect(root["runtimeMemoryFactor"] as? Double == 1.25)
        #expect(root["runtimeMemoryFactorIsAgreedReferenceValue"] as? Bool == true)

        let models = try #require(root["models"] as? [[String: Any]])
        #expect(models.count == ModelCatalog.entries.count)
        let required = ["id", "displayName", "repo", "purpose", "bytesOnDisk",
                        "estimatedRuntimeBytes", "memoryShare", "memoryFit",
                        "diskFit", "downloadAction", "subtitle"]
        for model in models {
            for key in required {
                #expect(model[key] != nil, "\(model["id"] ?? "?") 缺字段 \(key)")
            }
        }
        let e4b = try #require(models.first { $0["id"] as? String == "gemma-e4b-4bit" })
        #expect(e4b["bytesOnDisk"] as? UInt64 == 5_179_241_512)
        #expect(e4b["memoryFit"] as? String == "comfortable")
        #expect(e4b["downloadAction"] as? String == "proceed")
    }
}

@Suite struct MemoryFormattingTests {
    /// 装机内存按二进制报：一台「16 GB」的 Mac 的 `hw.memsize` 是 17 179 869 184，
    /// 十进制会印成「17.2 GB」，没人这样称呼自己的机器。
    @Test func memoryIsReportedTheWayPeopleNameTheirMachines() {
        #expect(ModelFitCopy.formatMemory(17_179_869_184) == "16 GB")
        #expect(ModelFitCopy.formatMemory(8 << 30) == "8.0 GB")
        #expect(ModelFitCopy.formatMemory(48 << 30) == "48 GB")
    }

    /// 模型体积仍走十进制，与 Hugging Face 和两份 README 一致——两个口径不合并。
    @Test func modelSizesStayDecimal() {
        #expect(ModelFitCopy.formatBytes(5_179_241_512) == "5.2 GB")
        #expect(ModelFitCopy.formatBytes(461_860_800) == "462 MB")
    }
}
