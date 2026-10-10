import AppKit
import Foundation
import os

class ActiveWindowService: ObservableObject {
    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    /// The browser page URL resolved at the start of the current dictation, if any.
    @Published var currentURL: String?
    private let browserURLService = BrowserURLService.shared

    private let logger = Logger(
        subsystem: "com.jaydenghiyam.parle",
        category: "browser.detection"
    )

    private init() {}

    @MainActor
    @discardableResult
    func beginApplyingConfiguration(
        modeId: UUID? = nil,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Void, Never> {
        currentURL = nil
        if let modeId = modeId,
            let config = ModeManager.shared.getConfiguration(with: modeId)
        {
            guard shouldApply() else { return Task {} }
            ModeManager.shared.setActiveConfiguration(config)
            return Task {}
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
            let bundleIdentifier = frontmostApp.bundleIdentifier
        else {
            return Task {}
        }

        guard shouldApply() else { return Task {} }
        currentApplication = frontmostApp

        let quickConfig =
            ModeManager.shared.getConfigurationForApp(bundleIdentifier)
            ?? ModeManager.shared.getDefaultConfiguration()

        if let quickConfig {
            ModeManager.shared.setActiveConfiguration(quickConfig)
        }

        guard let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return Task {}
        }

        return Task { [weak self] in
            guard let self else { return }

            do {
                let currentURL = try await self.browserURLService.getCurrentURL(from: browserType)
                await MainActor.run {
                    self.currentURL = currentURL
                    guard shouldApply(),
                        let config = ModeManager.shared.getConfigurationForURL(currentURL)
                    else {
                        return
                    }
                    ModeManager.shared.setActiveConfiguration(config)
                }
            } catch is CancellationError {
                return
            } catch {
                self.logger.error(
                    "❌ Failed to get URL from \(browserType.displayName, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    func applyConfiguration(modeId: UUID? = nil) async {
        let task = await MainActor.run {
            beginApplyingConfiguration(modeId: modeId)
        }
        await task.value
    }
}
