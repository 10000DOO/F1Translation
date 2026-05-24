import Foundation
import CoreMedia
import CoreVideo
import UIKit
import AVFoundation

public final class PiPSubtitleRenderer {
    private var pixelBufferPool: CVPixelBufferPool?
    private let size: CGSize
    
    public init(size: CGSize = CGSize(width: 800, height: 300)) {
        self.size = size
        setupPixelBufferPool()
    }
    
    private func setupPixelBufferPool() {
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary
        let bufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, bufferAttributes, &pixelBufferPool)
    }
    
    public func render(original: String, translated: String) -> CMSampleBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            
            // 반투명 검은 배경
            cgContext.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
            cgContext.fill(CGRect(origin: .zero, size: size))
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            
            let origAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]
            let transAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: UIColor.yellow,
                .paragraphStyle: paragraphStyle
            ]
            
            let origRect = CGRect(x: 20, y: 40, width: size.width - 40, height: 90)
            let transRect = CGRect(x: 20, y: 150, width: size.width - 40, height: 110)
            
            original.draw(in: origRect, withAttributes: origAttrs)
            translated.draw(in: transRect, withAttributes: transAttrs)
        }
        
        guard let cgImage = image.cgImage else { return nil }
        let ciContext = CIContext()
        ciContext.render(CIImage(cgImage: cgImage), to: buffer)
        
        var info = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDesc)
        guard let desc = formatDesc else { return nil }
        
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: desc,
            sampleTiming: &info,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }
}
