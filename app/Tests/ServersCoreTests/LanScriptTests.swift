// lib/lan.zsh 를 실제로 돌린다. networksetup 은 순서 파일을 읽고 쓰는 가짜(PATH 앞), sudo 는 함수로 통과.

import Foundation
import XCTest

/// 서비스 순서: Intranet 으로 지정할 때·서비스를 추가할 때 맨 뒤로 (나머지 순서는 그대로). 켜기·끄기·되돌리기는 없다 (2026-10-15 단순화).
/// 순서 파일에서 '*' 로 시작하는 이름은 비활성 서비스 — 가짜가 실제처럼 "(*) 이름" 으로 찍는다.
final class LanOrderScriptTests: XCTestCase {
    private let lanScript = TestPaths.repoRoot.appendingPathComponent("lib/lan.zsh").path

    private struct Outcome { let code: Int32; let stdout: String; let stderr: String; let order: [String]; let reorders: Int }

    private func run(_ body: String, order: [String]) throws -> Outcome {
        let dir = tempPath("lan-order")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let orderFile = dir.appendingPathComponent("order").path, log = dir.appendingPathComponent("log").path
        try (order.joined(separator: "\n") + "\n").write(toFile: orderFile, atomically: true, encoding: .utf8)
        let fake = """
            #!/bin/sh
            case "$1" in
              -listnetworkserviceorder) n=1; while IFS= read -r l; do
                  case "$l" in
                    '*'*) printf '(*) %s\\n(Hardware Port: X, Device: en%d)\\n' "${l#?}" $n ;;
                    *) printf '(%d) %s\\n(Hardware Port: X, Device: en%d)\\n' $n "$l" $n ;;
                  esac
                  n=$((n+1)); done < "$FAKE_ORDER" ;;
              -ordernetworkservices) shift; : > "$FAKE_ORDER"; for a in "$@"; do printf '%s\\n' "$a" >> "$FAKE_ORDER"; done; echo reorder >> "$FAKE_LOG" ;;
              *) printf 'networksetup %s\\n' "$*" >> "$FAKE_LOG" ;;
            esac
            """
        let path = bin.appendingPathComponent("networksetup").path
        try fake.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "sudo() { \"$@\"; }; source \(lanScript) || exit 9; \(body)"]
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin", "FAKE_ORDER": orderFile, "FAKE_LOG": log]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let finalOrder = ((try? String(contentsOfFile: orderFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let reorders = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == "reorder" }.count
        return Outcome(code: p.terminationStatus, stdout: stdout, stderr: stderr, order: finalOrder, reorders: reorders)
    }

    private let original = ["Ethernet (Hub)", "Wi-Fi", "Acme LAN", "Thunderbolt Bridge"]

    func testMoveLastKeepsOthersInOrder() throws {
        let r = try run("_lan_move_last 'Wi-Fi'", order: original)
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(r.order, ["Ethernet (Hub)", "Acme LAN", "Thunderbolt Bridge", "Wi-Fi"])
        XCTAssertEqual(r.reorders, 1)
    }

    func testAlreadyLastNoReorder() throws {
        let r = try run("_lan_move_last 'Thunderbolt Bridge'", order: original)
        XCTAssertEqual(r.reorders, 0)
        XCTAssertEqual(r.order, original)
    }

    /// 괄호 든 이름도 글자 그대로, 목록에 없는 이름은 실패(순서 그대로)
    func testNameWithParensAndMissing() throws {
        let r = try run("_lan_move_last 'Ethernet (Hub)'", order: original)
        XCTAssertEqual(r.order, ["Wi-Fi", "Acme LAN", "Thunderbolt Bridge", "Ethernet (Hub)"])
        let missing = try run("_lan_move_last 'Nope'", order: original)
        XCTAssertEqual(missing.code, 1)
        XCTAssertEqual(missing.order, original)
    }

    /// 비활성 서비스는 "(*) 이름" 으로 나온다 — 번호가 없어도 이름을 읽어 순서에 넣는다
    func testDisabledServiceLineIsRead() throws {
        let r = try run("_lan_move_last 'Acme LAN'", order: ["Wi-Fi", "*Acme LAN", "Thunderbolt Bridge"])
        XCTAssertEqual(r.code, 0, r.stderr)
        XCTAssertEqual(r.order, ["Wi-Fi", "Thunderbolt Bridge", "Acme LAN"])
        let other = try run("_lan_move_last 'Wi-Fi'", order: ["Wi-Fi", "*Acme LAN"])
        XCTAssertEqual(other.order, ["Acme LAN", "Wi-Fi"], "비활성 서비스도 목록에서 빠지지 않는다")
    }

    /// 목록을 못 읽으면(빈 출력) 순서를 건드리지 않고 실패
    func testEmptyListFails() throws {
        let r = try run("_lan_move_last 'Wi-Fi'", order: [])
        XCTAssertEqual(r.code, 1)
        XCTAssertEqual(r.reorders, 0)
    }
}
