// 패킷 캡처 창의 패킷 목록 카드 (목록 검색 · 최근 것이 위).

import ServersCore
import SwiftUI

/// 목록: 거르기·검색은 컨트롤러 큐에서 끝난 행(최근 것이 위, 최대 5천)을 그리기만 한다
struct PacketListCard: View {
    @ObservedObject var capture: PacketCaptureController
    let rows: [CaptureRow]
    let frozen: Bool
    @Binding var selection: Int?
    let totalCount: Int
    let captureFilter: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("패킷").font(.caption).foregroundStyle(.secondary)
                TextField("목록 검색 — 주소 · 포트 · 프로토콜 · Info · 제조사 (빈칸으로 여러 낱말)", text: $capture.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                if capture.display != .all {
                    Button("전체 패킷 보기") { capture.display = .all }.buttonStyle(.borderless).font(.caption)
                }
                Spacer()
                if frozen {
                    Text("목록 고정됨").font(.caption).foregroundStyle(.secondary)
                    Button("이어서 보기") { selection = nil }.buttonStyle(.borderless).font(.caption)
                }
                Text("\(totalCount.formatted())개" + (totalCount > rows.count ? " (최근 \(rows.count.formatted()))" : ""))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            // 표의 행은 자리(0 = 맨 위)로 구분한다 — 새 패킷이 와도 행을 끼워 넣지 않고 내용만 바꾼다 (CaptureSlots).
            // 선택·오른쪽 클릭·스크롤은 표와 자리로 주고받고, 바깥(selection)은 패킷 번호 그대로
            let slots = CaptureSlots(rows)
            let slotSelection = Binding<Int?>(get: { slots.position(ofPacket: selection) }, set: { selection = slots.row(at: $0)?.id })
            ScrollViewReader { proxy in
                Table(slots, selection: slotSelection) {
                    TableColumn("No.") { Text("\($0.row.id)").monospacedDigit().foregroundStyle(.secondary) }.width(min: 40, ideal: 52, max: 70)
                    TableColumn("Time") { slot in cell(slot.row) { Text(CaptureText.clock(slot.row.raw.time)).monospacedDigit() } }.width(min: 90, ideal: 98, max: 110)
                    TableColumn("Source") { slot in cell(slot.row) { Text(endpointText(slot.row.decoded.source, slot.row.decoded.sourceMAC)).lineLimit(1).truncationMode(.middle) } }
                        .width(min: 90, ideal: 140, max: 240)
                    TableColumn("Destination") { slot in cell(slot.row) { Text(endpointText(slot.row.decoded.destination, slot.row.decoded.destinationMAC)).lineLimit(1).truncationMode(.middle) } }
                        .width(min: 90, ideal: 140, max: 240)
                    TableColumn("Protocol") { slot in cell(slot.row) { Text(slot.row.decoded.proto).lineLimit(1) } }.width(min: 76, ideal: 86, max: 110)
                    TableColumn("Length") { slot in cell(slot.row) { Text("\(slot.row.raw.originalLength)").monospacedDigit() } }.width(min: 58, ideal: 62, max: 76)
                    TableColumn("Info") { slot in
                        HStack(spacing: 6) {
                            if let issue = slot.row.issue { Text(issue.rawValue).foregroundStyle(CaptureText.tone(issue).color) }
                            cell(slot.row) { Text(slot.row.decoded.info).lineLimit(1).truncationMode(.tail) }
                        }
                    }
                    .width(min: 220)
                }
                .contextMenu(forSelectionType: Int.self) { positions in
                    // 오른쪽 클릭: 이 패킷에서 캡처 필터를 거꾸로 만든다
                    if let row = slots.row(at: positions.first) {
                        ForEach(Array(CaptureFilterAssist.fromPacket(row.decoded).enumerated()), id: \.offset) { _, item in
                            Button(item.title == item.filter ? "캡처 필터: \(item.filter)" : "\(item.title) — \(item.filter)") { captureFilter(item.filter) }
                        }
                        Divider()
                        Button("이 대화의 패킷만 보기") { capture.display = .conversation(row.conversation) }
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: frozen) { _, isFrozen in
                    // 고정할 때 고른 행이 보이게
                    if isFrozen, let position = slots.position(ofPacket: selection) { proxy.scrollTo(position, anchor: .center) }
                }
            }
            .overlay {
                if rows.isEmpty { Text(emptyText).foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .cardSurface()
    }

    private var emptyText: String {
        if capture.state == .starting { return "관리자 인증을 기다리는 중…" }
        if !capture.search.isEmpty { return "검색에 맞는 패킷이 없습니다." }
        return capture.display == .all ? "아직 받은 패킷이 없습니다." : "이 조건에 맞는 패킷이 없습니다."
    }

    /// IP 가 아닌 프레임(MAC 만)은 제조사 이름을 앞에 ("Realtek 60:15:6f:…")
    private func endpointText(_ value: String, _ mac: String?) -> String {
        guard let mac, value == mac, let vendor = AppModel.ouiTable?.vendor(mac: mac) else { return value }
        return "\(vendor.split(separator: " ").first.map(String.init) ?? vendor) \(mac)"
    }

    /// 내용 없는 ACK 는 옅게 — 데이터·문제 줄이 눈에 들어오게
    @ViewBuilder
    private func cell<Content: View>(_ row: CaptureRow, @ViewBuilder _ content: () -> Content) -> some View {
        content().foregroundStyle(row.isBareACK ? Color.secondary : Color.primary)
    }
}
