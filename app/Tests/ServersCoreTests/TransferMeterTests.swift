// TransferMeter: 파일마다 0→100% 를 새로 찍는 scp 진행률 → 전체 진행률. RemoteCommands.sizeCommand: 원격 전체 크기.

import Foundation
import XCTest
@testable import ServersCore

final class TransferMeterTests: XCTestCase {
    private func line(_ file: String, _ percent: Int, _ size: String) -> TransferProgress {
        TransferProgress(file: file, percent: percent, transferred: size, rate: "1.0MB/s", eta: "00:01")
    }

    func testBytes() {
        XCTAssertEqual(TransferMeter.bytes("512"), 512)
        XCTAssertEqual(TransferMeter.bytes("12KB"), 12 * 1024)
        XCTAssertEqual(TransferMeter.bytes("123MB"), 123 * 1024 * 1024)
        XCTAssertEqual(TransferMeter.bytes("2GB"), 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(TransferMeter.bytes("0.0KB"), 0)
        XCTAssertEqual(TransferMeter.bytes("1.5MiB"), Int64(1.5 * 1024 * 1024))
        XCTAssertNil(TransferMeter.bytes("abc"))
        XCTAssertNil(TransferMeter.bytes(""))
    }

    // 폴더: 파일마다 0→100% 가 반복돼도 전체는 앞으로만 간다
    func testDirectoryProgressAccumulates() {
        var meter = TransferMeter(totalBytes: 300 * 1024)
        meter.record(line("a.txt", 50, "50KB"))
        XCTAssertEqual(meter.fraction!, 50.0 / 300, accuracy: 0.001)
        meter.record(line("a.txt", 100, "100KB"))
        meter.record(line("b.txt", 10, "20KB"))           // 새 파일: 0 부터 다시 찍어도
        XCTAssertEqual(meter.fraction!, 120.0 / 300, accuracy: 0.001)
        meter.record(line("b.txt", 100, "200KB"))
        XCTAssertEqual(meter.fraction!, 1, accuracy: 0.001)
        XCTAssertEqual(meter.fileCount, 2)
        XCTAssertEqual(meter.doneBytes, 300 * 1024)
    }

    // 다른 폴더의 같은 이름 파일: 100% 뒤에 같은 이름이 오면 새 파일
    func testSameNameInDifferentFolders() {
        var meter = TransferMeter(totalBytes: 200)
        meter.record(line("index.html", 100, "100"))
        meter.record(line("index.html", 30, "30"))
        XCTAssertEqual(meter.fileCount, 2)
        XCTAssertEqual(meter.doneBytes, 130)
        meter.record(line("index.html", 100, "100"))
        XCTAssertEqual(meter.fileCount, 2, "같은 파일이 이어진 것")
        XCTAssertEqual(meter.doneBytes, 200)
    }

    // 같은 이름에서 % 가 줄면(100% 줄이 안 찍힌 채) 역시 새 파일
    func testPercentDropMeansNewFile() {
        var meter = TransferMeter()
        meter.record(line("log", 80, "80"))
        meter.record(line("log", 5, "5"))
        XCTAssertEqual(meter.fileCount, 2)
        XCTAssertEqual(meter.doneBytes, 85)
    }

    func testUnknownOrZeroTotalAndCap() {
        var meter = TransferMeter()
        meter.record(line("a", 50, "50"))
        XCTAssertNil(meter.fraction, "전체 크기를 모르면 nil")
        meter.totalBytes = 0
        XCTAssertNil(meter.fraction)
        meter.totalBytes = 10                                // du -sk 로 작게 잡혀도 1 을 넘지 않는다
        XCTAssertEqual(meter.fraction, 1)
    }

    func testMultipleSourceSpec() throws {
        let server = try ServerConfigParser.parse(fixture).server("nexus")!
        let spec = TransferSpec(server: server, direction: .download, localPaths: ["/tmp/out"], remotePaths: ["/var/log/a", "/srv/b dir/", "c.txt"])
        XCTAssertEqual(Array(spec.arguments(home: "/h").suffix(4)),
                       ["tester@100.64.0.1:/var/log/a", "tester@100.64.0.1:/srv/b dir/", "tester@100.64.0.1:c.txt", "/tmp/out"])
        XCTAssertEqual(spec.title, "↓ nexus: a 외 2개")
        XCTAssertEqual(spec.remotePath, "/var/log/a")
        let single = TransferSpec(server: server, direction: .download, localPaths: ["/tmp/out"], remotePaths: ["/var/log/a"])
        XCTAssertEqual(single.title, "↓ nexus:/var/log/a")
    }

    // Windows: SFTP 경로의 앞 / 를 떼고, 작은따옴표는 두 번
    func testWindowsSizeScript() {
        let script = RemoteCommands.windowsSizeScript(paths: ["/C:/Users/me/Desktop", "Downloads/it's.zip", "D:/backup"])
        XCTAssertTrue(script.contains("@('C:/Users/me/Desktop', 'Downloads/it''s.zip', 'D:/backup')"), script)
        let command = RemoteCommands.sizeCommand(paths: ["a"], type: .windows)
        XCTAssertTrue(command.command.hasPrefix("powershell.exe "))
        XCTAssertNil(command.stdin)
    }

    func testParseSize() {
        XCTAssertEqual(RemoteCommands.parseSize("12345\n"), 12345)
        XCTAssertEqual(RemoteCommands.parseSize("warning\r\n 42 \r\n"), 42)
        XCTAssertNil(RemoteCommands.parseSize("0\n"))
        XCTAssertNil(RemoteCommands.parseSize(""))
        XCTAssertNil(RemoteCommands.parseSize("du: cannot access"))
    }

    // Linux 명령을 이 Mac 의 sh 로 실제로 돌린다. BSD find 는 -printf 가 없어 du -skL×1024 쪽을, 가짜 GNU find 로 find 쪽을 탄다.
    func testLinuxSizeCommandRuns() throws {
        let home = tempPath("size")
        let dir = home.appendingPathComponent("a dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: dir.appendingPathComponent("x.bin"))
        try Data(count: 5_000).write(to: home.appendingPathComponent("it's.txt"))
        try Data(count: 3_000).write(to: home.appendingPathComponent("-dash.txt"))
        let script = RemoteCommands.sizeCommand(paths: ["a dir", "~/it's.txt", "-dash.txt"], type: .linux)
        XCTAssertEqual(script.command, "sh -s", "경로는 stdin 으로 — 인자로 보내면 한글이 NFD 로 바뀐다")

        func run(_ path: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script.command]
            let input = Pipe()
            p.standardInput = input
            p.currentDirectoryURL = home
            p.environment = ["HOME": home.path, "PATH": path]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            input.fileHandleForWriting.write(Data(script.stdin!.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        // BSD du: 블록 단위라 실제(18000)보다 같거나 크다
        let bsd = try XCTUnwrap(RemoteCommands.parseSize(try run("/usr/bin:/bin")))
        XCTAssertGreaterThanOrEqual(bsd, 18_000)
        XCTAssertLessThan(bsd, 18_000 + 64 * 1024)

        // 가짜 GNU find: -printf 를 받는 척하고, 경로마다 인자 길이를 크기로 찍는다 → 경로 인용·~·./ 처리가 맞는지 본다
        let fake = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        let find = fake.appendingPathComponent("find")
        try """
        #!/bin/sh
        [ "$1" = "/dev/null" ] && exit 0
        [ "$1" = "-L" ] || exit 64
        shift
        for p in "$@"; do [ "$p" = "-type" ] && break; [ -e "$p" ] || exit 1; printf '%s\\n' "${#p}"; done
        """.write(to: find, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: find.path)
        let gnu = try XCTUnwrap(RemoteCommands.parseSize(try run(fake.path + ":/usr/bin:/bin")))
        XCTAssertEqual(gnu, Int64("a dir".count + (home.path + "/it's.txt").count + "./-dash.txt".count))
    }

    // 업로드 전체 크기: 파일 크기 합, 폴더는 안의 파일만, 링크는 대상 크기
    func testLocalSize() throws {
        let root = tempPath("local")
        let dir = root.appendingPathComponent("d/sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: dir.appendingPathComponent("a"))
        try Data(count: 2_000).write(to: root.appendingPathComponent("d/b"))
        try Data(count: 500).write(to: root.appendingPathComponent("single"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("d/link"), withDestinationURL: root.appendingPathComponent("single"))
        XCTAssertEqual(TransferMeter.localSize([root.appendingPathComponent("d").path]), 3_500)
        XCTAssertEqual(TransferMeter.localSize([root.appendingPathComponent("single").path, dir.path]), 1_500)
        XCTAssertNil(TransferMeter.localSize([root.appendingPathComponent("nope").path]))
    }
}
