// this Mac 화면 읽기 주기 (5초 갱신 · 화면을 열 때 · 새로고침). 예전엔 5초마다 프로세스 35개쯤(Spec 스크립트·system_profiler·방화벽 3번…)을 띄웠다.
//   바뀌지 않는 Spec(zsh·system_profiler)        처음 한 번 (빈 결과면 다음에 다시)
//   메모리·디스크·가동 시간(LocalSpecProbe)      매번 — 앱 안 API, 프로세스 없음
//   주소(ifconfig·networksetup)                 매번 — 갱신 라운드에선 유선 스냅숏과 나눠 쓴다 (SharedReads)
//   리스닝 포트(lsof) · 라우팅 표(netstat·scutil --nwi)·VPN 바깥 장치 · hosts · 방화벽(socketfilterfw 3번) · 프록시   30초에 한 번
// force(화면의 새로고침 버튼)면 전부 다시 읽는다.

import Foundation

/// 바뀌는 Spec 값을 앱 안에서 읽는다 (프로세스 없음) — 예전 zsh 의 vm_stat·df -k /·kern.boottime 과 같은 값
public enum LocalSpecProbe {
    public static func liveLines(now: Date = Date()) -> [String] {
        let page = UInt64(SystemProbe.sysctlValue("hw.pagesize", Int64.self) ?? Int64(getpagesize()))
        let memory = SystemProbe.sysctlValue("hw.memsize", UInt64.self) ?? ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let read = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        // vm_stat 의 "Pages free" 는 free − speculative 라 free·inactive·speculative 셋을 더하면 free + inactive
        let available = read == KERN_SUCCESS ? (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * page : 0
        var root = statfs()
        let disk: (total: UInt64, available: UInt64) = statfs("/", &root) == 0
            ? (root.f_blocks * UInt64(root.f_bsize) / 1024, root.f_bavail * UInt64(root.f_bsize) / 1024) : (0, 0)
        let boot = SystemProbe.sysctlValue("kern.boottime", timeval.self).map { Int($0.tv_sec) }
        let uptime = boot.map { Int(now.timeIntervalSince1970) - $0 } ?? 0
        return LocalCommands.liveSpecLines(memoryTotal: memory, memoryAvailable: available, diskTotalKB: disk.total, diskAvailableKB: disk.available, uptime: uptime)
    }
}

public actor LocalInfoCollector {
    public static let slowInterval: TimeInterval = 30

    struct Slow: Sendable {
        var routes: RouteTable?
        var hosts: [HostsEntry]?
        var firewall: FirewallState?
        var proxies: [String]
    }

    private var staticSpec: [String] = []
    private var ports = TimedValue<[LocalPort]>()
    private var slow = TimedValue<Slow>()
    private let liveSpec: @Sendable () -> [String]

    /// liveSpec: 바뀌는 Spec 줄 (테스트는 고정 값)
    public init(liveSpec: @escaping @Sendable () -> [String] = { LocalSpecProbe.liveLines() }) {
        self.liveSpec = liveSpec
    }

    /// vpns·egressCache·network: Routes 카드의 utun 줄 끝 "→ en11" (연결된 시스템 VPN 의 바깥 장치 — VPNEgressCache)
    public func collect(runner: any CommandRunner, force: Bool = false, vpns: [SystemVPN] = [], egressCache: VPNEgressCache? = nil,
                        network: String = "", slowKey: String = "", now: Date = Date()) async -> LocalInfo {
        let needStatic = force || staticSpec.isEmpty
        let needPorts = force || ports.fresh(now: now, ttl: Self.slowInterval) == nil
        // slowKey(망·VPN·Tailscale 상태)가 바뀌면 30초를 기다리지 않는다 — 켜고 끈 뒤 Routes 가 토글 전 경로로 남지 않게
        let needSlow = force || slow.fresh(now: now, ttl: Self.slowInterval, key: slowKey) == nil
        async let staticRead: [String]? = needStatic ? Self.readStaticSpec(runner: runner) : nil
        async let addressRead = LocalInfoFetcher.addresses(runner: runner)
        async let portsRead: [LocalPort]? = needPorts ? LocalInfoFetcher.listeningPorts(runner: runner) : nil
        async let slowRead: Slow? = needSlow ? Self.readSlow(runner: runner, vpns: vpns, egressCache: egressCache, network: network, force: force) : nil
        if let lines = await staticRead, !lines.isEmpty { staticSpec = lines }
        let addresses = await addressRead
        if let read = await portsRead { ports.store(read, at: now) }
        if let read = await slowRead { slow.store(read, at: now, key: slowKey) }
        let spec = RemoteInfo.parseSpec(LocalCommands.mergeSpec(static: staticSpec, live: liveSpec()))
        let extra = slow.value
        return LocalInfo(spec: spec, addresses: addresses, ports: ports.value ?? [], fetchedAt: now, portsAt: ports.at ?? now,
                         routes: extra?.routes, hosts: extra?.hosts, firewall: extra?.firewall, proxies: extra?.proxies ?? [])
    }

    static func readStaticSpec(runner: any CommandRunner) async -> [String] {
        let result = await runner.run("/bin/zsh", ["-c", LocalCommands.macSpecStatic], timeout: 10)
        return result.stdout.split(separator: "\n").map(String.init)
    }

    static func readSlow(runner: any CommandRunner, vpns: [SystemVPN], egressCache: VPNEgressCache?, network: String, force: Bool) async -> Slow {
        async let firewall = FirewallState.fetch(runner: runner)
        async let proxies = SystemProxy.fetch(runner: runner)
        var routes = await RouteTable.fetch(runner: runner)
        for vpn in vpns where vpn.state == .connected {
            if let found = await SystemVPNs.egress(vpn, runner: runner, egressCache: egressCache, network: network, force: force) {
                routes?.tunnelEgress[found.tunnel] = found.egress.map(\.interface)
            }
        }
        return Slow(routes: routes, hosts: HostsFile.read(), firewall: await firewall, proxies: await proxies)
    }
}
