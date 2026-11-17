// 터널: 앱이 붙잡고 있는 `ssh -N` 프로세스. 터미널이 아니라 목록 항목으로 표시된다.
//   TunnelProcess     프로세스 실행·출력 줄 콜백·종료 콜백·중지. UI 와 무관하며 로컬 가짜 ssh 로 테스트한다.
//   PortAllocator     로컬 포트 충돌 회피: 다른 터널이 쓰거나 시스템에서 이미 열린 포트면 다음 빈 포트를 고른다.

import Foundation

public enum TunnelKind: Sendable, Equatable, Codable {
    case port(remotePort: Int, remoteHost: String = "127.0.0.1")   // localhost:local → server 의 remoteHost:remote
    case db(host: String, port: Int, name: String?)                // localhost:local → (server 경유) host:port
    case socks                                                     // localhost:local 이 SOCKS5 프록시 (ssh -D) — 어디로든 server 를 거쳐 나간다
}

public struct TunnelSpec: Sendable, Equatable {
    public let server: Server
    public let kind: TunnelKind
    public let localPort: Int
    /// 서버 주소로 열기: 루프백 별칭(127.0.0.x)에 바인딩하고 /etc/hosts 이름(db.acme)을 붙인다. nil 이면 127.0.0.1(localhost).
    public let bindAddress: String?
    public let hostName: String?
    /// 서버로 나가는 연결을 묶을 장치 (내부망 서버면 그 서비스의 en10 등). 로컬 리스너(bindAddress)와는 별개.
    public let bindInterface: String?
    public init(server: Server, kind: TunnelKind, localPort: Int, bindAddress: String? = nil, hostName: String? = nil, bindInterface: String? = nil) {
        self.server = server
        self.kind = kind
        self.localPort = localPort
        self.bindAddress = bindAddress
        self.hostName = hostName
        self.bindInterface = bindInterface
    }

    public var isNamed: Bool { bindAddress != nil }
    /// 접속에 쓰는 호스트 표기 (db.acme 또는 localhost)
    public var localHost: String { hostName ?? "localhost" }
    public var localBind: String { bindAddress ?? "127.0.0.1" }

    /// "localhost:3001 → 192.168.112.11:3000" (그 서버의 터널 카드에 쓰이므로 서버 이름은 뺀다). 서버 안의 다른 주소면 그 주소.
    /// DB 는 경유 서버의 SSH 포트를 거쳐 감: "localhost:15432 → 192.168.112.11:22 → 192.168.113.6:5432"
    public var summary: String {
        switch kind {
        case let .port(remote, host): return "\(localHost):\(localPort) → \(host == "127.0.0.1" ? server.ip : host):\(remote)"
        case let .db(host, port, _): return "\(localHost):\(localPort) → \(server.ip):\(server.port) → \(host):\(port)"
        case .socks: return "socks5://\(localHost):\(localPort) → \(server.ip) 경유"
        }
    }

    /// 사이드바 제목: 어디로 가는 터널인지 (서버 : 원격 포트). "was : 3000", "win : 192.168.1.9:443", "was → db : 5432"
    public var sidebarTitle: String {
        switch kind {
        case let .port(remote, host): return host == "127.0.0.1" ? "\(server.key) : \(remote)" : "\(server.key) : \(host):\(remote)"
        case let .db(_, port, _): return "\(server.key) → db : \(port)"
        case .socks: return "\(server.key) proxy"
        }
    }

    /// 사이드바 설명: 로컬 포트 → 원격 포트 (호스트명 없이). "3001 → 3000". 이름이 있으면 "db.acme:5432".
    public var portMapping: String {
        if isNamed { return "\(localHost):\(localPort)" }
        switch kind {
        case let .port(remote, _): return "\(localPort) → \(remote)"
        case let .db(_, port, _): return "\(localPort) → \(port)"
        case .socks: return "socks5 :\(localPort)"
        }
    }

    /// 배너: ssh 가 인증 직후 LocalCommand 로 찍는다. 첫 줄이 도착하면 "열림" 으로 본다.
    public var banner: String {
        switch kind {
        case let .port(remote, host):
            return "✔ 터널 열림 — \(localHost):\(localPort) → \(server.key) \(host == "127.0.0.1" ? "localhost" : host):\(remote)"
        case let .db(host, port, name):
            return SessionCommand.dbBanner(server: server, host: host, port: port, localPort: localPort, name: name, localHost: localHost)
        case .socks:
            return "✔ 프록시 열림 — socks5://\(localHost):\(localPort) → \(server.key) 경유"
        }
    }

    public var arguments: [String] {
        switch kind {
        case let .port(remote, host):
            return SessionCommand.tunnelArguments(to: server, remotePort: remote, remoteHost: host, localPort: localPort, bindAddress: localBind, banner: banner, bindInterface: bindInterface)
        case let .db(host, port, _):
            return SessionCommand.dbTunnelArguments(via: server, host: host, port: port, localPort: localPort, bindAddress: localBind, banner: banner, bindInterface: bindInterface)
        case .socks:
            return SessionCommand.socksArguments(via: server, localPort: localPort, bindAddress: localBind, banner: banner, bindInterface: bindInterface)
        }
    }
}

/// 터널 워치독. ssh 를 자식으로 띄우고 표준입력(앱이 쥔 파이프)의 EOF 를 기다린다.
/// 앱이 어떤 이유로든 죽으면 파이프가 닫혀 ssh 를 끝내므로 고아 터널이 남지 않는다. 종료 코드는 ssh 의 것을 그대로 낸다.
public enum TunnelWatchdog {
    /// 비대화형 sh 는 `&` 작업의 stdin 을 /dev/null 로 바꾸므로, 앱의 파이프는 fd 3 으로 따로 넘겨 cat 에 준다.
    /// 감시 서브셸은 TERM 을 받으면 cat 까지 죽인다 (안 그러면 ssh 가 먼저 끝났을 때 cat 이 고아로 남아 파이프를 쥔다).
    public static let script = """
    exec 3<&0
    "$@" </dev/null & p=$!
    ( trap 'kill "$c" 2>/dev/null; exit 0' TERM; cat <&3 >/dev/null & c=$!; wait "$c"; kill -TERM "$p" 2>/dev/null ) & w=$!
    exec 3<&-
    trap 'kill -TERM "$p" 2>/dev/null' TERM INT HUP
    wait "$p"; rc=$?
    kill -TERM "$w" 2>/dev/null
    exit "$rc"
    """
    /// /bin/sh -c <script> sh <executable> <args...>
    public static func command(executable: String, arguments: [String]) -> (String, [String]) {
        ("/bin/sh", ["-c", script, "sh", executable] + arguments)
    }
}

public enum TunnelState: Sendable, Equatable {
    /// 이전 실행에서 기록된 터널 (recent.json). 아직 안 열었고 [열기]/다시 연결로 연다.
    case idle
    case connecting
    case open
    case closed(exitCode: Int32, message: String)
}

/// 장수 프로세스 하나. 콜백은 임의 스레드에서 온다 (호출자가 메인으로 넘긴다).
public final class TunnelProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stderrLines: [String] = []
    static let stderrKeep = 20
    var stderrSnapshot: [String] { lock.withLock { stderrLines } }
    private var started = false

    public var onOutputLine: (@Sendable (String) -> Void)?
    public var onExit: (@Sendable (Int32, String) -> Void)?

    public init() {}

    private let stdinPipe = Pipe()
    /// stop() 으로 끝낸 경우 (사용자 의도). 종료 코드와 무관하게 "끊음" 으로 표시할 수 있게 한다.
    public private(set) var stopRequested = false

    /// executable 은 절대 경로 또는 PATH 이름. environment 는 현재 환경(+LANG)에 덧씌운다.
    /// watchdog=true 면 sh 워치독으로 감싸 앱이 죽을 때 ssh 도 함께 끝나게 한다.
    public func start(executable: String, arguments: [String], environment: [String: String], watchdog: Bool = true) throws {
        let path = executable.hasPrefix("/") ? executable : (ProcessRunner.resolve(executable) ?? executable)
        if watchdog {
            let (sh, args) = TunnelWatchdog.command(executable: path, arguments: arguments)
            process.executableURL = URL(fileURLWithPath: sh)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        }
        process.environment = ProcessLocale.environment(adding: environment)
        // 워치독이 EOF 를 기다리는 파이프. 앱이 살아 있는 동안 쓰기 쪽을 쥐고 있다가 앱과 함께 닫힌다.
        process.standardInput = stdinPipe
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // onExit 는 종료 통지와 stderr EOF 가 모두 온 뒤에 한 번만 (오류 원인이 비어 있지 않도록).
        // stderr EOF 가 끝내 안 오면(누가 파이프를 쥐면) 종료 2초 뒤 강제로 낸다.
        let finished = Completion(needed: 2) { [weak self] in
            guard let self else { return }
            let message = self.lock.withLock { self.stderrLines.suffix(5).joined(separator: "\n") }
            self.onExit?(self.process.isRunning ? 128 + SIGTERM : self.process.terminationStatus, message)
        }
        Self.readLines(out.fileHandleForReading, onLine: { [weak self] line in self?.onOutputLine?(line) }, onEOF: {})
        Self.readLines(err.fileHandleForReading, onLine: { [weak self] line in
            guard let self else { return }
            self.lock.withLock {
                self.stderrLines.append(line)
                // 원인 표시는 마지막 5줄뿐 — 오래 도는 터널에서 끝없이 쌓이지 않게 자른다
                if self.stderrLines.count > Self.stderrKeep { self.stderrLines.removeFirst(self.stderrLines.count - Self.stderrKeep) }
            }
            self.onOutputLine?(line)
        }, onEOF: { finished.step() })
        process.terminationHandler = { _ in
            finished.step()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finished.force() }
        }
        try process.run()
        started = true
    }

    public var isRunning: Bool { started && process.isRunning }

    /// 프로세스 트리(워치독·ssh·비밀번호 팝업)에 SIGTERM, 2초 안에 안 죽으면 SIGKILL.
    public func stop() {
        guard started, process.isRunning else { return }
        stopRequested = true
        ProcessTree.terminate(process.processIdentifier) { [weak self] in self?.process.isRunning == true }
    }

    /// 전용 스레드에서 줄 단위로 읽는다 (GCD 풀 점유 금지).
    private static func readLines(_ handle: FileHandle, onLine: @escaping @Sendable (String) -> Void, onEOF: @escaping @Sendable () -> Void) {
        blockingThread("tunnel.read") {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<nl], as: UTF8.self).replacingOccurrences(of: "\r", with: "")
                    buffer.removeSubrange(...nl)
                    onLine(line)
                }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            onEOF()
        }
    }
}

/// 터널 입력창의 원격 호스트 칸: 서버 너머의 다른 주소로 포워딩한다 (서버 → 10.0.0.5:9090).
public enum TunnelTarget {
    /// Ports 카드(서버 ss 출력)의 대기 주소 → 원격 호스트 칸 값. 모든 주소·루프백 대기는 서버 자신(127.0.0.1).
    /// ss 는 장치에 묶인 소켓을 "100.101.0.1%tailscale0" 처럼 쓴다 — %장치 는 떼고 주소만 (2026-10-14 그대로 채워 Open 이 막혔다).
    public static func fromListenAddress(_ address: String) -> String {
        let host = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return ["", "*", "0.0.0.0", "::", "127.0.0.1", "::1"].contains(host) ? "127.0.0.1" : host
    }

    /// 입력값 → ssh -L 대상 호스트. 비었거나 localhost 면 "127.0.0.1"(서버 자신), 형식이 틀리면 nil.
    /// 받는 꼴: IPv4(점 넷, 0~255) · IPv6(대괄호는 벗김) · 호스트 이름(영문·숫자·'-'·'_' 라벨을 '.' 로).
    /// "10.0.0.5:9090" 처럼 포트를 붙이면 nil — 포트는 원격 포트 칸에 쓴다.
    public static func remoteHost(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.lowercased() == "localhost" { return "127.0.0.1" }
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if text.contains(":") {
            // IPv6: 16진수·콜론(·끝 IPv4 의 점)만, 콜론 두 개 이상
            let ok = text.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") } && text.filter { $0 == ":" }.count >= 2
            return ok ? text : nil
        }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) {
            guard labels.count == 4, labels.allSatisfy({ $0.count <= 3 && Int($0)! <= 255 }) else { return nil }
            return text
        }
        guard text.count <= 253 else { return nil }
        func ok(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        let valid = labels.allSatisfy { label in
            guard let first = label.first, let last = label.last, label.count <= 63, ok(first), ok(last) else { return false }
            return label.allSatisfy { ok($0) || $0 == "-" || $0 == "_" }
        }
        return valid ? text : nil
    }
}

public enum PortAllocator {
    /// 1024 미만은 관리자 권한이 있어야 열 수 있다 (macOS 에서 bind 가 EACCES).
    public static func isPrivileged(_ port: Int) -> Bool { port < 1024 }

    /// 원격 포트에 대응하는 로컬 포트 제안. 특권 포트는 +8000 관례(443→8443, 80→8080, 22→8022).
    public static func suggestedLocalPort(forRemote port: Int) -> Int {
        guard isPrivileged(port) else { return port }
        return port + 8000
    }

    /// preferred 부터 올라가며 taken 에 없고 127.0.0.1 에 바인딩 가능한 첫 포트. 없으면 nil.
    /// preferred 가 특권 포트면 제안 포트부터 시작한다.
    public static func nextFree(preferred: Int, taken: Set<Int>, address: String = "127.0.0.1", limit: Int = 200) -> Int? {
        let start = isPrivileged(preferred) ? suggestedLocalPort(forRemote: preferred) : preferred
        var port = start
        while port <= 65535, port < start + limit {
            if !taken.contains(port), isFree(port, address: address) { return port }
            port += 1
        }
        return nil
    }

    /// address:port 에 bind 가 되는가 (되면 비어 있음). 확인 후 바로 닫는다. 주소가 다르면 같은 포트도 따로 센다 (127.0.0.2:5432 등).
    /// SO_REUSEADDR 를 켜지 않는다: 켜면 0.0.0.0 에 LISTEN 중인 포트도 "비어 있음" 으로 보여 로컬 서비스 트래픽을 가로챈다.
    public static func isFree(_ port: Int, address: String = "127.0.0.1") -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(address)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // 루프백 별칭이 아직 없는 주소(127.0.0.x, 인증 뒤에 붙는다)는 bind 가 EADDRNOTAVAIL 로 실패하지만 쓰는 프로그램도 없다 → 비어 있음
        return result == 0 || errno == EADDRNOTAVAIL
    }
}
