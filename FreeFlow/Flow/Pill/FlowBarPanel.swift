import AppKit
import SwiftUI

/// The always-on, click-through panel that hosts the Flow Bar, its toasts and cards.
/// It never becomes key or main, so dictating never steals focus from the app being typed into.
final class FlowBarPanel: NSPanel {
    static let panelSize = NSSize(width: 520, height: 340)

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom edge on the visible frame (above the Dock), centered horizontally.
    /// When the Dock is hidden, `visibleFrame` reaches the screen bottom.
    static func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: (visible.midX - panelSize.width / 2).rounded(),
            y: visible.minY.rounded(),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

/// Hosting view that takes the first click without activating Flow and routes right-clicks to
/// the pill menu.
final class FlowBarHostingView: NSHostingView<FlowBarView> {
    weak var controller: FlowBarController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let handled = MainActor.assumeIsolated {
            controller?.handleRightClick(event: event, in: self) ?? false
        }
        if !handled {
            super.rightMouseDown(with: event)
        }
    }
}
