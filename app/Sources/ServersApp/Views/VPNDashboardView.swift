// VPN 화면: 사이드바 NETWORK 의 "VPN" 행(Tailscale 아래). 시스템 설정에 있는 VPN(scutil --nc, Tailscale 제외)을 모아 켜고 끄기만 한다.
// 대표 카드(제목·결론 + 띠에 목록: 전부, 켜기/끄기 — 이 화면에서 가장 자주 하는 일) →
// 연결된 VPN 마다 같은 모양의 묶음(이름 카드 + 띠에 수치: 연결 시간·Server·받기·보내기, 그 아래 상태·주소 카드) → 진단(ping·HTTP).
// 예전엔 첫 연결의 수치가 이름 없이 대표 카드 띠에 있고 둘째부터는 따로 뜬 카드라, 둘을 켜면 누구 수치인지 모르고 모양도 달랐다 (2026-11-10).
// 구성 추가·편집은 각 VPN 앱·시스템 설정에서. 목록은 서버 상태 확인 때(설정의 갱신 간격), 상세·속도는 이 화면이 떠 있을 때 5초마다 읽는다.

import ServersCore
import SwiftUI

extension SystemVPN {
    var tone: StatusTone {
        switch state {
        case .connected: return .good
        case .connecting, .disconnecting: return .warn
        default: return .muted
        }
    }
}

struct VPNDashboardView: View {
    @Environment(AppModel.self) private var model

    static func tone(_ vpns: [SystemVPN]) -> StatusTone {
        if vpns.contains(where: { $0.state == .connected }) { return .good }
        if vpns.contains(where: { $0.state == .connecting || $0.state == .disconnecting }) { return .warn }
        return .muted
    }

    private var connected: [SystemVPN] { (model.vpns ?? []).filter { $0.state == .connected } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                // 대표 카드: 띠에 목록 (켜기·끄기가 맨 위에)
                HeroCard {
                    LocalHeader(title: "VPN", subtitle: "시스템 설정의 VPN", tone: Self.tone(model.vpns ?? []),
                                conclusion: model.vpns.map(SystemVPNs.summary) ?? "확인 중…", checkedAt: model.lastRefresh) { EmptyView() }
                } strip: {
                    list.padding(.horizontal, 20).padding(.vertical, 12)
                }
                // 연결된 VPN 마다 같은 틀: 이름 카드(띠에 수치) + 상태·주소
                ForEach(connected) { vpn in
                    let detail = model.vpnDetails[vpn.id]
                    VStack(alignment: .leading, spacing: 12) {
                        HeroCard { connectionHeader(vpn, detail) } strip: { tiles(vpn, detail) }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: Metrics.gap) {
                                InfoCard(title: title("상태", vpn)) { statusRows(vpn, detail) }.fillingHeight()
                                InfoCard(title: title("주소", vpn)) { addressRows(vpn, detail) }.fillingHeight()
                            }
                            .fixedSize(horizontal: false, vertical: true)   // 두 카드 높이를 맞춘다
                            VStack(alignment: .leading, spacing: 12) {
                                InfoCard(title: title("상태", vpn)) { statusRows(vpn, detail) }
                                InfoCard(title: title("주소", vpn)) { addressRows(vpn, detail) }
                            }
                        }
                    }
                }
                // network=vpn 서버 (Tailscale·Intranet 화면의 서버 카드와 같다)
                if model.config?.servers.contains(where: { $0.network == .vpn }) == true {
                    InfoCard(title: "서버") { NetworkServersList(kind: .vpn) }
                }
                DiagnosticCard(screen: AppModel.vpnKey, wifi: model.wifi)   // 첫 번째로 연결된 VPN 의 인터페이스로만
            }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sampling(every: { 5 }) { await model.refreshVPNDetails() }
    }

    /// 연결된 VPN 이 둘 이상이면 카드 제목에 이름을 붙인다
    private func title(_ base: String, _ vpn: SystemVPN) -> String {
        connected.count > 1 ? "\(base) · \(vpn.name)" : base
    }

    /// 연결 하나의 이름 줄: 점 · 이름 · 종류·인터페이스 | 끄기
    private func connectionHeader(_ vpn: SystemVPN, _ detail: SystemVPNDetail?) -> some View {
        HStack(spacing: 10) {
            StatusDot(tone: vpn.tone)
            Text(vpn.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            Text([vpn.kind, detail?.interface].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            toggleButton(vpn)
        }
    }

    // MARK: 타일

    @ViewBuilder
    private func tiles(_ vpn: SystemVPN, _ detail: SystemVPNDetail?) -> some View {
        let endpoint = detail?.server.map(SystemVPNs.splitEndpoint)
        MetricGrid {
            MetricTile(title: "연결 시간", value: detail?.connectedSeconds.map(SystemVPNs.duration) ?? "–",
                       caption: detail?.connectedAt.map { "\($0.formatted(date: .omitted, time: .shortened)) 부터" },
                       tone: .muted, systemImage: "clock") { EmptyView() }
            MetricTile(title: "Server", value: endpoint?.host ?? "–",
                       caption: [endpoint?.port.map { "포트 \($0)" }, vpn.kind].compactMap { $0 }.joined(separator: " · "),
                       tone: .muted, systemImage: "server.rack") { EmptyView() }
            TrafficTile(direction: .rx, device: detail?.interface, total: detail?.bytesIn, connected: true)   // 연결된 VPN 에만 그린다
            TrafficTile(direction: .tx, device: detail?.interface, total: detail?.bytesOut, connected: true)
        }
    }

    // MARK: 상태·주소 카드

    private func statusRows(_ vpn: SystemVPN, _ detail: SystemVPNDetail?) -> some View {
        // 켜기·끄기는 이름 카드와 대표 카드의 목록에 있다
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                InfoRow("이름", "\(vpn.name) · \(vpn.kind)")
                InfoRow("인터페이스", detail?.interface ?? "–")   // Wi-Fi·Ethernet·Intranet 화면과 같은 이름
                // 암호화한 패킷이 실제로 나가는 물리 장치 — 라우팅 테이블엔 안 보여 확장 프로세스 소켓(nettop)으로 읽는다
                InfoRow("나가는 장치", detail?.egress.map(\.text).joined(separator: ", ").nonEmpty ?? "–")
                InfoRow("MTU", detail?.mtu.map(String.init) ?? "–")
                InfoRow("인터넷 경로", detail?.primary.map { $0 ? "이 VPN (전체 트래픽)" : "아님 (지정한 경로만)" } ?? "–")
                InfoRow("On-Demand", detail?.onDemand.map { $0 ? "켜짐" : "꺼짐" } ?? "–")
                // 속도 측정은 두지 않는다 — VPN 회선을 재 보려고 넣었지만 이제 쓸 일이 없다 (2026-11-10 사용자 결정). Wi-Fi·Ethernet 화면에는 그대로
            }
    }

    private func addressRows(_ vpn: SystemVPN, _ detail: SystemVPNDetail?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            // 이 VPN 으로 나가면 바깥에서 보이는 주소와 위치 — 지정한 경로만 가는 VPN 이면 못 가져온다
            VPNPublicIPRow(vpn: vpn, device: detail?.interface)
            InfoRow("IPv4", detail?.ipv4.joined(separator: ", ").nonEmpty ?? "–")
            InfoRow("IPv6", detail?.ipv6.joined(separator: ", ").nonEmpty ?? "–")
            InfoRow("경로", detail?.routes.joined(separator: "\n").nonEmpty ?? "–")
            InfoRow("DNS", detail?.dnsServers.joined(separator: "\n").nonEmpty ?? "–")
            InfoRow("검색 도메인", detail?.searchDomains.joined(separator: ", ").nonEmpty ?? "–")
        }
    }

    // MARK: 목록

    @ViewBuilder
    private var list: some View {
        if let vpns = model.vpns {
            if vpns.isEmpty {
                Text("시스템 설정에 VPN 이 없습니다.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(vpns) { vpn in row(vpn) }
                }
            }
        } else {
            Text("확인 중…").foregroundStyle(.secondary)
        }
    }

    private func row(_ vpn: SystemVPN) -> some View {
        HStack(spacing: 10) {
            StatusDot(tone: vpn.tone)
            Text(vpn.name).fontWeight(.medium).lineLimit(1)
            Text(vpn.kind).foregroundStyle(.secondary).lineLimit(1)
            if let server = model.vpnDetails[vpn.id]?.server {
                Text(server).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text(vpn.stateText).font(.callout).foregroundStyle(vpn.state == .connected ? Color.primary : Color.secondary)
            toggleButton(vpn)
        }
    }

    @ViewBuilder
    private func toggleButton(_ vpn: SystemVPN) -> some View {
        if model.vpnBusy.contains(vpn.id) {
            ProgressView().controlSize(.small).frame(width: 52)
        } else {
            Button(vpn.isOn ? "끄기" : "켜기") { model.toggleVPN(vpn) }
                .buttonStyle(CompactButtonStyle())
                .disabled(!vpn.canToggle)
        }
    }
}

private extension String {
    /// 빈 값은 "–"
    var nonEmpty: String { isEmpty ? "–" : self }
}

/// 주소 카드의 공인 IP 행: 그 VPN 의 utun 으로만 나가 본 주소 + 위치(도시 · AS). 화면에 들어오면 한 번 묻고(5분에 한 번), ↻ 로 다시.
private struct VPNPublicIPRow: View {
    @Environment(AppModel.self) private var model
    let vpn: SystemVPN
    let device: String?

    var body: some View {
        let ip = device.flatMap { model.publicIP[$0] }
        let loading = device.map { model.publicIPLoading.contains($0) } ?? false
        GridRow(alignment: .top) {
            Text("공인 IP").font(.fieldLabel).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let ip {
                        Text(ip).monospacedDigit().textSelection(.enabled)
                    } else if let device, model.publicIPFailed.contains(device), !loading {
                        Text("가져오지 못했습니다").foregroundStyle(.secondary)
                            .help("이 VPN 으로는 인터넷에 나가지 못합니다 (지정한 경로만 가는 VPN 이거나 막힌 망)")
                    } else {
                        Text(loading ? "확인 중…" : "–").foregroundStyle(loading ? .secondary : .primary)
                    }
                    if loading { ProgressView().controlSize(.small) }
                    Button { if let device { model.fetchVPNPublicIP(device: device, owner: vpn.id, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("공인 IP 다시 확인")
                        .buttonStyle(.borderless).controlSize(.small).help("다시 확인").disabled(device == nil || loading)
                }
                if let ip, let location = model.publicIPLocation[ip], !location.text.isEmpty {
                    Text(location.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .help("IP 로 추정한 위치 — 등록지로 나올 수 있습니다")
                }
            }
        }
        .task(id: device) { if let device { model.fetchVPNPublicIP(device: device, owner: vpn.id) } }
    }
}
