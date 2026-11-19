// 서버 화면의 "변화 기록" 카드 (원격 정보 카드 아래): 원격 정보를 받을 때마다 지난번과 견줘 달라진 것 — 최근 것이 위 (ServersCore ServerHistory).
// 한 줄: 시각 · 사건. 서비스 실패 · 재부팅 필요해짐만 경고색. 접혀 있을 때는 최근 6개, [더보기]로 전부. [비우기]는 사건만 지운다.

import ServersCore
import SwiftUI

struct HistoryCard: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @State private var expanded = false

    /// 접혀 있을 때 보이는 줄 수
    private static let shown = 6

    var body: some View {
        let events = model.historyEvents(server)
        InfoCard(title: "변화 기록") {
            if events.isEmpty {
                Text("달라진 것이 없습니다. 원격 정보(Spec · Ports · Services)를 받을 때마다 지난번과 견줍니다.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // 격자: 시각 열 폭을 가장 긴 것에 맞춘다
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
                    ForEach(expanded ? events : Array(events.prefix(Self.shown))) { event in
                        GridRow {
                            Text(verbatim: ServerHistory.timeText(event.at)).font(.fieldLabel.monospacedDigit()).foregroundStyle(.secondary)
                            Text(verbatim: event.text).foregroundStyle(event.warning ? StatusTone.warn.color : Color.primary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if events.count > Self.shown {
                    Button(expanded ? "접기" : "더보기 (\(events.count - Self.shown))") { expanded.toggle() }
                        .buttonStyle(.borderless).controlSize(.small).font(.caption)
                }
            }
        } accessory: {
            if !events.isEmpty {
                Button("비우기") { model.clearHistory(server) }
                    .buttonStyle(.borderless).controlSize(.small).font(.caption)
                    .help("사건을 지웁니다 (견주는 기준은 그대로)")
            }
        }
        .id(server.key)   // 펼침이 다른 서버로 옮겨 가지 않게
    }
}
