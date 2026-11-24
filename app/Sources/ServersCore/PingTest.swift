// ping 테스트 (Intranet·Wi-Fi·Ethernet 화면의 진단 카드): 입력한 주소로 ping 5회 + 경로(traceroute, ICMP). 그 화면의 장치에 묶어 보낸다 (ping -b · traceroute -i).
// traceroute 는 ICMP(-I): UDP 기본값은 공유기 다음 홉부터 대개 응답이 없었다 (2026-10-14 이 Mac 에서 비교).
// 대상은 영문·숫자·. - : 만 받는다 — 인자로만 넘기지만 "-" 로 시작하면 옵션으로 읽히므로 거른다.

import Foundation

public struct TraceHop: Sendable, Equatable {
    public let number: Int
    /// nil = 응답 없음 (*)
    public let address: String?
    public let ms: Double?

    public init(number: Int, address: String?, ms: Double?) {
        self.number = number; self.address = address; self.ms = ms
    }
}

public enum PingTest {
    public static let count = 5
    /// 경로는 30홉까지 재고(목적지에 닿으면 traceroute 가 먼저 끝난다), 화면엔 앞 15홉 — 나머지는 [더보기]
    public static let maxHops = 30
    public static let shownHops = 15

    /// 앞뒤 공백을 지운 대상. 비었거나 허용 밖 글자가 있으면 nil.
    public static func target(_ input: String) -> String? {
        DiagnosticInput.host(input, extra: ":")
    }

    /// ping 5회 (device 에 묶음). 이름을 못 풀면 resolveFailed.
    public static func ping(_ target: String, device: String?, runner: any CommandRunner) async -> (summary: PingSummary, resolveFailed: Bool) {
        guard let output = await NetworkProbe.pingOutput(target, device: device, count: count, timeout: 15, runner: runner) else { return (.none, false) }
        return (NetworkProbe.parsePing(output), resolveFailed(output))
    }

    /// 경로: 홉마다 한 번(-q 1), 1초 기다림, 최대 30홉 (응답 없는 홉이 이어지면 30초 남짓). 실패(이름 못 풂·장치 없음)면 nil.
    public static func trace(_ target: String, device: String?, runner: any CommandRunner) async -> [TraceHop]? {
        guard let bind = NetworkProbe.bindArguments(device, flag: "-i") else { return nil }
        let result = await runner.run("traceroute", ["-I", "-n", "-w", "1", "-q", "1", "-m", "\(maxHops)"] + bind + [target], timeout: 60)
        let hops = parseTrace(result.stdout)
        return hops.isEmpty ? nil : hops
    }

    /// 화면에 보일 홉. 끝의 응답 없는 홉이 2개 이상 이어지면 한 줄(silent, 번호 범위)로 묶는다 —
    /// 목적지가 답하지 않으면 traceroute 는 도착을 몰라 최대 홉까지 * 를 찍는다 (2026-10-15 223.130.x: 8–30 이 전부 *).
    /// 나머지가 shownHops 를 넘으면 접혀 있을 때 앞 shownHops 개와 숨긴 개수, foldable = [더보기]/[접기] 를 둘지
    public static func visibleHops(_ hops: [TraceHop], expanded: Bool) -> (shown: [TraceHop], hidden: Int, silent: ClosedRange<Int>?, foldable: Bool) {
        var body = hops
        var silent: ClosedRange<Int>?
        let tail = hops.reversed().prefix { $0.address == nil }.count
        if tail >= 2, let first = hops.dropLast(tail - 1).last, let last = hops.last {
            body = Array(hops.dropLast(tail))
            silent = first.number...last.number
        }
        let foldable = body.count > shownHops
        guard !expanded, foldable else { return (body, 0, silent, foldable) }
        return (Array(body.prefix(shownHops)), body.count - shownHops, silent, foldable)
    }

    static func resolveFailed(_ output: String) -> Bool {
        output.contains("cannot resolve") || output.contains("Unknown host") || output.contains("unknown host")
    }

    /// traceroute -n -q 1 출력: " 1  192.168.0.1  13.235 ms" · " 2  *" · " 3  10.0.0.1  1.2 ms !H"
    public static func parseTrace(_ text: String) -> [TraceHop] {
        var hops: [TraceHop] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ").map(String.init)
            guard parts.count >= 2, let number = Int(parts[0]) else { continue }
            if parts[1] == "*" {
                hops.append(TraceHop(number: number, address: nil, ms: nil))
            } else {
                let ms = parts.count >= 4 && parts[3] == "ms" ? Double(parts[2]) : nil
                hops.append(TraceHop(number: number, address: parts[1], ms: ms))
            }
        }
        return hops
    }
}

/// 한 번의 ping 테스트 결과 (Intranet·Wi-Fi·Ethernet 화면의 진단 카드). summary 가 nil 이면 ping 중, hops 가 nil 이면 경로를 아직 못 읽음.
public struct PingTestResult: Sendable, Equatable {
    public let target: String
    /// 보낸 장치 — 화면의 장치가 바뀌면(다른 SSID·대표 어댑터·내부망 서비스) 옛 결과를 보이지 않는다
    public let device: String
    public let at: Date
    public var summary: PingSummary?
    public var resolveFailed = false
    public var hops: [TraceHop]?
    /// ping 뒤 그 대상의 ARP (같은 대역이면 MAC — ping 이 막혀도 장비가 있는지)
    public var arp: ArpLookup?
    /// [주소 검색] 결과: 홉 IP → 위치 (nil = 아직 묻지 않음, IPLocate)
    public var locations: [String: IPLocation]?

    public init(target: String, device: String, at: Date = Date()) {
        self.target = target; self.device = device; self.at = at
    }
}

extension PingTestResult {
    /// [복사] 텍스트 — 화면과 같은 내용 (경로는 접지 않고 전부)
    public var reportText: String {
        var lines = ["ping \(target) · \(device) · \(at.formatted(date: .abbreviated, time: .standard))"]
        if resolveFailed {
            lines.append("응답: \(DiagnosticText.unresolved)")
            return lines.joined(separator: "\n")
        }
        if let summary { lines.append("응답: \(summary.text) (\(PingTest.count)회)") }
        if let arp { lines.append("ARP: \(arp.text)") }
        if let hops, !hops.isEmpty {
            lines.append("경로:")
            for hop in hops {
                let ms = hop.ms.map { String(format: "%.1f ms", $0) } ?? (hop.address == nil ? "응답 없음" : "–")
                let place = hop.address.flatMap { locations?[$0] }.map { "  \($0.text)" } ?? ""
                lines.append(String(format: "%3d  %@  %@", hop.number, hop.address ?? "*", ms) + place)
            }
        } else if hops != nil {
            lines.append("경로: 읽지 못했습니다")
        }
        return lines.joined(separator: "\n")
    }
}
