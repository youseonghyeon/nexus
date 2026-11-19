// 진단 결과 줄 — 망 화면의 진단 카드(DiagnosticCard)와 서버의 Diagnose 탭(ServerDiagnoseView)이 같이 쓴다.
// 따로 그리면 모양이 갈린다 (2026-11-18: Diagnose 탭이 결과를 "상세" 글 줄로만 보여 진단 카드와 달라 보였다) — 줄을 고칠 땐 여기서.

import ServersCore
import SwiftUI

/// 결과 전체를 텍스트로 복사 (경로는 접힌 홉까지) — 문의할 때 붙여 넣기용
struct DiagnosticCopyButton: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        Button { model.copy(text) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("결과 복사")
            .buttonStyle(.borderless).controlSize(.small)
            .help("결과를 텍스트로 복사")
    }
}

/// 그 항목의 결과·입력칸을 비운다
struct DiagnosticResetButton: View {
    var help = "이 결과를 지웁니다"
    let action: () -> Void

    var body: some View {
        Button("초기화", action: action)
            .buttonStyle(.borderless).controlSize(.small).font(.caption)
            .help(help)
    }
}

/// 결과 묶음: 대상(+시각·보낸 곳·복사·초기화) 줄 + 내용. report 가 nil 이면(재는 중) 복사·초기화가 꺼진다
struct DiagnosticResultGrid<Rows: View>: View {
    let target: String
    let at: Date
    /// 보낸 곳 — 망 화면은 장치(en0), Diagnose 탭은 서버 키
    let source: String
    let report: String?
    let reset: () -> Void
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
            GridRow {
                Text("대상").font(.fieldLabel).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(verbatim: target).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(verbatim: "\(at.formatted(date: .omitted, time: .shortened)) · \(source)").font(.caption).foregroundStyle(.tertiary)
                    DiagnosticCopyButton(text: report ?? "").disabled(report == nil)
                    DiagnosticResetButton(action: reset).disabled(report == nil)
                }
            }
            rows()
        }
    }
}

/// HTTP 결과 줄들 (격자 안에): 결과(상태 코드 또는 실패) · 상세(curl 문장) · 이동(리다이렉트) · 연결(붙은 IP) · 시간(단계별). check 가 nil 이면 요청 중
struct HTTPCheckRows: View {
    let check: HTTPCheck?

    var body: some View {
        GridRow {
            Text("결과").font(.fieldLabel).foregroundStyle(.secondary)
            if let check {
                HStack(spacing: 8) {
                    if let failure = check.failureText {
                        Text(failure)
                    } else if let status = check.status {
                        Text("\(status)").monospacedDigit()
                        if let kind = HTTPTest.statusKind(status) { Text(kind).foregroundStyle(.secondary) }
                        // 헤더는 받았는데 본문을 끝까지 못 받음 (큰 파일·느린 서버)
                        if let note = check.bodyNote { Text("· \(note)").foregroundStyle(.secondary) }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("요청 중… (최대 \(HTTPTest.maxTime)초)").foregroundStyle(.secondary)
                }
            }
        }
        if let check {
            // 실패면 curl 문장을 그대로 (원인 확인용 — 예: self signed certificate)
            if check.failureText != nil || check.bodyNote != nil, let error = check.error {
                InfoRow("상세", error)
            }
            if let redirect = check.redirect {
                GridRow {
                    Text("이동").font(.fieldLabel).foregroundStyle(.secondary)
                    Text(redirect).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            if let endpoint = check.endpoint { InfoRow("연결", endpoint) }
            if let stages = check.stages, stages.dnsMs != nil {
                GridRow(alignment: .top) {
                    Text("시간").font(.fieldLabel).foregroundStyle(.secondary).padding(.top, 1)
                    HTTPTimingBar(stages: stages)
                }
            }
        }
    }
}

/// 시간 줄: 전체 시간 + 단계별 비율 막대 + 단계마다 숫자. 숫자만 늘어놓으면 어디서 걸렸는지 다 읽어야 알았다 (2026-11-10)
struct HTTPTimingBar: View {
    let stages: HTTPStages
    /// 막대·범례에서 마우스가 올라간 단계 (이름)
    @State private var hoveredStage: String?

    /// 단계마다의 농도 (메모리 구성 막대와 같은 무채색 단계). 서버가 답을 만드는 시간(TTFB)이 가장 진하다 — 보통 여기가 길다
    private static let stageOpacity: [String: Double] = ["DNS": 0.30, "TCP": 0.45, "TLS": 0.60, "TTFB": 0.90, "Download": 0.20]

    var body: some View {
        let segments = stages.segments
        VStack(alignment: .leading, spacing: 5) {
            Text(stages.totalText).fontWeight(.semibold).monospacedDigit().textSelection(.enabled)
            // 몫·범례에 마우스를 올리면 그 단계가 무슨 처리이고 얼마나 걸렸는지 바로 뜬다 (HTTPStages.Segment.help).
            // 시스템 풀이말은 1~2초 늦어 "안 된다"로 보였다 — 막대 위에 직접 띄운다 (자리를 차지하지 않게 겹쳐서)
            StackedBar(segments: segments.map { .init(id: $0.name, value: $0.ms, opacity: Self.stageOpacity[$0.name] ?? 0.5) },
                       total: max(segments.map(\.ms).reduce(0, +), 0.001),
                       onHover: { hoveredStage = $0 })
                .frame(maxWidth: 420)
                .overlay(alignment: .topLeading) {
                    if let stage = segments.first(where: { $0.name == hoveredStage }) {
                        Text(stage.help).font(.caption).monospacedDigit().lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Palette.control, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous).strokeBorder(Palette.fieldBorder))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                            .offset(y: -30)
                            .allowsHitTesting(false)
                    }
                }
            FlowLayout(spacing: 12, lineSpacing: 3) {
                ForEach(segments) { segment in
                    HStack(spacing: 4) {
                        Swatch(opacity: Self.stageOpacity[segment.name] ?? 0.5)
                        Text(segment.name).foregroundStyle(.secondary)
                        Text(segment.text).monospacedDigit()
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                    .onHover { inside in hoveredStage = inside ? segment.name : (hoveredStage == segment.name ? nil : hoveredStage) }
                }
            }
        }
    }
}
