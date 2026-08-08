//
//  SettingsStore.swift
//  Audio Finder
//
//  Minimal, observable settings backed by UserDefaults. Launch-at-login is
//  reflected live from SMAppService rather than cached.
//

import Combine
import Foundation
import ServiceManagement
import os

enum LoginItemStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

enum SettingsTab: Hashable {
    case home
    case preferences
    case browsers
}

@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
struct SystemLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class SettingsStore: ObservableObject {

    private let defaults: UserDefaults
    private let loginItemManager: LoginItemManaging
    private let log = Logger(subsystem: "app.audiofinder.mac", category: "Settings")

    // Keys ------------------------------------------------------------------
    private enum Key {
        static let showRecentlyActive = "showRecentlyActive"
        static let recentlyActiveDuration = "recentlyActiveDuration"
        static let hideSystemApps = "hideSystemApps"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    // Published settings ----------------------------------------------------
    /// Transient window navigation. Browser setup links always return here.
    @Published var selectedTab: SettingsTab = .home

    @Published var showRecentlyActive: Bool {
        didSet { defaults.set(showRecentlyActive, forKey: Key.showRecentlyActive) }
    }
    /// One of 15 / 30 / 60 seconds.
    @Published var recentlyActiveDuration: Int {
        didSet { defaults.set(recentlyActiveDuration, forKey: Key.recentlyActiveDuration) }
    }
    @Published var hideSystemApps: Bool {
        didSet { defaults.set(hideSystemApps, forKey: Key.hideSystemApps) }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Reflected live from SMAppService; setting it (un)registers the login item.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !suppressLaunchSync else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    @Published private(set) var loginItemStatus: LoginItemStatus
    @Published private(set) var launchAtLoginError: String?

    /// Guards against the didSet side-effect when we sync from the real state.
    private var suppressLaunchSync = false

    init(
        defaults: UserDefaults = .standard,
        loginItemManager: LoginItemManaging? = nil
    ) {
        self.defaults = defaults
        self.loginItemManager = loginItemManager ?? SystemLoginItemManager()
        defaults.register(defaults: [
            Key.showRecentlyActive: true,
            Key.recentlyActiveDuration: 30,
            Key.hideSystemApps: true,
            Key.hasCompletedOnboarding: false,
        ])
        showRecentlyActive = defaults.bool(forKey: Key.showRecentlyActive)
        recentlyActiveDuration = defaults.integer(forKey: Key.recentlyActiveDuration)
        hideSystemApps = defaults.bool(forKey: Key.hideSystemApps)
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        let initialLoginItemStatus = self.loginItemManager.status
        loginItemStatus = initialLoginItemStatus
        launchAtLogin = initialLoginItemStatus.isRegistered
        launchAtLoginError = nil
    }

    /// Re-read the real login-item state (e.g. after returning from System Settings).
    func refreshLaunchAtLogin() {
        launchAtLoginError = nil
        let currentStatus = loginItemManager.status
        loginItemStatus = currentStatus
        let registered = currentStatus.isRegistered
        if registered != launchAtLogin {
            suppressLaunchSync = true
            launchAtLogin = registered   // update UI without re-registering
            suppressLaunchSync = false
        }
    }

    func openLoginItemSettings() {
        loginItemManager.openSystemSettings()
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        launchAtLoginError = nil
        do {
            if enable {
                if !loginItemManager.status.isRegistered {
                    try loginItemManager.register()
                }
            } else {
                if loginItemManager.status.isRegistered {
                    try loginItemManager.unregister()
                }
            }
            refreshLaunchAtLogin()
        } catch {
            log.error("Launch-at-login change failed: \(error.localizedDescription)")
            refreshLaunchAtLogin()
            if loginItemStatus != .requiresApproval {
                launchAtLoginError = error.localizedDescription
            }
        }
    }
}
