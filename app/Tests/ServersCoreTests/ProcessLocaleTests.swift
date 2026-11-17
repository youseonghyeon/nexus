import Foundation
@testable import ServersCore
import XCTest

final class ProcessLocaleTests: XCTestCase {
    func testPreferredPicksInstalledSystemLocale() {
        let installed: Set<String> = ["/usr/share/locale/ko_KR.UTF-8", "/usr/share/locale/en_US.UTF-8"]
        let exists: (String) -> Bool = { installed.contains($0) }
        XCTAssertEqual(ProcessLocale.preferred(candidates: ["ko_KR"], localeDir: "/usr/share/locale", exists: exists), "ko_KR.UTF-8")
        XCTAssertEqual(ProcessLocale.preferred(candidates: ["ko-KR"], localeDir: "/usr/share/locale", exists: exists), "ko_KR.UTF-8", "preferredLanguages 표기")
        XCTAssertEqual(ProcessLocale.preferred(candidates: ["ko_KR@calendar=gregorian"], localeDir: "/usr/share/locale", exists: exists), "ko_KR.UTF-8", "Locale.identifier 의 @ 뒤는 뗀다")
        XCTAssertEqual(ProcessLocale.preferred(candidates: ["ja_JP", "ko"], localeDir: "/usr/share/locale", exists: exists), "en_US.UTF-8", "설치 안 됐거나 ll_CC 꼴이 아니면 en_US")
        XCTAssertEqual(ProcessLocale.preferred(candidates: [], localeDir: "/usr/share/locale", exists: exists), "en_US.UTF-8")
    }

    func testLangIsUTF8AndEnvironmentCarriesIt() {
        XCTAssertTrue(ProcessLocale.lang.hasSuffix(".UTF-8") || ProcessLocale.lang.hasSuffix(".utf8") || ProcessLocale.lang.hasSuffix("UTF-8"), ProcessLocale.lang)
        let env = ProcessLocale.environment(adding: ["X": "1"])
        XCTAssertEqual(env["X"], "1")
        XCTAssertFalse(env["LANG"]?.isEmpty ?? true, "자식 환경에는 LANG 이 반드시 있다")
    }

    /// 소수점이 쉼표인 언어(독일어 등)의 Mac: ps·zsh printf 가 "53,2" 로 찍으면 프로세스 목록·메모리 막대 파싱이 깨진다.
    /// 앱이 띄우는 명령은 숫자만 C 로 (실제 ps·zsh, 로컬 — 네트워크 없음)
    func testNumbersUseDotEvenInCommaLocales() async {
        XCTAssertEqual(ProcessLocale.environment()["LC_NUMERIC"], "C")
        let runner = ProcessRunner()
        let ps = await runner.run("/bin/ps", ["-o", "pcpu=", "-p", "\(getpid())"], stdin: nil, environment: ["LANG": "de_DE.UTF-8"], timeout: 10)
        XCTAssertTrue(ps.ok, ps.stderr)
        XCTAssertTrue(ps.stdout.contains("."), ps.stdout)
        XCTAssertFalse(ps.stdout.contains(","), ps.stdout)
        let printf = await runner.run("/bin/zsh", ["-c", "printf '%.1f' 1.5"], stdin: nil, environment: ["LANG": "de_DE.UTF-8"], timeout: 10)
        XCTAssertEqual(printf.stdout, "1.5")
        XCTAssertEqual(ProcessLocale.environment(base: ["LC_ALL": "de_DE.UTF-8"]).filter { $0.key.hasPrefix("L") },
                       ["LANG": "de_DE.UTF-8", "LC_NUMERIC": "C"], "터미널에서 LC_ALL 로 띄웠으면 LANG 으로 옮긴다 — LC_ALL 이 있으면 LC_NUMERIC 이 무시된다")
    }

    /// 실제 sftp 가 LANG 만으로 한글 이름을 그대로 찍는지 (로컬 sftp-server, 네트워크 없음). LC_ALL 땜질을 걷어낸 근거.
    func testSftpListsKoreanNamesWithLangOnly() throws {
        let sftpServer = "/usr/libexec/sftp-server"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sftpServer), "sftp-server 없음")
        let root = NSTemporaryDirectory() + "sftp-lang-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/한글 폴더", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        p.arguments = ["-q", "-D", sftpServer]
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessLocale.environment()
        env["LC_ALL"] = nil   // LANG 만으로 되는지 본다
        // 테스트 러너는 터미널의 LANG 을 물려받으므로, 앱이 GUI 로 떴을 때 고르는 값(ko_KR.UTF-8)을 직접 넣어 본다
        env["LANG"] = ProcessLocale.preferred(candidates: ["ko_KR"], localeDir: "/usr/share/locale")
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = output
        try p.run()
        input.fileHandleForWriting.write("ls -la\n".data(using: .utf8)!)
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("한글 폴더"), text)
        XCTAssertFalse(text.contains("\\355"), "8진수 이스케이프가 나오면 로케일이 안 먹은 것: \(text)")
    }
}
