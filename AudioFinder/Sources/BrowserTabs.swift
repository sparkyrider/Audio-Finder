//
//  BrowserTabs.swift
//  Audio Finder
//
//  Optional Chrome/Brave tab enrichment. The Mac app does not inspect browser
//  state directly; a browser extension sends the currently audible tab
//  titles over a loopback-only HTTP bridge.
//

import Combine
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
    private let commandQueue = BrowserTabCommandQueue()
    private var snapshotDates: [String: Date] = [:]
    private let staleInterval: TimeInterval = 75

    func start() {
        guard server == nil else { return }

        let httpServer = BrowserTabHTTPServer(port: port, commandQueue: commandQueue) { [weak self] update, origin in
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
        commandQueue.enqueue(.activateTab(tab))
    }

    func resetTrustedExtensions() {
        BrowserExtensionTrust.reset()
        commandQueue.removeAll()
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

private final class BrowserTabCommandQueue {
    private struct Key: Hashable {
        let browserBundleID: String
        let extensionOrigin: String?
    }

    private let condition = NSCondition()
    private let staleInterval: TimeInterval = 30
    private var commandsByKey: [Key: [BrowserTabCommand]] = [:]

    func enqueue(_ command: BrowserTabCommand) {
        condition.lock()
        pruneLocked(now: Date().timeIntervalSince1970)
        let key = Key(browserBundleID: command.browserBundleID, extensionOrigin: command.extensionOrigin)
        commandsByKey[key, default: []].append(command)
        condition.broadcast()
        condition.unlock()
    }

    func takeCommands(
        for browserBundleID: String,
        extensionOrigin: String?,
        waitSeconds: TimeInterval
    ) -> [BrowserTabCommand] {
        let key = Key(browserBundleID: browserBundleID, extensionOrigin: extensionOrigin)
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

private final class BrowserTabHTTPServer {
    private let port: UInt16
    private let commandQueue: BrowserTabCommandQueue
    private let onUpdate: (BrowserTabUpdatePayload, String?) -> Void
    private let acceptQueue = DispatchQueue(label: "com.audiofinder.browser-tabs.accept", qos: .utility)
    private let clientQueue = DispatchQueue(label: "com.audiofinder.browser-tabs.clients", qos: .utility, attributes: .concurrent)
    private let maxRequestBytes = 256 * 1024

    private var socketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        port: UInt16,
        commandQueue: BrowserTabCommandQueue,
        onUpdate: @escaping (BrowserTabUpdatePayload, String?) -> Void
    ) {
        self.port = port
        self.commandQueue = commandQueue
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
            let commands = commandQueue.takeCommands(
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
        response.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            _ = Darwin.send(client, base, response.count, 0)
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data

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

private enum BrowserExtensionTrust {
    private static let defaultsKey = "BrowserTabTrustedExtensionOrigins"
    private static let maxTrustedOrigins = 4

    /// Current unpacked-development ID observed in Brave. Add the published
    /// Chrome Web Store ID here before submitting the Mac app for review.
    private static let knownExtensionOrigins: Set<String> = [
        "chrome-extension://hdfaeopcegkiplloaieikdldflangodo"
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
