//
//  AppActivator.swift
//  Audio Finder
//
//  Brings a target application to the foreground using the macOS 14+
//  cooperative-activation API, with a resolution path by PID or bundle id.
//

import AppKit

enum AppActivator {

    /// Bring the app described by `audioApp` to the front.
    static func activate(_ audioApp: AudioApp) {
        guard let target = runningApplication(for: audioApp) else { return }
        bringToFront(target)
    }

    private static func runningApplication(for app: AudioApp) -> NSRunningApplication? {
        if let pid = app.activationPID,
           let running = NSRunningApplication(processIdentifier: pid) {
            return running
        }
        if let bundleID = app.bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return nil
    }

    private static func bringToFront(_ target: NSRunningApplication) {
        // The MenuBarExtra popover panel is often NOT the active app's key
        // window, so cooperative activation (`yieldActivation` +
        // `activate(from:)`) can silently no-op on the first try — which is what
        // caused "click twice to open". We instead:
        //   1. Yield our activation to the target (harmless if we're not active).
        //   2. Activate the target directly, ignoring our own state.
        // `activate(from:)` is the modern API but its hand-off depends on the
        // caller being frontmost; `.activate()` (with the ignore option on
        // older systems) is the dependable fallback that works from a
        // background/accessory context.
        NSApp.yieldActivation(to: target)
        if !target.activate(from: .current, options: [.activateAllWindows]) {
            // Fall back to unconditional activation if the cooperative path
            // reports failure (e.g. our panel wasn't key).
            target.activate(options: [.activateAllWindows])
        }
    }
}
