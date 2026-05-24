import Foundation

public protocol AudioCaptureService {
    func startCapture() throws
    func stopCapture()
    var isCapturing: Bool { get }
}
