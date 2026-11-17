// RemoteCommands.writableCommand: 업로드 대상 폴더에 쓸 수 있는지. Linux 명령은 이 Mac 의 sh 로 실제로 돌린다.

import Foundation
import XCTest
@testable import ServersCore

final class WriteAccessTests: XCTestCase {
    func testLinuxCommandRuns() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("write-\(UUID().uuidString)")
        let fm = FileManager.default
        for name in ["open", "it's dir", "-dash", "locked", "새 폴더"] {
            try fm.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("file.txt"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.appendingPathComponent("locked").path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("locked").path)
            try? fm.removeItem(at: home)
        }

        func check(_ path: String) throws -> RemoteCommands.WriteAccess? {
            let script = RemoteCommands.writableCommand(path: path, type: .linux)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script.command]
            p.currentDirectoryURL = home          // ssh 처럼 홈에서 시작
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe(), input = Pipe(); p.standardOutput = out; p.standardInput = input
            try p.run()
            input.fileHandleForWriting.write(Data(script.stdin!.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            return RemoteCommands.parseWriteAccess(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        XCTAssertEqual(try check(""), .writable, "빈 경로 = 홈")
        XCTAssertEqual(try check("open"), .writable, "홈 기준 상대 경로")
        XCTAssertEqual(try check(home.appendingPathComponent("open").path), .writable, "절대 경로")
        XCTAssertEqual(try check("~/it's dir"), .writable, "~ 와 작은따옴표")
        XCTAssertEqual(try check("-dash"), .writable, "- 로 시작하는 이름")
        XCTAssertEqual(try check("locked"), .readonly)
        XCTAssertEqual(try check("nope"), .missing)
        XCTAssertEqual(try check("file.txt"), .missing, "폴더가 아니면 없는 것으로")
        XCTAssertEqual(try check("새 폴더"), .writable, "한글 이름")
    }

    // 한글 경로가 NFD 로 바뀌지 않게: ssh 인자(command)는 ASCII 만, 경로는 stdin 에 쓴 NFC 그대로
    func testLinuxPathGoesThroughStdinAsNFC() {
        let path = "/mnt/새 폴더"
        for script in [RemoteCommands.writableCommand(path: path, type: .linux), RemoteCommands.sizeCommand(paths: [path], type: .linux)] {
            XCTAssertTrue(script.command.unicodeScalars.allSatisfy(\.isASCII), script.command)
            XCTAssertTrue(script.stdin!.utf8.elementsEqual(script.stdin!.precomposedStringWithCanonicalMapping.utf8))
            XCTAssertTrue(script.stdin!.contains("'/mnt/새 폴더'"))
        }
    }

    func testParseHome() {
        XCTAssertEqual(RemoteCommands.parseHome("/home/alice\n", type: .linux), "/home/alice")
        XCTAssertNil(RemoteCommands.parseHome("sh: pwd: not found", type: .linux))
        XCTAssertEqual(RemoteCommands.parseHome("C:\\Users\\bob\r\n", type: .windows), "/C:/Users/bob")
        XCTAssertNil(RemoteCommands.parseHome("", type: .windows))
    }

    func testWindowsScript() {
        let script = RemoteCommands.windowsWritableScript(path: "/D:/deploy/it's")
        XCTAssertTrue(script.hasPrefix("$p = 'D:/deploy/it''s';"), script)
        XCTAssertTrue(script.contains("catch { 'readonly'; return }; 'writable'; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue"),
                      "판정은 쓰기로만, 지우기 실패는 판정에 영향 없음")
        XCTAssertTrue(RemoteCommands.windowsWritableScript(path: "~").hasPrefix("$p = '.';"), "~ = 홈")
        XCTAssertTrue(RemoteCommands.windowsWritableScript(path: "~/Desktop").hasPrefix("$p = 'Desktop';"))
        XCTAssertTrue(RemoteCommands.windowsWritableScript(path: "").hasPrefix("$p = '.';"), "빈 경로 = 홈")
        XCTAssertTrue(RemoteCommands.writableCommand(path: "x", type: .windows).command.hasPrefix("powershell.exe "))
    }

    func testParse() {
        XCTAssertEqual(RemoteCommands.parseWriteAccess("writable\n"), .writable)
        XCTAssertEqual(RemoteCommands.parseWriteAccess("banner\r\nreadonly\r\n"), .readonly)
        XCTAssertEqual(RemoteCommands.parseWriteAccess("missing"), .missing)
        XCTAssertNil(RemoteCommands.parseWriteAccess(""))
        XCTAssertNil(RemoteCommands.parseWriteAccess("Permission denied"))
    }
}
