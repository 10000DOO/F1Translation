import Foundation
import Speech
import AVFoundation
import CoreLocation

public final class AppleSpeechRecognitionService: NSObject, SpeechRecognitionService {
    private let speechRecognizer: SFSpeechRecognizer?
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var isRunning = false
    private var sessionTimer: Timer?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var isTransitioning = false
    private var isExternalCapture = false
    private var currentContinuation: AsyncThrowingStream<SpeechRecognitionResult, Error>.Continuation?
    
    private let queue = DispatchQueue(label: "com.10000doo.F1Translation.speechQueue")
    
    public override init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
    }
    
    public func startRecognition() -> AsyncThrowingStream<SpeechRecognitionResult, Error> {
        return startRecognition(isExternalCapture: false)
    }
    
    public func startRecognition(isExternalCapture: Bool) -> AsyncThrowingStream<SpeechRecognitionResult, Error> {
        return AsyncThrowingStream { continuation in
            self.queue.async {
                guard !self.isRunning else {
                    continuation.finish(throwing: SpeechRecognitionError.notAvailable)
                    return
                }
                self.isRunning = true
                self.isExternalCapture = isExternalCapture
                self.currentContinuation = continuation
                
                do {
                    if !isExternalCapture {
                        try self.setupAudioEngine()
                    }
                    self.startNewSession()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func setupAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.queue.async {
                guard self.isRunning else { return }
                
                if self.isTransitioning {
                    self.pendingBuffers.append(buffer)
                } else if let request = self.recognitionRequest {
                    request.append(buffer)
                }
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    private func startNewSession() {
        guard isRunning else { return }
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request
        
        isTransitioning = false
        if !pendingBuffers.isEmpty {
            for buffer in pendingBuffers {
                request.append(buffer)
            }
            pendingBuffers.removeAll()
        }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            currentContinuation?.finish(throwing: SpeechRecognitionError.notAvailable)
            return
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == kCLErrorDomain || nsError.code == 301 || nsError.code == 203 {
                        return
                    }
                    self.currentContinuation?.yield(with: .failure(SpeechRecognitionError.recognitionFailed(error)))
                    return
                }
                
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    let speechResult = SpeechRecognitionResult(text: text, isFinal: result.isFinal)
                    self.currentContinuation?.yield(speechResult)
                }
            }
        }
        
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: false) { [weak self] _ in
            self?.queue.async {
                self?.transitionToNextSession()
            }
        }
    }
    
    private func transitionToNextSession() {
        guard isRunning else { return }
        isTransitioning = true
        startNewSession()
    }
    
    public func stopRecognition() {
        queue.async {
            self.isRunning = false
            self.sessionTimer?.invalidate()
            self.sessionTimer = nil
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.pendingBuffers.removeAll()
            self.currentContinuation?.finish()
            self.currentContinuation = nil
        }
    }
    
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        self.queue.async {
            guard self.isRunning && self.isExternalCapture else { return }
            if self.isTransitioning {
                self.pendingBuffers.append(buffer)
            } else if let request = self.recognitionRequest {
                request.append(buffer)
            }
        }
    }
}
