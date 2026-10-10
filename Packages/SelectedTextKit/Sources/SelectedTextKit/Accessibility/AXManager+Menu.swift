//
//  AXManager+Menu.swift
//  SelectedTextKit
//
//  Created by tisfeng on 2025/9/5.
//

import AXSwift
import AppKit
import Foundation

extension AXManager {
    // MARK - Find Menu Item
    
    /// Find the enabled menu item in the frontmost application
    /// - Parameter menuItem: The type of menu item to find
    /// - Returns: UIElement for enabled menu item or throws AXError if not found or disabled
    public func findEnabledMenuItem(_ menuItem: SystemMenuItem) throws -> UIElement {
        return try findMenuItem(menuItem, requireEnabled: true)
    }

    /// Find an enabled menu item in a specific application.
    ///
    /// Passing a process identifier lets callers capture the target application on the main actor,
    /// then perform synchronous accessibility IPC from a background executor.
    public func findEnabledMenuItem(
        _ menuItem: SystemMenuItem,
        processIdentifier: pid_t
    ) throws -> UIElement {
        guard processIdentifier > 0 else {
            throw AXError.invalidUIElement
        }

        let appElement = Application(AXUIElementCreateApplication(processIdentifier))
        return try findMenuItem(
            menuItem,
            in: appElement,
            applicationDescription: "pid \(processIdentifier)",
            requireEnabled: true
        )
    }

    /// Find a specific menu item in the frontmost application
    ///
    /// - Parameters:
    ///   - menuItem: The type of menu item to find
    ///   - requireEnabled: If true, only return enabled menu items
    /// - Returns: UIElement for the menu item or throws AXError if not found or disabled (when requireEnabled is true)
    public func findMenuItem(_ menuItem: SystemMenuItem, requireEnabled: Bool = false) throws
        -> UIElement
    {
        guard let appElement = frontmostAppElement else {
            throw AXError.invalidUIElement
        }

        return try findMenuItem(
            menuItem,
            in: appElement,
            applicationDescription: frontmostAppBundleID,
            requireEnabled: requireEnabled
        )
    }

    private func findMenuItem(
        _ menuItem: SystemMenuItem,
        in appElement: UIElement,
        applicationDescription: String,
        requireEnabled: Bool
    ) throws -> UIElement {
        guard checkIsProcessTrusted(prompt: true) else {
            logError("Process is not trusted for accessibility")
            throw AXError.apiDisabled
        }

        logInfo("Checking \(menuItem) item in application: \(applicationDescription)")

        guard let foundMenuItem = try appElement.findMenuItem(menuItem) else {
            throw AXError.noMenuItem
        }

        if requireEnabled {
            guard try foundMenuItem.isEnabled() == true else {
                logError("\(menuItem) item not enabled")
                throw AXError.disabledMenuItem
            }
            logInfo("Found enabled \(menuItem) item in frontmost application menu")
        }

        return foundMenuItem
    }
    
    // MARK: - Check Menu Item Existence

    @objc
    public func hasCopyMenuItem() -> Bool {
        (try? findMenuItem(.copy)) != nil
    }

    @objc
    public func hasPasteMenuItem() -> Bool {
        (try? findMenuItem(.paste)) != nil
    }


    // MARK: - Frontmost Application

    /// Frontmost application as `NSRunningApplication`
    var frontmostApp: NSRunningApplication? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        guard let frontmostApp else {
            return nil
        }
        return frontmostApp
    }

    /// Bundle identifier of frontmost application
    var frontmostAppBundleID: String {
        frontmostApp?.bundleIdentifier ?? ""
    }
    
    /// Frontmost application as `UIElement`
    var frontmostAppElement: UIElement? {
        guard let frontmostApp else {
            return nil
        }
        return Application(frontmostApp)
    }
}
