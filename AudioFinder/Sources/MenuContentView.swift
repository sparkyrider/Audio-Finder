//
//  MenuContentView.swift
//  Audio Finder
//
//  The popover shown from the menu bar. Lists currently-playing apps and a
//  "recently active" section, with an Open action per row. Handles the
//  empty / unsupported / onboarding states.
//

import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var monitor: AudioMonitor
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browserTabs: BrowserTabMonitor
    @Environment(\.openSettings) private var openSettings

    @State private var showOnboarding = false
    @State private var isVisible = false

    // While the popover is open, tick at a low rate so it stays current even if
    // a single HAL change notification lands while the MenuBarExtra window isn't
    // flushing observation updates (a known quirk of .menuBarExtraStyle(.window)).
    private let refreshTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            footer
        }
        .frame(width: 300)
        .background(.regularMaterial)   // opaque popover surface (.window style is transparent by default)
        .onAppear {
            isVisible = true
            syncAndStart()
            monitor.refreshNow()        // catch anything that changed while closed
        }
        .onDisappear { isVisible = false }
        .onReceive(refreshTick) { _ in
            guard isVisible else { return }   // don't poll when the popover is closed
            monitor.refreshNow()              // keep the open popover live
            browserTabs.refreshNow()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { settings.hasCompletedOnboarding = true; showOnboarding = false }
        }
        // Re-sync monitor when settings change while the popover is open.
        .onChange(of: settings.hideSystemApps) { _, _ in pushSettings() }
        .onChange(of: settings.showRecentlyActive) { _, _ in pushSettings() }
        .onChange(of: settings.recentlyActiveDuration) { _, _ in pushSettings() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.tint)
            Text("Audio Finder")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch monitor.state {
        case .unsupportedOS:
            unsupportedState
        case .error(let message):
            errorState(message)
        case .ok:
            // The content stack has an intrinsic height, so the popover sizes
            // to it. A plain `ScrollView` reports zero ideal height and would
            // collapse the content band, so we only wrap in a ScrollView when
            // the list is long enough to need scrolling.
            if rowCount > maxVisibleRows {
                ScrollView { contentStack }
                    .frame(height: maxListHeight)
            } else {
                contentStack
            }
        }
    }

    /// The list of rows (or the empty state), with padding.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isEmpty {
                emptyState
            } else {
                if !monitor.playing.isEmpty {
                    sectionHeader("Currently Playing")
                    ForEach(monitor.playing) { app in
                        AppRow(
                            app: app,
                            style: .playing,
                            browserTabs: browserTabs.tabs(for: app.bundleID, visibleApps: monitor.playing)
                        ) {
                            AppActivator.activate(app)
                        } onOpenTab: { tab in
                            browserTabs.activate(tab)
                            AppActivator.activate(app)
                        }
                    }
                }
                if settings.showRecentlyActive && !monitor.recentlyActive.isEmpty {
                    sectionHeader("Recently Active")
                    ForEach(monitor.recentlyActive) { app in
                        AppRow(app: app, style: .recent) { AppActivator.activate(app) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private let maxVisibleRows = 8
    private let maxListHeight: CGFloat = 380

    /// True when nothing should be listed.
    private var isEmpty: Bool {
        monitor.playing.isEmpty && (monitor.recentlyActive.isEmpty || !settings.showRecentlyActive)
    }

    /// Rough number of rows currently shown (for sizing the scroll area).
    private var rowCount: Int {
        let recent = settings.showRecentlyActive ? monitor.recentlyActive.count : 0
        let browserTabRows = monitor.playing.reduce(0) { partial, app in
            partial + browserTabs.tabs(for: app.bundleID, visibleApps: monitor.playing).count
        }
        return monitor.playing.count + browserTabRows + recent
    }

    private var footer: some View {
        HStack {
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - State views

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No apps are currently playing audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var unsupportedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unsupported macOS version")
                .font(.headline)
            Text("Audio Finder needs \(OSSupport.minimumVersionLabel) or later to detect which app is playing audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio detection unavailable")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    // MARK: - Wiring

    private func syncAndStart() {
        pushSettings()
        monitor.start()
        browserTabs.start()
        if !settings.hasCompletedOnboarding {
            showOnboarding = true
        }
    }

    private func pushSettings() {
        monitor.apply(
            window: TimeInterval(settings.recentlyActiveDuration),
            hideSystem: settings.hideSystemApps,
            showRecent: settings.showRecentlyActive
        )
    }
}
