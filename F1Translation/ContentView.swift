import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var viewModel = SubtitleViewModel(translationService: AppleTranslationService())
    
    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Text("F1 실시간 번역 자막")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding()
                    
                    Spacer()
                    
                    Button(action: {
                        if viewModel.isRecording {
                            viewModel.stopLiveTranslation()
                        } else {
                            viewModel.startLiveTranslation()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.isRecording ? "stop.fill" : "play.fill")
                            Text(viewModel.isRecording ? "번역 중지" : "번역 시작")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(viewModel.isRecording ? Color.red : Color.green)
                        .cornerRadius(10)
                        .shadow(radius: 3)
                    }
                    .padding()
                }
                
                Spacer()
                
                SubtitleOverlayView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

#Preview {
    ContentView()
}

