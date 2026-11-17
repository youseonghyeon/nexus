// 시스템 VPN 의 바깥 길: 암호화한 패킷을 실제로 내보내는 물리 장치 (VPN 화면 "나가는 장치" · Routes 카드 utun 줄 "→ en11").
// 라우팅 테이블(route get <서버>)은 서버 주소도 utun 으로 답한다 — VPN 확장이 자기 소켓을 물리 장치에 직접 묶어 테이블을 거치지 않기 때문.
// 그래서 확장 프로세스(scutil --nc show 의 NEProviderBundleIdentifier)를 찾아 그 소켓이 묶인 장치를 nettop 으로 읽는다.
// 확장 프로세스가 없는 VPN(내장 IKEv2·L2TP)은 소켓 주인을 모르므로 빈 목록. 루트 권한 없이 읽기만 한다.
// 실제 출력: Tests/ServersCoreTests/Fixtures/nettop-wireguard-*.txt

import Foundation

public struct VPNEgress: Sendable, Equatable {
    public let interface: String
    /// nettop udp 의 type 을 사이드바 이름으로 (Wired → Ethernet, WiFi → Wi-Fi). tcp 소켓만 있으면 nil
    public var type: String?
    /// 그 장치의 default 라우터 (route get -ifscope). 없으면 nil
    public var gateway: String?
    /// 소켓 받기+보내기 합 — 장치가 여럿이면 많이 쓴 순서
    public var bytes: Int64

    public init(interface: String, type: String? = nil, gateway: String? = nil, bytes: Int64 = 0) {
        self.interface = interface
        self.type = type
        self.gateway = gateway
        self.bytes = bytes
    }

    /// "en11 (Ethernet) · 192.168.8.1"
    public var text: String {
        var out = interface
        if let type { out += " (\(type))" }
        if let gateway { out += " · \(gateway)" }
        return out
    }
}

public enum VPNEgresses {
    /// `ps -axo pid=,comm=` 에서 확장 프로세스 PID. 시스템 확장은 경로에 번들 ID 가 들어 있고("<id>.systemextension/"),
    /// 앱 확장(.appex)은 경로에 없어 그 .appex 의 번들 ID 를 읽어 비교한다 (WireGuard 는 이쪽).
    static func providerPID(ps: String, bundleID: String, appexBundleID: (String) -> String?) -> Int? {
        for raw in ps.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int(line[..<space]) else { continue }
            let path = line[space...].trimmingCharacters(in: .whitespaces)   // 경로에 빈칸이 있을 수 있어 첫 빈칸 뒤 전부
            if path.contains("/\(bundleID).systemextension/") { return pid }
            if let range = path.range(of: ".appex/Contents/MacOS/"),
               appexBundleID(String(path[..<range.lowerBound]) + ".appex") == bundleID { return pid }
        }
        return nil
    }

    /// nettop CSV(-m udp · -m tcp 출력을 이어 붙여도 됨 — 머리줄마다 칸을 다시 읽는다) → 소켓이 묶인 장치별 합.
    /// 뺀다: 프로세스 합계 줄 · 장치 없는 소켓 · 터널 자신 · lo
    static func parseNettop(_ text: String, excluding tunnel: String?) -> [VPNEgress] {
        var columns: [String] = []
        var out: [VPNEgress] = []
        for raw in text.split(separator: "\n") {
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if cols.first == "time" { columns = cols; continue }
            func value(_ name: String) -> String? {
                columns.firstIndex(of: name).flatMap { $0 < cols.count ? cols[$0] : nil }
            }
            guard cols.count > 1, ["tcp4 ", "tcp6 ", "udp4 ", "udp6 "].contains(where: cols[1].hasPrefix),
                  let device = value("interface"), !device.isEmpty, device != tunnel, !device.hasPrefix("lo") else { continue }
            let bytes = (Int64(value("bytes_in") ?? "") ?? 0) + (Int64(value("bytes_out") ?? "") ?? 0)
            let type = value("type").flatMap { ["Wired": "Ethernet", "WiFi": "Wi-Fi", "Cellular": "Cellular"][$0] }
            if let i = out.firstIndex(where: { $0.interface == device }) {
                out[i].bytes += bytes
                if out[i].type == nil { out[i].type = type }
            } else {
                out.append(VPNEgress(interface: device, type: type, bytes: bytes))
            }
        }
        return out.enumerated().sorted { ($1.element.bytes, $0.offset) < ($0.element.bytes, $1.offset) }.map(\.element)
    }

    /// `route -n get -ifscope <장치> default` → "gateway: x" 값
    static func parseGateway(_ text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("gateway:") {
                let value = line.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// 확장 프로세스를 못 찾거나 nettop 이 실패하면 빈 목록 (화면은 "–")
    public static func fetch(providerBundleID: String, tunnel: String?, runner: any CommandRunner,
                             appexBundleID: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }) async -> [VPNEgress] {
        let ps = await runner.run("ps", ["-axo", "pid=,comm="], timeout: 5)
        guard ps.ok, let pid = providerPID(ps: ps.stdout, bundleID: providerBundleID, appexBundleID: appexBundleID) else { return [] }
        var text = ""
        for mode in ["udp", "tcp"] {
            let result = await runner.run("nettop", ["-L", "1", "-n", "-m", mode, "-p", String(pid)], timeout: 5)
            if result.ok { text += result.stdout + "\n" }
        }
        var egress = parseNettop(text, excluding: tunnel)
        for i in egress.indices {
            let route = await runner.run("route", ["-n", "get", "-ifscope", egress[i].interface, "default"], timeout: 5)
            if route.ok { egress[i].gateway = parseGateway(route.stdout) }
        }
        return egress
    }
}
