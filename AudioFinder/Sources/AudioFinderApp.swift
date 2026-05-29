//
//  AudioFinderApp.swift
//  Audio Finder
//
//  Menu-bar-only SwiftUI app. The icon reflects whether audio is playing; the
//  popover lists currently-playing and recently-active apps.
//

import SwiftUI

@main
struct AudioFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings = SettingsStore()
    @StateObject private var monitor = AudioMonitor()
    @StateObject private var browserTabs = BrowserTabMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
                .environmentObject(settings)
                .environmentObject(browserTabs)
        } label: {
            MenuBarIcon(isPlaying: !monitor.playing.isEmpty)
                .onAppear { browserTabs.start() }
        }
        .menuBarExtraStyle(.window)   // popover-style window for rich custom rows

        // Settings window (also reachable from the popover).
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(monitor)
                .environmentObject(browserTabs)
        }
    }

    init() {
        // Wire settings → monitor and start detection once both exist.
        // (Done in onAppear of MenuContentView to ensure StateObjects are live.)
    }
}

/// App delegate: enforce menu-bar-only (accessory) activation policy and run
/// first-launch onboarding.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The menu-bar status icon. Uses an SF Symbol whose variant changes with
/// audio activity so the bar communicates state at a glance.
struct MenuBarIcon: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
            .symbolRenderingMode(.hierarchical)
            // Subtle emphasis when audio is active.
            .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .accessibilityLabel(isPlaying ? "Audio is playing" : "No audio playing")
    }
}
