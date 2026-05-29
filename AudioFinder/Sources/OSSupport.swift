//
//  OSSupport.swift
//  Audio Finder
//
//  Runtime OS-version gating. The Core Audio process-object selectors carry no
//  per-symbol availability annotation, so we enforce the floor ourselves.
//

import Foundation

enum OSSupport {
    /// V1 ships with a macOS 26 deployment target (the binary will not launch
    /// below it), so this matches the LSMinimumSystemVersion floor. The runtime
    /// check is a belt-and-suspenders guard; the underlying Core Audio
    /// process-object API itself works from macOS 14, so lowering the target
    /// later only requires changing this value and the deployment target.
    static let minimumVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    /// Human-readable floor for UI copy, kept in sync with `minimumVersion`.
    static let minimumVersionLabel = "macOS 26"

    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumVersion)
    }

    static var osVersionString: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
