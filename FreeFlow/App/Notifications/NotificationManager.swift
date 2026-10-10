import AppKit
import SwiftUI

/// App-wide transient notifications. They render as Flow Bar toasts anchored where the pill
/// sits: mini toasts, or condensed toasts when there is an action button.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var currentToastID: UUID?

    private init() {}

    func showNotification(
        title: String,
        type: AppNotificationView.NotificationType,
        duration: TimeInterval = 3.0,
        onTap: (() -> Void)? = nil,
        actionButton: (label: String, action: () -> Void)? = nil
    ) {
        var toast = FlowBarToast(
            style: actionButton != nil ? .condensed : .mini,
            title: title
        )
        toast.icon = Self.icon(for: type)
        toast.duration = duration
        toast.sound = type == .error ? .error : nil

        if let actionButton {
            let action = actionButton.action
            toast.actionTitle = actionButton.label
            toast.action = { action() }
        } else if let onTap {
            toast.action = { onTap() }
        }

        currentToastID = FlowBarController.shared.showToast(toast, onEnd: nil)
    }

    /// Dismisses the toast this manager showed last, leaving other Flow Bar toasts alone.
    func dismissNotification() {
        guard let currentToastID else { return }
        self.currentToastID = nil
        FlowBarController.shared.dismissToast(ifCurrent: currentToastID)
    }

    private static func icon(for type: AppNotificationView.NotificationType) -> FlowIconName? {
        switch type {
        case .error, .warning:
            return FlowIconName(rawValue: "circle-alert")
        case .success:
            return FlowIconName(rawValue: "circle-check")
        case .info:
            return nil
        }
    }
}
