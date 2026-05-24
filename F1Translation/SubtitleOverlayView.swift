import SwiftUI
import Translation
import AVFoundation

@available(macOS 15.0, iOS 18.0, *)
public struct SubtitleOverlayView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @State private var translationConfiguration: TranslationSession.Configuration?
    
    public init(viewModel: SubtitleViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
    }
    
    public var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                
                // PiP 활성화를 위해 뷰 계층 구조에 1x1 display layer를 심어 둠
                PiPDisplayView(layer: viewModel.pipManager.sampleBufferDisplayLayer)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                
                VStack(spacing: 16) {
                    HStack {
                        Spacer()
                        Button(action: {
                            if viewModel.pipManager.isPiPActive {
                                viewModel.pipManager.stopPiP()
                            } else {
                                viewModel.pipManager.startPiP()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: viewModel.pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                                Text(viewModel.pipManager.isPiPActive ? "PiP 끄기" : "PiP 켜기")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.bottom, 4)
                    
                    if !viewModel.originalText.isEmpty {
                        Text(viewModel.originalText)
                            .font(.system(size: geometry.size.width > 600 ? 24 : 18, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .shadow(radius: 4)
                    }
                    
                    if !viewModel.translatedText.isEmpty {
                        Text(viewModel.translatedText)
                            .font(.system(size: geometry.size.width > 600 ? 28 : 22, weight: .bold))
                            .foregroundColor(.yellow)
                            .multilineTextAlignment(.center)
                            .shadow(radius: 4)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.7))
                )
                .padding(.horizontal, geometry.size.width > 800 ? 80 : 20)
                .padding(.bottom, 40)
            }
        }
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

@available(iOS 18.0, *)
struct PiPDisplayView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        layer.frame = uiView.bounds
    }
}
