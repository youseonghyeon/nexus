// 서버별 선택 액션 줄 (tunnel_ports · proxy_port · wol_mac/wol_via) 편집.

import Foundation

extension ServerConfigEditor {
    /// 서버별 선택 액션 (tunnel_ports · proxy_port · wol_mac/wol_via). 기본 액션(SSH·Tunnel…)과 type 으로 정해지는 액션은 여기 없다.
    public struct Actions: Sendable, Equatable {
        public var tunnelPorts: [QuickTunnel]
        public var proxyPort: Int?
        public var wolMac: String?
        public var wolRoutes: [WakeRoute]

        public init(tunnelPorts: [QuickTunnel] = [], proxyPort: Int? = nil, wolMac: String? = nil, wolRoutes: [WakeRoute] = []) {
            self.tunnelPorts = tunnelPorts; self.proxyPort = proxyPort; self.wolMac = wolMac; self.wolRoutes = wolRoutes
        }
        public init(_ server: Server) {
            self.init(tunnelPorts: server.tunnelPorts, proxyPort: server.proxyPort, wolMac: server.wolMac, wolRoutes: server.wolRoutes)
        }

        /// servers.conf 에 쓸 값. nil 이면 그 줄을 지운다.
        var fields: [(name: String, value: String?)] {
            let ports = tunnelPorts.map { t in t.name.map { "\($0):\(t.port)" } ?? "\(t.port)" }.joined(separator: ",")
            let routes = wolRoutes.map(\.text).joined(separator: ",")
            return [("tunnel_ports", ports.isEmpty ? nil : ports), ("proxy_port", proxyPort.map(String.init)),
                    ("wol_mac", wolMac), ("wol_via", routes.isEmpty ? nil : routes)]
        }
    }

    /// 액션 입력값 문제를 한 줄로. nil 이면 쓸 수 있다.
    public static func problem(_ actions: Actions, for key: String, in config: ServerConfig) -> String? {
        var seen = Set<Int>()
        for t in actions.tunnelPorts {
            if !(1...65535).contains(t.port) { return "터널 포트는 1~65535 사이여야 합니다" }
            if !seen.insert(t.port).inserted { return "같은 터널 포트가 두 번 있습니다: \(t.port)" }
            if let name = t.name, name.isEmpty || name.range(of: #"^[A-Za-z0-9._\- ]+$"#, options: .regularExpression) == nil {
                return "터널 이름은 영문·숫자·공백·점(.)·밑줄(_)·하이픈(-)만 쓸 수 있습니다"
            }
        }
        if let p = actions.proxyPort, !(1...65535).contains(p) { return "프록시 포트는 1~65535 사이여야 합니다" }
        switch (actions.wolMac, actions.wolRoutes.isEmpty) {
        case (nil, true): break
        case let (mac?, false):
            if mac.range(of: ConfigPattern.mac, options: .regularExpression) == nil { return "MAC 은 AA:BB:CC:DD:EE:FF 형식이어야 합니다" }
            var vias = Set<String>()
            for route in actions.wolRoutes {
                if route.via == key || config.server(route.via) == nil { return "깨워 줄 서버를 고르세요" }
                if !vias.insert(route.via).inserted { return "같은 부팅 경로가 두 번 있습니다: \(route.via)" }
                if let iface = route.iface, iface.range(of: WakeRoute.ifacePattern, options: .regularExpression) == nil {
                    return "인터페이스 이름은 영문·숫자·점(.)·밑줄(_)·하이픈(-) 15자 이내여야 합니다"
                }
            }
        default: return "MAC 과 깨워 줄 서버를 둘 다 넣으세요"
        }
        return nil
    }

    /// [키] 블록의 액션 줄만 바꾼 텍스트. 값이 그대로인 줄은 건드리지 않는다(뒤 주석 유지). 새 줄은 블록 마지막 설정 줄 뒤에.
    public static func updating(_ actions: Actions, for key: String, in text: String, reference: String = "servers.conf") throws -> String {
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard let server = current.server(key) else {
            throw missingServer(key, reference: reference)
        }
        if let problem = problem(actions, for: key, in: current) {
            throw ConfigError(problem: problem, fix: "입력값을 고치세요.", reference: reference)
        }
        let before = Dictionary(uniqueKeysWithValues: Actions(server).fields.map { ($0.name, $0.value) })
        var all = lines(of: text)
        setFields(actions.fields.filter { (before[$0.name] ?? nil) != $0.value }, key: key, in: &all)
        let result = all.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(result, reference: reference)
        return result
    }

    /// 파일에서 읽은 그 서버의 액션에 변경 하나만 적용한다. 앱이 기억하는 값이 낡아도(파일을 직접 고친 뒤 Reload 전) 다른 줄을 덮지 않는다.
    public static func updating(for key: String, in text: String, reference: String = "servers.conf",
                                _ change: (inout Actions) -> Void) throws -> String {
        guard let server = try ServerConfigParser.parse(text, reference: reference).server(key) else {
            throw missingServer(key, reference: reference)
        }
        var actions = Actions(server)
        change(&actions)
        return try updating(actions, for: key, in: text, reference: reference)
    }
}
