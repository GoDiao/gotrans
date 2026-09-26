import Testing
import Foundation
@testable import GoTransKit

@Suite struct InstalledModelsTests {
    private func tempBase() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // 在 base 下伪造某 catalog 条目的快照目录（含完成标记），scan 应识别
    @Test func scan_findsCompletedSnapshot() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = ModelCatalog.entry(id: "gemma-e2b-4bit")!.repo
        let dir = ModelDownloader.snapshotDirectory(in: base, repo: repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = dir.appendingPathComponent("model.safetensors")
        try Data(repeating: 0, count: 2048).write(to: payload)
        // 完成标记：文件名→字节数（与 ModelDownloader.isComplete 一致）
        let marker = ["model.safetensors": Int64(2048)]
        try JSONEncoder().encode(marker).write(to: dir.appendingPathComponent(".download-complete"))

        let found = InstalledModels.scan(base: base)
        #expect(found.map(\.id) == ["gemma-e2b-4bit"])
        #expect(found.first!.bytesOnDisk >= 2048)
        #expect(InstalledModels.isInstalled(id: "gemma-e2b-4bit", base: base))
        #expect(!InstalledModels.isInstalled(id: "gemma-e4b-4bit", base: base))
    }

    @Test func scan_ignoresIncompleteOrUnknown() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        // 不完整（无标记）的已知仓库目录
        let repo = ModelCatalog.entry(id: "gemma-e4b-4bit")!.repo
        let dir = ModelDownloader.snapshotDirectory(in: base, repo: repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent("partial.bin"))
        #expect(InstalledModels.scan(base: base).isEmpty)
    }

    @Test func delete_removesSnapshot() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = ModelCatalog.entry(id: "gemma-e2b-4bit")!.repo
        let dir = ModelDownloader.snapshotDirectory(in: base, repo: repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try InstalledModels.delete(id: "gemma-e2b-4bit", base: base)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// D13 删掉了整层 legacy Hugging Face 缓存兼容。旧布局是 `<hub>/models--<owner>--<repo>/`，
    /// 这里把它直接摆进 base——旧实现会把 base 当 hub 命中，新实现必须完全不看这个约定。
    /// 半删的后果是 start() 的 isInstalled 守卫放行、随后静默重下 5.2 GB。
    @Test func legacyCacheLayoutNoLongerCountsAsInstalled() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let entry = ModelCatalog.entry(id: "gemma-e4b-4bit")!
        let legacy = base.appendingPathComponent(
            "models--\(entry.repo.replacingOccurrences(of: "/", with: "--"))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024).write(to: legacy.appendingPathComponent("config.json"))

        #expect(!InstalledModels.isInstalled(id: entry.id, base: base))
        #expect(InstalledModels.scan(base: base).isEmpty)
    }

    /// 已安装只由「快照目录 + 完成标记且字节数相符」决定，没有第二条认定途径。
    @Test func installedIsDecidedOnlyByTheSnapshotMarker() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let entry = ModelCatalog.entry(id: "gemma-e4b-4bit")!
        let dir = ModelDownloader.snapshotDirectory(in: base, repo: entry.repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 2048).write(to: dir.appendingPathComponent("model.safetensors"))
        // 有权重没标记
        #expect(!InstalledModels.isInstalled(id: entry.id, base: base))

        // 有标记但字节数对不上
        let marker = dir.appendingPathComponent(".download-complete")
        try JSONEncoder().encode(["model.safetensors": Int64(4096)]).write(to: marker)
        #expect(!InstalledModels.isInstalled(id: entry.id, base: base))

        try JSONEncoder().encode(["model.safetensors": Int64(2048)]).write(to: marker)
        #expect(InstalledModels.isInstalled(id: entry.id, base: base))
    }

    /// 删除只动快照目录。旧缓存目录不再被这段代码认识，也就不该被它删掉。
    @Test func deleteLeavesLegacyShapedDirectoriesAlone() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let entry = ModelCatalog.entry(id: "gemma-e4b-4bit")!
        let snapshot = ModelDownloader.snapshotDirectory(in: base, repo: entry.repo)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let legacy = base.appendingPathComponent(
            "models--\(entry.repo.replacingOccurrences(of: "/", with: "--"))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024).write(to: legacy.appendingPathComponent("config.json"))

        try InstalledModels.delete(id: entry.id, base: base)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
