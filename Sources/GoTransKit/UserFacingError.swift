import Foundation

public func userFacingMessage(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
}
