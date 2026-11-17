// 서버별 액션 편집 시트 (tunnel_ports · proxy_port · wol_mac/wol_via).

import AppKit
import ServersCore
import SwiftUI

/// 서버별 액션 목록: 터널 바로가기(tunnel_ports) · Chrome 프록시(proxy_port) · 깨우기(wol_mac/wol_via — 경로마다 한 줄).
/// 각각 별개 — 한 줄에 하나씩 보이고, 추가·빼기는 하나씩 바로 servers.conf 에 쓴다.
/// 확정 버튼은 오른쪽 아래 한 자리에 하나만: 입력 중이면 [취소][추가], 아니면 [완료].
/// 예전엔 입력칸 아래 [추가]와 오른쪽 아래 [완료]가 같이 보여, 값을 넣고 [완료]를 누르면 입력이 말없이 버려졌다 (2026-11-10 사용자 지적).
struct ActionsEditSheet: View {
    @Environment(AppModel.self) private var model
    let server: Server

    private enum Kind { case tunnel, proxy, wake }
    @State private var adding: Kind?
    @State private var tunnelName = ""
    @State private var tunnelPort = ""
    @State private var proxyPort = "1080"
    @State private var wolMac = ""
    @State private var wolVia = ""
    @State private var wolIface = ""
    @State private var error: ConfigError?

    /// 저장할 때마다 다시 읽은 설정의 값
    private var current: Server { model.config?.server(server.key) ?? server }
    /// 아직 경로로 쓰지 않은 다른 서버
    private var wakeTargets: [Server] {
        model.config?.servers.filter { s in s.key != server.key && !current.wolRoutes.contains { $0.via == s.key } } ?? []
    }

    /// 입력 중인 액션 하나 (저장할 때는 파일에서 읽은 값에 이것만 적용한다)
    private var draftChange: ((inout ServerConfigEditor.Actions) -> Void)? {
        switch adding {
        case .tunnel:
            guard let port = Int(tunnelPort.trimmingCharacters(in: .whitespaces)) else { return nil }
            let name = tunnelName.trimmingCharacters(in: .whitespaces)
            return { $0.tunnelPorts.append(QuickTunnel(name: name.isEmpty ? nil : name, port: port)) }
        case .proxy:
            guard let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)) else { return nil }
            return { $0.proxyPort = port }
        case .wake:
            guard !wolMac.isEmpty, !wolVia.isEmpty else { return nil }
            let mac = wolMac.trimmingCharacters(in: .whitespaces).uppercased(), via = wolVia
            let iface = wolIface.trimmingCharacters(in: .whitespaces)
            return { $0.wolMac = mac; $0.wolRoutes.append(WakeRoute(via: via, iface: iface.isEmpty ? nil : iface)) }
        case nil:
            return nil
        }
    }
    /// 추가 버튼 활성·경고용: 지금 보이는 값에 적용해 본 결과
    private var draft: ServerConfigEditor.Actions? {
        guard let draftChange else { return nil }
        var a = ServerConfigEditor.Actions(current)
        draftChange(&a)
        return a
    }
    private var draftProblem: String? {
        guard let draft, let config = model.config else { return nil }
        return ServerConfigEditor.problem(draft, for: server.key, in: config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(server.key) 액션").font(.title3.weight(.semibold))

            let actions = ServerConfigEditor.Actions(current)
            // 지금 있는 액션: 우묵한 면 하나에 줄마다
            VStack(spacing: 0) {
                ForEach(actions.tunnelPorts, id: \.self) { t in
                    row(icon: "arrow.left.arrow.right.circle", title: t.label, detail: "원격 \(t.port)") {
                        save { $0.tunnelPorts.removeAll { $0.port == t.port } }
                    }
                }
                if let port = actions.proxyPort {
                    row(icon: "globe", title: "Chrome 프록시", detail: "로컬 \(port)") {
                        save { $0.proxyPort = nil }
                    }
                }
                if let mac = actions.wolMac {
                    ForEach(actions.wolRoutes, id: \.self) { route in
                        row(icon: "power", title: "Boot via \(route.via)", detail: (route.iface.map { "\($0) · " } ?? "") + mac) {
                            // 마지막 경로를 빼면 MAC 도 함께 (wol_mac 만 남으면 설정 오류)
                            save { $0.wolRoutes.removeAll { $0.via == route.via }; if $0.wolRoutes.isEmpty { $0.wolMac = nil } }
                        }
                    }
                }
                if actions == ServerConfigEditor.Actions() {
                    Text("추가한 액션이 없습니다").foregroundStyle(.secondary).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))

            if let adding {
                // 추가하는 중: 따로 띄운 면 — 목록과 섞이지 않고 "지금 이것을 넣는 중"으로 읽힌다
                form(adding)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
            } else {
                Menu {
                    Button("터널 바로가기") { start(.tunnel) }
                    Button("Chrome 프록시") { start(.proxy) }.disabled(actions.proxyPort != nil)
                    Button("부팅 (Wake-on-LAN)") { start(.wake) }.disabled(wakeTargets.isEmpty)
                } label: {
                    Label("액션 추가", systemImage: "plus").fontWeight(.medium)
                }
                // 보조 버튼과 같은 면 (메뉴 버튼은 버튼 스타일이 먹지 않아 바깥에서 입힌다)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Palette.control, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).strokeBorder(Palette.hairline))
            }

            if let error {
                VStack(alignment: .leading, spacing: 2) {
                    Text("문제: \(error.problem)")
                    Text("해결: \(error.fix)")
                    Text("참조: \(error.reference)").foregroundStyle(.secondary)
                }
                .font(.caption).foregroundStyle(StatusTone.bad.color).textSelection(.enabled)
            }
            // 확정 버튼 자리는 하나: 입력 중이면 그 입력의 [취소][추가], 아니면 창의 [완료]
            HStack(spacing: 8) {
                Spacer()
                if adding != nil {
                    Button("취소") { adding = nil; error = nil }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                    Button("추가") { if let change = draftChange, save(change) { adding = nil } }
                        .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                        .disabled(draft == nil || draftProblem != nil)
                } else {
                    Button("완료") { model.closeActionsEditor() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 420)
    }

    private func row(icon: String, title: String, detail: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
            Text(verbatim: detail).foregroundStyle(.secondary)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("지우기")
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func form(_ kind: Kind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .tunnel:
                Text("터널 바로가기 추가").font(.cardTitle).foregroundStyle(.secondary)
                HStack {
                    TextField("이름 (비워도 됨)", text: $tunnelName).frame(width: 150)
                    TextField("원격 포트", text: $tunnelPort).frame(width: 90)
                }
            case .proxy:
                Text("Chrome 프록시 추가").font(.cardTitle).foregroundStyle(.secondary)
                HStack { Text("로컬 SOCKS 포트"); TextField("1080", text: $proxyPort).frame(width: 90) }
            case .wake:
                Text("부팅 (Wake-on-LAN) 추가").font(.cardTitle).foregroundStyle(.secondary)
                Grid(alignment: .leading) {
                    // 경로를 더 넣을 때는 같은 PC 라 MAC 을 고정한다
                    GridRow { Text("MAC"); TextField("AA:BB:CC:DD:EE:FF", text: $wolMac).frame(width: 180).disabled(current.wolMac != nil) }
                    GridRow {
                        Text("깨워 줄 서버")
                        Picker("", selection: $wolVia) {
                            Text("선택").tag("")
                            ForEach(wakeTargets) { Text($0.key).tag($0.key) }
                        }
                        .labelsHidden().frame(width: 180)
                    }
                    GridRow { Text("인터페이스"); TextField("br-lan (비우면 wakeonlan)", text: $wolIface).frame(width: 180) }
                }
            }
            if let draftProblem {
                Label { Text(verbatim: draftProblem) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(StatusTone.warn.color)
            }
        }
    }

    private func start(_ kind: Kind) {
        tunnelName = ""; tunnelPort = ""; proxyPort = "1080"; wolMac = current.wolMac ?? ""; wolVia = ""; wolIface = ""
        error = nil
        adding = kind
    }

    @discardableResult
    private func save(_ change: (inout ServerConfigEditor.Actions) -> Void) -> Bool {
        error = model.updateActions(for: current, change)
        return error == nil
    }
}
