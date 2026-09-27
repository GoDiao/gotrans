import Testing
import Foundation
import GoTransKit

@Suite struct UserFacingErrorTests {
    enum LocalizedFailure: Error, LocalizedError {
        case unavailable

        var errorDescription: String? { "翻译引擎暂不可用。" }
    }

    enum PlainFailure: Error {
        case unavailable
    }

    @Test func localizedErrorUsesDescription() {
        #expect(userFacingMessage(LocalizedFailure.unavailable) == "翻译引擎暂不可用。")
    }

    @Test func plainErrorKeepsSwiftDescription() {
        #expect(userFacingMessage(PlainFailure.unavailable) == "unavailable")
    }
}
