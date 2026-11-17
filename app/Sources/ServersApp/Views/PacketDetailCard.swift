// 패킷 캡처 창의 상세 카드: 고른 패킷의 계층별 줄 + 그 패킷이 속한 대화.

import ServersCore
import SwiftUI

/// 고른 패킷의 상세 줄. 컨트롤러 스냅숏이 0.4초마다 새로 와 body 가 다시 돌아도, 같은 패킷이면 다시 풀지 않는다
/// (관찰 대상이 아닌 보관함이라 body 안에서 채워도 다시 그리기를 부르지 않는다)
@MainActor
private final class PacketSectionsCache {
    private var row: CaptureRow?
    private var linkType: UInt32 = 0
    private var sections: [DetailSection] = []

    func sections(for row: CaptureRow, linkType: UInt32) -> [DetailSection] {
        if self.row != row || self.linkType != linkType {
            self.row = row
            self.linkType = linkType
            sections = PacketDetails.sections(row, linkType: linkType) { AppModel.ouiTable?.vendor(mac: $0) }
        }
        return sections
    }
}

struct PacketDetailCard: View {
    @ObservedObject var controller: PacketCaptureController
    let row: CaptureRow
    let linkType: UInt32
    let close: () -> Void
    let captureFilter: (String) -> Void
    @State private var cache = PacketSectionsCache()

    var body: some View {
        let sections = cache.sections(for: row, linkType: linkType)
        let conversation = controller.snapshot.selectedConversation.flatMap { $0.id == row.conversation ? $0 : nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("패킷 \(row.id)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("상세 닫기 (목록 고정 풀기)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(sections) { section in
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { index, line in
                                GridRow {
                                    Text(index == 0 ? section.title : "").foregroundStyle(.secondary).fontWeight(.medium)
                                    Text(line.name).foregroundStyle(.secondary)
                                    Text(line.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    // 대화는 격자 밖 — 긴 주소가 이름 칸 폭을 키우지 않게
                    if let conversation {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("이 대화").foregroundStyle(.secondary).fontWeight(.medium)
                            Text("\(conversation.a) ↔ \(conversation.b)").textSelection(.enabled)
                            Text([conversation.label ?? conversation.transport, "\(conversation.packets.formatted()) 패킷",
                                  DiskFormat.bytes(Double(conversation.bytes)), conversation.handshake.map { "연결 \(CaptureText.ms($0))" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("이 대화만 보기") { controller.display = .conversation(row.conversation) }
                                if let filter = CaptureFilterAssist.fromConversation(conversation) {
                                    Button("이 대화만 캡처") { captureFilter(filter) }.help(filter)
                                }
                            }
                            .buttonStyle(CompactButtonStyle())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .cardSurface()
    }
}
