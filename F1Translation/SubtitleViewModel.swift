import Foundation
import Combine

@MainActor
public final class SubtitleViewModel: ObservableObject {
    @Published public var originalText: String = ""
    @Published public var translatedText: String = ""
    @Published public var isClickThrough: Bool = false
    
    public let translationService: TranslationService
    private var translationTask: Task<Void, Never>?
    
    public init(translationService: TranslationService) {
        self.translationService = translationService
    }
    
    public func updateOriginalText(_ text: String) {
        self.originalText = text
        triggerTranslation(for: text)
    }
    
    private func triggerTranslation(for text: String) {
        translationTask?.cancel()
        
        guard !text.isEmpty else {
            self.translatedText = ""
            return
        }
        
        translationTask = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                
                let result = try await translationService.translate(text: text, from: "en", to: "ko")
                
                if !Task.isCancelled {
                    self.translatedText = result
                }
            } catch is CancellationError {
                // Task cancelled normally, ignore
            } catch {
                print("번역 처리 오류: \(error)")
                if !Task.isCancelled {
                    self.translatedText = "[번역 실패]"
                }
            }
        }
    }
}
