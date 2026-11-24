// 최근 터널 기록. 앱을 다시 켜도 터널 카드·TUNNELS 에 닫힘 상태로 남아 열기/다시 연결로 같은 조건으로 다시 연다.
// 저장: ~/Library/Application Support/Servers/recent.json (저장소 밖). 같은 터널(서버·종류·원격 대상)은 하나로 합치고 서버당 최근 10개.

import Foundation

public struct RecentTunnel: Codable, Sendable, Equatable, Identifiable {
    public let serverKey: String
    public let kind: TunnelKind
    public var localPort: Int
    public var lastUsed: Date
    /// 서버 주소로 연 터널 (루프백 별칭·hosts 이름). 없으면 localhost.
    public var bindAddress: String?
    public var hostName: String?
    /// 터널을 연 계정 (extra_users 서버). 없으면(옛 기록) 지금 고른 계정.
    public var user: String?

    public init(serverKey: String, kind: TunnelKind, localPort: Int, lastUsed: Date = Date(), bindAddress: String? = nil, hostName: String? = nil, user: String? = nil) {
        self.user = user
        self.serverKey = serverKey
        self.kind = kind
        self.localPort = localPort
        self.lastUsed = lastUsed
        self.bindAddress = bindAddress
        self.hostName = hostName
    }

    /// 같은 터널로 보는 기준 (로컬 포트는 빼고)
    public var id: String {
        switch kind {
        case let .port(remotePort, remoteHost): return "\(serverKey)|port|\(remoteHost):\(remotePort)"
        case let .db(host, port, _): return "\(serverKey)|db|\(host):\(port)"
        case .socks: return "\(serverKey)|socks"
        }
    }

    public var summary: String {
        switch kind {
        case let .port(remote, host): return "localhost:\(localPort) → \(serverKey) \(host == "127.0.0.1" ? "localhost" : host):\(remote)"
        case let .db(host, port, _): return "localhost:\(localPort) → \(serverKey) → \(host):\(port)"
        case .socks: return "socks5://localhost:\(localPort) → \(serverKey) 경유"
        }
    }
}

public struct RecentState: Codable, Sendable, Equatable {
    public var tunnels: [RecentTunnel] = []
    public init(tunnels: [RecentTunnel] = []) { self.tunnels = tunnels }
}

public enum RecentStore {
    public static let perServerLimit = 10

    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("recent.json") }

    /// 없거나 깨졌으면 빈 상태 (기록은 부가 기능이라 오류로 막지 않는다)
    public static func load(from url: URL = defaultURL) -> RecentState {
        (try? AppSupport.readJSON(RecentState.self, from: url, isoDates: true)) ?? RecentState()
    }

    public static func save(_ state: RecentState, to url: URL = defaultURL) throws {
        try AppSupport.writeJSON(state, to: url, isoDates: true)
    }

    /// 기록 추가·갱신: 같은 id 는 로컬 포트·시각만 갱신. 최근 순으로 정렬하고 서버당 상한을 넘는 오래된 것은 버린다.
    public static func record(_ tunnel: RecentTunnel, in state: RecentState) -> RecentState {
        var tunnels = state.tunnels.filter { $0.id != tunnel.id }
        tunnels.append(tunnel)
        tunnels.sort { $0.lastUsed > $1.lastUsed }
        var counts: [String: Int] = [:]
        tunnels = tunnels.filter { t in
            counts[t.serverKey, default: 0] += 1
            return counts[t.serverKey]! <= perServerLimit
        }
        return RecentState(tunnels: tunnels)
    }

    /// 서버 이름이 바뀌었을 때: 그 서버의 기록을 새 이름으로. 기본 hosts 이름(<키>.<그룹>)은 새 이름을 따라가고, 직접 지은 이름·계정·주소는 그대로.
    /// 새 기본 이름을 hosts 에 쓸 수 없으면(서버 이름의 밑줄) 옛 이름을 둔다 — 다시 연결이 막히지 않게.
    public static func renamingServer(_ old: Server, to new: Server, in state: RecentState) -> RecentState {
        RecentState(tunnels: state.tunnels.map { tunnel in
            guard tunnel.serverKey == old.key else { return tunnel }
            let newDefault = HostAliasStore.hostName(server: new, kind: tunnel.kind)
            let followsDefault = tunnel.hostName == HostAliasStore.hostName(server: old, kind: tunnel.kind) && HostAliasStore.isValidHostName(newDefault)
            let hostName = followsDefault ? newDefault : tunnel.hostName
            return RecentTunnel(serverKey: new.key, kind: tunnel.kind, localPort: tunnel.localPort, lastUsed: tunnel.lastUsed,
                                bindAddress: tunnel.bindAddress, hostName: hostName, user: tunnel.user)
        })
    }

    public static func remove(id: String, from state: RecentState) -> RecentState {
        RecentState(tunnels: state.tunnels.filter { $0.id != id })
    }
}
