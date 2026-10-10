import Foundation
import IOKit.hid
import os

/// Reads the fn/globe key straight from the keyboard's HID reports through IOHIDManager,
/// the lowest layer an app can listen at. Event taps sit above the WindowServer, which
/// coalesces fast modifier taps (a quick second fn press can arrive late or not at all);
/// HID values are the key's own down/up edges as the keyboard sent them.
///
/// Needs Input Monitoring. Without it `start()` returns false and the event tap stays in charge.
final class FnHIDMonitor {
    /// Apple's fn key: top-case page on the built-in keyboard, vendor keyboard page on
    /// Magic Keyboards (the globe key).
    private static let fnUsages: [(page: Int, usage: Int)] = [(0xFF, 0x03), (0xFF01, 0x03)]

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FnHID")
    private var manager: IOHIDManager?
    private var onEdge: ((Bool, TimeInterval) -> Void)?
    private var isDown = false
    /// Hardware time of the last edge delivered. The fn key reports through more than one
    /// HID interface, so every edge arrives twice with the same timestamp; the copy (and
    /// anything older) is dropped.
    private var lastEdgeTime: TimeInterval = 0
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// True once a keyboard has actually reported an fn edge, so HID can be trusted to see it.
    private(set) var isLive = false

    deinit { stop() }

    /// `onEdge(down, time)` runs on the main thread for every fn press and release.
    @discardableResult
    func start(onEdge: @escaping (Bool, TimeInterval) -> Void) -> Bool {
        stop()
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            || IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        else {
            logger.notice("Input Monitoring not granted; fn stays on the event tap")
            return false
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: 0xFF],
            [kIOHIDDeviceUsagePageKey: 0xFF00],
        ] as CFArray)
        IOHIDManagerSetInputValueMatchingMultiple(manager, Self.fnUsages.map {
            [kIOHIDElementUsagePageKey: $0.page, kIOHIDElementUsageKey: $0.usage]
        } as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<FnHIDMonitor>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            logger.notice("IOHIDManagerOpen failed (\(result, privacy: .public)); fn stays on the event tap")
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return false
        }
        self.manager = manager
        self.onEdge = onEdge
        logger.notice("fn HID monitor running")
        return true
    }

    func stop() {
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        onEdge = nil
        isDown = false
        isLive = false
        lastEdgeTime = 0
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard Self.fnUsages.contains(where: { $0.page == page && $0.usage == usage }) else { return }
        let down = IOHIDValueGetIntegerValue(value) != 0
        let ticks = IOHIDValueGetTimeStamp(value)
        let time = Double(ticks) * Double(Self.timebase.numer) / Double(Self.timebase.denom) / 1_000_000_000
        guard time > lastEdgeTime else { return }  // same edge from a second interface
        guard down != isDown else { return }  // a repeated report: edges only
        lastEdgeTime = time
        isDown = down
        isLive = true
        logger.notice("hid fn down=\(down, privacy: .public) hw=\(time, privacy: .public) lag=\((ProcessInfo.processInfo.systemUptime - time) * 1000, privacy: .public)ms")
        onEdge?(down, ProcessInfo.processInfo.systemUptime)
    }
}
