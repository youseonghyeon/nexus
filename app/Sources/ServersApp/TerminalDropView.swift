// 터미널에 끌어 놓기: libghostty 뷰는 끌기를 받지 않아 하위 클래스(TerminalViewState.makePlatformView)로 받는다.
// Finder 파일은 file URL, 스크린샷 썸네일·Photos·Mail 첨부는 file promise(놓은 뒤에 원본 앱이 파일을 써 줌)로 온다 —
// SwiftUI dropDestination(for: URL.self) 은 promise 를 받지 못해 썸네일 끌기가 반응이 없었다 (2026-10-19).
// 받은 파일은 onDrop(TerminalTab.onDropFiles → AppModel.dropIntoTerminal)으로 넘긴다.
// ⌘+클릭 링크도 여기서 먼저 받는다 (2026-11-15): 누른 칸에 http(s) 주소가 있으면 기본 브라우저로 열고 클릭을 Ghostty 에 넘기지 않는다 —
// 넘기면 마우스를 잡은 프로그램(Claude Code·tmux)으로 클릭이 가고, 프로그램이 꺾어 찍은 주소는 첫 줄만 열렸다. 판정은 ServersCore TerminalLink.

import AppKit
import GhosttyTerminal
import ServersCore

@MainActor
final class TerminalDropView: AppTerminalView {
    /// 놓은 파일들. 받았으면 true. promise 는 파일이 써진 뒤 부른다.
    var onDrop: (([URL]) -> Bool)?
    /// 지금 받을 수 있는가 (보이는 탭만 — 가려진 탭에 들어가지 않게)
    var canDrop: (() -> Bool)?

    /// 끌기 등록은 보이는 탭만 (TerminalPane.sync). 가려진 탭(opacity 0)도 본문 전체에 깔려 있어, 등록해 두면 AppKit 이 그 뷰를
    /// 끌기 대상으로 잡는다 — 맨 위 등록 뷰 하나만 묻고 거부해도 아래로 넘기지 않아, 서버 정보 화면의 업로드 영역에 놓기가 닿지 않았다 (2026-11-09).
    var acceptsDrops = false {
        didSet {
            guard acceptsDrops != oldValue else { return }
            if acceptsDrops {
                registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: ⌘+클릭 링크

    /// 링크 열기 (기본 브라우저)
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// ⌘ 로 누른 링크 — 같은 링크 위에서 떼면 연다 (다른 데로 끌고 가 떼면 취소)
    private var pressedLink: URL?

    override func mouseDown(with event: NSEvent) {
        pressedLink = link(at: event)
        guard pressedLink != nil else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedLink else { return super.mouseUp(with: event) }
        pressedLink = nil
        if link(at: event) == pressed { openLink(pressed) }
    }

    /// ⌘ 만 누른 클릭이 가리키는 링크. 없으면 nil — Ghostty 기본 동작(선택·OSC 8 링크·마우스 보고)으로 간다.
    private func link(at event: NSEvent) -> URL? {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              let screen = TerminalScreen.read(self) else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = TerminalLink.cell(x: point.x, y: bounds.height - point.y,
                                           paddingX: Double(TerminalScreen.paddingX), paddingY: Double(TerminalScreen.paddingY),
                                           cellWidth: screen.cellWidth, cellHeight: screen.cellHeight,
                                           columns: screen.columns, rows: screen.rows.count) else { return nil }
        return TerminalLink.url(rows: screen.rows, columns: screen.columns, row: cell.row, column: cell.column).flatMap(URL.init(string:))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }

    private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard canDrop?() ?? false, onDrop != nil else { return [] }
        let board = sender.draggingPasteboard
        let promised = board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        let files = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return promised || files ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let onDrop, canDrop?() ?? false else { return false }
        let board = sender.draggingPasteboard
        // 파일 URL 이 있으면 그것 (Finder). promise 를 함께 주는 앱도 URL 이 있으면 이미 디스크에 있는 파일이다.
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return onDrop(urls)
        }
        guard let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
              !receivers.isEmpty, let destination = Self.promiseDestination() else { return false }
        // 원본 앱이 파일을 다 쓰면 하나씩 불린다 (실패한 것은 빼고). 모두 끝나면 한 번에 넘긴다.
        let group = DispatchGroup()
        let lock = NSLock()
        var received: [URL] = []
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: Self.promiseQueue) { url, error in
                if error == nil {
                    lock.lock(); received.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            lock.lock(); let urls = received.sorted { $0.path < $1.path }; lock.unlock()
            MainActor.assumeIsolated { _ = urls.isEmpty ? false : onDrop(urls) }
        }
        return true
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// promise 파일을 받을 새 폴더 ($TMPDIR/nexus-paste/drop-<uuid>) — 원본 이름 그대로 받아 겹치지 않게 놓을 때마다 새로
    private static func promiseDestination() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-paste", isDirectory: true)
            .appendingPathComponent("drop-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ? url : nil
    }
}
