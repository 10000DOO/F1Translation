import AppKit

public final class SubtitleOverlayWindow: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow, .resizable, .titled],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
    }
    
    public func toggleClickThrough(ignore: Bool) {
        if ignore {
            self.ignoresMouseEvents = true
        } else {
            self.ignoresMouseEvents = false
        }
    }
}
