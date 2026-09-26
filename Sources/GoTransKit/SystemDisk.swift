import Foundation

/// 模型目录所在卷的空间读数。针对该卷而不是根卷——模型目录可以被用户放在别处。
public enum SystemDisk {
    /// 剩余可用字节。用 `volumeAvailableCapacityKey` 而不是
    /// `volumeAvailableCapacityForImportantUsageKey`：后者把系统可清除空间也算进来，
    /// 通常明显大于 `df` 与「关于本机 › 储存空间」显示的数。磁盘闸门是整个推荐机制里
    /// 唯一会真正阻止用户的地方，它宁可保守，也不该比用户自己看到的数字更宽松（评审 Q-a）。
    public static func freeBytes(at url: URL) -> UInt64? {
        capacity(at: url, key: .volumeAvailableCapacityKey)
    }

    /// 卷总容量。只供显示与自检，不参与判定。
    public static func totalBytes(at url: URL) -> UInt64? {
        capacity(at: url, key: .volumeTotalCapacityKey)
    }

    private static func capacity(at url: URL, key: URLResourceKey) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [key]) else { return nil }
        let bytes: Int?
        switch key {
        case .volumeAvailableCapacityKey: bytes = values.volumeAvailableCapacity
        case .volumeTotalCapacityKey: bytes = values.volumeTotalCapacity
        default: bytes = nil
        }
        guard let bytes, bytes >= 0 else { return nil }
        return UInt64(bytes)
    }
}
