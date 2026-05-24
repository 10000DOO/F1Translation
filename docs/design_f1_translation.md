# Design: F1 실시간 자막 및 번역 앱 (F1Translation)

이 설계 문서는 macOS 15+ 환경에서 ScreenCaptureKit을 사용해 가상 오디오 드라이버 없이 시스템 및 특정 애플리케이션의 오디오를 실시간으로 캡처하고, SFSpeechRecognizer와 Translation Framework를 활용하여 온디바이스 영어 STT 및 한국어 실시간 번역을 제공하는 앱의 아키텍처 및 구현 사양을 정의합니다.

---

## 1. Goal (목표)
- 가상 오디오 드라이버 설치 없이 ScreenCaptureKit API를 사용한 시스템 및 개별 앱 오디오의 안정적인 실시간 수집.
- macOS 15+의 Apple Silicon/Neural Engine을 활용하는 고성능 온디바이스 영어 음성 인식 및 한국어 실시간 번역.
- 윈도우 속성(항상 위, 클릭 통과 토글, 투명도 조절, 드래그 이동)을 자유롭게 제어할 수 있는 Floating Subtitle Overlay 제공.
- 상용 클라우드 서비스(OpenAI Whisper, DeepL 등)로의 교체가 용이하도록 모듈러 프로토콜 기반의 인터페이스 설계 및 의존성 주입(DIP) 보장.

---

## 2. Requirements (요구사항)
- **대상 OS**: macOS 15.0 이상 (SFSpeechRecognizer 온디바이스 개선 및 Swift Translation API 탑재 기준).
- **오디오 캡처**: ScreenCaptureKit을 활용한 무설치형 시스템/개별 앱 오디오 캡처 스트림 생성.
- **STT (Speech-To-Text)**: Apple `SFSpeechRecognizer` 온디바이스 모드를 기본으로 적용하되, 확장 가능한 스트리밍 API 설계.
- **번역 (Translation)**: macOS 15+ `Translation` 프레임워크의 `Translator` API를 사용해 비동기/온디바이스로 영어 -> 한국어 번역 수행.
- **UI/UX**: 
  - Floating Subtitle Overlay (자막 표시용 반투명 윈도우).
  - 마우스 클릭 통과(Click-Through) 활성화/비활성화 토글.
  - 자막 배경 불투명도(Alpha Value) 슬라이더 조절 기능.
  - 마우스 드래그를 통한 자유로운 위치 이동(단, 클릭 통과가 꺼져있을 때 가능).
  - 메뉴바(MenuBarExtra) 아이콘을 통한 설정 및 모드 토글 제어.

---

## 3. Architecture Overview (아키텍처 개요)

전체 시스템은 모듈 간의 결합도(Coupling)를 낮추고 각 클래스의 응집도(Cohesion)를 높이기 위해 **SOLID 설계 원칙**을 엄격히 적용합니다.

```mermaid
graph TD
    SCKit[ScreenCaptureKit Stream] -->|CMSampleBuffer| AudioPipeline[AudioCaptureCoordinator]
    AudioPipeline -->|AVAudioPCMBuffer| SpeechService[SpeechRecognitionService (Protocol)]
    SpeechService -->|SpeechRecognitionResult Stream| SubtitleViewModel[SubtitleViewModel]
    SubtitleViewModel -->|Debounced Text| TranslationService[TranslationService (Protocol)]
    TranslationService -->|Translated Korean Subtitle| SubtitleViewModel
    SubtitleViewModel -->|Update Subtitle UI| OverlayView[Subtitle Overlay View]
    
    MenuBar[MenuBar Control Panel] -->|Toggle Click-Through / Transparency| WindowController[SubtitleOverlayWindowController]
    WindowController -->|Control NSWindow Property| OverlayWindow[SubtitleOverlayWindow]
```

### 3.1. SOLID 설계 매핑
1. **SRP (단일 책임 원칙)**:
   - `AudioCaptureCoordinator`: ScreenCaptureKit 셋업 및 오디오 버퍼 가로채기(Intercepting)만 담당.
   - `AudioFormatConverter`: PCM 샘플 포맷 변환 및 리샘플링만 담당.
   - `SpeechRecognitionService`: 오디오 입력을 비동기적으로 텍스트로 전환하는 단일 목적에 집중.
   - `TranslationService`: 영어 텍스트를 대상 언어 텍스트로 기계 번역하는 단일 목적에 집중.
   - `SubtitleOverlayWindowController`: 자막이 표현되는 윈도우의 속성(레벨, 투명도, 클릭 통과 등) 제어만 담당.
2. **OCP (개방-폐쇄 원칙)**:
   - 모든 비즈니스 엔진(음성 인식, 번역)은 프로토콜을 통과하여 결합됩니다. 향후 OpenAI Whisper나 DeepL 같은 상용 API 기반 구현체가 새로 추가될 때, 기존 서비스 인터페이스를 구현하는 새 구체 클래스를 생성하여 코드 수정 없이 교체 가능합니다.
3. **LSP (리스코프 치환 원칙)**:
   - `SpeechRecognitionService` 및 `TranslationService`를 구현하는 임의의 Mock 또는 실구현 클래스(`AppleSpeechRecognitionService`, `WhisperSpeechRecognitionService` 등)는 상위 프로토콜 규약(동작, 에러 던지기 등)을 준수하므로 서로 부작용 없이 교체될 수 있습니다.
4. **ISP (인터페이스 분리 원칙)**:
   - 클라이언트(UI 및 뷰모델)가 필요로 하지 않는 복잡한 내부 프레임워크 델리게이트 메서드는 외부에 노출시키지 않고 인터페이스를 필요한 핵심 제어 수단으로만 한정합니다.
5. **DIP (의존 역전 원칙)**:
   - `SubtitleViewModel` 및 UI 컴포넌트는 구체 클래스에 직접 의존하지 않고, 추상화된 프로토콜인 `SpeechRecognitionService` 및 `TranslationService`에 의존합니다. 의존성은 런타임에 초기화 컨테이너를 통해 주입됩니다.

---

## 4. Interface Contract (인터페이스 정의)

### 4.1. Speech Recognition Service

```swift
import Foundation
import CoreMedia

/// 음성 인식 엔진 결과 구조체
struct SpeechRecognitionResult: Equatable {
    let text: String     // 인식된 전체 문자열 또는 단어
    let isFinal: Bool    // 문장의 완성 여부 (오디오 입력의 중단 또는 최종 확정 상태)
}

/// 음성 인식 엔진 에러 정의
enum SpeechRecognitionError: LocalizedError {
    case notAuthorized
    case onDeviceNotAvailable
    case failedToStart(Error)
    case streamClosed
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "음성 인식 사용 권한이 거부되었습니다."
        case .onDeviceNotAvailable: return "온디바이스 음성 인식을 지원하지 않는 환경입니다."
        case .failedToStart(let error): return "음성 인식을 시작할 수 없습니다: \(error.localizedDescription)"
        case .streamClosed: return "음성 인식 스트림이 강제로 닫혔습니다."
        }
    }
}

/// 음성 인식 엔진을 추상화하는 프로토콜
protocol SpeechRecognitionService: AnyObject {
    /// 현재 인식기 동작 여부
    var isRunning: Bool { get }
    
    /// 음성 인식 시작 (번역 텍스트의 비동기 스트림을 반환)
    func startRecognition() async throws -> AsyncThrowingStream<SpeechRecognitionResult, Error>
    
    /// 음성 인식 중단 및 자원 해제
    func stopRecognition() async
    
    /// 오디오 캡처 레이어로부터 샘플 버퍼를 공급받는 인터페이스
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer)
}
```

### 4.2. Translation Service

```swift
import Foundation

/// 번역 엔진 에러 정의
enum TranslationServiceError: LocalizedError {
    case modelNotPrepared
    case translationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .modelNotPrepared: return "온디바이스 번역 모델이 준비되지 않았습니다."
        case .translationFailed(let error): return "번역 실행 중 오류가 발생했습니다: \(error.localizedDescription)"
        }
    }
}

/// 번역 엔진을 추상화하는 프로토콜
protocol TranslationService: AnyObject {
    /// 번역 가용 여부 및 온디바이스 한국어 번역 모델 탑재 여부 체크 및 사전 로드
    func prepareTranslator() async throws
    
    /// 입력 텍스트 번역
    /// - Parameters:
    ///   - text: 영어 텍스트
    /// - Returns: 번역된 한국어 텍스트
    func translate(text: String) async throws -> String
}
```

### 4.3. Audio Capture Service

```swift
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 오디오 수집기를 추상화하는 프로토콜
protocol AudioCaptureService: AnyObject {
    var isCapturing: Bool { get }
    
    /// 캡처 대상(디스플레이 및 애플리케이션) 리스트 조회
    func fetchShareableContent() async throws -> SCShareableContent
    
    /// 오디오 캡처 시작
    /// - Parameters:
    ///   - filter: 캡처할 애플리케이션 혹은 디스플레이 필터
    ///   - onSampleCaptured: CMSampleBuffer 수신 시 호출될 콜백
    func startCapture(filter: SCContentFilter, onSampleCaptured: @escaping (CMSampleBuffer) -> Void) async throws
    
    /// 캡처 중단
    func stopCapture() async throws
}
```

---

## 5. Detailed Design Points (세부 설계 방안)

### 5.1. ScreenCaptureKit 오디오 포맷 리샘플링 설계 (AVAudioConverter)
- **이유**: `SFSpeechAudioBufferRecognitionRequest`는 일반적으로 `16kHz, 16-bit linear PCM` 포맷을 필요로 하지만, ScreenCaptureKit(`SCStream`)은 디바이스 환경 및 소스 앱에 따라 다른 PCM 포맷(예: `48kHz Float32`)을 제공합니다.
- **해결책**: `AudioFormatConverter` 클래스를 생성하여 `SCStreamOutput`에서 넘어오는 `CMSampleBuffer`를 받아 `AVAudioPCMBuffer`로 읽어 들인 뒤, `AVAudioConverter`를 통해 타겟 포맷인 `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)`로 실시간 다운샘플링합니다.

### 5.2. 비동기 처리 병목 해결 및 Debouncing/Cancellation 전략
- **이유**: 사용자가 실시간으로 말할 때 `SFSpeechRecognizer`는 음절 단위의 잦은 부분 인식 결과(`isFinal == false`)를 다량으로 쏟아냅니다. 이를 즉시 번역 모델(온디바이스 `Translator`)에 매번 비동기로 전달하면 심각한 스레드 경합(Thread Contention) 및 신경망 계산 병목이 발생하여 UI가 얼거나 레이턴시가 수 초 이상 벌어집니다.
- **해결책**:
  1. **Debounce (디바운스) 적용**: 수신되는 임시 텍스트 스트림을 SwiftUI 뷰모델 내부에서 디바운싱(예: 350ms)합니다. 이 시간 동안 새로운 텍스트 파편이 들어오지 않을 때만 최종 번역 연산을 요청합니다.
  2. **Task Cancellation (작업 취소)**: 번역을 수행하는 Task(`translationTask`)를 뷰모델의 멤버 변수로 유지하며, 새로운 텍스트가 디바운스를 거쳐 유효 번역 요청으로 격상될 때, 이전에 실행 중이던 번역 비동기 Task가 있다면 즉시 `cancel()`을 호출하여 불필요한 번역 계산을 중단시킵니다.
  3. **Sentence Segment Filtering**: 이전 텍스트와 현재 텍스트를 비교하여 어휘나 의미 구조가 실질적으로 바뀌지 않은 경우(예: 화이트스페이스 차이 등) 번역 호출을 스킵하는 최적화 패스(Filter)를 추가합니다.

### 5.3. Floating Window UI 및 AppKit-SwiftUI 하이브리드 제어
- **윈도우 레벨링 및 트래킹**: `NSPanel`을 사용해 `level = .statusBar`로 띄워 메인 메뉴바 및 타 앱 윈도우 위로 항상 노출시킵니다.
- **Click-Through (클릭 통과)**: 
  - `ignoresMouseEvents = true`일 때는 마우스 클릭이 창을 통과하여 뒤에 있는 사물을 클릭합니다.
  - `ignoresMouseEvents = false`일 때는 마우스 드래그를 통해 자막창 위치를 이동시키고, 불투명도 슬라이더 등 내부 위젯을 조작할 수 있습니다.
  - 이 두 모드의 전환은 윈도우 하단에 배치된 스위치 버튼이나 트레이 아이콘을 통해 가능하게 설계하고, 상태가 바뀔 때 윈도우의 속성을 동적으로 수정하도록 구현합니다.

---

## 6. As-is / To-be (구조 비교)

### As-is (현재 상태)
- 프로젝트에 빈 SwiftUI 템플릿(ContentView.swift, F1TranslationApp.swift)만 존재하는 상태입니다.
- 오디오 캡처, 온디바이스 STT, 번역, 오버레이 윈도우 기능이 전혀 구현되어 있지 않습니다.

### To-be (목표 상태)
- 캡처, STT, 번역의 역할이 인터페이스(Protocol) 단위로 분리되어 의존성 주입 구조를 갖춥니다.
- 메뉴 바에 백그라운드 구동을 위한 Tray 아이콘이 제공되며, 자막 윈도우는 화면의 특정 오버레이 레이어로 떠서 실시간 자막을 제공합니다.
- `Translation`과 `Speech` 프레임워크는 로컬 온디바이스 신경망 하드웨어를 사용하여 무부하 실시간 번역을 수행합니다.

---

## 7. Impact Analysis (영향도 분석)

| 대상 파일/심볼 | 변경 종류 | 영향 범위 | 주의 사항 |
| :--- | :--- | :--- | :--- |
| `F1TranslationApp.swift` | 수정 | 앱 라이프사이클 및 메뉴바 셋업 | AppDelegate 또는 SwiftUI `MenuBarExtra` 기반의 상주형(Agent) 앱 설정 필요 |
| `ContentView.swift` | 미사용/대체 | 기본 UI 삭제 및 관리 UI로 대체 | 메인 설정 패널 또는 튜토리얼 뷰로 전환 |
| `Info.plist` (또는 프로젝트 설정) | 추가 | 마이크 권한, 스크린 레코딩 권한 | `NSSpeechRecognitionUsageDescription` 권한 필수 정의 필요 |
| `Sandbox / Entitlements` | 변경 | 앱 샌드박스 설정 및 ScreenCaptureKit 연동 | `Screen Recording` 권한이 요청되는지, Sandbox 환경에서의 ScreenCaptureKit 작동 가능 범위를 확인 |

---

## 8. Migration & Integration Steps (마이그레이션 단계)

1. **설정 구성 및 권한 정의 (1단계)**:
   - `Info.plist`에 `NSSpeechRecognitionUsageDescription` 권한 추가.
   - ScreenCaptureKit 사용을 위해 앱의 Entitlements 및 Target 세팅 확인.
2. **프로토콜 및 핵심 엔진 구현 (2단계)**:
   - `SpeechRecognitionService` 및 `TranslationService` 선언 및 온디바이스 구현체 개발.
   - 온디바이스 Translation 프레임워크 모델 상태 감지 코드 추가.
3. **ScreenCaptureKit 오디오 파이프라인 연동 (3단계)**:
   - `AudioCaptureCoordinator` 구현.
   - SCStream의 오디오 PCM 버퍼를 Speech Recognizer로 연결하는 오디오 리샘플링/전달 레이어 개발.
4. **Overlay Window 및 SwiftUI 뷰 결합 (4단계)**:
   - `SubtitleOverlayWindow` 및 `SubtitleOverlayView` 구현.
   - 투명도 조절, 클릭 통과 토글 및 윈도우 Drag 처리 로직 검증.
5. **메뉴 바 앱 구성 및 최종 검증 (5단계)**:
   - `MenuBarExtra` 구성 또는 System StatusBar Item을 통한 온/오프 제어 컨트롤 및 단축키 추가.

---

## 9. Rollback Plan (롤백 계획)
- 온디바이스 번역 프레임워크(Translation.framework) 로드 실패 시, 에러 모달을 띄우고 앱 구동을 멈추거나 기존 텍스트(영문)만 노출하는 폴백(Fallback) 방식을 채택합니다.
- 특정 macOS 15 세부 마이너 버전 버그 등으로 번역 API 작동 실패 시, 텍스트 미제공 대신 오류 로깅 후 "번역기 초기화 실패" 상태를 Overlay에 임시 출력하도록 설계합니다.

---

## 10. Architect's Checklist (체크리스트)
- [ ] `Info.plist`에 Speech Recognition 관련 사용 설명 필드가 추가되었는가?
- [ ] ScreenCaptureKit은 비디오 스트림 렌더링 부하를 회피하기 위해 최소 사양의 스트림 포맷으로 튜닝되어 설계되었는가?
- [ ] `SFSpeechRecognizer`에 `requiresOnDeviceRecognition = true` 옵션이 들어가 온디바이스 동작을 보장하는가?
- [ ] `Translation` 프레임워크의 온디바이스 한국어 언어팩 가용성을 사전에 검증할 수 있는 상태 체킹 장치가 마련되었는가?
- [ ] `ignoresMouseEvents` 토글 시, 사용자가 자막창을 잃어버리지 않도록 외부 메뉴바에서 클릭 통과 상태를 명확히 끄고 켤 수 있는 제어기가 설계되었는가?
- [ ] 추후 OpenAI/DeepL 플러그인 교체가 간편하도록 인터페이스 기반 의존성 분리가 완료되었는가?
- [ ] 빈번한 부분인식 STT 결과가 들어올 때 번역 병목을 줄이기 위해 디바운싱(Debounce) 및 Task Cancellation(취소) 구조가 명시되었는가?
