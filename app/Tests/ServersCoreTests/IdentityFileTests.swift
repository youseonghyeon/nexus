// 서버별 키 파일: 개인키 판정·권한·저장, 그리고 모든 연결(SSH 탭·상태 확인·전송·파일 목록·터널)에 -i 가 붙는지.

import Foundation
import XCTest
@testable import ServersCore

final class IdentityFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = tempPath("identity")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ text: String, mode: Int = 0o600) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: 판정

    func testPrivateKeyHeaders() {
        XCTAssertTrue(IdentityFile.isPrivateKey("-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn"), "ssh-keygen (id_ed25519)")
        XCTAssertTrue(IdentityFile.isPrivateKey("-----BEGIN RSA PRIVATE KEY-----\nMIIE"), "AWS .pem")
        XCTAssertTrue(IdentityFile.isPrivateKey("-----BEGIN PRIVATE KEY-----\n"), "PKCS#8")
        XCTAssertTrue(IdentityFile.isPrivateKey("-----BEGIN ENCRYPTED PRIVATE KEY-----\r\n"), "암호 걸린 PKCS#8 · CRLF")
        XCTAssertTrue(IdentityFile.isPrivateKey("-----BEGIN EC PRIVATE KEY-----\n"))
        XCTAssertFalse(IdentityFile.isPrivateKey("ssh-ed25519 AAAAC3Nz me@mac"), ".pub 공개키")
        XCTAssertFalse(IdentityFile.isPrivateKey("PuTTY-User-Key-File-3: ssh-rsa\n"), "PuTTY .ppk — ssh 가 못 읽는다")
        XCTAssertFalse(IdentityFile.isPrivateKey("-----BEGIN CERTIFICATE-----\n"), "인증서 .pem")
        XCTAssertFalse(IdentityFile.isPrivateKey(""))
    }

    func testCheckFiles() throws {
        XCTAssertNil(IdentityFile.check(path: try file("aws.pem", "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n")))
        XCTAssertEqual(IdentityFile.check(path: try file("open.pem", "-----BEGIN RSA PRIVATE KEY-----\n", mode: 0o644)), .tooOpen)
        XCTAssertEqual(IdentityFile.check(path: try file("group.pem", "-----BEGIN RSA PRIVATE KEY-----\n", mode: 0o640)), .tooOpen)
        XCTAssertNil(IdentityFile.check(path: try file("ro.pem", "-----BEGIN RSA PRIVATE KEY-----\n", mode: 0o400)), "400 도 된다 (AWS 안내값)")
        XCTAssertEqual(IdentityFile.check(path: try file("id.pub", "ssh-ed25519 AAAA me\n")), .notPrivateKey)
        XCTAssertEqual(IdentityFile.check(path: try file("empty", "")), .notPrivateKey)
        XCTAssertEqual(IdentityFile.check(path: dir.path), .notPrivateKey, "폴더")
        XCTAssertEqual(IdentityFile.check(path: dir.appendingPathComponent("gone.pem").path), .missing)
    }

    func testRestrictMakesUsable() throws {
        let path = try file("open.pem", "-----BEGIN OPENSSH PRIVATE KEY-----\n", mode: 0o644)
        try IdentityFile.restrict(path: path)
        XCTAssertNil(IdentityFile.check(path: path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
    }

    // MARK: ~/.ssh 로 옮기기

    func testIsInSSHDirectory() {
        XCTAssertTrue(IdentityFile.isInSSHDirectory("/Users/me/.ssh/aws.pem", home: "/Users/me"))
        XCTAssertTrue(IdentityFile.isInSSHDirectory("/Users/me/.ssh/keys/aws.pem", home: "/Users/me"), "하위 폴더도")
        XCTAssertFalse(IdentityFile.isInSSHDirectory("/Users/me/Downloads/aws.pem", home: "/Users/me"))
        XCTAssertFalse(IdentityFile.isInSSHDirectory("/Users/me/.ssh-backup/aws.pem", home: "/Users/me"), "이름만 비슷한 폴더")
        XCTAssertFalse(IdentityFile.isInSSHDirectory("/Users/me/.ssh/../Downloads/aws.pem", home: "/Users/me"), "../ 로 빠져나감")
    }

    func testMoveIntoSSHCreatesDirAndRestricts() throws {
        let home = dir.appendingPathComponent("home").path
        let source = try file("aws.pem", "-----BEGIN RSA PRIVATE KEY-----\nA\n", mode: 0o644)
        let moved = try IdentityFile.moveIntoSSH(source, home: home)
        XCTAssertEqual(moved, home + "/.ssh/aws.pem")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source), "옮김 — 두 벌로 남지 않는다")
        XCTAssertNil(IdentityFile.check(path: moved), "600 으로 맞춰 바로 쓸 수 있다")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home + "/.ssh")[.posixPermissions] as? Int, 0o700)
    }

    func testMoveIntoSSHNameClash() throws {
        let home = dir.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try "-----BEGIN RSA PRIVATE KEY-----\nOLD\n".write(toFile: home + "/.ssh/aws.pem", atomically: true, encoding: .utf8)
        let different = try file("aws.pem", "-----BEGIN RSA PRIVATE KEY-----\nNEW\n")
        XCTAssertThrowsError(try IdentityFile.moveIntoSSH(different, home: home), "내용이 다르면 덮지 않는다")
        XCTAssertEqual(try String(contentsOfFile: home + "/.ssh/aws.pem", encoding: .utf8), "-----BEGIN RSA PRIVATE KEY-----\nOLD\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: different), "실패하면 원본도 그대로")

        try "-----BEGIN RSA PRIVATE KEY-----\nOLD\n".write(toFile: different, atomically: true, encoding: .utf8)
        XCTAssertEqual(try IdentityFile.moveIntoSSH(different, home: home), home + "/.ssh/aws.pem", "같은 내용이면 이미 있는 것을 쓴다")
    }

    // MARK: 저장

    func testStoreRoundTripAndBrokenFile() throws {
        let url = dir.appendingPathComponent("sub/identities.json")
        XCTAssertEqual(IdentityStore.load(from: url), [:], "없으면 빈 목록")
        try IdentityStore.save(["nexus": "/Users/me/.ssh/aws.pem"], to: url)
        XCTAssertEqual(IdentityStore.load(from: url), ["nexus": "/Users/me/.ssh/aws.pem"])
        try "{broken".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(IdentityStore.load(from: url), [:], "깨졌으면 빈 목록 — 접속은 지금처럼")
    }

    func testApplyingIdentities() throws {
        let config = try ServerConfigParser.parse(fixture)
        let applied = config.applyingIdentities(["nexus": "/k/aws.pem", "gone": "/k/x.pem"])
        XCTAssertEqual(applied.server("nexus")?.identityFile, "/k/aws.pem")
        XCTAssertNil(applied.server("win")?.identityFile)
        XCTAssertNil(applied.applyingIdentities([:]).server("nexus")?.identityFile, "지우면 다시 nil")
        XCTAssertEqual(applied.groups, config.groups)
        XCTAssertEqual(applied.servers.map(\.key), config.servers.map(\.key))
    }

    // MARK: 연결 인자

    func testIdentityOptionsOnlyWhenFileExists() throws {
        let path = try file("aws.pem", "-----BEGIN RSA PRIVATE KEY-----\n")
        XCTAssertEqual(ConnectPolicy.identityOptions(path), ["-i", path, "-o", "IdentitiesOnly=yes"])
        XCTAssertEqual(ConnectPolicy.identityOptions(nil), [])
        XCTAssertEqual(ConnectPolicy.identityOptions(""), [])
        XCTAssertEqual(ConnectPolicy.identityOptions(dir.appendingPathComponent("gone.pem").path), [],
                       "파일이 사라졌으면 붙이지 않는다 — IdentitiesOnly 로 기본 키까지 막히지 않게")
    }

    func testEveryConnectionCarriesIdentity() throws {
        let path = try file("aws.pem", "-----BEGIN RSA PRIVATE KEY-----\n")
        let config = try ServerConfigParser.parse(fixture).applyingIdentities(["nexus": path])
        let nexus = config.server("nexus")!
        func carries(_ args: [String], _ what: String) {
            guard let i = args.firstIndex(of: "-i") else { return XCTFail("\(what): -i 없음 \(args)") }
            XCTAssertEqual(args[i + 1], path, what)
            XCTAssertTrue(args.contains("IdentitiesOnly=yes"), what)
        }
        carries(SessionCommand.sshCommandLine(to: nexus, config: config, home: "/h").components(separatedBy: " ").map { $0.replacingOccurrences(of: "'", with: "") }, "SSH 탭")
        carries(TransferSpec(server: nexus, direction: .upload, localPaths: ["/tmp/a"], remotePath: "").arguments(home: "/h"), "전송")
        carries(RemoteBrowser.arguments(server: nexus, home: "/h"), "파일 목록")
        carries(SessionCommand.tunnelArguments(to: nexus, remotePort: 80, localPort: 8080, banner: "b"), "터널")
        carries(SessionCommand.socksArguments(via: nexus, localPort: 1080, banner: "b"), "SOCKS")
        carries(ConnectPolicy.sharedArguments(port: 22, bindInterface: nil, identity: nexus.identityFile), "상태 확인·원격 실행")
        // 키 파일이 없는 서버는 그대로
        XCTAssertFalse(RemoteBrowser.arguments(server: config.server("win")!, home: "/h").contains("-i"))
    }

    /// 상태 확인(check=ssh)도 그 키로 — 키 인증 서버가 BatchMode 확인에서 실패(빨강)로 보이지 않게
    func testStatusCheckUsesIdentity() async throws {
        let path = try file("aws.pem", "-----BEGIN RSA PRIVATE KEY-----\n")
        let config = try ServerConfigParser.parse(fixture).applyingIdentities(["nexus": path])
        let runner = FakeRunner()
        _ = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        let ssh = runner.calls.filter { $0.executable == "ssh" }
        XCTAssertEqual(ssh.count, 1)
        XCTAssertTrue(ssh[0].arguments.contains(path), "\(ssh[0].arguments)")
        XCTAssertTrue(ssh[0].arguments.contains("IdentitiesOnly=yes"))
    }
}
