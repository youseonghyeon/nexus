// 원격 정보 카드의 Diagnose 탭 (linux · openwrt): 대상을 넣으면 그 서버에서 재서 보인다 (ServersCore ServerDiagnose) — 서버에 들어가 직접 쳐 보던 것을 대신한다.
// 모양은 망 화면의 진단 카드와 같다: 도구 탭(ping · TCP · HTTP · DNS) → 입력칸 한 줄 + [Run] → 결과 격자. 결과 줄은 진단 카드와 같은 부품(DiagnosticResultRows)으로 그린다. 도구를 옮겨도 다른 도구의 결과는 남아 있다.
// 이 Mac 에서 재는 것은 망 화면의 진단 카드 (여기서는 뺐다 — 2026-11-18 사용자 결정).

import ServersCore
import SwiftUI

struct ServerDiagnoseView: View {
    @Environment(AppModel.self) private var model
    let server: Server
    /// 고른 도구와 입력칸 글자는 결과와 같이 AppModel 에 서버별로 둔다 (ServerDiagnoseForm) — 다른 화면에 다녀와도 남는다
    private var tool: ServerDiagnose.Tool { model.serverDiagnoseForms[server.key]?.tool ?? .ping }
    private var toolSelection: Binding<ServerDiagnose.Tool> {
        Binding(get: { tool }, set: { model.setServerDiagnoseTool($0, on: server) })
    }
    private var input: Binding<String> {
        Binding(get: { model.serverDiagnoseForms[server.key]?.inputs[tool] ?? "" }, set: { model.setServerDiagnoseInput($0, for: tool, on: server) })
    }

    var body: some View {
        let run = model.serverDiagnose(server, tool)
        let canRun = ServerDiagnoseRun.canRun(tool, input: input.wrappedValue, reachable: model.isReachable(server), running: run?.running ?? false)
        // 망 화면의 진단 카드(DiagnosticCard)와 같은 꼴: 도구 탭 → 입력칸 한 줄 + [Run] → 결과 격자
        VStack(alignment: .leading, spacing: 10) {
            PlainSegmented(items: ServerDiagnose.Tool.allCases, selection: toolSelection, title: \.title)
            HStack(spacing: 8) {
                TextField(tool.placeholder, text: input)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .fieldSurface()
                    .frame(maxWidth: 420)
                    .onSubmit { if canRun { start() } }
                    .accessibilityLabel(tool.title)
                Button("Run", action: start)
                    .buttonStyle(CompactButtonStyle()).disabled(!canRun)
                    .help("\(server.key) 에서 잽니다")
            }
            if let run {
                // 결과 줄은 진단 카드와 같은 부품으로 (DiagnosticResultRows) — 보낸 곳 자리에 장치 대신 서버 키
                DiagnosticResultGrid(target: run.request.target, at: run.at, source: server.key,
                                     report: run.running ? nil : run.reportText(serverKey: server.key),
                                     reset: { model.clearServerDiagnose(tool, on: server); model.setServerDiagnoseInput("", for: tool, on: server) }) {
                    resultRows(run)
                }
            }
        }
    }

    /// 도구마다의 결과 줄 — 진단 카드의 같은 도구와 같은 줄. 서버에서 못 얻는 줄(ping 경로 · DNS 의 TTL·네임서버)만 없다
    @ViewBuilder
    private func resultRows(_ run: ServerDiagnose.Run) -> some View {
        let outcome = run.outcome
        // 재지 못했거나(도구 없음 · 접속 실패) 이름이 안 풀린 것은 흐리게
        let dim = outcome?.state == .unavailable || outcome?.headline == ServerDiagnose.unresolvedText
        if run.request.tool == .http, outcome == nil || outcome?.check != nil {
            HTTPCheckRows(check: outcome?.check)
        } else {
            GridRow {
                Text(run.request.tool == .ping ? "응답" : "결과").font(.fieldLabel).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let outcome {
                        Text(verbatim: outcome.headline).monospacedDigit().textSelection(.enabled)
                            .foregroundStyle(dim ? Color.secondary : Color.primary)
                        if run.request.tool == .ping, !dim { Text("\(PingTest.count)회").font(.caption).foregroundStyle(.tertiary) }
                        if let ms = outcome.ms { Text("\(ms) ms").font(.caption).foregroundStyle(.tertiary) }
                    } else {
                        ProgressView().controlSize(.small)
                        switch run.request.tool {
                        case .ping: Text("보내는 중…").foregroundStyle(.secondary)
                        case .dns: Text("묻는 중…")
                        default: Text("확인 중…")
                        }
                    }
                }
            }
            if let v6 = outcome?.addresses6, !v6.isEmpty {
                GridRow(alignment: .top) {
                    Text("IPv6").font(.fieldLabel).foregroundStyle(.secondary)
                    Text(verbatim: v6.joined(separator: ", ")).textSelection(.enabled)
                }
            }
        }
    }

    private func start() {
        model.runServerDiagnose(tool, input: input.wrappedValue, on: server)
    }
}
