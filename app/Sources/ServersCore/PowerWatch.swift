// 서버 전원 전이 감지 (notify=on 서버의 켜짐·꺼짐 알림). 5초 갱신 결과를 여러 번 연속 같은 값으로 봐야 전이로 친다.
// 거짓 "꺼짐" 을 막는 게 우선이다: 이 Mac 쪽 사정으로 모르는 회차는 판단에서 빼고, 꺼짐은 켜짐보다 오래 확인한다.

import Foundation

public enum PowerState: Sendable, Equatable { case up, down }
public enum PowerEvent: Sendable, Equatable { case booted, shutDown }

public struct PowerWatch: Sendable {
    /// 켜짐으로 치기까지 연속 확인 횟수 (5초 간격이면 약 10초). 서버가 응답했다는 건 확실한 신호라 짧게.
    public static let upConfirmations = 2
    /// 꺼짐은 약 20초 — Windows 쪽 Tailscale 재시작·경로 흔들림으로 잠깐 끊긴 걸 꺼짐으로 알리지 않게
    public static let downConfirmations = 4
    /// 잠자기에서 깬 뒤 판단을 쉬는 시간. 깬 직후엔 망이 덜 올라와 확인이 실패한다.
    public static let wakeQuietPeriod: TimeInterval = 30
    /// 이만큼 모르는 채로 지나면(잠자기·Tailscale 을 꺼 둠) 그 사이 바뀐 건 알리지 않고 조용히 기준을 다시 잡는다 — 알림은 "지금" 일어난 일만
    public static let staleAfter: TimeInterval = 300

    private var stable: [String: PowerState] = [:]
    private var candidate: [String: PowerState] = [:]
    private var streak: [String: Int] = [:]
    private var lastKnownAt: [String: Date] = [:]
    private var quietUntil: Date?

    public init() {}

    /// 스냅샷에서 읽은 서버 전원 상태. 이 Mac 쪽 사정으로 알 수 없으면 nil.
    /// 꺼짐(확인 실패·피어 offline)은 같은 망의 다른 서버가 응답할 때만 믿는다 — 이 Mac 의 인터넷이 끊겨도
    /// Tailscale 은 Running·피어 online 을 그대로 보여 줘서, 확인 실패만으로는 서버가 꺼진 건지 알 수 없다.
    public static func state(of server: Server, in snapshot: StatusSnapshot, among servers: [Server]) -> PowerState? {
        let down: Bool
        switch snapshot.remote(server.key) {
        case .ok: return .up
        case .fail, .off: down = true
        case .skip:
            // Tailscale 은 정상인데 피어가 offline. 그 밖의 skip(Tailscale·내부망 꺼짐, 피어 없음)은 이 Mac 쪽 사정.
            down = server.network == .tailscale && snapshot.tailscale == .running && snapshot.peer(server.key) == .offline
        case .pending, .needsAuth:
            return nil
        }
        guard down else { return nil }
        // 인증 필요(Tailscale SSH check)도 그 서버까지 닿았다는 뜻이다
        let witnessed = servers.contains { other in
            guard other.key != server.key, other.network == server.network else { return false }
            if server.network == .vpn, other.vpn != server.vpn { return false }   // 같은 VPN 너머여야 근거가 된다
            // Direct 는 망 단계가 없어 서버마다 경로가 다를 수 있다 (VPN 너머 · 공인 IP) — 같은 /24 만 근거로
            if server.network == .direct, !Self.sameSubnet24(server.ip, other.ip) { return false }
            switch snapshot.remote(other.key) {
            case .ok, .needsAuth: return true
            default: return false
            }
        }
        return witnessed ? .down : nil
    }

    /// IPv4 앞 세 자리가 같은가. IPv4 가 아니면(호스트 이름·IPv6) 같다고 보지 않는다
    static func sameSubnet24(_ a: String, _ b: String) -> Bool {
        func prefix(_ ip: String) -> [Substring]? {
            let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
            return Array(parts.prefix(3))
        }
        guard let pa = prefix(a), let pb = prefix(b) else { return false }
        return pa == pb
    }

    /// 이 Mac 이 잠자기에서 깼다: wakeQuietPeriod 동안 관찰을 모름으로 친다.
    public mutating func noteWake(at now: Date) {
        quietUntil = now.addingTimeInterval(Self.wakeQuietPeriod)
    }

    /// 관찰 한 번. 확인된 전이면 이벤트를 돌려준다. 처음 확정되는 상태(앱 시작·notify 를 막 켬·오래 모른 뒤)는 알리지 않고 기억만 한다.
    /// nil(모름)은 연속 확인을 끊는다 — 모르는 회차를 사이에 두고 이어 붙이지 않는다.
    public mutating func observe(_ key: String, _ observed: PowerState?, at now: Date) -> PowerEvent? {
        let quiet = quietUntil.map { now < $0 } ?? false
        guard let state = quiet ? nil : observed else {
            candidate[key] = nil; streak[key] = nil
            return nil
        }
        if let last = lastKnownAt[key], now.timeIntervalSince(last) > Self.staleAfter { stable[key] = nil }
        lastKnownAt[key] = now
        guard stable[key] != state else {
            candidate[key] = nil; streak[key] = nil
            return nil
        }
        let count = candidate[key] == state ? (streak[key] ?? 0) + 1 : 1
        guard count >= (state == .up ? Self.upConfirmations : Self.downConfirmations) else {
            candidate[key] = state; streak[key] = count
            return nil
        }
        let previous = stable[key]
        stable[key] = state; candidate[key] = nil; streak[key] = nil
        guard previous != nil else { return nil }
        return state == .up ? .booted : .shutDown
    }

    /// 한 서버의 기록을 지운다 (접속 정보가 바뀜 — 같은 키가 다른 서버를 가리킨다). 다음 확정은 조용히.
    public mutating func forget(_ key: String) {
        stable[key] = nil; candidate[key] = nil; streak[key] = nil; lastKnownAt[key] = nil
    }

    /// 목록에서 빠졌거나 notify 를 끈 서버의 기록을 지운다 (다시 켜면 처음부터 조용히 시작).
    public mutating func retain(keys: Set<String>) {
        for key in Set(stable.keys).union(candidate.keys).union(lastKnownAt.keys) where !keys.contains(key) { forget(key) }
    }
}
