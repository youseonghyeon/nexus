// 서버 정보 화면: 대표 카드(이름·결론·상태 파이프라인·접속 버튼) → 접속 · 액션 카드 → 원격 정보 → 터널.

import ServersCore
import SwiftUI

/// 서버 정보 화면: 대표 카드(이름·결론·상태 파이프라인·접속 버튼) → 접속 · 액션 카드 → 원격 정보 → 터널.
struct ServerInfoView: View {
    @Environment(AppModel.self) private var model
    let server: Server

    /// 액션 카드 제목: 전원 줄이 있는 서버(부팅 경로가 있거나 Windows)만 "전원 · 파일"
    private var actionsTitle: String {
        model.wakeVia(server) != nil || server.type == .windows ? "전원 · 파일" : "파일"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                ServerHero(server: server)
                ViewThatFits(in: .horizontal) {
                    // 두 카드 높이를 맞춘다 — 파일 카드의 드롭 영역이 남는 높이를 채운다
                    HStack(alignment: .top, spacing: Metrics.gap) {
                        InfoCard(title: "접속") { ConnectionCard(server: server) } accessory: { EditServerButton(server: server) }
                            .fillingHeight()
                        InfoCard(title: actionsTitle) { ActionButtons(server: server) }
                            .fillingHeight()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Metrics.gap) {
                        InfoCard(title: "접속") { ConnectionCard(server: server) } accessory: { EditServerButton(server: server) }
                        InfoCard(title: actionsTitle) { ActionButtons(server: server) }
                    }
                }
                if RemoteCommands.query(.services, for: server.type) != nil {
                    RemoteInfoCard(server: server)
                    // 달라진 것이 있을 때만 — 빈 카드가 늘 떠 있으면 거슬렸다 (2026-11-18 사용자 지적)
                    if !model.historyEvents(server).isEmpty { HistoryCard(server: server) }
                }
                if model.tunnels.contains(where: { $0.server.key == server.key }) {
                    InfoCard(title: "터널") { TunnelsCard(server: server) }
                }
            }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 24, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 화면 맨 위 대표 카드: 누구인지(이름·주소) · 지금 어떤지(결론·파이프라인) · 무엇을 할지(접속 버튼)를 한 덩어리로.
/// 가장 자주 누르는 접속 버튼이 화면에서 가장 먼저 읽히는 자리에 온다 (전원·파일은 아래 액션 카드).
struct ServerHero: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 10) {
                ServerHeader(server: server)
                StatusPipeline(server: server)
            }
        } strip: {
            HStack(alignment: .top, spacing: 12) {
                ConnectActions(server: server)
                    .frame(maxWidth: .infinity, alignment: .leading)
                EditActionsButton(server: server).padding(.top, 5)
            }
            .padding(.horizontal, 20).padding(.vertical, 9)
        }
    }
}

/// 이름 · ENV · 역할, 오른쪽에 결론 한 줄
struct ServerHeader: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(server.key).font(.screenTitle).tracking(-0.6)
                    TagBadges(tags: server.tags, large: true)
                    if let role = server.role { Text(role).font(.title3).foregroundStyle(.secondary) }
                }
                // 주소는 기술 값 글꼴로 — 이름(제목)과 결이 갈린다
                Text("\(server.user)@\(server.ip)").font(.dataValue).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(text: conclusion, tone: model.remoteTone(server))   // 사이드바와 같은 판정 (StatusDisplay)
                if let at = model.status.checkedAt[server.key] {
                    Text("\(at.formatted(date: .omitted, time: .shortened)) 확인").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 결론 문구는 ServersCore StatusText.conclusion
    private var conclusion: String {
        StatusText.conclusion(model.status.remote(server.key), lanName: model.networkName(.lan))
    }
}

/// 망 → 피어 → SSH/포트. 어디서 막혔는지 한 줄로.
struct StatusPipeline: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        // 단계마다 알약, 사이는 가는 선 — 망에서 SSH 까지 한 줄로 이어진 길로 읽힌다. 확인 간격·방법 문구는 두지 않는다 (2026-11-17).
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Rectangle().fill(Palette.hairline).frame(width: 18, height: 1) }
                HStack(spacing: 6) {
                    Circle().fill(StatusTone(step.level) == .muted ? Color.secondary.opacity(0.5) : StatusTone(step.level).color).frame(width: 7, height: 7)
                    Text(step.label).foregroundStyle(.secondary)
                    Text(step.value).fontWeight(.semibold).monospacedDigit()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Palette.well, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline))
            }
            if let at = model.status.lastFailAt[server.key] {
                Text("마지막 실패 \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 14)
            }
            Spacer(minLength: 0)
        }
    }

    /// 단계 판정은 ServersCore StatusText.pipeline
    private var steps: [StatusText.PipelineStep] {
        StatusText.pipeline(server, in: model.status, lanName: model.networkName(.lan))
    }
}

/// 복사해서 쓰는 값만
struct ConnectionCard: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @State private var passwordDraft = ""
    /// 나가는 장치 (outgoingInterface). 상태 확인 한 라운드마다 다시 묻는다 — VPN 을 켜고 끄면 Direct 서버의 장치도 바뀐다.
    @State private var device: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            InfoRow("주소", server.ip)
            GridRow {
                Text("사용자").font(.fieldLabel).foregroundStyle(.secondary)
                AccountPicker(server: server)
            }
            GridRow {
                Text("비밀번호").font(.fieldLabel).foregroundStyle(.secondary)
                // 저장된 비밀번호(암호화 파일). 있으면 ssh·spec·터널·전송이 창 없이 대입한다.
                HStack(spacing: 6) {
                    if model.hasPassword(server) {
                        Text("●●●●●●●●").foregroundStyle(.secondary)
                        Text("저장됨").font(.caption).foregroundStyle(.tertiary)
                        Button("지우기") { model.clearPassword(for: server) }.buttonStyle(.borderless)
                    } else {
                        RomanSecureField("비밀번호", text: $passwordDraft, plain: true, onSubmit: savePassword)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(width: 180)
                            .fieldSurface()
                            .id(server.accountID)
                        Button("저장", action: savePassword).buttonStyle(.borderless).disabled(passwordDraft.isEmpty)
                    }
                }
            }
            GridRow {
                Text("키 파일").font(.fieldLabel).foregroundStyle(.secondary)
                // 기본 이름(~/.ssh/id_*)이 아닌 개인키(.pem 등)를 이 서버에만. 있으면 SSH 탭·상태 확인·전송·터널이 모두 -i 로 쓴다.
                HStack(spacing: 6) {
                    if let path = server.identityFile {
                        Text((path as NSString).lastPathComponent).help(path)
                        // 파일이 없으면 접속은 키 없이 (ConnectPolicy.identityOptions) — 권한이 열려 있으면 ssh 가 거부한다
                        switch model.identityProblem(server) {
                        case .missing: Text("파일 없음").font(.caption).foregroundStyle(StatusTone.warn.color)
                        case .tooOpen: Text("권한 열림 — ssh 가 쓰지 않음").font(.caption).foregroundStyle(StatusTone.warn.color)
                        case .notPrivateKey: Text("키 파일 아님").font(.caption).foregroundStyle(StatusTone.warn.color)
                        case nil: EmptyView()
                        }
                        Button("변경") { model.chooseIdentity(for: server) }.buttonStyle(.borderless)
                        Button("지우기") { model.clearIdentity(for: server) }.buttonStyle(.borderless)
                    } else {
                        Button("파일 선택…") { model.chooseIdentity(for: server) }.buttonStyle(.borderless)
                            .help("기본 키(~/.ssh/id_*)가 아닌 개인키로 접속할 때 (.pem 등)")
                    }
                }
            }
            InfoRow("셸", shellText)
            // 그룹 테마를 켠 Linux 서버만: 터미널에 찍히는 프롬프트 미리 보기 (태그 색은 운영 빨강·스테이징 파랑만)
            if let label = promptLabel {
                GridRow {
                    Text("프롬프트").font(.fieldLabel).foregroundStyle(.secondary)
                    Text("\(Text(label).foregroundStyle(promptColor)) ~ ❯").font(.body.monospaced())
                        .help("이 앱의 SSH 탭에서만 바꾸는 프롬프트 (서버의 셸 설정은 그대로)")
                }
            }
            InfoRow("네트워크", networkText)
            if let mac = server.wolMac, let route = model.wakeRoute(server) {
                InfoRow("부팅", "\(route.label) 경유 · \(mac)")
            }
        }
        .textSelection(.enabled)
        // 뷰는 서버가 바뀌어도 재사용된다: 입력 중이던 값이 다른 서버·계정에 저장되지 않게 비운다 (입력칸이 안 보이는 서버를 거쳐도)
        .onChange(of: server.accountID) { _, _ in passwordDraft = "" }
        .task(id: "\(server.key)|\(model.status.checkedAt[server.key]?.timeIntervalSince1970 ?? 0)|\(model.bindInterface(for: server) ?? "")") {
            device = await model.outgoingInterface(server)
        }
    }

    private func savePassword() {
        model.setPassword(passwordDraft, for: server)
        passwordDraft = ""
    }

    private var shellText: String {
        switch server.type {
        case .windows: return "PowerShell"
        case .linux: return "bash"
        case .openwrt: return "ash"
        }
    }

    /// 프롬프트 태그 글자 — 그룹 테마(theme=on)를 켠 Linux 서버만, 아니면 nil (줄 없음)
    private var promptLabel: String? {
        guard server.type == .linux, model.config?.settings(for: server.group)?.theme == true else { return nil }
        return SessionTheme.promptLabel(server.promptTag)
    }

    private var promptColor: Color {
        let tone = ServerTags.strongest(ServerTags.parse(server.promptTag))
        return tone == .plain ? .primary : tone.badgeColor
    }

    private var networkText: String {
        NetworkPathText.text(network: server.network, networkName: model.networkName(server.network), vpn: server.vpn, device: device, services: model.lanServices)
    }
}

/// 접속 카드의 사용자 칸: 계정 고르기 · [+] 추가 · 우클릭으로 제거·기본 계정. 아래 비밀번호·키 파일과 새로 여는 SSH·전송·터널·원격 정보가 고른 계정을 따른다.
/// 열린 탭·터널은 연 계정 그대로. 세그먼트는 3개까지 — 그보다 많으면 카드를 넘치니 메뉴로.
struct AccountPicker: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @State private var adding = false

    private static let segmentLimit = 3

    private var selection: Binding<String> {
        Binding(get: { server.user }, set: { model.selectAccount($0, of: server) })
    }

    var body: some View {
        HStack(spacing: 8) {
            if server.extraUsers.isEmpty {
                Text(server.user)
            } else if server.accounts.count <= Self.segmentLimit {
                PlainSegmented(items: server.accounts, selection: selection, title: { $0 }, itemMenu: { AnyView(menu(for: $0)) })
                    .fixedSize()
                    .help("이제부터 여는 SSH·전송·터널에 쓸 계정 · 우클릭으로 기본 계정·제거")
            } else {
                accountMenu
            }
            Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("계정 추가")
                .buttonStyle(.borderless)
                .help("이 서버의 다른 계정 추가")
                .popover(isPresented: $adding, arrowEdge: .bottom) { AddAccountPopover(server: server, isPresented: $adding) }
        }
    }

    /// 계정 하나의 우클릭 메뉴 (기본 계정엔 메뉴가 없다)
    @ViewBuilder
    private func menu(for name: String) -> some View {
        if name != server.primaryUser {
            Button("기본 계정으로") { model.promoteAccount(name, of: server) }
            Button("계정 제거…") { model.confirmRemoveAccount(name, of: server) }
        }
    }

    /// 계정이 많을 때: 메뉴 안에서는 항목을 우클릭할 수 없어 기본 계정·제거를 하위 메뉴로 둔다
    private var accountMenu: some View {
        Menu {
            ForEach(server.accounts, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { name == server.user }, set: { if $0 { model.selectAccount(name, of: server) } }))
            }
            Divider()
            Menu("기본 계정으로") {
                ForEach(server.extraUsers, id: \.self) { name in Button(name) { model.promoteAccount(name, of: server) } }
            }
            Menu("계정 제거") {
                ForEach(server.extraUsers, id: \.self) { name in Button("\(name)…") { model.confirmRemoveAccount(name, of: server) } }
            }
        } label: {
            Text(server.user).lineLimit(1)
        }
        .fixedSize()
        .help("이제부터 여는 SSH·전송·터널에 쓸 계정")
    }
}

/// [+] 를 누르면 뜨는 계정 이름 입력칸
private struct AddAccountPopover: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var error: ConfigError?

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { trimmed.isEmpty ? nil : ServerConfigEditor.accountProblem(trimmed, for: server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("예: deploy", text: $name).accessibilityLabel("계정 이름")
                    .frame(width: 180)
                    .onSubmit(add)
                Button("추가", action: add).buttonStyle(CompactButtonStyle()).disabled(trimmed.isEmpty || problem != nil)
            }
            if let message = problem ?? error?.problem {
                Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(StatusTone.warn.color)
                    .frame(width: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private func add() {
        guard !trimmed.isEmpty, problem == nil else { return }
        error = model.addAccount(trimmed, to: server)
        if error == nil { isPresented = false }
    }
}

/// 이 서버의 터널 (활성 먼저, 닫힘은 열기/지우기)
struct TunnelsCard: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.sortedTunnels.filter { $0.server.key == server.key }) { tunnel in
                TunnelInlineRow(tunnel: tunnel)
            }
        }
    }
}

struct TunnelInlineRow: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var tunnel: TunnelSession

    var body: some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            StatusDot(tone: tunnel.tone, size: 7)
            Text(tunnel.spec.summary).monospacedDigit().lineLimit(1)
            Spacer()
            Button("정보") { model.showTunnelInfo(tunnel) }.buttonStyle(CompactButtonStyle())
            if tunnel.isActive {
                Button("끊기") { model.stopTunnel(tunnel.id) }.buttonStyle(CompactButtonStyle())
            } else {
                Button("다시 연결") { model.reconnectTunnel(tunnel.id) }.buttonStyle(CompactButtonStyle())
                    .disabled(!model.isReachable(tunnel.server))
                Button("지우기") { model.removeTunnel(tunnel.id) }.buttonStyle(CompactButtonStyle())
            }
        }
    }
}

/// 접속 카드 제목 줄 끝: 서버 기본 항목 편집
struct EditServerButton: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        Button { model.editServer(server) } label: { Image(systemName: "pencil") }.accessibilityLabel("서버 편집")
            .buttonStyle(.borderless)
            .help("서버 편집 — 이름 · IP · 사용자 · 포트 · 그룹 · 역할 · 태그 · 알림")
    }
}

/// 액션 카드 제목 줄 끝: 서버별 액션 편집 (원격 정보 카드의 ↻ 와 같은 자리)
struct EditActionsButton: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        Button { model.editActions(server) } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("액션 편집")
            .buttonStyle(.borderless)
            .help("액션 편집 — 터널 바로가기 · 프록시 · 부팅")
    }
}

/// 대표 카드의 접속 버튼 줄: SSH(주 버튼) · Browser · Tunnel… · 서버별 바로가기. 버튼이 많으면 줄바꿈. 메뉴(메뉴 막대의 서버 메뉴·우클릭)와 같은 규칙.
struct ConnectActions: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        let reachable = model.isReachable(server)
        // 버튼이 많아지면 줄바꿈 (HStack 은 버튼을 줄여 버린다)
        FlowLayout {
            if model.status.remote(server.key).needsAuth {
                Button { model.tailscaleLogin(server) } label: { Label("Tailscale 로그인", systemImage: "person.badge.key") }
                    .disabled(model.busyAction != nil)
                    .help("브라우저에서 Tailscale SSH 인증 — 한 번이면 모든 서버에 적용됩니다")
            }
            Button { model.openSSH(server) } label: { Label(server.extraUsers.isEmpty ? "SSH" : "SSH · \(server.user)", systemImage: "terminal") }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(model.sidebarSearchFocused || model.tabPanelOpen ? nil : .defaultAction)
                .disabled(!reachable)
            Button { model.openBrowser(server) } label: { Label("Browser", systemImage: "globe") }
                .disabled(!reachable)
                .help("앱 안 브라우저 탭 — 이 서버로 연 SOCKS 터널만 지나고, 이 서버 IP 와 루프백(터널)만 허용")
            Button { model.promptTunnel(server) } label: { Label("Tunnel…", systemImage: "arrow.left.arrow.right") }
                .disabled(!reachable)
            if let settings = model.config?.settings(for: server.group), settings.dbJump == server.key {
                Button { model.promptDBTunnel(server) } label: { Label("DB Tunnel", systemImage: "cylinder") }
                    .disabled(!reachable)
            }
            if server.type == .windows, model.moonlightInstalled {
                Button { model.openMoonlight() } label: { Label("Moonlight", systemImage: "display") }
                    .disabled(!reachable)
                    .help("Moonlight 를 엽니다")
            }
            if server.proxyPort != nil, model.chromeInstalled {
                Button { model.openChromeProxy(server) } label: { Label("Chrome", systemImage: "globe") }
                    .disabled(!reachable)
                    .help("이 서버를 거쳐 나가는 Chrome 창 (SOCKS 프록시 · 별도 프로필)")
            }
        }
        .buttonStyle(SecondaryButtonStyle())   // SSH 는 PrimaryButtonStyle 이 안쪽에서 이긴다
    }
}

/// 액션 카드: 전원 · 파일(업로드·다운로드·드롭) 묶음. 접속 버튼은 대표 카드(ConnectActions)에.
struct ActionButtons: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        // 전원 줄이 있는 서버만 줄 이름을 단다 — 파일뿐이면 카드 제목이 이미 "파일"
        Group {
            if model.wakeVia(server) != nil || server.type == .windows {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("전원").font(.fieldLabel).foregroundStyle(.secondary)
                        PowerToggle(server: server)
                    }
                    GridRow {
                        Text("파일").font(.fieldLabel).foregroundStyle(.secondary)
                        TransferButtons(server: server)
                    }
                }
            } else {
                TransferButtons(server: server)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        TransferDropZone(server: server)
        if let busy = model.busyAction {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy.text) }
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 전원 토글: 꺼져 있으면 Boot, 켜져 있으면 Shutdown 하나만. 요청을 보낸 뒤 30초(또는 상태가 바뀔 때까지)는 스피너 + 설명으로 잠근다.
struct PowerToggle: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        // 요청 대기 중일 때만 1초 타임라인(남은 초). 만료는 settlePowerPendings 가 powerPendings 를 비워 알린다
        if let pending = model.powerPending(server) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(pending.until.timeIntervalSince(context.date).rounded(.up)))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(pending.kind == .boot ? "부팅 요청 보냄 (\(remaining)초)" : "종료 요청 보냄 (\(remaining)초)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } else if model.status.remote(server.key).isReachable {
            if server.type == .windows {
                Button(role: .destructive) { model.shutdown(server) } label: { Label("Shutdown…", systemImage: "power.circle") }
                    .disabled(!model.canShutdown(server))
                    .help("지금 종료합니다 (확인)")
            } else {
                Text("켜져 있음").font(.callout).foregroundStyle(.secondary)
            }
        } else if let via = model.wakeVia(server) {
            Button { model.wake(server) } label: { Label("Boot", systemImage: "power") }
                .disabled(!model.canWake(server))
                .help("\(via.key) 에서 WOL 패킷을 보냅니다")
        } else {
            Text("꺼져 있음").font(.callout).foregroundStyle(.secondary)
        }
    }
}
