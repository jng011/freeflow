import AppKit

/// Watches the cursor so the Flow Bar panel can stay click-through everywhere except over the
/// pill or the visible toast. The panel ignores mouse events by default; the controller flips
/// `ignoresMouseEvents` off only while the cursor is inside a hot rect.
///
/// Mouse-moved monitors cost nothing while the cursor is still. The 20 Hz timer runs only while a
/// toast or card is on screen, because a toast can appear or grow under a resting cursor.
@MainActor
final class FlowBarMouseTracker {
    weak var panel: NSPanel?
    var onMove: ((NSPoint) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fastTimer: Timer?

    private static let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        // Global monitors see events headed to other apps (the panel is click-through then).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fire()
            }
        }
        // Local monitors see events once the panel is accepting the mouse.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.fire()
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        setFastPolling(false)
    }

    /// 20 Hz polling, only while a toast or card is visible.
    func setFastPolling(_ enabled: Bool) {
        if enabled {
            guard fastTimer == nil else { return }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fire()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            fastTimer = timer
        } else {
            fastTimer?.invalidate()
            fastTimer = nil
        }
    }

    private func fire() {
        onMove?(NSEvent.mouseLocation)
    }
}
