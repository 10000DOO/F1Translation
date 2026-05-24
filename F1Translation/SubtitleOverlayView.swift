import SwiftUI
import Translation

@available(macOS 15.0, iOS 18.0, *)
public struct SubtitleOverlayView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @State private var translationConfiguration: TranslationSession.Configuration?
    
    public init(viewModel: SubtitleViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            if !viewModel.originalText.isEmpty {
                Text(viewModel.originalText)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 4)
            }
            
            if !viewModel.translatedText.isEmpty {
                Text(viewModel.translatedText)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.yellow)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 4)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.6))
        )
        .frame(minWidth: 400, minHeight: 120)
        .translationTask(translationConfiguration) { session in
            if let appleService = viewModel.translationService as? AppleTranslationService {
                appleService.updateSession(session)
            }
        }
        .onChange(of: viewModel.originalText) { oldValue, newValue in
            if !newValue.isEmpty && translationConfiguration == nil {
                translationConfiguration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "ko")
                )
            }
        }
    }
}
