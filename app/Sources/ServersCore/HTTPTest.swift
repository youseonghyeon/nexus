// HTTP 확인 (Intranet·Wi-Fi·Ethernet 화면의 진단 카드): 입력한 URL 로 요청 한 번. 그 화면의 장치에 묶고(curl --interface) 프록시를 타지 않는다(--noproxy).
// 본문은 저장하지 않고(받아서 버림, 최대 maxTime 초) 상태 코드·리다이렉트 위치·단계별 시간·붙은 IP 만 본다. 리다이렉트는 따라가지 않는다 — 어디로 보내는지가 결과다.
// 인증서 검사는 끄지 않는다: 실패하면 "인증서 확인 실패" 로 보여 줄 뿐이다.
// 결과는 curl -w 의 key=value 줄 (exitcode·errormsg 는 curl 7.75+, 이 Mac 은 8.7.1). 실제 출력: Tests/…/Fixtures/http-curl-*.txt (2026-10-14, 공개·로컬 주소 — 내부망 아님).

import Foundation

public enum HTTPTest {
    public static let connectTimeout = 3
    public static let maxTime = 10

    static let format = "exit=%{exitcode}\\ncode=%{http_code}\\nscheme=%{scheme}\\nip=%{remote_ip}\\nport=%{remote_port}\\ndns=%{time_namelookup}\\nconnect=%{time_connect}\\ntls=%{time_appconnect}\\nfirst=%{time_starttransfer}\\ntotal=%{time_total}\\nredirect=%{redirect_url}\\nerror=%{errormsg}\\n"

    /// 입력 → 요청할 URL. 스킴이 없으면 http:// (curl 과 같음). http·https 만, 호스트 필수.
    /// 보이는 ASCII 만 (공백·제어·폭 없는 문자·한글 도메인 X — 경로의 한글은 %인코딩해 넣는다), 아이디·비밀번호(user:pw@)는 "대상" 줄에 보이므로 받지 않는다.
    public static func url(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2048,
              text.allSatisfy({ $0.asciiValue.map { $0 > 0x20 && $0 < 0x7f } ?? false }) else { return nil }
        // 스킴은 맨 앞에서만 본다 ("host/p?u=http://y" 는 스킴 없음). "http:/host" 처럼 스킴이 깨진 입력은 받지 않는다.
        let hasScheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        guard hasScheme || text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:/"#, options: .regularExpression) == nil else { return nil }
        let full = hasScheme ? text : "http://" + text
        guard let components = URLComponents(string: full),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return full
    }

    /// 상태 코드의 뜻 (영어 사유 문구 대신). 자주 보는 코드는 따로 — 400번대를 전부 "요청 거부"로 적으면 404(없음)도 거부로 읽혔다 (2026-11-10)
    public static func statusKind(_ status: Int) -> String? {
        switch status {
        case 100..<200: return "정보"
        case 200..<300: return "성공"
        case 300..<400: return "이동"
        case 400: return "잘못된 요청"
        case 401, 407: return "인증 필요"
        case 403: return "거부"
        case 404, 410: return "없음"
        case 405: return "허용 안 된 메서드"
        case 408: return "요청 시간 초과"
        case 429: return "요청 과다"
        case 400..<500: return "요청 오류"
        case 502: return "게이트웨이 오류"
        case 503: return "서비스 불가"
        case 504: return "게이트웨이 시간 초과"
        case 500..<600: return "서버 오류"
        default: return nil
        }
    }

    /// 요청 한 번 (device 에 묶음). 장치 이름이 이상하면 명령을 돌리지 않는다.
    public static func check(_ url: String, device: String, runner: any CommandRunner) async -> HTTPCheck {
        guard let bind = NetworkProbe.bindArguments(device, flag: "--interface") else {
            return HTTPCheck(exitCode: 45, error: "장치 이름이 올바르지 않습니다: \(device)")
        }
        // -g: [] {} 를 범위 문법으로 읽지 않게 (IPv6 주소) · --proto: http·https 밖으로 가지 않게
        let arguments = ["-sS", "-g", "-o", "/dev/null", "--proto", "=http,https", "--noproxy", "*",
                         "--connect-timeout", "\(connectTimeout)", "--max-time", "\(maxTime)"] + bind + ["-w", format, url]
        let result = await runner.run("curl", arguments, timeout: TimeInterval(maxTime + 5))
        if let check = parse(result.stdout) { return check }
        // -w 줄이 없다 = curl 이 끝나지 못했다 (앱 쪽 시간 초과 · curl 없음) — curl 종료 코드가 아니므로 따로 적는다
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = result.exitCode == CommandResult.timedOutExitCode ? "응답 없음 (앱 시간 초과)"
            : "curl 을 실행하지 못했습니다 (종료 코드 \(result.exitCode))"
        return HTTPCheck(exitCode: Int(result.exitCode), error: message.isEmpty ? nil : message, runFailure: failure)
    }

    /// curl -w 출력 → 결과. exit= 줄이 없으면 nil.
    public static func parse(_ text: String) -> HTTPCheck? {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            values[String(raw[..<eq])] = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let exit = values["exit"].flatMap({ Int($0) }) else { return nil }
        func seconds(_ key: String) -> Double { values[key].flatMap(Double.init) ?? 0 }
        func field(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
        let status = values["code"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        let port = values["port"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        return HTTPCheck(exitCode: exit, status: status, https: values["scheme"]?.lowercased() == "https", remoteIP: field("ip"), remotePort: port,
                         stages: HTTPStages(dns: seconds("dns"), connect: seconds("connect"), tls: seconds("tls"),
                                            firstByte: seconds("first"), total: seconds("total")),
                         redirect: field("redirect"), error: field("error"))
    }
}

/// curl 의 누적 시각(초) → 단계별 걸린 시간(ms). 가지 못한 단계는 nil.
/// 화면 표기는 영어 (DNS·TCP·TLS·TTFB·Download·Total — 개발자 도구와 같은 말, 2026-10-14 사용자 결정).
public struct HTTPStages: Sendable, Equatable {
    public var dnsMs: Double?
    public var connectMs: Double?
    public var tlsMs: Double?
    /// 요청을 보낸 뒤 첫 바이트까지 (서버 처리 시간, TTFB)
    public var waitMs: Double?
    /// 첫 바이트부터 끝까지 (본문 받기)
    public var downloadMs: Double?
    public var totalMs: Double

    public init(dns: Double, connect: Double, tls: Double, firstByte: Double, total: Double) {
        dnsMs = dns > 0 ? dns * 1000 : nil
        connectMs = connect > 0 ? (connect - dns) * 1000 : nil
        tlsMs = tls > 0 && connect > 0 ? (tls - connect) * 1000 : nil
        waitMs = firstByte > 0 ? (firstByte - max(tls, connect)) * 1000 : nil
        downloadMs = firstByte > 0 ? max(0, total - firstByte) * 1000 : nil
        totalMs = total * 1000
    }

    /// 단계 하나 (화면의 시간 막대 · 범례)
    public struct Segment: Sendable, Equatable, Identifiable {
        public var id: String { name }
        /// "DNS" · "TCP" · "TLS" · "TTFB" · "Download"
        public let name: String
        public let ms: Double
        /// "1.5 ms" · "265 ms"
        public var text: String { HTTPStages.msText(ms) }
        /// 마우스를 올렸을 때 뜨는 풀이: "TTFB 265 ms — 요청을 보낸 뒤 첫 응답까지 (서버가 답을 만드는 시간)"
        public var help: String {
            let meaning: String
            switch name {
            case "DNS": meaning = "이름을 IP 로 바꾸는 시간"
            case "TCP": meaning = "서버와 연결을 맺는 시간"
            case "TLS": meaning = "암호화 연결을 맺는 시간 (인증서 확인 포함)"
            case "TTFB": meaning = "요청을 보낸 뒤 첫 응답까지 (서버가 답을 만드는 시간)"
            case "Download": meaning = "응답 본문을 받는 시간"
            default: return "\(name) \(text)"
            }
            return "\(name) \(text) — \(meaning)"
        }
    }

    /// 잰 단계만, 일어난 순서대로. 시계 오차로 음수가 된 값은 0 으로 (막대 길이가 음수가 되지 않게)
    public var segments: [Segment] {
        let all: [(String, Double?)] = [("DNS", dnsMs), ("TCP", connectMs), ("TLS", tlsMs), ("TTFB", waitMs), ("Download", downloadMs)]
        return all.compactMap { name, ms in ms.map { Segment(name: name, ms: max(0, $0)) } }
    }

    /// "308 ms"
    public var totalText: String { Self.msText(totalMs) }

    static func msText(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v) }

    /// "DNS 2.0 ms · TCP 25 ms · TLS 36 ms · TTFB 43 ms · Download 4.0 ms · Total 110 ms" (복사용 보고 글)
    public var text: String {
        (segments.map { "\($0.name) \($0.text)" } + ["Total \(totalText)"]).joined(separator: " · ")
    }
}

public struct HTTPCheck: Sendable, Equatable {
    /// curl 종료 코드 (0 = 응답 받음 — 4xx·5xx 도 0)
    public var exitCode: Int
    /// HTTP 상태 코드 (응답을 못 받았으면 nil)
    public var status: Int?
    /// 연결된 스킴이 https 인가 (연결 전에 실패하면 curl 이 비워 줘서 false)
    public var https: Bool
    public var remoteIP: String?
    public var remotePort: Int?
    public var stages: HTTPStages?
    public var redirect: String?
    /// curl 의 오류 문장 (영어 그대로 — 원인 확인용)
    public var error: String?
    /// curl 이 끝나지 못했을 때의 한 줄 (앱 쪽 시간 초과 · curl 없음) — 있으면 curl 종료 코드보다 먼저
    public var runFailure: String?

    public init(exitCode: Int, status: Int? = nil, https: Bool = false, remoteIP: String? = nil, remotePort: Int? = nil,
                stages: HTTPStages? = nil, redirect: String? = nil, error: String? = nil, runFailure: String? = nil) {
        self.exitCode = exitCode; self.status = status; self.https = https; self.remoteIP = remoteIP; self.remotePort = remotePort
        self.stages = stages; self.redirect = redirect; self.error = error; self.runFailure = runFailure
    }

    /// 실패 한 줄 (상태 코드를 받았으면 nil — 본문 쪽 문제는 bodyNote). 시간 초과는 어느 단계까지 갔는지로 가른다.
    public var failureText: String? {
        if let runFailure { return runFailure }
        guard status == nil else { return nil }
        switch exitCode {
        case 60, 51, 58, 77, 83, 90, 91: return "인증서 확인 실패"
        case 35: return "TLS 연결 실패"
        case 6: return "이름을 찾지 못했습니다"
        case 7: return "연결 실패"   // 거부·경로 없음·호스트 꺼짐이 다 7 — 원인은 상세 줄의 curl 문장
        case 28:
            // --connect-timeout 은 TLS 핸드셰이크까지 포함한다
            if stages?.connectMs == nil { return "연결 실패 (시간 초과)" }
            if https, stages?.tlsMs == nil { return "TLS 연결 실패 (시간 초과)" }
            return "응답 없음 (\(HTTPTest.maxTime)초 초과)"
        case 45: return "장치에 묶지 못했습니다"
        case 52: return "빈 응답 (서버가 아무것도 보내지 않음)"
        case 56: return "응답 받는 중 연결이 끊겼습니다"
        default: return "실패 (curl 종료 코드 \(exitCode))"
        }
    }

    /// 상태 코드는 받았는데 본문을 끝까지 못 받은 경우의 한 줄 (본문은 받아서 버린다 — 큰 파일이면 maxTime 에 걸린다)
    public var bodyNote: String? {
        guard runFailure == nil, status != nil, exitCode != 0 else { return nil }
        switch exitCode {
        case 28: return "본문 받는 중 시간 초과 (\(HTTPTest.maxTime)초)"
        case 18: return "본문이 덜 왔습니다"
        case 56: return "본문 받는 중 연결이 끊겼습니다"
        default: return "본문 받는 중 실패 (curl 종료 코드 \(exitCode))"
        }
    }

    /// "10.50.10.17:443"
    public var endpoint: String? {
        guard let ip = remoteIP else { return nil }
        let host = ip.contains(":") ? "[\(ip)]" : ip
        return remotePort.map { "\(host):\($0)" } ?? host
    }
}

/// 한 번의 HTTP 확인 (Intranet·Wi-Fi·Ethernet 화면의 진단 카드). check 가 nil 이면 요청 중.
public struct HTTPTestResult: Sendable, Equatable {
    public let url: String
    /// 보낸 장치 (PingTestResult.device 와 같은 쓰임)
    public let device: String
    public let at: Date
    public var check: HTTPCheck?

    public init(url: String, device: String, at: Date = Date()) {
        self.url = url; self.device = device; self.at = at
    }
}

extension HTTPTestResult {
    /// [복사] 텍스트 — 화면과 같은 내용
    public var reportText: String {
        var lines = ["HTTP \(url) · \(device) · \(at.formatted(date: .abbreviated, time: .standard))"]
        guard let check else { return (lines + ["결과: 요청 중"]).joined(separator: "\n") }
        if let failure = check.failureText {
            lines.append("결과: \(failure)")
        } else if let status = check.status {
            var text = "결과: \(status)"
            if let kind = HTTPTest.statusKind(status) { text += " \(kind)" }
            if let note = check.bodyNote { text += " · \(note)" }
            lines.append(text)
        }
        if check.failureText != nil || check.bodyNote != nil, let error = check.error { lines.append("상세: \(error)") }
        if let redirect = check.redirect { lines.append("이동: \(redirect)") }
        if let endpoint = check.endpoint { lines.append("연결: \(endpoint)") }
        if let stages = check.stages, stages.dnsMs != nil { lines.append("시간: \(stages.text)") }
        return lines.joined(separator: "\n")
    }
}
