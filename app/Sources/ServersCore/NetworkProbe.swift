// 망 Dashboard 의 살아 있는 값들. 이 Mac 의 명령만 쓴다 (route·ifconfig·netstat·ping·curl·networkQuality).
// 파서는 전부 static 이라 가짜 출력으로 테스트한다. 서버에는 접속하지 않는다.
//   DefaultRoute      인터넷이 어느 인터페이스·게이트웨이로 나가는가
//   LinkMedia         링크 속도·상태 (1000baseT <full-duplex> · active)
//   InterfaceCounters 인터페이스 누적 바이트 → TrafficRate 로 초당 속도
//   PingSummary       ping 요약 (평균·손실·지터)
//   InternetProbe     204 엔드포인트에 병렬 HTTPS: 평균 연결 시간·손실·지터 (net.zsh 와 같은 방식)
//   SpeedTest         networkQuality (-s 순차, -M 3초, 회선을 가득 채우므로 버튼으로만)

import Foundation

public struct DefaultRoute: Sendable, Equatable {
    public let interface: String?
    public let gateway: String?
    public init(interface: String?, gateway: String?) {
        self.interface = interface
        self.gateway = gateway
    }
    public var isEmpty: Bool { interface == nil && gateway == nil }
}

public struct LinkMedia: Sendable, Equatable {
    /// "1000baseT <full-duplex>" 처럼 autoselect 괄호를 벗긴 값
    public let media: String?
    /// "active" / "inactive"
    public let status: String?
    public init(media: String?, status: String?) {
        self.media = media
        self.status = status
    }
}

public struct InterfaceCounters: Sendable, Equatable {
    public let rxBytes: UInt64
    public let txBytes: UInt64
    public let at: Date
    public init(rxBytes: UInt64, txBytes: UInt64, at: Date = Date()) {
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.at = at
    }
}

public struct TrafficRate: Sendable, Equatable {
    public let rxPerSecond: Double
    public let txPerSecond: Double

    /// 두 표본의 차이. 카운터가 줄었거나(재설정) 간격이 0 이면 nil.
    public static func between(_ previous: InterfaceCounters, _ current: InterfaceCounters) -> TrafficRate? {
        let elapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed > 0.1, current.rxBytes >= previous.rxBytes, current.txBytes >= previous.txBytes else { return nil }
        return TrafficRate(rxPerSecond: Double(current.rxBytes - previous.rxBytes) / elapsed,
                           txPerSecond: Double(current.txBytes - previous.txBytes) / elapsed)
    }

    /// 직전 표본에 이어 계산해도 되는가: 갱신 주기 두 번(+1초) 안이어야 한다. 화면을 떠나 있던 사이·뺐다 꽂은 사이의 표본과 이으면
    /// 그 긴 시간의 평균이 지금 속도처럼 보인다 — 아니면 지난 값·그래프를 비우고 다시 쌓는다.
    public static func continues(from previous: InterfaceCounters, at now: Date, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(previous.at) <= interval * 2 + 1
    }

    /// "1.2 MB/s" — 디스크·서버 Live 와 같은 10진 단위 (DiskFormat)
    public static func format(_ bytesPerSecond: Double) -> String {
        DiskFormat.rate(bytesPerSecond)
    }
}

public struct PingSummary: Sendable, Equatable {
    public let averageMs: Double?
    public let lossPercent: Double
    public let jitterMs: Double?

    /// 응답이 하나도 없음 (재지 못했을 때도)
    public static let none = PingSummary(averageMs: nil, lossPercent: 100, jitterMs: nil)

    /// "12.3 ms · 손실 0%" / "응답 없음"
    public var text: String {
        guard let averageMs else { return "응답 없음" }
        var out = String(format: "%.1f ms", averageMs)
        if lossPercent > 0 { out += String(format: " · 손실 %.0f%%", lossPercent) }
        if let jitterMs { out += String(format: " · Jitter %.1f ms", jitterMs) }
        return out
    }
}

public struct SpeedTest: Sendable, Equatable {
    public let download: String?
    public let upload: String?
    public let responsiveness: String?
    public var text: String {
        guard download != nil || upload != nil else { return "측정 실패" }
        return "↓ \(download ?? "–") · ↑ \(upload ?? "–")"
    }
}

/// macOS 가 지금 인터넷(기본 경로)에 쓰는 네트워크 서비스 (scutil State:/Network/Global/IPv4 PrimaryService)
public enum PrimaryService: Sendable, Equatable {
    /// 이 이름의 서비스로 나간다
    case service(String)
    /// 이름 있는 서비스가 아니다 (VPN 등). underlying: 그 아래 실제 회선 장치 (scutil --nwi 의 utun 아닌 첫 장치) — 기본 경로가 없으면 nil
    case other(underlying: String?)

    /// 이 서비스를 끄면 인터넷이 끊기는가. primary 를 못 읽었으면(nil) 장치 기준(deviceMatch — 예전 판정)으로 조심스럽게.
    /// 같은 장치(en10)에 서비스가 둘(Ethernet 인터넷 + 내부망)이어도 인터넷 서비스 하나만 해당한다 (2026-10-15 팀원 Mac 에서 내부망까지 막혔다).
    /// VPN 아래 회선은 그 장치에서 서비스 순서가 가장 앞인 켜진 서비스 (macOS 가 고르는 방식) — WireGuard 가 켜져 있어도 아랫단 유선을 끄면 VPN 까지 끊긴다.
    /// services: 서비스 순서대로 (networksetup -listnetworkserviceorder)
    public static func carriesInternet(_ service: String, primary: PrimaryService?, services: [LanServiceEntry], deviceMatch: Bool) -> Bool {
        switch primary {
        case .service(let name): return name == service
        case .other(let underlying):
            guard let underlying else { return false }
            return services.first { $0.enabled && $0.device == underlying }?.name == service
        case nil: return deviceMatch
        }
    }
}

public enum NetworkProbe {
    // MARK: 기본 경로

    /// PrimaryService 의 이름. 못 읽으면 nil (판정은 예전 장치 기준으로)
    public static func primaryService(runner: any CommandRunner) async -> PrimaryService? {
        let global = await runner.run("scutil", [], stdin: "show State:/Network/Global/IPv4\nquit\n", environment: [:], timeout: 5)
        guard global.ok else { return nil }
        guard let id = SCDictionary.parse(global.stdout).values["PrimaryService"], !id.isEmpty else { return .other(underlying: nil) }   // 기본 경로 없음
        // id 는 UUID 꼴만 (scutil 입력 줄에 끼워 넣는다)
        guard id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let setup = await runner.run("scutil", [], stdin: "show Setup:/Network/Service/\(id)\nquit\n", environment: [:], timeout: 5)
        guard setup.ok else { return nil }
        if let name = parseServiceName(setup.stdout) { return .service(name) }
        // VPN 등: 그 아래 실제 회선 (못 읽으면 nil — 예전 장치 기준으로)
        let nwi = await runner.run("scutil", ["--nwi"], timeout: 5)
        guard nwi.ok else { return nil }
        return .other(underlying: underlyingDevice(nwi.stdout))
    }

    /// scutil --nwi 의 "Network interfaces: utun7 en10 en0" 에서 터널(utun·ipsec·ppp)이 아닌 첫 장치
    static func underlyingDevice(_ nwi: String) -> String? {
        guard let line = nwi.split(separator: "\n").last(where: { $0.hasPrefix("Network interfaces:") }) else { return nil }
        return line.dropFirst("Network interfaces:".count).split(separator: " ").map(String.init)
            .first { !$0.hasPrefix("utun") && !$0.hasPrefix("ipsec") && !$0.hasPrefix("ppp") }
    }

    /// Setup:/Network/Service/<id> 의 UserDefinedName (VPN 은 없다 → nil)
    static func parseServiceName(_ text: String) -> String? {
        SCDictionary.parse(text).values["UserDefinedName"].flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func defaultRoute(runner: any CommandRunner) async -> DefaultRoute {
        let result = await runner.run("route", ["-n", "get", "default"], timeout: 5)
        return parseRoute(result.stdout)
    }

    /// 그 주소로 가는 패킷이 나갈 장치 (라우팅 표 조회만, 망에 나가지 않는다). 장치에 묶지 않는 서버(Direct·Tailscale)의 표시용.
    /// IPv4 주소일 때만 묻는다 — 이름을 넘기면 route 가 DNS 를 물어 망에 나가고, 안 풀리는 이름이면 라운드마다 시간 제한까지 기다린다. 이름이면 nil.
    public static func routeInterface(to host: String, runner: any CommandRunner) async -> String? {
        guard IPv4.parse(host) != nil else { return nil }
        let result = await runner.run("route", ["-n", "get", host], timeout: 5)
        return result.ok ? parseRoute(result.stdout).interface : nil
    }

    /// `route -n get default` 출력에서 interface·gateway
    public static func parseRoute(_ text: String) -> DefaultRoute {
        var interface: String?, gateway: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if key == "interface" { interface = value }
            if key == "gateway" { gateway = value }
        }
        return DefaultRoute(interface: interface, gateway: gateway)
    }

    // MARK: 링크

    public static func linkMedia(device: String, runner: any CommandRunner) async -> LinkMedia {
        let result = await runner.run("ifconfig", [device], timeout: 5)
        return parseLinkMedia(result.stdout)
    }

    /// ifconfig 의 "media: autoselect (1000baseT <full-duplex>)" · "status: active"
    public static func parseLinkMedia(_ text: String) -> LinkMedia {
        var media: String?, status: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("media:") {
                var value = line.dropFirst("media:".count).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("autoselect ("), value.hasSuffix(")") {
                    value = String(value.dropFirst("autoselect (".count).dropLast())
                } else if value == "autoselect" {
                    value = "Autoselect"
                }
                if value != "none" { media = value }
            }
            if line.hasPrefix("status:") { status = line.dropFirst("status:".count).trimmingCharacters(in: .whitespaces) }
        }
        return LinkMedia(media: media, status: status)
    }

    // MARK: 트래픽

    public static func counters(device: String, runner: any CommandRunner, now: Date = Date()) async -> InterfaceCounters? {
        let result = await runner.run("netstat", ["-ibn", "-I", device], timeout: 5)
        return parseCounters(result.stdout, at: now)
    }

    /// netstat -ibn -I <if> 의 <Link#n> 줄에서 Ibytes·Obytes. 이더넷은 Address(MAC) 칸이 있어 7·10번째,
    /// utun 처럼 MAC 이 없는 장치는 그 칸이 비어 하나씩 당겨진 6·9번째 (칸 수로 가른다: 11 / 10).
    public static func parseCounters(_ text: String, at now: Date = Date()) -> InterfaceCounters? {
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 10, f[2].hasPrefix("<Link#") else { continue }
            let shift = f.count >= 11 ? 1 : 0
            guard let rx = UInt64(f[5 + shift]), let tx = UInt64(f[8 + shift]) else { continue }
            return InterfaceCounters(rxBytes: rx, txBytes: tx, at: now)
        }
        return nil
    }

    // MARK: ping

    /// 그 장치로만 보낸다 (ping -b) — 어댑터가 빠져 기본 경로(VPN 등)로 새면 다른 망의 같은 주소가 대답할 수 있다
    public static func ping(_ target: String, device: String, count: Int = 3, runner: any CommandRunner) async -> PingSummary {
        guard let output = await pingOutput(target, device: device, count: count, timeout: 10, runner: runner) else { return .none }
        return parsePing(output)
    }

    /// ping 을 돌린 출력 (stdout + stderr — 이름을 못 풀었다는 말은 stderr 에 온다). 0.2초 간격, 응답은 1초까지 기다린다.
    /// device 가 nil 이면 묶지 않고, 장치 이름이 이상하면 돌리지 않고 nil. 진단 카드의 ping(PingTest.ping)도 이것을 쓴다
    static func pingOutput(_ target: String, device: String?, count: Int, timeout: TimeInterval, runner: any CommandRunner) async -> String? {
        guard let bind = bindArguments(device, flag: "-b") else { return nil }
        let result = await runner.run("ping", ["-c", "\(count)", "-i", "0.2", "-W", "1000"] + bind + [target], timeout: timeout)
        return result.stdout + result.stderr
    }

    /// ping 요약 줄: "3 packets transmitted, 3 packets received, 0.0% packet loss" +
    /// "round-trip min/avg/max/stddev = 1.2/3.4/5.6/1.1 ms"
    public static func parsePing(_ text: String) -> PingSummary {
        var loss = 100.0, avg: Double?, jitter: Double?
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.contains("packet loss"),
               let range = line.range(of: #"([0-9.]+)% packet loss"#, options: .regularExpression) {
                let digits = line[range].prefix { $0.isNumber || $0 == "." }
                loss = Double(digits) ?? 100
            }
            if line.contains("min/avg/max"), let equals = line.firstIndex(of: "=") {
                let parts = line[line.index(after: equals)...]
                    .replacingOccurrences(of: "ms", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: "/")
                if parts.count >= 2 { avg = Double(parts[1].trimmingCharacters(in: .whitespaces)) }
                // 응답이 1개면 macOS ping 이 stddev 를 "nan" 으로 찍는다 → 지터 없음
                if parts.count >= 4, let value = Double(parts[3].trimmingCharacters(in: .whitespaces)), value.isFinite { jitter = value }
            }
        }
        return PingSummary(averageMs: loss >= 100 ? nil : avg, lossPercent: loss, jitterMs: jitter)
    }

    // MARK: 인터넷 응답 (204 엔드포인트)

    public static let probeURL = "https://cp.cloudflare.com/generate_204"
    public static let probeCount = 5

    /// 병렬 HTTPS 요청 N 번. 204 가 아닌 응답(포털 가로채기 등)은 실패로 센다.
    /// device 를 주면 그 장치로만 나간다 (curl --interface) — Wi-Fi·Ethernet 화면은 기본 경로가 아니라 자기 장치의 응답을 본다.
    public static func internetProbe(device: String? = nil, runner: any CommandRunner) async -> PingSummary {
        guard let bind = bindArguments(device, flag: "--interface") else { return .none }
        let script = """
        for i in $(seq 1 \(probeCount)); do
          curl -s -o /dev/null --connect-timeout 1 --max-time 2\(bind.map { " " + $0 }.joined()) -w '%{http_code} %{time_connect}\\n' \(probeURL) &
        done
        wait
        """
        let result = await runner.run("/bin/sh", ["-c", script], timeout: 10)
        return parseProbe(result.stdout, count: probeCount)
    }

    /// "204 0.0123" 줄들 → 평균 연결 시간·손실·표준편차
    public static func parseProbe(_ text: String, count: Int) -> PingSummary {
        var samples: [Double] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 2, f[0] == "204", let seconds = Double(f[1]), seconds > 0 else { continue }
            samples.append(seconds * 1000)
        }
        let loss = Double(max(0, count - samples.count)) * 100 / Double(count)
        guard !samples.isEmpty else { return .none }
        let avg = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(samples.count)
        return PingSummary(averageMs: avg, lossPercent: loss, jitterMs: variance > 0 ? variance.squareRoot() : 0)
    }

    /// 장치 묶기 인자: nil → [] (기본 경로), "en0" → [flag, "en0"]. 장치 이름이 영문·숫자가 아니면 nil (셸 스크립트에 들어가므로 거른다).
    static func bindArguments(_ device: String?, flag: String) -> [String]? {
        guard let device else { return [] }
        guard !device.isEmpty, device.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return [flag, device]
    }

    // MARK: 공인 IP

    /// device 를 주면 그 장치로만 나가 본다 (curl --interface) — Wi-Fi 화면은 기본 경로(VPN·유선)가 아니라 Wi-Fi 쪽 공인 IP 여야 한다.
    /// nil 이면 기본 경로 = 이 Mac 이 실제로 나가는 공인 IP.
    public static func publicIP(device: String? = nil, runner: any CommandRunner) async -> String? {
        guard let bind = bindArguments(device, flag: "--interface") else { return nil }
        let result = await runner.run("curl", ["-4", "-fsS", "--connect-timeout", "2", "--max-time", "4"] + bind + ["https://api.ipify.org"], timeout: 10)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, !value.isEmpty, value.count <= 45 else { return nil }
        return value
    }

    // MARK: 속도 측정

    /// 최대 실행 시간 (-M, 정수 초). 순차라 방향마다 절반씩 (2026-11-04 en11 실측 ↓1.52초 · ↑1.45초).
    /// 다운로드는 8초와 거의 같고 업로드는 7~26% 낮게 나오지만 빠른 쪽을 골랐다 (2026-11-04 사용자 결정)
    public static let speedTestSeconds = 3

    /// device 를 주면 그 장치로만 잰다 (networkQuality -I)
    public static func speedTest(device: String? = nil, runner: any CommandRunner) async -> SpeedTest? {
        guard runner.hasExecutable("networkQuality"), let bind = bindArguments(device, flag: "-I") else { return nil }
        // -s 순차: 동시에 재면 업로드가 절반 아래로 나왔다 (2026-11-04 en11 실측 동시 ↑157~183 · 순차 ↑393~419 Mbps). 전체 시간은 -M 그대로
        let result = await runner.run("networkQuality", ["-s", "-M", "\(speedTestSeconds)"] + bind, timeout: 60)
        return parseSpeedTest(result.stdout + result.stderr)
    }

    /// networkQuality 출력의 "Downlink capacity: 900.123 Mbps" 같은 줄. 응답성은 방향별 두 줄 중 나쁜 쪽(RPM 이 낮은 쪽)
    public static func parseSpeedTest(_ text: String) -> SpeedTest {
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("=") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, values[key] == nil { values[key] = value }
        }
        return SpeedTest(download: values["Downlink capacity"], upload: values["Uplink capacity"],
                         responsiveness: worseResponsiveness(values["Uplink Responsiveness"], values["Downlink Responsiveness"]))
    }

    /// RPM 이 낮은 쪽. 한쪽이 없거나 RPM 을 못 읽으면 읽힌 쪽
    private static func worseResponsiveness(_ a: String?, _ b: String?) -> String? {
        guard let a, let b else { return a ?? b }
        guard let rpmA = rpm(a) else { return b }
        guard let rpmB = rpm(b) else { return a }
        return rpmA <= rpmB ? a : b
    }

    /// "High (15.268 milliseconds | 3929 RPM)" → 3929
    private static func rpm(_ text: String) -> Int? {
        guard let range = text.range(of: " RPM") else { return nil }
        return text[..<range.lowerBound].split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
    }
}
