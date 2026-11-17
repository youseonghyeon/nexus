// 터널 시트: 정보(접속 주소·DB 문자열·다시 연결/끊기) · 포트 입력.

import AppKit
import ServersCore
import SwiftUI

/// 터널 정보: 상태 → 접속 주소(크게, 복사) → 용도별 접속 문자열(DB) → 경로(작게) → 다시 연결/끊기.
/// 복사하는 값은 그대로 붙여 쓸 수 있는 것만: 이름 붙인 터널은 그 이름으로 (127.0.0.x 별칭에만 붙으므로 localhost 로는 안 닿는다).
struct TunnelInfoSheet: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var session: TunnelSession

    var body: some View {
        let spec = session.spec
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatusDot(tone: session.tone)
                Text(stateText).font(.headline)
                if session.isActive {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("· \(Self.elapsed(from: session.startedAt, to: context.date))").foregroundStyle(.secondary)
                    }
                }
            }
            if case let .closed(code, message) = session.state, !message.isEmpty {
                Text("exit \(code) · \(message)").font(.caption).foregroundStyle(StatusTone.warn.color).lineLimit(3)
            }

            // 가장 자주 쓰는 값: 접속 주소
            HStack(spacing: 8) {
                Text(primaryAddress).font(.title3.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                CopyButton(value: primaryAddress, model: model)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

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

            // 경로는 참고용: 작게
            VStack(alignment: .leading, spacing: 2) {
                Text("경로  \(pathText)").textSelection(.enabled)
                Text("      \(spec.isNamed ? "바인드 \(spec.localBind) · " : "")경유 \(spec.server.target)").textSelection(.enabled)
            }
            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)

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
        .frame(minWidth: 540)
    }

    /// 붙여 쓰는 주소: SOCKS 면 프록시 URL, 아니면 호스트:포트 (이름 붙인 터널은 그 이름)
    private var primaryAddress: String {
        let spec = session.spec
        if case .socks = spec.kind { return "socks5://\(spec.localHost):\(spec.localPort)" }
        return "\(spec.localHost):\(spec.localPort)"
    }

    /// "jenkins.acme:9090 → nexus → 127.0.0.1:9090". DB 는 경유 서버의 SSH 를 거쳐 DB 호스트로.
    private var pathText: String {
        let spec = session.spec
        let local = "\(spec.localHost):\(spec.localPort)"
        switch spec.kind {
        case let .port(remote, host): return "\(local) → \(spec.server.key) → \(host):\(remote)"
        case let .db(host, port, _): return "\(local) → \(spec.server.key) → \(host):\(port)"
        case .socks: return "\(local) → \(spec.server.key) 경유"
        }
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
    /// 서버 주소로 열기 (루프백 별칭 + hosts 이름). 마지막 선택을 기억한다.
    @AppStorage(AppPreferences.namedTunnelsKey) private var named = true   // 설정 창에도 같은 값
    /// hosts 이름 입력. 비우면 기본 이름(<서버키>.<그룹>).
    @State private var name = ""

    init(request: TunnelPromptRequest) {
        self.request = request
        _remote = State(initialValue: request.remotePort.map(String.init) ?? "")
        _host = State(initialValue: request.remoteHost == "127.0.0.1" ? "" : request.remoteHost)
        // 제안 로컬 포트(127.0.0.1 기준 다음 빈 포트)는 localhost 모드용. 서버 주소 모드는 별칭 주소라 원격과 같은 포트가 기본 — 비워서 placeholder 로 보인다.
        let namedOn = UserDefaults.standard.object(forKey: AppPreferences.namedTunnelsKey) as? Bool ?? true
        _local = State(initialValue: namedOn ? "" : request.localPort.map(String.init) ?? "")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isDB ? "\(server.key) DB 터널" : "\(server.key) 로컬 포트 터널").font(.title3.weight(.semibold))
            // 안내문은 입력을 따라 바로 바뀐다: 로컬 쪽은 모드(db.acme / localhost)와 로컬 포트(비우면 기본값), 원격 포트는 비어 있으면 <원격>
            let localSide = "\(named ? hostName : "localhost"):\(localPort.map(String.init) ?? "<로컬>")"
            if let dbTarget = request.dbTarget {
                Text(verbatim: "\(localSide) → \(server.key) 경유 → \(dbTarget.host):\(dbTarget.port)\(dbTarget.name.map { " (\($0))" } ?? "")")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // 서버 너머 주소면 DB 터널처럼 "nexus 경유 → 10.0.0.5:9090"
                let port = remotePort.map(String.init) ?? "<원격>"
                let route = switch remoteHost {
                case nil: "\(server.key) 경유 → <원격 호스트>:\(port)"
                case "127.0.0.1": "\(server.key) 127.0.0.1:\(port)"
                case let h?: "\(server.key) 경유 → \(h.contains(":") ? "[\(h)]" : h):\(port)"
                }
                Text(verbatim: "\(localSide) → \(route)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle(isOn: $named) {
                Text("localhost 대신 서버 이름으로 열기")
            }
            .toggleStyle(.checkbox)
            .help("127.0.0.1 이 아니라 서버별 루프백 주소에 열고, /etc/hosts 에 \(hostName) 이름을 등록합니다. 서버마다 같은 포트를 써도 겹치지 않습니다. 처음 한 번·재부팅 뒤 관리자 인증.")
            Grid(alignment: .leading) {
                // 서버 주소 모드는 이름을 먼저. 그다음 로컬 포트: 안내문(localhost:<로컬> → …)과 같은 순서. 비우면 원격과 같은 포트(특권 포트면 +8000).
                if named {
                    GridRow {
                        Text("이름")
                        TextField(preview.name, text: $name).frame(width: 200)
                    }
                }
                GridRow {
                    Text("로컬 포트")
                    TextField(remotePort.map { String(PortAllocator.suggestedLocalPort(forRemote: $0)) } ?? "원격과 같음", text: $local).frame(width: 120)
                }
                if let dbTarget = request.dbTarget {
                    GridRow { Text("원격"); Text(verbatim: "\(dbTarget.host):\(dbTarget.port)").foregroundStyle(.secondary) }
                } else {
                    GridRow { Text("원격 호스트"); TextField("127.0.0.1", text: $host).frame(width: 200) }
                    GridRow { Text("원격 포트"); TextField("예: 6443", text: $remote).frame(width: 120) }
                }
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
        .frame(width: 440)
    }
}
