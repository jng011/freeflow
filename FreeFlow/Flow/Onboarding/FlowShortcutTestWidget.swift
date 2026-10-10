import AppKit
import Carbon.HIToolbox
import SwiftUI

// Onboarding shortcut test: draws the dictation shortcut as keyboard keys that
// turn purple while they are held. Listens through a local NSEvent monitor that
// only exists while the page is visible.

/// One key of the shortcut and how to tell whether it is held.
struct FlowTestKey: Identifiable, Equatable {
    enum Trigger: Equatable {
        case modifier(NSEvent.ModifierFlags.RawValue)
        case keyCode(UInt16)
        case mouse(UInt16)
    }

    let id: Int
    let label: String
    let width: CGFloat
    let trigger: Trigger

    /// Keys for `shortcut`, in display order. Falls back to fn.
    static func keys(for shortcut: Shortcut?) -> [FlowTestKey] {
        guard let shortcut else {
            return [FlowTestKey(id: 0, label: "fn", width: 60, trigger: .modifier(NSEvent.ModifierFlags.function.rawValue))]
        }
        var result: [FlowTestKey] = []
        let flags = shortcut.modifierFlags
        let ordered: [(NSEvent.ModifierFlags, String, CGFloat)] = [
            (.function, "fn", 60),
            (.control, "control", 70),
            (.option, "option", 70),
            (.shift, "shift", 150),
            (.command, "command", 90),
        ]
        for (flag, label, width) in ordered where flags.contains(flag) {
            result.append(FlowTestKey(id: result.count, label: label, width: width, trigger: .modifier(flag.rawValue)))
        }
        switch shortcut.kind {
        case .modifierOnly:
            if result.isEmpty {
                let label = FlowShortcutRules.tokens(shortcut).first ?? "fn"
                result.append(
                    FlowTestKey(
                        id: 0, label: label, width: 60,
                        trigger: .modifier(NSEvent.ModifierFlags.function.rawValue)))
            }
        case .key:
            let name = shortcut.displayTokens.last ?? "key"
            let isSpace = shortcut.keyCode == UInt16(kVK_Space)
            result.append(
                FlowTestKey(
                    id: result.count,
                    label: isSpace ? "space" : name,
                    width: isSpace ? 150 : 60,
                    trigger: .keyCode(shortcut.keyCode)))
        case .mouseButton:
            result.append(
                FlowTestKey(
                    id: result.count,
                    label: shortcut.displayTokens.last ?? "mouse",
                    width: 90,
                    trigger: .mouse(shortcut.keyCode)))
        }
        return result
    }
}

/// Tracks which keys are held while the shortcut test page is visible.
@MainActor
final class FlowShortcutTestMonitor: ObservableObject {
    @Published private(set) var heldModifiers: NSEvent.ModifierFlags = []
    @Published private(set) var heldKeyCodes: Set<UInt16> = []
    @Published private(set) var heldMouseButtons: Set<UInt16> = []
    /// Set once every key of the shortcut was held at the same time.
    @Published private(set) var didPressShortcut = false

    var keys: [FlowTestKey] = []
    private var monitor: Any?

    func start(keys: [FlowTestKey]) {
        self.keys = keys
        stop()
        FlowOnboardingState.isTestingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        heldModifiers = []
        heldKeyCodes = []
        heldMouseButtons = []
        FlowOnboardingState.isTestingShortcut = false
    }

    func isHeld(_ key: FlowTestKey) -> Bool {
        switch key.trigger {
        case .modifier(let raw):
            return heldModifiers.contains(NSEvent.ModifierFlags(rawValue: raw))
        case .keyCode(let code):
            return heldKeyCodes.contains(code)
        case .mouse(let button):
            return heldMouseButtons.contains(button)
        }
    }

    /// Returns true when the event belongs to the shortcut and should not reach text fields.
    private func handle(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.function, .control, .option, .shift, .command]
        switch event.type {
        case .flagsChanged:
            heldModifiers = event.modifierFlags.intersection(relevant)
        case .keyDown:
            // Modifiers come from flagsChanged only: arrow and function keys report
            // .function on keyDown, which would light up the fn key by mistake.
            if keys.contains(where: { $0.trigger == .keyCode(event.keyCode) }) {
                heldKeyCodes.insert(event.keyCode)
                checkComplete()
                return true
            }
            return false
        case .keyUp:
            heldKeyCodes.remove(event.keyCode)
            return keys.contains(where: { $0.trigger == .keyCode(event.keyCode) })
        case .otherMouseDown:
            heldMouseButtons.insert(UInt16(event.buttonNumber))
        case .otherMouseUp:
            heldMouseButtons.remove(UInt16(event.buttonNumber))
        default:
            break
        }
        checkComplete()
        return false
    }

    private func checkComplete() {
        guard !keys.isEmpty, keys.allSatisfy(isHeld) else { return }
        if !didPressShortcut { didPressShortcut = true }
    }
}

// MARK: - Views

/// The key area: backgroundTertiary, 96 tall, keys centered.
struct FlowShortcutTestKeys: View {
    @ObservedObject var monitor: FlowShortcutTestMonitor

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(monitor.keys) { key in
                    FlowKeyboardKey(label: key.label, width: key.width, isPressed: monitor.isHeld(key))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .padding(.horizontal, 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))

            Text("Press the key on your keyboard!")
                .font(FlowFont.sans(14, weight: 550))
                .foregroundStyle(FlowColor.primaryForeground)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.primary))
        }
    }
}

/// One drawn keyboard key: 60x60 (wider for modifiers), radius 5, 1.43 pt border, sm shadow.
struct FlowKeyboardKey: View {
    let label: String
    var width: CGFloat = 60
    let isPressed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(label)
            .font(FlowFont.sans(12.4, weight: 550))
            .foregroundStyle(isPressed ? FlowColor.dawn900 : FlowColor.neutral600)
            .lineLimit(1)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(width: width, height: 60, alignment: .bottomLeading)
            .background(shape.fill(isPressed ? FlowColor.dawn500 : FlowSettingsPalette.keyFace))
            .overlay(shape.strokeBorder(isPressed ? FlowColor.dawn900 : FlowColor.neutral500, lineWidth: 1.43))
            .flowShadow(isPressed ? .xs : .sm)
            .offset(y: isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}

/// Right panel card for the shortcut test page.
struct FlowShortcutTestWidget: View {
    @ObservedObject var monitor: FlowShortcutTestMonitor
    let onEdit: () -> Void
    let onNo: () -> Void
    let onYes: () -> Void

    var body: some View {
        FlowOnboardingWidgetCard {
            FlowShortcutTestKeys(monitor: monitor)
                .frame(maxWidth: .infinity)

            Text("Does the button turn purple while pressing it?")
                .flowText(.h4)
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Edit shortcut", action: onEdit)
                    .buttonStyle(FlowButtonStyle(variant: .ghost, size: .md))
                Spacer(minLength: 8)
                Button("No", action: onNo)
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .md))
                Button("Yes", action: onYes)
                    .buttonStyle(FlowButtonStyle(variant: .primary, size: .md))
            }
        }
    }
}
