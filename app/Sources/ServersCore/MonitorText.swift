// 이 Mac 화면(System · Disk · VPN)과 사이드바 · Ports 표의 작은 판정 · 문구. 화면(SystemDashboardView · DiskDashboardView · VPNDashboardView ·
// SidebarView · RemoteInfoCard)에 있던 것을 그대로 옮긴 것. 색은 앱이 단계(StatusLevel)를 StatusTone 으로 바꾼다.

import Foundation

// MARK: VPN 화면

extension SystemVPN {
    /// 목록 한 줄의 점: 연결 초록 · 바뀌는 중 노랑 · 그 밖 회색
    public var level: StatusLevel {
        switch state {
        case .connected: return .good
        case .connecting, .disconnecting: return .warn
        default: return .muted
        }
    }

    /// 화면 · 사이드바 행의 결론 색: 하나라도 연결이면 초록, 아니고 바뀌는 중인 것이 있으면 노랑, 그 밖(빈 목록 포함) 회색
    public static func overallLevel(_ vpns: [SystemVPN]) -> StatusLevel {
        if vpns.contains(where: { $0.state == .connected }) { return .good }
        if vpns.contains(where: { $0.state == .connecting || $0.state == .disconnecting }) { return .warn }
        return .muted
    }
}

// MARK: System 화면

extension SwapUsage {
    /// 메모리 카드의 스왑 줄: "1.2 GB / 2 GB · 암호화". 아직 못 읽었으면 "–", 스왑 파일이 없으면 "사용 안 함"
    public static func text(_ swap: SwapUsage?) -> String {
        guard let swap else { return "–" }
        guard swap.total > 0 else { return "사용 안 함" }
        return "\(SystemFormat.bytes(swap.used)) / \(SystemFormat.bytes(swap.total))" + (swap.encrypted ? " · 암호화" : "")
    }
}

extension PagingRates {
    /// 메모리 카드의 페이징 줄. 첫 표본 전(nil)은 "측정 중…"
    public static func text(_ paging: PagingRates?) -> String {
        guard let paging else { return "측정 중…" }
        func rate(_ value: Double) -> String { String(format: "%.0f", value) }
        // 초당 값 — /s 는 끝에 한 번 (항목마다 붙이면 영어 표기로 길어져 줄이 넘어갔다)
        return "In \(rate(paging.pageins)) · Out \(rate(paging.pageouts)) · Compress \(rate(paging.compressions)) · Decompress \(rate(paging.decompressions)) · Swap In \(rate(paging.swapins)) · Swap Out \(rate(paging.swapouts)) /s"
    }
}

extension BatteryHealth {
    /// "최대 용량 100% · 충전 사이클 184 / 1000" (80% 미만이면 교체 권장)
    public var text: String {
        let cycles = cycleCount.map { count in "충전 사이클 \(count)" + (designCycles.map { " / \($0)" } ?? "") }
        return [maxCapacityPercent.map { "최대 용량 \($0)%" }, cycles, needsService ? "교체 권장" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

extension TemperatureSummary {
    /// 전원 카드의 온도 줄: "성능 코어 48° · 효율 코어 41° · GPU 44° · 센서 26개". unavailable: 센서를 못 읽는 기기
    public static func text(_ summary: TemperatureSummary?, unavailable: Bool) -> String {
        if unavailable { return "온도 센서를 읽지 못했습니다" }
        guard let t = summary else { return "측정 중…" }
        func degrees(_ label: String, _ value: Double?) -> String? { value.map { "\(label) \(Int($0.rounded()))°" } }
        return ([degrees("성능 코어", t.performanceMax), degrees("효율 코어", t.efficiencyMax), degrees("GPU", t.gpuMax)].compactMap { $0 }
                + ["센서 \(t.sensors)개"]).joined(separator: " · ")
    }
}

// MARK: Disk 화면

extension PhysicalDisk {
    /// "내장 SSD" · "외장 HDD" · "이미지" (SSD 인지 모르면 자리만)
    public var kindText: String {
        let place = isDiskImage ? "이미지" : (isInternal ? "내장" : "외장")
        switch solidState {
        case true?: return "\(place) SSD"
        case false?: return "\(place) HDD"
        case nil: return place
        }
    }

    /// 화면 부제: "APPLE SSD AP0512Z · 500 GB · 내장 SSD · Apple Fabric · disk0 → disk3". 시동 디스크를 모르면 "이 Mac 의 디스크".
    /// rootContainer: 루트 볼륨이 든 APFS 컨테이너의 id (모르면 뺀다)
    public static func subtitle(boot disk: PhysicalDisk?, rootContainer: String?) -> String {
        guard let disk else { return "이 Mac 의 디스크" }
        var parts = [disk.name, DiskFormat.bytes(disk.size), disk.kindText]
        if let bus = disk.bus { parts.append(bus) }
        if let rootContainer { parts.append("\(disk.id) → \(rootContainer)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: 사이드바의 접은 그룹

/// 접은 서버 그룹 이름을 줄바꿈으로 이어 한 글로 저장한다 (UserDefaults "sidebarCollapsedGroups")
public enum CollapsedGroups {
    public static func names(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    public static func contains(_ stored: String, _ group: String) -> Bool {
        stored.split(separator: "\n").contains(Substring(group))
    }

    /// 그 그룹을 펴거나(expanded) 접은 뒤의 저장 글. 접으면 맨 뒤에 붙는다 (다른 그룹의 순서는 그대로)
    public static func setting(_ stored: String, _ group: String, expanded: Bool) -> String {
        var names = stored.split(separator: "\n").map(String.init).filter { $0 != group }
        if !expanded { names.append(group) }
        return names.joined(separator: "\n")
    }
}

// MARK: Ports 표

extension PortItem {
    /// 줄을 누르면 복사하는 "주소:포트" — IPv6 는 대괄호로 ("[::1]:8080")
    public var copyAddress: String {
        primaryAddress.contains(":") ? "[\(primaryAddress)]:\(port)" : "\(primaryAddress):\(port)"
    }
}
