# Design: F1 실시간 자막 및 번역 앱 (F1Translation)

이 설계 문서는 iOS 18+ / iPadOS 18+ 환경에서 AVAudioEngine 마이크 입력을 사용해 실시간으로 오디오를 캡처하고, SFSpeechRecognizer와 Translation Framework를 활용하여 온디바이스 영어 STT 및 한국어 실시간 번역을 제공하는 앱의 아키텍처 및 구현 사양을 정의합니다.

---

## 1. Goal (목표)
- 가상 오디오 드라이버나 ScreenCaptureKit 없이 iPad의 마이크 입력(AVAudioEngine)을 통한 안정적인 실시간 오디오 수집.
- DRM이 적용된 스트리밍 서비스(F1 TV, Safari 등) 재생 시 화면/오디오 캡처 제한을 우회하기 위해 마이크를 통해 재생되는 외부/물리적 사운드를 수집하는 구조 적용.
- iOS 18+의 Apple Silicon/Neural Engine을 활용하는 고성능 온디바이스 영어 음성 인식 및 한국어 실시간 번역 제공.
- iOS/iPadOS 환경의 제약을 우회하고 백그라운드 및 홈 화면에서도 번역 자막을 표시할 수 있도록 Picture-in-Picture (PiP) 기술을 적용한 Floating Subtitle Overlay 제공.
- 상용 클라우드 서비스로의 교체가 용이하도록 모듈러 프로토콜 기반의 인터페이스 설계 및 의존성 주입(DIP) 보장.

---

## 2. Requirements (요구사항)
- **대상 OS**: iOS 18.0 / iPadOS 18.0 이상 (SFSpeechRecognizer 온디바이스 모드 및 Swift Translation API 탑재 기준).
- **오디오 캡처**:
  - `AVAudioEngine`의 `inputNode`에 Tap을 설치하여 실시간 마이크 오디오 입력 스트림 생성.
  - 타 미디어 앱 오디오와 마이크 수집이 충돌하지 않도록 `AVAudioSession`을 `.playAndRecord` 카테고리 및 `.mixWithOthers`, `.defaultToSpeaker` 옵션으로 설정.
- **STT (Speech-To-Text)**:
  - Apple `SFSpeechRecognizer` 온디바이스 모드를 기본으로 적용하되, 1분 세션 제한을 극복하는 연속 체이닝 아키텍처 설계.
- **번역 (Translation)**:
  - iOS 18+ `Translation` 프레임워크의 `TranslationSession` API를 사용해 비동기/온디바이스로 영어 -> 한국어 번역 수행.
- **UI/UX**:
  - **SwiftUI Local Subtitle View**: Split View 또는 Slide Over 환경에서 앱 내부 오버레이로 작동.
  - **Picture-in-Picture (PiP) Subtitle View**: 백그라운드 구동 시 다른 비디오 위에 떠 있는 형태로 자막을 제공하는 PiP 창 렌더러 구현.
  - 자막의 크기, 투명도(Alpha Value), 자막 언어 조합 설정을 위한 메인 설정 뷰 제공.

---

## 3. Architecture Overview (아키텍처 개요)

전체 시스템은 모듈 간의 결합도(Coupling)를 낮추고 각 클래스의 응집도(Cohesion)를 높이기 위해 **SOLID 설계 원칙**을 엄격히 적용합니다.

```mermaid
graph TD
    Mic[AVAudioEngine Mic Input] -->|AVAudioPCMBuffer| AudioPipeline[AudioCaptureCoordinator]
    AudioPipeline -->|16kHz AVAudioPCMBuffer| SpeechService[SpeechRecognitionService (Protocol)]
    SpeechService -->|SpeechRecognitionResult Stream| SubtitleViewModel[SubtitleViewModel]
    SubtitleViewModel -->|Debounced Text| TranslationService[TranslationService (Protocol)]
    TranslationService -->|Translated Korean Subtitle| SubtitleViewModel
    
    SubtitleViewModel -->|Update Subtitle UI| OverlayView[Subtitle Overlay View]
    SubtitleViewModel -->|Render Subtitles to Image| PiPRenderer[PiPSubtitleRenderer]
    PiPRenderer -->|CMSampleBuffer| PiPDisplayLayer[AVSampleBufferDisplayLayer]
    PiPDisplayLayer -->|PiP Subtitle window| PiPController[AVPictureInPictureController]
    
    OverlayView -->|Provide Session via translationTask| TranslationService
```

### 3.1. SOLID 설계 매핑
1. **SRP (단일 책임 원칙)**:
   - `AudioCaptureCoordinator`: AVAudioEngine 셋업 및 오디오 캡처 라이프사이클 관리만 담당.
   - `AudioFormatConverter`: 입력 오디오 샘플 포맷의 변환 및 리샘플링만 담당.
   - `SpeechRecognitionService`: 오디오 입력을 비동기적으로 텍스트로 전환하고 1분 세션 제한 리셋(Chaining)을 관리하는 단일 목적에 집중.
   - `TranslationService`: 영어 텍스트를 대상 언어 텍스트로 기계 번역하는 단일 목적에 집중.
   - `PiPSubtitleRenderer`: 자막 텍스트 데이터를 받아 CoreGraphics 기반의 이미지 비디오 프레임으로 변환하여 PiP Layer로 방출하는 레이아웃 및 렌더링에만 집중.
2. **OCP (개방-폐쇄 원칙)**:
   - 모든 비즈니스 엔진(음성 인식, 번역)은 프로토콜을 통과하여 결합됩니다. 향후 타 외부 API 기반 구현체가 새로 추가될 때, 기존 서비스 인터페이스를 구현하는 새 구체 클래스를 생성하여 코드 수정 없이 교체 가능합니다.
3. **LSP (리스코프 치환 원칙)**:
   - `SpeechRecognitionService` 및 `TranslationService`를 구현하는 임의의 Mock 또는 실구현 클래스는 상위 프로토콜 규약을 준수하므로 서로 부작용 없이 교체될 수 있습니다.
4. **ISP (인터페이스 분리 원칙)**:
   - 클라이언트(UI 및 뷰모델)가 필요로 하지 않는 복잡한 내부 프레임워크 델리게이트 메서드는 외부에 노출시키지 않고 인터페이스를 필요한 핵심 제어 수단으로만 한정합니다.
5. **DIP (의존 역전 원칙)**:
   - `SubtitleViewModel` 및 UI 컴포넌트는 구체 클래스에 직접 의존하지 않고, 추상화된 프로토콜인 `SpeechRecognitionService` 및 `TranslationService`에 의존합니다. 의존성은 런타임에 초기화 컨테이너를 통해 주입됩니다.

---

## 4. Interface Contract (인터페이스 정의)

### 4.1. Speech Recognition Service

```swift
import Foundation
import AVFoundation

/// 음성 인식 엔진 결과 구조체
public struct SpeechRecognitionResult: Sendable, Equatable {
    public let text: String     // 인식된 전체 문자열 또는 단어
    public let isFinal: Bool    // 문장의 완성 여부 (오디오 입력의 중단 또는 최종 확정 상태)
    
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// 음성 인식 엔진 에러 정의
public enum SpeechRecognitionError: Error, LocalizedError {
    case microphoneAccessDenied
    case recognitionFailed(Error)
    case notAvailable
    
    public var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied: return "마이크 사용 권한이 거부되었습니다."
        case .recognitionFailed(let error): return "음성 인식을 시작할 수 없습니다: \(error.localizedDescription)"
        case .notAvailable: return "음성 인식을 지원하지 않는 환경입니다."
        }
    }
}

/// 음성 인식 엔진을 추상화하는 프로토콜
public protocol SpeechRecognitionService {
    /// 음성 인식 시작 (번역 텍스트의 비동기 스트림을 반환)
    func startRecognition() -> AsyncThrowingStream<SpeechRecognitionResult, Error>
    
    /// 외부에서 음성 인식을 제어하는 시작 메서드 (마이크 입력 우회 여부 포함)
    func startRecognition(isExternalCapture: Bool) -> AsyncThrowingStream<SpeechRecognitionResult, Error>
    
    /// 음성 인식 중단 및 자원 해제
    func stopRecognition()
    
    /// 오디오 캡처 레이어로부터 PCM 버퍼를 공급받는 인터페이스 (DIP 유지)
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer)
}
```

### 4.2. Translation Service

```swift
import Foundation
import Translation

/// 번역 엔진 에러 정의
public enum TranslationServiceError: Error, LocalizedError {
    case translationFailed(Error)
    case invalidInput
    
    public var errorDescription: String? {
        switch self {
        case .translationFailed(let error): return "번역 실행 중 오류가 발생했습니다: \(error.localizedDescription)"
        case .invalidInput: return "유효하지 않은 입력 데이터입니다."
        }
    }
}

/// 번역 엔진을 추상화하는 프로토콜
public protocol TranslationService {
    /// SwiftUI .translationTask로부터 획득한 TranslationSession 주입/업데이트
    func updateSession(_ session: TranslationSession)
    
    /// 입력 텍스트 번역
    func translate(text: String, from source: String, to target: String) async throws -> String
}
```

### 4.3. Audio Capture Service

```swift
import Foundation
import AVFoundation

/// 오디오 수집기를 추상화하는 프로토콜
public protocol AudioCaptureService {
    var isCapturing: Bool { get }
    var onAudioBufferReceived: ((AVAudioPCMBuffer) -> Void)? { get set }
    
    /// 오디오 캡처 시작
    func startCapture() throws
    
    /// 캡처 중단
    func stopCapture()
}
```

---

## 5. Detailed Design Points (세부 설계 방안)

### 5.1. AVAudioEngine 마이크 캡처 및 리샘플링
- **이유**: SFSpeechRecognizer는 `16kHz mono, 16-bit linear PCM` 포맷을 선호합니다. 반면, iPadOS의 마이크 입력(AVAudioEngine inputNode)은 기본적으로 `44.1kHz` 혹은 `48kHz` 스트림을 전달합니다. SFSpeechRecognizer 내부에서 이를 처리할 수도 있으나, 리소스 효율화 및 일정한 입력 품질 유지를 위해 명시적으로 다운샘플링합니다.
- **해결책**:
  1. `AVAudioSession`을 활성화하고 category를 `.playAndRecord`로 설정, 옵션에 `.mixWithOthers`를 적용하여 사용자가 시청 중인 F1 비디오 소리 출력과 마이크 녹음이 공존하게 합니다.
  2. `AudioFormatConverter` 클래스에 `AVAudioConverter`를 정의하여, 입력 노드 샘플 버퍼를 `16kHz, mono, Int16` 타겟 포맷의 `AVAudioPCMBuffer`로 실시간 리샘플링하여 `AppleSpeechRecognitionService`에 입력합니다.

### 5.2. 비동기 처리 병목 해결 및 Debouncing/Cancellation 전략
- **이유**: 사용자가 실시간으로 말하거나 비디오 사운드가 들어올 때 SFSpeechRecognizer는 잦은 임시 결과(`isFinal == false`)를 지속적으로 발생시킵니다. 이를 곧장 번역 API인 `TranslationSession`에 보낼 경우 신경망 로드 병목으로 인해 렉이 생기고 반응 속도가 지연됩니다.
- **해결책**:
  1. **Debounce (디바운스) 적용**: STT에서 넘어오는 텍스트 조각들을 SwiftUI 뷰모델 내에서 디바운싱(약 350ms)하여 의미 있는 정적이 생겼을 때만 실제 번역을 수행합니다.
  2. **Task Cancellation (작업 취소)**: 번역을 수행하는 Task(`translationTask`)를 멤버 변수로 가지며, 디바운싱을 통과하여 새로운 번역이 요청될 때 진행 중인 이전 번역 태스크가 있다면 즉시 `cancel()`을 호출합니다.

### 5.3. TranslationSession의 라이프사이클 및 SwiftUI 연동
- **이유**: Swift Translation 프레임워크는 SwiftUI 뷰 모디파이어인 `.translationTask`가 제공하는 `TranslationSession`을 통해서만 온디바이스 번역 기능이 작동합니다.
- **해결책**:
  1. SwiftUI 자막 뷰 계층에서 `.translationTask` 모디파이어를 선언합니다.
  2. 제공받은 `TranslationSession` 인스턴스를 `TranslationService` 구현체에 주입(`updateSession`)합니다.
  3. 번역 요청이 들어올 때 이 주입된 세션을 경유하여 처리하며, `LanguageAvailability`를 사용하여 영어-한국어 페어가 온디바이스 번역 가능 상태인지 사전 판정합니다.

### 5.4. SFSpeechRecognizer 세션 체이닝 (1분 제한 대응)
- **이유**: SFSpeechRecognizer는 단일 인식 세션 지속 시간이 약 1분으로 제한되어 있습니다. F1 스포츠 경기 중계와 같은 장시간 스트리밍 오디오를 처리하려면 세션의 유실 없는 자동 갱신(Chaining)이 필수적입니다.
- **해결책**:
  1. **타이머 기반 세션 갱신**: 음성 인식이 시작된 지 50초 경과 시, 현재 인식 중인 `SFSpeechAudioBufferRecognitionRequest`에 `endAudio()`를 전송하고 즉시 내부 세션을 교체할 준비를 합니다.
  2. **버퍼 임시 홀딩(Buffering)**: 이전 세션이 완전히 정리되고 새 세션의 `SFSpeechRecognitionTask`가 수립되기까지 약 수백 밀리초의 공백이 발생합니다. 이 과도기 동안 마이크에서 유입되는 오디오 버퍼들은 폐기하지 않고 내부 큐(Queue)에 잠시 홀딩합니다.
  3. **새 세션 개시 및 버퍼 방출**: 새 세션 수립 즉시 큐에 임시 홀딩되어 있던 누적 버퍼들을 순차적으로 새 `SFSpeechAudioBufferRecognitionRequest`에 밀어 넣어 오디오 유실 없는 연속 STT를 보장합니다.

### 5.5. iPadOS Picture-in-Picture(PiP) 기반 Floating Subtitle Overlay
- **이유**: iPadOS는 macOS와 달리 화면 전체에 다른 앱 위에 항상 떠 있는 Window(`NSPanel` 등)를 생성할 수 없습니다. 따라서 백그라운드에서도 자막을 보여주려면 비디오용으로 제작된 Picture-in-Picture(PiP) 기능을 응용해야 합니다.
- **해결책**:
  1. **가상 비디오 스트림 생성**: 번역 결과인 텍스트 데이터를 `UILabel` 또는 CoreGraphics를 사용해 검은색/반투명 배경의 이미지 프레임으로 주기적으로 렌더링합니다.
  2. **CMSampleBuffer 변환**: 렌더링된 이미지를 `CVPixelBuffer`로 변환한 후 시간 정보(Presentation Time Stamp)를 부여하여 `CMSampleBuffer`를 생성합니다.
  3. **AVSampleBufferDisplayLayer 연동**: 생성한 샘플 버퍼를 `AVSampleBufferDisplayLayer`에 공급하여 비디오 프레임 형태로 표출합니다.
  4. **AVPictureInPictureController 가동**: `AVSampleBufferDisplayLayer`를 기반으로 `AVPictureInPictureController`를 셋업하여 사용자가 홈 화면으로 나가거나 F1 비디오 앱을 전체 화면으로 켜더라도 PiP 화면을 통해 번역 자막이 오버레이되도록 처리합니다.

---

## 6. As-is / To-be (구조 비교)

### As-is (macOS 구조)
- **오디오**: ScreenCaptureKit을 사용해 가상 오디오 디바이스 없이 시스템 출력 소리를 direct 캡처.
- **UI**: AppKit `NSPanel` 클래스를 사용하여 마우스 클릭 관통 및 반투명 설정을 거친 Window를 시스템 전역에 플로팅.
- **라이프사이클**: System StatusBar `MenuBarExtra`를 통해 가동 제어.

### To-be (iPadOS 구조)
- **오디오**: `AVAudioEngine` 마이크 인풋 탭으로 iPad 스피커에서 흘러나오는 소리를 녹음 방식으로 우회 캡처(DRM 오디오 캡처 제한 우회).
- **UI**:
  - 앱 내부: SwiftUI 기반 반응형 레이아웃 오버레이 자막 제공.
  - 시스템 전역: 비디오 재생 프레임워크인 PiP(Picture-in-Picture) 기능을 응용하여 실시간 텍스트 프레임을 그리는 방식의 플로팅 자막 오버레이 제공.
- **라이프사이클**: SwiftUI Life cycle 메인 창 내 활성화 버튼 및 백그라운드 감지 코드를 통해 가동 제어.

---

## 7. Impact Analysis (영향도 분석)

| 대상 파일/심볼 | 변경 종류 | 영향 범위 | 주의 사항 |
| :--- | :--- | :--- | :--- |
| `AudioCaptureService.swift` | 수정 | 오디오 캡처 프로토콜 | 플랫폼 종속성 제거를 위해 ScreenCaptureKit 타입 배제 |
| `AudioCaptureCoordinator.swift` | 수정 | 마이크 입력 캡처 구현 | ScreenCaptureKit 제거 및 AVAudioEngine 탭 수집 방식으로 전면 교체 |
| `AudioFormatConverter.swift` | 수정 | PCM 리샘플링 | CMSampleBuffer가 아닌 `AVAudioPCMBuffer`를 인풋으로 받아 리샘플링하도록 리팩토링 |
| `SubtitleOverlayWindow.swift` | 삭제 / 대체 | 플로팅 윈도우 | macOS 전용 `NSPanel` 기반이므로 iOS 빌드 대상에서 제외하고 삭제, PiP 매니저로 대체 |
| `SubtitleOverlayView.swift` | 수정 | 자막 뷰 | PiP 토글 제어 인터페이스 추가 및 디바이스 가로/세로 레이아웃 반응형 지원 |
| `F1TranslationApp.swift` | 수정 | 앱 엔트리 포인트 | `AppDelegate` 제거 및 iPadOS SwiftUI App 구조로 리팩토링 |
| `Sandbox / Entitlements` | 변경 | 시스템 설정 | Sandbox 권한을 제거하고 iOS 마이크 사용 및 Background Mode Capability 추가 |

---

## 8. Migration & Integration Steps (마이그레이션 단계)

1. **설정 구성 및 권한 정의 (1단계)**:
   - 프로젝트 Destination을 iPad로 전환 (iOS 18.0 이상).
   - `Info.plist`에 `NSMicrophoneUsageDescription` 및 `NSSpeechRecognitionUsageDescription` 권한 추가.
   - Background Mode `Audio, AirPlay, and Picture in Picture` Capability 설정.
2. **AVAudioEngine 오디오 파이프라인 연동 (2단계)**:
   - `AudioCaptureCoordinator` 구현을 AVAudioEngine 및 AVAudioSession 설정 코드로 교체.
   - 오디오 출력/스피커 출력 동시 활성화를 위한 카테고리 튜닝.
   - `AudioFormatConverter` 리샘플링 로직 수정.
3. **STT 및 번역 파이프라인 연동 검증 (3단계)**:
   - 마이크에서 들어오는 PCM 버퍼가 Speech Recognition Service로 정상 유입되는지 검증.
   - SFSpeechRecognizer의 세션 체이닝 메커니즘을 마이크 오디오 입력 탭 속도에 맞추어 검증.
4. **Picture-in-Picture 자막 렌더러 설계 및 구축 (4단계)**:
   - `PiPSubtitleRenderer` 및 `PiPManager` 개발.
   - 자막 텍스트 변화 시 CoreGraphics를 통한 텍스트 비디오 프레임 드로잉 및 `AVSampleBufferDisplayLayer` 방출 로직 연동.
5. **실기기 테스트 및 검증 (5단계)**:
   - iPad 기기에서 스피커 오디오를 통해 F1 동영상 재생 및 실시간 STT + 번역 PiP 오버레이 작동 검증.

---

## 9. Rollback Plan (롤백 계획)
- iOS 18의 AVSampleBufferDisplayLayer 기반 PiP 커스텀 렌더러 동작이 실패할 경우, 루핑 애니메이션 또는 투명 비디오 플레이어에 `AVPlayer` 자막 트랙을 실시간으로 갈아끼우는 오프라인 자막 렌더링 폴백 방식을 사용합니다.
- 마이크 볼륨에 따른 인식률 저하 대처를 위해 실시간 볼륨 미터를 UI에 표시하거나 입력 볼륨 부스팅 알고리즘을 포맷 변환 단계에 임시 추가합니다.

---

## 10. Architect's Checklist (체크리스트)
- [ ] `Info.plist`에 마이크 사용 동의 문구 및 음성 인식 동의 문구가 정의되었는가?
- [ ] iOS Background Mode에 오디오 및 PiP 백그라운드 구동 옵션이 포함되었는가?
- [ ] ScreenCaptureKit 및 AppKit(`NSPanel`) 관련 모든 레거시 코드가 빌드 타겟에서 분리 또는 삭제되었는가?
- [ ] `AVAudioSession` 카테고리가 다른 오디오 재생을 방해하지 않도록 `.playAndRecord`와 `.mixWithOthers`로 적절하게 초기화되는가?
- [ ] `AVAudioPCMBuffer`를 대상 규격(16kHz mono)에 맞게 실시간 다운샘플링하는 `AudioFormatConverter`가 설계되었는가?
- [ ] 백그라운드 환경 대응을 위해 `AVPictureInPictureController` 기반 플로팅 자막 아키텍처가 계획되었는가?
- [ ] 빈번한 부분인식 결과가 들어올 때의 디바운싱 및 태스크 취소 메커니즘이 유지되었는가?
