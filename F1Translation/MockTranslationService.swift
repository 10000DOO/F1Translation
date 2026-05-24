import Foundation

public final class MockTranslationService: TranslationService {
    public init() {}
    
    public func translate(text: String, from source: String, to target: String) async throws -> String {
        let delayMs = Double.random(in: 200...500)
        try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
        return "\(text)[번역완료]"
    }
}
