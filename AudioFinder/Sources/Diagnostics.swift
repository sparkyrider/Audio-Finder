//
//  Diagnostics.swift
//  Audio Finder
//
//  Builds a copy-able troubleshooting report. Contains version, permission
//  posture, output-device type, and the NAMES of detected apps only — never
//  any audio content.
//

import AppKit
import CoreAudio
import Foundation
import ServiceManagement

enum Diagnostics {

    @MainActor
    static func report(monitor: AudioMonitor, settings: SettingsStore) -> String {
        let snap = monitor.diagnosticSnapshot()
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        lines.append("Audio Finder — Diagnostic Report")
        lines.append(String(repeating: "=", count: 34))
        lines.append("App version:        \(appVersion) (\(build))")
        lines.append("macOS version:      \(OSSupport.osVersionString)")
        lines.append("Detection supported: \(OSSupport.isSupported ? "yes" : "no")")
        lines.append("Monitor state:      \(describe(monitor.state))")
        lines.append("")
        lines.append("Permissions:")
        lines.append("  Audio detection:  no permission required (read-only HAL)")
        lines.append("  Launch at login:  \(loginItemStatus())")
        lines.append("")
        lines.append("Audio output device: \(defaultOutputDeviceDescription())")
        lines.append("")
        lines.append("Settings:")
        lines.append("  Show recently active: \(settings.showRecentlyActive)")
        lines.append("  Recently-active window: \(settings.recentlyActiveDuration)s")
        lines.append("  Hide system apps:      \(settings.hideSystemApps)")
        lines.append("")
        lines.append("Detection snapshot:")
        lines.append("  HAL process objects:   \(snap.processCount)")
        lines.append("  Currently playing:     \(snap.playing.isEmpty ? "(none)" : snap.playing.joined(separator: ", "))")
        lines.append("  Recently active:       \(snap.recent.isEmpty ? "(none)" : snap.recent.joined(separator: ", "))")
        if let err = snap.error {
            lines.append("  Last error:            \(err)")
        }
        lines.append("")
        lines.append("This report contains no audio content.")
        return lines.joined(separator: "\n")
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Helpers

    private static func describe(_ state: MonitorState) -> String {
        switch state {
        case .ok: "ok"
        case .unsupportedOS: "unsupported OS"
        case .error(let message): "error: \(message)"
        }
    }

    private static func loginItemStatus() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .notRegistered: "not registered"
        case .requiresApproval: "requires approval"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }

    /// Describe the default output device's transport (built-in / BT / USB / HDMI…).
    private static func defaultOutputDeviceDescription() -> String {
        let device = CAProperty.scalar(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioObjectID(kAudioObjectUnknown)
        )
        guard device != AudioObjectID(kAudioObjectUnknown) else { return "(none)" }

        let name = CAProperty.string(device, kAudioObjectPropertyName) ?? "Unknown device"
        let transport = CAProperty.scalar(
            device, kAudioDevicePropertyTransportType, default: UInt32(0)
        )
        return "\(name) [\(transportLabel(transport))]"
    }

    private static func transportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeHDMI: "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: "displayport"
        case kAudioDeviceTransportTypeAirPlay: "airplay"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: "virtual"
        default: "other"
        }
    }
}
