// TerminalPaste: 터미널 이미지·문서 넣기의 판정·이름·경로.

import Foundation
import XCTest
@testable import ServersCore

final class TerminalPasteTests: XCTestCase {
    func testPlanLocal() {
        XCTAssertEqual(TerminalPaste.plan(remote: false, files: ["/a/b c.pdf", "/x.png"], hasText: true, hasImageData: true),
                       .pastePaths(["/a/b c.pdf", "/x.png"]), "로컬은 어떤 파일이든 경로 — 파일이 글자보다 먼저 (Ghostty 순서)")
        XCTAssertEqual(TerminalPaste.plan(remote: false, files: [], hasText: false, hasImageData: true), .stageImage(upload: false))
        XCTAssertEqual(TerminalPaste.plan(remote: false, files: [], hasText: true, hasImageData: true), .none, "글자와 그림이 함께면(표 복사) 글자")
        XCTAssertEqual(TerminalPaste.plan(remote: false, files: [], hasText: true, hasImageData: false), .none)
        XCTAssertEqual(TerminalPaste.plan(remote: false, files: [], hasText: false, hasImageData: false), .none, "빈 클립보드")
    }

    func testPlanRemote() {
        XCTAssertEqual(TerminalPaste.plan(remote: true, files: ["/s/a.PNG", "/s/b.jpeg"], hasText: false, hasImageData: false),
                       .upload(["/s/a.PNG", "/s/b.jpeg"]), "확장자 대소문자 무관")
        XCTAssertEqual(TerminalPaste.plan(remote: true, files: ["/s/a.png", "/s/big.zip"], hasText: false, hasImageData: false), .none,
                       "올리지 않는 종류가 섞이면 전부 올리지 않는다")
        XCTAssertEqual(TerminalPaste.plan(remote: true, files: ["/s/보고서.PDF", "/s/a.png", "/s/notes.md", "/s/app.log"], hasText: false, hasImageData: false),
                       .upload(["/s/보고서.PDF", "/s/a.png", "/s/notes.md", "/s/app.log"]), "문서는 이미지와 함께 올린다")
        for ext in ["pdf", "txt", "md", "csv", "json", "log", "yaml", "yml", "xml", "html"] {
            XCTAssertTrue(TerminalPaste.isUploadable("/s/a.\(ext)"), ext)
        }
        for name in ["a.zip", "a.sh", "a.docx", "a.app", "folder", ".env"] {
            XCTAssertFalse(TerminalPaste.isUploadable("/s/\(name)"), name)
        }
        XCTAssertEqual(TerminalPaste.plan(remote: true, files: ["/s/noext"], hasText: false, hasImageData: false), .none)
        XCTAssertEqual(TerminalPaste.plan(remote: true, files: [], hasText: false, hasImageData: true), .stageImage(upload: true))
        XCTAssertEqual(TerminalPaste.plan(remote: true, files: [], hasText: true, hasImageData: true), .none)
    }

    func testShellEscapeMatchesGhostty() {
        XCTAssertEqual(TerminalPaste.shellEscape("/Users/me/스크린샷 2026-10-19 오전 10.31.59.png"),
                       "/Users/me/스크린샷\\ 2026-10-19\\ 오전\\ 10.31.59.png")
        XCTAssertEqual(TerminalPaste.shellEscape("/a/(1)[x]'q'$&!.png"), "/a/\\(1\\)\\[x\\]\\'q\\'\\$\\&\\!.png")
        XCTAssertEqual(TerminalPaste.pasteText(["/a b", "/c"]), "/a\\ b /c")
    }

    func testStagedName() {
        let stamp = "20261019-103159"
        XCTAssertEqual(TerminalPaste.stagedName(original: "image.png", stamp: stamp, index: 0, count: 1), "nexus-20261019-103159-image.png")
        XCTAssertEqual(TerminalPaste.stagedName(original: "스크린샷 2026-10-19 오전 10.31.59.PNG", stamp: stamp, index: 0, count: 1),
                       "nexus-20261019-103159-image.png", "영문이 없으면 image, 확장자는 소문자")
        XCTAssertEqual(TerminalPaste.stagedName(original: "My Shot (2).jpg", stamp: stamp, index: 1, count: 3),
                       "nexus-20261019-103159-2-My-Shot-2.jpg", "여러 개면 순번 — 공백·괄호는 - 하나로")
        XCTAssertEqual(TerminalPaste.stagedName(original: "-.png", stamp: stamp, index: 0, count: 1), "nexus-20261019-103159-image.png")
        XCTAssertEqual(TerminalPaste.stagedName(original: "noext", stamp: stamp, index: 0, count: 1), "nexus-20261019-103159-noext")
        XCTAssertEqual(TerminalPaste.stagedName(original: "보고서.PDF", stamp: stamp, index: 0, count: 1), "nexus-20261019-103159-file.pdf", "이미지 아닌 파일은 file")
        XCTAssertEqual(TerminalPaste.stagedName(original: "Q3 report.pdf", stamp: stamp, index: 0, count: 1), "nexus-20261019-103159-Q3-report.pdf")
        let date = ISO8601DateFormatter().date(from: "2026-10-19T01:31:59Z")!
        XCTAssertEqual(TerminalPaste.stamp(date, timeZone: TimeZone(identifier: "Asia/Seoul")!), stamp)
    }

    func testRemotePaths() {
        XCTAssertEqual(TerminalPaste.remotePath(name: "n.png", type: .linux, home: "/home/me"), "/tmp/n.png")
        XCTAssertEqual(TerminalPaste.remotePath(name: "n.png", type: .windows, home: "/C:/Users/me"), "C:\\Users\\me\\AppData\\Local\\Temp\\n.png")
        XCTAssertEqual(TerminalPaste.remotePath(name: "n.png", type: .windows, home: nil), "AppData\\Local\\Temp\\n.png", "홈을 모르면 홈 기준 상대 경로")
        XCTAssertEqual(TerminalPaste.remoteDirectory(type: .windows), "AppData/Local/Temp", "scp(SFTP) 대상은 / 구분")
        XCTAssertEqual(TerminalPaste.remotePasteText(["C:\\T\\a.png", "C:\\T\\b.png"]), "C:\\T\\a.png C:\\T\\b.png", "Windows \\ 는 escape 하지 않는다")
        let spaced = TerminalPaste.remotePath(name: "n.png", type: .windows, home: "/C:/Users/John Smith")
        XCTAssertEqual(TerminalPaste.remotePasteText([spaced, "/tmp/b.png"]), "\"C:\\Users\\John Smith\\AppData\\Local\\Temp\\n.png\" /tmp/b.png",
                       "공백 있는 홈은 따옴표로 — 인자 하나")
    }
}
