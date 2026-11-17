import Foundation
import Network
@testable import ServersCore
import XCTest

/// 이 Mac 안에서만: 가짜 HTTP 서버(127.0.0.1) + 중계 두 개(하나는 상류 역할). 클라이언트는 curl --socks5-hostname (호스트 이름을 프록시에 그대로 넘긴다).
final class SocksRelayTests: XCTestCase {
    /// 127.0.0.1 의 빈 포트에 "HTTP/1.1 200 OK … <body>" 만 돌려주는 리스너
    private func httpServer(body: String) async throws -> (NWListener, Int) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "test-http")
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        final class Flag: @unchecked Sendable { let lock = NSLock(); var done = false
            func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } } }
        let flag = Flag()
        let port: Int = try await withCheckedThrowingContinuation { c in
            listener.stateUpdateHandler = { state in
                if case .ready = state, flag.claim() { c.resume(returning: Int(listener.port!.rawValue)) }
                if case let .failed(e) = state, flag.claim() { c.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        return (listener, port)
    }

    /// curl 로 SOCKS5(원격 이름 풀이) 경유 GET. (종료 코드, 본문)
    private func curl(via socksPort: Int, _ url: String) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--max-time", "3", "--socks5-hostname", "127.0.0.1:\(socksPort)", url]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()   // 큰 응답은 파이프가 차기 전에 읽어야 curl 이 끝난다
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// 브라우저 판정(BrowserPolicy.route)을 건 중계: 루프백 별칭은 상류에 127.0.0.1 로, 그 밖은 받은 이름 그대로 넘어간다
    func testBrowserRouteSendsAliasToUpstreamLoopback() async throws {
        let (loopServer, loopPort) = try await httpServer(body: "SERVER-LOOPBACK")
        defer { loopServer.cancel() }

        // 상류 역할(실제로는 ssh -D — 서버에서 연결한다): 받은 대상을 적고, 127.0.0.1 만 실제로 연결해 준다
        let seen = Seen()
        let upstream = SocksRelay(upstreamPort: nil) { host, port in
            seen.add("\(host):\(port)")
            return host == "127.0.0.1" ? .direct(host: host, port: port) : .deny
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = SocksRelay(upstreamPort: upstreamPort) { host, port in BrowserPolicy.route(host: host, port: port) }
        let relayPort = try await relay.start()
        defer { relay.stop() }

        // 1) 별칭(127.0.0.1 · localhost) → 상류가 127.0.0.1:<포트> 로 받아 서버 루프백의 응답이 온다
        for alias in ["127-0-0-1.server.localhost", "localhost.server.localhost"] {
            let result = try curl(via: relayPort, "http://\(alias):\(loopPort)/")
            XCTAssertEqual(result.0, 0, alias); XCTAssertEqual(result.1, "SERVER-LOOPBACK", alias)
        }
        XCTAssertEqual(Set(seen.all), ["127.0.0.1:\(loopPort)"])

        // 2) 그 밖의 이름·주소는 막지 않고 받은 그대로 상류에 넘긴다 (이름 풀이도 상류 = 서버가 한다)
        _ = try curl(via: relayPort, "http://intranet.example.test:8080/")
        _ = try curl(via: relayPort, "http://198.51.100.7:80/")
        XCTAssertTrue(seen.all.contains("intranet.example.test:8080"), "\(seen.all)")
        XCTAssertTrue(seen.all.contains("198.51.100.7:80"), "\(seen.all)")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    /// 127.0.0.1 의 지금 닫혀 있는 포트 (빈 포트에 묶었다 바로 닫는다)
    private func closedPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        close(fd)
        return Int(UInt16(bigEndian: got.sin_port))
    }

    /// 닫힌 포트로의 연결은 바로 SOCKS 실패로 끝난다 — 매달리면 curl 이 --max-time 3 뒤 28(타임아웃)로 끝난다.
    /// NWConnection 은 connection refused 를 .failed 가 아니라 .waiting 으로 알려, 예전엔 응답 없이 클라이언트 타임아웃까지 갔다.
    func testRefusedConnectionFailsFastInsteadOfHanging() async throws {
        let dead = closedPort()
        // 직접(루프백) 연결이 거절될 때
        let direct = SocksRelay(upstreamPort: nil) { host, port in .direct(host: host, port: port) }
        let directPort = try await direct.start()
        defer { direct.stop() }
        var started = Date()
        let refused = try curl(via: directPort, "http://127.0.0.1:\(dead)/")
        XCTAssertNotEqual(refused.0, 0)
        XCTAssertNotEqual(refused.0, 28, "타임아웃까지 매달렸다")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "거절은 바로 돌아와야 한다")

        // 상류 SOCKS(ssh -D)가 떠 있지 않을 때
        let noUpstream = SocksRelay(upstreamPort: dead) { _, _ in .upstream }
        let noUpstreamPort = try await noUpstream.start()
        defer { noUpstream.stop() }
        started = Date()
        let failed = try curl(via: noUpstreamPort, "http://198.51.100.7/")
        XCTAssertNotEqual(failed.0, 0)
        XCTAssertNotEqual(failed.0, 28, "타임아웃까지 매달렸다")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// 상류 성공 경로: 상류 중계가 "서버 IP" 를 실제 로컬 서버로 바꿔 주게 해서 끝까지 흐르는지 본다
    func testUpstreamSuccessPath() async throws {
        let (farServer, farPort) = try await httpServer(body: "VIA-UPSTREAM")
        defer { farServer.cancel() }
        let upstream = SocksRelay(upstreamPort: nil) { host, port in
            host == "198.51.100.7" ? .direct(host: "127.0.0.1", port: port) : .deny
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = SocksRelay(upstreamPort: upstreamPort) { host, _ in host == "198.51.100.7" ? .upstream : .deny }
        let relayPort = try await relay.start()
        defer { relay.stop() }
        let result = try curl(via: relayPort, "http://198.51.100.7:\(farPort)/")
        XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1, "VIA-UPSTREAM")
        // 200KB 정도 큰 응답도 양방향 복사가 끊기지 않는지
        let big = String(repeating: "x", count: 200_000)
        let (bigServer, bigPort) = try await httpServer(body: big)
        defer { bigServer.cancel() }
        let upstream2 = SocksRelay(upstreamPort: nil) { host, port in .direct(host: "127.0.0.1", port: port) }
        let up2 = try await upstream2.start(); defer { upstream2.stop() }
        let relay2 = SocksRelay(upstreamPort: up2) { _, _ in .upstream }
        let r2 = try await relay2.start(); defer { relay2.stop() }
        XCTAssertEqual(try curl(via: r2, "http://198.51.100.7:\(bigPort)/").1.count, 200_000)
    }
}
