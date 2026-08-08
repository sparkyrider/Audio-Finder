//
//  OnboardingView.swift
//  Audio Finder
//
//  First-run explanation. No permission step is required for detection, so this
//  focuses on what the app does and the privacy guarantees.
//

import SwiftUI

enum PrivacyCopy {
    static let bullets: [String] = [
        "It reads whether an app is using audio output.",
        "It does not record audio.",
        "It does not save audio.",
        "It does not upload audio.",
        "It does not transcribe audio.",
        "It does not inspect audio content.",
        "Browser tab detection is optional and local.",
    ]
    static let summary =
        "Audio Finder reads only whether each app is currently using audio output, using a "
        + "built-in macOS capability that needs no microphone or recording permission. "
        + "If you install the browser extension, it can also show titles for Chrome or Brave "
        + "tabs that are currently making sound."
}

struct OnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browserTabs: BrowserTabMonitor
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    SetupStepHeader(
                        number: 1,
                        title: "Connect your browser",
                        detail: "Install the extension so playing tabs show up by title."
                    )
                    BrowserConnectorCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SetupStepHeader(
                        number: 2,
                        title: "Keep it in your menu bar",
                        detail: "Recommended for a menu-bar utility."
                    )
                    LaunchAtLoginCard()
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                Label("No mic access needed", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip for now", action: onFinish)
                    .controlSize(.large)
                Button("Continue", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 580, height: 484)
        .onAppear {
            settings.refreshLaunchAtLogin()
            browserTabs.start()
            browserTabs.refreshNow()
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            AudioSignalMark(isActive: true)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 5) {
                Text("Welcome to Audio Finder")
                    .font(.title.bold())
                Text("See which app — and which browser — is playing sound.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The product's recurring visual cue: a speaker sitting inside a restrained
/// signal ring. It connects onboarding with the menu-bar status without adding
/// decorative chrome to the rest of the interface.
struct AudioSignalMark: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.10))
            Circle()
                .stroke(Color.accentColor.opacity(isActive ? 0.34 : 0.18), lineWidth: 2)
                .scaleEffect(pulse ? 1.12 : 0.86)
                .opacity(pulse ? 0 : 1)
            Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityHidden(true)
        .onAppear { updateAnimation() }
        .onChange(of: isActive) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        guard isActive, !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
