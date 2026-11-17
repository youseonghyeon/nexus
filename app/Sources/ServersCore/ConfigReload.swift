// servers.conf 를 다시 읽을 때 서버별로 무엇을 버릴지 가른다 — AppModel.loadConfig 는 이 분류를 적용만 한다.
// 같은 키가 다른 서버를 가리킬 수 있어(주소·망을 고침, 지웠다 같은 이름으로 다시 추가) 옛 값이 새 서버에 보이면 안 된다.
// 상태 표는 ConfigReloadTests.

import Foundation

public struct ConfigReloadChanges: Sendable, Equatable {
    /// 접속 정보가 바뀐 서버의 옛 값 (Server.sameConnection 이 아님 — 주소·포트·망·종류·VPN, 옛 기본 계정이 빠짐).
    /// 원격 정보·실시간·전원 판정·상태·계정별 캐시를 버리고 옛 주소로 열린 터널을 끊는다. 옛 값이라 옛 계정 목록을 그대로 쓴다
    public var connectionChanged: [Server] = []
    /// 접속은 같고 이 값의 계정만 바뀐 서버 키 (고른 계정이 목록에서 빠져 기본 계정으로) — 원격 정보·실시간만 새 계정으로
    public var accountChanged: [String] = []
    /// 목록에서 사라진 서버 키 — 키별 상태를 모두 버린다 (같은 키로 다시 추가했을 때 옛 상태가 보이지 않게)
    public var removed: [String] = []

    public init(connectionChanged: [Server] = [], accountChanged: [String] = [], removed: [String] = []) {
        self.connectionChanged = connectionChanged; self.accountChanged = accountChanged; self.removed = removed
    }

    /// 지금 도는 상태 확인을 버려야 하는가: 옛 목록으로 확인 중이라, 끝나면서 버린 상태(옛 주소·사라진 서버)를 되살린다.
    /// 계정만 바뀐 건 상태를 버리지 않으므로 해당 없음
    public var discardsRunningRefresh: Bool { !connectionChanged.isEmpty || !removed.isEmpty }

    /// old = 지금 목록 (첫 읽기면 nil — 버릴 것 없음), loaded = 새로 읽은 목록 (고른 계정을 적용한 값).
    /// 새로 생긴 서버는 버릴 옛 값이 없어 어디에도 들지 않는다. 순서는 connectionChanged·accountChanged 는 새 목록, removed 는 옛 목록 순서
    public static func between(old: ServerConfig?, loaded: ServerConfig) -> ConfigReloadChanges {
        guard let old else { return ConfigReloadChanges() }
        var changes = ConfigReloadChanges()
        for server in loaded.servers {
            guard let before = old.server(server.key) else { continue }
            if !server.sameConnection(as: before) {
                changes.connectionChanged.append(before)
            } else if before.user != server.user {
                changes.accountChanged.append(server.key)
            }
        }
        changes.removed = old.servers.filter { loaded.server($0.key) == nil }.map(\.key)
        return changes
    }
}
