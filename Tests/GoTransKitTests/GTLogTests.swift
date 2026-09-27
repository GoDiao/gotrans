import Testing
import Foundation
@testable import GoTransKit

@Suite struct GTLogTests {
    /// 回归守卫：测试夹具的报错曾经写进用户的 `~/Library/Logs/GoTrans/gotrans.log`，
    /// 在那里冒充引擎故障（`mldrift buffer allocation failed`，56 行）。
    @Test func logFileStaysOutOfTheUserLibraryWhileTesting() {
        let userLibrary = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath().path
        let actual = GTLog.logFileURL.resolvingSymlinksInPath().path
        #expect(!actual.hasPrefix(userLibrary))
    }
}
