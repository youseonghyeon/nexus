// 계정 추가·제거·기본 계정 (서버 정보의 사용자 칸 — extra_users=·user= 줄만 고친다) · 두 항목을 한 서버의 계정으로 합치기.

import Foundation

extension ServerConfigEditor {
    /// 새 계정 이름의 문제 한 줄. nil 이면 추가할 수 있다.
    public static func accountProblem(_ name: String, for server: Server) -> String? {
        if server.accounts.contains(name) { return "이미 있는 계정입니다: \(name)" }
        if name.range(of: ConfigPattern.account, options: .regularExpression) == nil {
            return "계정은 영문·숫자로 시작하고 영문·숫자·점(.)·밑줄(_)·하이픈(-)만 쓸 수 있습니다"
        }
        return nil
    }

    private static func serverToEdit(_ key: String, in text: String, reference: String) throws -> Server {
        guard let server = try ServerConfigParser.parse(text, reference: reference).server(key) else {
            throw missingServer(key, reference: reference)
        }
        return server
    }

    private static func writing(_ fields: [(name: String, value: String?)], key: String, in text: String, reference: String) throws -> String {
        var all = lines(of: text)
        setFields(fields, key: key, in: &all)
        let result = all.joined(separator: "\n") + "\n"
        _ = try ServerConfigParser.parse(result, reference: reference)
        return result
    }

    public static func addingAccount(_ name: String, to key: String, in text: String, reference: String = "servers.conf") throws -> String {
        let server = try serverToEdit(key, in: text, reference: reference)
        if let problem = accountProblem(name, for: server) {
            throw ConfigError(problem: problem, fix: "다른 계정 이름을 쓰세요.", reference: reference)
        }
        return try writing([("extra_users", (server.extraUsers + [name]).joined(separator: ","))], key: key, in: text, reference: reference)
    }

    /// 추가 계정을 뺀다. 기본 계정은 뺄 수 없다 — 다른 계정을 기본으로 올린 뒤 뺀다. 그 계정의 비밀번호·키 파일은 목록을 다시 읽을 때 지워진다.
    public static func removingAccount(_ name: String, from key: String, in text: String, reference: String = "servers.conf") throws -> String {
        let server = try serverToEdit(key, in: text, reference: reference)
        guard server.extraUsers.contains(name) else {
            throw ConfigError(problem: name == server.primaryUser ? "기본 계정은 뺄 수 없습니다: \(name)" : "'\(key)' 에 없는 계정입니다: \(name)",
                              fix: name == server.primaryUser ? "다른 계정을 기본 계정으로 올린 뒤 빼세요." : "보기 ▸ servers.conf 다시 읽기(⌘⇧R)로 목록을 다시 읽으세요.", reference: reference)
        }
        let rest = server.extraUsers.filter { $0 != name }
        return try writing([("extra_users", rest.isEmpty ? nil : rest.joined(separator: ","))], key: key, in: text, reference: reference)
    }

    /// 추가 계정을 기본 계정과 맞바꾼다 (옛 기본 계정은 그 자리로). 비밀번호·키 파일은 목록을 다시 읽을 때 계정을 따라 옮겨 간다 (rekeyingCredentials).
    public static func promotingAccount(_ name: String, of key: String, in text: String, reference: String = "servers.conf") throws -> String {
        let server = try serverToEdit(key, in: text, reference: reference)
        guard server.extraUsers.contains(name) else {
            throw ConfigError(problem: name == server.primaryUser ? "이미 기본 계정입니다: \(name)" : "'\(key)' 에 없는 계정입니다: \(name)",
                              fix: "보기 ▸ servers.conf 다시 읽기(⌘⇧R)로 목록을 다시 읽으세요.", reference: reference)
        }
        let extras = server.extraUsers.map { $0 == name ? server.primaryUser : $0 }.joined(separator: ",")
        return try writing([("user", name), ("extra_users", extras)], key: key, in: text, reference: reference)
    }

    // MARK: 두 항목을 한 서버의 계정으로 합치기

    /// source 를 target 의 계정으로 합칠 수 없는 이유 한 줄. nil 이면 합칠 수 있다.
    /// 같은 장비(주소·포트·종류·망)여야 하고, 그룹이 같아야 한다 (db_jump 를 옮겨도 DB Tunnel 이 사라지지 않게).
    public static func accountMergeProblem(from source: Server, into target: Server) -> String? {
        if source.key == target.key { return "같은 서버입니다" }
        guard source.ip == target.ip, source.port == target.port else { return "주소·포트가 다른 서버는 합칠 수 없습니다" }
        guard source.type == target.type, source.network == target.network, source.vpn == target.vpn else { return "종류·망이 다른 서버는 합칠 수 없습니다" }
        guard source.group == target.group else { return "그룹이 다른 서버는 합칠 수 없습니다" }
        if let same = source.accounts.first(where: target.accounts.contains) { return "두 서버에 같은 사용자가 있습니다: \(same)" }
        return nil
    }

    /// key 를 계정으로 합쳐 넣을 수 있는 서버들 (파일 순서). 없으면 메뉴를 보이지 않는다.
    public static func accountMergeTargets(for key: String, in config: ServerConfig) -> [Server] {
        guard let source = config.server(key) else { return [] }
        return config.servers.filter { accountMergeProblem(from: source, into: $0) == nil }
    }

    /// source 블록을 지우고 그 계정을 target 의 extra_users 로 옮긴 텍스트.
    /// target 에 없는 값(역할·알림·프록시·부팅)은 가져오고 태그·터널 바로가기는 더한다 (운영 태그를 잃지 않게). 있는 값은 target 것.
    /// 다른 서버의 wol_via·그룹의 db_jump 는 지우지 않고 target 으로 돌린다. 비밀번호·키 파일은 movingCredentials.
    public static func mergingAccount(from sourceKey: String, into targetKey: String, in text: String, reference: String = "servers.conf") throws -> String {
        let current = try ServerConfigParser.parse(text, reference: reference)
        guard let source = current.server(sourceKey), let target = current.server(targetKey) else {
            throw ConfigError(problem: "'\(sourceKey)' 또는 '\(targetKey)' 가 servers.conf 에 없습니다.", fix: "보기 ▸ servers.conf 다시 읽기(⌘⇧R)로 목록을 다시 읽으세요.", reference: reference)
        }
        if let problem = accountMergeProblem(from: source, into: target) {
            throw ConfigError(problem: "\(sourceKey) 를 \(targetKey) 에 합칠 수 없습니다: \(problem)", fix: "주소·포트·종류·망·그룹이 같은 서버끼리 합치세요.", reference: reference)
        }
        var all = lines(of: text)

        var fields: [(name: String, value: String?)] = [("extra_users", (target.extraUsers + source.accounts).joined(separator: ","))]
        if trimmed(target.role) == nil, let role = trimmed(source.role) { fields.append(("role", role)) }
        let newTags = source.tags.filter { tag in !target.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        if !newTags.isEmpty { fields.append(("env", ([target.env].compactMap(trimmed) + [newTags.joined(separator: ", ")]).joined(separator: ", "))) }
        if source.notify, !target.notify { fields.append(("notify", "on")) }
        var actions = Actions(target)
        actions.tunnelPorts += source.tunnelPorts.filter { new in !target.tunnelPorts.contains { $0.port == new.port } }
        if actions.proxyPort == nil { actions.proxyPort = source.proxyPort }
        // 자기를 깨우는 경로는 뺀다 (같은 장비가 된다) — 다 빠지면 MAC 도
        actions.wolRoutes.removeAll { $0.via == sourceKey }
        if actions.wolRoutes.isEmpty, let mac = target.wolMac ?? source.wolMac {
            actions.wolRoutes = source.wolRoutes.filter { $0.via != targetKey }
            actions.wolMac = actions.wolRoutes.isEmpty ? nil : mac
        }
        // 값이 그대로인 줄은 건드리지 않는다 (뒤 주석 유지)
        let before = Dictionary(uniqueKeysWithValues: Actions(target).fields.map { ($0.name, $0.value) })
        fields += actions.fields.filter { (before[$0.name] ?? nil) != $0.value }
        setFields(fields, key: targetKey, in: &all)

        for server in current.servers where ![sourceKey, targetKey].contains(server.key) && server.wolRoutes.contains(where: { $0.via == sourceKey }) {
            var routes: [WakeRoute] = []
            for route in server.wolRoutes {
                let moved = route.via == sourceKey ? WakeRoute(via: targetKey, iface: route.iface) : route
                if !routes.contains(where: { $0.via == moved.via }) { routes.append(moved) }
            }
            setFields([("wol_via", routes.map(\.text).joined(separator: ","))], key: server.key, in: &all)
        }
        for group in groupHeaders(in: all) where fieldValue("db_jump", key: group, in: all) == sourceKey {
            setFields([("db_jump", targetKey)], key: group, in: &all)
        }
        return try removing(key: sourceKey, from: all.joined(separator: "\n") + "\n", reference: reference)
    }
}
