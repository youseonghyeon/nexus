// Tunnel: ssh -L 인자·워치독·프로세스 트리 종료.

import Foundation
import XCTest
@testable import ServersCore

final class TunnelTests: XCTestCase {
    /// 가짜 ssh: 배너를 찍고 대기하거나(open), 즉시 실패한다(closed). 실제 ssh 는 실행하지 않는다.
    private func fakeSSH(_ body: String) throws -> String {
        let dir = tempPath("tunnel")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent("ssh")
        try ("#!/bin/sh\n" + body + "\n").write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }

    /// Ports 카드 주소 → 원격 호스트 칸: ss 의 %장치 는 떼고, 결과는 원격 호스트 검사를 통과해야 한다
    func testFromListenAddress() {
        XCTAssertEqual(TunnelTarget.fromListenAddress("100.101.0.1%tailscale0"), "100.101.0.1")
        XCTAssertEqual(TunnelTarget.fromListenAddress("*"), "127.0.0.1")
        XCTAssertEqual(TunnelTarget.fromListenAddress(""), "127.0.0.1")
        XCTAssertEqual(TunnelTarget.fromListenAddress("0.0.0.0%eth0"), "127.0.0.1")
        XCTAssertEqual(TunnelTarget.fromListenAddress("::1"), "127.0.0.1")
        XCTAssertEqual(TunnelTarget.fromListenAddress("127.0.0.53%lo"), "127.0.0.53")
        XCTAssertEqual(TunnelTarget.fromListenAddress("10.0.0.5"), "10.0.0.5")
        XCTAssertEqual(TunnelTarget.fromListenAddress("fe80::1%eth0"), "fe80::1")
        for address in ["100.101.0.1%tailscale0", "127.0.0.53%lo", "fe80::1%eth0", "*", "10.0.0.5"] {
            XCTAssertNotNil(TunnelTarget.remoteHost(TunnelTarget.fromListenAddress(address)), address)
        }
        XCTAssertNil(TunnelTarget.remoteHost("100.101.0.1%tailscale0"), "옛 버그: 그대로 채우면 검사에 걸린다")
    }

    /// 입력창 원격 호스트 칸: 비우면 서버 자신, IP·이름은 그대로, 포트 붙임·공백·잘못된 문자는 거절
    func testRemoteHostInput() {
        XCTAssertEqual(TunnelTarget.remoteHost(""), "127.0.0.1")
        XCTAssertEqual(TunnelTarget.remoteHost("   "), "127.0.0.1")
        XCTAssertEqual(TunnelTarget.remoteHost("LocalHost"), "127.0.0.1")
        XCTAssertEqual(TunnelTarget.remoteHost(" 10.0.0.5 "), "10.0.0.5")
        XCTAssertEqual(TunnelTarget.remoteHost("db-1.internal"), "db-1.internal")
        XCTAssertEqual(TunnelTarget.remoteHost("my_svc"), "my_svc")
        XCTAssertEqual(TunnelTarget.remoteHost("fe80::1"), "fe80::1")
        XCTAssertEqual(TunnelTarget.remoteHost("[::1]"), "::1")
        XCTAssertNil(TunnelTarget.remoteHost("10.0.0.5:9090"))      // 포트는 원격 포트 칸에
        XCTAssertNil(TunnelTarget.remoteHost("10.0.0.256"))
        XCTAssertNil(TunnelTarget.remoteHost("10.0.0"))
        XCTAssertNil(TunnelTarget.remoteHost("10.0.0.5.6"))
        XCTAssertNil(TunnelTarget.remoteHost("10.0.0.٥"))           // 아라비아 숫자: 크래시 없이 거절
        XCTAssertNil(TunnelTarget.remoteHost("a b"))
        XCTAssertNil(TunnelTarget.remoteHost("-host"))
        XCTAssertNil(TunnelTarget.remoteHost("host."))
        XCTAssertNil(TunnelTarget.remoteHost("user@host"))
        XCTAssertNil(TunnelTarget.remoteHost("fe80::g"))
        XCTAssertNil(TunnelTarget.remoteHost("호스트"))
    }

    func testPortTunnelToBindAddress() throws {
        let config = try ServerConfigParser.parse(fixture)
        let was = config.server("was")!
        let spec = TunnelSpec(server: was, kind: .port(remotePort: 5432, remoteHost: "192.168.1.9"), localPort: 15432)
        XCTAssertEqual(spec.summary, "localhost:15432 → 192.168.1.9:5432")
        XCTAssertEqual(spec.arguments.suffix(2).first, "127.0.0.1:15432:192.168.1.9:5432")
        XCTAssertEqual(TunnelSpec(server: was, kind: .port(remotePort: 80), localPort: 8080).summary, "localhost:8080 → \(was.ip):80")
        XCTAssertEqual(TunnelSpec(server: was, kind: .port(remotePort: 3000), localPort: 3001).sidebarTitle, "was : 3000")
        XCTAssertEqual(TunnelSpec(server: was, kind: .port(remotePort: 3000), localPort: 3001).portMapping, "3001 → 3000")
        XCTAssertEqual(spec.sidebarTitle, "was : 192.168.1.9:5432")
        let db = TunnelSpec(server: was, kind: .db(host: "192.168.113.6", port: 5432, name: "acme"), localPort: 15432)
        XCTAssertEqual(db.sidebarTitle, "was → db : 5432"); XCTAssertEqual(db.portMapping, "15432 → 5432")
        XCTAssertEqual(db.summary, "localhost:15432 → \(was.ip):\(was.port) → 192.168.113.6:5432")
        // IPv6 바인딩 주소는 대괄호로 감싸야 ssh -L 이 받는다 (ssh -G 로 확인, 접속 없음)
        let v6 = TunnelSpec(server: was, kind: .port(remotePort: 22, remoteHost: "fe80::1%en0"), localPort: 18022)
        XCTAssertEqual(v6.arguments.suffix(2).first, "127.0.0.1:18022:[fe80::1%en0]:22")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G", "-F", "/dev/null"] + v6.arguments; p.standardOutput = Pipe(); p.standardError = Pipe()
        p.terminationHandler = { _ in }
        try p.run(); while p.isRunning { usleep(10_000) }
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testSpecArgumentsAndBanner() throws {
        let config = try ServerConfigParser.parse(fixture)
        let was = config.server("was")!
        let spec = TunnelSpec(server: was, kind: .db(host: "db.example.test", port: 5432, name: "testdb"), localPort: 15432)
        XCTAssertEqual(spec.summary, "localhost:15432 → \(was.ip):\(was.port) → db.example.test:5432")
        XCTAssertTrue(spec.banner.hasPrefix("✔ DB 터널 열림"))
        let args = spec.arguments
        XCTAssertNotEqual(args.first, "ssh", "인자 배열에 실행 파일 이름이 들어가면 ssh 가 그것을 호스트로 받는다")
        XCTAssertEqual(args.prefix(4), ["-o", "ControlMaster=no", "-o", "ControlPath=none"])
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes") && args.contains("-N"))
        XCTAssertTrue(args.contains("NumberOfPasswordPrompts=2"), "터널도 오답 재시도 제한")
        XCTAssertEqual(args.suffix(3), ["-L", "127.0.0.1:15432:db.example.test:5432", "tester@192.0.2.22"])
        let port = TunnelSpec(server: was, kind: .port(remotePort: 8080), localPort: 18080)
        XCTAssertEqual(port.arguments.suffix(2).first, "127.0.0.1:18080:127.0.0.1:8080")
        XCTAssertFalse(port.arguments.contains("BindInterface=en10"))
        // 바깥쪽(서버로 가는) 연결만 장치에 묶고, 로컬 리스너(127.0.0.x)는 그대로라 다른 앱이 붙는다
        let bound = TunnelSpec(server: was, kind: .port(remotePort: 8080), localPort: 18080, bindInterface: "en10")
        XCTAssertTrue(bound.arguments.contains("BindInterface=en10"))
        XCTAssertEqual(bound.arguments.suffix(2).first, "127.0.0.1:18080:127.0.0.1:8080")

        // SOCKS(ssh -D): -L 대신 -D, 목적지 없음. 배너·요약·기록 id 도 따로.
        let socks = TunnelSpec(server: was, kind: .socks, localPort: 1080)
        XCTAssertEqual(socks.arguments.suffix(3), ["-D", "127.0.0.1:1080", "tester@192.0.2.22"])
        XCTAssertTrue(socks.arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertEqual(socks.summary, "socks5://localhost:1080 → \(was.ip) 경유")
        XCTAssertEqual(socks.sidebarTitle, "was proxy")
        XCTAssertTrue(socks.banner.hasPrefix("✔ 프록시 열림"))
        XCTAssertEqual(RecentTunnel(serverKey: "was", kind: .socks, localPort: 1080).id, "was|socks")
        XCTAssertEqual(HostAliasStore.assignmentKey(server: was, kind: .socks), "was")

        // 실제 ssh 가 이 인자를 받아들이는지 -G 로 확인 (설정 평가만, 접속 없음). 호스트는 fixture 의 TEST-NET 주소.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G", "-F", "/dev/null"] + port.arguments
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(text.contains("hostname 192.0.2.22") && text.contains("user tester"), text)
        XCTAssertTrue(text.contains("localforward [127.0.0.1]:18080 [127.0.0.1]:8080"), text)
    }

    func testOpenThenStop() async throws {
        let stub = try fakeSSH("printf '✔ 터널 열림 — test\\n'; sleep 30")
        let process = TunnelProcess()
        let opened = expectation(description: "banner")
        let exited = expectation(description: "exit")
        let lines = DataBoxLines()
        process.onOutputLine = { line in lines.append(line); if line.hasPrefix("✔") { opened.fulfill() } }
        process.onExit = { code, _ in lines.exitCode = code; exited.fulfill() }
        try process.start(executable: stub, arguments: ["-N", "x"], environment: ["SSH_ASKPASS": "/x"])
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertTrue(process.isRunning)
        process.stop()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(lines.exitCode, 128 + SIGTERM)   // 워치독(sh)이 SIGTERM 으로 죽은 자식을 143 으로 보고
    }

    // 리뷰 2차 #3·#6: stop() 은 워치독·ssh·손자(비밀번호 팝업 자리)까지 끝내고, 앱(stdin 파이프)이 사라지면 ssh 도 끝난다
    func testStopKillsWholeTreeAndWatchdogFollowsStdin() async throws {
        let marker = tempPath("grandchild").path
        // 가짜 ssh: 손자(sleep)를 띄우고 자기도 대기. 손자가 죽으면 marker 파일이 지워진다.
        let stub = try fakeSSH("touch '\(marker)'; (sleep 30; rm -f '\(marker)') & g=$!; trap 'kill $g; rm -f \"\(marker)\"; exit 143' TERM; printf '✔ open\\n'; wait $g")
        let process = TunnelProcess()
        let opened = expectation(description: "open"); let exited = expectation(description: "exit")
        process.onOutputLine = { line in if line.hasPrefix("✔") { opened.fulfill() } }
        process.onExit = { _, _ in exited.fulfill() }
        try process.start(executable: stub, arguments: ["-N", "x"], environment: [:])
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        process.stop()
        await fulfillment(of: [exited], timeout: 5)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "손자까지 죽어야 한다")
        XCTAssertFalse(process.isRunning)
    }

    // 리뷰 3차: ssh 가 먼저 끝나면 감시 cat 도 함께 끝나야 한다 (고아 cat 이 앱 파이프를 쥐면 리더 스레드가 샌다)
    func testWatchdogCleansUpCatWhenChildExits() async throws {
        let stub = try fakeSSH("echo 'boom: Permission denied' >&2; exit 255")
        let process = TunnelProcess()
        let exited = expectation(description: "exit")
        let box = DataBoxLines()
        process.onExit = { code, message in box.exitCode = code; box.message = message; exited.fulfill() }
        try process.start(executable: stub, arguments: [], environment: [:])
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(box.exitCode, 255)
        XCTAssertTrue(box.message.contains("Permission denied"), "onExit 는 stderr EOF 뒤에 와야 원인이 담긴다: \(box.message)")
        try await Task.sleep(for: .milliseconds(500))
        // 이 워치독 아래에서 살아남은 cat 이 없어야 한다
        let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-axo", "ppid=,command="]
        let out = Pipe(); ps.standardOutput = out; ps.terminationHandler = { _ in }
        try ps.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let orphanCats = text.split(separator: "\n").filter { $0.hasPrefix("    1 cat") || $0.hasPrefix("1 cat") }
        XCTAssertTrue(orphanCats.isEmpty, "고아 cat: \(orphanCats)")
    }

    func testWatchdogScriptIsValidSh() throws {
        let (sh, args) = TunnelWatchdog.command(executable: "/usr/bin/true", arguments: ["-x"])
        XCTAssertEqual(sh, "/bin/sh"); XCTAssertEqual(args.prefix(2), ["-c", TunnelWatchdog.script]); XCTAssertEqual(args.suffix(3), ["sh", "/usr/bin/true", "-x"])
        XCTAssertEqual(try shellSyntaxStatus("/bin/sh", TunnelWatchdog.script), 0)
        // 종료 코드는 자식(ssh)의 것: exit 7 → 7
        let run = Process(); run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = ["-c", TunnelWatchdog.script, "sh", "/bin/sh", "-c", "exit 7"]
        run.standardInput = Pipe()   // 열린 채로 두면 워치독은 자식 종료를 기다린다
        try run.run(); run.waitUntilExit(); XCTAssertEqual(run.terminationStatus, 7)
    }

    func testForwardFailureExits() async throws {
        let stub = try fakeSSH("echo 'bind [127.0.0.1]:15432: Address already in use' >&2; echo 'Could not request local forwarding.' >&2; exit 255")
        let process = TunnelProcess()
        let exited = expectation(description: "exit")
        let box = DataBoxLines()
        process.onExit = { code, message in box.exitCode = code; box.message = message; exited.fulfill() }
        try process.start(executable: stub, arguments: [], environment: [:])
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(box.exitCode, 255)
        XCTAssertTrue(box.message.contains("Address already in use") && box.message.contains("Could not request"), box.message)
    }

    func testPortAllocatorSkipsTakenAndBusyPorts() {
        // 실제로 한 포트를 0.0.0.0(와일드카드)에 점유해 두고 할당기가 건너뛰는지 본다 (리뷰 2차 #1: SO_REUSEADDR 면 놓친다)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 1)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let busy = Int(UInt16(bigEndian: bound.sin_port))
        defer { close(fd) }
        XCTAssertFalse(PortAllocator.isFree(busy))
        XCTAssertNotEqual(PortAllocator.nextFree(preferred: busy, taken: []), busy)
        let next = PortAllocator.nextFree(preferred: busy, taken: [busy + 1])
        XCTAssertNotNil(next)
        XCTAssertNotEqual(next, busy); XCTAssertNotEqual(next, busy + 1)
        XCTAssertNil(PortAllocator.nextFree(preferred: 65535, taken: [65535], limit: 1))
        // 특권 포트: 제안은 +8000, 할당은 제안 포트부터 (443 자체는 시도하지 않는다)
        XCTAssertTrue(PortAllocator.isPrivileged(443)); XCTAssertFalse(PortAllocator.isPrivileged(1024))
        XCTAssertEqual(PortAllocator.suggestedLocalPort(forRemote: 443), 8443)
        XCTAssertEqual(PortAllocator.suggestedLocalPort(forRemote: 80), 8080)
        XCTAssertEqual(PortAllocator.suggestedLocalPort(forRemote: 6443), 6443)
        let forPrivileged = PortAllocator.nextFree(preferred: 443, taken: [])
        XCTAssertNotNil(forPrivileged); XCTAssertGreaterThanOrEqual(forPrivileged ?? 0, 8443)
    }

    // stderr 는 끝 N줄만 남기고, 종료 메시지는 마지막 5줄 그대로
    func testStderrLinesCapped() async throws {
        let stub = try fakeSSH("i=1; while [ $i -le 100 ]; do echo \"err $i\" >&2; i=$((i+1)); done; exit 255")
        let process = TunnelProcess()
        let exited = expectation(description: "exit")
        let box = DataBoxLines()
        process.onExit = { code, message in box.exitCode = code; box.message = message; exited.fulfill() }
        try process.start(executable: stub, arguments: [], environment: [:])
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(process.stderrSnapshot.count, TunnelProcess.stderrKeep)
        XCTAssertEqual(process.stderrSnapshot.last, "err 100")
        XCTAssertEqual(box.message, (96...100).map { "err \($0)" }.joined(separator: "\n"))
    }

    /// 서버 주소 터널: -L 이 별칭 주소에 바인딩되고 요약·배너·정보에 hosts 이름이 쓰인다. 기록도 주소를 남긴다.
    func testNamedTunnelBindsAliasAndShowsHostName() throws {
        let server = Server(key: "db", group: "acme", network: .lan, type: .linux, ip: "192.168.113.11", user: "manager", port: 22,
                            check: .tcp, role: nil, env: nil, wolMac: nil)
        let spec = TunnelSpec(server: server, kind: .port(remotePort: 5432), localPort: 5432, bindAddress: "127.0.0.2", hostName: "db.acme")
        XCTAssertTrue(spec.arguments.contains("127.0.0.2:5432:127.0.0.1:5432"), spec.arguments.joined(separator: " "))
        XCTAssertEqual(spec.summary, "db.acme:5432 → 192.168.113.11:5432")
        XCTAssertEqual(spec.portMapping, "db.acme:5432")
        XCTAssertTrue(spec.banner.contains("db.acme:5432"))
        let plain = TunnelSpec(server: server, kind: .port(remotePort: 5432), localPort: 15432)
        XCTAssertTrue(plain.arguments.contains("127.0.0.1:15432:127.0.0.1:5432"))
        XCTAssertEqual(plain.portMapping, "15432 → 5432")

        let record = RecentTunnel(serverKey: "db", kind: .port(remotePort: 5432), localPort: 5432, bindAddress: "127.0.0.2", hostName: "db.acme")
        let data = try JSONEncoder().encode(RecentState(tunnels: [record]))
        XCTAssertEqual(try JSONDecoder().decode(RecentState.self, from: data).tunnels.first?.hostName, "db.acme")
        let legacy = #"{"tunnels":[{"serverKey":"db","kind":{"port":{"remotePort":5432,"remoteHost":"127.0.0.1"}},"localPort":15432,"lastUsed":0}]}"#
        XCTAssertNil(try JSONDecoder().decode(RecentState.self, from: Data(legacy.utf8)).tunnels.first?.bindAddress, "옛 기록은 localhost 터널")
    }

    /// 아직 별칭이 없는 루프백 주소는 bind 가 안 되지만 "사용 중" 이 아니다 (별칭은 인증 뒤에 붙는다)
    func testPortOnMissingLoopbackAliasCountsAsFree() {
        XCTAssertTrue(PortAllocator.isFree(5432, address: "127.0.0.250"))
        XCTAssertEqual(PortAllocator.nextFree(preferred: 5432, taken: [], address: "127.0.0.250"), 5432)
    }
}

final class DataBoxLines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var exitCode: Int32 = -1
    var message = ""
    func append(_ l: String) { lock.withLock { _lines.append(l) } }
    var lines: [String] { lock.withLock { _lines } }
}
