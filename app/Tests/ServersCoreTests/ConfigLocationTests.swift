import Foundation
@testable import ServersCore
import XCTest

final class ConfigLocationTests: XCTestCase {
    private func tempDir() -> String {
        tempPath("config-location").path
    }

    /// 저장소 servers.conf 의 머리 주석과 새 목록 템플릿(ConfigLocation.header)은 함께 고친다 (AGENTS.md) — 어긋나면 여기서 잡는다
    func testRepoServersConfHeaderMatchesTemplate() throws {
        func commentBlock(_ text: String) -> [Substring] {
            Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix { $0.hasPrefix("#") })
        }
        let repo = try String(contentsOf: TestPaths.repoRoot.appendingPathComponent("servers.conf"), encoding: .utf8)
        XCTAssertFalse(commentBlock(ConfigLocation.header).isEmpty)
        XCTAssertEqual(commentBlock(repo), commentBlock(ConfigLocation.header))
    }

    func testDefaultPathIsAppSupport() {
        XCTAssertTrue(ConfigLocation.defaultPath.hasSuffix("/Library/Application Support/Servers/servers.conf"))
        XCTAssertEqual(ConfigLocation.legacyPath, NSHomeDirectory() + "/.config/servers/servers.conf")
    }

    func testOverride() {
        XCTAssertEqual(ConfigLocation.override(arguments: ["Nexus", "--conf", "/x.conf"], environment: ["SERVERS_CONF": "/y.conf"]), "/x.conf")
        XCTAssertEqual(ConfigLocation.override(arguments: ["Nexus"], environment: ["SERVERS_CONF": "/y.conf"]), "/y.conf")
        XCTAssertNil(ConfigLocation.override(arguments: ["Nexus", "--conf"], environment: ["SERVERS_CONF": ""]))
    }

    /// 새 위치·옛 위치 모두 없으면 템플릿(형식 설명만, 서버 0개) — 폴더도 만든다. 빈 목록도 오류 없이 읽힌다
    func testCreatesTemplateWhenNothingExists() throws {
        let dir = tempDir(), path = dir + "/Servers/servers.conf"
        XCTAssertEqual(try ConfigLocation.prepare(path: path, legacy: dir + "/old/servers.conf"), .created)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), ConfigLocation.template)
        let config = try ServerConfigParser.load(path: path)
        XCTAssertTrue(config.servers.isEmpty, "기본 서버를 넣지 않는다")
        XCTAssertTrue(config.groups.isEmpty)
        XCTAssertNil(config.lan)
    }

    /// 옛 위치에 있으면 복사 — 원본은 남긴다
    func testCopiesLegacyOnce() throws {
        let dir = tempDir(), path = dir + "/Servers/servers.conf", legacy = dir + "/old/servers.conf"
        try FileManager.default.createDirectory(atPath: dir + "/old", withIntermediateDirectories: true)
        let text = "[a]\ngroup=g\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        try text.write(toFile: legacy, atomically: true, encoding: .utf8)

        XCTAssertEqual(try ConfigLocation.prepare(path: path, legacy: legacy), .copied(from: legacy))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy))

        // 이미 있으면 건드리지 않는다 (옛 파일이 바뀌어도)
        try "[b]\n".write(toFile: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ConfigLocation.prepare(path: path, legacy: legacy), .existing)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text)
    }

    func testCreateFailureIsConfigError() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "".write(toFile: dir + "/file", atomically: true, encoding: .utf8)   // 폴더 자리에 파일
        XCTAssertThrowsError(try ConfigLocation.prepare(path: dir + "/file/servers.conf", legacy: nil)) { error in
            XCTAssertTrue((error as? ConfigError)?.problem.contains("만들지 못했습니다") == true)
        }
    }
}
