// 서버 추가·편집 입력창.

import AppKit
import ServersCore
import SwiftUI

/// 서버 추가·편집 입력창. 추가는 이름·IP·사용자만 채우면 된다 (그룹·망은 누른 그룹 헤더 값으로 채워진다).
/// 편집은 바꾼 항목만 파일에 쓴다. 이름을 바꾸면 이름에 묶인 값(비밀번호·키 파일·터널 기록·wol_via·db_jump 등)을 함께 옮기고, 열린 탭·터널은 닫힌다.
struct ServerFormSheet: View {
    enum Mode {
        case add(AddServerRequest)
        case edit(Server)
    }

    @Environment(AppModel.self) private var model
    let mode: Mode
    @State private var key = ""
    @State private var group = ""
    @State private var network: ServerNetwork = .tailscale
    @State private var type: ServerType = .linux
    @State private var ip = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var role = ""
    @State private var env = ""
    @State private var notify = false
    @State private var error: ConfigError?
    @State private var peers: [TailscalePeer] = []
    @State private var portCheck: PortCheck = .idle
    @State private var pingCheck: PingCheck = .idle
    /// 확인·Ping 을 누를 때마다 올린다 — 칸을 바꾸고 곧바로 다시 누르면 먼저 끝난 옛 확인이 새 값 옆에 붙었다 (둘 다 checking 이라 구분이 안 됐다)
    @State private var portCheckRun = 0
    @State private var pingCheckRun = 0
    /// 내부망 설정이 없는 목록의 첫 Intranet 서버: 함께 쓸 [network:lan] service=
    @State private var lanService: String?
    /// network=vpn 의 VPN 이름 (vpn=). nil = 연결된 첫 VPN
    @State private var vpnName: String?
    /// Ping·포트 확인을 묶을 장치 (formBindDevice): vpn 은 고른 VPN 의 utun, lan 은 내부망 장치(설정이 없으면 고른 서비스의 장치).
    /// 그 망을 고른 동안 3초마다 다시 읽는다 (창을 연 채 VPN·Intranet 을 켜도 버튼이 켜지게)
    @State private var bindDevice: String?

    private var original: Server? {
        if case let .edit(server) = mode { return server }
        return nil
    }
    private var server: NewServer {
        NewServer(key: original?.key ?? key.trimmingCharacters(in: .whitespaces), group: group.trimmingCharacters(in: .whitespaces),
                  network: network, type: type,
                  ip: ip.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces),
                  port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
                  role: role.isEmpty ? nil : role, env: env.isEmpty ? nil : env, vpn: network == .vpn ? vpnName : nil,
                  extraUsers: original?.extraUsers ?? [])   // 추가 계정은 서버 정보의 사용자 칸에서만 고친다
    }
    /// 내부망 설정([network:lan])이 없는데 Intranet 을 골랐다 — 서비스도 고르게 한다
    private var needsLanService: Bool { network == .lan && model.config != nil && model.config?.lan == nil }
    /// 내부망 설정이 아직 없을 때 이 창에서 고른 서비스 — 저장하면 Intranet 서비스가 되고, 그 전의 Ping·포트 확인도 그 장치에 묶는다
    private var chosenLanService: String? { needsLanService ? lanService : nil }
    private var filled: Bool {
        !key.isEmpty && !ip.isEmpty && !user.isEmpty && !group.trimmingCharacters(in: .whitespaces).isEmpty
            && (!needsLanService || lanService != nil)
    }
    private var problem: String? {
        if !filled { return nil }   // 다 채우기 전엔 경고 없이 버튼만 비활성
        if let original {
            guard let config = model.config else { return nil }
            return ServerConfigEditor.renameProblem(newKey, for: original.key, in: config)
                ?? ServerConfigEditor.problem(editing: server, from: original, in: config)   // 바꾼 칸만
        }
        if model.config?.server(server.key) != nil { return "이미 있는 이름입니다 (\(server.key))" }
        return ServerConfigEditor.problem(server)
    }
    private var ready: Bool { filled && problem == nil }
    private var newKey: String { key.trimmingCharacters(in: .whitespaces) }
    /// 이름을 바꾸면 닫히는 탭·터널 안내 (열린 게 없으면 nil)
    private var renameClosesText: String? {
        guard let original, newKey != original.key else { return nil }
        let open = model.openSessionCount(original)
        return ServerFormCheck.renameClosesText(tabs: open.tabs, tunnels: open.tunnels)
    }
    /// 저장하면 저장한 비밀번호를 지우는가 (AppModel.updateServer) — 미리 보여 준다
    private var clearsPassword: Bool {
        guard let original else { return false }
        return ServerConfigEditor.clearedCredentials(original, server).contains { model.passwords[$0] != nil }
    }

    /// 채워야 할 칸 (버튼이 꺼진 이유 — 경고가 아니라 안내)
    private var missing: [String] {
        ServerFormCheck.missingFields(key: key, lanServiceMissing: needsLanService && lanService == nil, ip: ip, user: user, group: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original.map { "\($0.key) 편집" } ?? "서버 추가").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                // 접속 정보
                GridRow { label("이름"); TextField("예: nexus", text: $key).accessibilityLabel("이름") }
                GridRow {
                    label("네트워크")
                    // 같은 폭 네 칸 — "Tailscale VPN" 이 가장 넓어 칸이 두 줄로 꺾였다. 옆에 VPN 칸이 있으니 여기선 "Tailscale" 로
                    PlainSegmented(items: [ServerNetwork.direct, .lan, .vpn, .tailscale], selection: $network, equalWidths: true,
                                   title: { $0 == .tailscale ? "Tailscale" : model.networkName($0) })
                }
                if needsLanService {
                    GridRow { label("서비스"); lanServiceMenu }
                }
                if network == .vpn {
                    GridRow { label("VPN"); vpnMenu }
                }
                GridRow {
                    label("IP")
                    // 포트 줄과 같은 꼴 (칸 · 버튼 · 연결 그림) — 칸 폭을 고정해 결과가 나와도 칸이 줄지 않게
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            TextField(network == .tailscale ? "예: 100.101.0.9" : "예: 192.168.8.101", text: $ip).accessibilityLabel("IP")
                            if network == .tailscale, original == nil { peerMenu }
                        }
                        .frame(width: 140)
                        Button("Ping") { ping() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!ServerFormCheck.canPing(ip: ip, network: network, device: bindDevice, checking: pingCheck == .checking))
                            .help("IP 로 ping 을 \(PingTest.count)회 보냅니다")
                        if let phase = pingPhase {
                            PortProbeLine(phase: phase, width: 90).help(pingCheckText ?? "")   // 460 폭 창에 칸·버튼·"응답 없음" 까지 들어가게 짧게
                            if let text = pingResultText {
                                Text(verbatim: text).font(.caption).monospacedDigit()
                                    .foregroundStyle(pingCheck == .none ? StatusTone.bad.color : pingHasLoss ? StatusTone.warn.color : .secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                // 안내 문구는 모두 "예: …" — IP 는 Tailscale(100.x)만 따로, 사용자는 종류에 따라. 필수 칸은 아래 안내 줄이 알려 주므로 "비워도 됨" 은 쓰지 않는다
                GridRow { label("사용자"); TextField(type == .windows ? "예: Administrator" : type == .openwrt ? "예: root" : "예: nexus-user", text: $user).accessibilityLabel("사용자") }
                GridRow {
                    label("종류")
                    // 망 줄처럼 한 줄을 다 쓴다 — 포트·[확인]과 한 줄이면 세 칸이 "Windo…" · "Open…" 으로 잘렸다 (2026-10-20)
                    PlainSegmented(items: [ServerType.linux, .windows, .openwrt], selection: $type, equalWidths: true,
                                   title: { $0 == .linux ? "Linux" : ($0 == .windows ? "Windows" : "OpenWrt") })
                }
                GridRow {
                    label("포트")
                    HStack(spacing: 8) {
                        TextField("22", text: $port).accessibilityLabel("포트").frame(width: 56)
                        Button("확인") { checkPort() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!ServerFormCheck.canProbePort(ip: ip, port: portNumber, network: network, device: bindDevice, checking: portCheck == .checking))
                            .help("IP:포트에 TCP 연결을 한 번 시도합니다")
                        if let phase = probePhase {
                            PortProbeLine(phase: phase).help(portCheckText ?? "")
                            if let text = probeResultText {
                                Text(verbatim: text).font(.caption).monospacedDigit()
                                    .foregroundStyle(portCheck == .closed ? StatusTone.bad.color : .secondary)   // 실패만 색 (숫자는 그대로)
                            }
                        }
                    }
                }
                Divider().gridCellColumns(2)
                // 표시 정보
                GridRow {
                    label("그룹")
                    // ⌄ 는 칸 안 오른쪽 끝에 — 칸 밖 버튼이면 이 줄만 폭·모양이 달랐다 (2026-10-21)
                    TextField("예: AWS", text: $group).accessibilityLabel("그룹")
                        .overlay(alignment: .trailing) { groupMenu.padding(.trailing, 6) }
                }
                GridRow { label("역할"); TextField("예: WAS", text: $role).accessibilityLabel("역할") }
                GridRow(alignment: .firstTextBaseline) {   // 배지가 붙어도 라벨은 입력칸 줄에
                    label("태그")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("예: PROD", text: $env).accessibilityLabel("태그")
                        TagBadges(tags: ServerTags.parse(env))   // 사이드바와 같은 색으로 미리 (운영 빨강 · 스테이징 파랑)
                    }
                }
                GridRow { label("알림"); Toggle("켜짐·꺼짐 알림", isOn: $notify) }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let hint = ServerFormCheck.missingHint(missing, adding: original == nil) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                if let problem {
                    Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(StatusTone.warn.color)
                }
                if let text = renameClosesText {
                    Label(text, systemImage: "rectangle.stack")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if clearsPassword {
                    Label("IP·사용자가 바뀌면 그 계정의 저장한 비밀번호를 지웁니다", systemImage: "key")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("문제: \(error.problem)")
                        Text("해결: \(error.fix)")
                        Text("참조: \(error.reference)").foregroundStyle(.secondary)
                    }
                    .font(.caption).foregroundStyle(StatusTone.bad.color).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("취소") { close() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                Button(original == nil ? "추가" : "저장") {
                    error = save()
                    if error == nil { close() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(!ready)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear(perform: fill)
        .task(id: network) {
            if needsLanService { await model.refreshInternetRoute() }   // 서비스 목록·인터넷 경로 (고를 수 있는지)
            guard network == .tailscale, original == nil else { return }
            peers = await model.unregisteredTailscalePeers()
        }
        .task(id: [network.rawValue, vpnName ?? "", chosenLanService ?? ""]) {
            bindDevice = nil
            guard network == .vpn || network == .lan else { return }
            while !Task.isCancelled {
                bindDevice = await model.formBindDevice(network: network, vpn: vpnName, lanService: chosenLanService)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: [ip, port, network.rawValue, vpnName ?? "", chosenLanService ?? ""]) { portCheck = .idle }
        .onChange(of: [ip, network.rawValue, vpnName ?? "", chosenLanService ?? ""]) { pingCheck = .idle }
    }

    /// 라벨은 한 줄로 ("사용자" 가 "사용 / 자" 로 꺾이지 않게)
    private func label(_ text: String) -> some View {
        Text(text).fixedSize()
    }

    /// 아직 등록하지 않은 Tailscale 피어에서 골라 IP·종류(·비어 있으면 이름)를 채운다. 없으면 비활성.
    private var peerMenu: some View {
        Menu {
            ForEach(peers, id: \.self) { peer in
                Button("\(peer.name) · \(peer.ip)" + (peer.online ? "" : " · offline")) {
                    ip = peer.ip; type = peer.type
                    if key.isEmpty { key = peer.suggestedKey }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(peers.isEmpty)
        .help("Tailscale 피어에서 고르기")
    }

    /// 첫 Intranet 서버의 내부망 서비스: 유선 서비스 전부 (Ethernet 서비스 카드의 지정과 같다 — 검사 없음)
    @ViewBuilder
    private var lanServiceMenu: some View {
        let entries = model.lanServiceCandidates
        if entries.isEmpty {
            Text("유선 네트워크 서비스가 없습니다").foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(entries) { entry in
                    Toggle(entry.label, isOn: Binding(get: { entry.name == lanService }, set: { if $0 { lanService = entry.name } }))
                }
            } label: {
                Text(entries.first { $0.name == lanService }?.label ?? "서비스 고르기").lineLimit(1)
            }
            .fixedSize()
            .help("Intranet 켜기·끄기가 다룰 macOS 네트워크 서비스 — 나중에 Intranet 화면에서 바꿀 수 있습니다")
        }
    }

    /// network=vpn 의 VPN: 연결된 첫 VPN(이름 없이) 또는 시스템 설정의 VPN 하나 (Tailscale 제외 — 자기 망이 있다).
    /// 파일에 적힌 이름이 지금 목록에 없어도 그대로 보여 준다 (지우지 않게).
    private var vpnMenu: some View {
        let names = (model.vpns ?? []).map(\.name)
        let choices = names + (vpnName.map { names.contains($0) ? [] : [$0] } ?? [])
        return Menu {
            Toggle("연결된 첫 VPN", isOn: Binding(get: { vpnName == nil }, set: { if $0 { vpnName = nil } }))
            if !choices.isEmpty { Divider() }
            ForEach(choices, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { vpnName == name }, set: { if $0 { vpnName = name } }))
            }
        } label: {
            Text(vpnName ?? "연결된 첫 VPN").lineLimit(1)
        }
        .fixedSize()
        .help("이 서버로 가는 연결(SSH·전송·터널·상태 확인)을 이 VPN 의 인터페이스에 묶습니다 — VPN 이 꺼져 있으면 비활성")
    }

    /// 있는 그룹에서 고르기 (새 그룹은 칸에 직접)
    private var groupMenu: some View {
        Menu {
            ForEach(model.config?.groups ?? [], id: \.self) { g in
                Button(g) { group = g }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled((model.config?.groups ?? []).isEmpty)
        .help("있는 그룹에서 고르기")
        .accessibilityLabel("그룹 고르기")
    }

    /// 확인 상태와 그 문구는 ServersCore (ServerFormText.swift)
    private typealias PortCheck = ServerFormCheck.PortResult
    private var portNumber: Int? { ServerFormCheck.portNumber(port) }
    private var portCheckText: String? { portCheck.text(ip: ip, port: port) }

    /// 포트 줄 연결 그림의 단계 (확인 전엔 그림 없음)
    private var probePhase: PortProbeLine.Phase? {
        switch portCheck {
        case .idle: return nil
        case .checking: return .checking
        case .open: return .open
        case .closed: return .closed
        }
    }
    private var probeResultText: String? { portCheck.resultText }

    private func checkPort() {
        guard let p = portNumber else { return }
        let host = ip.trimmingCharacters(in: .whitespaces), net = network, vpn = vpnName, service = chosenLanService
        portCheck = .checking
        portCheckRun += 1
        let run = portCheckRun
        Task {
            let started = Date()
            let ok = await model.probePort(ip: host, port: p, network: net, vpn: vpn, lanService: service)
            // 확인하는 동안 칸을 바꿨으면 결과를 버린다 (onChange 가 idle 로 돌려놓음). 그 뒤 다시 눌렀으면 새 확인의 것만 받는다
            guard portCheck == .checking, run == portCheckRun else { return }
            portCheck = ok ? .open(Int(Date().timeIntervalSince(started) * 1000)) : .closed
        }
    }

    /// [Ping] 결과: 응답(평균 ms · 손실 %) / 응답 없음
    private typealias PingCheck = ServerFormCheck.PingResult
    private var pingHasLoss: Bool { pingCheck.hasLoss }
    private var pingPhase: PortProbeLine.Phase? {
        switch pingCheck {
        case .idle: return nil
        case .checking: return .checking
        case .replied: return .open
        case .none: return .closed
        }
    }
    /// 칸 옆 글자는 짧게 (ms, 일부 손실이면 노랑) — 손실 % 는 그림에 마우스를 올리면
    private var pingResultText: String? { pingCheck.resultText }
    private var pingCheckText: String? { pingCheck.text(ip: ip) }

    private func ping() {
        let host = ip, net = network, vpn = vpnName, service = chosenLanService
        pingCheck = .checking
        pingCheckRun += 1
        let run = pingCheckRun
        Task {
            let summary = await model.pingHost(ip: host, network: net, vpn: vpn, lanService: service)
            // ping 하는 동안 칸을 바꿨으면 결과를 버린다 (onChange 가 idle 로 돌려놓음). 그 뒤 다시 눌렀으면 새 ping 의 것만 받는다
            guard pingCheck == .checking, run == pingCheckRun else { return }
            pingCheck = .of(summary)
        }
    }

    private func fill() {
        switch mode {
        case let .add(request):
            group = request.group; network = request.network
        case let .edit(s):
            // 파일에 적힌 그대로 (태그도 쉼표 문자열 그대로) — 안 건드린 칸은 저장할 때 바뀐 것으로 치지 않는다
            key = s.key; group = s.group; network = s.network; type = s.type; ip = s.ip; user = s.primaryUser; port = String(s.port)
            role = s.role ?? ""; env = s.env ?? ""; notify = s.notify; vpnName = s.vpn
        }
    }

    private func save() -> ConfigError? {
        switch mode {
        case .add: return model.addServer(server, notify: notify, lanService: chosenLanService)
        case let .edit(s): return model.updateServer(s, to: server, notify: notify, lanService: chosenLanService, newKey: newKey)
        }
    }

    private func close() {
        switch mode {
        case .add: model.closeAddServerPrompt()
        case .edit: model.closeServerEditor()
        }
    }
}
