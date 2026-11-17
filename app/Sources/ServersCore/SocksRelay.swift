// 앱 안 SOCKS5 중계. 브라우저 탭(WebKit)이 여기로 오면 "어디로 연결할지" 를 앱이 정한다 — 시스템 리졸버·/etc/hosts 를 거치지 않는다.
//   .direct(host, port)  이 Mac 의 터널 리스너로 바로 (jenkins.acme → 127.0.0.2, 127.0.0.x, localhost)
//   .upstream            서버로 연 ssh -D(SOCKS) 에 요청을 그대로 넘긴다 (서버 IP)
//   .deny                즉시 거절 (그 밖 전부)
// SOCKS5 CONNECT 만, 인증 없음, 127.0.0.1 에만 바인딩. 한 연결 = 클라이언트 NWConnection 하나 + 원격 NWConnection 하나, 양방향 그대로 복사.

import Foundation
import Network

public enum SocksRoute: Sendable, Equatable {
    case direct(host: String, port: Int)
    case upstream
    case deny
}

public final class SocksRelay: @unchecked Sendable {
    public typealias Router = @Sendable (_ host: String, _ port: Int) -> SocksRoute

    private let upstreamPort: Int?
    private let route: Router
    private let queue = DispatchQueue(label: "servers.socks-relay")
    private var listener: NWListener?
    private let lock = NSLock()
    private var sessions: Set<Session> = []
    /// 바인딩된 포트 (start 가 끝나면 값이 있다)
    public private(set) var port: Int = 0

    public init(upstreamPort: Int?, route: @escaping Router) {
        self.upstreamPort = upstreamPort
        self.route = route
    }

    /// 127.0.0.1 의 빈 포트에 리슨하고 그 포트를 돌려준다.
    public func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    let port = Int(listener.port?.rawValue ?? 0)
                    self?.port = port
                    c.resume(returning: port)
                case let .failed(error):
                    guard once.claim() else { return }
                    c.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let open = lock.withLock { let s = sessions; sessions.removeAll(); return s }
        // 세션 상태(closed·remote)는 중계 큐에서만 만진다 — 부르는 쪽 스레드(메인)에서 닫으면 큐의 콜백과 겹친다
        for s in open { queue.async { s.close() } }
    }

    /// 컨티뉴에이션을 한 번만 재개하기 위한 플래그 (상태 콜백은 여러 번 온다)
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var used = false
        func claim() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
    }

    private func accept(_ client: NWConnection) {
        let session = Session(client: client, upstreamPort: upstreamPort, route: route, queue: queue) { [weak self] s in
            _ = self?.lock.withLock { self?.sessions.remove(s) }
        }
        lock.withLock { _ = sessions.insert(session) }
        session.start()
    }

    // MARK: - 연결 하나

    final class Session: Hashable, @unchecked Sendable {
        private let client: NWConnection
        private var remote: NWConnection?
        private let upstreamPort: Int?
        private let route: Router
        private let queue: DispatchQueue
        private let onEnd: (Session) -> Void
        private var closed = false
        /// 클라이언트에 SOCKS 응답을 이미 보냈다 — 그 뒤 원격이 끊기면 응답을 또 쓰지 않고 닫기만 한다 (데이터 사이에 10바이트가 섞인다)
        private var replied = false

        init(client: NWConnection, upstreamPort: Int?, route: @escaping Router, queue: DispatchQueue, onEnd: @escaping (Session) -> Void) {
            self.client = client
            self.upstreamPort = upstreamPort
            self.route = route
            self.queue = queue
            self.onEnd = onEnd
        }

        static func == (a: Session, b: Session) -> Bool { a === b }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

        func start() {
            client.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.close() }
                if case .cancelled = state { self?.close() }
            }
            client.start(queue: queue)
            greet()
        }

        func close() {
            guard !closed else { return }
            closed = true
            client.cancel()
            remote?.cancel()
            onEnd(self)
        }

        // 클라이언트 인사: VER NMETHODS METHODS… → VER 0x00(인증 없음)
        private func greet() {
            read(client, 2) { [weak self] head in
                guard let self, let head, head[0] == 5 else { self?.close(); return }
                self.read(self.client, Int(head[1])) { [weak self] _ in
                    guard let self else { return }
                    self.client.send(content: Data([5, 0]), completion: .contentProcessed { [weak self] _ in self?.request() })
                }
            }
        }

        // 요청: VER CMD RSV ATYP ADDR PORT
        private func request() {
            read(client, 4) { [weak self] head in
                guard let self, let head, head[0] == 5 else { self?.close(); return }
                let command = head[1], atyp = head[3]
                self.readAddress(atyp) { [weak self] address, rawAddress in
                    guard let self, let address, let rawAddress else { self?.close(); return }
                    self.read(self.client, 2) { [weak self] portData in
                        guard let self, let portData else { self?.close(); return }
                        let port = Int(portData[0]) << 8 | Int(portData[1])
                        guard command == 1 else { self.reply(7); return }   // CONNECT 만
                        let requestBytes = Data([5, 1, 0, atyp]) + rawAddress + portData
                        switch self.route(address, port) {
                        case .deny: self.reply(2)                              // connection not allowed by ruleset
                        case let .direct(host, targetPort): self.connectDirect(host: host, port: targetPort)
                        case .upstream: self.connectUpstream(requestBytes)
                        }
                    }
                }
            }
        }

        /// ATYP 별 주소. (문자열, 원본 바이트) — 원본은 상류로 그대로 넘길 때 쓴다.
        private func readAddress(_ atyp: UInt8, _ completion: @escaping (String?, Data?) -> Void) {
            switch atyp {
            case 1:
                read(client, 4) { data in
                    guard let data else { return completion(nil, nil) }
                    completion(data.map(String.init).joined(separator: "."), data)
                }
            case 3:
                read(client, 1) { [weak self] lengthData in
                    guard let self, let lengthData else { return completion(nil, nil) }
                    self.read(self.client, Int(lengthData[0])) { name in
                        guard let name else { return completion(nil, nil) }
                        completion(String(decoding: name, as: UTF8.self), lengthData + name)
                    }
                }
            case 4:
                read(client, 16) { data in
                    guard let data else { return completion(nil, nil) }
                    let groups = stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(data[$0]) << 8 | Int(data[$0 + 1])) }
                    completion(groups.joined(separator: ":"), data)
                }
            default:
                completion(nil, nil)
            }
        }

        /// 응답: VER REP RSV ATYP=1 0.0.0.0 0. REP 0 이면 연결 성공, 아니면 보내고 닫는다.
        private func reply(_ code: UInt8, then: (() -> Void)? = nil) {
            guard !replied else { close(); return }
            replied = true
            client.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak self] _ in
                if code == 0 { then?() } else { self?.close() }
            })
        }

        private func connectDirect(host: String, port: Int) {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { reply(1); return }
            let remote = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            self.remote = remote
            remote.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.reply(0) { self.pipe() }
                // connection refused. 닫힌 포트는 .failed 가 아니라 .waiting 으로 온다 — 기다리지 않고 바로 거절한다
                case .waiting, .failed, .cancelled: if !self.closed { self.reply(5) }
                default: break
                }
            }
            remote.start(queue: queue)
        }

        /// 상류 SOCKS(ssh -D)에 같은 요청을 그대로: 인사 → 요청 → 응답을 클라이언트에 전달 → 복사
        private func connectUpstream(_ requestBytes: Data) {
            guard let upstreamPort, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: upstreamPort)) else { reply(1); return }
            let remote = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            self.remote = remote
            remote.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    remote.send(content: Data([5, 1, 0]), completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        self.read(remote, 2) { [weak self] greeting in
                            guard let self, let greeting, greeting == Data([5, 0]) else { self?.reply(1); return }
                            remote.send(content: requestBytes, completion: .contentProcessed { [weak self] _ in
                                guard let self else { return }
                                self.read(remote, 4) { [weak self] head in
                                    guard let self, let head, head[0] == 5 else { self?.reply(1); return }
                                    let addressLength: Int
                                    switch head[3] { case 1: addressLength = 4; case 4: addressLength = 16; default: addressLength = -1 }
                                    let finish: (Data) -> Void = { [weak self] tail in
                                        guard let self, !self.replied else { return }
                                        // 상류의 응답을 그대로 전달. 실패면 그 뒤 닫는다.
                                        self.replied = true
                                        self.client.send(content: head + tail, completion: .contentProcessed { [weak self] _ in
                                            guard let self else { return }
                                            if head[1] == 0 { self.pipe() } else { self.close() }
                                        })
                                    }
                                    if addressLength > 0 {
                                        // 꼬리를 못 읽으면(상류가 조용히 끊음) 실패로 답한다 — 그냥 돌아가면 세션이 클라이언트가 끊을 때까지 남는다
                                        self.read(remote, addressLength + 2) { [weak self] tail in
                                            guard let tail else { self?.reply(1); return }
                                            finish(tail)
                                        }
                                    } else {
                                        self.read(remote, 1) { [weak self] lengthData in
                                            guard let self, let lengthData else { self?.reply(1); return }
                                            self.read(remote, Int(lengthData[0]) + 2) { [weak self] rest in
                                                guard let rest else { self?.reply(1); return }
                                                finish(lengthData + rest)
                                            }
                                        }
                                    }
                                }
                            })
                        }
                    })
                case .waiting, .failed, .cancelled: if !self.closed { self.reply(1) }   // general failure (상류 없음 — 닫힌 포트는 .waiting)
                default: break
                }
            }
            remote.start(queue: queue)
        }

        private func pipe() {
            guard let remote else { return }
            copy(from: client, to: remote)
            copy(from: remote, to: client)
        }

        private func copy(from source: NWConnection, to sink: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        if sendError != nil { self?.close() } else if !isComplete { self?.copy(from: source, to: sink) } else { self?.close() }
                    })
                } else if isComplete || error != nil {
                    self.close()
                } else {
                    self.copy(from: source, to: sink)
                }
            }
        }

        private func read(_ connection: NWConnection, _ count: Int, _ completion: @escaping (Data?) -> Void) {
            guard count > 0 else { return completion(Data()) }
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                guard error == nil, let data, data.count == count else { return completion(nil) }
                completion(data)
            }
        }
    }
}
