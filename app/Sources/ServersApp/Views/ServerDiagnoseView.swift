// 원격 정보 카드의 Diagnose 탭 (linux): 같은 대상을 이 Mac 과 그 서버에서 한 번씩 재서 나란히 보인다 (ServersCore ServerDiagnose).
// 도구(ping · TCP · HTTP · DNS)를 고르고 입력칸 한 줄 + [Run] → 왼쪽 "이 Mac" · 오른쪽 "<서버>" 칸에 결론 한 줄과 덧붙는 줄, 아래에 양쪽을 놓고 본 한 줄.
// 한쪽만 되거나 답이 다르면(다른 주소로 풀림 · 다른 상태 코드) 그 줄이 경고색. 도구를 옮겨도 다른 도구의 결과는 남아 있다.

import ServersCore
import SwiftUI

struct ServerDiagnoseView: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @State private var tool: ServerDiagnose.Tool = .ping
    @State private var inputs: [ServerDiagnose.Tool: String] = [:]

    private var input: Binding<String> { Binding(get: { inputs[tool] ?? "" }, set: { inputs[tool] = $0 }) }

    var body: some View {
        let run = model.serverDiagnose(server, tool)
        let canRun = ServerDiagnoseRun.canRun(tool, input: input.wrappedValue, reachable: model.isReachable(server), running: run?.running ?? false)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PlainSegmented(items: ServerDiagnose.Tool.allCases, selection: $tool, title: \.title)
                TextField(tool.placeholder, text: input)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .fieldSurface()
                    .frame(maxWidth: 360)
                    .onSubmit { if canRun { start() } }
                    .accessibilityLabel(tool.title)
                Button("Run", action: start)
                    .buttonStyle(CompactButtonStyle()).disabled(!canRun)
                    .help("이 Mac 과 \(server.key) 에서 함께 잽니다")
                Spacer(minLength: 0)
            }
            if let run {
                HStack(alignment: .top, spacing: 10) {
                    side("이 Mac", run.mac)
                    side(server.key, run.server)
                }
                .fixedSize(horizontal: false, vertical: true)   // 두 칸의 높이를 긴 쪽에 맞춘다
                HStack(spacing: 8) {
                    if let verdict = run.verdict(serverKey: server.key) {
                        Label { Text(verbatim: verdict.text) } icon: { Image(systemName: verdict.notable ? "exclamationmark.triangle" : "equal.circle") }
                            .font(.callout).foregroundStyle(verdict.notable ? StatusTone.warn.color : Color.secondary)
                    } else {
                        Text("재는 중…").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: "\(run.request.target) · \(run.at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Button { model.copy(run.reportText(serverKey: server.key)) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("결과 복사")
                        .buttonStyle(.borderless).controlSize(.small).disabled(run.running)
                        .help("결과를 텍스트로 복사")
                    Button("초기화") { model.clearServerDiagnose(tool, on: server) }
                        .buttonStyle(.borderless).controlSize(.small).font(.caption).disabled(run.running)
                        .help("이 결과를 지웁니다")
                }
            } else {
                Text("대상을 넣고 Run 을 누르면 이 Mac 과 \(server.key) 에서 함께 재서 나란히 보입니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        model.runServerDiagnose(tool, input: input.wrappedValue, on: server)
    }

    /// 한쪽의 결과 칸: 이름 · 결론 한 줄(상태 점) · 덧붙는 줄. nil 이면 재는 중
    private func side(_ title: String, _ outcome: ServerDiagnose.Outcome?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.cardTitle).foregroundStyle(.secondary).lineLimit(1)
            if let outcome {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(tone: tone(outcome.state))
                    Text(verbatim: outcome.headline).font(.body.monospacedDigit()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(outcome.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("재는 중…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.content, in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).strokeBorder(Palette.hairline))
    }

    private func tone(_ state: ServerDiagnose.Outcome.State) -> StatusTone {
        switch state {
        case .ok: return .good
        case .failed: return .bad
        case .unavailable: return .muted
        }
    }
}
