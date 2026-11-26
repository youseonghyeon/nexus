// 조회 결과 창(텍스트 줄들 — 로그·명령 오류). 터널·전송·서버 편집·액션 시트는 각자 파일 (TunnelSheets · TransferViews · ServerFormSheet · ActionsEditSheet).

import AppKit
import ServersCore
import SwiftUI

/// 조회 결과: 줄을 클릭하면 복사된다. 누르고 끌면 그 사이 줄들이 골라지고 놓으면 복사, Shift 누름은 앞서 누른 줄부터 (판정은 ServersCore LineSelection · LineHit).
/// 제목은 창 제목 줄에 (QueryResultWindow).
/// 줄들이 창을 좌우 끝까지 채우고(터미널처럼 — 바깥 여백 · 구분선 없음), 아래 얇은 띠에 줄 수 · 오류/경고 개수 · 모두 복사. 닫기는 창의 신호등 · esc.
/// 오류 · 경고 줄은 상태 색(왼쪽 띠 + 글자), debug 는 흐리게, info 와 레벨을 못 읽은 줄은 그대로 (판정은 ServersCore LogLevel).
struct QueryResultView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let result = model.queryResult {
                QueryResultBody(result: result)
                    .id(result.id)   // 새 결과면 스크롤 · 걸러 보기를 처음으로
                    // esc 로 닫기 (보이는 닫기 버튼은 없다)
                    .background(Button("") { model.closeQueryResult() }.keyboardShortcut(.cancelAction).opacity(0))
            }
        }
        // 틀은 조건 밖 — 결과가 비어 있을 때(닫는 순간)도 최소 크기가 남는다
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(Palette.content)
    }
}

private struct QueryResultBody: View {
    @Environment(AppModel.self) private var model
    let result: QueryResult
    /// 걸러 보기: 아래 띠의 오류 · 경고 개수를 누르면 그 레벨의 줄만 (다시 누르면 전부)
    @State private var filter: LogLevel?
    /// 고른 줄들 (누르고 끌기 · Shift 누름)
    @State private var selection = LineSelection()
    /// 그려진 줄들의 자리 (목록 안 좌표) — 마우스 자리를 줄로 바꾸는 데만 쓴다. 바뀌어도 다시 그릴 일이 없어 관찰하지 않는 상자에
    @State private var rows = RowFrames()
    /// 복사할 때마다 올린다 — 고른 줄들이 한 번 반짝인다
    @State private var copiedTick = 0
    /// 복사 알림 — 이 창의 오른쪽 아래에 잠깐 (본창의 토스트는 이 창을 보는 동안 눈에 안 들어왔다, 2026-11-26 사용자)
    @State private var notice: String?
    private static let space = "query-lines"

    private func shown(_ index: Int) -> Bool { filter == nil || result.levels[index] == filter }

    /// 복사하고 이 창에 알린다: 한 줄이면 그 글, 여러 줄이면 줄 수
    private func copy(_ text: String, count: Int) {
        model.copyQuietly(text)
        notice = count > 1 ? "\(count)줄 복사됨" : "복사됨: \(text.prefix(60))"
        copiedTick += 1
    }

    /// 누름 · 끌기 · 놓음을 한 제스처로 (거리 0 — 끌지 않은 누름도 여기로 온다). macOS 의 스크롤은 휠이라 겹치지 않는다
    private var selecting: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !selection.pressing {
                    guard let line = LineHit.line(atY: value.startLocation.y, rows: rows.list) else { return }
                    selection.press(line, extend: NSEvent.modifierFlags.contains(.shift))
                }
                if let line = LineHit.line(atY: value.location.y, rows: rows.list) { selection.drag(to: line) }
            }
            .onEnded { _ in
                guard let range = selection.release() else { return }
                copy(LineSelection.text(lines: result.lines, range: range, shown: shown), count: result.lines.indices.filter { range.contains($0) && shown($0) }.count)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(result.lines.enumerated()), id: \.offset) { index, line in
                        if shown(index) {
                            QueryResultLine(line: line, level: result.levels[index], selected: selection.contains(index))
                                .copyFlash(tick: copiedTick, active: selection.contains(index))
                                .modifier(RowFrameReport(line: index, rows: rows, space: Self.space))
                        }
                    }
                }
                .padding(.vertical, 6)
                .coordinateSpace(.named(Self.space))
                .gesture(selecting)
            }
            // 걸러 보기를 바꾸면 숨은 줄에 표시가 남는다 — 처음부터 (줄 자리는 줄마다 스스로 다시 알린다)
            .onChange(of: filter) { selection.clear() }
            .defaultScrollAnchor(result.startsAtEnd ? .bottom : .top)
            .overlay(alignment: .bottomTrailing) {
                if let notice {
                    StatusToast(message: notice, count: 1) { self.notice = nil }
                        .padding(12)
                        // 줄을 덮으니 본창(5초)보다 짧게. 또 복사하면 다시 센다
                        .task(id: copiedTick) {
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                            self.notice = nil
                        }
                }
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                if result.failed { Text("실패").foregroundStyle(StatusTone.bad.color) }
                Text("\(result.lines.count)줄").foregroundStyle(.secondary)
                LogLevelFilterButton(title: "Error", count: result.count(.error), tone: .bad, level: .error, filter: $filter)
                LogLevelFilterButton(title: "Warning", count: result.count(.warning), tone: .warn, level: .warning, filter: $filter)
                Spacer()
                Button("모두 복사") { copy(result.lines.joined(separator: "\n"), count: result.lines.count) }.buttonStyle(CompactButtonStyle())
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

/// 아래 띠의 "● Error 3": 누르면 그 레벨의 줄만, 다시 누르면 전부. 고른 것은 올라온 면. 0개면 자리 없음
private struct LogLevelFilterButton: View {
    let title: String
    let count: Int
    let tone: StatusTone
    let level: LogLevel
    @Binding var filter: LogLevel?

    var body: some View {
        if count > 0 {
            Button { filter = filter == level ? nil : level } label: {
                HStack(spacing: 4) {
                    Circle().fill(tone.color).frame(width: 6, height: 6)
                    Text("\(title) \(count)").foregroundStyle(filter == level ? .primary : .secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(filter == level ? Palette.control : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.smallRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 그려진 줄들의 자리 (줄 번호 → 목록 안 틀). 화면 밖으로 나간 줄은 뺀다
@MainActor
private final class RowFrames {
    var frames: [Int: CGRect] = [:]
    var list: [LineHit.Row] { frames.map { LineHit.Row(line: $0.key, minY: $0.value.minY, maxY: $0.value.maxY) } }
}

/// 줄이 제 자리를 알린다: 자리가 바뀔 때마다, 그리고 화면에 다시 들어올 때마다 (밖으로 나가면 뺀다).
/// LazyVStack 은 나간 줄을 버리기도 그대로 두기도 한다 — 그대로 둔 줄은 같은 자리로 돌아오면 자리 변화가 없어 다시 알리지 않으므로,
/// 들어올 때마다 바뀌는 번호(seen)를 값에 넣어 알리게 한다.
private struct RowFrameReport: ViewModifier {
    private struct Report: Equatable { let frame: CGRect; let seen: Int }
    let line: Int
    let rows: RowFrames
    let space: String
    @State private var seen = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Report.self) { Report(frame: $0.frame(in: .named(space)), seen: seen) } action: { rows.frames[line] = $0.frame }
            .onAppear { seen += 1 }
            .onDisappear { rows.frames[line] = nil }
    }
}

/// 조회 결과의 한 줄: 긴 줄은 접혀 내려가고, 올리면 옅은 면(누르면 복사된다는 표시), 고른 줄은 조금 더 진한 면, 줄 사이는 조금 띄워 접힌 줄과 새 줄을 가른다.
/// 오류 · 경고는 왼쪽 가는 띠와 글자를 상태 색으로 — 이어진 줄(스택 트레이스)의 띠는 한 줄로 붙는다.
private struct QueryResultLine: View {
    let line: String
    let level: LogLevel?
    let selected: Bool
    @State private var hovering = false

    private var tone: StatusTone? {
        switch level {
        case .error: .bad
        case .warning: .warn
        default: nil
        }
    }

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(tone?.color ?? (level == .debug ? Color.secondary : Color.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 3)
            .background(Color.primary.opacity(selected ? 0.12 : (hovering ? 0.06 : 0)))
            .overlay(alignment: .leading) {
                if let tone { Rectangle().fill(tone.color).frame(width: 2) }
            }
            .contentShape(Rectangle())
            .hoverEase(hovering)
            .onHover { hovering = $0 }
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
