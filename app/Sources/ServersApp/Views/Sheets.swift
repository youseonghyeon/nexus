// 조회 결과 창(텍스트 줄들 — 로그·명령 오류). 터널·전송·서버 편집·액션 시트는 각자 파일 (TunnelSheets · TransferViews · ServerFormSheet · ActionsEditSheet).

import AppKit
import ServersCore
import SwiftUI

/// 조회 결과: 줄을 클릭하면 복사된다. 제목은 창 제목 줄에 (QueryResultWindow).
/// 줄들이 창을 좌우 끝까지 채우고(터미널처럼 — 바깥 여백 · 구분선 없음), 아래 얇은 띠에 줄 수와 모두 복사. 닫기는 창의 신호등 · esc.
struct QueryResultView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let result = model.queryResult {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                                QueryResultLine(line: line) { model.copy(line) }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .defaultScrollAnchor(result.startsAtEnd ? .bottom : .top)
                    .id(result.id)   // 새 결과면 스크롤을 처음 자리로
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    HStack(spacing: 8) {
                        if result.failed { Text("실패").foregroundStyle(StatusTone.bad.color) }
                        Text("\(result.lines.count)줄").foregroundStyle(.secondary)
                        Spacer()
                        Button("모두 복사") { model.copy(result.lines.joined(separator: "\n")) }.buttonStyle(CompactButtonStyle())
                    }
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                // esc 로 닫기 (보이는 닫기 버튼은 없다)
                .background(Button("") { model.closeQueryResult() }.keyboardShortcut(.cancelAction).opacity(0))
            }
        }
        // 틀은 조건 밖 — 결과가 비어 있을 때(닫는 순간)도 최소 크기가 남는다
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(Palette.content)
    }
}

/// 조회 결과의 한 줄: 긴 줄은 접혀 내려가고, 올리면 옅은 면(누르면 복사된다는 표시), 줄 사이는 조금 띄워 접힌 줄과 새 줄을 가른다.
private struct QueryResultLine: View {
    let line: String
    let copy: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 3)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: copy)
    }
}

/// 조회 결과를 보이는 독립 창 (하나만 — 새 결과는 같은 창에). 시트는 본창 가운데에 붙어 모서리를 끌면 양쪽이 같이 늘어났다 (2026-11-13 사용자 지적).
/// 열 때마다 같은 크기(openSize)로 뜨고, 떠 있는 동안은 끌어 바꿀 수 있다 — 크기는 기억하지 않고 위치만 (2026-11-25 사용자.
/// 크기를 기억하던 때는 0×32 가 저장돼 늘 최소 크기로 떴다). 창을 닫으면 결과를 비우고, 결과가 비면 창을 닫는다.
@MainActor
final class QueryResultWindow: NSObject, NSWindowDelegate {
    static let shared = QueryResultWindow()
    private static let openSize = NSSize(width: 900, height: 560)
    private var window: NSWindow?
    private weak var model: AppModel?

    /// model.queryResult 가 바뀔 때마다 부른다 (ContentView)
    func sync(_ model: AppModel) {
        self.model = model
        guard let result = model.queryResult else { window?.close(); return }
        let window = self.window ?? make(model)
        window.title = result.title
        if !window.isVisible { window.setContentSize(Self.openSize) }   // 새로 열 때만 — 떠 있는 창에 새 결과가 오면 바꿔 둔 크기 그대로
        window.makeKeyAndOrderFront(nil)
    }

    private func make(_ model: AppModel) -> NSWindow {
        let hosting = NSHostingController(rootView: QueryResultView().environment(model).tint(Palette.neutralTint))
        hosting.sizingOptions = [.minSize]   // 최소 크기만 내용에서 — 그 위로는 자유롭게 늘린다
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.openSize)   // 가운데 놓기 전에 — 저장된 위치가 없는 첫 실행의 자리
        window.center()
        window.setFrameAutosaveName("QueryResultPosition")   // 저장된 위치가 있으면 그것으로 (크기는 sync 가 열 때마다 잡는다)
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if model?.queryResult != nil { model?.closeQueryResult() }
    }
}
