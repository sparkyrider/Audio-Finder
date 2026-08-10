//
//  MenuContentView.swift
//  Audio Finder
//
//  The popover shown from the menu bar. Lists currently-playing apps and a
//  "recently active" section, with an Open action per row. Handles the
//  empty / unsupported / onboarding states.
//

import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var monitor: AudioMonitor
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browserTabs: BrowserTabMonitor
    @Environment(\.openWindow) private var openWindow

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
        .background(menuPanelBackground)
        .onAppear {
            isVisible = true
            monitor.refreshNow()        // catch anything that changed while closed
            browserTabs.refreshNow()
        }
        .onDisappear { isVisible = false }
        .onReceive(refreshTick) { _ in
            guard isVisible else { return }   // don't poll when the popover is closed
            monitor.refreshNow()              // keep the open popover live
            browserTabs.refreshNow()
        }
    }

    // The system menu material, so the dropdown matches every other menu bar
    // item. The marketing renderer draws offscreen where behind-window
    // sampling is unavailable, so it keeps the previous in-window material.
    @ViewBuilder
    private var menuPanelBackground: some View {
#if AUDIO_FINDER_SCREENSHOT_RENDERER
        Rectangle().fill(.regularMaterial)
#else
        MenuPanelMaterial().ignoresSafeArea()
#endif
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.tint)
            Text("Audio Finder")
                .font(.headline)
            Spacer()
            browserStatusPill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var browserStatusPill: some View {
        let isConnected = browserConnectionText != nil

        return Button(action: showBrowserSetup) {
            HStack(spacing: 8) {
                if isConnected {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }

                Text(browserConnectionText ?? "Connect browser")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isConnected
                            ? Color.green.opacity(0.12)
                            : Color.accentColor.opacity(0.10)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Open browser extension setup")
        .accessibilityLabel(browserConnectionText ?? "Connect browser")
    }

    private var browserConnectionText: String? {
        let names = browserTabs.connectedBrowsers.map(\.displayName)
        switch names.count {
        case 0:
            return nil
        case 1:
            return "\(names[0]) connected"
        default:
            return "\(names.count) browsers connected"
        }
    }

    private func showBrowserSetup() {
        settings.selectedTab = .home
        openWindow(id: AppWindow.settings)
        NSApp.activate(ignoringOtherApps: true)
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
                    .scrollIndicators(.hidden)
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
            FooterActionButton(title: "Settings", systemImage: "gearshape") {
                settings.selectedTab = .home
                openWindow(id: AppWindow.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            FooterActionButton(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
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

}

/// Footer actions highlight on hover like rows do, so the whole panel shares
/// one interaction language.
private struct FooterActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#if !AUDIO_FINDER_SCREENSHOT_RENDERER
/// The `.menu` material native menu bar dropdowns sit on. SwiftUI materials
/// composite within the window, which left the panel reading as a flat sheet
/// next to NSMenu; blending behind the window picks up the desktop blur the
/// same way the system menus alongside it do.
private struct MenuPanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#endif
