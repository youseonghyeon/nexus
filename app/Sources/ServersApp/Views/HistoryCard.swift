// 서버 화면의 "변경 이력" 카드 (원격 정보 카드 아래): 원격 정보를 받을 때마다 지난번과 견줘 달라진 것 — 최근 것이 위 (ServersCore ServerHistory).
// 사건이 있을 때만 보인다 (ServerInfoView) — [비우기]를 누르면 카드도 사라진다.
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
        InfoCard(title: "변경 이력") {
            do {
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
            Button("비우기") { model.clearHistory(server) }
                .buttonStyle(.borderless).controlSize(.small).font(.caption)
                .help("사건을 지웁니다 — 카드도 다음 변화가 생길 때까지 사라집니다 (견주는 기준은 그대로)")
        }
        .id(server.key)   // 펼침이 다른 서버로 옮겨 가지 않게
    }
}
