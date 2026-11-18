// TunnelDraft: 터널 포트 입력창의 칸 값 → 포트·특권 포트·원격 호스트·이름 문제·[열기] 가능 여부.
// 기댓값은 옮기기 전 TunnelPromptSheet 의 계산 속성(remotePort·localPort·localIsPrivileged·nameProblem·disabled 조건)을 하나씩 따라 적었다.

import XCTest
@testable import ServersCore

final class TunnelDraftTests: XCTestCase {
    private struct Row {
        let note: String
        var remote = "", local = "", host = ""
        var fixed: Int? = nil
        let remotePort: Int?, localPort: Int?
        var privileged = false
        var remoteHost: String? = "127.0.0.1"
        let canOpen: Bool
    }

    /// 이름을 쓰지 않는 모드(named=false) — 이름 문제는 늘 nil
    func testPortsAndOpen() {
        let rows: [Row] = [
            Row(note: "빈 칸 전부", remotePort: nil, localPort: nil, canOpen: false),
            Row(note: "원격만, 로컬 비움 → 같은 포트", remote: "6443", remotePort: 6443, localPort: 6443, canOpen: true),
            Row(note: "원격 앞뒤 공백은 뗀다 (옛 버그: 안내 없이 비활성)", remote: " 6443 ", remotePort: 6443, localPort: 6443, canOpen: true),
            Row(note: "원격 숫자 아님", remote: "abc", remotePort: nil, localPort: nil, canOpen: false),
            Row(note: "원격 0 은 범위 밖", remote: "0", remotePort: nil, localPort: nil, canOpen: false),
            Row(note: "원격 1 → 로컬 기본 8001", remote: "1", remotePort: 1, localPort: 8001, canOpen: true),
            Row(note: "원격 65535 끝값", remote: "65535", remotePort: 65535, localPort: 65535, canOpen: true),
            Row(note: "원격 65536 범위 밖", remote: "65536", remotePort: nil, localPort: nil, canOpen: false),
            Row(note: "특권 원격 443 → 로컬 기본 8443", remote: "443", remotePort: 443, localPort: 8443, canOpen: true),
            Row(note: "로컬 443 직접 → 특권이라 못 연다", remote: "443", local: "443", remotePort: 443, localPort: 443, privileged: true, canOpen: false),
            Row(note: "로컬 1023 은 특권", remote: "80", local: "1023", remotePort: 80, localPort: 1023, privileged: true, canOpen: false),
            Row(note: "로컬 1024 는 특권 아님", remote: "80", local: "1024", remotePort: 80, localPort: 1024, canOpen: true),
            Row(note: "로컬 범위 밖", remote: "80", local: "70000", remotePort: 80, localPort: nil, canOpen: false),
            Row(note: "로컬만 있고 원격 없음", local: "8080", remotePort: nil, localPort: 8080, canOpen: false),
            Row(note: "원격 호스트 IP", remote: "9090", host: "10.0.0.5", remotePort: 9090, localPort: 9090, remoteHost: "10.0.0.5", canOpen: true),
            Row(note: "원격 호스트에 포트를 붙이면 형식 오류", remote: "9090", host: "10.0.0.5:9090", remotePort: 9090, localPort: 9090, remoteHost: nil, canOpen: false),
            Row(note: "DB: 원격 칸 무시, 고정 포트", remote: "abc", fixed: 5432, remotePort: 5432, localPort: 5432, canOpen: true),
            Row(note: "DB: 원격 호스트 칸은 보지 않는다", host: "1.2.3.4:5", fixed: 5432, remotePort: 5432, localPort: 5432, remoteHost: nil, canOpen: true),
            Row(note: "DB: 특권 포트 22 → 로컬 기본 8022", fixed: 22, remotePort: 22, localPort: 8022, canOpen: true),
            Row(note: "DB: 로컬 특권 직접", local: "80", fixed: 5432, remotePort: 5432, localPort: 80, privileged: true, canOpen: false),
        ]
        for row in rows {
            let draft = TunnelDraft(remote: row.remote, local: row.local, host: row.host, named: false, fixedRemotePort: row.fixed)
            XCTAssertEqual(draft.remotePort, row.remotePort, "remotePort: \(row.note)")
            XCTAssertEqual(draft.localPort, row.localPort, "localPort: \(row.note)")
            XCTAssertEqual(draft.localIsPrivileged, row.privileged, "privileged: \(row.note)")
            XCTAssertEqual(draft.remoteHost, row.remoteHost, "remoteHost: \(row.note)")
            let problem = draft.nameProblem(defaultName: "was.acme") { _ in XCTFail("named=false 면 충돌을 묻지 않는다"); return nil }
            XCTAssertNil(problem, row.note)
            XCTAssertEqual(draft.canOpen(nameProblem: problem), row.canOpen, "canOpen: \(row.note)")
        }
    }

    /// 이름 문제가 있으면 포트가 맞아도 못 연다
    func testNameProblemBlocksOpen() {
        let draft = TunnelDraft(remote: "6443", named: true)
        XCTAssertTrue(draft.canOpen(nameProblem: nil))
        XCTAssertFalse(draft.canOpen(nameProblem: "다른 터널이 씁니다"))
    }

    /// 서버 주소 모드의 이름: 비우면 기본 이름, 공백은 뗀다. 형식이 틀리면 안내(충돌은 묻지 않음), 맞으면 충돌 안내를 그대로
    func testHostNameAndProblem() {
        struct NameRow { let note: String; let name: String; let hostName: String; let asked: String?; let problem: String? }
        let conflict = "이미 다른 터널이 씁니다"
        let rows: [NameRow] = [
            NameRow(note: "빈 칸 → 기본 이름", name: "", hostName: "was.acme", asked: "was.acme", problem: nil),
            NameRow(note: "공백만 → 기본 이름", name: "   ", hostName: "was.acme", asked: "was.acme", problem: nil),
            NameRow(note: "앞뒤 공백 뗌", name: "  api.acme ", hostName: "api.acme", asked: "api.acme", problem: nil),
            NameRow(note: "충돌", name: "taken.acme", hostName: "taken.acme", asked: "taken.acme", problem: conflict),
            NameRow(note: "밑줄은 형식 오류", name: "api_1.acme", hostName: "api_1.acme", asked: nil, problem: TunnelDraft.invalidNameMessage),
            NameRow(note: "빈 라벨", name: "api..acme", hostName: "api..acme", asked: nil, problem: TunnelDraft.invalidNameMessage),
            NameRow(note: "localhost 는 막는다", name: "localhost", hostName: "localhost", asked: nil, problem: TunnelDraft.invalidNameMessage),
        ]
        for row in rows {
            let draft = TunnelDraft(remote: "6443", name: row.name, named: true)
            XCTAssertEqual(draft.hostName(defaultName: "was.acme"), row.hostName, row.note)
            var asked: String?
            let problem = draft.nameProblem(defaultName: "was.acme") { name in
                asked = name
                return name == "taken.acme" ? conflict : nil
            }
            XCTAssertEqual(asked, row.asked, "asked: \(row.note)")
            XCTAssertEqual(problem, row.problem, "problem: \(row.note)")
        }
        XCTAssertEqual(TunnelDraft.invalidNameMessage, "이름은 영문·숫자·하이픈(-)·점(.)만 쓸 수 있습니다 (예: api.acme)", "화면 문구 그대로")
    }

    // MARK: HTTPS 전용 도메인 경고

    func testForcedSuffix() {
        XCTAssertEqual(HTTPSOnlyDomains.forcedSuffix(of: "acme.office"), "office")
        XCTAssertEqual(HTTPSOnlyDomains.forcedSuffix(of: " API.Acme.DEV. "), "dev", "대소문자·끝 점·공백 무시")
        XCTAssertEqual(HTTPSOnlyDomains.forcedSuffix(of: "dev"), "dev", "마디 하나짜리 이름도")
        for free in ["acme-office", "office.acme", "acme.lan", "acme.internal", "localhost", "acme.com", "devbox", "", "."] {
            XCTAssertNil(HTTPSOnlyDomains.forcedSuffix(of: free), free)
        }
        XCTAssertEqual(HTTPSOnlyDomains.topLevel.count, 52)
        XCTAssertTrue(HTTPSOnlyDomains.topLevel.allSatisfy { $0 == $0.lowercased() && !$0.contains(".") && !$0.isEmpty })
    }

    /// 서버 이름으로 여는 포트 터널에만 — 막지는 않는다
    func testBrowserWarningOnlyForNamedPortTunnelAndNeverBlocks() {
        let named = TunnelDraft(remote: "9090", named: true)
        XCTAssertEqual(named.browserWarning(defaultName: "acme.office"), ".office 로 끝나는 이름은 브라우저가 HTTPS 로만 엽니다 — 웹 화면이면 localhost 로 여세요.")
        XCTAssertTrue(named.canOpen(nameProblem: named.nameProblem(defaultName: "acme.office") { _ in nil }), "경고가 있어도 열 수 있다")
        XCTAssertNil(named.browserWarning(defaultName: "acme-office"))
        XCTAssertNil(TunnelDraft(remote: "9090", named: false).browserWarning(defaultName: "acme.office"), "localhost 로 열면 상관없다")
        XCTAssertNil(TunnelDraft(named: true, fixedRemotePort: 5432).browserWarning(defaultName: "acme.office"), "DB 터널은 웹이 아니다")
        // 이름 칸에 친 값이 기본 이름보다 먼저
        XCTAssertNil(TunnelDraft(remote: "9090", name: "grafana.lan", named: true).browserWarning(defaultName: "acme.office"))
        XCTAssertNotNil(TunnelDraft(remote: "9090", name: "grafana.app", named: true).browserWarning(defaultName: "acme"))
        XCTAssertNil(TunnelDraft(remote: "9090", name: "bad name.dev", named: true).browserWarning(defaultName: "acme"), "형식이 틀린 이름은 그쪽 안내만")
    }
}
