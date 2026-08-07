//
//  BrowserTabs.swift
//  Audio Finder
//
//  Optional Chrome/Brave tab enrichment. The Mac app does not inspect browser
//  state directly; a browser extension sends the currently audible tab
//  titles over a loopback-only HTTP bridge.
//

import Combine
import CryptoKit
import Darwin
import Foundation

private let supportedBrowserBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.brave.Browser"
]

struct BrowserAudioTab: Identifiable, Equatable {
    let id: String
    let browserBundleID: String
    let browserName: String
    let title: String
    let windowID: Int
    let tabID: Int
    let isMuted: Bool
    let isIncognito: Bool
    let extensionOrigin: String?
    let receivedAt: Date

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled tab" : trimmed
    }
}

@MainActor
final class BrowserTabMonitor: ObservableObject {
    enum ServerState: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    @Published private(set) var tabsByBundleID: [String: [BrowserAudioTab]] = [:]
    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var trustedExtensionOrigins: [String] = BrowserExtensionTrust.trustedOrigins
    @Published private(set) var lastConnectorSeenAt: Date?
    @Published private(set) var lastConnectorName: String?

    let port: UInt16 = 17654

    private var server: BrowserTabHTTPServer?
    private let commandHub = BrowserTabCommandHub()
    private var snapshotDates: [String: Date] = [:]
    private let staleInterval: TimeInterval = 75

    func start() {
        guard server == nil else { return }

        let httpServer = BrowserTabHTTPServer(port: port, commandHub: commandHub) { [weak self] update, origin in
            Task { @MainActor in
                self?.apply(update, origin: origin)
            }
        }

        do {
            try httpServer.start()
            server = httpServer
            serverState = .running(port: port)
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        serverState = .stopped
    }

    func refreshNow() {
        pruneStaleSnapshots()
        trustedExtensionOrigins = BrowserExtensionTrust.trustedOrigins
    }

    func tabs(for bundleID: String?) -> [BrowserAudioTab] {
        guard let bundleID else { return [] }
        return tabsByBundleID[bundleID] ?? []
    }

    func tabs(for bundleID: String?, visibleApps: [AudioApp]) -> [BrowserAudioTab] {
        let direct = tabs(for: bundleID)
        guard direct.isEmpty,
              let bundleID,
              supportedBrowserBundleIDs.contains(bundleID) else {
            return direct
        }

        let visibleBrowserIDs = visibleApps.compactMap(\.bundleID).filter {
            supportedBrowserBundleIDs.contains($0)
        }
        guard visibleBrowserIDs.count == 1, visibleBrowserIDs.first == bundleID else {
            return direct
        }

        return tabsByBundleID
            .filter { supportedBrowserBundleIDs.contains($0.key) }
            .flatMap(\.value)
            .sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
    }

    func activate(_ tab: BrowserAudioTab) {
        commandHub.enqueue(.activateTab(tab))
    }

    func resetTrustedExtensions() {
        BrowserExtensionTrust.reset()
        commandHub.removeAll()
        trustedExtensionOrigins = []
        lastConnectorSeenAt = nil
        lastConnectorName = nil
        tabsByBundleID.removeAll()
        snapshotDates.removeAll()
    }

    private func apply(_ update: BrowserTabUpdatePayload, origin: String?) {
        let bundleID = update.browserBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportedBrowserBundleIDs.contains(bundleID) else { return }

        let now = Date()
        snapshotDates[bundleID] = now

        let browserName = update.browserName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = browserName?.isEmpty == false ? browserName! : BrowserTabMonitor.browserName(for: bundleID)
        lastConnectorSeenAt = now
        lastConnectorName = name
        if origin != nil {
            trustedExtensionOrigins = BrowserExtensionTrust.trustedOrigins
        }

        let tabs = update.tabs.map { tab in
            BrowserAudioTab(
                id: "\(bundleID).\(tab.windowID).\(tab.tabID)",
                browserBundleID: bundleID,
                browserName: name,
                title: tab.title,
                windowID: tab.windowID,
                tabID: tab.tabID,
                isMuted: tab.isMuted,
                isIncognito: tab.isIncognito,
                extensionOrigin: origin,
                receivedAt: now
            )
        }
        .sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }

        if tabs.isEmpty {
            tabsByBundleID.removeValue(forKey: bundleID)
        } else {
            tabsByBundleID[bundleID] = tabs
        }

        pruneStaleSnapshots(now: now)
    }

    private func pruneStaleSnapshots(now: Date = Date()) {
        let staleBundleIDs = snapshotDates.compactMap { bundleID, date in
            now.timeIntervalSince(date) > staleInterval ? bundleID : nil
        }
        guard !staleBundleIDs.isEmpty else { return }

        for bundleID in staleBundleIDs {
            tabsByBundleID.removeValue(forKey: bundleID)
            snapshotDates.removeValue(forKey: bundleID)
        }

        if let lastConnectorSeenAt,
           now.timeIntervalSince(lastConnectorSeenAt) > staleInterval {
            self.lastConnectorSeenAt = nil
            lastConnectorName = nil
        }
    }

    private static func browserName(for bundleID: String) -> String {
        switch bundleID {
        case "com.brave.Browser":
            return "Brave"
        default:
            return "Google Chrome"
        }
    }

}

private struct BrowserTabUpdatePayload: Decodable {
    let browserBundleID: String
    let browserName: String?
    let tabs: [BrowserTabPayload]
}

private struct BrowserTabPayload: Decodable {
    let tabID: Int
    let windowID: Int
    let title: String
    let isMuted: Bool
    let isIncognito: Bool
}

private struct BrowserTabCommand: Encodable {
    let id: String
    let type: String
    let browserBundleID: String
    let windowID: Int
    let tabID: Int
    let createdAt: TimeInterval
    let extensionOrigin: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case browserBundleID
        case windowID
        case tabID
        case createdAt
    }

    static func activateTab(_ tab: BrowserAudioTab) -> BrowserTabCommand {
        BrowserTabCommand(
            id: UUID().uuidString,
            type: "activateTab",
            browserBundleID: tab.browserBundleID,
            windowID: tab.windowID,
            tabID: tab.tabID,
            createdAt: Date().timeIntervalSince1970,
            extensionOrigin: tab.extensionOrigin
        )
    }
}

private struct BrowserTabCommandResponse: Encodable {
    let commands: [BrowserTabCommand]
}

private struct BrowserTabCommandKey: Hashable {
    let browserBundleID: String
    let extensionOrigin: String?
}

private final class BrowserTabCommandHub {
    private let condition = NSCondition()
    private let fallbackQueue = BrowserTabCommandQueue()
    private var clientsByKey: [BrowserTabCommandKey: [BrowserTabWebSocketClient]] = [:]

    func enqueue(_ command: BrowserTabCommand) {
        let key = BrowserTabCommandKey(
            browserBundleID: command.browserBundleID,
            extensionOrigin: command.extensionOrigin
        )
        let payload = BrowserTabCommandResponse(commands: [command])
        let body = (try? JSONEncoder().encode(payload)) ?? Data()

        condition.lock()
        let clients = clientsByKey[key] ?? []
        condition.unlock()

        var delivered = false
        var disconnected: [BrowserTabWebSocketClient] = []
        for client in clients {
            if client.sendText(body) {
                delivered = true
            } else {
                disconnected.append(client)
            }
        }

        if !disconnected.isEmpty {
            condition.lock()
            for client in disconnected {
                removeLocked(client, from: key)
            }
            condition.unlock()
        }

        if !delivered {
            fallbackQueue.enqueue(command)
        }
    }

    func takeCommands(
        for browserBundleID: String,
        extensionOrigin: String?,
        waitSeconds: TimeInterval
    ) -> [BrowserTabCommand] {
        fallbackQueue.takeCommands(
            for: browserBundleID,
            extensionOrigin: extensionOrigin,
            waitSeconds: waitSeconds
        )
    }

    func addWebSocketClient(
        _ client: BrowserTabWebSocketClient,
        browserBundleID: String,
        extensionOrigin: String
    ) {
        let key = BrowserTabCommandKey(
            browserBundleID: browserBundleID,
            extensionOrigin: extensionOrigin
        )
        condition.lock()
        clientsByKey[key, default: []].removeAll { $0 === client }
        clientsByKey[key, default: []].append(client)
        condition.unlock()
    }

    func removeWebSocketClient(
        _ client: BrowserTabWebSocketClient,
        browserBundleID: String,
        extensionOrigin: String
    ) {
        let key = BrowserTabCommandKey(
            browserBundleID: browserBundleID,
            extensionOrigin: extensionOrigin
        )
        condition.lock()
        removeLocked(client, from: key)
        condition.unlock()
    }

    func removeAll() {
        condition.lock()
        let clients = clientsByKey.values.flatMap { $0 }
        clientsByKey.removeAll()
        condition.unlock()

        for client in clients {
            client.close()
        }
        fallbackQueue.removeAll()
    }

    private func removeLocked(_ client: BrowserTabWebSocketClient, from key: BrowserTabCommandKey) {
        clientsByKey[key]?.removeAll { $0 === client }
        if clientsByKey[key]?.isEmpty == true {
            clientsByKey.removeValue(forKey: key)
        }
    }
}

private final class BrowserTabCommandQueue {
    private let condition = NSCondition()
    private let staleInterval: TimeInterval = 30
    private var commandsByKey: [BrowserTabCommandKey: [BrowserTabCommand]] = [:]

    func enqueue(_ command: BrowserTabCommand) {
        condition.lock()
        pruneLocked(now: Date().timeIntervalSince1970)
        let key = BrowserTabCommandKey(
            browserBundleID: command.browserBundleID,
            extensionOrigin: command.extensionOrigin
        )
        commandsByKey[key, default: []].append(command)
        condition.broadcast()
        condition.unlock()
    }

    func takeCommands(
        for browserBundleID: String,
        extensionOrigin: String?,
        waitSeconds: TimeInterval
    ) -> [BrowserTabCommand] {
        let key = BrowserTabCommandKey(
            browserBundleID: browserBundleID,
            extensionOrigin: extensionOrigin
        )
        let deadline = Date().addingTimeInterval(max(0, waitSeconds))
        condition.lock()
        defer { condition.unlock() }

        pruneLocked(now: Date().timeIntervalSince1970)
        while commandsByKey[key]?.isEmpty ?? true {
            guard waitSeconds > 0, Date() < deadline else { return [] }
            condition.wait(until: deadline)
            pruneLocked(now: Date().timeIntervalSince1970)
        }

        return commandsByKey.removeValue(forKey: key) ?? []
    }

    func removeAll() {
        condition.lock()
        commandsByKey.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    private func pruneLocked(now: TimeInterval) {
        for (key, commands) in commandsByKey {
            let current = commands.filter { now - $0.createdAt <= staleInterval }
            if current.isEmpty {
                commandsByKey.removeValue(forKey: key)
            } else {
                commandsByKey[key] = current
            }
        }
    }
}

private final class BrowserTabWebSocketClient {
    private let socketFD: Int32
    private let sendLock = NSLock()

    init(socketFD: Int32) {
        self.socketFD = socketFD
    }

    func sendText(_ payload: Data) -> Bool {
        sendFrame(opcode: 0x1, payload: payload)
    }

    func sendPong(_ payload: Data) -> Bool {
        sendFrame(opcode: 0xA, payload: payload)
    }

    func close() {
        _ = sendFrame(opcode: 0x8, payload: Data())
        _ = Darwin.shutdown(socketFD, SHUT_RDWR)
    }

    private func sendFrame(opcode: UInt8, payload: Data) -> Bool {
        var frame = Data([0x80 | opcode])
        let payloadLength = payload.count

        if payloadLength <= 125 {
            frame.append(UInt8(payloadLength))
        } else if payloadLength <= Int(UInt16.max) {
            frame.append(126)
            var length = UInt16(payloadLength).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        } else {
            frame.append(127)
            var length = UInt64(payloadLength).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }

        frame.append(payload)

        sendLock.lock()
        defer { sendLock.unlock() }

        return frame.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return true }
            var bytesSent = 0
            while bytesSent < pointer.count {
                let written = Darwin.send(
                    socketFD,
                    base.advanced(by: bytesSent),
                    pointer.count - bytesSent,
                    0
                )
                if written <= 0 {
                    return false
                }
                bytesSent += written
            }
            return true
        }
    }
}

/// Listener lifecycle calls come from the main actor, accepts run on the accept
/// queue, and individual clients run on the client queue with locked shared
/// queues. Cancellation can overlap only an in-flight syscall on the integer
/// descriptor. The explicit conformance documents that boundary for Swift 6.
private final class BrowserTabHTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let commandHub: BrowserTabCommandHub
    private let onUpdate: (BrowserTabUpdatePayload, String?) -> Void
    private let acceptQueue = DispatchQueue(label: "app.audiofinder.mac.browser-tabs.accept", qos: .utility)
    private let clientQueue = DispatchQueue(label: "app.audiofinder.mac.browser-tabs.clients", qos: .utility, attributes: .concurrent)
    private let maxRequestBytes = 256 * 1024

    private var socketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        port: UInt16,
        commandHub: BrowserTabCommandHub,
        onUpdate: @escaping (BrowserTabUpdatePayload, String?) -> Void
    ) {
        self.port = port
        self.commandHub = commandHub
        self.onUpdate = onUpdate
    }

    func start() throws {
        guard socketFD == -1 else { return }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserTabServerError.socket(errno) }

        do {
            try configureSocket(fd)
            try bindSocket(fd)

            guard Darwin.listen(fd, SOMAXCONN) == 0 else {
                throw BrowserTabServerError.listen(errno)
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
            source.setEventHandler { [weak self] in
                self?.acceptAvailableConnections()
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }

            socketFD = fd
            acceptSource = source
            source.resume()
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        socketFD = -1
    }

    deinit {
        stop()
    }

    private func configureSocket(_ fd: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw BrowserTabServerError.configure(errno)
        }

        #if SO_NOSIGPIPE
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw BrowserTabServerError.configure(errno)
        }
    }

    private func bindSocket(_ fd: Int32) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else { throw BrowserTabServerError.bind(port: port, errno: errno) }
    }

    private func acceptAvailableConnections() {
        while true {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(socketFD, $0, &length)
                }
            }

            if client < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }

            clientQueue.async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { Darwin.close(client) }

        var yes: Int32 = 1
        #if SO_NOSIGPIPE
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let flags = fcntl(client, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let data = readRequest(from: client),
              let request = HTTPRequest(data: data) else {
            sendResponse(.badRequest, to: client)
            return
        }

        let corsOrigin = BrowserExtensionTrust.trustableOrigin(from: request.headers["origin"])

        switch (request.method, request.path) {
        case ("OPTIONS", _):
            guard let corsOrigin else {
                sendResponse(.forbidden, to: client)
                return
            }
            sendResponse(.noContent, corsOrigin: corsOrigin, to: client)
        case ("GET", "/v1/status"):
            let body = #"{"ok":true,"app":"Audio Finder"}"#.data(using: .utf8) ?? Data()
            sendResponse(.ok, body: body, contentType: "application/json", corsOrigin: corsOrigin, to: client)
        case ("GET", "/v1/browser-command-stream"):
            guard let corsOrigin else {
                sendResponse(.forbidden, to: client)
                return
            }

            let browserBundleID = request.queryItems["browserBundleID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard supportedBrowserBundleIDs.contains(browserBundleID),
                  request.isWebSocketUpgrade else {
                sendResponse(.badRequest, corsOrigin: corsOrigin, to: client)
                return
            }

            handleWebSocket(
                client: client,
                request: request,
                browserBundleID: browserBundleID,
                extensionOrigin: corsOrigin
            )
        case ("GET", "/v1/browser-commands"):
            guard let corsOrigin else {
                sendResponse(.forbidden, to: client)
                return
            }

            let browserBundleID = request.queryItems["browserBundleID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard supportedBrowserBundleIDs.contains(browserBundleID) else {
                sendResponse(.badRequest, corsOrigin: corsOrigin, to: client)
                return
            }

            let requestedWait = TimeInterval(request.queryItems["wait"].flatMap(Double.init) ?? 0)
            let waitSeconds = min(max(requestedWait, 0), 25)
            let commands = commandHub.takeCommands(
                for: browserBundleID,
                extensionOrigin: corsOrigin,
                waitSeconds: waitSeconds
            )
            let body = (try? JSONEncoder().encode(BrowserTabCommandResponse(commands: commands))) ?? Data()
            sendResponse(.ok, body: body, contentType: "application/json", corsOrigin: corsOrigin, to: client)
        case ("POST", "/v1/browser-tabs"):
            guard let corsOrigin else {
                sendResponse(.forbidden, to: client)
                return
            }

            do {
                let payload = try JSONDecoder().decode(BrowserTabUpdatePayload.self, from: request.body)
                onUpdate(payload, corsOrigin)
                sendResponse(.noContent, corsOrigin: corsOrigin, to: client)
            } catch {
                let message = #"{"error":"Invalid browser tab payload"}"#
                sendResponse(
                    .badRequest,
                    body: Data(message.utf8),
                    contentType: "application/json",
                    corsOrigin: corsOrigin,
                    to: client
                )
            }
        default:
            sendResponse(.notFound, to: client)
        }
    }

    private struct WebSocketFrame {
        let opcode: UInt8
        let payload: Data
    }

    private func handleWebSocket(
        client: Int32,
        request: HTTPRequest,
        browserBundleID: String,
        extensionOrigin: String
    ) {
        guard sendWebSocketUpgradeResponse(for: request, to: client) else { return }

        var timeout = timeval(tv_sec: 45, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let webSocketClient = BrowserTabWebSocketClient(socketFD: client)
        commandHub.addWebSocketClient(
            webSocketClient,
            browserBundleID: browserBundleID,
            extensionOrigin: extensionOrigin
        )
        defer {
            commandHub.removeWebSocketClient(
                webSocketClient,
                browserBundleID: browserBundleID,
                extensionOrigin: extensionOrigin
            )
        }

        while let frame = readWebSocketFrame(from: client) {
            switch frame.opcode {
            case 0x8:
                webSocketClient.close()
                return
            case 0x9:
                _ = webSocketClient.sendPong(frame.payload)
            default:
                continue
            }
        }
    }

    private func sendWebSocketUpgradeResponse(for request: HTTPRequest, to client: Int32) -> Bool {
        guard let key = request.headers["sec-websocket-key"],
              !key.isEmpty else {
            sendResponse(.badRequest, to: client)
            return false
        }

        let accept = webSocketAcceptValue(for: key)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "\r\n"
        ].joined(separator: "\r\n")
        return sendAll(Data(response.utf8), to: client)
    }

    private func webSocketAcceptValue(for key: String) -> String {
        let source = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(source.utf8))
        return Data(digest).base64EncodedString()
    }

    private func readWebSocketFrame(from client: Int32) -> WebSocketFrame? {
        guard let header = readExact(2, from: client) else { return nil }
        let headerBytes = [UInt8](header)
        let opcode = headerBytes[0] & 0x0F
        let isMasked = (headerBytes[1] & 0x80) != 0
        var payloadLength = UInt64(headerBytes[1] & 0x7F)

        if payloadLength == 126 {
            guard let lengthBytes = readExact(2, from: client) else { return nil }
            payloadLength = [UInt8](lengthBytes).reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
        } else if payloadLength == 127 {
            guard let lengthBytes = readExact(8, from: client) else { return nil }
            payloadLength = [UInt8](lengthBytes).reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
        }

        guard payloadLength <= 64 * 1024 else { return nil }

        let maskBytes: [UInt8]
        if isMasked {
            guard let mask = readExact(4, from: client) else { return nil }
            maskBytes = [UInt8](mask)
        } else {
            maskBytes = []
        }

        let payloadData = readExact(Int(payloadLength), from: client) ?? Data()
        var payloadBytes = [UInt8](payloadData)
        if isMasked {
            for index in payloadBytes.indices {
                payloadBytes[index] ^= maskBytes[index % 4]
            }
        }

        return WebSocketFrame(opcode: opcode, payload: Data(payloadBytes))
    }

    private func readExact(_ count: Int, from client: Int32) -> Data? {
        guard count > 0 else { return Data() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, count))
        while data.count < count {
            let remaining = count - data.count
            let requested = min(buffer.count, remaining)
            let received = buffer.withUnsafeMutableBytes {
                Darwin.recv(client, $0.baseAddress, requested, 0)
            }

            if received > 0 {
                data.append(buffer, count: received)
            } else if received < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }

        return data
    }

    private func readRequest(from client: Int32) -> Data? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while request.count < maxRequestBytes {
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(client, $0.baseAddress, capacity, 0)
            }

            if count > 0 {
                request.append(buffer, count: count)
                if let expected = HTTPRequest.expectedLength(for: request), request.count >= expected {
                    return Data(request.prefix(expected))
                }
            } else if count == 0 {
                return request.isEmpty ? nil : request
            } else {
                return request.isEmpty ? nil : request
            }
        }

        return nil
    }

    private func sendResponse(
        _ status: HTTPStatus,
        body: Data = Data(),
        contentType: String? = nil,
        corsOrigin: String? = nil,
        to client: Int32
    ) {
        var headers = [
            "HTTP/1.1 \(status.rawValue)",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]

        if let contentType {
            headers.append("Content-Type: \(contentType)")
        }

        if let corsOrigin {
            headers.append("Access-Control-Allow-Origin: \(corsOrigin)")
            headers.append("Access-Control-Allow-Methods: GET, POST, OPTIONS")
            headers.append("Access-Control-Allow-Headers: Content-Type")
            headers.append("Access-Control-Allow-Private-Network: true")
            headers.append("Access-Control-Max-Age: 86400")
            headers.append("Vary: Origin")
        }

        let head = headers.joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        _ = sendAll(response, to: client)
    }

    private func sendAll(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return true }
            var bytesSent = 0
            while bytesSent < pointer.count {
                let written = Darwin.send(
                    client,
                    base.advanced(by: bytesSent),
                    pointer.count - bytesSent,
                    0
                )
                if written <= 0 {
                    return false
                }
                bytesSent += written
            }
            return true
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data

    var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased() == "websocket" &&
        headers["connection"]?.lowercased().contains("upgrade") == true
    }

    init?(data: Data) {
        guard let headerRange = data.range(of: Data([13, 10, 13, 10])) else { return nil }

        let headerData = data[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        method = requestParts[0].uppercased()
        let requestTarget = requestParts[1]
        let components = URLComponents(string: "http://127.0.0.1\(requestTarget)")
        path = components?.path ?? String(requestTarget.split(separator: "?", maxSplits: 1).first ?? "")
        queryItems = (components?.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            guard let value = item.value else { return }
            result[item.name] = value
        }

        var parsedHeaders: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders

        let bodyStart = headerRange.upperBound
        let length = Int(parsedHeaders["content-length"] ?? "") ?? 0
        if parsedHeaders["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = HTTPRequest.decodeChunkedBody(Data(data[bodyStart...]))
        } else if length > 0, data.count >= bodyStart + length {
            body = Data(data[bodyStart..<(bodyStart + length)])
        } else {
            body = Data()
        }
    }

    static func expectedLength(for data: Data) -> Int? {
        guard let headerRange = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        let headerText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
        if headerText.lowercased().contains("transfer-encoding: chunked") {
            let terminator = Data([48, 13, 10, 13, 10]) // "0\r\n\r\n"
            return data.range(of: terminator, options: [], in: headerRange.upperBound..<data.endIndex)?.upperBound
        }

        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                guard let separator = line.firstIndex(of: ":") else { return nil }
                return Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines))
            } ?? 0
        return headerRange.upperBound + contentLength
    }

    private static func decodeChunkedBody(_ data: Data) -> Data {
        var decoded = Data()
        var index = data.startIndex
        let crlf = Data([13, 10])

        while index < data.endIndex {
            guard let lineRange = data.range(of: crlf, options: [], in: index..<data.endIndex) else { break }
            let sizeText = String(decoding: data[index..<lineRange.lowerBound], as: UTF8.self)
            let sizeToken = sizeText.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeText
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { break }

            index = lineRange.upperBound
            guard size > 0 else { break }

            let chunkEnd = index + size
            guard chunkEnd <= data.endIndex else { break }
            decoded.append(data[index..<chunkEnd])

            let nextIndex = chunkEnd + crlf.count
            guard nextIndex <= data.endIndex else { break }
            index = nextIndex
        }

        return decoded
    }
}

enum BrowserExtensionTrust {
    private static let defaultsKey = "BrowserTabTrustedExtensionOrigins"
    private static let maxTrustedOrigins = 4

    /// Stable ID assigned to the production Chrome Web Store item. Debug builds
    /// can additionally remember unpacked extensions for local development.
    static let productionExtensionOrigin =
        "chrome-extension://ehngclenbdcacgiajflfjfffhlilpcko"

    private static let knownExtensionOrigins: Set<String> = [
        productionExtensionOrigin
    ]

    static var trustedOrigins: [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    static func trustableOrigin(from origin: String?) -> String? {
        guard let normalized = normalizedExtensionOrigin(origin) else { return nil }
        var trusted = trustedOrigins

        if knownExtensionOrigins.contains(normalized) {
            remember(normalized, in: &trusted)
            return normalized
        }

        #if DEBUG
        if trusted.contains(normalized) {
            return normalized
        }

        guard trusted.count < maxTrustedOrigins else { return nil }
        remember(normalized, in: &trusted)
        return normalized
        #else
        return nil
        #endif
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func remember(_ origin: String, in trusted: inout [String]) {
        guard !trusted.contains(origin) else { return }
        trusted.append(origin)
        UserDefaults.standard.set(trusted, forKey: defaultsKey)
    }

    private static func normalizedExtensionOrigin(_ origin: String?) -> String? {
        guard let origin,
              let components = URLComponents(string: origin),
              components.scheme == "chrome-extension",
              let host = components.host,
              host.count == 32,
              host.allSatisfy({ ("a"..."p").contains(String($0)) }) else {
            return nil
        }
        return "chrome-extension://\(host)"
    }
}

private enum HTTPStatus: String {
    case ok = "200 OK"
    case noContent = "204 No Content"
    case badRequest = "400 Bad Request"
    case forbidden = "403 Forbidden"
    case notFound = "404 Not Found"
}

private enum BrowserTabServerError: LocalizedError {
    case socket(Int32)
    case configure(Int32)
    case bind(port: UInt16, errno: Int32)
    case listen(Int32)

    var errorDescription: String? {
        switch self {
        case .socket(let code):
            return "Could not create the browser tab bridge socket (\(code))."
        case .configure(let code):
            return "Could not configure the browser tab bridge socket (\(code))."
        case .bind(let port, let code):
            return "Could not start the browser tab bridge on 127.0.0.1:\(port) (\(code))."
        case .listen(let code):
            return "Could not listen for browser tab bridge connections (\(code))."
        }
    }
}
