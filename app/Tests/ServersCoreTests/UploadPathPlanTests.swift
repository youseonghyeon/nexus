// UploadPathPlan: 업로드 시트 원격 경로 칸 → 다음 동작 (기본 폴더를 절대 경로로 · 쓰기 확인 · 없는 기본 폴더면 홈).
// 기댓값은 옮기기 전 UploadPromptSheet 의 .task 분기를 따라 적었다. 다른 점은 하나: 홈으로 바꾸는 조건이
// "처음 값이 없었다(initialPath == nil)" 에서 "칸이 아직 자동으로 채운 값이다" 로 — 직접 친 없는 폴더를 바꾸지 않는다.

import XCTest
@testable import ServersCore

final class UploadPathPlanTests: XCTestCase {
    private struct Row {
        let note: String
        let field: String
        var windows = false
        var autoFilled = true
        let home: String?
        var access: RemoteCommands.WriteAccess? = nil
        let next: UploadPathPlan.Next
        /// 쓰기 확인에 넘긴 경로 (안 물었으면 빈 배열) · 홈을 물은 횟수
        let asked: [String]
        let homeCalls: Int
    }

    func testNext() async {
        let rows: [Row] = [
            Row(note: "기본 이름 + 홈 앎 → 절대 경로 (확인은 다음 차례)", field: "download", home: "/home/u",
                next: .fill("/home/u/download"), asked: [], homeCalls: 1),
            Row(note: "직접 친 기본 이름도 편다", field: "download", autoFilled: false, home: "/home/u",
                next: .fill("/home/u/download"), asked: [], homeCalls: 1),
            Row(note: "루트 홈은 '/' 를 겹치지 않는다", field: "download", home: "/",
                next: .fill("/download"), asked: [], homeCalls: 1),
            Row(note: "Windows 기본 이름", field: "Downloads", windows: true, home: "C:/Users/u",
                next: .fill("C:/Users/u/Downloads"), asked: [], homeCalls: 1),
            Row(note: "Linux 에서 Downloads 는 기본 이름이 아니다", field: "Downloads", home: "/home/u", access: .writable,
                next: .show(.writable), asked: ["Downloads"], homeCalls: 0),
            Row(note: "자동 채운 절대 기본 폴더가 없음 → 홈", field: "/home/u/download", home: "/home/u", access: .missing,
                next: .fill("/home/u"), asked: ["/home/u/download"], homeCalls: 1),
            Row(note: "같은 경로라도 직접 친 것이면 그대로 (옛 버그: 말없이 홈으로)", field: "/home/u/download", autoFilled: false,
                home: "/home/u", access: .missing, next: .show(.missing), asked: ["/home/u/download"], homeCalls: 0),
            Row(note: "홈을 모르고 기본 이름이 없음 → 빈 칸(= 홈)", field: "download", home: nil, access: .missing,
                next: .fill(""), asked: ["download"], homeCalls: 2),
            Row(note: "홈을 모르고 기본 이름에 쓸 수 있음", field: "download", home: nil, access: .writable,
                next: .show(.writable), asked: ["download"], homeCalls: 1),
            Row(note: "자동 채움이어도 기본 폴더가 아니면 그대로", field: "/srv/x", home: "/home/u", access: .missing,
                next: .show(.missing), asked: ["/srv/x"], homeCalls: 1),
            Row(note: "읽기 전용은 홈으로 바꾸지 않는다", field: "/home/u/download", home: "/home/u", access: .readonly,
                next: .show(.readonly), asked: ["/home/u/download"], homeCalls: 0),
            Row(note: "확인 실패(모름) → 막지 않는다", field: "/home/u/download", home: "/home/u", access: nil,
                next: .show(nil), asked: ["/home/u/download"], homeCalls: 0),
            Row(note: "빈 칸(홈) 확인", field: "", home: "/home/u", access: .writable,
                next: .show(.writable), asked: [""], homeCalls: 0),
            Row(note: "앞뒤 공백은 떼고 묻는다", field: "  /tmp  ", home: "/home/u", access: .writable,
                next: .show(.writable), asked: ["/tmp"], homeCalls: 0),
            Row(note: "Windows 역슬래시는 슬래시로 묻는다", field: "Desktop\\a", windows: true, home: "C:/Users/u", access: .writable,
                next: .show(.writable), asked: ["Desktop/a"], homeCalls: 0),
        ]
        for row in rows {
            var homeCalls = 0
            var asked: [String] = []
            let next = await UploadPathPlan.next(field: row.field, windows: row.windows, autoFilled: row.autoFilled,
                                                 home: { homeCalls += 1; return row.home },
                                                 access: { asked.append($0); return row.access })
            XCTAssertEqual(next, row.next, row.note)
            XCTAssertEqual(asked, row.asked, "asked: \(row.note)")
            XCTAssertEqual(homeCalls, row.homeCalls, "homeCalls: \(row.note)")
        }
    }

    func testDefaultName() {
        XCTAssertEqual(UploadPathPlan.defaultName(windows: false), "download")
        XCTAssertEqual(UploadPathPlan.defaultName(windows: true), "Downloads")
    }
}
