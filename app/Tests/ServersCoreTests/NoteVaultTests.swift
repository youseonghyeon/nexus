// NoteVault: 암호화 저장·권한 · 키체인 실패(고정 키)·못 푸는 파일은 막기 · 주소 판정 · 목록 바꾸기 · 브라우저에서 잡은 로그인 판정.

import Foundation
import XCTest
@testable import ServersCore

final class NoteVaultTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)/Servers/notes.bin")
    }
    private var key: VaultKey { PasswordVault.resolveKey(store: MemoryKeyStore()) }

    private let login = SecretNote(kind: .login, site: "http://localhost:3000", username: "admin", password: "s3cret 한글")
    private let memo = SecretNote(kind: .memo, title: "배포", body: "1. 빌드\n2. 올리기")

    // MARK: 저장

    func testRoundTripPermissionsAndNoPlaintext() throws {
        let url = tempURL(), key = key
        let state = NoteState(servers: ["web": [login, memo]])
        try NoteVault.save(state, to: url, key: key)
        let raw = try Data(contentsOf: url)
        for secret in ["s3cret", "admin", "localhost", "빌드"] {
            XCTAssertNil(raw.range(of: Data(secret.utf8)), "\(secret) 가 평문으로 들어 있지 않다")
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try NoteVault.load(from: url, key: key), state)
    }

    func testMissingFileIsEmptyAndEmptyStateRemovesFile() throws {
        let url = tempURL(), key = key
        XCTAssertEqual(try NoteVault.load(from: url, key: key), NoteState())
        try NoteVault.save(NoteState(servers: ["web": [memo]]), to: url, key: key)
        try NoteVault.save(NoteState(servers: ["web": []]), to: url, key: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// 키체인을 못 읽으면(고정 키) 읽지도 쓰지도 않는다 — 파일이 있든 없든, 그 파일은 그대로 남는다
    func testFallbackKeyBlocksReadAndWrite() throws {
        let url = tempURL(), key = key
        XCTAssertThrowsError(try NoteVault.load(from: url, key: PasswordVault.legacy), "파일이 없어도 막는다 — 빈 목록으로 보이면 새로 써서 덮는다")
        XCTAssertThrowsError(try NoteVault.save(NoteState(servers: ["web": [memo]]), to: url, key: PasswordVault.legacy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try NoteVault.save(NoteState(servers: ["web": [memo]]), to: url, key: key)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try NoteVault.load(from: url, key: PasswordVault.legacy)) { error in
            XCTAssertTrue((error as? ConfigError)?.problem.contains("키체인") ?? false)
        }
        XCTAssertThrowsError(try NoteVault.save(NoteState(), to: url, key: PasswordVault.legacy), "빈 상태로도 지우지 않는다")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testOtherKeyTamperedOrGarbageThrows() throws {
        let url = tempURL(), key = key
        try NoteVault.save(NoteState(servers: ["web": [login]]), to: url, key: key)
        XCTAssertThrowsError(try NoteVault.load(from: url, key: self.key), "다른 키")
        var data = try Data(contentsOf: url); data[data.count - 1] ^= 0xFF
        try data.write(to: url)
        XCTAssertThrowsError(try NoteVault.load(from: url, key: key), "변조")
        try Data("garbage".utf8).write(to: url)
        XCTAssertThrowsError(try NoteVault.load(from: url, key: key))
    }

    func testDecodesNoteWithMissingFields() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"memo","body":"x"}"#
        let note = try JSONDecoder().decode(SecretNote.self, from: Data(json.utf8))
        XCTAssertEqual(note.body, "x"); XCTAssertEqual(note.title, ""); XCTAssertFalse(note.concealed)
    }

    // MARK: 주소

    func testSite() {
        XCTAssertEqual(NoteVault.site(of: "http://Localhost:3000/login?next=/#top"), "http://localhost:3000")
        XCTAssertEqual(NoteVault.site(of: "https://A.example:443/"), "https://a.example")
        XCTAssertEqual(NoteVault.site(of: "http://192.0.2.10:80/admin"), "http://192.0.2.10")
        XCTAssertEqual(NoteVault.site(of: "https://a.example:8443"), "https://a.example:8443")
        XCTAssertEqual(NoteVault.site(of: " localhost:3000 "), "http://localhost:3000", "스킴 없이 친 것은 http")
        XCTAssertEqual(NoteVault.site(of: "http://[2001:db8::1]:8080/x"), "http://[2001:db8::1]:8080")
        XCTAssertNotEqual(NoteVault.site(of: "http://a.example"), NoteVault.site(of: "https://a.example"), "스킴이 다르면 다른 곳")
        for bad in ["", "about:blank", "file:///etc/passwd", "data:text/html,x", "http://", "ftp://a.example"] {
            XCTAssertNil(NoteVault.site(of: bad), bad)
        }
    }

    // MARK: 목록

    func testNormalized() {
        let cleaned = NoteVault.normalized(SecretNote(kind: .login, title: " 관리자 ", body: "남은 글", concealed: true, site: "LOCALHOST:3000/login", username: " admin ", password: " pw "))
        XCTAssertEqual(cleaned?.site, "http://localhost:3000")
        XCTAssertEqual(cleaned?.username, "admin")
        XCTAssertEqual(cleaned?.password, " pw ", "비밀번호는 다듬지 않는다")
        XCTAssertEqual(cleaned?.title, "관리자")
        XCTAssertEqual(cleaned?.body, ""); XCTAssertEqual(cleaned?.concealed, false)
        XCTAssertNil(NoteVault.normalized(SecretNote(kind: .login, site: "about:blank", username: "a", password: "b")))
        XCTAssertNil(NoteVault.normalized(SecretNote(kind: .login, site: "localhost", username: " ", password: "")))
        XCTAssertNotNil(NoteVault.normalized(SecretNote(kind: .login, site: "localhost", password: "pw")), "ID 없는 로그인")

        let note = NoteVault.normalized(SecretNote(kind: .memo, title: " t ", body: "\n a\nb \n", site: "x", username: "u", password: "p"))
        XCTAssertEqual(note?.body, "a\nb"); XCTAssertEqual(note?.title, "t")
        XCTAssertEqual([note?.site, note?.username, note?.password], ["", "", ""])
        XCTAssertNil(NoteVault.normalized(SecretNote(kind: .memo, title: " ", body: "\n")))
        XCTAssertNotNil(NoteVault.normalized(SecretNote(kind: .memo, title: "제목만")))
    }

    func testDisplayTitle() {
        XCTAssertEqual(memo.displayTitle, "배포")
        XCTAssertEqual(SecretNote(kind: .memo, body: "첫 줄\r\n둘째").displayTitle, "첫 줄")
        XCTAssertEqual(SecretNote(kind: .memo, body: "비밀", concealed: true).displayTitle, "메모", "가린 본문은 제목으로 새지 않는다")
        XCTAssertEqual(login.displayTitle, "admin")
        XCTAssertEqual(SecretNote(kind: .login, site: "http://localhost:3000", password: "p").displayTitle, "localhost:3000")
        XCTAssertEqual(SecretNote(kind: .login, title: "Grafana", site: "http://localhost:3000", username: "admin").displayTitle, "Grafana")
    }

    func testUpsertRemoveAndServerMoves() {
        var state = NoteVault.upsert(login, serverKey: "web", in: NoteState())
        state = NoteVault.upsert(memo, serverKey: "web", in: state)
        var edited = login; edited.password = "new"
        state = NoteVault.upsert(edited, serverKey: "web", in: state)
        XCTAssertEqual(NoteVault.notes(for: "web", in: state), [edited, memo], "같은 id 는 제자리에서")
        XCTAssertEqual(NoteVault.notes(for: "db", in: state), [], "서버마다 따로")
        XCTAssertEqual(NoteVault.remove(id: memo.id, serverKey: "db", from: state), state, "다른 서버의 것은 못 지운다")

        let renamed = NoteVault.renamingServer(from: "web", to: "www", in: state)
        XCTAssertEqual(renamed.servers, ["www": [edited, memo]])
        XCTAssertEqual(NoteVault.renamingServer(from: "web", to: "web", in: state), state)
        let stale = NoteState(servers: ["www": [memo]])
        XCTAssertEqual(NoteVault.renamingServer(from: "web", to: "www", in: stale).servers, [:], "옛 것이 없으면 새 이름에 남은 값도 지운다")

        state = NoteVault.remove(id: edited.id, serverKey: "web", from: state)
        state = NoteVault.remove(id: memo.id, serverKey: "web", from: state)
        XCTAssertEqual(state.servers, [:], "마지막 것을 빼면 서버 칸도 없다")
        XCTAssertEqual(NoteVault.removingServer("web", from: NoteState(servers: ["web": [memo], "db": [login]])).servers, ["db": [login]])
    }

    func testOrderedAndFits() {
        let other = SecretNote(kind: .login, site: "http://localhost:9090", username: "root", password: "x")
        let notes = [memo, other, login]
        XCTAssertEqual(NoteVault.ordered(notes, site: "http://localhost:3000"), [login, memo, other], "보는 페이지의 로그인이 맨 위")
        XCTAssertEqual(NoteVault.ordered(notes, site: nil), notes)
        XCTAssertTrue(NoteVault.fits(login, site: "http://localhost:3000"))
        XCTAssertFalse(NoteVault.fits(login, site: "https://localhost:3000"), "스킴이 다르면 채우지 않는다")
        XCTAssertFalse(NoteVault.fits(login, site: "http://localhost:3001"))
        XCTAssertFalse(NoteVault.fits(login, site: nil))
        XCTAssertFalse(NoteVault.fits(SecretNote(kind: .memo, site: "http://localhost:3000"), site: "http://localhost:3000"))
    }

    func testMatchesNeverSearchesSecrets() {
        XCTAssertTrue(NoteVault.matches(login, ""))
        XCTAssertTrue(NoteVault.matches(login, "ADMIN"))
        XCTAssertTrue(NoteVault.matches(login, "3000"))
        XCTAssertFalse(NoteVault.matches(login, "s3cret"), "비밀번호로는 찾지 않는다 — 치는 글자로 비밀번호를 맞혀 볼 수 있다")
        XCTAssertTrue(NoteVault.matches(memo, "올리기"))
        var hidden = memo; hidden.concealed = true
        XCTAssertFalse(NoteVault.matches(hidden, "올리기"), "가린 본문도")
        XCTAssertTrue(NoteVault.matches(hidden, "배포"))
    }

    // MARK: 잡은 로그인

    func testCapture() {
        let state = NoteState(servers: ["web": [login, memo]])
        func capture(_ address: String, _ user: String, _ password: String, on server: String = "web") -> NoteVault.Capture {
            NoteVault.capture(address: address, username: user, password: password, serverKey: server, in: state)
        }
        XCTAssertEqual(capture("http://localhost:3000/login", "admin", "s3cret 한글"), .ignore, "이미 같은 것")
        guard case let .update(changed) = capture("http://localhost:3000/login", " admin ", "new") else { return XCTFail("같은 주소·같은 ID 는 바꾸기") }
        XCTAssertEqual(changed.id, login.id); XCTAssertEqual(changed.password, "new")
        guard case let .add(fresh) = capture("http://localhost:3000/login", "viewer", "pw") else { return XCTFail("다른 ID 는 새로") }
        XCTAssertEqual([fresh.site, fresh.username, fresh.password], ["http://localhost:3000", "viewer", "pw"])
        XCTAssertEqual(fresh.kind, .login)
        if case .add = capture("http://localhost:3001/", "admin", "s3cret 한글") {} else { XCTFail("다른 포트는 다른 곳") }
        if case .add = capture("http://localhost:3000/", "admin", "s3cret 한글", on: "db") {} else { XCTFail("다른 서버는 따로") }
        XCTAssertEqual(capture("http://localhost:3000/", "admin", ""), .ignore, "빈 비밀번호")
        XCTAssertEqual(capture("about:blank", "admin", "pw"), .ignore, "웹 주소가 아니다")
        XCTAssertEqual(capture("http://localhost:3000/", "admin", String(repeating: "x", count: 1001)), .ignore, "너무 긴 값")
        XCTAssertEqual(capture("http://localhost:3000/", String(repeating: "x", count: 1001), "pw"), .ignore)
    }

    func testConfirms() {
        let at = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(NoteVault.confirms(capturedAt: at, now: at.addingTimeInterval(2), passwordFieldVisible: false))
        XCTAssertFalse(NoteVault.confirms(capturedAt: at, now: at.addingTimeInterval(2), passwordFieldVisible: true), "칸이 다시 떴다 — 로그인 실패")
        XCTAssertTrue(NoteVault.confirms(capturedAt: at, now: at.addingTimeInterval(60), passwordFieldVisible: false))
        XCTAssertFalse(NoteVault.confirms(capturedAt: at, now: at.addingTimeInterval(61), passwordFieldVisible: false), "오래된 것은 묻지 않는다")
        XCTAssertFalse(NoteVault.confirms(capturedAt: at, now: at.addingTimeInterval(-1), passwordFieldVisible: false))
    }
}
