//
//  AudioMonitor.swift
//  Audio Finder
//
//  The detection engine. Enumerates Core Audio HAL process objects, observes
//  each one's `kAudioProcessPropertyIsRunningOutput` flag, groups emitting
//  processes by their owning application, and publishes an observable snapshot
//  of "currently playing" and "recently active" apps.
//
//  Design: the source of truth is a per-HAL-object cache (`tracked`). Each
//  object records its resolved owning app and whether it is currently
//  outputting. An app's "is playing" is *derived* from that cache, never stored
//  as a sticky flag — so when an object stops OR disappears from the HAL list
//  (app quit/crash, closed browser tab), the app correctly leaves the playing
//  list. We also reconcile fully on wake and after Core Audio service resets.
//
//  Event-driven: listeners push changes, with a light health pass every 15
//  seconds and a timer that runs only while aging out the recent list.
//

import AppKit
import Combine
import CoreAudio
import Foundation
import os

/// One app shown in the UI, aggregating all of its audio processes.
struct AudioApp: Identifiable, Equatable {
    let id: String            // ResolvedApp.identity
    let bundleID: String?
    let name: String
    let icon: NSImage?
    /// PID of the running app we can activate.
    let activationPID: pid_t?
    let isSystemOrOther: Bool

    /// True while at least one of its processes is outputting audio.
    var isPlaying: Bool
    /// Last moment any of its processes was outputting audio.
    var lastActive: Date

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
            && lhs.isPlaying == rhs.isPlaying
            && lhs.lastActive == rhs.lastActive
            && lhs.name == rhs.name
    }
}

/// Overall detection availability / health, surfaced to the UI.
enum MonitorState: Equatable {
    case ok
    case unsupportedOS          // below our deployment floor
    case error(String)
}

@MainActor
final class AudioMonitor: ObservableObject {

    // Published UI state ----------------------------------------------------
    @Published private(set) var playing: [AudioApp] = []
    @Published private(set) var recentlyActive: [AudioApp] = []
    @Published private(set) var state: MonitorState = .ok

    // Settings (driven from SettingsStore) ----------------------------------
    private(set) var recentlyActiveWindow: TimeInterval = 30
    private(set) var hideSystemApps: Bool = true
    private(set) var showRecentlyActive: Bool = true

    /// Apply settings and immediately re-filter the published lists so the UI
    /// updates live even when no aging timer is running.
    func apply(window: TimeInterval, hideSystem: Bool, showRecent: Bool) {
        recentlyActiveWindow = window
        hideSystemApps = hideSystem
        showRecentlyActive = showRecent
        recomputePublished()
    }

    // Internals -------------------------------------------------------------
    private let queue = DispatchQueue(label: "com.audiofinder.monitor", qos: .utility)
    private let log = Logger(subsystem: "com.audiofinder.app", category: "AudioMonitor")

    /// What we know about each tracked HAL process object.
    private struct TrackedProcess {
        let identity: String
        let isOutputting: Bool
    }

    /// Per-HAL-object listener tokens.
    private var processListeners: [AudioObjectID: ListenerToken] = [:]
    /// Per-HAL-object cache: resolved owning app + current output state.
    private var tracked: [AudioObjectID: TrackedProcess] = [:]
    /// Display metadata per app identity (name, icon, activation pid…).
    private var appMeta: [String: AudioApp] = [:]
    /// Last time each app identity was outputting (drives "recently active").
    private var lastActiveByIdentity: [String: Date] = [:]

    private var processListListener: ListenerToken?
    private var serviceRestartListener: ListenerToken?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var ageTimer: Timer?
    private var healthTimer: Timer?
    private var started = false

    // Diagnostics -----------------------------------------------------------
    private(set) var lastProcessObjectCount = 0
    private(set) var lastError: String?

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        guard OSSupport.isSupported else {
            state = .unsupportedOS
            return
        }

        observeWorkspace()
        establishSystemListeners()
        startHealthTimer()
        refreshProcessSet()
    }

    /// Re-read all HAL process state and republish. Safe to call from the UI
    /// (e.g. a refresh tick while the popover is open). No-op until started.
    func refreshNow() {
        guard started else { return }
        refreshProcessSet()
    }

    func stop() {
        started = false
        processListeners.values.forEach { $0.remove() }
        processListeners.removeAll()
        processListListener?.remove()
        processListListener = nil
        serviceRestartListener?.remove()
        serviceRestartListener = nil
        tracked.removeAll()
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        ageTimer?.invalidate()
        ageTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Establish listeners owned by the Core Audio system object. Either can
    /// become invalid when coreaudiod resets, so the health timer retries any
    /// missing registration without requiring an app restart.
    private func establishSystemListeners() {
        guard started else { return }

        if serviceRestartListener == nil {
            serviceRestartListener = CAProperty.addListener(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyServiceRestarted,
                queue: queue
            ) { [weak self] in
                Task { @MainActor in self?.handleAudioServiceRestart() }
            }
        }

        if processListListener == nil {
            processListListener = CAProperty.addListener(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyProcessObjectList,
                queue: queue
            ) { [weak self] in
                Task { @MainActor in self?.refreshProcessSet() }
            }
        }

        if processListListener == nil {
            state = .error("Audio detection is reconnecting. It will retry automatically.")
            lastError = "Could not observe the Core Audio process list."
        } else {
            state = .ok
            lastError = nil
        }
    }

    private func startHealthTimer() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.establishSystemListeners()
                self.refreshProcessSet()
            }
        }
    }

    private func handleAudioServiceRestart() {
        guard started else { return }
        log.notice("Core Audio restarted; rebuilding process listeners")
        rebuildHALConnections()
    }

    // MARK: - Process set management

    /// Reconcile our per-process listeners and cache with the current HAL list.
    private func refreshProcessSet() {
        guard started else { return }   // ignore Tasks that landed after stop()

        let ids = CAProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        )
        lastProcessObjectCount = ids.count
        let current = Set(ids)

        // Drop listeners + cache entries for processes that disappeared.
        // (This is what fixes "app quit/crashed while playing": its cache entry
        //  is removed, so the app is no longer derived as playing.)
        for (obj, token) in processListeners where !current.contains(obj) {
            token.remove()
            processListeners.removeValue(forKey: obj)
            tracked.removeValue(forKey: obj)
        }

        // Add listeners for new processes; re-read state for ALL current
        // objects. Re-reading survivors (not just new ones) self-heals the case
        // where a process goes silent without its per-object listener firing
        // (e.g. coreaudiod keeps the object but flips IsRunningOutput to 0).
        for obj in current {
            if processListeners[obj] == nil {
                let token = CAProperty.addListener(
                    obj,
                    kAudioProcessPropertyIsRunningOutput,
                    queue: queue
                ) { [weak self] in
                    Task { @MainActor in self?.evaluateProcess(obj) }
                }
                // A nil token is deliberately not cached; the next health pass
                // retries that process while cache reconciliation still works.
                processListeners[obj] = token
            }
            cacheProcess(obj)
        }

        recomputePublished()
    }

    /// Read one process object's state into the cache (no publish).
    /// Returns true if the cache changed.
    @discardableResult
    private func cacheProcess(_ object: AudioObjectID) -> Bool {
        let pid = pid_t(CAProperty.scalar(object, kAudioProcessPropertyPID, default: Int32(-1)))
        guard pid > 0 else {
            return tracked.removeValue(forKey: object) != nil
        }

        let isOutputting = CAProperty.scalar(
            object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)
        ) == 1

        // Resolve the owning app once and remember its display metadata.
        let resolved = AppResolver.resolve(
            pid: pid,
            bundleIDHint: CAProperty.string(object, kAudioProcessPropertyBundleID)
        )
        rememberMeta(resolved)

        let new = TrackedProcess(identity: resolved.identity, isOutputting: isOutputting)
        let old = tracked[object]
        tracked[object] = new

        if isOutputting {
            lastActiveByIdentity[resolved.identity] = Date()
        }
        return old?.identity != new.identity || old?.isOutputting != new.isOutputting
    }

    /// Listener callback for one process's output flag.
    private func evaluateProcess(_ object: AudioObjectID) {
        guard started else { return }   // ignore Tasks that landed after stop()
        if cacheProcess(object) {
            recomputePublished()
        }
    }

    /// Cache display metadata for an app identity (icon/name/activation pid).
    private func rememberMeta(_ resolved: ResolvedApp) {
        let icon = resolved.runningApplication?.icon
        let existing = appMeta[resolved.identity]
        // Always refresh the live PID and display metadata. An app can relaunch
        // under the same bundle identity while our recently-active entry is
        // still cached; retaining the old PID would make its Open action stale.
        appMeta[resolved.identity] = AudioApp(
            id: resolved.identity,
            bundleID: resolved.bundleID,
            name: resolved.name,
            icon: icon ?? existing?.icon,
            activationPID: resolved.runningApplication?.processIdentifier,
            isSystemOrOther: resolved.isSystemOrOther,
            isPlaying: existing?.isPlaying ?? false,
            lastActive: existing?.lastActive ?? .distantPast
        )
    }

    // MARK: - Workspace / power observation

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter

        // App quit: re-derive (its processes should already be gone, but this
        // catches any lag and refreshes icons).
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProcessSet() }
        })

        // App launch: update activation PIDs and icons for any identities that
        // are still in the recently-active window.
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProcessSet() }
        })

        // Wake from sleep: coreaudiod and HAL objects may have been recreated
        // and we may have missed transitions — fully reconcile.
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildHALConnections() }
        })
    }

    /// Full reconciliation after wake or a Core Audio reset. Apple documents
    /// that clients must re-establish all cached state and listeners after the
    /// service-restarted signal.
    private func rebuildHALConnections() {
        guard started else { return }

        processListeners.values.forEach { $0.remove() }
        processListeners.removeAll()
        processListListener?.remove()
        processListListener = nil
        serviceRestartListener?.remove()
        serviceRestartListener = nil
        tracked.removeAll()

        establishSystemListeners()
        refreshProcessSet()
    }

    // MARK: - Publishing & aging

    /// Derive the published lists purely from the per-object cache.
    private func recomputePublished() {
        let now = Date()

        // Which identities currently have at least one outputting process?
        var playingIdentities = Set<String>()
        for t in tracked.values where t.isOutputting {
            playingIdentities.insert(t.identity)
            lastActiveByIdentity[t.identity] = now
        }

        var live: [AudioApp] = []
        var recent: [AudioApp] = []

        for (identity, var meta) in appMeta {
            if hideSystemApps && meta.isSystemOrOther { continue }
            meta.lastActive = lastActiveByIdentity[identity] ?? .distantPast

            if playingIdentities.contains(identity) {
                meta.isPlaying = true
                live.append(meta)
            } else if showRecentlyActive,
                      now.timeIntervalSince(meta.lastActive) <= recentlyActiveWindow {
                meta.isPlaying = false
                recent.append(meta)
            }
        }

        // Forget metadata for apps that are neither playing nor recent, so the
        // maps don't grow unbounded.
        let keepGrace = max(recentlyActiveWindow, 1) + 5
        appMeta = appMeta.filter { identity, _ in
            playingIdentities.contains(identity)
                || now.timeIntervalSince(lastActiveByIdentity[identity] ?? .distantPast) <= keepGrace
        }
        lastActiveByIdentity = lastActiveByIdentity.filter { identity, date in
            playingIdentities.contains(identity) || now.timeIntervalSince(date) <= keepGrace
        }

        playing = live.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        recentlyActive = recent.sorted { $0.lastActive > $1.lastActive }

        manageAgeTimer()
    }

    /// Run the 1 Hz aging timer only while there's something to age out.
    private func manageAgeTimer() {
        let needsTimer = !recentlyActive.isEmpty
        if needsTimer, ageTimer == nil {
            ageTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.recomputePublished() }
            }
        } else if !needsTimer, ageTimer != nil {
            ageTimer?.invalidate()
            ageTimer = nil
        }
    }

    // MARK: - Diagnostics support

    /// Snapshot used by the diagnostic report (no audio content, names only).
    func diagnosticSnapshot() -> (playing: [String], recent: [String], processCount: Int, error: String?) {
        (playing.map(\.name), recentlyActive.map(\.name), lastProcessObjectCount, lastError)
    }

#if DEBUG
    /// Seed sample data for SwiftUI previews / offline rendering. Not used at runtime.
    func previewSeed(playing: [AudioApp], recent: [AudioApp]) {
        self.playing = playing
        self.recentlyActive = recent
    }
#endif
}
