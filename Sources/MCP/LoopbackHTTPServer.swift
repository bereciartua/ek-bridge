import Darwin
import Foundation
import Network

/// One accepted connection. Requests on it are answered strictly in order.
///
/// Reading pauses while `maxQueued` requests wait, so a client that pipelines
/// without reading replies can't grow memory. Each phase has a fixed deadline
/// that later bytes don't extend: the head within 10 s of its first byte,
/// the body within 10 s of the head, and 30 s idle between requests.
final class HTTPConnection: @unchecked Sendable {
    fileprivate let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = HTTPParser()
    private var handler: LoopbackHTTPServer.Handler?
    private var pending = [HTTPRequest]()
    /// A parse error to answer once earlier requests have their replies.
    private var failure: Int?
    private var busy = false
    private var receiving = false
    private var closed = false
    private var closeHandlers = [UUID: () -> Void]()
    private var timer: DispatchSourceTimer?
    private var phase = Phase.idle
    fileprivate var onClose: (() -> Void)?

    private enum Phase { case idle, head, body, busy }

    static let headerTimeout: TimeInterval = 10
    static let bodyTimeout: TimeInterval = 10
    static let idleTimeout: TimeInterval = 30
    static let maxQueued = 4

    fileprivate init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Runs `action` on the connection's queue when it closes (at once if it
    /// already has). A closed connection is how a client cancels a request.
    /// Call the returned closure once the action is no longer needed.
    @discardableResult
    func whenClosed(_ action: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        queue.async {
            if self.closed { action() } else { self.closeHandlers[id] = action }
        }
        return { [weak self] in self?.queue.async { self?.closeHandlers[id] = nil } }
    }

    fileprivate func start(handler: @escaping LoopbackHTTPServer.Handler) {
        self.handler = handler
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        updatePhase()
        receive()
    }

    private func receive() {
        guard !closed, !receiving, failure == nil, pending.count < Self.maxQueued else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            self.receiving = false
            if let data, !data.isEmpty { self.parse(data) }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    /// Feeds bytes to the parser and queues complete requests, stopping when
    /// the queue is full; the rest stays buffered in the parser until then.
    private func parse(_ data: Data) {
        var input = data
        while !closed && failure == nil && pending.count < Self.maxQueued {
            let result = parser.feed(input)
            input = Data()
            switch result {
            case .needMore:
                updatePhase()
                return
            case .expectContinue:
                // Only for the request that's next in line, so the interim
                // reply can't land between another request's bytes.
                if !busy && pending.isEmpty {
                    connection.send(content: HTTPResponse.continueBytes, completion: .contentProcessed { _ in })
                }
            case .request(let request):
                pending.append(request)
                next()
            case .error(let status):
                failure = status
                next()
                return
            }
        }
    }

    private func next() {
        guard !busy, !closed else { return }
        guard !pending.isEmpty else {
            if let failure {
                write(HTTPResponse(status: failure), close: true)
            } else {
                updatePhase()
            }
            return
        }
        busy = true
        setPhase(.busy)
        let request = pending.removeFirst()
        handler?(request, self) { [weak self] response, close in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.busy = false
                let closing = close || request.wantsClose
                self.write(response, close: closing)
                guard !closing else { return }
                // Requests already buffered first, then more reading.
                self.parse(Data())
                self.next()
                self.receive()
            }
        }
    }

    private func write(_ response: HTTPResponse, close: Bool) {
        connection.send(content: response.serialized(close: close),
                        completion: .contentProcessed { [weak self] _ in
            if close { self?.queue.async { self?.close() } }
        })
    }

    private func updatePhase() {
        guard !busy else { return }
        if parser.isReadingBody { setPhase(.body) }
        else if parser.hasBufferedBytes { setPhase(.head) }
        else { setPhase(.idle) }
    }

    /// Starts a phase's deadline only when the phase changes.
    private func setPhase(_ next: Phase) {
        guard next != phase || timer == nil else { return }
        phase = next
        timer?.cancel()
        timer = nil
        let limit: TimeInterval
        switch next {
        case .busy: return
        case .idle: limit = Self.idleTimeout
        case .head: limit = Self.headerTimeout
        case .body: limit = Self.bodyTimeout
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + limit)
        source.setEventHandler { [weak self] in
            guard let self, !self.busy, !self.closed else { return }
            if self.phase == .idle {
                self.close()
            } else {
                self.write(HTTPResponse(status: 408), close: true)
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
        let handlers = closeHandlers.values
        closeHandlers.removeAll()
        handlers.forEach { $0() }
        handler = nil
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
