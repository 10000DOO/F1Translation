import Foundation

public enum TranslationServiceError: Error, LocalizedError {
    case translationFailed(Error)
    case invalidInput
    
    public var errorDescription: String? {
        switch self {
        case .translationFailed(let error): return "번역 오류: \(error.localizedDescription)"
        case .invalidInput: return "유효하지 않은 입력 데이터입니다."
        }
    }
}

public protocol TranslationService {
    func translate(text: String, from source: String, to target: String) async throws -> String
}
