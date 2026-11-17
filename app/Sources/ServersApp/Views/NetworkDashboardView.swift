// 망 Dashboard: 사이드바 NETWORK 행(Tailscale VPN · Intranet)을 누르면 오른쪽에 뜬다. Ethernet·Wi-Fi·VPN 은 자기 화면.
// 머리글(결론 한 줄) → 상태 카드(켜기/끄기) → 이 Mac 카드(Tailscale) · 주소 카드 → 진단 카드(Intranet) → 서버 카드. 정보는 이 Mac 명령만 읽는다.

import ServersCore
import SwiftUI

struct NetworkDashboardView: View {
    @Environment(AppModel.self) private var model
    let kind: ServerNetwork

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HeroCard { header } strip: { metrics }
                switch kind {
                case .tailscale: tailscaleCards
                case .lan: lanCards
                case .direct, .vpn: EmptyView()   // 망 설정 없음은 망 화면이 없다 · VPN 은 자기 화면(VPNDashboardView)
                }
                InfoCard(title: "서버") { NetworkServersList(kind: kind) }
            }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 머리글

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.networkName(kind)).font(.screenTitle).tracking(-0.6)
                    if isDefaultRoute { StatusChip(text: "인터넷 경로", tone: .good) }
                }
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(text: conclusion, tone: tone)
                if let at = model.networkInfoAt {
                    Text("\(at.formatted(date: .omitted, time: .shortened)) 확인").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        switch kind {
        case .tailscale: return model.tailscaleInfo.map { "\($0.tailnet) · \($0.shortDNSName)" } ?? "이 Mac 의 Tailscale"
        case .lan: return model.lanInfo.map { "\($0.service) · \($0.hardwarePort ?? "Ethernet")\($0.device.map { " · \($0)" } ?? "")" } ?? (model.lan?.service ?? "이 Mac 의 이더넷 서비스")
        case .direct, .vpn: return ""
        }
    }

    /// 사이드바·메뉴바와 같은 판정 (StatusDisplay) — 일부러 꺼 둔 내부망은 회색
    private var tone: StatusTone { kind == .tailscale ? model.tailscaleTone : model.lanTone }

    private var conclusion: String {
        switch kind {
        case .tailscale: return model.tailscaleDetail
        case .lan:
            switch model.status.lan {
            case .up: return model.lanLink?.text ?? (model.status.lanAdapterPresent ? "활성" : "활성 · 어댑터 없음")   // 서비스 판정 하나
            case .down: return "비활성"
            case .missing: return "서비스 없음"
            case .none: return "설정 없음"
            }
        case .direct, .vpn: return ""
        }
    }

    // MARK: 수치 타일

    @ViewBuilder
    private var metrics: some View {
        let servers = model.config?.servers.filter { $0.network == kind } ?? []
        let reachable = servers.filter { model.status.remote($0.key).isReachable }.count
        MetricGrid {
            switch kind {
            case .tailscale:
                let peers = model.tailscaleInfo?.peers ?? []
                let online = peers.filter(\.online).count
                MetricTile(title: "Peers", value: "\(online)", unit: "/ \(peers.count)",
                           caption: model.tailscaleInfo.map { "v\($0.shortVersion)" }, tone: .muted, systemImage: "point.3.connected.trianglepath.dotted") {
                    MeterBar(level: peers.isEmpty ? 0 : Double(online) / Double(peers.count), tone: .good)
                }
                MetricTile(title: "이 Mac", value: model.tailscaleInfo?.ipv4 ?? "–",
                           caption: model.tailscaleInfo?.shortDNSName, tone: .muted, systemImage: "laptopcomputer")
            case .lan:
                gatewayTile
                MetricTile(title: "링크", value: linkValue, caption: linkCaption,
                           tone: linkValue == "–" ? .muted : .good, systemImage: "cable.connector")
            case .direct, .vpn:
                EmptyView()
            }
            serverTile(reachable: reachable, total: servers.count)
            trafficTile
        }
    }

    @ViewBuilder
    private var gatewayTile: some View {
        if let ping = model.gatewayPing, let ms = ping.averageMs {
            MetricTile(title: "게이트웨이", value: String(format: "%.1f", ms), unit: "ms",
                       caption: model.lanInfo?.router, tone: SignalScale.latencyTone(ms), systemImage: "arrow.triangle.branch") {
                HStack(spacing: 8) {
                    MeterBar(level: 1 - min(1, ms / 50), tone: SignalScale.latencyTone(ms))
                    if ping.lossPercent > 0 { StatusChip(text: "손실 \(Int(ping.lossPercent))%", tone: .bad) }
                }
            }
        } else {
            MetricTile(title: "게이트웨이", value: model.gatewayPing == nil ? "–" : "없음",
                       caption: model.lanInfo?.router ?? (model.status.lan == .up ? "확인 중…" : "연결 안 됨"),
                       tone: model.gatewayPing == nil ? .muted : .bad, systemImage: "arrow.triangle.branch")
        }
    }

    private func serverTile(reachable: Int, total: Int) -> some View {
        // 이 망의 서버가 없으면 "0 / 0 · 접속 가능" 과 초록 막대 조각 대신 빈 값 (아래 서버 카드도 "이 망의 서버가 없습니다")
        let tone: StatusTone = total == 0 ? .muted : (reachable == total ? .good : (reachable == 0 ? .bad : .warn))
        return MetricTile(title: "서버", value: total == 0 ? "–" : "\(reachable)", unit: total == 0 ? nil : "/ \(total)",
                          caption: total == 0 ? "서버 없음" : "접속 가능", tone: tone, systemImage: "server.rack") {
            MeterBar(level: total == 0 ? 0 : Double(reachable) / Double(total), tone: tone, fill: total == 0 ? .clear : nil)
        }
    }

    @ViewBuilder
    private var trafficTile: some View {
        // 받기·보내기 두 타일 (Wi-Fi·Ethernet 화면과 같은 부품). 내부망 연결됨일 때만 이 서비스의 값
        if kind == .lan {
            TrafficTile(direction: .rx, device: lanDevice)
            TrafficTile(direction: .tx, device: lanDevice)
        }
    }

    /// Intranet 서비스가 연결됨일 때만 장치. NIC 값(링크·받기/보내기·인터넷 경로)은 그때만 이 서비스 것이다 —
    /// 아니면 같은 장치(en10 등)를 쓰는 다른 서비스(Ethernet)의 값이라 비운다 (서비스 판정 하나)
    private var lanDevice: String? { model.lanLink?.isConnected == true ? model.lanInfo?.device : nil }

    private var linkValue: String {
        guard let device = lanDevice, let link = model.linkMedia[device] else { return "–" }
        return link.valueText
    }

    private var linkCaption: String? {
        guard let device = lanDevice, let link = model.linkMedia[device] else { return nil }
        return link.captionText
    }

    private var isDefaultRoute: Bool {
        guard kind == .lan, let device = lanDevice else { return false }   // 연결이 아니면 같은 장치의 다른 서비스(Ethernet) 경로다
        return model.defaultRoute?.interface == device
    }

    // MARK: Tailscale

    @ViewBuilder
    private var tailscaleCards: some View {
        InfoCard(title: "상태") {
            HStack(alignment: .top) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    InfoRow("Backend", model.tailscaleInfo?.backendState ?? "–")
                    InfoRow("버전", model.tailscaleInfo?.shortVersion ?? "–")
                    InfoRow("Peers", model.tailscaleInfo.map { "\($0.peers.filter(\.online).count)/\($0.peers.count) 온라인" } ?? "–")
                }
                Spacer()
                HStack(spacing: 8) {
                    // 인증은 tailnet 공통(한 번 통과하면 12시간 동안 모든 서버). 인증 필요한 서버가 하나라도 있으면 보이고, 그 서버는 링크를 받아올 통로일 뿐이다.
                    if let server = model.tailscaleAuthNeededServer {
                        Button("Tailscale 로그인") { model.tailscaleLogin(server) }
                            .buttonStyle(CompactButtonStyle())
                            .disabled(model.busyAction != nil)
                            .help("브라우저에서 Tailscale SSH 인증 — 한 번이면 모든 서버에 적용됩니다")
                    }
                    NetworkToggleButton(kind: .tailscale)
                }
            }
        }
        InfoCard(title: "이 Mac") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                InfoRow("이름", model.tailscaleInfo?.hostName ?? "–")
                InfoRow("IPv4", model.tailscaleInfo?.ipv4 ?? "–")
                InfoRow("IPv6", model.tailscaleInfo?.ipv6 ?? "–")
                GridRow {
                    Text("MagicDNS").font(.fieldLabel).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(model.tailscaleInfo?.shortDNSName ?? "–").textSelection(.enabled)
                        if let name = model.tailscaleInfo?.shortDNSName, !name.isEmpty {
                            Button { model.copy(name) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("이름 복사")
                                .buttonStyle(.borderless).help("MagicDNS 이름 복사")
                        }
                    }
                }
                InfoRow("tailnet", model.tailscaleInfo?.tailnet ?? "–")
            }
        }
    }

    // MARK: Intranet

    @ViewBuilder
    private var lanCards: some View {
        let info = model.lanInfo
        let status = InfoCard(title: "상태") {
            HStack(alignment: .top) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("서비스").font(.fieldLabel).foregroundStyle(.secondary)
                        LanServicePicker()
                    }
                    // 어댑터 · 인터페이스 두 줄 (Ethernet 화면과 같은 틀). 구성은 주소 카드에.
                    InfoRow("어댑터", info.map { $0.hardwarePort ?? "–" } ?? "–")
                    InfoRow("인터페이스", interfaceText(info))
                }
                Spacer()
                NetworkToggleButton(kind: .lan)
            }
        }
        let address = InfoCard(title: "주소") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                InfoRow("IP", ipText(info))
                InfoRow("게이트웨이", gatewayText(info))
                InfoRow("구성", info?.configuration ?? "–")
                // 이 장치에 걸린 DNS (scoped) — 검색 도메인은 있을 때만.
                // NIC(장치) 값이라 Intranet 서비스가 연결됨일 때만 (아니면 같은 en10 의 다른 서비스 DNS 다)
                let dns = lanDevice.flatMap { model.dnsConfig?.scoped[$0] }
                InfoRow("DNS", dns?.nameserverText ?? "–")
                if let domains = dns?.searchDomainText { InfoRow("검색 도메인", domains) }
            }
        }
        // 다른 망 화면처럼 상태·주소를 나란히 (좁으면 위아래로)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.gap) {
                status.fillingHeight()
                address.fillingHeight()
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Metrics.gap) {
                status
                address
            }
        }
        DiagnosticCard(screen: AppModel.lanKey, wifi: model.wifi)
    }

    /// 게이트웨이 + 응답 (내부망이 실제로 통하는지)
    private func gatewayText(_ info: LanInfo?) -> String {
        guard let router = info?.router else { return "–" }
        guard let ping = model.gatewayPing else { return router }
        return "\(router) · \(ping.text)"
    }

    private func interfaceText(_ info: LanInfo?) -> String {
        guard let info else { return "–" }
        guard let device = info.device else { return "장치 없음" }
        return model.status.lanAdapterPresent ? device : device + " · 연결 안 됨"
    }

    /// "10.50.10.17/24" (서브넷은 접두 길이로 붙인다)
    private func ipText(_ info: LanInfo?) -> String {
        info?.addressText ?? "–"
    }
}
