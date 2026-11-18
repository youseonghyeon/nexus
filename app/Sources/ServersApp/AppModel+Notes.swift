// 메모·로그인 (notes.bin — NoteVault): 탭 막대의 열쇠 버튼 팝오버(NotesPopover)와 브라우저 탭의 저장 띠·채우기(BrowserSession)가 쓴다.
// 서버마다 따로. 키체인을 못 읽었거나 파일을 못 풀면(notesError) 읽기·쓰기를 다 막는다 — 저장을 묻지도 않는다.

import AppKit
import Foundation
import ServersCore

extension AppModel {
    func loadNotes() {
        do {
            notes = try NoteVault.load(key: vaultKey)
            notesError = nil
        } catch {
            notes = NoteState()
            notesError = error as? ConfigError ?? ConfigError(problem: "메모·로그인을 읽지 못했습니다 (\(error.localizedDescription))", fix: "앱을 다시 실행하세요.", reference: NoteVault.defaultURL.path)
        }
    }

    /// 설정의 키 새로 만들기 창에 보이는 개수
    var noteCount: Int { notes.servers.values.reduce(0) { $0 + $1.count } }

    /// 키를 새로 만들었다: 옛 키로 잠근 파일을 지운다 (못 풀던 파일도 — 이제 풀 길이 없다)
    func clearNotes() {
        try? FileManager.default.removeItem(at: NoteVault.defaultURL)
        notes = NoteState()
        notesError = nil
    }

    /// 탭 막대 버튼. 버튼이 있는 곳(서버의 탭 막대)에서만 연다.
    func toggleNotes() {
        guard selectedServer != nil, !tabsForSelected.isEmpty else { notesShown = false; return }
        notesShown.toggle()
    }

    func closeNotes() {
        if notesShown { notesShown = false }
    }

    /// 추가·편집 저장. 넣을 수 없는 값이거나 막힌 상태면 false (편집기는 저장 버튼을 비활성으로 둔다).
    @discardableResult
    func saveNote(_ note: SecretNote, for serverKey: String) -> Bool {
        guard let clean = NoteVault.normalized(note) else { return false }
        return writeNotes(NoteVault.upsert(clean, serverKey: serverKey, in: notes))
    }

    func deleteNote(_ id: UUID, for serverKey: String) {
        writeNotes(NoteVault.remove(id: id, serverKey: serverKey, from: notes))
    }

    /// 바뀐 것이 없으면 쓰지 않는다. 막힌 상태(notesError)면 쓰지 않고 false.
    @discardableResult
    func writeNotes(_ next: NoteState) -> Bool {
        guard notesError == nil else { return false }
        guard next != notes else { return true }
        do {
            try NoteVault.save(next, key: vaultKey)
            notes = next
            return true
        } catch {
            statusMessage = "메모·로그인 저장 실패: \((error as? ConfigError)?.problem ?? error.localizedDescription)"
            return false
        }
    }

    // MARK: 브라우저 탭

    /// 보이는 탭이 브라우저 탭이면 그 세션
    var visibleBrowser: BrowserSession? { visibleTab?.browser }

    /// 브라우저 탭이 로그인을 잡았다 — 저장을 물을지 (막힌 상태면 묻지 않는다)
    func capturedLogin(address: URL, username: String, password: String, on server: Server) -> NoteVault.Capture {
        guard notesError == nil else { return .ignore }
        return NoteVault.capture(address: address.absoluteString, username: username, password: password, serverKey: server.key, in: notes)
    }

    /// 보이는 브라우저 탭에 채운다 (그 페이지의 로그인일 때만 — BrowserSession.fill 이 주소를 다시 본다)
    func fillLogin(_ note: SecretNote) {
        visibleBrowser?.fill(note)
    }

    // MARK: 클립보드

    /// 비밀 값 복사: 토스트에 값을 적지 않고, 클립보드 기록 앱이 남기지 않게 표시한다 (org.nspasteboard.ConcealedType)
    func copySecret(_ text: String, label: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        statusMessage = "복사됨: \(label)"
    }
}
