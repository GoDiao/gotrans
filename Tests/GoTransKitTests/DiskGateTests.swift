import Testing
import Foundation
@testable import GoTransKit

/// 磁盘闸门第二段。评审 I18：拿整仓总字节去比剩余空间，会把一个已经下到 90% 的续传永远
/// 拦死，而那一段恰恰是设计里被称作「真正的保证」的部分。
@Suite struct DiskGateTests {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private let files = [
        ModelDownloader.RemoteFile(path: "config.json", size: 1_000),
        ModelDownloader.RemoteFile(path: "model.safetensors", size: 1_000_000),
    ]

    /// 空目录：还需要下的就是全部。
    @Test func nothingOnDiskMeansEverythingIsStillNeeded() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelDownloader.remainingBytes(for: files, in: dir) == 1_001_000)
    }

    /// 已完整落盘的文件被下载循环跳过，因此不计入需求。
    @Test func completedFilesAreDeducted() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(1_000, to: dir.appendingPathComponent("config.json"))
        #expect(ModelDownloader.remainingBytes(for: files, in: dir) == 1_000_000)
    }

    /// 已写入的 `.part` 会被 Range 续传接上，只差剩下那一截。
    @Test func partialBytesAreDeducted() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(1_000, to: dir.appendingPathComponent("config.json"))
        try write(900_000, to: dir.appendingPathComponent("model.safetensors.part"))
        #expect(ModelDownloader.remainingBytes(for: files, in: dir) == 100_000)
    }

    /// 字节数对不上的完整文件不算数，要重下。
    @Test func aWrongSizedFileIsNotCredited() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(777, to: dir.appendingPathComponent("config.json"))
        #expect(ModelDownloader.remainingBytes(for: files, in: dir) == 1_001_000)
    }

    /// 下到 90% 后断线，剩余空间只够剩下那 10%：闸门必须放行。
    /// 按整仓总字节比的话这里会被拒，而且永远拒。
    @Test func aResumedDownloadIsNotBlockedByItsOwnTotal() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(1_000, to: dir.appendingPathComponent("config.json"))
        try write(900_000, to: dir.appendingPathComponent("model.safetensors.part"))

        let stillNeeded = ModelDownloader.remainingBytes(for: files, in: dir)
        let freeSpace: UInt64 = 150_000          // 够剩下的 100 000，远不够整仓 1 001 000
        #expect(ModelDownloader.diskShortfall(needed: stillNeeded, freeBytes: freeSpace) == nil)

        let total = files.reduce(Int64(0)) { $0 + $1.size }
        #expect(ModelDownloader.diskShortfall(needed: total, freeBytes: freeSpace) != nil,
                "按整仓总字节比会拦死这次续传——这正是本用例存在的理由")
    }

    /// 空间确实不足时报明差额。
    @Test func aRealShortfallIsReportedWithItsSize() {
        #expect(ModelDownloader.diskShortfall(needed: 1_000_000, freeBytes: 400_000) == 600_000)
        #expect(ModelDownloader.diskShortfall(needed: 1_000_000, freeBytes: 1_000_000) == nil)
        let error = ModelDownloadError.insufficientDiskSpace(needed: 1_000_000, free: 400_000)
        let text = try! #require(error.errorDescription)
        #expect(text.contains("600000"))
    }

    /// 剩余空间读不到时不拦——缺数据不构成拒绝的理由。
    @Test func unknownFreeSpaceDoesNotBlock() {
        #expect(ModelDownloader.diskShortfall(needed: .max, freeBytes: nil) == nil)
    }

    /// 磁盘不足是本地问题，换个源一样不够，所以不触发自动换源。
    @Test func aDiskShortfallDoesNotTriggerASourceFallback() {
        #expect(!ModelDownloader.shouldFallbackToModelScope(
            after: ModelDownloadError.insufficientDiskSpace(needed: 10, free: 1)))
    }

    /// 两个 GGUF 条目走单文件路径，不读远端清单，因此不经过这一段；它们的字节数由
    /// revision 钉死，界面那一段闸门对它们本来就是精确的。
    @Test func singleFileEntriesBypassThisGate() {
        for entry in ModelCatalog.entries {
            guard case .singleFile(let file) = entry.distribution else { continue }
            #expect(entry.bytesOnDisk == UInt64(file.bytes))
            #expect(!file.huggingFaceRevision.isEmpty)
            #expect(!file.modelScopeRevision.isEmpty)
        }
        let curated = ModelCatalog.entries.filter {
            if case .singleFile = $0.distribution { return true }
            return false
        }
        #expect(curated.map(\.id).sorted() == ["hymt2-1.25bit", "hymt2-2bit"])
    }
}
