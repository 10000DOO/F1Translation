import Foundation
import ScreenCaptureKit
import AVFoundation

public final class AudioCaptureCoordinator: NSObject, SCStreamOutput, AudioCaptureService {
    private var stream: SCStream?
    private let converter = AudioFormatConverter()
    private let queue = DispatchQueue(label: "com.10000doo.F1Translation.captureQueue")
    
    public private(set) var isCapturing: Bool = false
    public var onAudioBufferReceived: ((AVAudioPCMBuffer) -> Void)?
    
    public func startCapture() throws {
        guard !isCapturing else { return }
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                
                stream.startCapture { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        print("스트림 캡처 시작 실패: \(error)")
                    } else {
                        self.isCapturing = true
                        self.stream = stream
                    }
                }
            } catch {
                print("공유 콘텐츠 획득 실패: \(error)")
            }
        }
    }
    
    public func stopCapture() {
        guard isCapturing, let stream = stream else { return }
        stream.stopCapture { [weak self] _ in
            self?.isCapturing = false
            self?.stream = nil
        }
    }
    
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        do {
            let convertedBuffer = try converter.convert(sampleBuffer: sampleBuffer)
            onAudioBufferReceived?(convertedBuffer)
        } catch {
            print("오디오 변환 실패: \(error)")
        }
    }
}
