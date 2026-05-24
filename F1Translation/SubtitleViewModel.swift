import Foundation
import Combine
import AVFoundation

@MainActor
public final class SubtitleViewModel: ObservableObject {
    @Published public var originalText: String = "" {
        didSet {
            pipManager.updateSubtitles(original: originalText, translated: translatedText)
        }
    }
    @Published public var translatedText: String = "" {
        didSet {
            pipManager.updateSubtitles(original: originalText, translated: translatedText)
        }
    }
    @Published public var isClickThrough: Bool = false
    @Published public var isRecording: Bool = false
    
    public let translationService: TranslationService
    public let pipManager = PiPManager()
    
    private let speechService: AppleSpeechRecognitionService
    private let audioCaptureCoordinator: AudioCaptureCoordinator
    
    private var translationTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    
    public init(translationService: TranslationService,
                speechService: AppleSpeechRecognitionService = AppleSpeechRecognitionService(),
                audioCaptureCoordinator: AudioCaptureCoordinator = AudioCaptureCoordinator()) {
        self.translationService = translationService
        self.speechService = speechService
        self.audioCaptureCoordinator = audioCaptureCoordinator
        
        setupBindings()
    }
    
    private func setupBindings() {
        audioCaptureCoordinator.onAudioBufferReceived = { [weak self] buffer in
            guard let self = self else { return }
            self.speechService.appendAudioBuffer(buffer)
        }
    }
    
    public func startLiveTranslation() {
        guard !isRecording else { return }
        
        isRecording = true
        
        // STT 스트림 시작
        let stream = speechService.startRecognition(isExternalCapture: true)
        
        recognitionTask = Task {
            do {
                for try await result in stream {
                    if !Task.isCancelled {
                        self.updateOriginalText(result.text)
                    }
                }
            } catch {
                print("음성 인식 오류 발생: \(error)")
                if !Task.isCancelled {
                    self.stopLiveTranslation()
                }
            }
        }
        
        // 오디오 캡처 시작
        do {
            try audioCaptureCoordinator.startCapture()
        } catch {
            print("오디오 캡처 시작 실패: \(error)")
            stopLiveTranslation()
        }
    }
    
    public func stopLiveTranslation() {
        guard isRecording else { return }
        isRecording = false
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        audioCaptureCoordinator.stopCapture()
        speechService.stopRecognition()
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


