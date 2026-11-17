// PasswordVault: 암호화 저장·권한·변조 감지 · 키 만들기·옛 고정 키에서 옮기기·키 갱신.

import Foundation
import XCTest
@testable import ServersCore

/// 메모리 키 저장소. failRead/failWrite 로 키체인 실패를 흉내 낸다.
private final class MemoryKeyStore: VaultKeyStore {
    var data: Data?
    var failRead = false, failWrite = false
    var writes = 0
    func read() throws -> Data? {
        if failRead { throw KeychainError(status: -25300) }
        return data
    }
    func write(_ data: Data) throws {
        if failWrite { throw KeychainError(status: -25308) }
        self.data = data; writes += 1
    }
}

final class PasswordVaultTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)/Servers/passwords.bin")
    }

    func testRoundTripAndTamper() throws {
        let key = PasswordVault.resolveKey(store: MemoryKeyStore())
        let passwords = ["win": "p@ss w\"ord", "was": "한글비번"]
        let data = try PasswordVault.encrypt(passwords, key: key)
        XCTAssertNil(String(data: data, encoding: .utf8).flatMap { $0.contains("p@ss") ? $0 : nil }, "평문이 그대로 들어 있지 않다")
        XCTAssertEqual(PasswordVault.decrypt(data, key: key), passwords)
        var tampered = data; tampered[tampered.count - 1] ^= 0xFF
        XCTAssertNil(PasswordVault.decrypt(tampered, key: key), "변조되면 nil")
        XCTAssertNil(PasswordVault.decrypt(Data("garbage".utf8), key: key))
        XCTAssertNil(PasswordVault.decrypt(data, key: PasswordVault.legacy), "고정 키로는 못 푼다")
    }

    func testSaveLoadPermissionsAndEmptyRemoves() throws {
        let url = tempURL(), key = PasswordVault.resolveKey(store: MemoryKeyStore())
        XCTAssertEqual(PasswordVault.load(from: url, key: key), .init(passwords: [:], needsResave: false))
        try PasswordVault.save(["win": "secret"], to: url, key: key)
        XCTAssertEqual(PasswordVault.load(from: url, key: key).passwords, ["win": "secret"])
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        try PasswordVault.save([:], to: url, key: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "비면 파일을 지운다")
    }

    /// 키가 없으면 한 번 만들고, 다음엔 같은 키를 읽는다
    func testResolveCreatesOnceThenReuses() {
        let store = MemoryKeyStore()
        let first = PasswordVault.resolveKey(store: store)
        XCTAssertFalse(first.isFallback)
        XCTAssertEqual(store.data?.count, 32)
        let again = PasswordVault.resolveKey(store: store)
        XCTAssertEqual(store.writes, 1)
        let data = try? PasswordVault.encrypt(["a": "b"], key: first)
        XCTAssertEqual(data.flatMap { PasswordVault.decrypt($0, key: again) }, ["a": "b"])
    }

    /// 키체인을 못 쓰면 고정 키 — 비밀번호를 잃지 않는다
    func testKeychainFailureFallsBackToLegacy() {
        let unreadable = MemoryKeyStore(); unreadable.failRead = true
        XCTAssertTrue(PasswordVault.resolveKey(store: unreadable).isFallback)
        let unwritable = MemoryKeyStore(); unwritable.failWrite = true
        XCTAssertTrue(PasswordVault.resolveKey(store: unwritable).isFallback)
        let broken = MemoryKeyStore(); broken.data = Data([1, 2, 3])   // 길이가 틀린 항목은 새로 만든다
        XCTAssertFalse(PasswordVault.resolveKey(store: broken).isFallback)
        XCTAssertEqual(broken.data?.count, 32)
    }

    /// 키체인을 일시적으로 못 읽어 고정 키가 됐을 때 키체인 키 파일을 덮거나 지우지 않는다
    func testFallbackDoesNotOverwriteKeychainFile() throws {
        let url = tempURL()
        try PasswordVault.save(["win": "x"], to: url, key: PasswordVault.resolveKey(store: MemoryKeyStore()))
        XCTAssertThrowsError(try PasswordVault.save(["was": "y"], to: url, key: PasswordVault.legacy))
        XCTAssertThrowsError(try PasswordVault.save([:], to: url, key: PasswordVault.legacy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // 고정 키 파일·파일 없음은 그대로 쓴다
        try PasswordVault.save(["a": "b"], to: tempURL(), key: PasswordVault.legacy)
    }

    /// 옛 고정 키 파일 → 새 키로 읽히고 다시 쓰라고 알린다. 다시 쓴 뒤엔 새 키로만 풀린다
    func testMigratesLegacyFile() throws {
        let url = tempURL()
        try PasswordVault.save(["win": "old"], to: url, key: PasswordVault.legacy)
        let key = PasswordVault.resolveKey(store: MemoryKeyStore())
        let loaded = PasswordVault.load(from: url, key: key)
        XCTAssertEqual(loaded, .init(passwords: ["win": "old"], needsResave: true))

        try PasswordVault.save(loaded.passwords, to: url, key: key)
        XCTAssertEqual(PasswordVault.load(from: url, key: key), .init(passwords: ["win": "old"], needsResave: false))
        XCTAssertEqual(PasswordVault.load(from: url, key: PasswordVault.legacy).passwords, [:], "옮긴 뒤엔 고정 키로 못 푼다")
    }

    /// 다른 키로 쓴 파일(다른 Mac·키 분실)은 빈 목록, 파일은 남긴다
    func testForeignFileLoadsEmpty() throws {
        let url = tempURL()
        try PasswordVault.save(["win": "x"], to: url, key: PasswordVault.resolveKey(store: MemoryKeyStore()))
        XCTAssertEqual(PasswordVault.load(from: url, key: PasswordVault.resolveKey(store: MemoryKeyStore())), .init(passwords: [:], needsResave: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 키 갱신: 새 키 저장 → 파일 삭제. 저장에 실패하면 파일·키 그대로
    func testRotate() throws {
        let url = tempURL(), store = MemoryKeyStore()
        let old = PasswordVault.resolveKey(store: store)
        try PasswordVault.save(["win": "x"], to: url, key: old)

        store.failWrite = true
        XCTAssertThrowsError(try PasswordVault.rotateKey(store: store, url: url))
        XCTAssertEqual(PasswordVault.load(from: url, key: PasswordVault.resolveKey(store: store)).passwords, ["win": "x"])

        store.failWrite = false
        let fresh = try PasswordVault.rotateKey(store: store, url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let reread = PasswordVault.resolveKey(store: store)
        let data = try PasswordVault.encrypt(["a": "b"], key: fresh)
        XCTAssertEqual(PasswordVault.decrypt(data, key: reread), ["a": "b"])
        XCTAssertNil(PasswordVault.decrypt(data, key: old))
    }
}
