// 조회 결과 창(텍스트 줄들 — 로그·명령 오류). 터널·전송·서버 편집·액션 시트는 각자 파일 (TunnelSheets · TransferViews · ServerFormSheet · ActionsEditSheet).

import AppKit
import ServersCore
import SwiftUI

/// 조회 결과: 줄을 클릭하면 복사된다. 제목은 창 제목 줄에 (QueryResultWindow).
struct QueryResultView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int?

    var body: some View {
        if let result = model.queryResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if result.failed { Text("실패").foregroundStyle(StatusTone.bad.color) }
                    Spacer()
                    Text("\(result.lines.count)줄 · 클릭하면 복사").font(.caption).foregroundStyle(.secondary)
                }
                List(selection: $selection) {
                    ForEach(Array(result.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.body.monospaced())
                            .tag(index)
                            .onTapGesture { model.copy(line) }
                    }
                }
                .id(result.id)   // 새 결과면 고른 줄·스크롤을 처음으로
                HStack {
                    Button("모두 복사") { model.copy(result.lines.joined(separator: "\n")) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("닫기") { model.closeQueryResult() }.keyboardShortcut(.cancelAction).buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(16)
            .frame(minWidth: 560, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            .background(Palette.content)
        }
    }
}

/// 조회 결과를 보이는 독립 창 (하나만 — 새 결과는 같은 창에). 시트는 본창 가운데에 붙어 모서리를 끌면 양쪽이 같이 늘어났다 (2026-11-13 사용자 지적).
/// 크기·위치는 기억한다. 창을 닫으면 결과를 비우고, 결과가 비면 창을 닫는다.
@MainActor
final class QueryResultWindow: NSObject, NSWindowDelegate {
    static let shared = QueryResultWindow()
    private var window: NSWindow?
    private weak var model: AppModel?

    /// model.queryResult 가 바뀔 때마다 부른다 (ContentView)
    func sync(_ model: AppModel) {
        self.model = model
        guard let result = model.queryResult else { window?.close(); return }
        let window = self.window ?? make(model)
        window.title = result.title
        window.makeKeyAndOrderFront(nil)
    }

    private func make(_ model: AppModel) -> NSWindow {
        let hosting = NSHostingController(rootView: QueryResultView().environment(model).tint(Palette.neutralTint))
        hosting.sizingOptions = [.minSize]   // 최소 크기만 내용에서 — 그 위로는 자유롭게 늘린다
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 560))
        window.center()
        window.setFrameAutosaveName("QueryResult")   // 저장된 크기·위치가 있으면 그것으로
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if model?.queryResult != nil { model?.closeQueryResult() }
    }
}
