//
//  AppResolver.swift
//  Audio Finder
//
//  Resolves an audio-emitting process id to the user-facing application that
//  owns it, so helper processes (e.g. "Discord Helper (Renderer)" or
//  "Google Chrome Helper") are grouped under their parent ("Discord", "Chrome").
//
//  Uses only public, sandbox-safe APIs:
//    • NSRunningApplication(processIdentifier:)         — direct match
//    • NSRunningApplication.activationPolicy            — tells helpers from real apps
//    • proc_pidinfo(PROC_PIDTBSDINFO).pbi_ppid          — parent-PID walk
//    • proc_pidpath                                      — bundle-path-prefix match
//
//  Key insight (verified live): a helper such as "Discord Helper (Renderer)"
//  IS its own NSRunningApplication, but it is an `.accessory` app whose bundle
//  lives inside the parent's `.app/Contents/Frameworks`. We therefore only
//  accept a direct match as final when it's a regular (Dock-shown) app; for
//  helpers we climb to the owning regular app.
//

import AppKit
import Darwin

/// The application an audio process belongs to.
struct ResolvedApp: Hashable {
    /// Stable identity for grouping. Bundle id when known, else a synthetic key.
    let identity: String
    let bundleID: String?
    let name: String
    let runningApplication: NSRunningApplication?

    /// True when we could not map the process to any real app bundle
    /// (daemons, coreaudiod, plug-in hosts …).
    var isSystemOrOther: Bool { runningApplication == nil }
}

enum AppResolver {

    /// Resolve a PID to its owning application. Never returns nil — falls back
    /// to a "System / other" descriptor so unknown emitters are still listed.
    static func resolve(pid: pid_t, bundleIDHint: String?) -> ResolvedApp {
        let direct = NSRunningApplication(processIdentifier: pid)

        // Fast path: the audio PID is itself a regular, user-facing app.
        if let direct, direct.activationPolicy == .regular {
            return descriptor(for: direct)
        }

        // The PID is a helper/agent (or unmapped). Find the owning REGULAR app.
        if let owner = owningRegularApp(of: pid) {
            return descriptor(for: owner)
        }

        // No regular owner found. If the direct match exists (an accessory app
        // like a menu-bar utility), use it rather than dropping to "other".
        if let direct {
            return descriptor(for: direct)
        }

        // Bundle-id hint from Core Audio, if it maps to something running.
        if let hint = bundleIDHint,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: hint).first {
            return descriptor(for: app)
        }

        let name = bundleIDHint.map(systemOrOtherName(from:)) ?? "System / other"
        let identity = bundleIDHint ?? "system.other.pid.\(pid)"
        return ResolvedApp(identity: identity, bundleID: bundleIDHint, name: name, runningApplication: nil)
    }

    // MARK: - Owning-app resolution

    /// Find the regular (Dock-shown) application that owns `pid`, using the
    /// parent-PID walk first and the bundle-path-prefix as a backstop.
    private static func owningRegularApp(of pid: pid_t) -> NSRunningApplication? {
        if let viaParent = walkParentsForRegularApp(from: pid) {
            return viaParent
        }
        if let viaPath = matchRegularAppByExecutablePath(pid: pid) {
            return viaPath
        }
        return nil
    }

    /// Walk up the parent-process chain looking for a regular app.
    private static func walkParentsForRegularApp(from pid: pid_t) -> NSRunningApplication? {
        var current = pid
        // Cap depth so a broken chain can't loop; stop at launchd (PID 1).
        for _ in 0..<8 {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular {
                return app
            }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Find the running regular app whose bundle directory contains the
    /// process's executable path (catches Chrome/Electron/Safari/Teams helpers
    /// whose parent PID may not itself be a running NSRunningApplication).
    private static func matchRegularAppByExecutablePath(pid: pid_t) -> NSRunningApplication? {
        guard let execPath = executablePath(of: pid) else { return nil }

        var best: NSRunningApplication?
        var bestLength = 0
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundlePath = app.bundleURL?.path else { continue }
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            if execPath.hasPrefix(prefix), bundlePath.count > bestLength {
                best = app
                bestLength = bundlePath.count // most specific (deepest) match wins
            }
        }
        return best
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Descriptors

    private static func descriptor(for app: NSRunningApplication) -> ResolvedApp {
        let bundleID = app.bundleIdentifier
        let name = app.localizedName
            ?? bundleID
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? "Unknown app"
        let identity = bundleID ?? "pid.\(app.processIdentifier)"
        return ResolvedApp(identity: identity, bundleID: bundleID, name: name, runningApplication: app)
    }

    /// Turn a raw bundle id into something readable for the "System / other" row.
    private static func systemOrOtherName(from bundleID: String) -> String {
        if bundleID == "com.apple.audio.coreaudiod" { return "System audio" }
        // e.g. "com.apple.WebKit.GPU" → "GPU"
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
