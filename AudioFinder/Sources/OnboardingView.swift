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
        "It detects audio activity level only.",
        "It does not record audio.",
        "It does not save audio.",
        "It does not upload audio.",
        "It does not transcribe audio.",
        "It does not inspect audio content.",
        "Browser tab detection is optional and local.",
    ]
    static let summary =
        "Audio Finder reads only whether each app is currently producing sound, using a "
        + "built-in macOS capability that needs no microphone or recording permission. "
        + "If you install the browser extension, it can also show titles for Chrome or Brave "
        + "tabs that are currently making sound."
}

struct OnboardingView: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(PrivacyCopy.bullets, id: \.self) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                Text(line)
                            }
                        }
                    }

                    Text(PrivacyCopy.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Label("No microphone permission is needed to detect audio.",
                          systemImage: "checkmark.shield")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                }
                .padding(28)
            }

            Divider()

            HStack {
                Spacer()
                Button("Get Started", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 460, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Audio Finder")
                        .font(.largeTitle.bold())
                    Text("Find which app is making sound.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
