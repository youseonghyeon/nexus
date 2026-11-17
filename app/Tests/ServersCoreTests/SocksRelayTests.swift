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

    func testDirectUpstreamAndDeny() async throws {
        let (loopServer, loopPort) = try await httpServer(body: "LOOPBACK")
        let (farServer, farPort) = try await httpServer(body: "VIA-UPSTREAM")
        defer { loopServer.cancel(); farServer.cancel() }

        // 상류 역할: 무엇이든 직접 연결해 주는 중계 (실제로는 ssh -D)
        let upstream = SocksRelay(upstreamPort: nil) { host, port in .direct(host: host, port: port) }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        // 시험 대상: 이름 → 루프백 직접, "서버 IP"(여기선 198.51.100.7 라는 가짜) → 상류, 그 외 거절
        let scope = BrowserScope(serverIP: "198.51.100.7", loopbackNameAddresses: ["jenkins.acme": "127.0.0.1"])
        let relay = SocksRelay(upstreamPort: upstreamPort) { host, port in
            // 상류는 진짜 198.51.100.7 에 못 가니, 상류로 넘길 때 실제로는 far 서버로 가도록 상류 쪽 판정을 흉내 낸다
            BrowserPolicy.route(host: host, port: port, scope: scope)
        }
        let relayPort = try await relay.start()
        defer { relay.stop() }
        XCTAssertGreaterThan(relayPort, 0)

        // 1) 터널 이름: 앱이 직접 127.0.0.1 로 (시스템 리졸버 없이 — jenkins.acme 는 hosts 에 없다)
        let named = try curl(via: relayPort, "http://jenkins.acme:\(loopPort)/")
        XCTAssertEqual(named.0, 0); XCTAssertEqual(named.1, "LOOPBACK")

        // 2) 루프백 IP 리터럴·localhost 도 직접
        XCTAssertEqual(try curl(via: relayPort, "http://127.0.0.1:\(loopPort)/").1, "LOOPBACK")
        XCTAssertEqual(try curl(via: relayPort, "http://localhost:\(loopPort)/").1, "LOOPBACK")

        // 3) 거절: 다른 호스트는 SOCKS 오류로 즉시 (curl 종료 코드 97 = 프록시가 거절)
        let denied = try curl(via: relayPort, "http://192.168.112.11:80/")
        XCTAssertNotEqual(denied.0, 0); XCTAssertEqual(denied.1, "")

        // 4) 상류 전달: 서버 IP 요청은 상류 SOCKS 로 그대로 넘어간다. 상류(직접 연결 중계)가 198.51.100.7 에 닿을 수 없으니
        //    여기서는 "상류가 응답 실패를 돌려주면 클라이언트도 실패로 끝난다" 까지만 확인한다 (성공 경로는 WebKit 진단 테스트에서 실제 ssh -D 없이 확인 불가)
        let far = try curl(via: relayPort, "http://198.51.100.7:\(farPort)/")
        XCTAssertNotEqual(far.0, 0, "상류가 못 가면 실패로 끝나야 한다 (매달리지 않음)")
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
