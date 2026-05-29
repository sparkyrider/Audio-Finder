//
//  CoreAudioProperties.swift
//  Audio Finder
//
//  Thin, type-safe helpers over the Core Audio HAL property API.
//  Everything here is read-only: we never create a tap, never capture
//  samples, and therefore never trigger any TCC / microphone permission.
//

import CoreAudio
import Foundation

/// Small conveniences for reading HAL object properties without the usual
/// boilerplate of size queries and unsafe pointers.
enum CAProperty {

    /// Build a global-scope, main-element property address for a selector.
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Read a fixed-size scalar property (UInt32, pid_t, AudioObjectID, …).
    static func scalar<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        default fallback: T
    ) -> T {
        var addr = address(selector)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return OSStatus(paramErr) }
            return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, baseAddress)
        }
        return status == noErr ? value : fallback
    }

    /// Read a CFString property (e.g. a process's bundle id).
    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw)
            }
        }
        guard status == noErr, let result = cf else { return nil }
        return result as String
    }

    /// Read a variable-length array of AudioObjectIDs (process list, device list…).
    static func objectIDs(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var addr = address(selector)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &dataSize, &ids)
        return status == noErr ? ids : []
    }

    /// Register a property listener block. Returns a token used to remove it.
    /// The block is invoked on the supplied dispatch queue.
    static func addListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) -> ListenerToken? {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        guard status == noErr else { return nil }
        return ListenerToken(object: object, address: addr, queue: queue, block: block)
    }
}

/// Owns a HAL property listener registration and removes it on demand.
final class ListenerToken {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var removed = false

    init(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }

    func remove() {
        guard !removed else { return }
        removed = true
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { remove() }
}
