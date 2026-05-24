import Foundation
import AVFoundation
import CoreMedia

public final class AudioFormatConverter {
    private let targetFormat: AVAudioFormat
    private var activeConverter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    
    public init() {
        // 16kHz, 16-bit linear PCM, mono
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        self.targetFormat = AVAudioFormat(streamDescription: &asbd)!
    }
    
    public func convert(sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let sourceASBD = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw NSError(domain: "AudioFormatConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "포맷 서술자를 읽지 못했습니다."])
        }
        
        let sourceFormat = AVAudioFormat(streamDescription: sourceASBD)!
        
        if self.sourceFormat != sourceFormat || activeConverter == nil {
            self.sourceFormat = sourceFormat
            self.activeConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        
        guard let converter = activeConverter else {
            throw NSError(domain: "AudioFormatConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "변환기 생성 실패"])
        }
        
        guard let inputPCMBuffer = makePCMBuffer(from: sampleBuffer, format: sourceFormat) else {
            throw NSError(domain: "AudioFormatConverter", code: -3, userInfo: [NSLocalizedDescriptionKey: "입력 버퍼 래핑 실패"])
        }
        
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputPCMBuffer.frameLength) * ratio) + 16
        guard let outputPCMBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            throw NSError(domain: "AudioFormatConverter", code: -4, userInfo: [NSLocalizedDescriptionKey: "출력 버퍼 할당 실패"])
        }
        
        var error: NSError?
        var inputBlockCalled = false
        
        let status = converter.convert(to: outputPCMBuffer, error: &error) { inNumPackets, outStatus in
            if inputBlockCalled {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputBlockCalled = true
            outStatus.pointee = .haveData
            return inputPCMBuffer
        }
        
        if let error = error {
            throw error
        }
        
        if status == .error {
            throw NSError(domain: "AudioFormatConverter", code: -5, userInfo: [NSLocalizedDescriptionKey: "컨버터 변환 에러"])
        }
        
        return outputPCMBuffer
    }
    
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard CMSampleBufferGetDataBuffer(sampleBuffer) != nil else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let frameCapacity = AVAudioFrameCount(numSamples)
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        pcmBuffer.frameLength = frameCapacity
        
        let bufferList = pcmBuffer.mutableAudioBufferList
        let frameCount: Int32 = Int32(numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: frameCount, into: bufferList)
        if status != noErr {
            return nil
        }
        
        return pcmBuffer
    }
}
