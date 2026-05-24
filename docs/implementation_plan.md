# Implementation Plan: F1 Translation App (iOS/iPadOS 18+)

본 문서는 macOS 기반의 프로젝트를 iOS 18+ / iPadOS 18+ 환경으로 포팅하고, 실시간 마이크 오디오 캡처(AVAudioEngine), 온디바이스 STT 및 번역, SwiftUI 및 Picture-in-Picture(PiP) 자막 오버레이 애플리케이션 개발을 위한 단계별 구현 가이드 및 검증 시나리오를 정의합니다.

---

## 1. 프로젝트 대상 플랫폼 변환 가이드라인 (macOS -> iPadOS)

### 1.1. Xcode Target 설정 변환
1. Xcode의 **Project Navigator**에서 `F1Translation` 프로젝트를 선택합니다.
2. **Targets** 아래의 `F1Translation` 타겟을 선택한 후 **General** 탭으로 이동합니다.
3. **Supported Destinations** 항목에서 기존 `macOS`를 삭제하고, `iPad` 및 `iPhone` (Destination)을 추가합니다.
4. **Minimum Deployments** 항목에서 iOS / iPadOS 버전을 **18.0** 이상으로 상향 조정합니다.
5. **Build Settings**에서 `Deployment Target`이 `iOS 18.0`으로 설정되었는지 확인합니다.

### 1.2. Info.plist 권한 구성 키 정의
마이크 및 온디바이스 음성 인식을 정상적으로 구동하기 위해 다음 키들을 `Info.plist`에 정의합니다.
```xml
<key>NSMicrophoneUsageDescription</key>
<string>F1 방송의 물리적 소리를 수집하여 번역용 오디오 스트림을 생성하기 위해 마이크 권한이 필요합니다.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>수집된 영어 음성을 텍스트로 인식하기 위해 온디바이스 음성 인식 권한을 사용합니다.</string>
```

### 1.3. Capabilities 설정 (Background Modes)
자막 서비스가 백그라운드 및 타 동영상 앱 위에서 지속적으로 돌 수 있게 하려면 백그라운드 모드를 추가해야 합니다.
1. **Signing & Capabilities** 탭으로 이동합니다.
2. **+ Capability** 버튼을 눌러 **Background Modes**를 추가합니다.
3. 다음 옵션을 선택합니다:
   - `Audio, AirPlay, and Picture in Picture`

---

## 2. 구현 로드맵 및 단계별 가이드 (Phase 1 ~ Phase 6)

### Phase 1: 플랫폼 전환 및 의존성 정비

1. Target 설정을 iPadOS 18+로 전환하고, macOS 전용 API(AppKit 및 ScreenCaptureKit 관련 코드)를 빌드에서 제외하거나 삭제합니다.
2. `SubtitleOverlayWindow.swift` 파일을 삭제하거나 빌드 타겟에서 해제합니다.
3. 마이크 권한 요청 및 음성 인식 권한 동의 절차를 앱 진입 시 수행하는 권한 도우미 모듈을 구성합니다.

---

### Phase 2: Core Interface 및 Mock 엔진 설계

#### 2.1. 캡처, STT, 번역 인터페이스 선언
`design_f1_translation.md`에 맞춰 `SpeechRecognitionService`, `TranslationService`, `AudioCaptureService` 프로토콜을 일관되게 정비합니다.

#### 2.2. Mock 구현을 통한 데이터 흐름 확인
실제 마이크 캡처나 온디바이스 번역 기능이 초기 단계에서 세팅되기 전, UI 데이터 바인딩 동작을 검증하기 위해 Mock 서비스를 준비합니다.
- `MockAudioCaptureService`: 주기적으로 더미 신호를 흘려보내는 가짜 캡처기.
- `MockSpeechRecognitionService`: 주기적으로 가상의 영어 대화 텍스트 스트림을 방출.

---

### Phase 3: 온디바이스 STT 및 번역 엔진 구현

#### 3.1. SFSpeechRecognizer 세션 체이닝 (`AppleSpeechRecognitionService`)
이 모듈은 50초 단위 세션 순환(Chaining)을 지원하여 1분 세션 강제 종료 한계를 우회합니다. 마이크로부터 들어오는 `AVAudioPCMBuffer`를 연속적으로 큐에 저장한 뒤 새로운 세션 요청에 무손실로 주입합니다.

```swift
import Foundation
import Speech
import AVFoundation

public final class AppleSpeechRecognitionService: SpeechRecognitionService {
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var isRunning = false
    private var sessionTimer: Timer?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var isTransitioning = false
    private var currentContinuation: AsyncThrowingStream<SpeechRecognitionResult, Error>.Continuation?
    
    private let queue = DispatchQueue(label: "com.10000doo.F1Translation.speechQueue")
    
    public init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
    
    public func startRecognition() -> AsyncThrowingStream<SpeechRecognitionResult, Error> {
        return AsyncThrowingStream { continuation in
            self.queue.async {
                guard !self.isRunning else {
                    continuation.finish(throwing: SpeechRecognitionError.notAvailable)
                    return
                }
                self.isRunning = true
                self.currentContinuation = continuation
                self.startNewSession()
            }
        }
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
                    // Task 취소 관련 오류는 통과 처리
                    if nsError.code == 203 || nsError.code == 301 {
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
            self.pendingBuffers.removeAll()
            self.currentContinuation?.finish()
            self.currentContinuation = nil
        }
    }
    
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        self.queue.async {
            guard self.isRunning else { return }
            if self.isTransitioning {
                self.pendingBuffers.append(buffer)
            } else if let request = self.recognitionRequest {
                request.append(buffer)
            }
        }
    }
}
```

#### 3.2. Translation Framework (`AppleTranslationService`)
SwiftUI `.translationTask` 바인딩을 통해 주입된 번역 세션 객체를 받아 비동기 통신을 처리합니다. iOS 18 온디바이스 번역 가용성은 `LanguageAvailability`를 통해 체크합니다.

---

### Phase 4: 마이크 오디오 캡처 파이프라인 개발

#### 4.1. AVAudioEngine 오디오 캡처 구현 (`AudioCaptureCoordinator`)
가상 디바이스 없는 DRM 미디어 재생 시 우회 캡처를 지원하기 위해 마이크 입력을 탭으로 가로챕니다.

```swift
import Foundation
import AVFoundation

public final class AudioCaptureCoordinator: AudioCaptureService {
    private var audioEngine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.10000doo.F1Translation.captureQueue")
    
    public private(set) var isCapturing: Bool = false
    public var onAudioBufferReceived: ((AVAudioPCMBuffer) -> Void)?
    
    private let converter = AudioFormatConverter()
    
    public init() {}
    
    public func startCapture() throws {
        guard !isCapturing else { return }
        
        let session = AVAudioSession.sharedInstance()
        // playAndRecord 카테고리를 mixWithOthers 및 defaultToSpeaker 옵션과 혼합하여 
        // 외부 앱의 사운드가 재생되는 동시에 마이크를 통해 캡처할 수 있도록 처리합니다.
        try session.setCategory(.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.queue.async {
                do {
                    // 마이크 입력 형식(예: 44.1kHz stereo)을 16kHz mono로 변환
                    let convertedBuffer = try self.converter.convert(buffer: buffer)
                    self.onAudioBufferReceived?(convertedBuffer)
                } catch {
                    print("오디오 포맷 리샘플링 실패: \(error)")
                }
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        isCapturing = true
    }
    
    public func stopCapture() {
        guard isCapturing else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        
        isCapturing = false
    }
}
```

#### 4.2. 포맷 변환 및 리샘플러 설계 (`AudioFormatConverter`)
마이크 입력 `AVAudioPCMBuffer`를 Speech SDK 형식(`16kHz mono, 16-bit linear PCM`)으로 리샘플링합니다.

```swift
import Foundation
import AVFoundation

public final class AudioFormatConverter {
    private let targetFormat: AVAudioFormat
    private var activeConverter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    
    public init() {
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
    
    public func convert(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        
        if self.sourceFormat != inputFormat || activeConverter == nil {
            self.sourceFormat = inputFormat
            self.activeConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        
        guard let converter = activeConverter else {
            throw NSError(domain: "AudioFormatConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "리샘플링 컨버터 생성 실패"])
        }
        
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            throw NSError(domain: "AudioFormatConverter", code: -4, userInfo: [NSLocalizedDescriptionKey: "출력 버퍼 할당 실패"])
        }
        
        var error: NSError?
        var inputBlockCalled = false
        
        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            if inputBlockCalled {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputBlockCalled = true
            outStatus.pointee = .haveData
            return buffer
        }
        
        if let error = error {
            throw error
        }
        
        return outputBuffer
    }
}
```

---

### Phase 5: Picture-in-Picture (PiP) 자막 오버레이 통합

iPadOS는 앱 화면을 이탈했을 때 다른 동영상 스트림 위에 별도 뷰를 플로팅할 수 없으므로, **AVSampleBufferDisplayLayer 기반의 Picture-in-Picture(PiP)** 렌더링 방식을 사용하여 실시간 번역 자막을 홈 화면 및 외부 앱 위에 표시합니다.

#### 5.1. PiP 자막 이미지 렌더러 (`PiPSubtitleRenderer`)
자막 텍스트(영문/국문)를 이미지 데이터 프레임으로 그리는 모듈입니다.
```swift
import UIKit
import CoreMedia
import AVFoundation

public final class PiPSubtitleRenderer {
    private let size = CGSize(width: 800, height: 160)
    
    public init() {}
    
    public func renderSubtitleFrame(original: String, translated: String, opacity: Double) -> CMSampleBuffer? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            // 배경 투명도 설정
            let rect = CGRect(origin: .zero, size: size)
            UIColor.black.withAlphaComponent(opacity).setFill()
            context.fill(rect)
            
            // 영문 텍스트 렌더링
            let originalAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: UIColor.white
            ]
            let originalSize = original.size(withAttributes: originalAttributes)
            let originalRect = CGRect(
                x: (size.width - originalSize.width) / 2,
                y: 20,
                width: originalSize.width,
                height: originalSize.height
            )
            original.draw(in: originalRect, withAttributes: originalAttributes)
            
            // 국문 텍스트 렌더링
            let translatedAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: UIColor.yellow
            ]
            let translatedSize = translated.size(withAttributes: translatedAttributes)
            let translatedRect = CGRect(
                x: (size.width - translatedSize.width) / 2,
                y: 75,
                width: translatedSize.width,
                height: translatedSize.height
            )
            translated.draw(in: translatedRect, withAttributes: translatedAttributes)
        }
        
        return createSampleBuffer(from: image)
    }
    
    private func createSampleBuffer(from image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        
        guard let ctx = context else {
            CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
            return nil
        }
        
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        
        // Sample Buffer로 변환 및 포맷 정보 작성
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let desc = formatDescription else { return nil }
        
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        
        return sampleBuffer
    }
}
```

#### 5.2. PiP 매니저 구축 (`PiPManager`)
`AVSampleBufferDisplayLayer`와 `AVPictureInPictureController`를 활용하여 시스템 PiP 오버레이 세션을 실행하고 렌더링된 자막 프레임을 화면으로 발송합니다.
```swift
import AVKit

public final class PiPManager: NSObject, AVPictureInPictureControllerDelegate {
    public static let shared = PiPManager()
    
    private var sampleLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private let renderer = PiPSubtitleRenderer()
    
    public func setupPiP(with layer: AVSampleBufferDisplayLayer) {
        self.sampleLayer = layer
        
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        
        pipController = AVPictureInPictureController(contentSource: source)
        pipController?.delegate = self
    }
    
    public func startPiP() {
        guard let pip = pipController, !pip.isPictureInPictureActive else { return }
        pip.startPictureInPicture()
    }
    
    public func stopPiP() {
        pipController?.stopPictureInPicture()
    }
    
    public func updateSubtitle(original: String, translated: String, opacity: Double) {
        guard let pip = pipController, pip.isPictureInPictureActive,
              let buffer = renderer.renderSubtitleFrame(original: original, translated: translated, opacity: opacity) else { return }
        
        sampleLayer?.enqueue(buffer)
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .indefinite)
    }
    public func pictureInPictureControllerIsPlaybackActive(_ pictureInPictureController: AVPictureInPictureController) -> Bool { return true }
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newSize: CMVideoFormatDescription) {}
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}
```

---

### Phase 6: SwiftUI 기반 App UI 및 전체 결합

#### 6.1. 메인 App 구조 (`F1TranslationApp.swift`)
```swift
import SwiftUI

@main
struct F1TranslationApp: App {
    @StateObject private var viewModel = SubtitleViewModel(translationService: AppleTranslationService())
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
```

#### 6.2. SwiftUI Local Subtitle View 및 제어 인터페이스 (`ContentView.swift`)
자막 활성화 토글, 번역 상태 표시 및 PiP 기능을 키고 끌 수 있는 제어 화면을 구성합니다.
자막 뷰 하단에는 `.translationTask` 모디파이어를 제공해 `AppleTranslationService`에 세션을 전달합니다.

---

## 3. 검증 계획 및 테스트 케이스 (Validation Plan)

### 3.1. iPad 실기기 테스트 및 검증 시나리오
AVAudioEngine 및 PiP는 iOS/iPadOS 시뮬레이터 상에서 권한 승인 오류나 하드웨어 입출력 부재로 오작동하기 쉽습니다. 따라서 **iPad 실기기(iPad OS 18.0 이상)** 에서의 검증이 필수입니다.

#### TC-01: 마이크 권한 거부 대응성
- **방법**: 앱 최초 실행 시 마이크 권한 요청 팝업에서 "허용 안 함"을 탭합니다.
- **예상 결과**: 자막 활성화 토글 시 에러 알림창이 팝업되며 권한 설정으로 유도하는 안내 문구가 표시되어야 합니다.

#### TC-02: DRM 오디오 동시 재생 및 캡처 검증
- **방법**: Safari에서 DRM이 가미된 미디어나 F1 라이브 방송(F1 TV)을 볼륨 50% 수준으로 재생합니다. 그 상태에서 F1Translation 앱을 Slide Over로 활성화한 뒤 자막 가동을 시작합니다.
- **예상 결과**: DRM 콘텐츠의 재생이 멈추거나 마스킹되지 않고, 스피커로 출력되는 오디오 음성에 비례하여 STT가 정상적으로 영어 문장을 텍스트화해야 합니다.

#### TC-03: Picture-in-Picture(PiP) 활성화 및 연동 검증
- **방법**: 앱 메인 화면에서 "PiP 모드 시작"을 탭하여 플로팅 자막 레이어를 화면에 띄웁니다. 그 후 F1Translation 앱을 아래로 쓸어내려 백그라운드(홈 화면)로 이탈합니다.
- **예상 결과**: 홈 화면 또는 F1 TV 풀스크린 방송 위로 투명/검정 배경의 자막 바가 떠 있어야 하며, STT 인식 및 한글 번역 결과가 실시간으로 PiP 자막 박스 텍스트로 업데이트되어야 합니다.

#### TC-04: 장시간 작동 시 세션 로테이션 (50초 제한 극복)
- **방법**: 오디오 재생 상태를 3분 이상 길게 유지하여 자막 처리를 모니터링합니다.
- **예상 결과**: 50초 경과 시점에 오디오 수집 흐름이 중단되지 않고, 텍스트가 유실 없이 연속적으로 렌더링되어야 합니다.

#### TC-05: 주변 노음(Noise) 내성 및 스피커 인식 한계
- **방법**: 약 10dB 수준의 가벼운 백그라운드 노이즈(선풍기 등)가 존재하는 방 안에서 스피커 볼륨을 30%, 50%, 70%로 바꾸며 STT 정확도를 비교합니다.
- **예상 결과**: 50% 이상 볼륨에서는 F1 해설진의 목소리가 잡음에 묻히지 않고 대략 85% 이상의 단어 정확도로 번역 자막에 나타나야 합니다.
