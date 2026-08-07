//
//  AudioFinderApp.swift
//  Audio Finder
//
//  Menu-bar SwiftUI app. Monitoring begins with the application lifecycle,
//  while dedicated welcome and settings windows make Finder launches visible.
//

import AppKit
import CoreServices
import SwiftUI

enum AppWindow {
    static let welcome = "welcome"
    static let settings = "settings"
}

extension Notification.Name {
    static let audioFinderShowPrimaryWindow = Notification.Name(
        "com.audiofinder.app.show-primary-window"
    )
}

@main
struct AudioFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings = SettingsStore()
    @StateObject private var monitor = AudioMonitor()
    @StateObject private var browserTabs = BrowserTabMonitor()
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
                .environmentObject(settings)
                .environmentObject(browserTabs)
        } label: {
            AppLifecycleBridge(
                settings: settings,
                monitor: monitor,
                browserTabs: browserTabs,
                coordinator: coordinator
            )
        }
        .menuBarExtraStyle(.window)

        Window("Audio Finder Settings", id: AppWindow.settings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(monitor)
                .environmentObject(browserTabs)
        }
        .defaultSize(width: 540, height: 560)
        .windowResizability(.contentSize)

        Window("Welcome to Audio Finder", id: AppWindow.welcome) {
            WelcomeWindow()
                .environmentObject(settings)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
    }
}

/// Bridges scene-independent AppKit launch/reopen events into SwiftUI windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = Self.isLoginItemLaunch(
            NSAppleEventManager.shared().currentAppleEvent
        )

        NSApp.setActivationPolicy(.accessory)
        // SMAppService is the only launch-at-login mechanism we expose. Avoid
        // an additional implicit relaunch simply because the app was open when
        // the user logged out.
        NSApp.disableRelaunchOnLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services may still be dispatching the open-application event
        // here, even if it was not yet current during will-finish-launching.
        launchedAsLoginItem = launchedAsLoginItem || Self.isLoginItemLaunch(
            NSAppleEventManager.shared().currentAppleEvent
        )

        // A normal Finder/Spotlight launch should visibly respond. A background
        // launch at login stays quiet; first launch is independently handled by
        // AppLifecycleBridge so onboarding can never be missed.
        if !launchedAsLoginItem {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioFinderShowPrimaryWindow, object: nil)
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        NotificationCenter.default.post(name: .audioFinderShowPrimaryWindow, object: nil)
        return true
    }

    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventID == AEEventID(kAEOpenApplication) else { return false }
        if event?.paramDescriptor(
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        ) != nil {
            return true
        }

        // Some older Launch Services paths represented the same marker as the
        // open event's property-data enumerator.
        return event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
            .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

private struct AppLifecycleBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: AudioMonitor
    @ObservedObject var browserTabs: BrowserTabMonitor
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        MenuBarIcon(isPlaying: !monitor.playing.isEmpty)
            .task {
                coordinator.start(
                    settings: settings,
                    monitor: monitor,
                    browserTabs: browserTabs
                )
                if !settings.hasCompletedOnboarding {
                    presentPrimaryWindow()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .audioFinderShowPrimaryWindow)
            ) { _ in
                presentPrimaryWindow()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                coordinator.applicationBecameActive(
                    settings: settings,
                    monitor: monitor,
                    browserTabs: browserTabs
                )
            }
            .onChange(of: settings.hideSystemApps) { _, _ in syncSettings() }
            .onChange(of: settings.showRecentlyActive) { _, _ in syncSettings() }
            .onChange(of: settings.recentlyActiveDuration) { _, _ in syncSettings() }
    }

    private func syncSettings() {
        coordinator.syncSettings(settings, to: monitor)
    }

    private func presentPrimaryWindow() {
        let id = settings.hasCompletedOnboarding ? AppWindow.settings : AppWindow.welcome
        openWindow(id: id)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct WelcomeWindow: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingView {
            settings.hasCompletedOnboarding = true
            dismissWindow(id: AppWindow.welcome)
        }
    }
}

/// The menu-bar status icon. Uses an SF Symbol whose variant changes with
/// audio activity so the bar communicates state at a glance.
struct MenuBarIcon: View {
    let isPlaying: Bool

    var body: some View {
        Image("MenuBarMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .accessibilityLabel(isPlaying ? "Audio is playing" : "No audio playing")
    }
}
