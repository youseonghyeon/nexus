// 서버 주소로 여는 터널: 서버마다 루프백 별칭(127.0.0.2, 127.0.0.3 …)과 /etc/hosts 이름(db.acme)을 고정 배정한다.
// 배정표는 ~/Library/Application Support/Servers/hosts.json. 한 번 배정한 번호는 서버 목록 순서가 바뀌어도 유지한다 —
// hosts 줄과 사용자의 설정 파일(JDBC URL 등)이 그 주소에 묶이기 때문이다.
// 실제 반영(별칭 추가·hosts 편집)은 root 라 lib/hosts.zsh 를 인트라넷과 같은 인증 래퍼로 돌린다. 별칭은 재부팅하면 사라져 다시 붙인다.

import Foundation

public struct HostAliasState: Codable, Sendable, Equatable {
    /// 배정 키("db" · "was-db") → 127.0.0.x
    public var assignments: [String: String]
    public init(assignments: [String: String] = [:]) { self.assignments = assignments }
}

public enum HostAliasStore {
    public static let hostsPath = "/etc/hosts"

    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("hosts.json") }

    /// 없거나 깨졌으면 빈 배정표 (다음 배정부터 다시 시작 — hosts 의 옛 줄은 표식으로 남아 있어 겹치면 교체된다)
    public static func load(from url: URL = defaultURL) -> HostAliasState {
        guard let data = try? Data(contentsOf: url) else { return HostAliasState() }
        return (try? JSONDecoder().decode(HostAliasState.self, from: data)) ?? HostAliasState()
    }

    public static func save(_ state: HostAliasState, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    /// 배정 키: 포트 터널은 서버 키, DB 터널은 "<서버키>-db" (경유 서버와 DB 를 다른 주소로). SOCKS 는 서버 주소로 열지 않지만 서버 키로 둔다.
    public static func assignmentKey(server: Server, kind: TunnelKind) -> String {
        switch kind {
        case .port, .socks: return server.key
        case .db: return "\(server.key)-db"
        }
    }

    /// 서버 이름이 바뀌었을 때 배정을 옮긴 사본 (서버 키 · "<서버키>-db"). 고정 주소가 그대로여야 그 주소의 hosts 줄·별칭을 다시 쓴다.
    public static func renaming(from old: String, to new: String, in state: HostAliasState) -> HostAliasState {
        var out = state
        for suffix in ["", "-db"] {
            if let address = out.assignments.removeValue(forKey: old + suffix) { out.assignments[new + suffix] = address }
        }
        return out
    }

    /// 기본 hosts 이름: "<서버키>.<그룹>" · DB 터널은 "<서버키>-db.<그룹>". 입력창에서 다른 이름으로 바꿀 수 있다 (isValidHostName).
    public static func hostName(server: Server, kind: TunnelKind) -> String {
        "\(assignmentKey(server: server, kind: kind)).\(server.group)"
    }

    /// 사용자가 입력한 hosts 이름: 영문·숫자·'-' 라벨(양끝은 영문·숫자, 63자 이하)을 '.' 로 이은 꼴, 전체 253자 이하.
    /// macOS 기본 항목(localhost·broadcasthost)은 표식 줄로 덧씌우면 헷갈리므로 막는다.
    public static func isValidHostName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 253, !["localhost", "broadcasthost"].contains(name.lowercased()) else { return false }
        func ok(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard let first = label.first, let last = label.last, label.count <= 63, ok(first), ok(last) else { return false }
            return label.allSatisfy { ok($0) || $0 == "-" }
        }
    }

    /// 이미 배정돼 있으면 그 주소, 아니면 127.0.0.2 부터 비어 있는 다음 번호를 배정한 새 상태와 함께 돌려준다.
    public static func assign(_ key: String, in state: HostAliasState) -> (address: String, state: HostAliasState) {
        if let existing = state.assignments[key] { return (existing, state) }
        let used = Set(state.assignments.values)
        var prefix = "127.0.0", n = 2
        while used.contains("\(prefix).\(n)") { n += 1 }
        // 127.0.0.255 는 브로드캐스트처럼 보여 피한다 — 다 찼으면 127.0.1.x 로
        if n >= 255 { prefix = "127.0.1"; n = 2; while used.contains("\(prefix).\(n)") { n += 1 } }
        let address = "\(prefix).\(n)"
        var next = state
        next.assignments[key] = address
        return (address, next)
    }

    /// 배정만 미리 본다 (입력창 미리보기용, 저장하지 않는다)
    public static func preview(_ key: String, in state: HostAliasState) -> String { assign(key, in: state).address }

    /// /etc/hosts 에 앱 표식이 붙은 "IP 이름" 줄이 있는가 (읽기만, 권한 불필요)
    public static func hostsEntryPresent(name: String, address: String, hostsText: String) -> Bool {
        hostsText.split(separator: "\n").contains { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return f.count >= 4 && f[0] == address && f[1] == name && f[2] == "#" && f[3] == HostsFile.marker
        }
    }

    /// ifconfig lo0 출력에 그 별칭이 있는가
    public static func aliasPresent(address: String, ifconfigText: String) -> Bool {
        ifconfigText.split(separator: "\n").contains { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return f.count >= 2 && f[0] == "inet" && f[1] == address
        }
    }
}

public enum HostAliasCommands {
    /// 별칭·hosts 줄이 둘 다 이미 있으면 true (인증 없이 바로 터널을 연다)
    public static func isReady(name: String, address: String, runner: any CommandRunner) async -> Bool {
        let ifconfig = await runner.run("ifconfig", ["lo0"], timeout: 5).stdout
        guard HostAliasStore.aliasPresent(address: address, ifconfigText: ifconfig) else { return false }
        let hosts = (try? String(contentsOfFile: HostAliasStore.hostsPath, encoding: .utf8)) ?? ""
        return HostAliasStore.hostsEntryPresent(name: name, address: address, hostsText: hosts)
    }

    /// 정리: "IP 이름 # servers-app" 과 정확히 같은 줄만 지우고, 그 주소를 쓰는 터널이 더 없으면 별칭도 뗀다. root (인증 한 번).
    public static func teardownScript(name: String, address: String, dropAlias: Bool, libDir: String) -> String {
        var body = "source \(shellQuote(libDir + "/hosts.zsh")) || exit 1\n_hosts_remove \(shellQuote(name)) \(shellQuote(address))"
        if dropAlias { body += "\n_hosts_unalias \(shellQuote(address))" }
        return LanCommands.privilegedScript(body: body, prompt: "\(name) 터널 주소 제거")
    }

    /// 지울 게 있는가 (hosts 줄 또는 별칭). 없으면 인증 없이 끝낸다.
    public static func needsTeardown(name: String, address: String, runner: any CommandRunner) async -> Bool {
        let hosts = (try? String(contentsOfFile: HostAliasStore.hostsPath, encoding: .utf8)) ?? ""
        if HostAliasStore.hostsEntryPresent(name: name, address: address, hostsText: hosts) { return true }
        let ifconfig = await runner.run("ifconfig", ["lo0"], timeout: 5).stdout
        return HostAliasStore.aliasPresent(address: address, ifconfigText: ifconfig)
    }

    /// 별칭 추가 + hosts 줄 설정을 root 로 (Touch ID 시트 → 승인 창). 인증 취소면 LanCommands.authFailedExitCode.
    public static func setupScript(name: String, address: String, libDir: String) -> String {
        LanCommands.privilegedScript(
            body: "source \(shellQuote(libDir + "/hosts.zsh")) || exit 1\n_hosts_alias \(shellQuote(address)) || exit 1\n_hosts_set \(shellQuote(name)) \(shellQuote(address))",
            prompt: "\(name) → \(address) 터널 주소 준비")
    }
}
