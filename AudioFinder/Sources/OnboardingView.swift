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
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    VStack(spacing: 12) {
                        feature(
                            icon: "menubar.rectangle",
                            title: "Always one click away",
                            detail: "Look for the speaker in your menu bar whenever sound is hard to find."
                        )
                        feature(
                            icon: "waveform.badge.magnifyingglass",
                            title: "Find the source, not the content",
                            detail: "Audio Finder checks output state. It never records, transcribes, or listens."
                        )
                    }

                    startupChoice
                }
                .padding(30)
            }

            Divider()

            HStack {
                Label("No microphone permission needed", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start using Audio Finder", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 520, height: 470)
        .onAppear { settings.refreshLaunchAtLogin() }
    }

    private var header: some View {
        HStack(spacing: 18) {
            AudioSignalMark(isActive: true)
                .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                Text("Welcome to Audio Finder")
                    .font(.largeTitle.bold())
                Text("Know exactly where your Mac's sound is coming from.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startupChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Start Audio Finder when I log in", isOn: $settings.launchAtLogin)
                .font(.headline)

            Text("Recommended for a menu-bar utility. You can change this anytime in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if settings.loginItemStatus == .requiresApproval {
                approvalCallout
            } else if let message = settings.launchAtLoginError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        )
    }

    private var approvalCallout: some View {
        HStack(alignment: .center, spacing: 10) {
            Label("Approval is required in System Settings.", systemImage: "person.badge.key")
                .font(.callout)
            Spacer()
            Button("Open Login Items") {
                settings.openLoginItemSettings()
            }
        }
    }

    private func feature(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
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
                .font(.system(size: 29, weight: .semibold))
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
