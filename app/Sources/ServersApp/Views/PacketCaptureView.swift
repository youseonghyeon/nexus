// 패킷 캡처 창 (윈도우 ▸ Packet Capture · 망 화면 진단 카드 [Capture…]). 열면 바로 시작, 닫으면 끝.
// 툴바(본창과 같은 unifiedCompact): 장치 · 캡처 필터(tcpdump 식 + 도우미) · 일시정지/재개 · 초기화 · .pcap 저장 · 상태.
// 본문: 요약 카드(대화 · 문제 · DNS · WireGuard — 누르면 목록을 그것만) → 패킷 카드(목록 검색 · 최근 것이 위) + 고른 패킷의 상세
// (넓으면 오른쪽, 좁으면 아래 — 경계를 끌어 높이 조절). hex·펼치는 트리는 두지 않는다 — 깊게 볼 때는 .pcap 을 Wireshark 로.
// 필터 도우미: 필터 칸을 누르면 아래에 다음 낱말·값 후보(servers.conf·게이트웨이·DNS·지금 캡처의 상대)·자주 쓰는 것,
// 목록 행·대화 줄 오른쪽 클릭으로 거꾸로 만들기, 적용 전 문법 검사(tcpdump -d, root 없이).
// 부품은 파일별로: CaptureFilterField(필터 칸·도우미 목록) · CaptureSummaryCard · PacketListCard · PacketDetailCard.

import ServersCore
import SwiftUI

struct PacketCaptureView: View {
    static let windowID = "packet-capture"
    /// 이 폭 이상이면 상세를 목록 오른쪽에
    static let sideDetailWidth: CGFloat = 1250

    @Environment(AppModel.self) private var model
    @ObservedObject var capture: PacketCaptureController
    @State private var filterText = ""
    /// 필터 칸을 편집 중인가 — 도우미를 띄운다. 툴바 안 칸이라 @FocusState 가 켜지지 않아(2026-11-02) NSTextField 가 직접 알린다
    @State private var filterEditing = false
    /// 바깥에서 필터 칸에 포커스를 주거나(도우미에서 낱말을 고른 뒤) 거둘 때(적용·창 열기) 올리는 번호
    @State private var filterFocusRequest = 0
    @State private var filterEndRequest = 0
    @State private var selection: Int?
    /// 행을 고르면 목록을 고정한다 — 최근 것이 위로 계속 들어와 보던 행이 밀리지 않게. 선택을 풀면 이어서
    @State private var frozen: [CaptureRow]?
    @State private var width: CGFloat = 1100
    @State private var pickerWidth: CGFloat = 160
    @State private var controlsWidth: CGFloat = 420

    var body: some View {
        // 스냅숏이 올 때마다(0.4초) body 가 다시 돈다 — 내 주소 집합·도우미 후보는 한 번만 만든다
        let localHosts = currentLocalHosts
        let suggestions = filterEditing ? makeSuggestions(localHosts: localHosts) : []
        VStack(alignment: .leading, spacing: 12) {
            if let problem = capture.filterError {
                Text(problem).foregroundStyle(StatusTone.warn.color).textSelection(.enabled)
            }
            if case .failed(let message) = capture.state {
                Text(message).foregroundStyle(StatusTone.bad.color).textSelection(.enabled)
            }
            CaptureSummaryCard(capture: capture, localHosts: localHosts) { apply(filter: $0) }
            packetsAndDetail
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
        .frame(minWidth: 900, minHeight: 600)
        .background(Palette.content)
        .background(FullScreenAuxiliary())
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .overlay(alignment: .top) {
            // 필터 도우미: 필터 칸(툴바 가운데) 바로 아래, 같은 폭. 열려 있는 동안 바깥 아무 곳이나 누르면 닫힌다 (메뉴·팝오버처럼 —
            // 요약·빈 바탕은 포커스를 받지 않아 눌러도 안 닫혔다, 2026-11-02). 첫 클릭은 닫기만 하고 아래로 넘기지 않는다
            if !suggestions.isEmpty {   // 편집 중이 아니면 비어 있다
                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeHelper() }
                    FilterSuggestionPanel(suggestions: suggestions, text: filterText, pick: { pick($0) },
                                          apply: { submitFromHelper() }, close: { closeHelper() })
                        .frame(width: filterWidth)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                devicePicker
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { pickerWidth = $0 }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
                FilterField(text: $filterText, editing: $filterEditing, focusRequest: filterFocusRequest, endRequest: filterEndRequest,
                            placeholder: "캡처 필터 — 누르면 도우미 (tcpdump 식 · Enter)") {
                    capture.submitFilter(filterText)
                    filterEndRequest += 1
                }
                    .frame(width: filterWidth)
                    .help("받는 것 자체를 거릅니다 — Enter 로 문법을 확인하고 그 조건으로 다시 시작. 받은 목록 안에서 찾을 때는 아래 검색칸")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                controls
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { controlsWidth = $0 }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            filterText = capture.filter
            capture.windowAppeared(defaultDevice: model.defaultRoute?.interface ?? "en0", runner: model.runner, vendors: AppModel.ouiTable)
            // 창을 열 때 필터 칸이 바로 입력 상태(파란 테두리)가 되지 않게
            Task { try? await Task.sleep(for: .milliseconds(120)); filterEndRequest += 1 }
        }
        .onDisappear {
            capture.windowClosed()
            selection = nil
            frozen = nil
        }
        .onChange(of: capture.device) { selection = nil }
        .onChange(of: capture.display) { selection = nil }
        .onChange(of: capture.search) { selection = nil }
        .onChange(of: selection) { _, id in
            let rows = frozen ?? capture.snapshot.visible
            if id != nil, frozen == nil { frozen = rows } else if id == nil { frozen = nil }
            capture.select(row: id, conversation: id.flatMap { id in rows.first { $0.id == id }?.conversation })
        }
    }

    /// 툴바 항목은 내용 크기만큼만 커진다 — 창 폭에서 양옆 항목(실제로 잰 폭)과 여백을 빼 준다
    private var filterWidth: CGFloat { max(220, width - pickerWidth - controlsWidth - 170) }

    // MARK: 목록 + 상세

    @ViewBuilder
    private var packetsAndDetail: some View {
        let list = PacketListCard(capture: capture, rows: frozen ?? capture.snapshot.visible, frozen: frozen != nil,
                                  selection: $selection, totalCount: frozen?.count ?? capture.snapshot.visibleCount) { apply(filter: $0) }
        if let row = selectedRow {
            let detail = PacketDetailCard(controller: capture, row: row, linkType: capture.snapshot.linkType,
                                          close: { selection = nil }, captureFilter: { apply(filter: $0) })
            if width >= Self.sideDetailWidth {
                HStack(alignment: .top, spacing: 12) {
                    list
                    detail.frame(width: 440)
                }
            } else {
                VSplitView {
                    list.frame(minHeight: 200).padding(.bottom, 6)
                    detail.frame(minHeight: 140, idealHeight: 240).padding(.top, 6)
                }
            }
        } else {
            list
        }
    }

    private var selectedRow: CaptureRow? {
        guard let id = selection else { return nil }
        return (frozen ?? capture.snapshot.visible).first { $0.id == id } ?? capture.snapshot.selectedRow.flatMap { $0.id == id ? $0 : nil }
    }

    // MARK: 필터 도우미

    private func makeSuggestions(localHosts: Set<String>) -> [FilterSuggestion] {
        CaptureFilterAssist.suggestions(for: filterText, context: filterContext(localHosts: localHosts))
    }

    /// 값 후보: servers.conf · 게이트웨이 · DNS · 지금 캡처의 상대 · 이 Mac 대역
    private func filterContext(localHosts: Set<String>) -> FilterContext {
        var hosts: [(String, String)] = []
        var seen = Set<String>()
        func add(_ ip: String?, _ label: String) {
            guard let ip, !ip.isEmpty, seen.insert(ip).inserted else { return }
            hosts.append((ip, label))
        }
        let servers = (model.config?.servers ?? []).map { ($0.key, $0.ip) }
        for (name, ip) in servers { add(ip, "\(name) · servers.conf") }
        add(model.defaultRoute?.gateway, "게이트웨이")
        for server in model.dnsConfig?.primary?.nameservers ?? [] { add(server, "DNS") }
        var ports: [(UInt16, String)] = []
        for c in capture.snapshot.top {
            for end in [c.a, c.b] {
                let host = Self.host(end)
                if !localHosts.contains(host) { add(host, "지금 캡처 · \(c.label ?? c.transport)") }
                if let port = Self.port(end), port < 49152, !ports.contains(where: { $0.0 == port }) { ports.append((port, "지금 캡처 · \(c.label ?? c.transport)")) }
            }
        }
        let nets = (model.localInfo?.routes?.entries ?? []).filter { $0.destination.contains("/") && $0.kind == .route }
            .map { ($0.destination, "이 Mac 경로 · \($0.interfaces.joined(separator: ", "))") }
        return FilterContext(hosts: hosts, ports: ports, nets: nets, servers: servers)
    }

    private func closeHelper() {
        filterEditing = false
        filterEndRequest += 1
    }

    private func submitFromHelper() {
        capture.submitFilter(filterText)
        closeHelper()
    }

    private func pick(_ suggestion: FilterSuggestion) {
        filterText = CaptureFilterAssist.apply(suggestion, to: filterText)
        if suggestion.kind == .preset {
            capture.submitFilter(filterText)
            filterEndRequest += 1
        } else {
            filterFocusRequest += 1   // 칸으로 돌아가 커서를 끝에 — 다음 제안이 바로 이어지게
        }
    }

    /// 오른쪽 클릭·[이 대화만 캡처]: 칸을 채우고 바로 적용 (문법 검사 뒤)
    private func apply(filter: String) {
        filterText = filter
        capture.submitFilter(filter)
    }

    /// 끝점("192.168.8.101:58108" · "[fd00::2]:443" · 포트 없는 "fe80::1")의 호스트·포트. 분해는 ServersCore CaptureEndpoint 하나로
    static func host(_ endpoint: String) -> String {
        CaptureEndpoint.parts(endpoint).host
    }

    static func port(_ endpoint: String) -> UInt16? {
        CaptureEndpoint.parts(endpoint).port.flatMap { UInt16(exactly: $0) }
    }

    // MARK: 툴바

    private var devicePicker: some View {
        Picker("장치", selection: Binding(get: { capture.device }, set: { capture.switchDevice($0) })) {
            ForEach(deviceChoices, id: \.self) { Text(deviceTitle($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                if capture.isActive { capture.pause() } else { capture.applyFilter(filterText); capture.start() }
            } label: {
                Image(systemName: capture.isActive ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help(capture.isActive ? "일시정지 — tcpdump 를 끝냅니다 (목록은 남음)" : "재개 — 관리자 인증 뒤 이어서 받습니다")
            Button("초기화") { capture.reset(); selection = nil }
                .help("목록과 요약을 비웁니다 (캡처는 계속)")
            Button(".pcap 저장") { capture.savePcap() }
                .disabled(capture.snapshot.rowCount == 0)
                .help("들고 있는 패킷을 저장합니다 — Wireshark 로 열 수 있습니다 (패킷마다 앞 \(CaptureStore.keptBytes) 바이트)")
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .fixedSize()
            .padding(.leading, 4)
        }
        .buttonStyle(CompactButtonStyle())   // 유리 캡슐을 뺀 툴바에서 글자만이면 버튼인지 몰랐다
    }

    private var statusText: String {
        let s = capture.snapshot
        var count = "\(s.totalPackets.formatted()) 패킷"
        if capture.skipped > 0 { count += " · 놓침 \(capture.skipped.formatted())" }
        switch capture.state {
        case .idle: return "멈춤"
        case .starting: return "인증·시작 중…"
        case .running: return "캡처 중 · \(count)"
        case .paused: return "일시정지 · \(count)"
        case .failed: return "멈춤 · \(count)"
        }
    }

    private var statusColor: Color {
        switch capture.state {
        case .running: return StatusTone.good.color
        case .starting: return StatusTone.warn.color
        case .failed: return StatusTone.bad.color
        case .idle, .paused: return StatusTone.muted.color
        }
    }

    /// tcpdump -D 의 장치 + 지금 장치 (목록을 아직 못 읽었어도 고른 장치는 보이게)
    private var deviceChoices: [String] {
        var list = capture.devices
        if !capture.device.isEmpty, !list.contains(capture.device) { list.insert(capture.device, at: 0) }
        return list
    }

    /// "en11 · TPlink 2.5G Ethernet" · "utun6 · Brume 3" — 하드웨어 포트 이름, 없으면 서비스·연결된 VPN 이름
    private func deviceTitle(_ device: String) -> String {
        if device == "lo0" { return "lo0 · Loopback" }
        if let name = capture.portNames[device] { return "\(device) · \(name)" }
        if let name = model.localInfo?.addresses.first(where: { $0.device == device })?.name, name != device { return "\(device) · \(name)" }
        if let id = model.vpnDetails.first(where: { $0.value.interface == device })?.key, let vpn = model.vpns?.first(where: { $0.id == id }) {
            return "\(device) · \(vpn.name)"
        }
        return device
    }

    /// 이 Mac 의 주소 — 대화 줄에서 내 쪽 끝을 옅게
    private var currentLocalHosts: Set<String> {
        var hosts: Set<String> = ["127.0.0.1", "::1"]
        for address in model.localInfo?.addresses ?? [] { hosts.insert(address.ip) }
        for detail in model.vpnDetails.values { hosts.formUnion(detail.ipv4.map { $0.split(separator: "/").first.map(String.init) ?? $0 }) }
        return hosts
    }
}

// MARK: 글자

enum CaptureText {
    /// 닫은 뒤 RST 는 정상 흐름(연결하자마자 닫는 확인)이라 무채색, 거부·RST 는 빨강, 재전송·Win=0 은 노랑
    static func tone(_ issue: TCPIssue) -> StatusTone {
        switch issue {
        case .resetAfterClose: return .muted
        case .refused, .reset: return .bad
        case .retransmission, .zeroWindow: return .warn
        }
    }

    static func ms(_ seconds: Double) -> String {
        CaptureFormat.ms(seconds)
    }

    static func clock(_ time: Double) -> String {
        Date(timeIntervalSince1970: time).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
    }
}

/// 메뉴 윈도우 ▸ Packet Capture (메뉴는 뷰 밖이라 openWindow 를 쓰는 작은 뷰로)
struct OpenCaptureButton: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Button("Packet Capture") {
            model.capture.prepare(device: nil, askPassHelper: model.askPassHelper)
            openWindow(id: PacketCaptureView.windowID)
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
    }
}
