# Design: macOS to iPadOS Migration (iOS 18+ / iPadOS 18+)

This document defines the architectural redesign and migration plan to port the F1Translation App from macOS (AppKit / ScreenCaptureKit) to iPadOS (SwiftUI / AVAudioEngine / Picture-in-Picture).

---

## 1. Goal (목표)
- macOS 전용 프레임워크(ScreenCaptureKit, AppKit) 의존성을 제거하고, iPadOS 18+ 환경에 최적화된 아키텍처로 전환.
- DRM으로 보호된 영상 재생 시 화면 및 오디오가 블랙 마스킹되는 제약을 우회하기 위해, 물리적 오디오를 수집하는 `AVAudioEngine` 마이크 입력 탭 방식 도입.
- NSPanel 기반 플로팅 윈도우를 iPadOS에서 실현하기 위해, 멀티태스킹(Split View / Slide Over) 환경을 위한 SwiftUI 오버레이 뷰와 백그라운드 상주를 위한 Picture-in-Picture(PiP) 자막 오버레이 구조 설계.
- 기존의 모듈러 프로토콜 인터페이스(DIP)를 유지하여 음성 인식 및 번역 비즈니스 로직의 수정을 최소화.

---

## 2. Requirements (요구사항)
- **대상 OS**: iOS 18.0 / iPadOS 18.0 이상.
- **오디오 캡처**:
  - `AVAudioEngine`을 사용한 마이크 입력 노드 탭링.
  - DRM 미디어 오디오 재생과 마이크 수집이 동시에 활성화되도록 `AVAudioSession` 카테고리 구성 (`.playAndRecord` + `.mixWithOthers` + `.defaultToSpeaker`).
- **STT (Speech-To-Text)**:
  - 온디바이스 `SFSpeechRecognizer` 영어 인식 세션 및 50초 주기 세션 체이닝 메커니즘 유지.
- **번역 (Translation)**:
  - iOS 18+ `Translation` 프레임워크의 `TranslationSession` 비동기 번역 API 적용.
- **UI/UX**:
  - **SwiftUI Local Overlay View**: Split View / Slide Over로 앱 실행 시 자막 오버레이 표시.
  - **Picture-in-Picture (PiP) Floating Subtitle**: 백그라운드 구동 시 화면 상단에 자막을 플로팅할 수 있는 PiP 기반 커스텀 비디오 프레임 렌더러 구현.
  - 투명도 및 레이아웃 제어를 위한 인앱 설정 화면.

---

## 3. Architecture Overview (아키텍처 개요)

### As-is / To-be 구조 비교

#### As-is (macOS)
- **Audio Source**: ScreenCaptureKit (`SCStream`) -> `CMSampleBuffer`
- **Format Converter**: `AudioFormatConverter` (CMSampleBuffer -> 16kHz AVAudioPCMBuffer)
- **Speech Service**: `AppleSpeechRecognitionService`
- **Subtitle UI**: `SubtitleOverlayWindow` (`NSPanel`) + `SubtitleOverlayView` (SwiftUI)
- **Controller**: `AppDelegate` (System Status Bar Menu)

#### To-be (iPadOS)
- **Audio Source**: AVAudioEngine Microphone Input Tap -> `AVAudioPCMBuffer`
- **Format Converter**: `AudioFormatConverter` (Resampling input sample rate [e.g., 44.1kHz/48kHz] -> 16kHz mono)
- **Speech Service**: `AppleSpeechRecognitionService` (동일 인터페이스 유지)
- **Subtitle UI**:
  - **In-App**: SwiftUI `SubtitleOverlayView` (Local)
  - **System-wide Floating**: `PiPManager` + `PiPSubtitleRenderer` (AVSampleBufferDisplayLayer 기반 PiP 창)
- **Controller**: SwiftUI App Lifecycle (`F1TranslationApp.swift`) + `SubtitleViewModel`

```mermaid
graph TD
    Mic[AVAudioEngine Mic Input] -->|Raw PCMBuffer| Resampler[AudioFormatConverter]
    Resampler -->|16kHz PCMBuffer| SpeechService[SpeechRecognitionService (Protocol)]
    SpeechService -->|SpeechRecognitionResult Stream| SubtitleViewModel[SubtitleViewModel]
    SubtitleViewModel -->|Debounced English Text| TranslationService[TranslationService (Protocol)]
    TranslationService -->|Translated Korean Subtitle| SubtitleViewModel
    
    SubtitleViewModel -->|Update Subtitle UI| OverlayView[Subtitle Overlay View]
    SubtitleViewModel -->|Render Subtitles to Image| PiPRenderer[PiPSubtitleRenderer]
    PiPRenderer -->|CMSampleBuffer| PiPLayer[AVSampleBufferDisplayLayer]
    PiPLayer -->|PiP Overlay| PiPController[AVPictureInPictureController]
```

---

## 4. Interface Contract (인터페이스 정의)

기존 프로토콜 인터페이스(DIP)를 최대한 유지하되, 플랫폼 독립적으로 정비합니다.

### 4.1. Audio Capture Service
ScreenCaptureKit 의존성을 제거하고 `AVAudioPCMBuffer` 캡처 콜백 기반으로 인터페이스를 유지합니다.

```swift
public protocol AudioCaptureService {
    var isCapturing: Bool { get }
    var onAudioBufferReceived: ((AVAudioPCMBuffer) -> Void)? { get set }
    func startCapture() throws
    func stopCapture()
}
```

### 4.2. Speech Recognition Service
기존과 동일하게 유지되어 데이터 흐름 호환성을 보장합니다.

```swift
public protocol SpeechRecognitionService {
    func startRecognition() -> AsyncThrowingStream<SpeechRecognitionResult, Error>
    func stopRecognition()
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer)
}
```

### 4.3. Translation Service
기존과 동일하게 유지됩니다.

```swift
public protocol TranslationService {
    func updateSession(_ session: TranslationSession)
    func translate(text: String, from source: String, to target: String) async throws -> String
}
```

---

## 5. Impact Scope (영향 범위)

| 파일 경로 | 수정 유형 | 변경 상세 요약 |
| :--- | :--- | :--- |
| `AudioCaptureService.swift` | 수정 | ScreenCaptureKit 관련 주석 제거 및 플랫폼 공통 오디오 버퍼 콜백 프로토콜 정비 |
| `AudioCaptureCoordinator.swift` | 수정 / 재구현 | `SCStreamOutput` 제거, `AVAudioEngine` 마이크 인풋 탭 수집 구현 |
| `AudioFormatConverter.swift` | 수정 | `CMSampleBuffer` 기반 오디오 변환을 제거하고, 마이크 입력 `AVAudioPCMBuffer` 리샘플링 로직으로 간소화 |
| `SubtitleOverlayWindow.swift` | 삭제 / 대체 | macOS AppKit `NSPanel` 클래스 제거. `PiPManager.swift` 도입 |
| `SubtitleOverlayView.swift` | 수정 | iPadOS 크기에 맞는 반응형 자막 뷰로 수정, PiP 제어 버튼 UI 추가 |
| `F1TranslationApp.swift` | 수정 | AppKit `AppDelegate` 제거, SwiftUI Life cycle 및 TabView 기반 모바일 앱 구조로 전환 |
| `SubtitleViewModel.swift` | 수정 | PiP 활성화/비활성화 상태 및 렌더링용 퍼블리셔 추가 |

---

## 6. Migration Steps (마이그레이션 단계)

### Phase 1: 플랫폼 전환 및 권한 셋업
1. Xcode 프로젝트 Target 설정을 macOS에서 iOS / iPadOS (Destination: iPad)로 변경하고 Target SDK 버전을 iOS 18.0+로 설정합니다.
2. `Info.plist`에서 macOS 전용 설정을 제거하고 다음 권한 설명 키를 정의합니다.
   - `NSMicrophoneUsageDescription` (마이크 입력 수집 목적 명시)
   - `NSSpeechRecognitionUsageDescription` (온디바이스 음성 인식 목적 명시)
3. Target Capabilities에서 **Background Modes**를 활성화하고 `Audio, AirPlay, and Picture in Picture`를 체크합니다.

### Phase 2: 마이크 오디오 캡처 파이프라인 구현
1. `AudioCaptureCoordinator`에서 `ScreenCaptureKit`을 제거하고 `AVAudioEngine` 기반 마이크 탭 캡처를 구현합니다.
2. `AVAudioSession`을 활성화하고 오디오 카테고리를 설정하는 라이프사이클 관리를 추가합니다.
3. `AudioFormatConverter`를 수정하여 입력받은 다양한 샘플 레이트의 PCM 버퍼를 `16kHz mono, 16bit Int` 포맷으로 다운샘플링하는 `AVAudioConverter` 로직을 작성합니다.

### Phase 3: STT 및 번역 데이터 흐름 검증
1. 기존 `AppleSpeechRecognitionService` 및 `AppleTranslationService` 프로토콜을 그대로 연동하여 동작 여부를 확인합니다.
2. iPadOS 시뮬레이터 및 실기기에서 마이크 녹음 데이터가 STT 엔진으로 흘러가 정상적으로 텍스트화되는지 디버그 로그로 확인합니다.

### Phase 4: SwiftUI Overlay 및 PiP(Picture-in-Picture) 통합
1. `PiPManager`와 `PiPSubtitleRenderer`를 구축합니다.
   - `PiPSubtitleRenderer`는 전달받은 자막 텍스트를 `UILabel` 또는 CoreGraphics를 통해 이미지로 렌더링하고, 이를 `CMSampleBuffer` 비디오 프레임으로 변환합니다.
   - `AVSampleBufferDisplayLayer`와 `AVPictureInPictureController`를 셋업하여 비디오 프레임을 PiP 창으로 방출합니다.
2. SwiftUI `SubtitleOverlayView` 내에 PiP 제어(시작/중단) 토글 버튼을 제공합니다.

### Phase 5: 실기기 검증 및 안정화
1. 오디오 소리 캡처 시 주변 소음 대비 F1 중계 소리 인식률 테스트를 수행합니다.
2. 실기기(iPad)에서 동영상 재생 앱(Safari 또는 F1 TV)을 켜고 멀티태스킹 및 PiP 오버레이 작동 상태를 확인합니다.

---

## 7. Rollback Plan (롤백 계획)
- iPadOS 빌드 실패 또는 PiP 프레임 렌더러 오동작 시, AVSampleBufferDisplayLayer 방식을 사용하지 않고 iOS 18의 비디오 플레이어 파일 재생 트릭(루핑 비디오 파일에 자막 트랙을 추가하여 PiP 구동)으로 우회 구현합니다.
- 마이크 입력 캡처 지연이 클 경우, 리샘플링 버퍼 크기를 줄이고(1024 frames 이하) 오디오 데이터 수집 큐를 최적화합니다.

---

## 8. Architect's Checklist (체크리스트)
- [ ] iOS 18.0 / iPadOS 18.0 이상 Target 설정이 명시되었는가?
- [ ] `AVAudioSession` 카테고리가 DRM 오디오 동시 재생을 방해하지 않는 `.playAndRecord` + `.mixWithOthers` 옵션으로 설계되었는가?
- [ ] ScreenCaptureKit 코드가 전체 프로젝트에서 완벽히 배제되었는가?
- [ ] NSPanel 기반의 윈도우가 제거되고 SwiftUI View 및 Picture-in-Picture(PiP) 자막 레이어로 아키텍처가 완전히 전환되었는가?
- [ ] `AudioCaptureService` 및 `SpeechRecognitionService` 사이의 DIP 의존성 관계가 흐트러지지 않았는가?
- [ ] 백그라운드 자막 유지를 위해 Background Modes `Audio, AirPlay, and Picture in Picture` 설정 가이드라인이 구현 계획에 포함되었는가?
