// 터널 시트: 정보(접속 주소·DB 문자열·다시 연결/끊기) · 포트 입력. 둘 다 창이 곧 터널 그림이다 — 왼쪽 이 Mac → 오른쪽 서버 (TunnelSidePanel).

import AppKit
import ServersCore
import SwiftUI

/// 터널의 한쪽 (이 Mac · 서버) — 머리 줄(이름 · 오른쪽 조작부) + 주소 줄 + 안내 한 줄. 입력창과 정보 창이 같이 쓴다.
private struct TunnelSidePanel<Trailing: View, Address: View>: View {
    let title: String
    let hint: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var address: () -> Address

    /// 화살표를 주소 줄 높이에 맞출 때 쓰는 값: 칸 안 여백 + 머리 줄 + 간격
    static var addressOffset: CGFloat { 12 + 26 + 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: title).font(.cardTitle).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                trailing()
            }
            .frame(height: 26)   // 고르개가 있는 쪽과 없는 쪽의 주소 줄 높이를 맞춘다
            HStack(spacing: 6) { address() }
            Text(verbatim: hint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.content, in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).strokeBorder(Palette.hairline))
    }
}

/// 터널 정보 (2026-11-18 다시 그림 — 입력창과 같은 터널 그림): 제목 · 상태 → 왼쪽 이 Mac(접속 주소 크게 · 복사) → 오른쪽 서버(원격 대상) →
/// 용도별 접속 문자열(DB) → 다시 연결/끊기. 예전엔 경로를 글자 두 줄(`경로 a → b → c` / `바인드 … · 경유 …`)로 적어 한눈에 안 들어왔다.
/// 복사하는 값은 그대로 붙여 쓸 수 있는 것만: 이름 붙인 터널은 그 이름으로 (127.0.0.x 별칭에만 붙으므로 localhost 로는 안 닿는다).
struct TunnelInfoSheet: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var session: TunnelSession

    var body: some View {
        let spec = session.spec
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: heading).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(tone: session.tone)
                    Text(stateText).font(.callout)
                    if session.isActive {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("· \(Self.elapsed(from: session.startedAt, to: context.date))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if case let .closed(code, message) = session.state, !message.isEmpty {
                Text("exit \(code) · \(message)").font(.caption).foregroundStyle(StatusTone.warn.color).lineLimit(3)
            }

            HStack(alignment: .top, spacing: 10) {
                // 가장 자주 쓰는 값: 접속 주소
                TunnelSidePanel(title: "이 Mac", hint: "바인드 \(spec.localBind)") {
                    CopyButton(value: primaryAddress, model: model)
                } address: {
                    Text(verbatim: primaryAddress).font(.title3.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                }
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, TunnelSidePanel<EmptyView, EmptyView>.addressOffset + 4)
                TunnelSidePanel(title: remoteTitle, hint: "경유 \(spec.server.target)") { EmptyView() } address: {
                    Text(verbatim: remoteAddress).font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                }
            }
            // 이름이 HTTPS 전용 도메인으로 끝나는 포트 터널: 브라우저에서는 안 열린다 (HTTPSOnlyDomains)
            if case .port = spec.kind, spec.isNamed, let warning = HTTPSOnlyDomains.browserWarning(host: spec.localHost) {
                Label { Text(verbatim: warning) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(StatusTone.warn.color)
            }

            if case let .db(_, _, name) = spec.kind {
                let db = name ?? "<db>"
                let host = spec.localHost
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    copyRow("JDBC", "jdbc:postgresql://\(host):\(spec.localPort)/\(db)")
                    copyRow("psql", "psql \"postgresql://<user>:<password>@\(host):\(spec.localPort)/\(db)\"")
                }
                HStack(spacing: 6) {
                    CopyChip(label: "Host", value: host, model: model)
                    CopyChip(label: "Port", value: "\(spec.localPort)", model: model)
                    CopyChip(label: "DB", value: db, model: model)
                }
            }

            HStack {
                if session.isActive {
                    Button("끊기") { model.stopTunnel(session.id) }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("다시 연결") { model.reconnectTunnel(session.id) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!model.isReachable(spec.server))
                        .help("같은 조건으로 다시 엽니다")
                }
                Spacer()
                Button("닫기") { model.closeTunnelInfo() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 620)   // 입력창과 같은 폭
    }

    /// 창 제목: 입력창과 같은 말 ("web-01 포트 터널")
    private var heading: String {
        switch session.spec.kind {
        case .port: return "\(session.spec.server.key) 포트 터널"
        case .db: return "\(session.spec.server.key) DB 터널"
        case .socks: return "\(session.spec.server.key) 프록시 터널"
        }
    }

    /// 오른쪽 칸의 이름: 서버 자신의 포트면 "…에서", 서버를 거쳐 다른 곳이면 "…경유"
    private var remoteTitle: String {
        if case .port = session.spec.kind { return "\(session.spec.server.key) 에서" }
        return "\(session.spec.server.key) 경유"
    }

    /// 오른쪽 칸의 주소: 원격 대상 (SOCKS 는 정해진 대상이 없다)
    private var remoteAddress: String {
        switch session.spec.kind {
        case let .port(remote, host): return "\(host):\(remote)"
        case let .db(host, port, _): return "\(host):\(port)"
        case .socks: return "모든 주소 (SOCKS5)"
        }
    }

    /// 붙여 쓰는 주소: SOCKS 면 프록시 URL, 아니면 호스트:포트 (이름 붙인 터널은 그 이름)
    private var primaryAddress: String {
        let spec = session.spec
        if case .socks = spec.kind { return "socks5://\(spec.localHost):\(spec.localPort)" }
        return "\(spec.localHost):\(spec.localPort)"
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.body.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            CopyButton(value: value, model: model)
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 경과" }
        return "\(minutes / 60)시간 \(minutes % 60)분 경과"
    }

    private var stateText: String {
        switch session.state {
        case .connecting: return "연결 중"
        case .open: return "열림"
        case .idle: return "지난번에 연 터널 · [다시 연결]로 엽니다"
        case .closed: return "닫힘"
        }
    }
}

/// 터널 포트 입력. Ports 카드에서 오면 원격 포트와 제안 로컬 포트가 채워져 있다.
struct TunnelPromptSheet: View {
    @Environment(AppModel.self) private var model
    let request: TunnelPromptRequest
    @State private var remote: String
    @State private var local: String
    /// 원격 호스트 입력. 비우면 서버 자신(localhost), IP·이름을 쓰면 서버를 거쳐 그 주소로.
    @State private var host: String
    /// 서버 주소로 열기 (루프백 별칭 + hosts 이름). 늘 localhost 에서 시작하고, 여기서 고른 것은 이 터널에만 쓴다 (2026-11-17) —
    /// 서버 이름 방식은 /etc/hosts 를 고치느라 처음 한 번·재부팅 뒤 관리자 인증을 묻는다. 예전엔 기본이 서버 이름이고 마지막 선택을 설정에 기억했다.
    @State private var named = false
    /// hosts 이름 입력. 비우면 기본 이름(<서버키>.<그룹>).
    @State private var name = ""

    init(request: TunnelPromptRequest) {
        self.request = request
        _remote = State(initialValue: request.remotePort.map(String.init) ?? "")
        _host = State(initialValue: request.remoteHost == "127.0.0.1" ? "" : request.remoteHost)
        // 제안 로컬 포트(127.0.0.1 기준 다음 빈 포트)를 채워 둔다 — 창은 localhost 방식으로 열린다
        _local = State(initialValue: request.localPort.map(String.init) ?? "")
    }

    private var server: Server { request.server }
    private var isDB: Bool { request.dbTarget != nil }
    /// 칸 값 → 포트·호스트·[열기] 판정 (ServersCore TunnelDraft). DB 터널은 원격이 servers.conf 값으로 고정이라 편집창의 값을 쓰지 않는다.
    private var draft: TunnelDraft {
        TunnelDraft(remote: remote, local: local, host: host, name: name, named: named, fixedRemotePort: request.dbTarget?.port)
    }
    private var remotePort: Int? { draft.remotePort }
    private var localPort: Int? { draft.localPort }
    /// ssh -L 대상 호스트. 형식이 틀리면 nil (Open 비활성).
    private var remoteHost: String? { draft.remoteHost }
    private var localIsPrivileged: Bool { draft.localIsPrivileged }
    private var kind: TunnelKind {
        if let dbTarget = request.dbTarget { return .db(host: dbTarget.host, port: dbTarget.port, name: dbTarget.name) }
        return .port(remotePort: remotePort ?? 0, remoteHost: remoteHost ?? "127.0.0.1")
    }
    private var preview: (name: String, address: String) { model.namedTunnelPreview(server, kind: kind) }
    /// 실제로 쓸 hosts 이름: 입력값(공백 제거), 비었으면 기본 이름
    private var hostName: String { draft.hostName(defaultName: preview.name) }
    /// 서버 주소 모드에서 이름을 쓸 수 없는 이유 (형식 · 다른 터널과 충돌). nil 이면 열 수 있다.
    private var nameProblem: String? {
        let address = preview.address
        return draft.nameProblem(defaultName: preview.name) { model.namedTunnelConflict(name: $0, address: address) }
    }

    private enum Field { case remotePort, localPort }
    @FocusState private var focus: Field?

    /// 터널의 한쪽 (이 Mac · 서버) — 머리 줄(이름 · 오른쪽 조작부) + 주소 줄(호스트 : 포트) + 안내 한 줄
    private func side<Trailing: View, Address: View>(_ title: String, hint: String, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder address: @escaping () -> Address) -> some View {
        TunnelSidePanel(title: title, hint: hint, trailing: trailing, address: address)
    }

    private var colon: some View { Text(verbatim: ":").font(.body.monospaced().weight(.semibold)).foregroundStyle(.tertiary) }

    // 창이 곧 터널 그림이다 (2026-11-17 시안 A): 왼쪽 이 Mac → 오른쪽 서버. 예전엔 안내문(`…:<로컬> → … 127.0.0.1:<원격>`)과 아래 칸들이 같은 것을 다른 순서로 두 번 말했고,
    // 꼭 넣어야 하는 원격 포트가 맨 아래였다. 커서는 원격 포트에서 시작한다 (DB 터널은 원격이 고정이라 로컬 포트).
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isDB ? "\(server.key) DB 터널" : "\(server.key) 포트 터널").font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 10) {
                side("이 Mac", hint: "포트를 비우면 원격과 같은 번호") {
                    PlainSegmented(items: [false, true], selection: $named, title: { $0 ? "서버 이름" : "localhost" })
                        .help("서버 이름: 127.0.0.1 이 아니라 서버별 루프백 주소에 열고, /etc/hosts 에 \(hostName) 이름을 등록합니다. 서버마다 같은 포트를 써도 겹치지 않습니다. 처음 한 번·재부팅 뒤 관리자 인증.")
                } address: {
                    if named {
                        TextField(preview.name, text: $name).font(.body.monospaced()).accessibilityLabel("이름")
                    } else {
                        Text(verbatim: "localhost").font(.body.monospaced()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    colon
                    TextField(remotePort.map { String(PortAllocator.suggestedLocalPort(forRemote: $0)) } ?? "자동", text: $local)
                        .font(.body.monospaced()).frame(width: 76).focused($focus, equals: .localPort).accessibilityLabel("로컬 포트")
                }
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 12 + 26 + 8 + 4)   // 주소 줄 높이에 (칸 안 여백 + 머리 줄 + 간격)
                if let dbTarget = request.dbTarget {
                    side("\(server.key) 경유", hint: dbTarget.name.map { "데이터베이스 \($0)" } ?? "servers.conf 의 DB 주소") { EmptyView() } address: {
                        Text(verbatim: "\(dbTarget.host):\(dbTarget.port)").font(.body.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    }
                } else {
                    side("\(server.key) 에서", hint: "호스트를 비우면 서버 자신") { EmptyView() } address: {
                        TextField("127.0.0.1", text: $host).font(.body.monospaced()).accessibilityLabel("원격 호스트")
                        colon
                        TextField("포트", text: $remote).font(.body.monospaced()).frame(width: 76).focused($focus, equals: .remotePort).accessibilityLabel("원격 포트")
                    }
                }
            }
            if let l = localPort, draft.canOpen(nameProblem: nameProblem) {
                (Text("열리면 ") + Text(verbatim: "\(named ? hostName : "localhost"):\(l)").font(.callout.monospaced()).foregroundStyle(.primary) + Text(" 으로 접속합니다"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if localIsPrivileged {
                let suggested = localPort.map { PortAllocator.suggestedLocalPort(forRemote: $0) } ?? 8443
                Label {
                    Text(verbatim: "1024 미만 로컬 포트는 관리자 권한이 필요합니다. \(suggested) 같은 포트를 쓰세요.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption).foregroundStyle(StatusTone.warn.color)
            }
            if !isDB, remoteHost == nil {
                Label { Text(verbatim: "원격 호스트는 IP 나 호스트 이름만 쓸 수 있습니다 (포트는 원격 포트 칸에)") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(StatusTone.warn.color)
            }
            if let nameProblem {
                Label { Text(verbatim: nameProblem) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(StatusTone.warn.color)
            }
            // 막지 않는 경고: 이름이 HTTPS 전용 도메인으로 끝난다 (브라우저에서만 안 열린다)
            if let warning = draft.browserWarning(defaultName: preview.name) {
                Label { Text(verbatim: warning) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(StatusTone.warn.color)
            }
            HStack {
                Spacer()
                Button("취소") { model.closeTunnelPrompt() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                Button("열기") {
                    guard let l = localPort else { return }
                    model.closeTunnelPrompt()
                    if isDB {
                        model.openDBTunnel(server, localPort: l, named: named, name: named ? hostName : nil)
                    } else if let r = remotePort, let h = remoteHost {
                        model.openTunnel(server, remotePort: r, localPort: l, remoteHost: h, named: named, name: named ? hostName : nil)
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(!draft.canOpen(nameProblem: nameProblem))
            }
        }
        .padding(16)
        .frame(width: 620)
        .onAppear { focus = isDB ? .localPort : .remotePort }
    }
}
