//
//  OSSupport.swift
//  Audio Finder
//
//  Runtime OS-version gating. The Core Audio process-object selectors carry no
//  per-symbol availability annotation, so we enforce the floor ourselves.
//

import Foundation

enum OSSupport {
    /// The Core Audio process-object API and the activation APIs used by Audio
    /// Finder are available on macOS 14. The 14.2 floor matches the deployment
    /// policy; the full multi-version release matrix remains a release gate.
    static let minimumVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

    /// Human-readable floor for UI copy, kept in sync with `minimumVersion`.
    static let minimumVersionLabel = "macOS 14.2"

    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumVersion)
    }

    static var osVersionString: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
