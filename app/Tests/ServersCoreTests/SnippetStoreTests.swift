// SnippetStore: 명령 모음 정리·추가·바꾸기·삭제·저장, 깨진 파일 처리.

import Foundation
import XCTest
@testable import ServersCore

final class SnippetStoreTests: XCTestCase {
    func testNormalizedTrimsAndRejectsEmptyCommand() {
        let raw = CommandSnippet(type: .windows, title: "  방화벽 규칙  ", command: "\n  Get-NetFirewallRule |\n    Select Name  \n\n")
        let out = SnippetStore.normalized(raw)
        XCTAssertEqual(out?.title, "방화벽 규칙")
        XCTAssertEqual(out?.command, "Get-NetFirewallRule |\n    Select Name", "안쪽 줄바꿈·들여쓰기는 그대로")
        XCTAssertNil(SnippetStore.normalized(CommandSnippet(type: .linux, title: "이름만", command: " \n\t ")), "명령이 비면 저장하지 않는다")
    }

    func testDisplayTitleFallsBackToFirstCommandLine() {
        XCTAssertEqual(CommandSnippet(type: .linux, title: "디스크", command: "df -h").displayTitle, "디스크")
        XCTAssertEqual(CommandSnippet(type: .linux, title: "", command: "\nsudo ss -tlnp\nwc -l").displayTitle, "sudo ss -tlnp")
        XCTAssertEqual(CommandSnippet(type: .windows, title: "", command: "Get-Service\r\nGet-Process").displayTitle, "Get-Service", "Windows 에서 붙여 넣은 CRLF")
    }

    func testUpsertKeepsOrderAndFiltersByType() {
        let a = CommandSnippet(type: .windows, title: "a", command: "A")
        let b = CommandSnippet(type: .linux, title: "b", command: "B")
        let c = CommandSnippet(type: .windows, title: "c", command: "C")
        var state = SnippetState()
        for s in [a, b, c] { state = SnippetStore.upsert(s, in: state) }
        XCTAssertEqual(SnippetStore.snippets(for: .windows, in: state).map(\.title), ["a", "c"])
        XCTAssertEqual(SnippetStore.snippets(for: .linux, in: state).map(\.title), ["b"])
        // 편집은 그 자리에서
        var edited = a
        edited.command = "A2"
        state = SnippetStore.upsert(edited, in: state)
        XCTAssertEqual(state.snippets.map(\.command), ["A2", "B", "C"])
        state = SnippetStore.remove(id: b.id, from: state)
        XCTAssertEqual(state.snippets.map(\.title), ["a", "c"])
        XCTAssertEqual(SnippetStore.snippets(for: .linux, in: state), [])
    }

    func testMatchesTitleOrCommand() {
        let s = CommandSnippet(type: .windows, title: "방화벽 규칙", command: "Get-NetFirewallRule")
        XCTAssertTrue(SnippetStore.matches(s, ""))
        XCTAssertTrue(SnippetStore.matches(s, "방화벽"))
        XCTAssertTrue(SnippetStore.matches(s, "firewall"), "대소문자 무시")
        XCTAssertFalse(SnippetStore.matches(s, "ssh"))
    }

    func testTemplateVariablesAndFill() {
        let cmd = "Get-Service {{이름}} | Restart-Service; Get-Service {{ 이름 }}; Test-NetConnection -Port {{포트}}"
        XCTAssertEqual(SnippetTemplate.variables(in: cmd), ["이름", "포트"], "나온 순서, 같은 이름은 한 번 (안쪽 공백 무시)")
        XCTAssertEqual(SnippetTemplate.fill(cmd, values: ["이름": "Spooler", "포트": "443"]),
                       "Get-Service Spooler | Restart-Service; Get-Service Spooler; Test-NetConnection -Port 443")
        XCTAssertEqual(SnippetTemplate.fill("a {{x}} {{y}}", values: ["x": "1"]), "a 1 {{y}}", "값이 없으면 그대로")
        // 셸 문법의 중괄호 하나는 빈칸이 아니다
        XCTAssertEqual(SnippetTemplate.variables(in: "Get-Process | ForEach-Object { $_.Name }; echo ${HOME}; awk '{print $1}'; @{a=1}"), [])
        XCTAssertEqual(SnippetTemplate.variables(in: "echo {{}} {{a\nb}}"), [], "빈 이름·줄바꿈 낀 것은 빈칸 아님")
        XCTAssertEqual(SnippetTemplate.variables(in: "docker ps --format '{{.Names}} {{json .}}' | grep {{컨테이너 이름}}"), ["컨테이너 이름"],
                       "Go 템플릿(점·따옴표가 든 것)은 빈칸 아님, 공백 낀 한글 이름은 빈칸")
    }

    func testSensitiveDetectionAndConfirm() throws {
        for command in ["sudo reboot", "sudo shutdown -h now", "systemctl restart nginx", "sudo rm -rf /var/lib/x", "rm -fr build",
                        "mkfs.ext4 /dev/sdb1", "dd if=/dev/zero of=/dev/sda", "kubectl delete pod x", "sudo k3s kubectl drain node1",
                        "docker compose down", "docker rm -f web", "Restart-Computer -Force", "Stop-Service sshd", "Remove-Item C:\\x -Recurse",
                        "DROP TABLE users;", "sudo init 6",
                        // 리뷰에서 나온 누락: 옵션 위치·같은 뜻 명령
                        "rm -i -rf x", "rm --preserve-root -rf /", "rm x -rf", "kubectl -n kube-system delete pod x",
                        "docker compose -f a.yml down", "systemctl --user restart x", "sudo systemctl -q stop x", "docker restart web",
                        "Restart-Service sshd", "Remove-Item x -r", "docker-compose down", "rd /s /q C:\\tmp", "del /f /s *.log",
                        "service nginx stop", "diskutil eraseDisk APFS X disk4",
                        // 여러 줄 명령: 줄 처음도 명령 자리
                        "cd /tmp\nrm -rf x", "cd /tmp\r\nsudo rm -rf x", "echo start\n  rm -r build"] {
            XCTAssertTrue(SnippetStore.looksSensitive(command), command)
        }
        for command in ["df -h", "systemctl status nginx", "docker ps -a", "kubectl get pods -A", "rm file.txt", "Get-Service",
                        "journalctl -u rebootd", "echo shutdown_hook", "ls -rf",
                        "rm -f one.txt", "git rm -r --cached x", "docker run --rm alpine", "kubectl get pods | grep delete",
                        "systemctl status nginx | grep stop",
                        // 다음 줄은 다른 명령
                        "rm a.txt\nls -lr", "kubectl get pods\necho will delete later", "docker ps\necho stop"] {
            XCTAssertFalse(SnippetStore.looksSensitive(command), command)
        }
        XCTAssertTrue(CommandSnippet(type: .linux, command: "sudo reboot").sensitive, "새로 만들면 글자로 판단")
        XCTAssertFalse(CommandSnippet(type: .linux, command: "sudo reboot", sensitive: false).sensitive, "사용자가 끈 값은 그대로")
        // 이 기능 전에 저장한 파일: sensitive 칸이 없으면 글자로 판단 (이미 넣어 둔 reboot 도 확인을 받는다)
        let old = #"{"snippets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","type":"linux","title":"","command":"sudo reboot","runImmediately":true},"#
            + #"{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","type":"linux","title":"","command":"df -h"}]}"#
        let decoded = try JSONDecoder().decode(SnippetState.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.snippets.map(\.sensitive), [true, false])

        // 빈칸을 채운 결과로 민감해지면 확인 (템플릿이 이미 민감해 보이는데 꺼져 있으면 사용자가 끈 것)
        let template = CommandSnippet(type: .linux, command: "systemctl {{동작}} nginx")
        XCTAssertFalse(template.sensitive)
        XCTAssertTrue(SnippetStore.needsConfirm(template, filled: "systemctl restart nginx"))
        XCTAssertFalse(SnippetStore.needsConfirm(template, filled: "systemctl status nginx"))
        let optedOut = CommandSnippet(type: .linux, command: "sudo reboot", sensitive: false)
        XCTAssertFalse(SnippetStore.needsConfirm(optedOut, filled: "sudo reboot"))
        XCTAssertTrue(SnippetStore.needsConfirm(CommandSnippet(type: .mac, command: "sudo reboot"), filled: "sudo reboot"))

        XCTAssertTrue(SnippetStore.confirms(" Nexus ", server: "nexus"))
        XCTAssertFalse(SnippetStore.confirms("nexu", server: "nexus"))
        XCTAssertFalse(SnippetStore.confirms("", server: ""), "서버를 모르면 확인되지 않는다")
    }

    func testSaveLoadAndBrokenFile() throws {
        let dir = tempPath("snippets")
        let url = dir.appendingPathComponent("Servers/snippets.json")
        XCTAssertEqual(try SnippetStore.load(from: url), SnippetState(), "파일이 없으면 빈 목록")
        let state = SnippetStore.upsert(CommandSnippet(type: .windows, title: "t", command: "c"), in: SnippetState())
        try SnippetStore.save(state, to: url)
        XCTAssertEqual(try SnippetStore.load(from: url), state)
        // 바로 실행 값도 남고, 그 칸이 없던 예전 파일은 꺼짐으로 읽는다
        let run = SnippetStore.upsert(CommandSnippet(type: .linux, title: "r", command: "uptime", runImmediately: true), in: state)
        try SnippetStore.save(run, to: url)
        XCTAssertEqual(try SnippetStore.load(from: url).snippets.map(\.runImmediately), [false, true])
        let old = #"{"snippets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","type":"windows","title":"t","command":"c\n"}]}"#
        try old.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SnippetStore.load(from: url).snippets.first?.runImmediately, false)
        XCTAssertEqual(try SnippetStore.load(from: url).snippets.first?.command, "c", "손으로 넣은 끝 줄바꿈은 읽을 때 뗀다 (입력만 해도 실행되지 않게)")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SnippetStore.load(from: url), "깨진 파일은 빈 목록으로 덮지 않게 오류") { error in
            XCTAssertEqual((error as? ConfigError)?.reference, url.path)
        }
    }
}
