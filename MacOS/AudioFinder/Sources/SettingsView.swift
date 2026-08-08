//
//  SettingsView.swift
//  Audio Finder
//
//  Minimal settings, plus Privacy, browser connector, and diagnostics sections.
//

import SwiftUI

private enum ProductLinks {
    static let privacyPolicy = URL(string: "https://audiofinder.app/privacy")!
    static let termsOfService = URL(string: "https://audiofinder.app/terms")!
    static let browserConnector = URL(
        string: "https://chromewebstore.google.com/detail/ehngclenbdcacgiajflfjfffhlilpcko"
    )!
}

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: AudioMonitor
    @EnvironmentObject private var browserTabs: BrowserTabMonitor
    @State private var isPrivacyExpanded = false
    @State private var isDiagnosticsExpanded = false

    var body: some View {
        TabView(selection: $settings.selectedTab) {
            homeTab
                .tabItem { Label("Home", systemImage: "house") }
                .tag(SettingsTab.home)
            preferencesTab
                .tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.preferences)
            browserTab
                .tabItem { Label("Browsers", systemImage: "macwindow.on.rectangle") }
                .tag(SettingsTab.browsers)
        }
        .frame(width: 580, height: 600)
        .onAppear {
            settings.refreshLaunchAtLogin()
            browserTabs.start()
            browserTabs.refreshNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLogin()
        }
    }

    // MARK: - Home

    private var homeTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            welcomeHeader

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
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var welcomeHeader: some View {
        HStack(spacing: 16) {
            AudioSignalMark(isActive: true)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Audio Finder")
                    .font(.title.bold())
                Text("See which app — and which browser — is playing sound.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Preferences

    private var preferencesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                audioListPreferences
                privacySection
                diagnosticsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var audioListPreferences: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio list")
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                Toggle("Hide system & background apps", isOn: $settings.hideSystemApps)
                    .padding(14)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show recently active apps", isOn: $settings.showRecentlyActive)

                    HStack {
                        Text("Keep visible for")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Keep visible for", selection: $settings.recentlyActiveDuration) {
                            Text("15 seconds").tag(15)
                            Text("30 seconds").tag(30)
                            Text("60 seconds").tag(60)
                        }
                        .labelsHidden()
                        .frame(width: 128)
                        .disabled(!settings.showRecentlyActive)
                    }

                    Text("Useful for catching brief notification sounds after they stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)

                Divider()

                HStack {
                    Text(audioStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Welcome") {
                        openWindow(id: AppWindow.welcome)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
            )
        }
    }

    private var audioStatusText: String {
        switch monitor.state {
        case .ok:
            return monitor.playing.isEmpty ? "Listening for audio" : "Audio source found"
        case .unsupportedOS:
            return "Unsupported macOS version"
        case .error:
            return "Audio detection is recovering"
        }
    }

    private var privacySection: some View {
        DisclosureGroup(isExpanded: $isPrivacyExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Everything stays on your Mac")
                    .font(.callout.weight(.semibold))

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

                Divider()
                    .padding(.vertical, 4)

                HStack(spacing: 16) {
                    Link("Privacy Policy", destination: ProductLinks.privacyPolicy)
                    Link("Terms of Service", destination: ProductLinks.termsOfService)
                }
                .font(.callout)
            }
            .padding(.top, 12)
        } label: {
            Label("Privacy", systemImage: "lock.shield")
                .font(.headline)
        }
        .padding(14)
        .background(infoCardBackground)
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
                Text("Install the companion browser extension, review its disclosure, and enable the connector. After that, audible Chrome and Brave tab titles connect automatically over 127.0.0.1 without a pairing code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(destination: ProductLinks.browserConnector) {
                    Label("Get Browser Connector", systemImage: "arrow.up.right.square")
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.hidden)
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

    private var diagnosticsSection: some View {
        DisclosureGroup(isExpanded: $isDiagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
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
                .frame(height: 150)
                .scrollIndicators(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )

                HStack {
                    Spacer()
                    Button {
                        Diagnostics.copyToPasteboard(report)
                    } label: {
                        Label("Copy Report", systemImage: "doc.on.doc")
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.headline)
        }
        .padding(14)
        .background(infoCardBackground)
    }

    private var infoCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
            )
    }

    private var report: String {
        Diagnostics.report(monitor: monitor, settings: settings)
    }
}

struct SetupStepHeader: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.10)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct BrowserConnectorCard: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var browserTabs: BrowserTabMonitor

    private enum BrowserTarget: String, CaseIterable, Identifiable {
        case chrome
        case brave

        var id: String { rawValue }

        var name: String {
            switch self {
            case .chrome: "Chrome"
            case .brave: "Brave"
            }
        }

        var bundleID: String {
            switch self {
            case .chrome: "com.google.Chrome"
            case .brave: "com.brave.Browser"
            }
        }

        var assetName: String {
            switch self {
            case .chrome: "ChromeLogo"
            case .brave: "BraveLogo"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(BrowserTarget.allCases.enumerated()), id: \.element.id) { index, browser in
                    browserRow(browser)

                    if index < BrowserTarget.allCases.count - 1 {
                        Divider()
                            .padding(.leading, 66)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
            )

            Text("One-click install — free on the Chrome Web Store.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 38)
        .padding(.trailing, 10)
    }

    private func browserRow(_ browser: BrowserTarget) -> some View {
        let connected = browserTabs.isConnected(to: browser.bundleID)

        return HStack(spacing: 12) {
            Image(browser.assetName)
                .interpolation(.high)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .padding(browser == .brave ? 3 : 0)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

            Text(browser.name)
                .font(.headline)

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.65))
                    .frame(width: 8, height: 8)
                Text(connected ? "Connected" : "Not detected")
                    .font(.callout)
                    .foregroundStyle(connected ? Color.green : Color.secondary)
            }
            .accessibilityElement(children: .combine)

            Button(connected ? "Installed" : "Install") {
                openURL(ProductLinks.browserConnector)
            }
            .disabled(connected)
            .controlSize(.regular)
            .frame(minWidth: 72)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct LaunchAtLoginCard: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Start Audio Finder when I log in")
                    .font(.body)
                Spacer()
                Toggle("Start Audio Finder when I log in", isOn: $settings.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .accessibilityLabel("Start Audio Finder when I log in")
            }

            if settings.loginItemStatus == .requiresApproval {
                HStack(spacing: 10) {
                    Label("Approval required in System Settings", systemImage: "person.badge.key")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items") {
                        settings.openLoginItemSettings()
                    }
                }
            } else if let message = settings.launchAtLoginError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
        )
        .padding(.leading, 38)
        .padding(.trailing, 10)
    }
}
