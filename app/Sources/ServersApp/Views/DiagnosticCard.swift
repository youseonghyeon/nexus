// 진단 카드 (Intranet·Wi-Fi·Ethernet·VPN 화면 공통): ping 줄(+ 같은 대역이면 ARP) + HTTP 줄 + TCP 포트 + DNS 조회 + ARP 표. 그 화면의 장치로만 보낸다 (AppModel.diagnosticDevice).
// VPN 화면엔 ARP 표·ping 결과의 ARP 줄이 없다 — utun 은 점대점이라 ARP 가 없어 늘 비었다 (2026-11-01).
// 도구는 제목 줄의 탭으로 고르고(원격 정보 카드와 같은 꼴) 고른 도구의 입력칸 한 줄과 그 결과만 보인다 — 다섯 줄을 늘 펼쳐 두면 카드가 화면 높이를 먹었다 (2026-11-10).
// 도구를 옮겨도 다른 도구의 결과는 남아 있다. 장치가 없거나 입력이 꼴에 안 맞으면 버튼만 비활성.
// 결과 옆 복사 아이콘은 결과 전체를 텍스트로 (PingTestResult·HTTPTestResult.reportText).

import ServersCore
import SwiftUI

struct DiagnosticCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// 화면 키 (AppModel.lanKey·wifiKey·ethernetKey·vpnKey) — 결과·장치를 화면별로 가른다
    let screen: String
    var title = "진단"
    /// Wi-Fi 화면의 장치(AppModel.diagnosticDevice)는 WiFiMonitor 값 — AppModel(@Observable) 관찰에 잡히지 않아 따로 지켜본다
    @ObservedObject var wifi: WiFiMonitor
    /// 경로를 다 펼친 결과 (그 결과의 시각) — 새로 재면 다시 접힌다
    @State private var allHopsAt: Date?

    typealias Tool = AppModel.DiagnosticItem

    /// 고른 도구(제목 줄의 탭)와 입력칸 글자는 결과와 같이 AppModel 에 화면별로 둔다 (DiagnosticState) —
    /// 뷰 상태로 두면 다른 화면에 다녀올 때 결과만 남고 탭은 ping · 칸은 빈 채로 돌아왔다
    private var tool: Tool { model.diagnostics[screen]?.tool ?? .ping }
    private var toolSelection: Binding<Tool> {
        Binding(get: { tool }, set: { model.setDiagnosticTool($0, screen: screen) })
    }
    private func field(_ item: Tool) -> Binding<String> {
        Binding(get: { model.diagnostics[screen]?.inputs[item] ?? "" }, set: { model.setDiagnosticInput($0, for: item, screen: screen) })
    }

    /// 이 화면에서 고를 수 있는 도구 — VPN 화면엔 ARP 가 없다 (utun 은 ARP 가 없다)
    private var tools: [Tool] { Tool.allCases.filter { $0 != .arp || screen != AppModel.vpnKey } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(title).font(.cardTitle).foregroundStyle(.secondary)
                PlainSegmented(items: tools, selection: toolSelection, title: \.title)
                Spacer()
                // 이 화면의 장치로 패킷 캡처 창을 연다 (열면 바로 시작 — 관리자 인증)
                Button("Capture…") {
                    model.capture.prepare(device: device, askPassHelper: model.askPassHelper)
                    openWindow(id: PacketCaptureView.windowID)
                }
                .buttonStyle(CompactButtonStyle())
                .disabled(!DiagnosticRun.canCapture(device: device))
                .help("\(device ?? "이 장치") 의 패킷을 캡처 창에서 봅니다 (sudo tcpdump)")
            }
            switch tools.contains(tool) ? tool : .ping {
            case .ping: pingRows
            case .http: httpRows
            case .tcp: tcpRows
            case .dns: dnsRows
            case .arp: arpRows
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    private var device: String? { model.diagnosticDevice(screen) }

    /// 그 도구의 결과를 줄 아래 보이는가: 지금 장치로 잰 결과이거나, 실행 중이면 (장치가 바뀐 옛 결과는 숨긴다)
    private func showsResult(_ resultDevice: String?, _ tasks: DiagnosticTask...) -> Bool {
        guard let resultDevice else { return false }
        return resultDevice == device || tasks.contains { model.isDiagnosticRunning($0, screen) }
    }

    /// "en0 장치로만" (장치를 모를 땐 일반 문장 — 비활성 이유는 쓰지 않는다)
    private var via: String { device.map { "\($0) 장치로만" } ?? "이 화면의 장치로만" }

    /// 고른 도구의 한 줄: 입력칸 + [Run] (도구 이름은 제목 줄 탭에). 버튼은 영어로 — 도구 이름(ping·HTTP·TCP·DNS·ARP)과 같이 (2026-10-26)
    private func input(_ name: String, prompt: String, text: Binding<String>, canRun: Bool, help: String,
                       run: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .fieldSurface()
                .frame(maxWidth: 420)
                .onSubmit { if canRun { run() } }
                .accessibilityLabel(name)
            Button("Run", action: run)
                .buttonStyle(CompactButtonStyle()).disabled(!canRun)
                .help(help)
        }
    }

    // MARK: ping

    /// 입력칸 + [Run] → 응답(5회) · 경로(홉)
    @ViewBuilder
    private var pingRows: some View {
        let running = model.isDiagnosticRunning(.ping, screen)
        let tracing = model.isDiagnosticRunning(.trace, screen)
        let locating = model.isDiagnosticRunning(.locate, screen)
        let canRun = DiagnosticRun.canPing(field(.ping).wrappedValue, device: device, running: model.diagnosticRunning(screen))
        VStack(alignment: .leading, spacing: 10) {
            input("ping", prompt: "IP 또는 이름", text: field(.ping), canRun: canRun,
                  help: "\(via) ping \(PingTest.count)회를 보내고 이어서 경로를 확인합니다") {
                model.runDiagnosticPing(field(.ping).wrappedValue, screen: screen)
            }
            // 지금 장치로 보낸 결과만 (장치가 바뀌었으면 옛 결과는 숨긴다 — 실행 중인 것은 그대로 보인다)
            if let result = model.diagnostics[screen]?.ping, showsResult(result.device, .ping, .trace) {
                Grid(alignment: .leading, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
                    GridRow {
                        Text("대상").font(.fieldLabel).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(result.target).textSelection(.enabled)
                            Text("\(result.at.formatted(date: .omitted, time: .shortened)) · \(result.device)").font(.caption).foregroundStyle(.tertiary)
                            copyButton(result.reportText).disabled(running || tracing)
                            resetButton { model.clearDiagnostic(.ping, screen: screen); model.setDiagnosticInput("", for: .ping, screen: screen) }.disabled(running || tracing || locating)
                            Button("주소 검색") { model.locateDiagnosticHops(screen: screen) }
                                .buttonStyle(.borderless).controlSize(.small).font(.caption)
                                .disabled(running || tracing || locating || IPLocate.targets(result.hops ?? []).isEmpty)
                                .help("경로의 공인 IP 홉 위치를 ip-api.com 에 묻습니다 (요청 한 번)")
                            if locating { ProgressView().controlSize(.small) }
                        }
                    }
                    GridRow {
                        Text("응답").font(.fieldLabel).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if running {
                                ProgressView().controlSize(.small)
                                Text("보내는 중…").foregroundStyle(.secondary)
                            } else if result.resolveFailed {
                                Text("이름을 찾지 못했습니다").foregroundStyle(.secondary)
                            } else if let summary = result.summary {
                                Text(summary.text)
                                Text("\(PingTest.count)회").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let arp = result.arp, screen != AppModel.vpnKey {   // utun 은 ARP 가 없어 늘 "기록 없음"·"같은 대역 아님"
                        GridRow {
                            Text("ARP").font(.fieldLabel).foregroundStyle(.secondary)
                            Text(arp.text).monospacedDigit().textSelection(.enabled)
                        }
                    }
                    if !result.resolveFailed {
                        GridRow(alignment: .top) {
                            Text("경로").font(.fieldLabel).foregroundStyle(.secondary)
                            hopList(result, tracing: tracing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hopList(_ result: PingTestResult, tracing: Bool) -> some View {
        if tracing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("확인 중… (최대 \(PingTest.maxHops)홉)").foregroundStyle(.secondary)
            }
        } else if let hops = result.hops, !hops.isEmpty {
            let expanded = allHopsAt == result.at
            let visible = PingTest.visibleHops(hops, expanded: expanded)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(visible.shown, id: \.number) { hop in
                    GridRow {
                        Text("\(hop.number)").monospacedDigit().foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
                        // 주소·시간은 줄이지 않는다 — 좁으면 위치 칸만 말줄임
                        Text(hop.address ?? "*").monospacedDigit().foregroundStyle(hop.address == nil ? .tertiary : .primary).textSelection(.enabled)
                            .fixedSize()
                        Text(hop.ms.map { String(format: "%.1f ms", $0) } ?? (hop.address == nil ? "응답 없음" : "–"))
                            .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        Text(hop.address.flatMap { result.locations?[$0] }?.text ?? "")
                            .foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                }
                if let silent = visible.silent {
                    GridRow {
                        Text("\(silent.lowerBound)–\(silent.upperBound)").monospacedDigit().foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
                        Text("*").foregroundStyle(.tertiary)
                        Text("응답 없음 (\(silent.count)홉)").foregroundStyle(.secondary).fixedSize()
                    }
                }
                if visible.foldable {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Button(expanded ? "접기" : "더보기 (\(visible.hidden)홉)") { allHopsAt = expanded ? nil : result.at }
                            .buttonStyle(.borderless).font(.callout)
                            .gridCellColumns(2)
                    }
                }
            }
        } else if result.hops != nil {
            Text("경로를 읽지 못했습니다").foregroundStyle(.secondary)
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }

    /// 그 항목의 결과·입력칸을 비운다
    private func resetButton(help: String = "이 결과를 지웁니다", _ action: @escaping () -> Void) -> some View {
        DiagnosticResetButton(help: help, action: action)
    }

    /// 결과 전체를 텍스트로 복사 (경로는 접힌 홉까지) — 문의할 때 붙여 넣기용
    private func copyButton(_ text: String) -> some View {
        DiagnosticCopyButton(text: text)
    }

    // MARK: TCP · DNS

    /// IPv4:포트에 연결을 한 번 — ping 이 막혀도 서비스 포트는 열려 있는 경우가 많다
    @ViewBuilder
    private var tcpRows: some View {
        let running = model.isDiagnosticRunning(.tcp, screen)
        let canRun = DiagnosticRun.canTCP(field(.tcp).wrappedValue, device: device, running: model.diagnosticRunning(screen))
        VStack(alignment: .leading, spacing: 10) {
            input("TCP", prompt: "IPv4:포트 (예: 192.168.112.11:22)", text: field(.tcp), canRun: canRun,
                  help: "\(via) TCP 연결을 한 번 시도합니다 (최대 \(Int(TCPPortTest.timeout))초, 로그인하지 않습니다)") {
                model.runDiagnosticTCP(field(.tcp).wrappedValue, screen: screen)
            }
            if let result = model.diagnostics[screen]?.tcp, showsResult(result.device, .tcp) {
                resultGrid(target: "\(result.host):\(result.port)", at: result.at, device: result.device,
                           report: result.open == nil ? nil : result.reportText,
                           reset: { model.clearDiagnostic(.tcp, screen: screen); model.setDiagnosticInput("", for: .tcp, screen: screen) }) {
                    GridRow {
                        Text("결과").font(.fieldLabel).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if running { ProgressView().controlSize(.small) }
                            Text(result.text).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    /// 그 화면의 DNS 서버에 이름 하나 (A) — 이름이 안 풀리는지·엉뚱한 IP 로 풀리는지
    @ViewBuilder
    private var dnsRows: some View {
        let running = model.isDiagnosticRunning(.dns, screen)
        let server = model.diagnosticDNSServer(screen)
        let canRun = DiagnosticRun.canDNS(field(.dns).wrappedValue, device: device, server: server, running: model.diagnosticRunning(screen))
        VStack(alignment: .leading, spacing: 10) {
            input("DNS", prompt: "이름 (예: www.example.com)", text: field(.dns), canRun: canRun,
                  help: "\(server.map { "\($0) 에 " } ?? "이 화면의 DNS 서버에 ")이름 하나를 묻습니다") {
                model.runDiagnosticDNS(field(.dns).wrappedValue, screen: screen)
            }
            if let result = model.diagnostics[screen]?.dns, showsResult(result.device, .dns) {
                resultGrid(target: "\(result.name) @\(result.server)", at: result.at, device: result.device,
                           report: result.answers == nil && !result.timedOut ? nil : result.reportText,
                           reset: { model.clearDiagnostic(.dns, screen: screen); model.setDiagnosticInput("", for: .dns, screen: screen) }) {
                    GridRow {
                        Text("결과").font(.fieldLabel).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if running { ProgressView().controlSize(.small) }
                            Text(result.text).textSelection(.enabled)
                            if let ms = result.ms { Text("\(ms) ms").font(.caption).foregroundStyle(.tertiary) }
                            if let ttl = result.ttl {
                                Text("TTL \(DurationFormat.compact(TimeInterval(ttl)))").font(.caption).foregroundStyle(.tertiary)
                                    .help("이 답이 캐시에 남는 시간 (\(ttl)초)")
                            }
                        }
                    }
                    if !result.addresses6.isEmpty {
                        GridRow(alignment: .top) {
                            Text("IPv6").font(.fieldLabel).foregroundStyle(.secondary)
                            Text(result.addresses6.joined(separator: ", ")).textSelection(.enabled)
                        }
                    }
                    // CNAME 을 거쳤으면 경로도 (최종 주소만으론 어디로 갔는지 모른다)
                    if let answers = result.answers, answers.contains(where: { $0.type == "CNAME" }) {
                        GridRow(alignment: .top) {
                            Text("경로").font(.fieldLabel).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                                    Text("\(answer.type) \(answer.value)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    // 이 이름을 관리하는 영역의 네임서버 — 알려진 DNS 서비스면 그 이름을 앞에
                    if let zone = result.zone, !result.nameservers.isEmpty {
                        GridRow(alignment: .top) {
                            Text("네임서버").font(.fieldLabel).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    if let provider = result.provider { Text(provider) }
                                    Text(zone).font(.caption).foregroundStyle(.tertiary)
                                }
                                ForEach(result.nameservers, id: \.self) { server in
                                    Text(server).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 결과 묶음: 대상(+시각·장치·복사) 줄 + 내용
    private func resultGrid<Rows: View>(target: String, at: Date, device: String, report: String?, reset: @escaping () -> Void,
                                        @ViewBuilder rows: @escaping () -> Rows) -> some View {
        DiagnosticResultGrid(target: target, at: at, source: device, report: report, reset: reset, rows: rows)
    }

    // MARK: ARP

    /// 이 장치의 이웃 (IP ↔ MAC). 읽기만 — 앱 안에서 표가 비면 관리자 권한으로 다시 읽기
    @ViewBuilder
    private var arpRows: some View {
        let running = model.isDiagnosticRunning(.arp, screen)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // 입력칸 자리에 설명 — [Scan] 이 다른 도구의 [Run] 과 같은 자리에 오게
                Text("이 대역의 장비 (IP · MAC)").foregroundStyle(.tertiary)
                    .padding(.leading, 9).frame(maxWidth: 420, alignment: .leading)
                Button("Scan") { model.runDiagnosticArp(screen: screen) }
                    .buttonStyle(CompactButtonStyle())
                    .disabled(!DiagnosticRun.canScanArp(device: device, running: model.diagnosticRunning(screen)))
                    .help("\(via) 대역의 주소에 ping 을 한 번씩 병렬로 보내고, 응답한 장비(MAC)를 보여 줍니다")
                if running { ProgressView().controlSize(.small) }
            }
            if let result = model.diagnostics[screen]?.arp, showsResult(result.device, .arp) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(result.at.formatted(date: .omitted, time: .shortened)) · \(result.device)" + (result.subnet.map { " · \($0)" } ?? "")
                             + (result.found.map { " · \($0.count)대 응답" } ?? "") + (result.checked.map { " / \($0)개 확인" } ?? "")
                             + (result.privileged ? " · 관리자 권한" : ""))
                            .font(.caption).foregroundStyle(.tertiary)
                        copyButton(result.reportText).disabled(result.entries == nil)
                        resetButton(help: "이 Mac 의 ARP 캐시를 비우고(sudo arp -a -d, 관리자 인증) 이 결과를 지웁니다") { model.clearDiagnostic(.arp, screen: screen) }
                            .disabled(running)
                    }
                    // 응답한 장비(MAC 이 잡힌 것)만 — 답이 없는 주소(incomplete)는 보이지 않는다
                    if let entries = result.found {
                        if entries.isEmpty {
                            HStack(spacing: 8) {
                                Text("응답한 장비가 없습니다").foregroundStyle(.secondary)
                                if !result.privileged {
                                    Button("관리자 권한으로 다시 읽기") { model.runDiagnosticArp(screen: screen, privileged: true) }
                                        .buttonStyle(.borderless).controlSize(.small).disabled(running)
                                }
                            }
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                                ForEach(entries) { entry in
                                    GridRow {
                                        Text(entry.ip).monospacedDigit().textSelection(.enabled)
                                        Text(entry.mac ?? "").monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
                                        Text(result.identities[entry.ip]?.text ?? "").foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: HTTP

    /// 입력칸 + [Run] → 결과(상태 코드 또는 실패) · 연결(붙은 IP) · 시간(단계별) · 이동(리다이렉트)
    @ViewBuilder
    private var httpRows: some View {
        let canRun = DiagnosticRun.canHTTP(field(.http).wrappedValue, device: device, running: model.diagnosticRunning(screen))
        VStack(alignment: .leading, spacing: 10) {
            input("HTTP", prompt: "URL (http:// 생략 가능)", text: field(.http), canRun: canRun,
                  help: "\(via) 요청을 한 번 보냅니다 (본문은 저장하지 않고, 리다이렉트는 따라가지 않습니다)") {
                model.runDiagnosticHTTP(field(.http).wrappedValue, screen: screen)
            }
            if let result = model.diagnostics[screen]?.http, showsResult(result.device, .http) {
                resultGrid(target: result.url, at: result.at, device: result.device,
                           report: result.check == nil ? nil : result.reportText,
                           reset: { model.clearDiagnostic(.http, screen: screen); model.setDiagnosticInput("", for: .http, screen: screen) }) {
                    HTTPCheckRows(check: result.check)
                }
            }
        }
    }
}
