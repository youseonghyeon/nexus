// Wi-Fi Dashboard: 사이드바 NETWORK 의 Wi-Fi 행을 누르면 뜬다.
// 머리글 → 큰 수치 타일(신호·링크·응답·↓·↑) → 상태·주소 → 인터넷 → 진단(ping·HTTP) → 접속 세부 → 주변 네트워크(열 때 한 번 + [다시 검색]).
// SSID 는 위치 권한이 있어야 읽히므로 없으면 안내와 [시스템 설정 열기].

import AppKit
import ServersCore
import SwiftUI

struct WiFiDashboardView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var wifi: WiFiMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HeroCard { header } strip: { metrics }
                if needsLocationNotice { locationNotice }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Metrics.gap) {
                        InfoCard(title: "상태") { statusRows }.fillingHeight()
                        InfoCard(title: "주소") { addressRows }.fillingHeight()
                    }
                    .fixedSize(horizontal: false, vertical: true)   // 두 카드 높이를 맞춘다
                    VStack(alignment: .leading, spacing: Metrics.gap) {
                        InfoCard(title: "상태") { statusRows }
                        InfoCard(title: "주소") { addressRows }
                    }
                }
                InfoCard(title: "인터넷") { internetRows }
                DiagnosticCard(screen: AppModel.wifiKey, wifi: wifi)
                InfoCard(title: "접속 세부") { detailRows } accessory: { detailButton }
                InfoCard(title: "주변 네트워크") { nearbyRows } accessory: { scanButton }
            }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 화면을 열 때 한 번만 직접 검색 (계속 검색하면 연결 응답이 30초마다 튄다 — 그 뒤는 [다시 검색])
        .task { if AppModel.mainWindowVisible { wifi.scanNearby() } }
        // 창이 가려진 채 열려 검색을 건너뛰었으면 "검색 중…" 으로 남는다 — 창이 보이게 될 때 한 번 (AppModel.installVisibilityObserver 와 같은 알림)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            if wifi.nearbyAt == nil, !wifi.scanFailed, AppModel.mainWindowVisible { wifi.scanNearby() }
        }
    }

    // MARK: 주변 네트워크

    @ViewBuilder
    private var scanButton: some View {
        if wifi.scanning {
            ProgressView().controlSize(.small)
        } else {
            Button("다시 검색") { wifi.scanNearby() }
                .buttonStyle(.borderless).font(.caption)
                .disabled(wifi.info?.powerOn != true)
                .help("주변 Wi-Fi 를 지금 검색합니다 (2~3초 동안 연결 응답이 잠깐 늦어질 수 있습니다)")
        }
    }

    @ViewBuilder
    private var nearbyRows: some View {
        if wifi.info?.powerOn != true {
            Text("Wi-Fi 가 꺼져 있습니다.").foregroundStyle(.secondary)
        } else if wifi.nearby.isEmpty {
            Text(wifi.scanning || wifi.nearbyAt == nil && !wifi.scanFailed ? "검색 중…"
                 : wifi.scanFailed ? "주변 네트워크를 검색하지 못했습니다 · 다시 검색하세요"
                 : (wifi.locationAuthorized ? "주변 네트워크가 없습니다." : "위치 권한이 없어 네트워크 이름을 읽지 못했습니다."))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(wifi.nearby) { network in
                        GridRow {
                            SignalBars(level: SignalScale.level(rssi: network.rssi), tone: SignalScale.tone(rssi: network.rssi))
                            HStack(spacing: 6) {
                                Text(network.ssid).fontWeight(network.ssid == wifi.info?.ssid ? .semibold : .regular).lineLimit(1)
                                if network.ssid == wifi.info?.ssid { StatusChip(text: "연결됨", tone: .good) }
                            }
                            Text("\(network.rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                            Text([network.channel.map { "채널 \($0)" }, network.band].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            Text(network.security ?? "–").foregroundStyle(.secondary)
                        }
                    }
                }
                if let at = wifi.nearbyAt {
                    Text("\(at.formatted(date: .omitted, time: .standard)) 검색 · 신호 센 순 \(wifi.nearby.count)개 (같은 이름은 가장 센 것 하나)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 머리글

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ssidText).font(.screenTitle).tracking(-0.6)
                    if let phy = wifi.info?.phyMode, associated { StatusChip(text: phy, tone: .muted) }
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
        var parts = ["Wi-Fi"]
        if let info = wifi.info {
            parts.append(info.interface)
            if let security = info.security, associated { parts.append(security) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 수치 타일

    @ViewBuilder
    private var metrics: some View {
        MetricGrid {
            if let info = wifi.info, associated {
                MetricTile(title: "신호", value: "\(info.rssi)", unit: "dBm",
                           caption: "Noise \(info.noise) dBm · SNR \(info.rssi - info.noise) dB",
                           tone: SignalScale.tone(rssi: info.rssi), systemImage: "wifi") {
                    HStack(spacing: 8) {
                        SignalBars(level: SignalScale.level(rssi: info.rssi), tone: SignalScale.tone(rssi: info.rssi))
                        StatusChip(text: SignalScale.label(rssi: info.rssi), tone: SignalScale.tone(rssi: info.rssi))
                    }
                }
            } else {
                MetricTile(title: "신호", value: "–", caption: conclusion, systemImage: "wifi")
            }
            linkTile
            LatencyTile(device: activeDevice, idleCaption: conclusion)
            TrafficTile(direction: .rx, device: activeDevice)
            TrafficTile(direction: .tx, device: activeDevice)
        }
    }

    /// 연결됐을 때만 Wi-Fi 장치 — 응답·받기/보내기·공인 IP 는 이 장치로만 잰 값 (기본 경로와 무관)
    private var activeDevice: String? { associated ? wifi.info?.interface : nil }

    /// 링크: 지금 연결 속도(CoreWLAN 전송 속도) — 유선과 달리 신호·간섭에 따라 몇 초마다 오르내린다. 아래 줄은 PHY · 대역 · 채널 폭.
    @ViewBuilder
    private var linkTile: some View {
        if let info = wifi.info, associated, info.txRate > 0 {
            let speed = Ethernet.speedText(mbps: Int(info.txRate))
            // channel "36 (5GHz, 80MHz)" → "5GHz · 80MHz"
            let band = info.channel.flatMap(WiFiChannelText.parse)?.caption
            MetricTile(title: "링크", value: speed.value, unit: speed.unit,
                       caption: [info.phyMode, band].compactMap { $0 }.joined(separator: " · "),
                       tone: .muted, systemImage: "antenna.radiowaves.left.and.right")
        } else {
            MetricTile(title: "링크", value: "–", caption: associated ? nil : conclusion, systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    // MARK: 카드

    @ViewBuilder
    private var statusRows: some View {
        HStack(alignment: .top) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                InfoRow("전원", wifi.info.map { $0.powerOn ? "켜짐" : "꺼짐" } ?? "–")
                InfoRow("SSID", ssidText)
                InfoRow("보안", wifi.info?.security ?? "–")
                InfoRow("인터페이스", wifi.info?.interface ?? "–")
            }
            Spacer()
            if let info = wifi.info {
                Button(info.powerOn ? "끄기" : "켜기") { model.toggleWiFi() }.buttonStyle(CompactButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var addressRows: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            InfoRow("IP", ipText)
            InfoRow("서브넷", model.wifiAddress.subnet ?? "–")
            InfoRow("게이트웨이", model.wifiAddress.router ?? "–")
            InfoRow("구성", model.wifiAddress.configuration ?? "–")   // 서비스 설정 (Ethernet 화면과 같은 자리)
            // 이 장치에 걸린 DNS (scoped) — 검색 도메인은 있을 때만
            let dns = wifi.info?.associated == true ? wifi.info.flatMap { model.dnsConfig?.scoped[$0.interface] } : nil
            InfoRow("DNS", dns?.nameserverText ?? "–")
            if let domains = dns?.searchDomainText { InfoRow("검색 도메인", domains) }
            PublicIPRow(device: activeDevice)
        }
    }

    private var internetRows: some View { InternetRows(device: activeDevice) }

    /// 루트로만 보이는 값(혼잡도·MCS·스트림·가드 인터벌·국가 코드)은 [상세 보기] 로 인증한 뒤 채워진다 — 그 전엔 "–"
    private var detailRows: some View {
        let detail = associated ? model.wifiDetail : nil
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            InfoRow("채널", wifi.info?.channel ?? "–")
            InfoRow("채널 혼잡도", detail?.cca.map { "\($0)%" } ?? "–")
            InfoRow("PHY", wifi.info?.phyMode ?? "–")
            InfoRow("MCS", detail?.mcs.map(String.init) ?? "–")
            InfoRow("공간 스트림", detail?.nss.map { "\($0)개" } ?? "–")
            InfoRow("가드 인터벌", detail?.guardInterval.map { "\($0) ns" } ?? "–")
            InfoRow("전송 속도", associated ? "\(Int(wifi.info?.txRate ?? 0)) Mbps" : "–")
            InfoRow("BSSID", wifi.info?.bssid ?? (wifi.locationAuthorized ? "–" : "위치 권한 필요"))
            InfoRow("국가 코드", detail?.countryCode ?? "–")
        }
    }

    /// [상세 보기]: 누를 때마다 Touch ID·암호로 한 번 읽는다 (sudo 자격이 남지 않음). 읽은 뒤엔 시각과 [다시].
    @ViewBuilder
    private var detailButton: some View {
        if model.wifiDetailLoading {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 8) {
                if associated, let at = model.wifiDetail?.fetchedAt {
                    Text("\(at.formatted(date: .omitted, time: .shortened)) 기준").font(.caption).foregroundStyle(.tertiary)
                }
                Button(associated && model.wifiDetail != nil ? "다시" : "상세 보기") { model.fetchWiFiDetail() }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(!associated)
                    .help("Touch ID 또는 암호로 인증하고 루트로만 보이는 값(채널 혼잡도·MCS·공간 스트림·가드 인터벌·국가 코드)을 읽습니다")
            }
        }
    }

    private var needsLocationNotice: Bool {
        wifi.locationDenied || (wifi.authorization == .notDetermined && associated)
    }

    private var locationNotice: some View {
        HStack(spacing: 10) {
            Label("Wi-Fi 이름(SSID)을 읽으려면 위치 권한이 필요합니다.", systemImage: "location.slash")
                .font(.callout).foregroundStyle(StatusTone.warn.color)
            Spacer()
            if wifi.authorization == .notDetermined {
                Button("권한 요청") { wifi.requestLocationIfNeeded() }.buttonStyle(CompactButtonStyle())
            } else {
                Button("시스템 설정 열기") { model.openLocationSettings() }.buttonStyle(CompactButtonStyle())
            }
        }
        .padding(12)
        .background(StatusTone.warn.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 값

    private var associated: Bool { wifi.info?.associated == true }

    /// 사이드바와 같은 판정 (StatusDisplay)
    private var tone: StatusTone { model.wifiTone(wifi.info) }

    private var conclusion: String {
        guard let info = wifi.info else { return "인터페이스 없음" }
        if !info.powerOn { return "꺼짐" }
        return info.associated ? "연결됨" : "연결 안 됨"
    }

    private var ssidText: String {
        guard let info = wifi.info, info.powerOn else { return "Wi-Fi" }
        guard info.associated else { return "연결 안 됨" }
        return info.ssid ?? (wifi.locationAuthorized ? "이름 없음" : "이름 숨김")
    }

    private var isDefaultRoute: Bool {
        guard let device = wifi.info?.interface else { return false }
        return model.defaultRoute?.interface == device
    }

    private var ipText: String {
        let address = model.wifiAddress
        guard let ip = address.ip else { return "–" }
        let prefix = address.subnet.flatMap(NetworkInfoFetcher.prefixLength(mask:)).map { "/\($0)" } ?? ""
        return ip + prefix
    }
}
