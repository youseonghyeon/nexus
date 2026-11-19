// 서버 시점 진단 (2026-11-18, 원격 정보 카드의 Diagnose 탭 — linux 만): 같은 대상을 이 Mac 과 그 서버에서 한 번씩 재서 나란히 보인다.
// "내 쪽에선 되는데 서버에선 안 됨"(방화벽·경로·DNS)을 한 화면에서 가르려는 것. 도구는 ping · TCP · HTTP · DNS.
//   이 Mac: 기본 경로로 (장치에 묶지 않는다 — 터미널에서 직접 친 것과 같다). ping · curl · dscacheutil · TCP 연결 한 번.
//   서버: ssh 로 `sh -s` 에 스크립트를 넘긴다. ping · curl · getent ahosts · bash 의 /dev/tcp. 아무것도 설치하지 않고, 없는 도구는 "없음"으로 알린다.
// 서버는 보내기만 한다 (설정을 바꾸지 않는다). 대상은 입력창 검사(PingTest·TCPPortTest·HTTPTest·DNSLookup)를 거친 뒤 작은따옴표로 싸서 넣는다.
// 서버 스크립트의 실제 출력: Tests/…/Fixtures/diagnose-*.txt (2026-11-18, 로컬 docker ubuntu:24.04 — 서버 아님).

import Foundation

public enum ServerDiagnose {
    public enum Tool: String, CaseIterable, Sendable {
        case ping, tcp, http, dns
        public var title: String { self == .ping ? "ping" : rawValue.uppercased() }
        /// 입력칸의 자리 글
        public var placeholder: String {
            switch self {
            case .ping: return "주소 · 이름"
            case .tcp: return "IP:포트"
            case .http: return "URL"
            case .dns: return "이름"
            }
        }
    }

    /// 검사를 거친 대상
    public struct Request: Sendable, Equatable {
        public let tool: Tool
        /// ping: 주소·이름 · tcp: "IP:포트" · http: URL(스킴 포함) · dns: 이름
        public let target: String
        /// tcp 만
        let host: String
        let port: Int
    }

    /// 입력 → 요청. 꼴이 틀리면 nil (버튼 비활성)
    public static func request(_ tool: Tool, input: String) -> Request? {
        switch tool {
        case .ping: return PingTest.target(input).map { Request(tool: tool, target: $0, host: "", port: 0) }
        case .tcp: return TCPPortTest.target(input).map { Request(tool: tool, target: "\($0.host):\($0.port)", host: $0.host, port: $0.port) }
        case .http: return HTTPTest.url(input).map { Request(tool: tool, target: $0, host: "", port: 0) }
        case .dns: return DNSLookup.name(input).map { Request(tool: tool, target: $0, host: "", port: 0) }
        }
    }

    // MARK: 결과

    public struct Outcome: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case ok, failed
            /// 재지 못했다 (도구 없음 · 접속 실패) — 비교하지 않는다
            case unavailable
        }
        public var state: State
        /// 한 줄 결론: "12.3 ms" · "열림 · 3 ms" · "200 성공 · 308 ms" · "192.0.2.10"
        public var headline: String
        /// 덧붙는 줄 (연결된 주소 · 단계별 시간 · curl 문장)
        public var lines: [String] = []
        /// dns: 풀린 주소들 · http: 연결된 주소 하나 (양쪽 비교에 쓴다)
        public var addresses: [String] = []
        /// http: 상태 코드
        public var status: Int?

        public init(state: State, headline: String, lines: [String] = [], addresses: [String] = [], status: Int? = nil) {
            self.state = state; self.headline = headline; self.lines = lines; self.addresses = addresses; self.status = status
        }
    }

    /// 양쪽을 놓고 본 한 줄
    public struct Verdict: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case same, differs, macOnly, serverOnly, neither, unknown }
        public let kind: Kind
        public let text: String
        /// 눈여겨볼 결과인가 (한쪽만 되거나 답이 다르다)
        public var notable: Bool { kind == .differs || kind == .macOnly || kind == .serverOnly }
    }

    public static func verdict(_ tool: Tool, mac: Outcome, server: Outcome, serverKey: String) -> Verdict {
        if mac.state == .unavailable || server.state == .unavailable {
            return Verdict(kind: .unknown, text: "한쪽을 재지 못해 비교하지 않았습니다")
        }
        switch (mac.state == .ok, server.state == .ok) {
        case (true, false): return Verdict(kind: .macOnly, text: "이 Mac 에서는 되고 \(serverKey) 에서는 안 됩니다")
        case (false, true): return Verdict(kind: .serverOnly, text: "\(serverKey) 에서는 되고 이 Mac 에서는 안 됩니다")
        case (false, false): return Verdict(kind: .neither, text: "양쪽 다 안 됩니다")
        case (true, true):
            if tool == .dns, Set(mac.addresses) != Set(server.addresses) {
                return Verdict(kind: .differs, text: "양쪽이 다른 주소로 풉니다")
            }
            if tool == .http, let a = mac.status, let b = server.status, a != b {
                return Verdict(kind: .differs, text: "상태 코드가 다릅니다 (이 Mac \(a) · \(serverKey) \(b))")
            }
            if tool == .http, let a = mac.addresses.first, let b = server.addresses.first, a != b {
                return Verdict(kind: .differs, text: "양쪽 다 되지만 붙은 주소가 다릅니다")
            }
            return Verdict(kind: .same, text: "양쪽 다 됩니다")
        }
    }

    // MARK: 서버에서

    /// `sh -s` 에 넘길 스크립트. 줄 끝의 @RC(종료 코드)·@MS(걸린 ms)·@MISSING(없는 도구)로 결과를 가른다.
    public static func script(_ request: Request) -> String {
        let target = shellQuote(request.target)
        switch request.tool {
        case .ping:
            return """
                command -v ping >/dev/null 2>&1 || { echo "@MISSING ping"; exit 0; }
                LC_ALL=C ping -c \(PingTest.count) -i 0.2 -W 1 \(target) 2>&1
                echo "@RC $?"
                """
        case .tcp:
            // 0 열림 · 124 시간 초과(막힘) · 그 밖 거부(닫힘). 주소는 IPv4, 포트는 숫자뿐이라 따옴표 없이 넣는다 (TCPPortTest.target)
            return """
                command -v bash >/dev/null 2>&1 || { echo "@MISSING bash"; exit 0; }
                command -v timeout >/dev/null 2>&1 || { echo "@MISSING timeout"; exit 0; }
                s=$(date +%s%N)
                timeout \(Int(TCPPortTest.timeout)) bash -c 'exec 3<>/dev/tcp/\(request.host)/\(request.port)' 2>/dev/null
                rc=$?
                e=$(date +%s%N)
                echo "@RC $rc"
                case "$s$e" in *[!0-9]*) ;; *) echo "@MS $(( (e - s) / 1000000 ))" ;; esac
                """
        case .http:
            return """
                command -v curl >/dev/null 2>&1 || { echo "@MISSING curl"; exit 0; }
                curl -sS -g -o /dev/null --proto =http,https --noproxy '*' --connect-timeout \(HTTPTest.connectTimeout) --max-time \(HTTPTest.maxTime) -w '\(HTTPTest.format)' \(target) 2>&1
                echo "@RC $?"
                """
        case .dns:
            // 서버의 프로그램들이 보는 그대로 (nsswitch — /etc/hosts · 리졸버). 2 = 없는 이름
            return """
                command -v getent >/dev/null 2>&1 || { echo "@MISSING getent"; exit 0; }
                s=$(date +%s%N)
                getent ahosts \(target) 2>/dev/null
                rc=$?
                e=$(date +%s%N)
                echo "@RC $rc"
                case "$s$e" in *[!0-9]*) ;; *) echo "@MS $(( (e - s) / 1000000 ))" ;; esac
                """
        }
    }

    /// 서버 스크립트의 출력 → 결과. ssh 가 실패했으면(ok=false) failure 문구로 "재지 못함".
    public static func parseServer(_ request: Request, output: String, ok: Bool, failure: String? = nil) -> Outcome {
        var body: [String] = [], rc: Int?, ms: Int?, missing: String?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("@RC ") { rc = Int(line.dropFirst(4).trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix("@MS ") { ms = Int(line.dropFirst(4).trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix("@MISSING ") { missing = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            else { body.append(line) }
        }
        if let missing { return Outcome(state: .unavailable, headline: "서버에 \(missing) 이(가) 없습니다") }
        guard ok, let rc else { return Outcome(state: .unavailable, headline: failure ?? "서버에서 실행하지 못했습니다") }
        let text = body.joined(separator: "\n")
        switch request.tool {
        case .ping: return ping(text)
        case .tcp:
            switch rc {
            case 0: return Outcome(state: .ok, headline: "열림" + (ms.map { " · \($0) ms" } ?? ""))
            case 124: return Outcome(state: .failed, headline: "응답 없음 (막힘 · 시간 초과)")
            default: return Outcome(state: .failed, headline: "거부됨 (닫힘)")
            }
        case .http:
            // 옛 curl(7.75 앞)은 %{exitcode} 를 몰라 exit= 줄이 비어 온다 — 셸이 준 종료 코드로 채운다
            let patched = body.map { $0 == "exit=" ? "exit=\(rc)" : $0 }.joined(separator: "\n")
            guard let check = HTTPTest.parse(patched) else { return Outcome(state: .unavailable, headline: "curl 출력을 읽지 못했습니다") }
            return http(check)
        case .dns:
            return dns(addresses: getentAddresses(text), ms: ms)
        }
    }

    /// getent ahosts 출력 ("192.0.2.10   STREAM name" · DGRAM · RAW 가 주소마다 한 줄씩) → 겹치지 않는 주소, 나온 순서
    static func getentAddresses(_ text: String) -> [String] {
        var seen: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
                  first.contains(".") || first.contains(":"), !seen.contains(first) else { continue }
            seen.append(first)
        }
        return seen
    }

    // MARK: 이 Mac 에서

    /// 이 Mac 에서 같은 대상을 잰다 (기본 경로). tcp 는 연결 한 번 — 테스트는 tcpConnect 를 바꿔 넣는다.
    public static func runLocal(_ request: Request, runner: any CommandRunner,
                                tcpConnect: @Sendable (String, Int) async -> Bool = { host, port in
                                    await TCPProbe.connect(host: host, port: port, timeout: TCPPortTest.timeout, device: nil)
                                }) async -> Outcome {
        switch request.tool {
        case .ping:
            let result = await runner.run("ping", ["-c", "\(PingTest.count)", "-i", "0.2", "-W", "1000", request.target], timeout: 15)
            return ping(result.stdout + result.stderr)
        case .tcp:
            let started = Date()
            let open = await tcpConnect(request.host, request.port)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            // 이 Mac 의 연결 확인은 열림/아님만 안다 (거부와 막힘을 가르지 않는다 — TCPProbe)
            return open ? Outcome(state: .ok, headline: "열림 · \(ms) ms") : Outcome(state: .failed, headline: "응답 없음 (닫힘 · 막힘)")
        case .http:
            let arguments = ["-sS", "-g", "-o", "/dev/null", "--proto", "=http,https", "--noproxy", "*",
                             "--connect-timeout", "\(HTTPTest.connectTimeout)", "--max-time", "\(HTTPTest.maxTime)", "-w", HTTPTest.format, request.target]
            let result = await runner.run("curl", arguments, timeout: TimeInterval(HTTPTest.maxTime + 5))
            guard let check = HTTPTest.parse(result.stdout) else { return Outcome(state: .unavailable, headline: "curl 을 실행하지 못했습니다") }
            return http(check)
        case .dns:
            // 이 Mac 의 프로그램들이 보는 그대로 (/etc/hosts · 시스템 리졸버) — 서버의 getent 와 같은 층
            let started = Date()
            let result = await runner.run("dscacheutil", ["-q", "host", "-a", "name", request.target], timeout: 10)
            guard result.exitCode != CommandResult.timedOutExitCode else { return Outcome(state: .failed, headline: "응답 없음 (시간 초과)") }
            return dns(addresses: dscacheutilAddresses(result.stdout), ms: Int(Date().timeIntervalSince(started) * 1000))
        }
    }

    /// dscacheutil -q host 출력의 "ip_address: …" · "ipv6_address: …" 줄 → 겹치지 않는 주소, 나온 순서
    static func dscacheutilAddresses(_ text: String) -> [String] {
        var seen: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "ip_address" || parts[0] == "ipv6_address", !parts[1].isEmpty, !seen.contains(parts[1]) else { continue }
            seen.append(parts[1])
        }
        return seen
    }

    // MARK: 양쪽이 같이 쓰는 풀이

    /// ping 출력 (macOS · Linux 요약 줄이 같은 꼴 — NetworkProbe.parsePing)
    static func ping(_ output: String) -> Outcome {
        let unresolved = PingTest.resolveFailed(output) || output.contains("Name or service not known") || output.contains("failure in name resolution")
        if unresolved { return Outcome(state: .failed, headline: "이름을 찾지 못했습니다") }
        let summary = NetworkProbe.parsePing(output)
        return Outcome(state: summary.averageMs == nil ? .failed : .ok, headline: summary.text)
    }

    static func http(_ check: HTTPCheck) -> Outcome {
        var lines: [String] = []
        if let endpoint = check.endpoint { lines.append("연결 \(endpoint)") }
        if let redirect = check.redirect { lines.append("이동 \(redirect)") }
        if let stages = check.stages, stages.dnsMs != nil || stages.connectMs != nil { lines.append(stages.text) }
        if let failure = check.failureText {
            if let error = check.error { lines.insert(error, at: 0) }
            return Outcome(state: .failed, headline: failure, lines: lines)
        }
        guard let status = check.status else { return Outcome(state: .failed, headline: "응답 없음", lines: lines) }
        var headline = "\(status)" + (HTTPTest.statusKind(status).map { " \($0)" } ?? "")
        if let stages = check.stages { headline += " · \(stages.totalText)" }
        if let note = check.bodyNote { lines.insert(note, at: 0) }
        // 응답을 받았으면 된 것이다 (4xx·5xx 도 — 서버가 답했다. 코드가 다르면 verdict 가 알린다)
        return Outcome(state: .ok, headline: headline, lines: lines, addresses: check.remoteIP.map { [$0] } ?? [], status: status)
    }

    static func dns(addresses: [String], ms: Int?) -> Outcome {
        guard !addresses.isEmpty else { return Outcome(state: .failed, headline: "이름을 찾지 못했습니다") }
        let shown = addresses.prefix(4).joined(separator: ", ") + (addresses.count > 4 ? " 외 \(addresses.count - 4)" : "")
        return Outcome(state: .ok, headline: shown, lines: ms.map { ["\($0) ms"] } ?? [], addresses: addresses)
    }

    // MARK: 한 번의 실행

    /// 한 번의 비교 (탭의 결과 한 칸). mac·server 가 nil 이면 그쪽은 재는 중.
    public struct Run: Sendable, Equatable {
        public let request: Request
        public let at: Date
        public var mac: Outcome?
        public var server: Outcome?

        public init(request: Request, at: Date = Date()) { self.request = request; self.at = at }

        public var running: Bool { mac == nil || server == nil }

        public func verdict(serverKey: String) -> Verdict? {
            guard let mac, let server else { return nil }
            return ServerDiagnose.verdict(request.tool, mac: mac, server: server, serverKey: serverKey)
        }

        /// [복사] 텍스트 — 화면과 같은 내용
        public func reportText(serverKey: String) -> String {
            var out = ["\(request.tool.title) \(request.target) · \(at.formatted(date: .abbreviated, time: .standard))"]
            for (name, outcome) in [("이 Mac", mac), (serverKey, server)] {
                guard let outcome else { out.append("\(name): 재는 중"); continue }
                out.append("\(name): \(outcome.headline)")
                out += outcome.lines.map { "  \($0)" }
            }
            if let verdict = verdict(serverKey: serverKey) { out.append("결과: \(verdict.text)") }
            return out.joined(separator: "\n")
        }
    }
}
