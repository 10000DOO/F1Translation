import Foundation
import Translation

@available(macOS 15.0, iOS 18.0, *)
public final class AppleTranslationService: TranslationService {
    private var session: TranslationSession?
    private let queue = DispatchQueue(label: "com.10000doo.F1Translation.translationQueue")
    
    public init() {}
    
    public func updateSession(_ session: TranslationSession) {
        queue.sync {
            self.session = session
        }
    }
    
    public func translate(text: String, from source: String, to target: String) async throws -> String {
        guard !text.isEmpty else { return "" }
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let session = self.session else {
                    continuation.resume(throwing: TranslationServiceError.invalidInput)
                    return
                }
                
                Task {
                    do {
                        let response = try await session.translate(text)
                        continuation.resume(returning: response.targetText)
                    } catch {
                        continuation.resume(throwing: TranslationServiceError.translationFailed(error))
                    }
                }
            }
        }
    }
}
