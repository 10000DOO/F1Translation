# Implementation Plan: F1 Translation App

본 문서는 macOS 15+ 기반의 실시간 시스템 오디오 캡처, 온디바이스 STT 및 번역, Floating Subtitle Overlay 애플리케이션 개발을 위한 단계별 구현 가이드 및 검증 시나리오를 정의합니다.

---

## 1. 구현 로드맵 및 단계별 가이드 (Phase 1 ~ Phase 6)

### Phase 1: 프로젝트 기반 설정 및 시스템 권한 정의

#### 1.1. 권한 키 선언 (Info.plist)
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>실시간 자막 생성을 위해 온디바이스 음성 인식을 사용합니다.</string>
<key>NSMicrophoneUsageDescription</key>
<string>오디오 캡처를 지원하기 위해 마이크 권한이 필요합니다.</string>
```

#### 1.2. App Sandbox 및 Entitlements
ScreenCaptureKit으로 시스템 오디오를 캡처할 때, macOS Sandbox 환경에서는 시스템 오디오에 액세스하기 위해 `com.apple.security.device.audio-input` 및 `com.apple.security.temporary-exception.mach-lookup.global-name` 등의 예외 설정이 필요할 수 있습니다. 
만약 Sandbox 환경에서 차단이 발생할 경우를 대비하여 Sandbox 활성화/비활성화 시의 동작을 사전에 테스트하고, Target Settings에서 Screen Recording 권한을 획득하도록 구현합니다.

---

### Phase 2: Core Interface 및 Mock 엔진 설계

#### 2.1. 캡처, STT, 번역 인터페이스 정의
`design_f1_translation.md`에 명시된 `SpeechRecognitionService`, `TranslationService`, `AudioCaptureService` 프로토콜을 각각의 개별 파일로 분리하여 선언합니다.

#### 2.2. Mock 구현을 통한 아키텍처 조립
실제 오디오 캡처 장비나 API가 완성되기 전에 전체적인 UI 데이터 흐름을 점검하기 위해 Mock 클래스를 구현합니다.
- `MockSpeechRecognitionService`: 1초 간격으로 영어 텍스트 조각을 발행하는 `AsyncThrowingStream`을 반환합니다.
- `MockTranslationService`: 입력 영문 뒤에 `"[번역완료]"`를 붙여 반환하는 초간단 지연 모듈을 구성합니다.

---

### Phase 3: 온디바이스 STT 및 번역 엔진 구현

#### 3.1. Apple Speech Engine (`AppleSpeechRecognitionService`) 구현
`SFSpeechRecognizer`의 1분 세션 한계를 극복하기 위해 **세션 체이닝(Session Chaining)** 메커니즘을 반영한 실시간 음성 인식 서비스 예시 코드입니다.

```swift
import Foundation
import Speech
import CoreMedia

class AppleSpeechRecognitionService: SpeechRecognitionService {
    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // 세션 체이닝을 위한 상태 변수
    private var sessionStartTime: Date?
    private var isResettingSession = false
    private var temporaryAudioBufferQueue: [CMSampleBuffer] = []
    private let sessionDurationLimit: TimeInterval = 50.0 // 50초 단위로 순환
    
    var isRunning: Bool = false
    private var continuation: AsyncThrowingStream<SpeechRecognitionResult, Error>.Continuation?
    
    init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
    
    func startRecognition() async throws -> AsyncThrowingStream<SpeechRecognitionResult, Error> {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw SpeechRecognitionError.onDeviceNotAvailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechRecognitionError.onDeviceNotAvailable
        }
        
        isRunning = true
        
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            setupNewRecognitionSession()
            
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.stopRecognition()
                }
            }
        }
    }
    
    /// 새로운 인식 세션 수립
    private func setupNewRecognitionSession() {
        guard isRunning, let recognizer = recognizer else { return }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        
        isResettingSession = false
        sessionStartTime = Date()
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                // 세션 교체 중의 취소 에러는 예외 처리
                let nsError = error as NSError
                if nsError.domain == kCLErrorDomain || nsError.code == 203 { // 203: Task Cancelled
                    return
                }
                self.continuation?.finish(throwing: error)
                return
            }
            
            if let result = result {
                let bestTranscription = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                
                self.continuation?.yield(SpeechRecognitionResult(text: bestTranscription, isFinal: isFinal))
                
                if isFinal && !self.isResettingSession {
                    self.continuation?.finish()
                }
            }
        }
        
        // 큐에 대기 중이던 임시 버퍼들 방출
        flushBufferedSamples()
    }
    
    /// 50초 제한 도달 시 기존 세션을 안전하게 정리하고 다음 세션으로 교체
    private func rotateSession() {
        guard isRunning, !isResettingSession else { return }
        isResettingSession = true
        
        // 기존 세션 완료 요청
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        
        recognitionTask = nil
        recognitionRequest = nil
        
        // 즉시 새로운 세션 개설
        setupNewRecognitionSession()
    }
    
    func stopRecognition() async {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRunning = false
        continuation = nil
        temporaryAudioBufferQueue.removeAll()
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else { return }
        
        // 세션 교체 중일 경우 버퍼를 임시 큐에 누적하여 누수 방지
        if isResettingSession {
            temporaryAudioBufferQueue.append(sampleBuffer)
            return
        }
        
        // 세션 지속 시간 체크
        if let startTime = sessionStartTime, Date().timeIntervalSince(startTime) > sessionDurationLimit {
            rotateSession()
            temporaryAudioBufferQueue.append(sampleBuffer)
            return
        }
        
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }
    
    private func flushBufferedSamples() {
        guard let request = recognitionRequest, !isResettingSession else { return }
        for buffer in temporaryAudioBufferQueue {
            request.appendAudioSampleBuffer(buffer)
        }
        temporaryAudioBufferQueue.removeAll()
    }
}
```

#### 3.2. Translation Framework (`AppleTranslationService`) 구현
SwiftUI `.translationTask` 모디파이어를 통해 획득한 `TranslationSession`을 전달받아 구동되도록 설계된 번역 서비스의 예시 코드입니다.

```swift
import Foundation
import Translation
import SwiftUI

class AppleTranslationService: TranslationService {
    private var activeSession: TranslationSession?
    
    func updateSession(_ session: TranslationSession) {
        self.activeSession = session
    }
    
    func translate(text: String) async throws -> String {
        guard let session = activeSession else {
            throw TranslationServiceError.sessionNotAvailable
        }
        
        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            throw TranslationServiceError.translationFailed(error)
        }
    }
}

// macOS 15+ LanguageAvailability를 활용한 로컬 모델 가용성 사전 검사 기능
class TranslationAvailabilityChecker {
    func checkAvailability() async -> Bool {
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: "en"),
            to: Locale.Language(identifier: "ko")
        )
        
        switch status {
        case .installed:
            return true
        case .supported:
            // 지원되나 다운로드가 필요한 상태
            return false
        case .unsupported:
            return false
        @unknown default:
            return false
        }
    }
}
```

---

### Phase 4: ScreenCaptureKit 오디오 파이프라인 개발

#### 4.1. ScreenCaptureKit 오디오 단독 스트림 구성
비디오 스트림 처리를 배제하고 오직 오디오 정보만 캡처하여 최적의 성능을 낼 수 있도록 구현한 오디오 캡처 매니저 예시 코드입니다. (가짜 비디오 프레임 변환 트릭 배제)

```swift
import Foundation
import ScreenCaptureKit
import AVFoundation

class AudioCaptureCoordinator: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var onAudioBufferReceived: ((CMSampleBuffer) -> Void)?
    
    func startAudioCapture(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        // 오디오 정보만 활성화
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        
        // 중요: addStreamOutput 호출 시 type을 .audio로만 단독 등록
        // 이 구조를 취하면 비디오 수신 및 가공에 따르는 어떠한 리소스 소모도 발생하지 않습니다.
        try stream?.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "audio.capture.queue")
        )
        
        try await stream?.startCapture()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onAudioBufferReceived?(sampleBuffer)
    }
    
    func stopCapture() async throws {
        try await stream?.stopCapture()
        stream = nil
    }
}
```

#### 4.2. 포맷 변환 및 리샘플러 설계 (`AudioFormatConverter`)
ScreenCaptureKit의 PCM 샘플(예: Float32)을 Speech SDK가 요구하는 포맷으로 실시간 다운샘플링합니다.
```swift
import AVFoundation

class AudioFormatConverter {
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    
    func convert(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let inputFormat = AVAudioFormat(cmAudioFormatDescription: CMSampleBufferGetFormatDescription(sampleBuffer)!) else { return nil }
        
        if converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        
        guard let converter = converter else { return nil }
        
        // CMSampleBuffer를 AVAudioPCMBuffer로 디코딩 후 변환
        // ... AVAudioConverter.convert(to:outputBuffer:error:withInputFrom:) 메서드를 이용한 실시간 변환 로직 탑재 ...
        return nil
    }
}
```

---

### Phase 5: Floating UI & Window

#### 5.1. NSPanel 기반 Subtitle Window 제어
```swift
import AppKit
import SwiftUI

class SubtitleOverlayWindow: NSPanel {
    init(contentView: AnyView) {
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 150),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        
        self.contentView = NSHostingView(rootView: contentView)
    }
    
    func toggleClickThrough(_ isEnabled: Bool) {
        if isEnabled {
            self.ignoresMouseEvents = true
        } else {
            self.ignoresMouseEvents = false
        }
    }
}
```

#### 5.2. Debounce 및 비동기 병목을 해결하는 ViewModel 구조 (`SubtitleViewModel`)
STT 부분 결과로 인한 비동기 연산 병목을 해결하기 위한 **Debouncing** 및 **Task Cancellation** 패턴의 뷰모델 적용 상세 예시입니다.

```swift
import SwiftUI
import Combine

@MainActor
class SubtitleViewModel: ObservableObject {
    @Published var englishSubtitle: String = ""
    @Published var koreanSubtitle: String = ""
    @Published var isClickThrough: Bool = false
    @Published var overlayOpacity: Double = 0.6
    
    private let speechService: SpeechRecognitionService
    private let translationService: TranslationService
    
    private var translationTask: Task<Void, Never>?
    private var debounceTimer: Timer?
    
    init(speechService: SpeechRecognitionService, translationService: TranslationService) {
        self.speechService = speechService
        self.translationService = translationService
    }
    
    /// 실시간 STT 업데이트 반영 및 번역 요청 디바운스
    func handleSpeechResult(_ result: SpeechRecognitionResult) {
        self.englishSubtitle = result.text
        
        // 이전 디바운스 타이머 리셋
        debounceTimer?.invalidate()
        
        if result.isFinal {
            // 문장이 완전히 끝난 경우 디바운스 없이 즉시 고성능 번역 요청
            triggerTranslation(for: result.text)
        } else {
            // 부분 일치 결과(실시간 텍스트)의 경우, 350ms 대기 후 번역 호출
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.triggerTranslation(for: result.text)
                }
            }
        }
    }
    
    /// 비동기 병목 및 리소스 낭비를 막기 위한 번역 태스크 취소 및 처리
    private func triggerTranslation(for text: String) {
        // 이미 진행 중인 번역 Task가 있다면 즉시 취소하여 스레드 경합 방지
        translationTask?.cancel()
        
        translationTask = Task {
            do {
                // Task가 취소되었는지 확인하여 불필요한 번역 API 호출 예방
                try Task.checkCancellation()
                
                let translated = try await translationService.translate(text: text)
                
                try Task.checkCancellation()
                
                self.koreanSubtitle = translated
            } catch is CancellationError {
                // Task가 취소된 경우 아무 작업도 하지 않음
            } catch {
                print("Translation Error: \(error.localizedDescription)")
            }
        }
    }
}
```

---

### Phase 6: 메뉴바 & 통합 및 SwiftUI 세션 바인딩

#### 6.1. MenuBarExtra 연동 및 전역 제어
SwiftUI `MenuBarExtra` 또는 `NSStatusItem`을 활용해 시스템 상태 바 메뉴를 로드합니다.
- 메뉴에서 타겟 앱 목록 갱신 및 선택 이벤트를 바인딩합니다.
- `Cmd + Option + C` 키 입력 이벤트를 감지하여 `SubtitleOverlayWindow` 인스턴스의 `toggleClickThrough`를 실시간 호출하도록 연동합니다.

#### 6.2. SwiftUI View 계층의 세션 획득 및 업데이트 연동
```swift
import SwiftUI
import Translation

struct SubtitleOverlayView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    let translationService: TranslationService
    
    var body: some View {
        VStack {
            Text(viewModel.englishSubtitle)
                .font(.title2)
                .foregroundColor(.white)
            Text(viewModel.koreanSubtitle)
                .font(.title)
                .bold()
                .foregroundColor(.yellow)
        }
        .padding()
        // SwiftUI 번역 태스크 트리거로 세션 동적으로 획득
        .translationTask(
            .init(source: .init(identifier: "en"), target: .init(identifier: "ko"))
        ) { session in
            // 획득한 세션을 TranslationService에 동적으로 전달
            translationService.updateSession(session)
            
            // 세션 유효 기간 동안 대기 구조 유지
            try? await Task.sleep(nanoseconds: UInt64.max)
        }
    }
}
```

---

## 2. 검증 계획 및 테스트 케이스 (Validation Plan)

### 2.1. 유닛 테스트 시나리오
- **STT 세션 체이닝(Chaining) 유효성**:
  - 인식기를 활성화하고 100초 동안 임의의 오디오 데이터를 흘려보냈을 때, 50초 경과 시점에 정상적으로 `rotateSession()`이 트리거되는지, 그 전후로 들어온 데이터가 유실되지 않고 병합되어 출력되는지 검증.
- **번역 태스크 취소성 테스트**:
  - `TranslationService` 호출 도중 `Task.cancel()`이 트리거되었을 때, `CancellationError`가 정상 검출되며 가중치 연산 스레드 점유율이 0%로 빠르게 수렴하는지 확인.

### 2.2. 매뉴얼 테스트 시나리오 (Checklist)

| ID | 테스트 분류 | 시나리오 및 기대 동작 | 상태 |
| :--- | :--- | :--- | :--- |
| **TC-01** | 번역 병목 검증 | 영어 오디오를 5초간 쉬지 않고 발성하여 STT 텍스트가 수십 차례 변동할 때, CPU 사용률이 50%를 넘지 않고 마지막 최종 한글 자막이 0.5초 이내에 출력되는가? | |
| **TC-02** | 모델 설치 폴백 | 로컬 번역 모델이 아직 설치되지 않은 청정 macOS 환경에서 실행 시, 오류로 크래시가 나지 않고 "모델 다운로드 대기 중" 알림이 오버레이에 정상 표출되는가? | |
| **TC-03** | 클릭 통과 | `ignoresMouseEvents` 속성이 true일 때, 자막 영역 내부를 정확히 클릭해도 하단의 브라우저나 데스크톱 파일이 무리 없이 선택되는가? | |
| **TC-04** | 화면 영역 복구 | 해상도 변경 혹은 모니터 연결이 해제된 이후에도 자막 오버레이 윈도우가 가시 영역 내로 자동 배치되는가? | |
| **TC-05** | 오디오 단독 점유 | ScreenCaptureKit 구동 시 CPU 프로파일러 상에서 Video 관련 렌더 프레임워크 스택이 호출되지 않는가? | |
| **TC-06** | 1분 한계 돌파 | 오디오 캡처를 지속한 지 3분 이상 지난 상태에서도 끊임 없이 영문 텍스트 인식이 들어오는가? | |
