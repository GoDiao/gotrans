import XCTest
@testable import GoTransKit

final class ModelCatalogTests: XCTestCase {
    func test_entries_haveUniqueStableIDs() {
        let ids = ModelCatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "catalog id 必须唯一")
        XCTAssertEqual(ids, [
            "gemma-e4b-4bit",
            "gemma-e2b-4bit",
            "hymt2-4bit",
            "hymt2-8bit",
            "hymt2-1.25bit",
            "hymt2-2bit",
            "qwen35-4b-4bit",
            "qwen35-9b-4bit",
        ])
    }

    func test_entry_lookupByID() {
        let e = ModelCatalog.entry(id: "gemma-e2b-4bit")
        XCTAssertEqual(e?.repo, "mlx-community/gemma-4-e2b-it-4bit")
        XCTAssertEqual(e?.purpose, .generalPurpose)
        XCTAssertNil(ModelCatalog.entry(id: "nope"))
    }

    func test_autoIsNotAnEntry() {
        XCTAssertNil(ModelCatalog.entry(id: "auto"))
    }

    func test_curatedGGUFMetadataIsPinned() throws {
        let light = try XCTUnwrap(ModelCatalog.entry(id: "hymt2-1.25bit"))
        XCTAssertEqual(light.backend, .llamaGGUF(.stq1_0))
        XCTAssertEqual(light.distribution, .singleFile(SingleFileDistribution(
            fileName: "Hy-MT2-1.8B-1.25bit-v2.gguf",
            huggingFaceRevision: "0989912c0cc2d3edeeecd76171d1c7d94ee17255",
            modelScopeRevision: "2d3896c601bb165415669c31e8cf43c2554e7900",
            bytes: 461_860_800,
            sha256: "13a33fc4f72d5c92c439a65fd343696de4ccd0485bca84de2712bc0d8cc4e773"
        )))

        let balanced = try XCTUnwrap(ModelCatalog.entry(id: "hymt2-2bit"))
        XCTAssertEqual(balanced.backend, .llamaGGUF(.q2_0c))
        XCTAssertEqual(balanced.distribution, .singleFile(SingleFileDistribution(
            fileName: "Hy-MT2-1.8B-2bit-v2.gguf",
            huggingFaceRevision: "2245b9ea2bdd68a67b21b44db9564e7d32fc3bc6",
            modelScopeRevision: "6689e68668273c14fb5a45bd04ffe12e0601077b",
            bytes: 600_534_976,
            sha256: "ae35b1ee4e4a12011e8105d5e7e2bd10f0c4b4e09320367274922184c0831c95"
        )))
    }

    /// 落盘体积以 Hugging Face tree API 实算为准（D5），并按 D16 以常量落进仓库——
    /// 运行时不查 tree API，所以评审的对象是这些常量，这个用例就是那份评审的留痕。
    /// 实算于 2026-09-21；I1（E4B 偏低 5.7%）与 I8（8-bit 偏低 0.9%、4-bit 偏高 7.7%）由此关闭。
    func test_bytesOnDiskMatchTheMeasuredTreeSizes() throws {
        let measured: [String: UInt64] = [
            "gemma-e4b-4bit": 5_179_241_512,
            "gemma-e2b-4bit": 3_583_088_661,
            "hymt2-8bit": 1_916_841_510,
            "hymt2-4bit": 1_021_371_026,
            "hymt2-2bit": 600_534_976,
            "hymt2-1.25bit": 461_860_800,
            "qwen35-4b-4bit": 3_061_132_920,
            "qwen35-9b-4bit": 5_977_074_591,
        ]
        XCTAssertEqual(Set(measured.keys), Set(ModelCatalog.entries.map(\.id)),
                       "新增条目必须同时补一个实算值")
        for entry in ModelCatalog.entries {
            XCTAssertEqual(entry.bytesOnDisk, measured[entry.id], entry.id)
        }
    }

    /// 单文件条目的落盘体积就是那个文件本身，两处不能各记一个数。
    func test_singleFileEntriesAgreeWithTheirPinnedFileSize() throws {
        for entry in ModelCatalog.entries {
            guard case .singleFile(let file) = entry.distribution else { continue }
            XCTAssertEqual(entry.bytesOnDisk, UInt64(file.bytes), entry.id)
        }
    }

    /// 拆开 `ModelFamily` 是纯重构：每个条目的三条属性必须与拆分前那张 family 映射逐条相同，
    /// 否则 prompt 策略或通用处理准入就悄悄变了（设计风险四）。
    /// 拆分前：`.gemma` → 发 system prompt、可通用处理、内置架构；`.hunyuanMT2` → 三者相反。
    func test_splitPropertiesMatchTheFormerFamilyMapping() throws {
        // 阶段二加入的两款 Qwen3.5 不在这张映射里——那时还没有它们，拆分也就无从「保持不变」。
        let formerlyGemma: Set<String> = ["gemma-e4b-4bit", "gemma-e2b-4bit"]
        let existedBeforeTheSplit: Set<String> = formerlyGemma.union([
            "hymt2-4bit", "hymt2-8bit", "hymt2-1.25bit", "hymt2-2bit",
        ])
        for entry in ModelCatalog.entries where existedBeforeTheSplit.contains(entry.id) {
            let wasGemma = formerlyGemma.contains(entry.id)
            XCTAssertEqual(entry.usesSystemPrompt, wasGemma, entry.id)
            XCTAssertEqual(entry.purpose, wasGemma ? .generalPurpose : .translationOnly, entry.id)
            XCTAssertEqual(entry.architecture, wasGemma ? .builtIn : .hunyuan, entry.id)
        }
    }

    /// 三条属性是三条轴，不是一个枚举的三个别名：任意组合都可表达。
    /// 阶段二要加的正是「内置架构的通用模型」，它在旧的 family 下无法表达。
    func test_theThreeAxesAreIndependentlyAssignable() throws {
        let unusual = ModelCatalogEntry(
            id: "hypothetical", displayName: "假想条目", repo: "owner/repo",
            purpose: .generalPurpose, usesSystemPrompt: false, architecture: .hunyuan,
            bytesOnDisk: 1, defaultMaxTokens: 1, defaultMaxInputChars: 1)
        XCTAssertEqual(unusual.purpose, .generalPurpose)
        XCTAssertFalse(unusual.usesSystemPrompt)
        XCTAssertEqual(unusual.architecture, .hunyuan)
    }

    func test_existingCatalogEntriesRemainRepositoryMLX() {
        for id in ["gemma-e4b-4bit", "gemma-e2b-4bit", "hymt2-4bit", "hymt2-8bit",
                   "qwen35-4b-4bit", "qwen35-9b-4bit"] {
            XCTAssertEqual(ModelCatalog.entry(id: id)?.backend, .mlx)
            XCTAssertEqual(ModelCatalog.entry(id: id)?.distribution, .repositorySnapshot)
        }
    }
}
