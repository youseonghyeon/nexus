// 주기 갱신의 읽기 줄이기: 한 라운드 안의 같은 읽기는 한 번만(SharedReads), 라운드를 넘는 느린 값은 시간·조건으로(TimedValue).
//   SharedReads      5초 갱신 한 바퀴 동안만 쓴다 — 서비스 목록·ifconfig·scutil --nc list·tailscale status 를 StatusMonitor·VPN·유선 스냅숏·화면이 나눠 쓴다
//   GatewayCache     수동 IP 서비스의 게이트웨이 응답 (ping·ARP) — IP·게이트웨이·장치가 같으면 15초
//   VPNEgressCache   시스템 VPN 의 바깥 장치 (ps·nettop·route) — 망(기본 경로·인터넷 서비스·연결된 회선)이 같으면 45초 (찾은 것만)
// 강제(새로고침·활성화 뒤)면 캐시를 보지 않고 다시 읽어 넣는다.

import Foundation

/// 한 갱신 라운드의 읽기 공유: 아래 목록의 읽기 명령은 같은 인자면 한 번만 돌리고 결과를 나눈다 (동시에 물어도 하나를 기다린다).
/// 라운드마다 새로 만든다 — 라운드를 넘어 값을 쥐지 않으므로 낡은 값이 남지 않는다. 그 밖의 명령(ssh·ping·쓰기)은 그대로 지나간다.
public final class SharedReads: CommandRunner, @unchecked Sendable {
    private let base: any CommandRunner
    private let lock = NSLock()
    private var reads: [String: Task<CommandResult, Never>] = [:]

    public init(_ base: any CommandRunner) { self.base = base }

    /// 나눠 쓰는 명령: 상태를 바꾸지 않고, 한 라운드(수 초) 안에서 여러 곳이 같은 답을 원하는 것만
    static func shareable(_ executable: String, _ arguments: [String]) -> Bool {
        switch executable {
        case "networksetup":
            return arguments == ["-listnetworkserviceorder"] || arguments == ["-listallhardwareports"]
                || (arguments.count == 2 && arguments[0] == "-getinfo")
        case "tailscale":
            return arguments == ["status", "--json"]   // 상태 확인과 Tailscale 화면
        case "ifconfig":
            return arguments.isEmpty
        case "scutil":
            return arguments == ["--nc", "list"] || (arguments.count == 3 && arguments[0] == "--nc" && arguments[1] == "status")
        default:
            return false
        }
    }

    public func hasExecutable(_ name: String) -> Bool { base.hasExecutable(name) }

    /// 라운드 도중 사용자가 망·서비스·VPN 을 바꿨다 — 그 뒤에 묻는 읽기는 새로 돈다 (전에 받아 둔 답을 나누지 않는다)
    public func invalidate() {
        lock.withLock { reads.removeAll() }
    }

    public func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        guard stdin == nil, environment.isEmpty, Self.shareable(executable, arguments) else {
            return await base.run(executable, arguments, stdin: stdin, environment: environment, timeout: timeout)
        }
        let key = ([executable] + arguments).joined(separator: "\u{1F}")
        let base = self.base
        let read: Task<CommandResult, Never> = lock.withLock {
            if let running = reads[key] { return running }
            let started = Task { await base.run(executable, arguments, stdin: nil, environment: [:], timeout: timeout) }
            reads[key] = started
            return started
        }
        return await read.value
    }

    /// 조기 중단(ssh 의 Tailscale check 배너)은 나눌 일이 없다 — 그대로 넘긴다
    public func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval,
                    abortOnLine: (@Sendable (String) -> Bool)?) async -> CommandResult {
        guard abortOnLine == nil else {
            return await base.run(executable, arguments, stdin: stdin, environment: environment, timeout: timeout, abortOnLine: abortOnLine)
        }
        return await run(executable, arguments, stdin: stdin, environment: environment, timeout: timeout)
    }
}

/// 읽은 값 하나와 그때의 시각·조건. ttl 안이고 조건(key)이 같으면 다시 읽지 않는다.
public struct TimedValue<Value: Sendable>: Sendable {
    public private(set) var value: Value?
    public private(set) var at: Date?
    public private(set) var key: String = ""
    public init() {}

    /// 아직 쓸 수 있는 값 — 시간이 지났거나, 조건이 바뀌었거나, 시계가 뒤로 갔으면 nil
    public func fresh(now: Date, ttl: TimeInterval, key: String = "") -> Value? {
        guard let value, let at, self.key == key, now >= at, now.timeIntervalSince(at) < ttl else { return nil }
        return value
    }

    public mutating func store(_ value: Value, at: Date, key: String = "") {
        self.value = value
        self.at = at
        self.key = key
    }
}

/// 수동 IP 서비스의 게이트웨이 응답 (WiredSnapshot) — 서비스마다, 장치·IP·게이트웨이가 같으면 15초 동안 다시 묻지 않는다
public final class GatewayCache: @unchecked Sendable {
    public static let ttl: TimeInterval = 15
    private let lock = NSLock()
    private var entries: [String: TimedValue<Bool>] = [:]

    public init() {}

    static func key(device: String, ip: String, router: String) -> String { "\(device) \(ip) \(router)" }

    public func fresh(service: String, device: String, ip: String, router: String, now: Date) -> Bool? {
        lock.withLock { entries[service]?.fresh(now: now, ttl: Self.ttl, key: Self.key(device: device, ip: ip, router: router)) }
    }

    /// 응답 있음만 쥔다. 응답 없음이면 쥐고 있던 값도 버린다 — 꽂은 직후 첫 실패를 15초 붙들지 않고, 옛 "응답 있음" 이 남지도 않게
    public func store(_ present: Bool, service: String, device: String, ip: String, router: String, at: Date) {
        lock.withLock {
            if present { entries[service, default: TimedValue()].store(present, at: at, key: Self.key(device: device, ip: ip, router: router)) }
            else { entries[service] = nil }
        }
    }
}

/// 시스템 VPN 의 바깥 장치 (VPNEgresses.fetch — ps·nettop 두 번·route) — VPN 마다, 망 조건(network)이 같으면 45초.
/// network 는 앱이 만든다: 기본 경로·인터넷 서비스·연결된 유선·Wi-Fi 연결 (회선이 바뀌면 바깥 장치도 바뀐다)
public final class VPNEgressCache: @unchecked Sendable {
    public static let ttl: TimeInterval = 45
    private let lock = NSLock()
    private var entries: [String: TimedValue<[VPNEgress]>] = [:]

    public init() {}

    public func fetch(vpnID: String, providerBundleID: String, tunnel: String?, network: String, force: Bool = false,
                      runner: any CommandRunner, now: Date = Date()) async -> [VPNEgress] {
        let key = "\(providerBundleID) \(tunnel ?? "") \(network)"
        if !force, let cached = lock.withLock({ entries[vpnID]?.fresh(now: now, ttl: Self.ttl, key: key) }) { return cached }
        let egress = await VPNEgresses.fetch(providerBundleID: providerBundleID, tunnel: tunnel, runner: runner)
        // 못 찾은 결과(확장이 아직 소켓을 안 열었음·nettop 실패)는 쥐지 않는다 — 다음 읽기가 바로 다시 본다
        if !egress.isEmpty { lock.withLock { entries[vpnID, default: TimedValue()].store(egress, at: now, key: key) } }
        return egress
    }
}
