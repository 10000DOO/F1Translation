import SwiftUI
import AppKit
import Translation

@main
struct F1TranslationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayWindow: SubtitleOverlayWindow?
    private var viewModel: SubtitleViewModel?
    
    private let speechService = AppleSpeechRecognitionService()
    private let translationService = AppleTranslationService()
    private let captureCoordinator = AudioCaptureCoordinator()
    
    private var sttTask: Task<Void, Never>?
    private var isServiceActive = false
    private var clickThroughEnabled = false
    private var opacityValue: CGFloat = 0.6
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupServices()
        setupStatusItem()
        setupOverlayWindow()
        setupLocalHotKey()
    }
    
    private func setupServices() {
        self.viewModel = SubtitleViewModel(translationService: translationService)
        
        // 캡처한 PCM 버퍼를 STT 서비스에 수동 주입하는 연동 바인딩
        captureCoordinator.onAudioBufferReceived = { [weak self] buffer in
            self?.speechService.appendAudioBuffer(buffer)
        }
    }
    
    private func startPipeline() {
        guard !isServiceActive else { return }
        isServiceActive = true
        
        do {
            try captureCoordinator.startCapture()
        } catch {
            print("오디오 캡처 시작 실패: \(error)")
        }
        
        // 외부 버퍼 주입 모드로 STT 인식 가동
        let stream = speechService.startRecognition(isExternalCapture: true)
        sttTask = Task {
            do {
                for try await result in stream {
                    guard !Task.isCancelled else { break }
                    await viewModel?.updateOriginalText(result.text)
                }
            } catch {
                print("음성 인식 오류: \(error)")
            }
        }
    }
    
    private func stopPipeline() {
        guard isServiceActive else { return }
        isServiceActive = false
        
        captureCoordinator.stopCapture()
        speechService.stopRecognition()
        sttTask?.cancel()
        sttTask = nil
        
        viewModel?.updateOriginalText("")
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "F1 Translation")
        }
        updateMenu()
    }
    
    private func updateMenu() {
        let menu = NSMenu()
        
        let toggleServiceItem = NSMenuItem(
            title: isServiceActive ? "자막 서비스 끄기" : "자막 서비스 켜기",
            action: #selector(toggleService),
            keyEquivalent: ""
        )
        menu.addItem(toggleServiceItem)
        
        let toggleClickThroughItem = NSMenuItem(
            title: clickThroughEnabled ? "클릭 통과 비활성화" : "클릭 통과 활성화",
            action: #selector(toggleClickThroughAction),
            keyEquivalent: ""
        )
        menu.addItem(toggleClickThroughItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let opacityMenu = NSMenu()
        for val in stride(from: 0.2, through: 1.0, by: 0.2) {
            let title = String(format: "투명도 %.0f%%", val * 100)
            let item = NSMenuItem(title: title, action: #selector(changeOpacity(_:)), keyEquivalent: "")
            item.representedObject = val
            item.state = (abs(opacityValue - val) < 0.05) ? .on : .off
            opacityMenu.addItem(item)
        }
        
        let opacityParentItem = NSMenuItem(title: "창 투명도 설정", action: nil, keyEquivalent: "")
        opacityParentItem.submenu = opacityMenu
        menu.addItem(opacityParentItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    private func setupOverlayWindow() {
        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        let screenRect = mainScreen.visibleFrame
        let windowWidth: CGFloat = 800
        let windowHeight: CGFloat = 150
        let windowRect = NSRect(
            x: (screenRect.width - windowWidth) / 2,
            y: screenRect.minY + 50,
            width: windowWidth,
            height: windowHeight
        )
        
        let window = SubtitleOverlayWindow(contentRect: windowRect)
        if let viewModel = self.viewModel {
            let contentView = SubtitleOverlayView(viewModel: viewModel)
            window.contentView = NSHostingView(rootView: contentView)
        }
        window.alphaValue = opacityValue
        window.makeKeyAndOrderFront(nil)
        self.overlayWindow = window
    }
    
    private func setupLocalHotKey() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == [.command, .option] && event.charactersIgnoringModifiers == "c" {
                self.toggleClickThroughAction()
                return nil
            }
            return event
        }
    }
    
    @objc private func toggleService() {
        if isServiceActive {
            stopPipeline()
        } else {
            startPipeline()
        }
        updateMenu()
    }
    
    @objc private func toggleClickThroughAction() {
        clickThroughEnabled.toggle()
        overlayWindow?.toggleClickThrough(ignore: clickThroughEnabled)
        viewModel?.isClickThrough = clickThroughEnabled
        updateMenu()
    }
    
    @objc private func changeOpacity(_ sender: NSMenuItem) {
        if let val = sender.representedObject as? CGFloat {
            self.opacityValue = val
            overlayWindow?.alphaValue = val
            updateMenu()
        }
    }
    
    @objc private func quitApp() {
        stopPipeline()
        NSApp.terminate(nil)
    }
}
