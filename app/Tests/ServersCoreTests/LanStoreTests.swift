import Foundation
@testable import ServersCore
import XCTest

final class LanStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lan-store-\(UUID().uuidString)")
    }

    func testLoadOrSeedCreatesFileOnceThenPrefersFile() throws {
        let url = tempDir().appendingPathComponent("lan.json")
        XCTAssertNil(try LanStore.load(from: url), "파일이 없으면 nil")
        let seeded = try LanStore.loadOrSeed(service: "Acme Intranet", url: url)
        XCTAssertEqual(seeded, LanSettings(service: "Acme Intranet"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // 지정한 뒤에는 servers.conf 의 기본값이 바뀌어도 파일이 이긴다
        try LanStore.save(LanSettings(service: "Office LAN"), to: url)
        XCTAssertEqual(try LanStore.loadOrSeed(service: "Other", url: url), LanSettings(service: "Office LAN"))
    }

    /// 예전 파일(routes·activeService·orderAnchors)도 읽힌다 — 지정(service)만 쓴다
    func testOldFilesStillLoad() throws {
        let dir = tempDir(), url = dir.appendingPathComponent("lan.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"service":"Acme Intranet","activeService":"Acme Intranet","routes":[{"destination":"192.168.114.0","mask":"255.255.255.0"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LanStore.load(from: url), LanSettings(service: "Acme Intranet"))
        try #"{"service":"acme ethernet","activeService":"Old","orderAnchors":{"acme ethernet":"Wi-Fi"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LanStore.load(from: url), LanSettings(service: "acme ethernet"), "고른 것과 켜진 것이 달랐으면 고른 것")
    }

    func testCorruptFileThrowsInsteadOfSilentlyEmptying() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("lan.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LanStore.load(from: url))
        XCTAssertThrowsError(try LanStore.loadOrSeed(service: "X", url: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json", "깨진 파일을 덮어쓰지 않는다")
    }
}
