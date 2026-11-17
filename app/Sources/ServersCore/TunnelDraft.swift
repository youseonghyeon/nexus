// 터널 포트 입력창의 판정: 입력 문자열들 → 원격·로컬 포트, 원격 호스트, 이름 문제, [열기] 가능 여부.
// 화면(TunnelPromptSheet)은 칸 값을 넘기고 결과만 그린다. 이름 충돌·기본 이름은 AppModel 이 알아 인자로 받는다.

import Foundation

public struct TunnelDraft: Sendable, Equatable {
    /// 원격 포트 칸 · 로컬 포트 칸 · 원격 호스트 칸 · hosts 이름 칸
    public var remote: String
    public var local: String
    public var host: String
    public var name: String
    /// 서버 주소로 열기 (루프백 별칭 + hosts 이름)
    public var named: Bool
    /// DB 터널은 원격이 servers.conf 값으로 고정 — 원격 칸 대신 이 포트를 쓴다
    public var fixedRemotePort: Int?

    public init(remote: String = "", local: String = "", host: String = "", name: String = "", named: Bool, fixedRemotePort: Int? = nil) {
        self.remote = remote; self.local = local; self.host = host; self.name = name; self.named = named; self.fixedRemotePort = fixedRemotePort
    }

    /// 이름 형식이 틀렸을 때의 안내
    public static let invalidNameMessage = "이름은 영문·숫자·하이픈(-)·점(.)만 쓸 수 있습니다 (예: api.acme)"

    public var isDB: Bool { fixedRemotePort != nil }

    /// 1...65535 만. 원격 칸은 앞뒤 공백을 떼고 읽는다 (" 6443" 이 안내 없이 [열기]를 막았다)
    public var remotePort: Int? {
        if let fixedRemotePort { return fixedRemotePort }
        return Self.port(remote.trimmingCharacters(in: .whitespaces))
    }

    /// 비우면 원격과 같은 포트(특권 포트면 +8000)
    public var localPort: Int? {
        if local.isEmpty { return remotePort.map { PortAllocator.suggestedLocalPort(forRemote: $0) } }
        return Self.port(local)
    }

    /// ssh -L 대상 호스트. 형식이 틀리면 nil
    public var remoteHost: String? { TunnelTarget.remoteHost(host) }

    public var localIsPrivileged: Bool { localPort.map(PortAllocator.isPrivileged) ?? false }

    /// 실제로 쓸 hosts 이름: 입력값(공백 제거), 비었으면 기본 이름
    public func hostName(defaultName: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    /// 서버 주소 모드에서 이름을 쓸 수 없는 이유 (형식 · 다른 터널과 충돌). nil 이면 열 수 있다.
    /// conflict 는 형식이 맞을 때만 부른다 (hosts 이름 → 충돌 안내)
    public func nameProblem(defaultName: String, conflict: (String) -> String?) -> String? {
        guard named else { return nil }
        let hostName = hostName(defaultName: defaultName)
        guard HostAliasStore.isValidHostName(hostName) else { return Self.invalidNameMessage }
        return conflict(hostName)
    }

    /// [열기]: 두 포트가 있고, 로컬이 특권 포트가 아니고, 이름 문제가 없고, (포트 터널이면) 원격 호스트 형식이 맞을 때
    public func canOpen(nameProblem: String?) -> Bool {
        remotePort != nil && localPort != nil && !localIsPrivileged && nameProblem == nil && (isDB || remoteHost != nil)
    }

    private static func port(_ text: String) -> Int? {
        Int(text).flatMap { (1...65535).contains($0) ? $0 : nil }
    }
}
