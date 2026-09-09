import Foundation
import Network

/// Serves the prompter to a phone or tablet on the same network.
///
/// A second device is the strongest possible answer to "invisible during a screen
/// share" — it is not part of the screen at all, so no window flag is involved.
/// The Mac keeps doing every hard part (system-audio capture, on-device
/// transcription, alignment, question matching) and the phone is a live view of
/// the result.
///
/// Deliberately HTTP + Server-Sent Events rather than WebSocket: SSE needs no
/// handshake and no frame codec, so it is a few lines of plain text on this side
/// and one `EventSource` on the other. The channel only ever pushes Mac to phone,
/// which is exactly SSE's shape.
@MainActor
final class PrompterServer {

    private var listener: NWListener?
    private var eventClients: [ObjectIdentifier: NWConnection] = [:]
    private var keepAlive: Timer?

    private(set) var port: UInt16 = 0
    private(set) var isRunning = false

    /// Guards the script against anyone else on the network.
    ///
    /// Without it, every device on a café or office wifi could fetch your notes
    /// by guessing a port. The token is regenerated on each launch and is carried
    /// in the QR code, so it never has to be typed.
    let token: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// Supplies the current script whenever a device asks for it.
    var scriptProvider: (() -> ParsedScript)?

    // MARK: - Lifecycle

    func start(preferredPort: UInt16 = 8787) throws {
        stop()

        // Walk a few ports rather than failing outright if one is taken.
        var lastError: Error?
        for candidate in preferredPort..<(preferredPort + 12) {
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(
                    using: parameters,
                    on: NWEndpoint.Port(rawValue: candidate)!
                )
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated { self?.accept(connection) }
                }
                listener.start(queue: .main)
                self.listener = listener
                self.port = candidate
                self.isRunning = true
                startKeepAlive()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    func stop() {
        keepAlive?.invalidate()
        keepAlive = nil
        for connection in eventClients.values { connection.cancel() }
        eventClients.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    deinit { keepAlive?.invalidate() }

    /// SSE connections are dropped by intermediaries when idle; a comment line
    /// costs nothing and keeps them open through a long call.
    private func startKeepAlive() {
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcastRaw(": keepalive\n\n") }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
    }

    // MARK: - URL

    var url: URL? {
        guard isRunning, let host = Self.localAddress() else { return nil }
        return URL(string: "http://\(host):\(port)/?t=\(token)")
    }

    /// First non-loopback IPv4 address, which on a laptop is the wifi interface.
    static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            let address = String(cString: host)
            let name = String(cString: interface.ifa_name)
            // Prefer wifi; fall back to anything else routable.
            if name.hasPrefix("en") { return address }
            if best == nil { best = address }
        }
        return best
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var accumulated = buffer
                if let data { accumulated.append(data) }

                guard error == nil, !isComplete || !accumulated.isEmpty else {
                    connection.cancel()
                    return
                }

                // Headers end at a blank line; a GET has no body to wait for.
                guard let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                    if accumulated.count < 64 * 1024 {
                        self.receiveRequest(on: connection, buffer: accumulated)
                    } else {
                        connection.cancel()
                    }
                    return
                }

                let header = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
                self.route(header: header, on: connection)
            }
        }
    }

    private func route(header: String, on connection: NWConnection) {
        guard let requestLine = header.split(separator: "\r\n").first,
              let rawPath = requestLine.split(separator: " ").dropFirst().first
        else {
            send(status: "400 Bad Request", body: Data(), on: connection, close: true)
            return
        }

        let components = URLComponents(string: "http://local\(rawPath)")
        let path = components?.path ?? "/"
        let suppliedToken = components?.queryItems?
            .first(where: { $0.name == "t" })?.value

        guard suppliedToken == token else {
            send(
                status: "403 Forbidden",
                body: Data("Open the link from the QR code in the Mac app.".utf8),
                contentType: "text/plain; charset=utf-8",
                on: connection, close: true
            )
            return
        }

        switch path {
        case "/":
            send(
                status: "200 OK",
                body: Data(PrompterPage.html(token: token).utf8),
                contentType: "text/html; charset=utf-8",
                on: connection, close: true
            )

        case "/script":
            let payload = scriptJSON()
            send(
                status: "200 OK", body: payload,
                contentType: "application/json; charset=utf-8",
                on: connection, close: true
            )

        case "/events":
            startEventStream(on: connection)

        default:
            send(status: "404 Not Found", body: Data(), on: connection, close: true)
        }
    }

    // MARK: - Responses

    private func send(
        status: String,
        body: Data,
        contentType: String = "text/plain; charset=utf-8",
        on connection: NWConnection,
        close: Bool
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    private func startEventStream(on connection: NWConnection) {
        let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Cache-Control: no-store\r
            Connection: keep-alive\r
            \r

            """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        eventClients[ObjectIdentifier(connection)] = connection

        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed:
                    self?.eventClients.removeValue(forKey: ObjectIdentifier(connection))
                default:
                    break
                }
            }
        }
    }

    // MARK: - Broadcasting

    /// Pushes the current reading position to every connected device.
    func broadcast(word: Int, section: Int?, isConfident: Bool) {
        let payload: [String: Any] = [
            "word": word,
            "section": section as Any,
            "confident": isConfident,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        broadcastRaw("event: position\ndata: \(json)\n\n")
    }

    /// Tells connected devices the script changed and they should refetch.
    func broadcastScriptChanged() {
        broadcastRaw("event: reload\ndata: {}\n\n")
    }

    private func broadcastRaw(_ text: String) {
        guard !eventClients.isEmpty else { return }
        let data = Data(text.utf8)
        for connection in eventClients.values {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Script payload

    /// Sends the display text plus word ranges rather than pre-rendered HTML, so
    /// the phone can wrap each word in its own element and address word indices
    /// exactly as the Mac does. NSString ranges are UTF-16, and so are JavaScript
    /// strings, which makes the offsets line up without conversion.
    private func scriptJSON() -> Data {
        let script = scriptProvider?() ?? .empty
        let sections = script.sections.map { section -> [String: Any] in
            [
                "title": section.title,
                "first": section.firstWordIndex,
                "last": section.lastWordIndex,
                "words": section.wordCount,
            ]
        }
        let words = script.words.map { [$0.range.location, $0.range.length] }

        let payload: [String: Any] = [
            "text": script.displayText,
            "words": words,
            "sections": sections,
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }
}
