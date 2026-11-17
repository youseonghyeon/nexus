// 망 Dashboard 가 쓰는 부품: 켜기/끄기 버튼 · 이 망의 서버 목록 · 장치별 수치(받기/보내기 · 인터넷 응답 · 속도 · 공인 IP).

import ServersCore
import SwiftUI

/// 켜기/끄기: 사이드바 행과 같은 규칙 (Touch ID·비밀번호는 누른 뒤에 뜬다)
struct NetworkToggleButton: View {
    @Environment(AppModel.self) private var model
    let kind: ServerNetwork

    var body: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else {
            Button(label) { toggle() }
                .buttonStyle(CompactButtonStyle())
                .disabled(!canToggle)
        }
    }

    private var isUp: Bool { kind == .tailscale ? model.tailscaleRunning : model.status.lan == .up }

    private var label: String {
        switch kind {
        case .tailscale, .lan: return isUp ? "끄기" : "켜기"
        case .direct, .vpn: return ""   // 망 설정 없음은 켜고 끌 망이 없다 · VPN 은 VPN 화면 목록에서 (이 버튼을 쓰지 않음)
        }
    }

    private var isBusy: Bool {
        switch kind {
        case .tailscale: return model.busyAction?.kind == .tailscale
        case .lan: return model.busyAction?.kind == .lan
        case .direct, .vpn: return false
        }
    }

    private var canToggle: Bool {
        switch kind {
        case .tailscale: return model.canToggleTailscale
        case .lan: return model.canToggleLan
        case .direct, .vpn: return false
        }
    }

    private func toggle() {
        switch kind {
        case .tailscale: model.toggleTailscale()
        case .lan: model.toggleLan()
        case .direct, .vpn: break
        }
    }
}

/// 내부망 서비스 표시 (lan.json 의 service). 지정은 Ethernet 화면의 서비스 카드 [Intranet 으로 지정] — [변경…]은 그 화면으로.
struct LanServicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let lan = model.lan {
                Text(model.lanServiceCandidates.first { $0.name == lan.service }?.label ?? lan.service).lineLimit(1)
                Text(stateText).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("–")
            }
            Button("변경…") { model.showEthernet() }
                .buttonStyle(.borderless).controlSize(.small)
                .help("Ethernet 화면의 서비스 카드에서 Intranet 으로 쓸 서비스를 지정합니다")
        }
    }

    private var stateText: String {
        switch model.status.lan {
        case .up: return "활성"
        case .missing: return "서비스 없음"
        default: return "비활성"
        }
    }
}

struct NetworkServersList: View {
    @Environment(AppModel.self) private var model
    let kind: ServerNetwork

    var body: some View {
        let servers = model.config?.servers.filter { $0.network == kind } ?? []
        if servers.isEmpty {
            Text("이 망의 서버가 없습니다.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(servers) { server in
                    Button {
                        model.select(server)
                    } label: {
                        HStack(spacing: 10) {
                            StatusDot(tone: model.remoteTone(server))
                            Text(server.key).fontWeight(.medium).frame(minWidth: 70, alignment: .leading)
                            TagBadges(tags: server.tags)
                            Text(server.ip).font(.body.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(stateText(server)).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stateText(_ server: Server) -> String {
        let method = server.check == .tcp ? "포트" : "SSH"
        switch model.status.remote(server.key) {
        case let .ok(ms): return "\(method) ok · \(ms)ms"
        case let .fail(ms): return "\(method) 실패 · \(ms)ms"
        case .off: return "꺼짐"
        case .needsAuth: return "Tailscale 인증 필요"
        case let .skip(reason): return StatusText.skipReasonText(reason, lanName: model.networkName(.lan))
        case .pending: return "확인 중"
        }
    }
}

// MARK: 장치별 수치 (Wi-Fi · Ethernet · Intranet · VPN 화면 공용)
// device 는 그 망이 연결됨일 때만 넘긴다 — 같은 NIC 의 다른 서비스 값이 섞이지 않게. nil 이면 "–".

/// 받기·보내기 타일 하나. total 이 있으면(VPN 누적 바이트) 아래 줄에 누적을, 없으면 측정 상태를.
/// connected: 망은 연결됐는데 장치를 아직 못 읽은 경우(VPN 상세 읽기 전)에도 "측정 중…" 으로.
struct TrafficTile: View {
    enum Direction { case rx, tx }
    @Environment(AppModel.self) private var model
    let direction: Direction
    let device: String?
    var total: Int64? = nil
    var connected = false

    var body: some View {
        let rate = device.flatMap { model.trafficRates[$0] }
        let history = device.flatMap { model.trafficHistory[$0] } ?? []
        let rx = direction == .rx
        MetricTile(title: rx ? "받기" : "보내기", value: rate.map { TrafficRate.format(rx ? $0.rxPerSecond : $0.txPerSecond) } ?? "–",
                   caption: caption(rate: rate, samples: history.count), tone: .muted, systemImage: rx ? "arrow.down" : "arrow.up") {
            Sparkline(values: history.map(rx ? \.rxPerSecond : \.txPerSecond), tone: .good)   // 받기·보내기 같은 색 — 방향은 타일 제목이 말한다 (파랑은 뜻 없는 색이었다)
        }
    }

    private func caption(rate: TrafficRate?, samples: Int) -> String? {
        if let total { return "누적 \(TransferMeter.format(total))" }
        guard device != nil else { return connected ? "측정 중…" : nil }
        if rate == nil { return "측정 중…" }
        return direction == .tx ? "최근 \(samples)회" : nil   // 링크 표기는 링크 타일에만
    }
}

/// 인터넷 응답 타일: 그 장치로만 잰 값 (기본 경로와 무관). 장치가 없으면(연결 안 됨) idleCaption.
struct LatencyTile: View {
    @Environment(AppModel.self) private var model
    let device: String?
    let idleCaption: String?

    var body: some View {
        let probe = device.flatMap { model.internetProbe[$0] }
        if let probe, let ms = probe.averageMs {
            MetricTile(title: "인터넷 응답", value: String(format: "%.0f", ms), unit: "ms",
                       caption: probe.jitterMs.map { String(format: "Jitter %.1f ms", $0) },
                       tone: SignalScale.latencyTone(ms), systemImage: "globe") {
                HStack(spacing: 8) {
                    MeterBar(level: 1 - min(1, ms / 200), tone: SignalScale.latencyTone(ms))
                    if probe.lossPercent > 0 {
                        StatusChip(text: "손실 \(Int(probe.lossPercent))%", tone: .bad)
                    }
                }
            }
        } else if device != nil {
            MetricTile(title: "인터넷 응답", value: probe == nil ? "–" : "없음",
                       caption: probe == nil ? "확인 중…" : "응답 없음",
                       tone: probe == nil ? .muted : .bad, systemImage: "globe")
        } else {
            MetricTile(title: "인터넷 응답", value: "–", caption: idleCaption, systemImage: "globe")
        }
    }
}

/// 인터넷 카드의 응답·속도 행: 값은 모두 그 장치로만 잰 것 — 이 Mac 이 실제로 나가는 기본 경로는 이 Mac 화면에
struct InternetRows: View {
    @Environment(AppModel.self) private var model
    let device: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("응답").font(.fieldLabel).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(device == nil ? "–" : device.flatMap { model.internetProbe[$0] }?.text ?? "확인 중…")
                    Text("\(NetworkProbe.probeCount)회 · 15초 간격").font(.caption).foregroundStyle(.tertiary)
                }
            }
            GridRow {
                Text("속도").font(.fieldLabel).foregroundStyle(.secondary)
                SpeedTestRow(device: device)
            }
        }
    }
}

/// 속도 한 줄 (Wi-Fi·Ethernet 화면 공통): 그 장치로만 networkQuality. device 가 nil(연결 안 됨)이거나 다른 장치를 재는 중이면 버튼 비활성.
struct SpeedTestRow: View {
    @Environment(AppModel.self) private var model
    let device: String?

    var body: some View {
        if let device, model.speedTestDevice == device {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("측정 중 (약 \(NetworkProbe.speedTestSeconds)초)").foregroundStyle(.secondary)
            }
        } else if let device, let test = model.speedTest[device] {
            HStack(spacing: 12) {
                Label(test.download ?? "–", systemImage: "arrow.down").foregroundStyle(.primary)
                Label(test.upload ?? "–", systemImage: "arrow.up").foregroundStyle(.primary)
                if let responsiveness = test.responsiveness { StatusChip(text: responsiveness, tone: .good) }
                Button("다시") { model.runSpeedTest(device: device) }.buttonStyle(CompactButtonStyle())
                    .disabled(model.speedTestDevice != nil)
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 8) {
                Text("–").foregroundStyle(.secondary)
                Button("측정") { if let device { model.runSpeedTest(device: device) } }.buttonStyle(CompactButtonStyle())
                    .help("networkQuality — 약 \(NetworkProbe.speedTestSeconds)초 동안 회선을 가득 채웁니다")
                    .disabled(device == nil || model.speedTestDevice != nil)
            }
        }
    }
}

/// 주소 카드의 공인 IP 행: 그 장치로만 나가 본 값 — 기본 경로가 VPN·다른 망이어도 이 장치 쪽 공인 IP
struct PublicIPRow: View {
    @Environment(AppModel.self) private var model
    let device: String?

    var body: some View {
        GridRow(alignment: .top) {
            Text("공인 IP").font(.fieldLabel).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(device.flatMap { model.publicIP[$0] } ?? "–").textSelection(.enabled)
                    if let device, model.publicIPLoading.contains(device) { ProgressView().controlSize(.small) }
                    Button { if let device { model.fetchPublicIP(device: device, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("공인 IP 다시 확인")
                        .buttonStyle(.borderless).controlSize(.small).help("다시 확인").disabled(device == nil)
                }
                // 위치(도시 · AS)는 공인 IP 와 함께 받는다 — VPN 화면과 같은 줄
                if let ip = device.flatMap({ model.publicIP[$0] }), let location = model.publicIPLocation[ip], !location.text.isEmpty {
                    Text(location.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .help("IP 로 추정한 위치 — 등록지로 나올 수 있습니다")
                }
            }
        }
    }
}
