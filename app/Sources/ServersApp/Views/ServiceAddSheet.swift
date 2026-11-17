// Ethernet 화면 [서비스 추가…]: 케이블이 연결된 유선 어댑터에 수동 IP 서비스를 하나 만든다 (내부망용).
// 만든 서비스는 비활성 상태로 순서 맨 뒤 — 인터넷 경로를 가로채지 않는다. "Intranet 으로 지정" 을 켜 두면 만든 뒤 바로 지정한다.
// 입력 검사·명령은 ServersCore NetworkServiceDraft · LanCommands.createServiceScript.

import ServersCore
import SwiftUI

struct ServiceAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ports: [HardwarePort]?
    @State private var port = ""
    @State private var name = "Intranet"
    @State private var ip = ""
    @State private var mask = "255.255.255.0"
    @State private var router = ""
    @State private var dns = ""
    @State private var designate = true
    @State private var working = false
    @State private var error: String?

    private var draft: NetworkServiceDraft { NetworkServiceDraft(name: name, port: port, ip: ip, mask: mask, router: router, dns: dns) }
    private var filled: Bool { !name.isEmpty && !port.isEmpty && !ip.isEmpty && !mask.isEmpty && !router.isEmpty }
    /// 다 채운 뒤에만 경고 (서버 추가 창과 같은 규칙)
    private var problem: String? { filled ? draft.problem(existing: model.lanServices.map(\.name)) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("서비스 추가").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("어댑터").fixedSize()
                    if let ports {
                        if ports.isEmpty {
                            Text("케이블이 연결된 유선 어댑터가 없습니다").foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $port) {
                                ForEach(ports) { Text("\($0.name) (\($0.device))").tag($0.name) }
                            }
                            .labelsHidden()
                        }
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("확인 중…").foregroundStyle(.secondary) }
                    }
                }
                GridRow { Text("이름").fixedSize(); TextField("예: Intranet", text: $name) }
                Divider().gridCellColumns(2)
                GridRow { Text("IP").fixedSize(); TextField("예: 192.168.8.101", text: $ip) }
                GridRow { Text("서브넷").fixedSize(); TextField("255.255.255.0", text: $mask) }
                GridRow { Text("게이트웨이").fixedSize(); TextField("예: 192.168.8.1", text: $router) }
                GridRow { Text("DNS").fixedSize(); TextField("쉼표로 구분", text: $dns) }
                GridRow { Text(""); Toggle("만든 뒤 Intranet 으로 지정", isOn: $designate) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("비활성 상태로 만들고 서비스 순서 맨 뒤에 둡니다. 관리자 인증이 한 번 필요합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem {
                    Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(StatusTone.warn.color)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(StatusTone.bad.color).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle()).disabled(working)   // 인증·실행 중엔 결과를 볼 때까지
                Button("추가") {
                    working = true
                    Task {
                        error = await model.createNetworkService(draft, designate: designate)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(!filled || problem != nil || working)
            }
        }
        .padding(16)
        .frame(width: 420)
        .task {
            let found = await model.linkedWiredPorts()
            ports = found
            if port.isEmpty { port = found.first?.name ?? "" }
        }
    }
}
