//
//  AppRow.swift
//  Audio Finder
//
//  A single app row in the popover: icon, name, a status indicator, and an
//  Open action. Playing rows show an animated "sound bars" glyph; recent rows
//  show "Xs ago".
//

import SwiftUI

struct AppRow: View {
    enum Style { case playing, recent }

    let app: AudioApp
    let style: Style
    let browserTabs: [BrowserAudioTab]
    let onOpen: () -> Void
    let onOpenTab: (BrowserAudioTab) -> Void

    @State private var isHovering = false
    @State private var hoveringTabID: BrowserAudioTab.ID?

    init(
        app: AudioApp,
        style: Style,
        browserTabs: [BrowserAudioTab] = [],
        onOpen: @escaping () -> Void,
        onOpenTab: @escaping (BrowserAudioTab) -> Void = { _ in }
    ) {
        self.app = app
        self.style = style
        self.browserTabs = browserTabs
        self.onOpen = onOpen
        self.onOpenTab = onOpenTab
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            appButton
            if style == .playing && !browserTabs.isEmpty {
                tabList
            }
        }
    }

    private var appButton: some View {
        // The whole row is a Button. A SwiftUI Button responds to the FIRST
        // click even when the MenuBarExtra popover panel isn't key — a bare
        // onTapGesture does not (the first click only makes the panel key),
        // which was the "have to click twice" bug.
        Button(action: { if app.runningApplicationActivatable { onOpen() } }) {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(!app.runningApplicationActivatable)
        .onHover { isHovering = $0 }
        .help(app.runningApplicationActivatable ? "Bring \(app.name) to the front" : app.name)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            icon

            Text(app.name)
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 6)

            if style == .playing {
                SoundBars()
                    .frame(width: 16, height: 14)
                    .foregroundStyle(.tint)
            }

            if app.runningApplicationActivatable {
                // Affordance hint; the whole row is the click target.
                Image(systemName: "arrow.up.forward.app")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
    }

    private var icon: some View {
        Group {
            if let nsImage = app.icon {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: app.isSystemOrOther ? "gearshape.2" : "app.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
        }
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(browserTabs) { tab in
                Button {
                    onOpenTab(tab)
                } label: {
                    tabRow(tab)
                }
                .buttonStyle(.plain)
                .onHover { hoveringTabID = $0 ? tab.id : nil }
                .help("Open tab: \(tab.displayTitle)")
            }
        }
    }

    private func tabRow(_ tab: BrowserAudioTab) -> some View {
        let isTabHovering = hoveringTabID == tab.id

        return HStack(spacing: 7) {
            Image(systemName: tab.isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(tab.displayTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if tab.isIncognito {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "arrow.up.forward.app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .opacity(isTabHovering ? 1 : 0)
        }
        .padding(.leading, 38)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTabHovering ? Color.primary.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
    }
}

private extension AudioApp {
    /// Only offer "Open" when we have a concrete app to activate.
    var runningApplicationActivatable: Bool { activationPID != nil || (bundleID != nil && !isSystemOrOther) }
}

/// A small three-bar equalizer animation to indicate live audio.
struct SoundBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            bar(scale: phase ? 1.0 : 0.4, delay: 0.0)
            bar(scale: phase ? 0.5 : 1.0, delay: 0.15)
            bar(scale: phase ? 0.9 : 0.6, delay: 0.3)
        }
        .onAppear {
            if !reduceMotion {
                phase = true
            }
        }
    }

    private func bar(scale: CGFloat, delay: Double) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .frame(width: 3)
            .scaleEffect(y: scale, anchor: .bottom)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(delay),
                value: phase
            )
    }
}
