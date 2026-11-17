// 터미널 파일 넣기(이미지·문서): ⌘V(TerminalShortcuts)·끌어 놓기(TerminalDropView) → TerminalPaste.plan → 경로 입력 / 임시 저장 / 서버로 올린 뒤 입력.
// 올리는 동안은 TRANSFERS 목록에 보이고, 완료되면 그 탭에 서버 경로를 붙여 넣는다 (실패는 전송 실패 알림 그대로).

import AppKit
import Foundation
import GhosttyTerminal
import ServersCore

extension AppModel {
    /// ⌘V. 처리했으면 true — false 면 Ghostty 기본 붙여 넣기 (글자·SSH 탭에서 올리지 않는 파일 등).
    func pasteIntoTerminal(_ view: AppTerminalView) -> Bool {
        guard let tab = tabs.first(where: { $0.terminal?.attachedPlatformView === view }) else { return false }
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return insertFiles(into: tab, files: files.map(\.path), hasText: board.availableType(from: [.string]) != nil,
                           hasImageData: board.canReadObject(forClasses: [NSImage.self], options: nil))
    }

    /// 터미널에 끌어 놓은 파일. 받았으면 true.
    func dropIntoTerminal(_ tab: TerminalTab, urls: [URL]) -> Bool {
        guard insertFiles(into: tab, files: urls.filter(\.isFileURL).map(\.path), hasText: false, hasImageData: false) else { return false }
        tab.terminal?.requestFocus()   // Finder 에서 끌어 왔으면 클릭 없이 바로 이어 치게
        return true
    }

    private func insertFiles(into tab: TerminalTab, files: [String], hasText: Bool, hasImageData: Bool) -> Bool {
        guard tab.isAlive, tab.terminal != nil else { return false }
        let server = tab.server
        switch TerminalPaste.plan(remote: server != nil, files: files, hasText: hasText, hasImageData: hasImageData) {
        case .none:
            return false
        case let .pastePaths(paths):
            typeInto(tab, TerminalPaste.pasteText(paths))
        case let .upload(paths):
            guard let server else { return false }
            do {
                uploadAndPaste(tab, server: server, staged: try stagePasteFiles(paths))
            } catch {
                statusMessage = "파일을 임시 폴더에 복사하지 못했습니다: \(error.localizedDescription)"
            }
        case let .stageImage(upload):
            guard let file = stageClipboardImage() else {
                statusMessage = "클립보드 이미지를 저장하지 못했습니다. 파일로 저장해 끌어 놓으세요."
                return true
            }
            if upload, let server {
                uploadAndPaste(tab, server: server, staged: [file])
            } else {
                typeInto(tab, TerminalPaste.pasteText([file.path]))
            }
        }
        return true
    }

    /// 붙인 이미지·올릴 파일을 두는 이 Mac 임시 폴더 (시스템이 오래된 것을 지운다). 로컬 셸에 입력한 경로가 여기라 바로 지우지 않는다.
    private var pasteStagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nexus-paste", isDirectory: true)
    }

    /// 원래 이름들 → 임시 폴더 안 새 경로들 (TerminalPaste.stagedName). 같은 초에 또 붙여 이름이 겹치면 stamp 에 -2, -3 …
    private func stagingURLs(for originals: [String]) throws -> [URL] {
        let directory = pasteStagingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = TerminalPaste.stamp(Date())
        var attempt = 1
        while true {
            let stamp = attempt == 1 ? base : "\(base)-\(attempt)"
            let urls = originals.enumerated().map { index, name in
                directory.appendingPathComponent(TerminalPaste.stagedName(original: name, stamp: stamp, index: index, count: originals.count))
            }
            if !urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { return urls }
            attempt += 1
        }
    }

    /// 올릴 파일들을 서버에서 쓸 이름으로 임시 폴더에 복사 (scp 는 로컬 이름 그대로 올린다. APFS 는 복제라 바로 끝난다)
    private func stagePasteFiles(_ paths: [String]) throws -> [URL] {
        let targets = try stagingURLs(for: paths.map { ($0 as NSString).lastPathComponent })
        for (source, target) in zip(paths, targets) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
        }
        return targets
    }

    /// 클립보드의 경로 없는 이미지(스크린샷 등)를 png 로 저장. PNG 가 있으면 그 바이트, 없으면(TIFF·PDF 등) 변환. 못 하면 nil.
    private func stageClipboardImage() -> URL? {
        let board = NSPasteboard.general
        var data = board.data(forType: .png)
        if data == nil, let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        guard let data, let url = try? stagingURLs(for: ["image.png"]).first, (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// 서버 임시 폴더로 올리고, 끝나면 그 탭에 서버 경로를 입력한다. 실패·취소면 입력하지 않는다 (전송 항목·알림이 알린다).
    private func uploadAndPaste(_ tab: TerminalTab, server: Server, staged: [URL]) {
        let names = staged.map(\.lastPathComponent)
        let spec = TransferSpec(server: server, direction: .upload, localPaths: staged.map(\.path),
                                remotePath: TerminalPaste.remoteDirectory(type: server.type), bindInterface: bindInterface(for: server))
        startTransfer(spec) { [weak self, weak tab] session in
            guard let self, let tab, case .done = session.state else { return }
            Task {
                // Windows 는 C:\… 로 입력하려고 홈을 묻는다 — 방금 scp 가 연 공유 연결을 타 창이 뜨지 않는다
                let home = server.type == .windows ? await self.remoteHome(server) : nil
                let paths = names.map { TerminalPaste.remotePath(name: $0, type: server.type, home: home) }
                self.typeInto(tab, TerminalPaste.remotePasteText(paths))
            }
        }
    }

    /// 그 탭 터미널에 붙여 넣기 모드로 입력 (Enter 는 보내지 않는다). 탭이 닫혔으면 버린다.
    private func typeInto(_ tab: TerminalTab, _ text: String) {
        guard tab.isAlive, tabs.contains(where: { $0 === tab }) else { return }
        guard let terminal = tab.terminal, pasteDiscardingMarkedText(text, into: terminal) else {
            statusMessage = "터미널에 입력하지 못했습니다: \(text)"
            return
        }
    }

    /// 한글 조합 중인 글자를 버리고 붙여 넣기 모드로 입력한다 (명령 모음 typeSnippet · 파일 경로 typeInto 공통).
    /// 조합 글자가 남으면 붙인 글 뒤에 붙는다 ("uptimeㅎ"). 뷰가 없거나 못 붙였으면 false.
    func pasteDiscardingMarkedText(_ text: String, into terminal: TerminalViewState) -> Bool {
        guard let view = terminal.attachedPlatformView else { return false }
        if view.hasMarkedText() {
            view.unmarkText()
            view.inputContext?.discardMarkedText()
        }
        return view.paste(text: text)
    }
}
