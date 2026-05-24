import Foundation
import AVFoundation

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
    
    public func convert(pcmBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let sourceFormat = pcmBuffer.format
        
        if self.sourceFormat != sourceFormat || activeConverter == nil {
            self.sourceFormat = sourceFormat
            self.activeConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        
        guard let converter = activeConverter else {
            throw NSError(domain: "AudioFormatConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "변환기 생성 실패"])
        }
        
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 16
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
            return pcmBuffer
        }
        
        if let error = error {
            throw error
        }
        
        if status == .error {
            throw NSError(domain: "AudioFormatConverter", code: -5, userInfo: [NSLocalizedDescriptionKey: "컨버터 변환 에러"])
        }
        
        return outputPCMBuffer
    }
}

