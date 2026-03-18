import Foundation

enum AppError: LocalizedError, Sendable {
    case fileNotFound(String)
    case invalidData(String)
    case io(String)
    case network(String)
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let message),
             .invalidData(let message),
             .io(let message),
             .network(let message),
             .unauthorized(let message):
            return message
        }
    }
}
