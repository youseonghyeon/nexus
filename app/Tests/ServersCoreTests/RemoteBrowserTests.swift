import Foundation
@testable import ServersCore
import XCTest

final class RemoteBrowserTests: XCTestCase {
    /// 실제 sftp 출력 — 명령을 stdin 으로 준 것, -b 아님 (macOS sftp-server, 링크 수가 "?")
    private let macOutput = """
    sftp> cd "Desktop"
    sftp> pwd
    Remote working directory: /Users/me/Desktop
    sftp> ls -la
    drwxr-xr-x    ? me wheel         192 Sep 19 22:18 .
    drwxr-xr-x    ? me wheel          96 Sep 19 18:13 ..
    lrwxr-xr-x    ? me wheel          10 Sep 19 22:18 link.zip
    -rw-r--r--    ? me wheel           3 Sep 19 18:13 my report.zip
    -rw-r--r--    ? me wheel           3 Sep 19 18:13 report.zip
    drwxr-xr-x    ? me wheel          64 Sep 19 22:18 sub dir
    """

    func testParseListing() throws {
        let listing = try XCTUnwrap(RemoteBrowser.parse(macOutput).listing)
        XCTAssertEqual(listing.path, "/Users/me/Desktop")
        XCTAssertEqual(listing.entries.map(\.name), ["sub dir", "link.zip", "my report.zip", "report.zip"], "폴더 먼저, 그다음 이름순 · .·.. 제외")
        XCTAssertEqual(listing.entries[0].kind, .directory)
        XCTAssertEqual(listing.entries[1].kind, .link)
        XCTAssertEqual(listing.entries[2].kind, .file)
    }

    func testParseLinuxAndWindowsLongLines() {
        XCTAssertEqual(RemoteBrowser.parseLongLine("drwxr-xr-x    2 user  group      4096 Sep 19  2025 backup"), RemoteEntry(name: "backup", kind: .directory))
        XCTAssertEqual(RemoteBrowser.parseLongLine("-rw-r--r--    1 DESKTOP\\user DESKTOP\\None  1048576 Jan  5 09:30 data set.zip"),
                       RemoteEntry(name: "data set.zip", kind: .file), "Windows 소유자에 역슬래시·그룹에 공백 있어도 이름은 마지막")
        XCTAssertEqual(RemoteBrowser.parseLongLine("drwxr-xr-x    1 u g  0 Sep 19 10:00 C:"), RemoteEntry(name: "C:", kind: .drive))
        // Windows OpenSSH 실물 (2026-09-19 스크린샷): 권한 "*", 소유자·그룹 "-"
        XCTAssertEqual(RemoteBrowser.parseLongLine("drwx******    1 -        -                0 Apr 30 14:06 .android"), RemoteEntry(name: ".android", kind: .directory))
        XCTAssertEqual(RemoteBrowser.parseLongLine("-rw-******    1 -        -          1048576 Sep  7 22:13 my file.zip"), RemoteEntry(name: "my file.zip", kind: .file))
        XCTAssertEqual(RemoteBrowser.parseLongLine("/C:  /D:"), RemoteEntry(name: "/C:", kind: .drive), "Windows 루트의 드라이브 나열")
        // 로케일 없이 돌린 sftp 의 8진수 이스케이프 (실측) 도 되돌린다
        XCTAssertEqual(RemoteBrowser.parseLongLine("-rw-r--r--    ? me wheel           3 Sep 19 22:35 \\353\\263\\264\\352\\263\\240\\354\\204\\234.zip")?.name, "보고서.zip")
        XCTAssertEqual(RemoteBrowser.parseLongLine("drwxr-xr-x    ? me wheel          64 Sep 19 22:35 \\355\\225\\234\\352\\270\\200 \\355\\217\\264\\353\\215\\224")?.name, "한글 폴더")
        XCTAssertEqual(RemoteBrowser.unescapeOctal("a\\b"), "a\\b", "8진수 세 자리가 아니면 그대로")
        XCTAssertNil(RemoteBrowser.parseLongLine("sftp> ls -la"))
        XCTAssertNil(RemoteBrowser.parseLongLine("stat remote: No such file or directory"))
    }

    func testParseCdFailureAndUnparsed() {
        // -b 없이 돌리면 cd 가 실패해도 pwd·ls 가 이어진다 — cd 에코 다음 줄이 오류
        let failed = RemoteBrowser.parse("sftp> cd \"nope\"\nstat remote: No such file or directory\nsftp> pwd\nRemote working directory: /home/me\nsftp> ls -la\n")
        XCTAssertNil(failed.listing)
        XCTAssertEqual(failed.error, "stat remote: No such file or directory")
        // 모르는 형식의 줄은 unparsed 로 남겨 진단에 쓴다
        let odd = RemoteBrowser.parse("sftp> pwd\nRemote working directory: /C:/Users/u\nsftp> ls -la\nsomething weird here\n")
        XCTAssertEqual(odd.listing?.entries, [])
        XCTAssertEqual(odd.unparsed, ["something weird here"])
    }

    func testBatchScriptAndQuoting() {
        XCTAssertEqual(RemoteBrowser.batchScript(path: nil), "pwd\nls -la\n")
        XCTAssertEqual(RemoteBrowser.batchScript(path: "/D:/my backup"), "cd \"/D:/my backup\"\npwd\nls -la\n")
        XCTAssertEqual(RemoteBrowser.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    func testJoinAndParent() {
        let dir = RemoteEntry(name: "sub", kind: .directory)
        XCTAssertEqual(RemoteBrowser.join("/home/me", dir), "/home/me/sub")
        XCTAssertEqual(RemoteBrowser.join("/D:/", dir), "/D:/sub")
        XCTAssertEqual(RemoteBrowser.join("/", dir), "/sub")
        XCTAssertEqual(RemoteBrowser.join("/", RemoteEntry(name: "/D:", kind: .drive)), "/D:/")
        XCTAssertEqual(RemoteBrowser.join("/", RemoteEntry(name: "D:", kind: .drive)), "/D:/")
        XCTAssertEqual(RemoteBrowser.parent("/home/me/sub"), "/home/me")
        XCTAssertEqual(RemoteBrowser.parent("/home"), "/")
        XCTAssertEqual(RemoteBrowser.parent("/"), "/")
        XCTAssertEqual(RemoteBrowser.parent("/D:/backup"), "/D:/")
        XCTAssertEqual(RemoteBrowser.parent("/D:/"), "/", "드라이브 루트 위는 드라이브 목록")
        XCTAssertEqual(RemoteBrowser.parent("/D:"), "/")
    }

    func testNormalizeAndRelative() {
        XCTAssertEqual(RemoteBrowser.normalizePath(" Desktop\\a.zip ", windows: true), "Desktop/a.zip")
        XCTAssertEqual(RemoteBrowser.normalizePath("D:\\x\\y", windows: true), "D:/x/y")
        XCTAssertEqual(RemoteBrowser.normalizePath("a\\b", windows: false), "a\\b", "Linux 는 역슬래시가 이름의 일부일 수 있다")
        XCTAssertEqual(RemoteBrowser.child("/home/me", "download"), "/home/me/download")
        XCTAssertEqual(RemoteBrowser.child("/", "tmp"), "/tmp")
        XCTAssertEqual(RemoteBrowser.child("/C:/Users/u/", "Downloads"), "/C:/Users/u/Downloads")
    }

    func testArgumentsShareConnection() throws {
        let server = Server(key: "s", group: "g", network: .tailscale, type: .linux, ip: "192.0.2.1", user: "u", port: 2222,
                            check: .ssh, role: nil, env: nil, wolMac: nil)
        let args = RemoteBrowser.arguments(server: server, home: "/h")
        XCTAssertEqual(args.suffix(2), ["-q", "u@192.0.2.1"])
        XCTAssertFalse(args.contains("-b"), "-b 는 BatchMode=yes 라 비밀번호 팝업이 막힌다")
        XCTAssertTrue(args.contains("-P") && args.contains("2222"))
        XCTAssertTrue(args.contains("ControlPath=/h/.ssh/srv-%C"), "전송·SSH 탭과 같은 공유 연결")
        XCTAssertTrue(RemoteBrowser.arguments(server: server, home: "/h", bindInterface: "en10").contains("BindInterface=en10"))
        XCTAssertFalse(args.contains { $0.hasPrefix("BindInterface") })
    }
}
