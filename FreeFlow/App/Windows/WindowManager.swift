import AppKit
import SwiftUI

enum AppWindowLayout {
    /// The Flow window opens at 1350x850 and never shrinks below 1140x750.
    static let width: CGFloat = 1350
    static let height: CGFloat = 850
    static let minimumWidth: CGFloat = 1140
    static let minimumHeight: CGFloat = 750
}

enum AppWindowID {
    static let main = "main"
}

enum WindowDiagnostics {
    static func visibleUserFacingWindows(excluding excludedWindow: NSWindow? = nil) -> [NSWindow] {
        NSApplication.shared.windows.filter { window in
            if let excludedWindow, window == excludedWindow {
                return false
            }

            return window.isVisible && window.level == .normal && window.styleMask.contains(.titled)
        }
    }
}

enum AppPresentationPolicy {
    static func activateForUserFacingWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func restoreAccessoryIfNeededAfterUserFacingWindowClosed() {
        DispatchQueue.main.async {
            let menuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
            let hasVisibleUserWindows = !WindowDiagnostics.visibleUserFacingWindows().isEmpty

            guard menuBarOnly else { return }
            guard !hasVisibleUserWindows else { return }

            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.deactivate()
        }
    }
}

class WindowManager: NSObject {
    static let shared = WindowManager()

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.jaydenghiyam.parle.mainWindow")
    // New name so the old 950-wide Parle frame is not restored.
    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("FlowMainWindowFrame")

    /// Traffic lights: top-left origin at (16, 19) from the window's top-left, 20 pt pitch.
    private static let trafficLightOrigin = CGPoint(x: 16, y: 19)
    private static let trafficLightPitch: CGFloat = 20
    /// Height of the custom title bar the traffic lights sit in.
    private static let titleBarHeight: CGFloat = 52

    private weak var mainWindow: NSWindow?
    private var didApplyInitialPlacement = false
    private var shouldShowNextConfiguredMainWindow = false
    private var chromeObservers: [ObjectIdentifier: ChromeObservation] = [:]

    private struct ChromeObservation {
        weak var window: NSWindow?
        var tokens: [NSObjectProtocol]
    }

    private override init() {
        super.init()
    }

    func prepareForUserRequestedMainWindow() {
        guard !shouldShowNextConfiguredMainWindow else { return }
        shouldShowNextConfiguredMainWindow = true
    }

    func configureWindow(_ window: NSWindow) {
        if let existingWindow = NSApplication.shared.windows.first(where: {
            $0.identifier == Self.mainWindowIdentifier && $0 != window
        }) {
            window.close()
            if shouldShowNextConfiguredMainWindow {
                presentMainWindow(existingWindow)
                shouldShowNextConfiguredMainWindow = false
            } else {
                existingWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        let requiredStyleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        window.styleMask.formUnion(requiredStyleMask)
        // Flow draws its own 52 pt title bar; the system one is transparent and untitled.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = FlowColor.nsBackgroundTertiary
        window.isReleasedWhenClosed = false
        window.title = "Free Flow"
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: AppWindowLayout.minimumWidth, height: AppWindowLayout.minimumHeight)
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        applyInitialPlacementIfNeeded(to: window)
        registerMainWindowIfNeeded(window)
        installTrafficLightLayout(on: window)

        if shouldShowNextConfiguredMainWindow {
            shouldShowNextConfiguredMainWindow = false
            presentMainWindow(window)
        } else if UserDefaults.standard.bool(forKey: "IsMenuBarOnly") {
            window.orderOut(nil)
        }
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.identifier = Self.mainWindowIdentifier
        window.delegate = self
    }

    @discardableResult
    func showMainWindow() -> NSWindow? {
        guard let window = resolveMainWindow() else {
            return nil
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        presentMainWindow(window)
        return window
    }

    func hideMainWindow() {
        guard let window = resolveMainWindow() else {
            return
        }

        window.orderOut(nil)
    }

    func currentMainWindow() -> NSWindow? {
        resolveMainWindow()
    }

    private func registerMainWindowIfNeeded(_ window: NSWindow) {
        if window.identifier == nil || window.identifier != Self.mainWindowIdentifier {
            registerMainWindow(window)
        }
    }

    private func applyInitialPlacementIfNeeded(to window: NSWindow) {
        guard !didApplyInitialPlacement else { return }
        // Attempt to restore previous frame if one exists; otherwise fall back to a centered placement
        if window.setFrameUsingName(Self.mainWindowAutosaveName) {
            enforceMainWindowFrameIfNeeded(on: window, preserveRestoredOrigin: true)
        } else {
            enforceMainWindowFrameIfNeeded(on: window, preserveRestoredOrigin: false)
            window.center()
        }
        didApplyInitialPlacement = true
    }

    private func enforceMainWindowFrameIfNeeded(on window: NSWindow, preserveRestoredOrigin: Bool) {
        let currentFrame = window.frame
        guard currentFrame.width < AppWindowLayout.minimumWidth || currentFrame.height < AppWindowLayout.minimumHeight else {
            return
        }

        let width = max(currentFrame.width, AppWindowLayout.width)
        let height = max(currentFrame.height, AppWindowLayout.height)
        let x = preserveRestoredOrigin ? currentFrame.origin.x : currentFrame.midX - (width / 2)
        let frame = NSRect(
            x: x,
            y: currentFrame.maxY - height,
            width: width,
            height: height
        )
        window.setFrame(frame, display: true)
    }

    private func resolveMainWindow() -> NSWindow? {
        if let window = mainWindow {
            return window
        }

        if let window = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            mainWindow = window
            window.delegate = self
            return window
        }

        return nil
    }

    private func presentMainWindow(_ window: NSWindow) {
        AppPresentationPolicy.activateForUserFacingWindow()

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.orderFrontRegardless()
        }
    }
}

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier == Self.mainWindowIdentifier {
            mainWindow = nil
            didApplyInitialPlacement = false
        }
    }
}

// MARK: - Traffic lights

extension WindowManager {
    /// Positions the close, minimize and zoom buttons inside the 52 pt Flow title bar and
    /// keeps them there across resizes, full screen and key changes.
    fileprivate func installTrafficLightLayout(on window: NSWindow) {
        let key = ObjectIdentifier(window)
        // A closed main window can be shown again, so observers stay until the window is replaced.
        if let existing = chromeObservers[key], existing.window !== window {
            removeTrafficLightLayout(for: key)
        }
        if chromeObservers[key] == nil {
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didChangeBackingPropertiesNotification,
            ]
            let tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self, weak window] _ in
                    guard let self, let window else { return }
                    self.layoutTrafficLights(in: window)
                }
            }
            chromeObservers[key] = ChromeObservation(window: window, tokens: tokens)
        }
        layoutTrafficLights(in: window)
        // SwiftUI may lay out the title bar again after the first pass.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.layoutTrafficLights(in: window)
        }
    }

    private func removeTrafficLightLayout(for key: ObjectIdentifier) {
        for observer in chromeObservers[key]?.tokens ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        chromeObservers[key] = nil
    }

    func layoutTrafficLights(in window: NSWindow) {
        // In full screen the system owns the (auto-hiding) title bar.
        guard !window.styleMask.contains(.fullScreen) else { return }

        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first,
            let buttonSuperview = first.superview,
            let titlebarContainer = buttonSuperview.superview
        else {
            return
        }

        // Make the system title bar as tall as ours so the buttons are not clipped.
        let windowHeight = window.frame.height
        var containerFrame = titlebarContainer.frame
        if abs(containerFrame.height - Self.titleBarHeight) > 0.5
            || abs(containerFrame.origin.y - (windowHeight - Self.titleBarHeight)) > 0.5
        {
            containerFrame.size.height = Self.titleBarHeight
            containerFrame.origin.y = windowHeight - Self.titleBarHeight
            titlebarContainer.frame = containerFrame
        }
        if buttonSuperview.frame != titlebarContainer.bounds {
            buttonSuperview.frame = titlebarContainer.bounds
        }

        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            // Window coordinates: origin at the bottom-left of the frame.
            let rectInWindow = NSRect(
                x: Self.trafficLightOrigin.x + CGFloat(index) * Self.trafficLightPitch,
                y: windowHeight - Self.trafficLightOrigin.y - size.height,
                width: size.width,
                height: size.height
            )
            let origin = buttonSuperview.convert(rectInWindow, from: nil).origin
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
        }
    }
}
