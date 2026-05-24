import Foundation
import AVKit
import AVFoundation
import Combine

@MainActor
public final class PiPManager: NSObject, ObservableObject {
    @Published public var isPiPActive: Bool = false
    
    public let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private let renderer = PiPSubtitleRenderer()
    private var timer: Timer?
    
    private var currentOriginal: String = ""
    private var currentTranslated: String = ""
    
    public override init() {
        super.init()
        setupPiP()
    }
    
    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController?.delegate = self
    }
    
    public func updateSubtitles(original: String, translated: String) {
        self.currentOriginal = original
        self.currentTranslated = translated
        pushFrame()
    }
    
    public func startPiP() {
        guard let controller = pipController, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
        startTimer()
    }
    
    public func stopPiP() {
        pipController?.stopPictureInPicture()
        stopTimer()
    }
    
    private func pushFrame() {
        guard let buffer = renderer.render(original: currentOriginal, translated: currentTranslated) else { return }
        if sampleBufferDisplayLayer.status == .failed {
            sampleBufferDisplayLayer.flush()
        }
        sampleBufferDisplayLayer.enqueue(buffer)
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushFrame()
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            if playing {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }
    
    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return timer == nil
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize size: CMVideoDimensions) {}
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    public func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        stopTimer()
    }
}
