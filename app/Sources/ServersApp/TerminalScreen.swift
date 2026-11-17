// 터미널에 보이는 화면 글자 읽기 — ⌘+클릭 링크(TerminalDropView → ServersCore TerminalLink)가 쓴다.
// GhosttyTerminal 은 실행(.exec) 터미널의 화면 글자를 읽는 공개 API 가 없다(readViewportText 는 InMemory 세션만). 그래서
// TerminalSurface 가 안에 쥔 C 핸들(private surface)을 Mirror 로 꺼내 libghostty 의 ghostty_surface_read_text 를 직접 부른다.
// 라이브러리가 그 속성 이름을 바꾸면 read 가 nil 이 되고 ⌘+클릭은 Ghostty 기본 동작으로 돌아간다(오류 없이) —
// libghostty-spm 을 올린 뒤 링크가 다시 잘려 열리면 여기부터 본다.

import AppKit
import GhosttyKit
import GhosttyTerminal

@MainActor
enum TerminalScreen {
    /// 터미널 글자 둘레 여백 (TerminalTab 의 windowPadding 설정과 같은 값 — 점 → 칸 계산에 쓴다)
    static let paddingX = 8
    static let paddingY = 6

    struct Snapshot {
        /// 보이는 줄 (위 → 아래). 줄 끝 공백은 없다.
        let rows: [String]
        let columns: Int
        /// 한 칸 크기 (포인트)
        let cellWidth: Double
        let cellHeight: Double
    }

    static func read(_ view: AppTerminalView) -> Snapshot? {
        guard let wrapper = (view.delegate as? TerminalViewState)?.surface,
              let surface = Mirror(reflecting: wrapper).children.first(where: { $0.label == "surface" })?.value as? ghostty_surface_t else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0, size.width_px > 0, view.bounds.width > 0 else { return nil }
        let scale = Double(size.width_px) / Double(view.bounds.width)   // 픽셀 → 포인트 (Ghostty 가 실제로 그리는 배율)
        // 줄마다 따로 읽는다 — 화면 전체를 한 번에 읽으면 저절로 넘어간 줄이 앞줄에 붙어 줄 번호가 어긋난다
        var rows: [String] = []
        for row in 0..<UInt32(size.rows) {
            let range = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: row),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(size.columns) - 1, y: row),
                rectangle: false)
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, range, &text) else { return nil }
            defer { ghostty_surface_free_text(surface, &text) }
            // 길이로 읽는다 (NUL 로 끝난다는 보장이 없다)
            rows.append(text.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self) } ?? "")
        }
        return Snapshot(rows: rows, columns: Int(size.columns),
                        cellWidth: Double(size.cell_width_px) / scale, cellHeight: Double(size.cell_height_px) / scale)
    }
}
