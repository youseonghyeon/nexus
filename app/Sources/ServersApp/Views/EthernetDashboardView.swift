// Ethernet Dashboard: 사이드바 Network 의 Ethernet 행을 누르면 뜬다.
// 머리글 → 큰 수치 타일(링크·응답·↓·↑, 대표 어댑터) → 어댑터마다 상태·주소 → 서비스(유선 서비스 전부 — 켜기·끄기·Intranet 지정·추가)
// → 인터넷 → 진단(DiagnosticCard — ping·HTTP·TCP·DNS·ARP, 대표 어댑터). Wi-Fi 화면과 같은 틀. 어댑터·주소 카드는 읽기만, 바꾸는 건 서비스 카드에서만.
// Intranet 도 그냥 유선 서비스 — 활성화·비활성화는 모든 서비스가 같은 함수(Intranet 스위치도), 지정할 때만 서비스 순서 맨 뒤로 (2026-10-15 단순화).
// 어느 유선이 여기 보이는지(내부망과 가르는 규칙)는 ServersCore Ethernet 머리 주석.

import ServersCore
import SwiftUI

struct EthernetDashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DashboardScroll {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HeroCard { header } strip: { metrics }
                if adapters.isEmpty {
                    InfoCard(title: "상태") {
                        Text(model.ethernet == nil ? "확인 중…" : "연결된 유선 어댑터가 없습니다.").foregroundStyle(.secondary)
                    }
                }
                ForEach(adapters) { adapter in
                    CardPair(left: InfoCard(title: title("상태", adapter)) { statusRows(adapter) },
                             right: InfoCard(title: title("주소", adapter)) { addressRows(adapter) })
                }
                InfoCard(title: "서비스") { serviceRows }
                InfoCard(title: "인터넷") { internetRows }
                // 진단도 대표 어댑터로만 (인터넷 카드와 같은 장치) — 어댑터가 여럿이면 제목에 서비스 이름
                DiagnosticCard(screen: AppModel.ethernetKey, title: primary.map { title("진단", $0) } ?? "진단", wifi: model.wifi)
            }
        }
    }

    // MARK: 머리글

    private var header: some View {
        NetworkHeader(title: primary?.service ?? "Ethernet", subtitle: subtitle, tone: model.ethernetTone, conclusion: conclusion(primary),
                      checkedAt: model.networkInfoAt) {
            if let primary, isDefaultRoute(primary) { StatusChip(text: "인터넷 경로", tone: .good) }
        }
    }

    private var subtitle: String {
        // 대표 서비스가 없으면 제목도 "Ethernet" 이라 같은 말을 되풀이하지 않게 (Bluetooth "이 Mac 의 블루투스" 와 같은 틀)
        guard let primary else { return "이 Mac 의 유선 연결" }
        return (["Ethernet", primary.hardwarePort, primary.device] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 수치 타일 (대표 어댑터)

    @ViewBuilder
    private var metrics: some View {
        // 링크·받기/보내기는 NIC(en10) 값 — 이 서비스가 그 선을 실제로 쓸 때(주소 있음)만 이 서비스의 값이다.
        // 같은 NIC 의 다른 서비스(내부망)가 쓰는 선이면 제목(iptime Hub NIC) 아래 보이지 않게 (2026-10-15)
        MetricGrid {
            linkTile
            LatencyTile(device: activeDevice, idleCaption: model.ethernet == nil ? "확인 중…" : conclusion(primary))
            TrafficTile(direction: .rx, device: activeDevice)
            TrafficTile(direction: .tx, device: activeDevice)
        }
    }

    /// 대표 어댑터가 연결됨일 때만 그 장치 — 응답·받기/보내기·공인 IP 는 이 장치로만 잰 값 (기본 경로와 무관)
    private var activeDevice: String? { primary?.state == .connected ? primary?.device : nil }

    /// 링크 속도: 1 Gbps 미만·half-duplex 는 경고 (기가비트 장비에서 100 Mbps 로 붙으면 대개 케이블·포트 문제)
    @ViewBuilder
    private var linkTile: some View {
        if let primary, primary.state == .connected, let mbps = Ethernet.speedMbps(media: primary.interface.media) {
            let speed = Ethernet.speedText(mbps: mbps)
            let duplex = Ethernet.duplex(media: primary.interface.media)
            let tone: StatusTone = Ethernet.linkWarns(mbps: mbps, duplex: duplex) ? .warn : .muted
            MetricTile(title: "링크", value: speed.value, unit: speed.unit, caption: primary.interface.media,
                       tone: tone, systemImage: "cable.connector") {
                if let duplex { StatusChip(text: duplex, tone: duplex == "half-duplex" ? .warn : .good) }
            }
        } else {
            MetricTile(title: "링크", value: "–", caption: model.ethernet == nil ? "확인 중…" : conclusion(primary),
                       systemImage: "cable.connector")
        }
    }

    // MARK: 카드 (어댑터마다)

    /// 어댑터가 둘 이상이면 카드 제목에 서비스 이름을 붙인다
    private func title(_ base: String, _ adapter: EthernetAdapter) -> String {
        adapters.count > 1 ? "\(base) · \(adapter.service)" : base
    }

    private func statusRows(_ adapter: EthernetAdapter) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
            InfoRow("서비스", adapter.service)
            InfoRow("어댑터", adapter.hardwarePort ?? "–")
            InfoRow("인터페이스", adapter.device)
            InfoRow("링크", linkText(adapter))
            // ifconfig 의 MAC 은 앱 안에서 가려 받으므로(02:00:…) networksetup 값을 함께 본다
            InfoRow("MAC", Ethernet.realMAC(adapter.interface.mac) ?? adapter.info?.mac ?? "–")
        }
    }

    private func addressRows(_ adapter: EthernetAdapter) -> some View {
        // 서비스 값(IP·서브넷·게이트웨이·구성)은 그 서비스 것, NIC 값(DNS·공인 IP)은 연결됨일 때만
        let info = adapter.info
        return Grid(alignment: .leading, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
            InfoRow("IP", ipText(adapter))
            InfoRow("서브넷", adapter.netmask ?? "–")
            InfoRow("게이트웨이", info?.router ?? "–")
            InfoRow("구성", info?.configuration ?? "–")
            // 이 장치에 걸린 DNS (scoped) — 검색 도메인은 있을 때만
            let dns = adapter.state == .connected ? model.dnsConfig?.scoped[adapter.device] : nil
            InfoRow("DNS", dns?.nameserverText ?? "–")
            if let domains = dns?.searchDomainText { InfoRow("검색 도메인", domains) }
            PublicIPRow(device: adapter.state == .connected ? adapter.device : nil)
        }
    }

    private var internetRows: some View { InternetRows(device: activeDevice) }

    // MARK: 서비스 (유선 서비스 전부)

    @ViewBuilder
    private var serviceRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.wiredServices.isEmpty {
                Text(model.lanServices.isEmpty ? "확인 중…" : "유선 서비스가 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(model.wiredServices) { entry in serviceRow(entry) }
            HStack {
                Button { model.promptAddService() } label: { Label("서비스 추가…", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.busyAction != nil)
                    .help("유선 어댑터에 수동 IP 서비스를 만듭니다 (내부망용)")
                if model.busyAction?.kind == .service { ProgressView().controlSize(.small) }
            }
        }
    }

    private func serviceRow(_ entry: LanServiceEntry) -> some View {
        let intranet = model.intranetDesignated.contains(entry.name)
        let link = model.serviceLink(entry)
        return HStack(spacing: 10) {
            // 점은 연결(링크 + 이 서비스의 IP)일 때만 초록 — 켜져 있어도 어댑터·케이블이 없을 수 있다
            Circle().fill(link.isConnected ? StatusTone.good.color : StatusTone.muted.color).frame(width: 9, height: 9)
            Text(entry.name).fontWeight(.medium).lineLimit(1)
            Text([entry.hardwarePort, entry.device].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
            if intranet { StatusChip(text: "Intranet", tone: .muted) }   // 색은 상태에만 — 지정 표시는 무채색
            if entry.enabled, model.carriesInternet(entry.name) { StatusChip(text: "인터넷 경로", tone: .good) }
            Spacer()
            if model.serviceBusy(entry) { ProgressView().controlSize(.small) }   // 활성화 → 주소가 붙기까지 몇 초
            Text(link.text).font(.callout).monospacedDigit().foregroundStyle(link.isConnected ? Color.primary : Color.secondary)
            if !intranet {
                Button("Intranet 으로 지정") { model.confirmDesignateIntranet(entry.name) }
                    .buttonStyle(CompactButtonStyle())
                    .disabled(!model.canDesignate(entry))
            }
            Button(entry.enabled ? "비활성화" : "활성화") { model.setServiceEnabled(entry, on: !entry.enabled) }
                .buttonStyle(CompactButtonStyle())
                .disabled(!model.canToggleService(entry))
        }
    }

    // MARK: 값

    private var adapters: [EthernetAdapter] { model.ethernet ?? [] }
    private var primary: EthernetAdapter? { model.ethernetPrimary }

    /// 이 서비스로 인터넷이 나가는가 (서비스 기준 — 같은 장치의 다른 서비스가 아니라)
    private func isDefaultRoute(_ adapter: EthernetAdapter) -> Bool {
        adapter.linkActive && model.carriesInternet(adapter.service)
    }

    private func conclusion(_ adapter: EthernetAdapter?) -> String {
        StatusText.ethernetConclusion(loaded: model.ethernet != nil, primary: adapter)   // 서비스 판정 하나
    }

    private func linkText(_ adapter: EthernetAdapter) -> String { StatusText.ethernetLinkText(adapter) }

    private func ipText(_ adapter: EthernetAdapter) -> String {
        StatusText.addressText(ip: adapter.address, mask: adapter.netmask)   // 이 서비스의 IP (같은 장치의 다른 서비스 주소가 아니라)
    }
}
