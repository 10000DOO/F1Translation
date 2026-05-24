import Foundation

public final class MockSpeechRecognitionService: SpeechRecognitionService {
    private var isRunning = false
    
    public init() {}
    
    public func startRecognition() -> AsyncThrowingStream<SpeechRecognitionResult, Error> {
        isRunning = true
        return AsyncThrowingStream { continuation in
            let mockTexts = [
                "Welcome back to",
                "the Formula 1",
                "Grand Prix live commentary"
            ]
            
            Task {
                var index = 0
                while self.isRunning && index < mockTexts.count {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1초 대기
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    guard self.isRunning else { break }
                    
                    let result = SpeechRecognitionResult(text: mockTexts[index], isFinal: index == mockTexts.count - 1)
                    continuation.yield(result)
                    index += 1
                }
                continuation.finish()
            }
        }
    }
    
    public func stopRecognition() {
        isRunning = false
    }
}
