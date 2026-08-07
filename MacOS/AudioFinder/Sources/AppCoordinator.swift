//
//  AppCoordinator.swift
//  Audio Finder
//
//  Owns the one-time application startup sequence. Keeping this logic outside
//  the menu popover ensures monitoring starts at login, before a user clicks
//  the menu-bar item, and makes the lifecycle independently testable.
//

import Combine
import Foundation

@MainActor
protocol AudioMonitoring: AnyObject {
    func apply(window: TimeInterval, hideSystem: Bool, showRecent: Bool)
    func start()
    func refreshNow()
}

@MainActor
protocol BrowserTabMonitoring: AnyObject {
    func start()
    func refreshNow()
}

extension AudioMonitor: AudioMonitoring {}
extension BrowserTabMonitor: BrowserTabMonitoring {}

@MainActor
final class AppCoordinator: ObservableObject {
    private(set) var hasStarted = false

    func start(
        settings: SettingsStore,
        monitor: AudioMonitoring,
        browserTabs: BrowserTabMonitoring
    ) {
        syncSettings(settings, to: monitor)
        settings.refreshLaunchAtLogin()

        guard !hasStarted else { return }
        hasStarted = true
        monitor.start()
        browserTabs.start()
    }

    func syncSettings(_ settings: SettingsStore, to monitor: AudioMonitoring) {
        monitor.apply(
            window: TimeInterval(settings.recentlyActiveDuration),
            hideSystem: settings.hideSystemApps,
            showRecent: settings.showRecentlyActive
        )
    }

    func applicationBecameActive(
        settings: SettingsStore,
        monitor: AudioMonitoring,
        browserTabs: BrowserTabMonitoring
    ) {
        settings.refreshLaunchAtLogin()
        monitor.refreshNow()
        browserTabs.refreshNow()
    }
}
