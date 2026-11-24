// servers.conf 텍스트 편집: 서버 블록 추가·제거·기본 항목 편집 (여기), 순서(+Order) · 액션(+Actions) · 이름(+Rename) ·
// 계정·합치기(+Accounts) · 가져오기(+Import) · 저장 키 옮기기(+Credentials). 파일 전체를 다시 쓰지 않고 그 [키] 블록만 다뤄
// 상단 설명 주석·다른 블록의 주석·순서를 그대로 둔다. 결과는 항상 파서로 다시 읽어 확인한 뒤에만 돌려준다.

import Foundation

/// 추가·편집 창의 기본 항목. 선택 액션(wol_*·proxy_port·tunnel_ports)은 Actions, 추가 계정은 서버 정보의 사용자 칸에서 고친다.
public struct NewServer: Sendable, Equatable {
    public var key: String
    public var group: String
    public var network: ServerNetwork
    public var type: ServerType
    public var ip: String
    public var user: String
    public var port: Int
    public var role: String?
    public var env: String?
    /// network=vpn 의 VPN 이름 (nil = 연결된 첫 VPN). 다른 망이면 쓰지 않는다.
    public var vpn: String?
    /// 같은 장비의 다른 계정 (extra_users=). user 가 기본 계정.
    public var extraUsers: [String]

    public init(key: String, group: String, network: ServerNetwork = .tailscale, type: ServerType, ip: String, user: String, port: Int = 22, role: String? = nil, env: String? = nil,
                vpn: String? = nil, extraUsers: [String] = []) {
        self.key = key; self.group = group; self.network = network; self.type = type; self.ip = ip; self.user = user; self.port = port
        self.role = role; self.env = env; self.vpn = vpn; self.extraUsers = extraUsers
    }

    /// 편집 창의 처음 값 (파일에 적힌 그대로 — 태그도 쉼표 문자열 그대로). 사용자는 지금 고른 계정이 아니라 기본 계정.
    public init(_ server: Server) {
        self.init(key: server.key, group: server.group, network: server.network, type: server.type, ip: server.ip, user: server.primaryUser,
                  port: server.port, role: server.role, env: server.env, vpn: server.vpn, extraUsers: server.extraUsers)
    }
}

public enum ServerConfigEditor {
    /// 입력값 문제를 한 줄로. nil 이면 쓸 수 있다 (키 중복 등 파일과 얽힌 검사는 appending 이 한다).
    public static func problem(_ server: NewServer) -> String? {
        if server.key.range(of: ConfigPattern.key, options: .regularExpression) == nil {
            return "이름은 소문자로 시작하고 소문자·숫자·밑줄만 쓸 수 있습니다 (예: sandbox2)"
        }
        if server.group.range(of: ConfigPattern.key, options: .regularExpression) == nil {
            return "그룹은 소문자로 시작하고 소문자·숫자·밑줄만 쓸 수 있습니다 (예: home)"
        }
        for (label, value) in [("IP", server.ip), ("사용자", server.user)] {
            if value.isEmpty { return "\(label)를 입력하세요" }
            if value.range(of: ConfigPattern.account, options: .regularExpression) == nil {
                return "\(label)는 영문·숫자로 시작하고 영문·숫자·점(.)·밑줄(_)·하이픈(-)만 쓸 수 있습니다"
            }
        }
        if let problem = extraUsersProblem(user: server.user, extras: server.extraUsers) { return problem }
        if !(1...65535).contains(server.port) { return "포트는 1~65535 사이여야 합니다" }
        for (label, value) in [("역할", server.role), ("태그", server.env), ("VPN 이름", server.vpn)] {
            if let value, ConfigLine.breaksLine(value) { return "\(label)에 # [ 줄바꿈은 쓸 수 없습니다" }
        }
        return nil
    }

    private static func extraUsersProblem(user: String, extras: [String]) -> String? {
        var seen: Set<String> = [user]
        for name in extras {
            if name.range(of: ConfigPattern.account, options: .regularExpression) == nil {
                return "추가 계정은 영문·숫자로 시작하고 영문·숫자·점(.)·밑줄(_)·하이픈(-)만 쓸 수 있습니다"
            }
            if !seen.insert(name).inserted { return "같은 사용자를 두 번 적을 수 없습니다: \(name)" }
        }
        return nil
    }

    /// 파일 끝에 [키] 블록을 붙인 텍스트. 입력·키 중복·결과 파싱 중 하나라도 실패하면 ConfigError. notify 는 켤 때만 줄을 쓴다(기본 off).
    public static func appending(_ server: NewServer, notify: Bool = false, to text: String, reference: String = "servers.conf") throws -> String {
        if let problem = problem(server) {
            throw ConfigError(problem: problem, fix: "입력값을 고치세요.", reference: reference)
        }
        let current = try ServerConfigParser.parse(text, reference: reference)
        if current.server(server.key) != nil {
            throw ConfigError(problem: "이미 있는 이름입니다 (\(server.key)).", fix: "다른 이름을 쓰세요.", reference: reference)
        }
        // 편집과 같은 줄·순서 (basicFields) — 값이 없는 줄은 쓰지 않는다
        let block = ["[\(server.key)]"] + basicFields(server, notify: notify).compactMap { field in field.value.map { "\(field.name)=\($0)" } }

        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        let result = body + "\n\n" + block.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(result, reference: reference)
        return result
    }

    /// 내부망 설정이 없는 목록에 [network:lan] service= 블록을 넣은 텍스트 — 첫 Intranet 서버를 추가·편집할 때 서버 블록과 함께 쓴다.
    /// 첫 블록 앞(머리 주석 뒤)에 둔다. service= 가 빈 [network:lan] 머리만 있으면 그 블록에 넣는다.
    /// 이미 있으면 ConfigError (서비스 바꾸기는 Intranet 화면 → lan.json).
    public static func addingLanService(_ service: String, to text: String, reference: String = "servers.conf") throws -> String {
        let name = service.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !ConfigLine.breaksLine(name) else {
            throw ConfigError(problem: "내부망 서비스 이름을 쓸 수 없습니다: '\(service)'", fix: "# [ 줄바꿈이 없는 서비스를 고르세요.", reference: reference)
        }
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard current.lan == nil else {
            throw ConfigError(problem: "내부망 설정([network:lan])이 이미 있습니다.", fix: "서비스는 Intranet 화면에서 바꾸세요.", reference: reference)
        }
        // 머리만 있고 service= 가 비었다 (파서는 내부망 없음으로 본다) — 그 블록을 채운다
        var existing = lines(of: text)
        if headerLines(in: existing).contains(where: { $0.name == "network:lan" }) {
            setFields([("service", name)], key: "network:lan", in: &existing)
            let filled = existing.joined(separator: "\n") + "\n"
            _ = try ServerConfigParser.parse(filled, reference: reference)
            return filled
        }
        let block = "[network:lan]\nservice=\(name)\n"
        var all = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let result: String
        if let first = all.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
            // 첫 블록 바로 위에 붙은 주석(빈 줄 없이)은 그 블록의 것 — 그 위에 넣는다. 파일 처음부터 이어진 주석은 머리 주석이라 그 뒤에.
            var at = first
            while at > 0, ConfigLine.isComment(all[at - 1]) { at -= 1 }
            if at == 0 { at = first }
            all.insert(block, at: at)   // 블록 뒤 빈 줄은 block 끝의 \n 이 만든다
            result = all.joined(separator: "\n")
        } else {
            var body = all.joined(separator: "\n")
            while body.hasSuffix("\n") { body.removeLast() }
            result = (body.isEmpty ? "" : body + "\n\n") + block
        }
        _ = try ServerConfigParser.parse(result, reference: reference)
        return result
    }

    /// 그 서버를 참조하는 곳 (wol_via · db_jump). 지울 때 함께 정리한다 — 확인 창에 미리 보여 준다.
    public static func references(to key: String, in config: ServerConfig) -> [String] {
        var found = config.servers.filter { $0.wolRoutes.contains { $0.via == key } }.map { "\($0.key) 의 wol_via" }
        for group in config.groups where config.settings(for: group)?.dbJump == key { found.append("[group:\(group)] 의 db_jump") }
        return found
    }

    /// [키] 블록을 뺀 텍스트. 블록은 헤더부터 다음 헤더 앞의 마지막 설정 줄까지 — 다음 블록 위에 붙은 주석은 남긴다.
    /// 그 서버를 가리키던 설정도 함께 정리한다: 다른 서버의 깨우기 경로에서 빼고(경로가 다 빠지면 wol_mac 도), 그룹의 db_jump 줄을 지운다.
    public static func removing(key: String, from text: String, reference: String = "servers.conf") throws -> String {
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard current.server(key) != nil else {
            throw missingServer(key, reference: reference)
        }
        var all = lines(of: text)
        for server in current.servers where server.wolRoutes.contains(where: { $0.via == key }) {
            let routes = server.wolRoutes.filter { $0.via != key }.map(\.text).joined(separator: ",")
            setFields(routes.isEmpty ? [("wol_mac", nil), ("wol_via", nil)] : [("wol_via", routes)], key: server.key, in: &all)
        }
        // [group:…] 머리 전체를 본다 — 파서의 그룹 목록엔 서버가 있는 그룹만 있다 (남기면 나중에 그 그룹에 서버를 넣을 때 저장이 막힌다)
        for group in groupHeaders(in: all) where fieldValue("db_jump", key: group, in: all) == key {
            setFields([("db_jump", nil)], key: group, in: &all)
        }
        guard let span = blockSpan(key, in: all) else {
            throw ConfigError(problem: "'\(key)' 블록 헤더를 찾지 못했습니다.", fix: "servers.conf 에서 직접 지우세요.", reference: reference)
        }
        let start = span.header
        all.removeSubrange(start...span.last)
        // 빠진 자리 앞뒤로 빈 줄이 겹치면 하나만 남긴다
        if start < all.count, all[start].trimmingCharacters(in: .whitespaces).isEmpty,
           start == 0 || all[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            all.remove(at: start)
        }
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
        let result = all.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(result, reference: reference)
        return result
    }

    // MARK: 기본 항목 편집 (이름은 +Rename 의 renaming)

    /// 기본 항목(그룹·망·종류·IP·사용자·포트·역할·태그·알림)을 servers.conf 에 쓸 값. nil 이면 그 줄을 지운다.
    static func basicFields(_ s: NewServer, notify: Bool) -> [(name: String, value: String?)] {
        [("group", s.group), ("network", s.network.rawValue), ("vpn", vpnField(s)), ("type", s.type.rawValue), ("ip", s.ip), ("user", s.user),
         ("extra_users", extraUsersField(s)), ("port", String(s.port)), ("role", trimmed(s.role)), ("env", trimmed(s.env)), ("notify", notify ? "on" : nil)]
    }

    /// extra_users= 에 쓸 값. 계정이 하나면 줄을 쓰지 않는다
    static func extraUsersField(_ s: NewServer) -> String? {
        s.extraUsers.isEmpty ? nil : s.extraUsers.joined(separator: ",")
    }

    /// vpn= 에 쓸 값: network=vpn 이고 이름을 골랐을 때만 (망을 바꾸면 줄을 지운다)
    static func vpnField(_ s: NewServer) -> String? {
        s.network == .vpn ? trimmed(s.vpn) : nil
    }

    /// 편집 입력값 문제를 한 줄로. 바꾼 칸만 검사한다 — 파일에 이미 있는 값은 파서가 받아 준 것이라, 추가 때 규칙으로 막으면
    /// (예: group=home-lab) 알림 토글 하나도 저장하지 못한다. 그룹의 db_jump 서버는 그룹을 옮기면 DB Tunnel 이 사라지므로 막는다.
    public static func problem(editing edited: NewServer, from original: Server, in config: ServerConfig) -> String? {
        let o = NewServer(original)
        // 이름은 renaming 이 따로 바꾼다 — 여기 오는 값은 늘 원래 이름이다
        if edited.key != o.key { return "이름은 바꿀 수 없습니다" }
        // 안 바꾼 칸은 규칙을 통과하는 자리값으로 두고 추가 때와 같은 검사(problem)를 돌린다
        var probe = NewServer(key: "a", group: "a", network: edited.network, type: edited.type, ip: "a", user: "a", port: 22)
        if edited.group != o.group { probe.group = edited.group }
        if edited.ip != o.ip { probe.ip = edited.ip }
        if edited.user != o.user { probe.user = edited.user }
        if edited.port != o.port { probe.port = edited.port }
        if trimmed(edited.role) != trimmed(o.role) { probe.role = edited.role }
        if trimmed(edited.env) != trimmed(o.env) { probe.env = edited.env }
        if trimmed(edited.vpn) != trimmed(o.vpn) { probe.vpn = edited.vpn }
        if let problem = problem(probe) { return problem }
        // 추가 계정은 사용자 칸에서 고친다 — 그대로면 겹침만 본다 (파서가 받아 준 형식 때문에 다른 칸 저장이 막히지 않게)
        if edited.extraUsers != o.extraUsers, let problem = extraUsersProblem(user: edited.user, extras: edited.extraUsers) { return problem }
        if edited.extraUsers.contains(edited.user) { return "같은 사용자를 두 번 적을 수 없습니다: \(edited.user)" }
        if edited.group != o.group, config.settings(for: o.group)?.dbJump == o.key {
            return "[group:\(o.group)] 의 db_jump 라 그룹을 옮길 수 없습니다 (DB Tunnel 이 사라집니다)"
        }
        return nil
    }

    /// 편집 창에서 바꾼 항목만 지금 파일에 쓴다 — 창을 연 뒤 파일을 직접 고쳤어도(Reload 전) 손대지 않은 줄은 덮지 않는다.
    /// 바뀌지 않은 줄은 그대로(뒤 주석 유지). 결과는 파서로 다시 읽어 확인한다.
    public static func updating(_ edited: NewServer, notify: Bool, from original: Server, in text: String,
                                reference: String = "servers.conf") throws -> String {
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard current.server(original.key) != nil else {
            throw missingServer(original.key, reference: reference)
        }
        if let problem = problem(editing: edited, from: original, in: current) {
            throw ConfigError(problem: problem, fix: "입력값을 고치세요.", reference: reference)
        }
        let before = Dictionary(uniqueKeysWithValues: basicFields(NewServer(original), notify: original.notify).map { ($0.name, $0.value) })
        var all = lines(of: text)
        setFields(basicFields(edited, notify: notify).filter { (before[$0.name] ?? nil) != $0.value }, key: original.key, in: &all)
        let result = all.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(result, reference: reference)
        return result
    }

    /// 파일에 원자적으로 쓴다 (임시 파일 → 교체). 권한은 원본을 따른다.
    public static func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let mode = attributes?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    // MARK: 텍스트 도우미 (다른 파일의 extension 도 쓴다)

    /// [키] 블록에서 주어진 줄만 바꾼다. 값이 nil 이면 그 줄을 지운다. 기존 줄은 제자리에서, 새 줄은 블록 마지막 설정 줄 뒤에.
    static func setFields(_ fields: [(name: String, value: String?)], key: String, in all: inout [String]) {
        for (name, value) in fields {
            guard let span = blockSpan(key, in: all) else { return }
            // 파서는 같은 이름이 여러 번이면 마지막 값을 쓴다 — 전부 지우고 한 줄로
            let existing = (span.header + 1..<span.next).filter { fieldName(all[$0]) == name }
            for i in existing.reversed() { all.remove(at: i) }
            guard let value else { continue }
            // 없던 줄이면 지운 것도 없다 — span.last 가 그대로 마지막 설정 줄
            all.insert("\(name)=\(value)", at: existing.first ?? span.last + 1)
        }
    }

    /// [키] 블록의 그 줄 값 (뒤 주석 뺀). 같은 이름이 여러 번이면 파서처럼 마지막 값.
    static func fieldValue(_ name: String, key: String, in all: [String]) -> String? {
        guard let span = blockSpan(key, in: all) else { return nil }
        guard let line = (span.header + 1..<span.next).last(where: { fieldName(all[$0]) == name }).map({ all[$0] }), let eq = line.firstIndex(of: "=") else { return nil }
        return ConfigLine.content(String(line[line.index(after: eq)...]))
    }

    static func fieldName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !ConfigLine.isComment(t), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    static func lines(of text: String) -> [String] {
        var all = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        return all
    }

    static func headerLines(in lines: [String]) -> [(name: String, line: Int)] {
        lines.enumerated().compactMap { i, raw in
            ConfigLine.header(ConfigLine.content(raw)).map { ($0, i) }
        }
    }

    /// [group:…] 머리 이름 전부 ("group:이름" 꼴 그대로 — setFields·fieldValue 의 key)
    static func groupHeaders(in lines: [String]) -> [String] {
        headerLines(in: lines).map(\.name).filter { $0.hasPrefix("group:") }
    }

    /// [이름] 블록의 줄 범위: 머리(header) · 마지막 설정 줄(last — 다음 블록 위의 빈 줄·주석은 뺀다) · 다음 머리 자리(next, 없으면 줄 수).
    /// 머리가 없으면 nil.
    static func blockSpan(_ name: String, in all: [String]) -> (header: Int, last: Int, next: Int)? {
        let headers = headerLines(in: all)
        guard let index = headers.firstIndex(where: { $0.name == name }) else { return nil }
        let header = headers[index].line
        let next = index + 1 < headers.count ? headers[index + 1].line : all.count
        var last = next - 1
        while last > header, isBlankOrComment(all[last]) { last -= 1 }
        return (header, last, next)
    }

    static func missingServer(_ key: String, reference: String) -> ConfigError {
        ConfigError(problem: "'\(key)' 가 servers.conf 에 없습니다.", fix: "보기 ▸ servers.conf 다시 읽기(⌘⇧R)로 목록을 다시 읽으세요.", reference: reference)
    }

    static func isBlankOrComment(_ line: String) -> Bool {
        ConfigLine.isBlankOrComment(line)
    }

    static func trimmed(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }
}
