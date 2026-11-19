// 서버 시점 진단 (2026-11-18, 원격 정보 카드의 Diagnose 탭 — linux · openwrt): 대상을 넣으면 그 서버에서 재서 보인다 — 서버에 들어가 직접 쳐 보던 것을 대신한다.
// 도구는 ping · TCP · HTTP · DNS. 처음엔 이 Mac 에서도 같이 재서 나란히 보였는데 서버 쪽만 있으면 된다고 해 뺐다 (2026-11-18 사용자 결정 — 이 Mac 쪽은 망 화면의 진단 카드).
//   ssh 로 `sh -s` 에 스크립트를 넘긴다. ping · curl · getent ahosts · bash 의 /dev/tcp. 아무것도 설치하지 않고, 없는 도구는 "없음"으로 알린다.
// 서버는 보내기만 한다 (설정을 바꾸지 않는다). 대상은 입력창 검사(PingTest·TCPPortTest·HTTPTest·DNSLookup)를 거친 뒤 작은따옴표로 싸서 넣는다.
// 서버 스크립트의 실제 출력: Tests/…/Fixtures/diagnose-*.txt (2026-11-18, 로컬 docker ubuntu:24.04 — 서버 아님).

import Foundation

public enum ServerDiagnose {
    public enum Tool: String, CaseIterable, Sendable {
        case ping, tcp, http, dns
        public var title: String { self == .ping ? "ping" : rawValue.uppercased() }
        /// 입력칸의 자리 글 (망 화면의 진단 카드와 같은 말)
        public var placeholder: String {
            switch self {
            case .ping: return "IP 또는 이름"
            case .tcp: return "IPv4:포트 (예: 192.0.2.10:22)"
            case .http: return "URL (http:// 생략 가능)"
            case .dns: return "이름 (예: www.example.com)"
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
            /// 재지 못했다 (도구 없음 · 접속 실패) — 서버에서 안 되는 것과는 다르다
            case unavailable
        }
        public var state: State
        /// 결과 줄: "12.3 ms · Jitter 0.4 ms" · "열림 · 3 ms" · "200 성공" · "192.0.2.10" (dns 는 IPv4 만 — IPv6 는 아랫줄)
        public var headline: String
        /// [복사] 텍스트에 덧붙는 줄 ("연결: 192.0.2.10:443" — 화면은 망 화면의 진단 카드와 같은 줄로 따로 그린다: check · ms · addresses6)
        public var lines: [String] = []
        /// dns: 풀린 주소들 · http: 연결된 주소 하나
        public var addresses: [String] = []
        /// http: 상태 코드
        public var status: Int?
        /// http: curl 이 준 값 그대로 — 화면이 진단 카드와 같은 줄(결과 · 상세 · 이동 · 연결 · 시간 막대)로 그린다
        public var check: HTTPCheck?
        /// dns: 걸린 시간 (결과 줄 옆 작은 글씨)
        public var ms: Int?

        /// dns: IPv6 주소 (진단 카드처럼 IPv6 줄로 따로)
        public var addresses6: [String] { addresses.filter { $0.contains(":") } }

        public init(state: State, headline: String, lines: [String] = [], addresses: [String] = [], status: Int? = nil,
                    check: HTTPCheck? = nil, ms: Int? = nil) {
            self.state = state; self.headline = headline; self.lines = lines; self.addresses = addresses; self.status = status
            self.check = check; self.ms = ms
        }
    }

    // MARK: 서버에서

    /// `sh -s` 에 넘길 스크립트. 줄 끝의 @RC(종료 코드)·@MS(걸린 ms)·@MISSING(없는 도구)로 결과를 가른다.
    /// openwrt 는 BusyBox 라 따로 (openwrtScript) — bash · timeout · getent 가 없고 ping 은 소수 간격을 모른다.
    public static func script(_ request: Request, type: ServerType = .linux) -> String {
        if type == .openwrt, let script = openwrtScript(request) { return script }
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

    /// OpenWrt(BusyBox) 용 — http 는 linux 와 같은 스크립트라 nil (curl 은 기본으로 없다: 있으면 재고 없으면 없다고 알린다).
    /// 실제 출력: Fixtures/diagnose-openwrt-*.txt (2026-11-18, 로컬 docker openwrt/rootfs:x86-64-23.05.5 — BusyBox 1.36.1).
    static func openwrtScript(_ request: Request) -> String? {
        let target = shellQuote(request.target)
        switch request.tool {
        case .ping:
            // BusyBox ping 은 -i 0.2 를 못 읽는다 ("invalid number") — 1초 간격 그대로
            return """
                command -v ping >/dev/null 2>&1 || { echo "@MISSING ping"; exit 0; }
                LC_ALL=C ping -c \(PingTest.count) -W 1 \(target) 2>&1
                echo "@RC $?"
                """
        case .tcp:
            // nc 는 "nc 주소 포트" 뿐이고 timeout 도 없다 — 뒤에서 돌리고 \(Int(TCPPortTest.timeout))초 기다린다. 끝났으면 0 열림 · 그 밖 거부.
            // 안 끝났으면 막힘(124) — 붙었는데 상대가 끊지 않는 것은 netstat 의 ESTABLISHED 로 가려 열림. sleep 이 소수를 모르면 1초씩.
            // 걸린 시간은 재지 않는다 (date 에 나노초가 없고, 기다리는 간격이 섞인다)
            let seconds = Int(TCPPortTest.timeout)
            return """
                command -v nc >/dev/null 2>&1 || { echo "@MISSING nc"; exit 0; }
                nc \(request.host) \(request.port) </dev/null >/dev/null 2>&1 &
                p=$!
                if sleep 0.1 2>/dev/null; then step=0.1; max=\(seconds * 10); else step=1; max=\(seconds); fi
                i=0
                while kill -0 $p 2>/dev/null && [ $i -lt $max ]; do sleep $step; i=$((i + 1)); done
                if kill -0 $p 2>/dev/null; then
                  rc=124
                  netstat -tn 2>/dev/null | grep -q "[ :]\(request.host):\(request.port) .*ESTABLISHED" && rc=0
                  kill $p 2>/dev/null
                else
                  wait $p; rc=$?
                fi
                echo "@RC $rc"
                """
        case .http:
            return nil
        case .dns:
            // 공유기의 리졸버(dnsmasq)에 묻는다. 없는 이름은 Name 줄이 없다
            return """
                command -v nslookup >/dev/null 2>&1 || { echo "@MISSING nslookup"; exit 0; }
                nslookup \(target) 2>&1
                echo "@RC $?"
                """
        }
    }

    /// 서버 스크립트의 출력 → 결과. ssh 가 실패했으면(ok=false) failure 문구로 "재지 못함".
    public static func parseServer(_ request: Request, output: String, ok: Bool, failure: String? = nil, type: ServerType = .linux) -> Outcome {
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
            return dns(addresses: type == .openwrt ? nslookupAddresses(text) : getentAddresses(text), ms: ms)
        }
    }

    /// BusyBox nslookup 출력 → 풀린 주소. 앞머리의 "Server · Address"(물어본 리졸버)는 버리고 Name 줄 뒤의 Address 만.
    /// 새 꼴 "Address: 192.0.2.10" · 옛 꼴 "Address 1: 192.0.2.10 이름" 둘 다
    static func nslookupAddresses(_ text: String) -> [String] {
        var seen: [String] = [], named = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Name:") { named = true; continue }
            guard named, line.hasPrefix("Address"), let colon = line.range(of: ": ") else { continue }
            guard let address = line[colon.upperBound...].split(separator: " ").first.map(String.init),
                  address.contains(".") || address.contains(":"), !seen.contains(address) else { continue }
            seen.append(address)
        }
        return seen
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

    // MARK: 출력 풀이

    /// 이름이 안 풀렸을 때의 결과 줄 (ping · dns) — 화면이 진단 카드처럼 흐리게 그린다
    public static let unresolvedText = "이름을 찾지 못했습니다"

    /// ping 출력 (Linux 요약 줄도 macOS 와 같은 꼴 — NetworkProbe.parsePing)
    static func ping(_ output: String) -> Outcome {
        let unresolved = PingTest.resolveFailed(output) || output.contains("Name or service not known") || output.contains("failure in name resolution")
            || output.contains("ping: bad address")   // BusyBox
        if unresolved { return Outcome(state: .failed, headline: unresolvedText) }
        let summary = NetworkProbe.parsePing(output)
        return Outcome(state: summary.averageMs == nil ? .failed : .ok, headline: summary.text)
    }

    /// 결과 줄·덧붙는 줄은 진단 카드의 [복사] 텍스트와 같은 말·같은 순서 (HTTPTestResult.reportText)
    static func http(_ check: HTTPCheck) -> Outcome {
        var lines: [String] = []
        if check.failureText != nil || check.bodyNote != nil, let error = check.error { lines.append("상세: \(error)") }
        if let redirect = check.redirect { lines.append("이동: \(redirect)") }
        if let endpoint = check.endpoint { lines.append("연결: \(endpoint)") }
        if let stages = check.stages, stages.dnsMs != nil { lines.append("시간: \(stages.text)") }
        if let failure = check.failureText { return Outcome(state: .failed, headline: failure, lines: lines, check: check) }
        guard let status = check.status else { return Outcome(state: .failed, headline: "응답 없음", lines: lines, check: check) }
        var headline = "\(status)" + (HTTPTest.statusKind(status).map { " \($0)" } ?? "")
        if let note = check.bodyNote { headline += " · \(note)" }
        // 응답을 받았으면 된 것이다 (4xx·5xx 도 — 상대가 답했다. 코드는 결과 줄에 있다)
        return Outcome(state: .ok, headline: headline, lines: lines, addresses: check.remoteIP.map { [$0] } ?? [], status: status, check: check)
    }

    static func dns(addresses: [String], ms: Int?) -> Outcome {
        guard !addresses.isEmpty else { return Outcome(state: .failed, headline: unresolvedText) }
        let v4 = addresses.filter { !$0.contains(":") }, v6 = addresses.filter { $0.contains(":") }
        let shown = v4.isEmpty ? "IPv4 주소 없음" : v4.prefix(4).joined(separator: ", ") + (v4.count > 4 ? " 외 \(v4.count - 4)" : "")
        return Outcome(state: .ok, headline: shown, lines: v6.isEmpty ? [] : ["IPv6: \(v6.joined(separator: ", "))"], addresses: addresses, ms: ms)
    }

    // MARK: 한 번의 실행

    /// 한 번의 실행 (탭의 결과 한 칸). outcome 이 nil 이면 재는 중.
    public struct Run: Sendable, Equatable {
        public let request: Request
        public let at: Date
        public var outcome: Outcome?

        public init(request: Request, at: Date = Date()) { self.request = request; self.at = at }

        public var running: Bool { outcome == nil }

        /// [복사] 텍스트 — 화면과 같은 내용
        public func reportText(serverKey: String) -> String {
            var out = ["\(request.tool.title) \(request.target) · \(serverKey) 에서 · \(at.formatted(date: .abbreviated, time: .standard))"]
            guard let outcome else { return (out + ["결과: 재는 중"]).joined(separator: "\n") }
            out.append("결과: \(outcome.headline)" + (outcome.ms.map { " · \($0) ms" } ?? ""))
            out += outcome.lines
            return out.joined(separator: "\n")
        }
    }
}
