import Darwin
import Foundation
import Network

/// One accepted connection. Requests on it are answered strictly in order.
final class HTTPConnection: @unchecked Sendable {
    fileprivate let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = HTTPParser()
    private var pending = [HTTPRequest]()
    private var busy = false
    private var closed = false
    private var closeHandlers = [() -> Void]()
    private var timer: DispatchSourceTimer?
    fileprivate var onClose: (() -> Void)?

    static let headerTimeout: TimeInterval = 10
    static let bodyTimeout: TimeInterval = 10
    static let idleTimeout: TimeInterval = 30

    fileprivate init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Runs `action` on the connection's queue when it closes (at once if it
    /// already has). A closed connection is how a client cancels a request.
    func whenClosed(_ action: @escaping () -> Void) {
        queue.async {
            if self.closed { action() } else { self.closeHandlers.append(action) }
        }
    }

    fileprivate func start(handler: @escaping LoopbackHTTPServer.Handler) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        armTimer()
        receive(handler: handler)
    }

    private func receive(handler: @escaping LoopbackHTTPServer.Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.consume(data, handler: handler) }
            if isComplete || error != nil {
                self.close()
            } else if !self.closed {
                self.receive(handler: handler)
            }
        }
    }

    private func consume(_ data: Data, handler: @escaping LoopbackHTTPServer.Handler) {
        var input = data
        while !closed {
            let result = parser.feed(input)
            input = Data()
            switch result {
            case .needMore:
                armTimer()
                return
            case .expectContinue:
                // Bodies are capped at 64 KiB, so there's little to save by
                // judging the head first; let the client send it.
                connection.send(content: HTTPResponse.continueBytes, completion: .contentProcessed { _ in })
            case .request(let request):
                pending.append(request)
                next(handler: handler)
            case .error(let status):
                // Anything still queued is answered first, then the error.
                pending.removeAll()
                write(HTTPResponse(status: status), close: true)
                return
            }
        }
    }

    private func next(handler: @escaping LoopbackHTTPServer.Handler) {
        guard !busy, !closed, !pending.isEmpty else { armTimer(); return }
        busy = true
        timer?.cancel()
        let request = pending.removeFirst()
        handler(request, self) { [weak self] response, close in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.busy = false
                let closing = close || request.wantsClose
                self.write(response, close: closing)
                if !closing { self.next(handler: handler) }
            }
        }
    }

    private func write(_ response: HTTPResponse, close: Bool) {
        connection.send(content: response.serialized(close: close),
                        completion: .contentProcessed { [weak self] _ in
            if close { self?.queue.async { self?.close() } }
        })
    }

    /// One timer, re-armed for whichever limit applies: headers arriving,
    /// the body arriving, or an idle keep-alive connection.
    private func armTimer() {
        timer?.cancel()
        guard !busy, !closed else { return }
        let limit: TimeInterval
        if parser.isReadingBody { limit = Self.bodyTimeout }
        else if parser.hasBufferedBytes { limit = Self.headerTimeout }
        else { limit = Self.idleTimeout }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + limit)
        source.setEventHandler { [weak self] in
            guard let self, !self.busy, !self.closed else { return }
            if self.parser.hasBufferedBytes {
                self.write(HTTPResponse(status: 408), close: true)
            } else {
                self.close()
            }
        }
        source.resume()
        timer = source
    }

    fileprivate func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        connection.cancel()
        let handlers = closeHandlers
        closeHandlers.removeAll()
        handlers.forEach { $0() }
        onClose?()
        onClose = nil
    }
}

/// A minimal HTTP/1.1 server bound to 127.0.0.1 only. It never binds another
/// address: there's no setting for it, and a test checks the parameters.
final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = (HTTPRequest, HTTPConnection,
                         @escaping (HTTPResponse, _ close: Bool) -> Void) -> Void

    enum State: Equatable {
        case stopped
        case starting
        case ready(port: Int)
        case failed(Failure)
    }

    enum Failure: Equatable {
        case portInUse(Int)
        case other(String)
    }

    static let host = "127.0.0.1"
    static let maxConnections = 32

    let queue = DispatchQueue(label: "mcp.http")
    private let requestedPort: Int
    private let handler: Handler
    private var listener: NWListener?
    private var connections = [ObjectIdentifier: HTTPConnection]()
    private var stateChanged: ((State) -> Void)?

    init(port: Int, handler: @escaping Handler) {
        requestedPort = port
        self.handler = handler
    }

    /// Loopback only, on purpose: `requiredLocalEndpoint` pins the address and
    /// `acceptLocalOnly` is a second fence.
    static func parameters(port: Int) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        return parameters
    }

    /// `stateChanged` is called on the main queue.
    func start(stateChanged: @escaping (State) -> Void) {
        queue.async { [self] in
            self.stateChanged = stateChanged
            report(.starting)
            let listener: NWListener
            do {
                listener = try NWListener(using: Self.parameters(port: requestedPort))
            } catch {
                report(.failed(Self.failure(error, port: requestedPort)))
                return
            }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.report(.ready(port: Int(listener.port?.rawValue ?? UInt16(self.requestedPort))))
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    self.closeAll()
                    self.report(.failed(Self.failure(error, port: self.requestedPort)))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Closes the listener and every connection. Safe to call more than once.
    func stop() {
        queue.sync {
            stateChanged = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            closeAll()
        }
    }

    private func accept(_ raw: NWConnection) {
        guard connections.count < Self.maxConnections else {
            raw.cancel()
            return
        }
        let connection = HTTPConnection(raw, queue: queue)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onClose = { [weak self] in self?.connections[key] = nil }
        connection.start(handler: handler)
    }

    private func closeAll() {
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll()
    }

    private func report(_ state: State) {
        let callback = stateChanged
        DispatchQueue.main.async { callback?(state) }
    }

    private static func failure(_ error: Error, port: Int) -> Failure {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE { return .portInUse(port) }
        return .other((error as? NWError).map { "\($0)" } ?? error.localizedDescription)
    }
}

/// Whether 127.0.0.1:port can be bound now, for the port sheet. Uses the
/// same address reuse as the listener, so a port in TIME_WAIT counts as free.
enum PortProbe {
    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
