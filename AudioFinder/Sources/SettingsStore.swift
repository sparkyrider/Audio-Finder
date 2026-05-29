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

@MainActor
final class SettingsStore: ObservableObject {

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.audiofinder.app", category: "Settings")

    // Keys ------------------------------------------------------------------
    private enum Key {
        static let showRecentlyActive = "showRecentlyActive"
        static let recentlyActiveDuration = "recentlyActiveDuration"
        static let hideSystemApps = "hideSystemApps"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    // Published settings ----------------------------------------------------
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

    /// Guards against the didSet side-effect when we sync from the real state.
    private var suppressLaunchSync = false

    init() {
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
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    /// Re-read the real login-item state (e.g. after returning from System Settings).
    func refreshLaunchAtLogin() {
        let enabled = (SMAppService.mainApp.status == .enabled)
        if enabled != launchAtLogin {
            suppressLaunchSync = true
            launchAtLogin = enabled   // update UI without re-registering
            suppressLaunchSync = false
        }
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            log.error("Launch-at-login change failed: \(error.localizedDescription)")
            // Re-sync the toggle to the real state on failure.
            let actual = (SMAppService.mainApp.status == .enabled)
            if actual != enable {
                DispatchQueue.main.async { [weak self] in self?.launchAtLogin = actual }
            }
        }
    }
}
