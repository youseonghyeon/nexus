// servers.conf 파서 (이 파일을 읽는 건 앱뿐이다).
//
//   [키]             서버. group/type/ip/user/port 필수, network(없으면 direct)/vpn/extra_users/check/role/env/wol_mac/wol_via/proxy_port/tunnel_ports/notify 선택
//   [network:lan]    service (wait_attempts/wait_interval 은 예전 키 — 남아 있어도 읽지 않는다)
//   [group:이름]     theme/db_jump/db_host/db_port/db_local/db_name
//   값 뒤 " # 주석" 허용.

import Foundation

/// direct = 망 설정 없음: 망 조건(Tailscale·내부망) 없이 이 Mac 의 기본 경로로 바로 확인·접속한다 (VPN 너머·공인 IP 장비 등). servers.conf 에서 network= 를 빼도 같다.
public enum ServerNetwork: String, Sendable, Codable { case tailscale, lan, direct, vpn }
/// openwrt: OpenWrt 공유기 — 셸·전송은 linux 와 같고, 원격 정보는 OpenWrt 판 (bash·systemd 대신 ash·procd·ubus)
public enum ServerType: String, Sendable, Codable { case linux, windows, openwrt }
public enum CheckMethod: String, Sendable, Codable { case ssh, tcp }

public struct Server: Sendable, Identifiable, Hashable {
    public var id: String { key }
    public let key: String
    public let group: String
    public let network: ServerNetwork
    public let type: ServerType
    public let ip: String
    /// 이 값이 접속할 계정. 처음엔 user= (primaryUser), account(_:)·ServerConfig.applyingAccounts 가 바꾼다 — SSH·전송·터널·원격 정보는 이 값을 그대로 쓴다.
    public private(set) var user: String
    /// user= 의 계정 (기본 계정)
    public let primaryUser: String
    /// extra_users= 의 계정 (같은 장비의 다른 계정). 사이드바엔 한 줄, 서버 정보에서 고른다.
    public let extraUsers: [String]
    public let port: Int
    public let check: CheckMethod
    public let role: String?
    public let env: String?
    public let wolMac: String?
    /// 깨워 줄 경로 (wol_via=, 적은 순서). 어느 경로로 보낼지는 설정 창에서 고른다 (AppPreferences.wakeRoute).
    public let wolRoutes: [WakeRoute]
    /// SOCKS 프록시(ssh -D)용 로컬 포트. 있으면 서버 정보에 [Chrome] 이 보인다 — 이 서버를 거쳐 브라우징.
    public let proxyPort: Int?
    /// 예전의 터널 바로가기 (tunnel_ports=). 앱은 더 쓰지 않는다 (2026-11-17) — 이미 적은 파일이 오류 없이 읽히고, 액션을 고칠 때 그 줄이 지워지지 않게 읽기만 한다.
    public let tunnelPorts: [QuickTunnel]
    /// 켜짐·꺼짐을 macOS 알림으로 (notify=on). 판정은 PowerWatch.
    public let notify: Bool
    /// network=vpn 의 시스템 VPN 이름 (vpn=, scutil --nc 의 이름). nil 이면 연결된 첫 VPN. 연결은 그 VPN 의 utun 에 묶는다.
    public let vpn: String?
    /// 계정별 키 파일 (.pem 등). servers.conf 가 아니라 앱 상태(identities.json)에서 붙인다 — ServerConfig.applyingIdentities
    var identityFiles: [String: String] = [:]
    /// 이 값의 계정에 쓰는 키 파일
    public var identityFile: String? { identityFiles[user] }

    public init(key: String, group: String, network: ServerNetwork, type: ServerType, ip: String, user: String, port: Int,
                check: CheckMethod, role: String?, env: String?, wolMac: String?, wolRoutes: [WakeRoute] = [], proxyPort: Int? = nil, tunnelPorts: [QuickTunnel] = [],
                notify: Bool = false, vpn: String? = nil, extraUsers: [String] = []) {
        self.key = key; self.group = group; self.network = network; self.type = type; self.ip = ip; self.user = user; self.port = port
        self.primaryUser = user; self.extraUsers = extraUsers
        self.check = check; self.role = role; self.env = env; self.wolMac = wolMac; self.wolRoutes = wolRoutes; self.proxyPort = proxyPort
        self.tunnelPorts = tunnelPorts; self.notify = notify; self.vpn = vpn
    }

    public var target: String { "\(user)@\(ip)" }
    /// 고를 수 있는 계정 (기본 계정 먼저, 적은 순서)
    public var accounts: [String] { [primaryUser] + extraUsers }
    /// 같은 서버의 그 계정으로 접속할 값. 목록에 없는 계정(nil·빠진 계정)이면 그대로.
    public func account(_ name: String?) -> Server {
        guard let name, accounts.contains(name) else { return self }
        var copy = self
        copy.user = name
        return copy
    }
    /// 그 계정의 비밀번호·키 파일 저장 키. 기본 계정은 서버 키 그대로 (계정 하나인 서버와 옛 passwords.bin·identities.json 이 그대로 읽힌다).
    /// 서버 키에 @ 를 쓸 수 없어 겹치지 않는다.
    public func credentialKey(for name: String) -> String { name == primaryUser ? key : "\(key)@\(name)" }
    public var credentialKey: String { credentialKey(for: user) }
    public var credentialKeys: [String] { accounts.map(credentialKey(for:)) }
    /// 계정별 캐시(원격 홈·마지막 업로드 폴더)의 키. 저장 키와 달리 기본 계정이 바뀌어도 같은 계정을 가리킨다.
    public func accountID(for name: String) -> String { "\(key)@\(name)" }
    public var accountID: String { accountID(for: user) }
    /// 같은 장비에 같은 방식으로 붙는 연결인가 (이전 값 old 와 비교). 고른 계정·계정 추가·기본 계정 맞바꿈은 같은 연결이다 — 옛 기본 계정이 목록에 남아 있으면.
    public func sameConnection(as old: Server) -> Bool {
        (ip, port, network, type, vpn) == (old.ip, old.port, old.network, old.type, old.vpn) && accounts.contains(old.primaryUser)
    }
    /// 창 없이 저절로 원격 정보를 읽어도 되는가. 추가 계정은 비밀번호·키 파일이 생긴 뒤부터 — 막 넣은 계정(오타일 수도)으로 로그인을 시도하면
    /// 서버에 실패 기록이 남는다 (fail2ban). 값을 넣으면 다음 갱신에 읽고, 기본 키로 되는 계정은 새로고침(↻)으로.
    public func autoFetches(hasPassword: Bool) -> Bool {
        user == primaryUser || hasPassword || identityFile != nil
    }
    /// 그 계정을 기본으로 올리면 상태 확인이 실패할 수 있는가: check=ssh 는 기본 계정의 BatchMode 로그인이라 비밀번호를 쓰지 않는다.
    /// Tailscale SSH 는 키 없이 된다. 등록하지 않은 기본 키(~/.ssh/id_*)로 될 수도 있어 "수 있다" 까지만.
    public func statusCheckMayFail(as name: String) -> Bool {
        check == .ssh && network != .tailscale && identityFiles[name] == nil
    }
    /// 터미널 탭 이름: 계정이 여럿일 때만 어느 계정인지 함께
    public var accountTitle: String { extraUsers.isEmpty ? key : "\(key) · \(user)" }
    /// 태그 (env= 를 쉼표로 나눈 것). 배지·프롬프트에 이 순서로. 색은 ServerTags.
    public var tags: [String] { ServerTags.parse(env) }
    /// 운영 태그(PROD·PRD·LIVE…)가 하나라도 있다
    public var isProd: Bool { ServerTags.strongest(tags) == .production }
    /// 접속 프롬프트에 찍는 태그 글자 (없으면 DEV)
    public var promptTag: String { tags.isEmpty ? "DEV" : tags.joined(separator: ",") }
}

/// wol_via= 의 항목 하나: "brume3:br-lan" → brume3 에서 etherwake -i br-lan, "nexus" → nexus 에서 wakeonlan.
public struct WakeRoute: Sendable, Hashable {
    public let via: String
    /// 패킷을 내보낼 via 쪽 인터페이스. 있으면 etherwake(OpenWrt 공유기 등), 없으면 wakeonlan.
    public let iface: String?
    public init(via: String, iface: String? = nil) { self.via = via; self.iface = iface }
    /// 설정 창·정보 화면 문구: "brume3 (br-lan)" / "nexus"
    public var label: String { iface.map { "\(via) (\($0))" } ?? via }
    /// servers.conf 에 쓰는 형태
    public var text: String { iface.map { "\(via):\($0)" } ?? via }

    /// 인터페이스 이름 (리눅스 IFNAMSIZ 15자). 원격 명령에 그대로 들어가므로 이 글자만.
    public static let ifacePattern = #"^[A-Za-z0-9._-]{1,15}$"#
}

/// tunnel_ports= 의 항목 하나: "Jenkins:9090" → 이름 Jenkins, 포트 9090. 이름이 없으면("9090") 버튼은 "Tunnel 9090".
public struct QuickTunnel: Sendable, Hashable {
    public let name: String?
    public let port: Int
    public init(name: String?, port: Int) { self.name = name; self.port = port }
    /// 버튼 문구
    public var label: String { name.map { "\($0) Tunnel" } ?? "Tunnel \(port)" }
}

/// 내부망 서비스. 분할 라우팅 대역은 없다 — 시스템 경로를 넣지 않고, 이 앱이 lan 서버로 여는 연결만 그 서비스의 장치에 묶는다(BindInterface).
/// 그래서 다른 프로세스는 내부망에 닿지 않고, 앱의 연결은 장치의 스코프 기본 경로(내부망 라우터)로 나간다.
public struct LanNetwork: Sendable, Hashable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    /// 서비스만 바꾼 사본 (앱 저장소 lan.json 의 값으로 servers.conf 기본값을 덮을 때)
    public func replacing(service: String) -> LanNetwork {
        LanNetwork(service: service)
    }
}

public struct GroupSettings: Sendable, Hashable {
    public let theme: Bool
    public let dbJump: String?
    public let dbHost: String?
    public let dbPort: Int?
    public let dbLocal: Int?
    public let dbName: String?
}

public struct ServerConfig: Sendable {
    public let servers: [Server]          // 정의 순서
    public let groups: [String]           // 첫 등장 순서
    public let lan: LanNetwork?
    public let groupSettings: [String: GroupSettings]

    public func servers(in group: String) -> [Server] { servers.filter { $0.group == group } }
    public func server(_ key: String) -> Server? { servers.first { $0.key == key } }
    public func settings(for group: String) -> GroupSettings? { groupSettings[group] }
    /// Tailscale VPN 행(사이드바·메뉴바): tailscale 서버가 없어도 이 Mac 에 tailscale 이 있으면 보인다 (켜고 끄기용).
    /// 확인 전(앱을 켠 직후)엔 숨기고, 확인해서 있을 때만 보인다. tailscale 서버가 있으면 늘 보인다 (확인 전·명령 없음이어도 비활성 행)
    public func showsTailscale(_ state: TailscaleState, checked: Bool) -> Bool {
        if servers.contains(where: { $0.network == .tailscale }) { return true }
        return checked && state != .missing
    }

    /// 계정마다 키 파일을 붙인 사본 (identities.json — 없는 계정은 키 없음)
    public func applyingIdentities(_ identities: [String: String]) -> ServerConfig {
        let servers = servers.map { server in
            var server = server
            server.identityFiles = server.accounts.reduce(into: [:]) { $0[$1] = identities[server.credentialKey(for: $1)] }
            return server
        }
        return ServerConfig(servers: servers, groups: groups, lan: lan, groupSettings: groupSettings)
    }

    /// 서버마다 고른 계정으로 접속하는 사본 ({서버 키: 계정}). 고른 적 없거나 목록에서 빠진 계정이면 기본 계정.
    public func applyingAccounts(_ selected: [String: String]) -> ServerConfig {
        let servers = servers.map { server in
            let base = server.account(server.primaryUser)
            return base.account(selected[server.key])
        }
        return ServerConfig(servers: servers, groups: groups, lan: lan, groupSettings: groupSettings)
    }

    /// 그 값의 계정에 지금 맞는 저장 키. 열린 탭·터널이 들고 있는 값은 기본 계정이 바뀌기 전 것일 수 있어, 비밀번호·키는 늘 이걸로 찾는다.
    /// 목록에서 빠진 계정이면 주인 없는 키가 되어 아무 값도 찾지 못한다.
    public func credentialKey(of server: Server) -> String {
        self.server(server.key)?.credentialKey(for: server.user) ?? server.credentialKey
    }

    /// 이 저장 키(비밀번호·키 파일)의 서버·계정이 목록에 있는가. 없는 값은 목록을 읽을 때 지운다.
    public func ownsCredential(_ key: String) -> Bool {
        servers.contains { $0.credentialKeys.contains(key) }
    }

    /// 내부망 설정만 바꾼 사본 (상태 확인이 앱 저장소의 서비스·경로를 보게 할 때)
    public func replacingLan(_ lan: LanNetwork?) -> ServerConfig {
        ServerConfig(servers: servers, groups: groups, lan: lan, groupSettings: groupSettings)
    }
}

/// servers.conf 값의 형식 (파서와 편집기가 같이 쓴다)
enum ConfigPattern {
    /// 서버 키 — 편집기는 그룹 이름에도 같은 규칙을 쓴다
    static let key = #"^[a-z][a-z0-9_]*$"#
    /// 편집기가 받는 IP·사용자·계정 이름 (파서는 더 느슨하다 — '-' 로 시작하는 것만 막는다)
    static let account = #"^[A-Za-z0-9_][A-Za-z0-9._\-]*$"#
    static let mac = #"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#
}

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let problem: String
    public let fix: String
    public let reference: String
    public init(problem: String, fix: String, reference: String) {
        self.problem = problem
        self.fix = fix
        self.reference = reference
    }
    public var description: String { "문제: \(problem)\n해결: \(fix)\n참조: \(reference)" }
}

public enum ServerConfigParser {
    public static func load(path: String) throws -> ServerConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ConfigError(problem: "서버 목록 파일을 읽을 수 없습니다: \(path)",
                              fix: "servers.conf 를 만들거나 경로를 확인하세요.", reference: path)
        }
        return try parse(text, reference: path)
    }

    public static func parse(_ text: String, reference: String = "servers.conf") throws -> ServerConfig {
        var sections: [String: [String: String]] = [:]
        var serverKeys: [String] = []
        var section = ""
        var lineNumber = 0

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            var line = String(rawLine)
            if let range = line.range(of: #"\s#.*$"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                if !section.hasPrefix("network:"), !section.hasPrefix("group:") {
                    guard section.range(of: ConfigPattern.key, options: .regularExpression) != nil else {
                        throw ConfigError(problem: "서버 키 '\(section)'는 소문자 영문·숫자·밑줄만 쓸 수 있습니다 (\(reference):\(lineNumber)).",
                                          fix: "[키] 이름을 예: [nexus] 처럼 바꾸세요.", reference: reference)
                    }
                    guard !serverKeys.contains(section) else {
                        throw ConfigError(problem: "서버 키 '\(section)'가 두 번 정의됐습니다 (\(reference):\(lineNumber)).",
                                          fix: "한 블록만 남기세요.", reference: reference)
                    }
                    serverKeys.append(section)
                }
                if sections[section] == nil { sections[section] = [:] }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigError(problem: "형식 오류: '\(line)' (\(reference):\(lineNumber))",
                                  fix: "키=값 형식으로 쓰세요.", reference: reference)
            }
            guard !section.isEmpty else {
                throw ConfigError(problem: "섹션 밖의 설정: '\(line)' (\(reference):\(lineNumber))",
                                  fix: "[키] 블록 안으로 옮기세요.", reference: reference)
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // 빈 값은 "미설정" 으로 본다 (key= 만 남긴 줄은 없는 것과 같다)
            if value.isEmpty { sections[section, default: [:]].removeValue(forKey: key) } else { sections[section, default: [:]][key] = value }
        }

        return try build(sections: sections, serverKeys: serverKeys, reference: reference)
    }

    private static func build(sections: [String: [String: String]], serverKeys: [String], reference: String) throws -> ServerConfig {
        func die(_ problem: String, _ fix: String) -> ConfigError {
            ConfigError(problem: problem, fix: fix, reference: reference)
        }
        func port(_ value: String) -> Int? {
            // zsh 의 <1-65535> 패턴과 같이 부호·공백 없는 숫자만 허용한다
            guard value.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  let n = Int(value), (1...65535).contains(n) else { return nil }
            return n
        }

        var lan: LanNetwork?
        if let s = sections["network:lan"], let service = s["service"], !service.isEmpty {
            // routes=·wait_attempts=·wait_interval= 은 예전 키. 읽지 않는다 (분할 라우팅 대신 BindInterface).
            lan = LanNetwork(service: service)
        }

        var servers: [Server] = []
        var groups: [String] = []
        for key in serverKeys {
            let s = sections[key] ?? [:]
            for field in ["group", "type", "ip", "user", "port"] where (s[field] ?? "").isEmpty {
                throw die("서버 '\(key)'에 \(field)= 가 없습니다.",
                          "[\(key)] 블록에 \(field)= 를 추가하세요. 필수: group type ip user port")
            }
            let rawNetwork = s["network"] ?? ""
            guard let network = rawNetwork.isEmpty ? .direct : ServerNetwork(rawValue: rawNetwork) else {
                throw die("서버 '\(key)'의 network='\(rawNetwork)'는 지원하지 않습니다.",
                          "network=tailscale · lan · vpn · direct(망 설정 없음) 중 하나로 바꾸거나 줄을 지우세요 (지우면 direct).")
            }
            guard let type = ServerType(rawValue: s["type"]!) else {
                throw die("서버 '\(key)'의 type='\(s["type"]!)'는 지원하지 않습니다.", "type=linux · windows · openwrt 중 하나로 바꾸세요.")
            }
            // 형식은 편집기(ServerConfigEditor.problem)보다 느슨하게 받되(admin@corp 등), '-' 로 시작하면 ssh·ping 이 옵션으로 읽는다
            // (가져온 파일의 user=-oProxyCommand=… 가 상태 확인 때 이 Mac 에서 명령을 돌린다)
            for field in ["ip", "user"] where s[field]!.utf8.first == UInt8(ascii: "-") {
                throw die("서버 '\(key)'의 \(field)='\(s[field]!)'는 '-' 로 시작해 쓸 수 없습니다.",
                          "\(field)= 값을 고치세요 ('-' 로 시작하면 ssh 가 옵션으로 읽습니다).")
            }
            var extraUsers: [String] = []
            for name in (s["extra_users"] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
                if name.utf8.first == UInt8(ascii: "-") {
                    throw die("서버 '\(key)'의 extra_users= 의 '\(name)'는 '-' 로 시작해 쓸 수 없습니다.", "extra_users= 값을 고치세요 ('-' 로 시작하면 ssh 가 옵션으로 읽습니다).")
                }
                if name == s["user"] {
                    throw die("서버 '\(key)'의 extra_users= 의 '\(name)'는 user= 와 같습니다.", "extra_users= 에는 user= 말고 다른 계정만 적으세요.")
                }
                if extraUsers.contains(name) {
                    throw die("서버 '\(key)'의 extra_users= 에 '\(name)'가 두 번 있습니다.", "한 계정은 한 번만 적으세요.")
                }
                extraUsers.append(name)
            }
            let check: CheckMethod
            if let raw = s["check"] {
                guard let c = CheckMethod(rawValue: raw) else {
                    throw die("서버 '\(key)'의 check='\(raw)'는 지원하지 않습니다.", "check=ssh (BatchMode 로그인) 또는 check=tcp (포트 열림) 로 바꾸세요.")
                }
                check = c
            } else {
                // Tailscale 은 Tailscale SSH 로 키 없이 로그인되지만, 내부망·Direct(VPN 너머 등)는 비밀번호 서버가 많아 ssh 확인이 늘 실패한다
                // 공유기(openwrt)도 보통 비밀번호 로그인이다
                check = (type == .windows || type == .openwrt || network != .tailscale) ? .tcp : .ssh
            }
            guard let p = port(s["port"]!) else {
                throw die("서버 '\(key)'의 port='\(s["port"]!)'가 1~65535 범위가 아닙니다.", "port= 값을 고치세요.")
            }
            if network == .lan, lan == nil {
                throw die("서버 '\(key)'는 network=lan 인데 [network:lan] service= 가 없습니다.",
                          "[network:lan] 블록에 service=<macOS 네트워크 서비스 이름> 을 추가하세요.")
            }
            let mac = s["wol_mac"], via = s["wol_via"]
            var wolRoutes: [WakeRoute] = []
            if mac != nil || via != nil {
                guard let mac, let via, !mac.isEmpty, !via.isEmpty else {
                    throw die("서버 '\(key)'의 wol_mac= 과 wol_via= 는 함께 있어야 합니다.", "둘 다 적거나 둘 다 지우세요.")
                }
                guard mac.range(of: ConfigPattern.mac, options: .regularExpression) != nil else {
                    throw die("서버 '\(key)'의 wol_mac='\(mac)'가 MAC 주소 형식(AA:BB:CC:DD:EE:FF)이 아닙니다.", "wol_mac= 값을 고치세요.")
                }
                for entry in via.split(separator: ",", omittingEmptySubsequences: false) {
                    // "brume3:br-lan" 또는 "nexus"
                    let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    let routeVia = parts[0], iface = parts.count == 2 ? parts[1] : nil
                    guard serverKeys.contains(routeVia) else {
                        throw die("서버 '\(key)'의 wol_via= 의 '\(routeVia)'는 등록되지 않은 서버 키입니다.", "wol_via= 에 이 파일에 있는 다른 서버 키를 쉼표로 적으세요 (예: brume3:br-lan,nexus).")
                    }
                    if let iface, iface.range(of: WakeRoute.ifacePattern, options: .regularExpression) == nil {
                        throw die("서버 '\(key)'의 wol_via= 의 인터페이스 '\(iface)'가 이름 형식(영문·숫자·._- 15자 이내)이 아닙니다.", "서버:인터페이스 로 적으세요 (예: brume3:br-lan).")
                    }
                    guard !wolRoutes.contains(where: { $0.via == routeVia }) else {
                        throw die("서버 '\(key)'의 wol_via= 에 '\(routeVia)'가 두 번 있습니다.", "한 서버는 한 번만 적으세요.")
                    }
                    wolRoutes.append(WakeRoute(via: routeVia, iface: iface))
                }
            }
            var proxyPort: Int?
            if let raw = s["proxy_port"] {
                guard let v = port(raw) else {
                    throw die("서버 '\(key)'의 proxy_port='\(raw)'가 1~65535 범위가 아닙니다.", "proxy_port= 값을 고치세요 (예: 1080).")
                }
                proxyPort = v
            }
            var tunnelPorts: [QuickTunnel] = []
            if let raw = s["tunnel_ports"] {
                for entry in raw.split(separator: ",") {
                    let text = entry.trimmingCharacters(in: .whitespaces)
                    // "Jenkins:9090" 또는 "9090"
                    let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let name = parts.count == 2 ? parts[0] : nil
                    let portText = parts.count == 2 ? parts[1] : text
                    guard let v = port(portText), name?.isEmpty != true else {
                        throw die("서버 '\(key)'의 tunnel_ports='\(raw)'에 잘못된 항목이 있습니다: '\(text)'", "이름:포트 또는 포트만, 쉼표로 구분하세요 (예: Jenkins:9090,8080).")
                    }
                    if !tunnelPorts.contains(where: { $0.port == v }) { tunnelPorts.append(QuickTunnel(name: name, port: v)) }
                }
            }
            var notify = false
            if let raw = s["notify"] {
                guard raw == "on" || raw == "off" else {
                    throw die("서버 '\(key)'의 notify='\(raw)'는 지원하지 않습니다.", "notify=on (켜짐·꺼짐 알림) 또는 notify=off 로 바꾸세요.")
                }
                notify = raw == "on"
            }
            // vpn= 은 network=vpn 의 VPN 이름 (빈 값·없음 = 연결된 첫 VPN). 다른 망에 적혀 있으면 무엇에 묶일지 헷갈리니 막는다
            let vpn = s["vpn"].flatMap { $0.isEmpty ? nil : $0 }
            if vpn != nil, network != .vpn {
                throw die("서버 '\(key)'에 vpn= 이 있는데 network=\(network.rawValue) 입니다.",
                          "network=vpn 으로 바꾸거나 vpn= 줄을 지우세요 (vpn= 은 network=vpn 에서만 씁니다).")
            }
            let group = s["group"]!
            if !groups.contains(group) { groups.append(group) }
            servers.append(Server(key: key, group: group, network: network, type: type, ip: s["ip"]!, user: s["user"]!,
                                  port: p, check: check, role: s["role"], env: s["env"], wolMac: mac, wolRoutes: wolRoutes, proxyPort: proxyPort, tunnelPorts: tunnelPorts,
                                  notify: notify, vpn: vpn, extraUsers: extraUsers))
        }

        var groupSettings: [String: GroupSettings] = [:]
        for group in groups {
            let s = sections["group:\(group)"] ?? [:]
            for field in ["db_port", "db_local"] {
                if let v = s[field], !v.isEmpty, port(v) == nil {
                    throw die("[group:\(group)] \(field)='\(v)'가 1~65535 범위가 아닙니다.", "\(field)= 값을 고치세요.")
                }
            }
            if let jump = s["db_jump"], !jump.isEmpty, !serverKeys.contains(jump) {
                throw die("[group:\(group)] db_jump='\(jump)'는 등록되지 않은 서버 키입니다.", "db_jump= 에 이 파일의 서버 키를 적으세요.")
            }
            groupSettings[group] = GroupSettings(theme: s["theme"] == "on", dbJump: s["db_jump"], dbHost: s["db_host"],
                                                 dbPort: s["db_port"].flatMap(port), dbLocal: s["db_local"].flatMap(port),
                                                 dbName: s["db_name"])
        }
        return ServerConfig(servers: servers, groups: groups, lan: lan, groupSettings: groupSettings)
    }
}
