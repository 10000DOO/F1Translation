import Foundation

public struct SpeechRecognitionResult: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public enum SpeechRecognitionError: Error, LocalizedError {
    case microphoneAccessDenied
    case recognitionFailed(Error)
    case notAvailable
    
    public var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied: return "마이크 접근 권한이 거부되었습니다."
        case .recognitionFailed(let error): return "음성 인식 오류: \(error.localizedDescription)"
        case .notAvailable: return "음성 인식을 사용할 수 없습니다."
        }
    }
}

public protocol SpeechRecognitionService {
    func startRecognition() -> AsyncThrowingStream<SpeechRecognitionResult, Error>
    func stopRecognition()
}
