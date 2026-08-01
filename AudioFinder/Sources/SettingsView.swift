//
//  SettingsView.swift
//  Audio Finder
//
//  Minimal settings, plus Privacy, browser connector, and diagnostics sections.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: AudioMonitor
    @EnvironmentObject private var browserTabs: BrowserTabMonitor

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            browserTab
                .tabItem { Label("Browsers", systemImage: "macwindow.on.rectangle") }
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 540, height: 560)
        .onAppear {
            settings.refreshLaunchAtLogin()
            browserTabs.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLogin()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                runningStatus
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Text("Audio Finder starts quietly in the menu bar after you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.loginItemStatus == .requiresApproval {
                    HStack {
                        Label("Approval required in System Settings", systemImage: "person.badge.key")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            settings.openLoginItemSettings()
                        }
                    }
                }

                if let message = settings.launchAtLoginError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Display") {
                Toggle("Hide system & background apps", isOn: $settings.hideSystemApps)
            }

            Section {
                Button("Show Welcome") {
                    openWindow(id: AppWindow.welcome)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Section("Recently Active") {
                Toggle("Show recently active apps", isOn: $settings.showRecentlyActive)
                Picker("Keep visible for", selection: $settings.recentlyActiveDuration) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                .disabled(!settings.showRecentlyActive)
                Text("How long an app stays listed after its sound stops — useful for catching brief notification blips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var runningStatus: some View {
        HStack(spacing: 16) {
            AudioSignalMark(isActive: !monitor.playing.isEmpty)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.title3.bold())
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch monitor.state {
        case .ok:
            return monitor.playing.isEmpty ? "Listening for audio" : "Audio source found"
        case .unsupportedOS:
            return "Unsupported macOS version"
        case .error:
            return "Audio detection is recovering"
        }
    }

    private var statusDetail: String {
        switch monitor.state {
        case .ok:
            if monitor.playing.isEmpty {
                return "Audio Finder is running in your menu bar."
            }
            let count = monitor.playing.count
            return "\(count) \(count == 1 ? "app is" : "apps are") using audio output."
        case .unsupportedOS:
            return "Audio Finder requires \(OSSupport.minimumVersionLabel) or later."
        case .error(let message):
            return message
        }
    }

    // MARK: - Privacy

    private var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Everything stays on your Mac", systemImage: "lock.shield")
                    .font(.headline)

                ForEach(PrivacyCopy.bullets, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(line)
                    }
                    .font(.callout)
                }

                Text(PrivacyCopy.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Browsers

    private var browserTab: some View {
        Form {
            Section("Chrome and Brave") {
                LabeledContent("Local bridge", value: browserBridgeStatus)
                LabeledContent("Browser connector", value: browserConnectorStatus)
                LabeledContent("Port", value: "\(browserTabs.port)")

                if !browserTabs.trustedExtensionOrigins.isEmpty {
                    Button {
                        browserTabs.resetTrustedExtensions()
                    } label: {
                        Label("Reset Browser Connector", systemImage: "arrow.counterclockwise")
                    }
                }
            }

            Section {
                Text("Install the companion browser extension once. After that, audible Chrome and Brave tab titles connect automatically over 127.0.0.1 without a pairing code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var browserBridgeStatus: String {
        switch browserTabs.serverState {
        case .stopped:
            return "Stopped"
        case .running(let port):
            return "Listening on 127.0.0.1:\(port)"
        case .failed(let message):
            return message
        }
    }

    private var browserConnectorStatus: String {
        if let name = browserTabs.lastConnectorName {
            return "Connected (\(name))"
        }
        if browserTabs.trustedExtensionOrigins.isEmpty {
            return "Waiting for extension"
        }
        return "Waiting for tab update"
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Troubleshooting report")
                .font(.headline)
            Text("Copy this when reporting an issue. It contains no audio content.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            HStack {
                Spacer()
                Button {
                    Diagnostics.copyToPasteboard(report)
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
            }
        }
        .padding(20)
    }

    private var report: String {
        Diagnostics.report(monitor: monitor, settings: settings)
    }
}
