import Foundation

struct OCRError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
