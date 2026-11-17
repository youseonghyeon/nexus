// ServicesReport: Services 탭 스크립트 출력 → 실패·실행 중·컨테이너.
// Fixtures/services-linux-{1,2}.txt 는 ServicesScript.linux 를 로컬 ubuntu:24.04 컨테이너(systemd 를 PID 1 로)에서 돌린 실제 출력이다 (2026-10-05).
//   1: nginx·cron 실행, broken.service(ExecStart=/bin/false) 실패, flaky 는 막 다시 켜진 순간(실행 중 · 재시작 218),
//      가짜 docker(컨테이너 4개)·kubeconfig 권한 거부 k3s (sudo 없음 → denied)
//   2: flaky.service(1초 뒤 exit 1, Restart=always)가 재시작 대기(auto-restart)일 때, docker·k3s 없음
// systemd 없는 ubuntu:24.04 는 "SYSTEMD=off", 데몬이 꺼진 docker 는 "SOURCE|docker|off" 를 냈다 (아래 손 입력 테스트).
// Windows 출력은 서버에서 떠 오지 못해 스크립트 모양대로 손으로 만든 것이다 (실제 값은 사용자 확인).

import Foundation
import XCTest
@testable import ServersCore

final class ServicesReportTests: XCTestCase {
    private func fixture(_ n: Int) throws -> [String] {
        RemoteCommands.cleanOutput(try fixtureText("services-linux-\(n)"), type: .linux)
    }

    func testLinuxFailedRunningAndContainers() throws {
        let report = try XCTUnwrap(ServicesParser.parse(try fixture(1), type: .linux))
        XCTAssertEqual(report.failed.map(\.name), ["broken"])
        let broken = report.failed[0]
        XCTAssertEqual(broken.description, "Broken test service")
        XCTAssertEqual(broken.changedAgo ?? -1, 593.98 - 103.009593, accuracy: 0.01, "부팅 후 µs 와 /proc/uptime 의 차")
        XCTAssertEqual(ServicesFormat.failure(broken), "exit-code · 8분 전")
        XCTAssertFalse(report.running.contains { $0.name == "broken" })

        XCTAssertTrue(report.running.contains { $0.name == "nginx" })
        XCTAssertEqual(report.mainRunning.map(\.name), ["flaky", "nginx"], "기본이 아닌 것만, 이름 순")
        XCTAssertEqual(report.running.first { $0.name == "flaky" }.map(ServicesFormat.detail)?.hasSuffix("재시작 218"), true, "재시작 횟수를 적는다")
        XCTAssertTrue(report.basicRunning.contains { $0.name == "cron" } && report.basicRunning.contains { $0.name == "systemd-journald" })
        XCTAssertFalse(report.mainRunning.contains { $0.name == "dbus" })
        let nginx = try XCTUnwrap(report.running.first { $0.name == "nginx" })
        XCTAssertEqual(nginx.restarts, 0)
        XCTAssertNotNil(nginx.memory)
        XCTAssertNotNil(nginx.uptime)
        XCTAssertFalse(ServicesFormat.detail(nginx).contains("재시작"), "재시작 0 은 적지 않는다")

        XCTAssertEqual(report.sources, ["docker": .ok, "k3s": .denied])
        XCTAssertEqual(report.containers.map(\.name), ["web", "worker", "job", "db"])
        XCTAssertEqual(report.containers.map(\.tone), [.good, .bad, .muted, .bad])
        XCTAssertEqual(report.containers[0].detail, "nginx:1.27")
    }

    func testLinuxRestartLoopIsFailed() throws {
        let report = try XCTUnwrap(ServicesParser.parse(try fixture(2), type: .linux))
        let flaky = try XCTUnwrap(report.failed.first { $0.name == "flaky" }, "auto-restart 도 실패 구역에")
        XCTAssertEqual(flaky.restarts, 221)
        XCTAssertEqual(ServicesFormat.failure(flaky), "재시작 반복 221회 · exit-code")
        XCTAssertFalse(report.running.contains { $0.name == "flaky" }, "한 번에 읽어 두 구역에 같이 뜨지 않는다")
        XCTAssertTrue(report.containers.isEmpty)
        XCTAssertEqual(report.sources, [:], "docker·k3s 가 없는 서버")
    }

    func testRunningRestartsAndEdgeValues() {
        let lines = ["UPTIME=1000", "## FAILED", "## RUNNING",
                     "Id=app.service", "Description=App", "ActiveEnterTimestampMonotonic=400000000", "MemoryCurrent=[not set]", "NRestarts=3",
                     // 빈 줄 없이 다음 블록 (같은 키가 다시 나오면 새 블록)
                     "Id=other.service", "MemoryCurrent=18446744073709551615", "ActiveEnterTimestampMonotonic=0",
                     "## CONTAINERS", "SOURCE|k3s|ok", "P|kube-system/coredns-1|Running|1/1|0|3d",
                     "P|default/api-2|CrashLoopBackOff|0/1|12|5m", "P|default/init-3|Pending|0/1|0|10s", "## END"]
        let report = ServicesParser.parse(lines, type: .linux)
        XCTAssertEqual(report?.running.map(\.name), ["app", "other"])
        let app = report?.running.first
        XCTAssertNil(app?.memory, "[not set] 은 없음")
        XCTAssertEqual(app?.uptime ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(app.map(ServicesFormat.detail), "10분 · 재시작 3")
        XCTAssertNil(report?.running.last?.memory, "무한대는 없음")
        XCTAssertNil(report?.running.last?.uptime, "0 은 모름")
        XCTAssertEqual(report?.containers.map(\.tone), [.good, .bad, .warn])
        XCTAssertEqual(report?.containers.first?.age, "3d")
        XCTAssertEqual(report?.containers.first?.copyName, "coredns-1", "kubectl 에 바로 쓰게 네임스페이스는 뗀다")
        // 리뷰에서 나온 상태들: readiness 실패 · 초기화 실패 · 초기화 진행 · 배포 중
        func tone(_ status: String, _ ready: String = "1/1") -> ContainerItem.Tone { ContainerItem(kind: .pod, name: "a/b", status: status, ready: ready).tone }
        XCTAssertEqual(tone("Running", "0/1"), .warn)
        XCTAssertEqual(tone("Init:CrashLoopBackOff"), .bad)
        XCTAssertEqual(tone("Init:0/2"), .warn)
        XCTAssertEqual(tone("Terminating"), .warn)
        XCTAssertEqual(ServicesParser.parse(["## CONTAINERS", "SOURCE|k3s|ok", "MORE|k3s|340", "## END"], type: .linux)?.truncated, ["k3s": 340])
        XCTAssertEqual(report?.containers.first?.namespace, "kube-system")
        XCTAssertEqual(report?.containers[1].restarts, 12)
        XCTAssertEqual(report?.containers[1].ready, "0/1")
        XCTAssertNil(ServicesParser.parse(["tailscaled  active", "garbage"], type: .linux), "구역 머리가 없으면 nil")

        // UNITS: SubState 로 나누고, 그 사이 멈춘 것(dead)은 뺀다. 실행 중 경과가 음수(lxcfs)면 모름.
        let units = ServicesParser.parse(["UPTIME=100", "## UNITS",
                                          "Id=a.service", "ActiveState=active", "SubState=running", "ActiveEnterTimestampMonotonic=200000000", "",
                                          "Id=b.service", "ActiveState=inactive", "SubState=dead", "",
                                          "Id=c.service", "ActiveState=failed", "SubState=failed", "StateChangeTimestampMonotonic=70000000", "",
                                          "## CONTAINERS", "SOURCE|docker|off", "## END"], type: .linux)
        XCTAssertEqual(units?.running.map(\.name), ["a"])
        XCTAssertNil(units?.running.first?.uptime, "/proc/uptime 보다 늦은 시각은 모름")
        XCTAssertEqual(units?.failed.map(\.name), ["c"])
        XCTAssertEqual(units.map { ServicesFormat.failure($0.failed[0]) }, "failed · 방금", "1분 안은 방금")
        XCTAssertEqual(units?.sources, ["docker": .off])
        // 패키지를 지운 뒤 남은 실패 기록 (2026-10-05 nexus fail2ban): LoadState=not-found
        let gone = ServicesParser.parse(["UPTIME=100", "## UNITS", "Id=fail2ban.service", "LoadState=not-found", "ActiveState=failed",
                                         "SubState=failed", "Result=exit-code", "## END"], type: .linux)?.failed.first
        XCTAssertEqual(gone?.removed, true)
        XCTAssertEqual(gone.map(ServicesFormat.failure), "삭제된 서비스의 실패 기록")
        XCTAssertEqual(ServicesParser.parse(["UPTIME=1", "## UNITS", "SYSTEMD=off", "## CONTAINERS", "## END"], type: .linux)?.noSystemd, true)
    }

    /// 2026-10-05 nexus k3s 화면에 나온 파드 이름들 (사용자 스크린샷)
    func testPodNameSplitAndAges() {
        func split(_ n: String) -> [String] { let p = PodName.split(n); return [p.base, p.hash] }
        XCTAssertEqual(split("calapp-server-f6cdff6d5-mt2v2"), ["calapp-server", "-f6cdff6d5-mt2v2"], "디플로이먼트")
        XCTAssertEqual(split("argocd-redis-796bc79b78-55vpg"), ["argocd-redis", "-796bc79b78-55vpg"])
        XCTAssertEqual(split("mysql-backup-29849400-8kkxt"), ["mysql-backup", "-29849400-8kkxt"], "크론잡: 시각 숫자")
        XCTAssertEqual(split("argocd-application-controller-0"), ["argocd-application-controller-0", ""], "스테이트풀셋 번호는 그대로")
        XCTAssertEqual(split("svclb-traefik-x7k2q"), ["svclb-traefik", "-x7k2q"], "데몬셋")
        XCTAssertEqual(split("nginx-proxy"), ["nginx-proxy", ""], "모음이 든 낱말은 꼬리가 아니다")
        let pod = ContainerItem(kind: .pod, name: "database/mysql-backup-29852280-l8p2h", status: "Completed", ready: "0/1", restarts: 0)
        XCTAssertEqual(pod.displayName.base, "mysql-backup")
        XCTAssertTrue(pod.finished)
        XCTAssertFalse(ContainerItem(kind: .pod, name: "a/b", status: "Running").statusWorthShowing)
        XCTAssertTrue(ContainerItem(kind: .docker, name: "job", status: "Exited (0) 5 minutes ago").finished)
        XCTAssertFalse(ContainerItem(kind: .docker, name: "w", status: "Exited (1) 2 hours ago").finished, "오류 종료는 접지 않는다")

        XCTAssertEqual(ServicesFormat.podAge("220d"), "220일")
        XCTAssertEqual(ServicesFormat.podAge("3d1h"), "3일 1시간")
        XCTAssertEqual(ServicesFormat.podAge("38h"), "1일 14시간")
        XCTAssertEqual(ServicesFormat.podAge("2d14h"), "2일 14시간")
        XCTAssertEqual(ServicesFormat.podAge("5m10s"), "5분")
        XCTAssertEqual(ServicesFormat.podAge("10s"), "10초")
        XCTAssertEqual(ServicesFormat.podAge("weird"), "weird", "못 읽으면 원문")
        XCTAssertEqual(ServicesFormat.duration(4 * 86400 + 17 * 3600 + 9 * 60), "4일 17시간", "큰 단위 둘까지")
    }

    func testWindowsBasicAndFailed() {
        let lines = ["## FAILED", "Id=gupdate", "Description=Google Update", "SubState=Stopped", "Result=exit-code 1", "",
                     "## RUNNING",
                     "Id=sshd", "Description=OpenSSH SSH Server", #"Path=C:\Windows\System32\OpenSSH\sshd.exe"#, "",
                     "Id=Tailscale", "Description=Tailscale", #"Path="C:\Program Files\Tailscale\tailscaled.exe""#, "",
                     "Id=Dhcp", "Description=DHCP Client", #"Path=C:\Windows\system32\svchost.exe -k LocalServiceNetworkRestricted -p"#, "",
                     "Id=WinDefend", "Description=Microsoft Defender", #"Path="C:\ProgramData\Microsoft\Windows Defender\Platform\4.18\MsMpEng.exe""#, "",
                     // 실패 쪽에 이미 있는 이름이 실행 중에도 오면 (따로 읽는 사이 바뀜) 실패만
                     "Id=gupdate", "Description=Google Update", #"Path="C:\Program Files (x86)\Google\Update\GoogleUpdate.exe""#, "",
                     "## CONTAINERS", "SOURCE|docker|off", "## END"]
        let report = ServicesParser.parse(lines, type: .windows)
        XCTAssertEqual(report?.failed.map(\.name), ["gupdate"])
        XCTAssertEqual(report.map { ServicesFormat.failure($0.failed[0]) }, "exit-code 1")
        XCTAssertEqual(report?.mainRunning.map(\.name), ["sshd", "Tailscale"], "OpenSSH 는 Windows 폴더 안이어도 사용자 것")
        XCTAssertEqual(report?.basicRunning.map(\.name), ["Dhcp", "WinDefend"], "Microsoft 제품 폴더도 기본")
        XCTAssertEqual(report?.sources, ["docker": .off])
    }

    func testLogCommandOnlyForSafeNames() {
        XCTAssertEqual(ServiceLog.command(unit: "nginx"),
                       "sudo -n journalctl -u 'nginx.service' -n 50 --no-pager -o short-iso 2>/dev/null || journalctl -u 'nginx.service' -n 50 --no-pager -o short-iso 2>&1")
        XCTAssertNotNil(ServiceLog.command(unit: "getty@tty1"))
        XCTAssertNotNil(ServiceLog.command(unit: #"systemd-fsck@dev-disk-by\x2duuid-1234"#))
        XCTAssertNil(ServiceLog.command(unit: "x'; rm -rf / #"), "따옴표·공백·; 는 거부")
        XCTAssertNil(ServiceLog.command(unit: ""))
    }

    func testDockerLogCommandOnlyForSafeNames() {
        let command = ServiceLog.dockerCommand(container: "acme-api_1.web")
        XCTAssertEqual(command, #"T=""; command -v timeout >/dev/null 2>&1 && T="timeout 8"; out=$($T docker logs --tail 50 'acme-api_1.web' 2>&1) || { first=$out; out=$($T sudo -n docker logs --tail 50 'acme-api_1.web' 2>&1) || { printf '%s\n' "$first"; exit 1; }; }; printf '%s\n' "$out""#)
        XCTAssertNil(ServiceLog.dockerCommand(container: "x'; rm -rf / #"), "따옴표·공백·; 는 거부")
        XCTAssertNil(ServiceLog.dockerCommand(container: "-f"), "옵션으로 읽힐 이름은 거부")
        XCTAssertNil(ServiceLog.dockerCommand(container: "app/calapp"), "파드 이름(네임스페이스/이름)은 docker 가 아니다")
        XCTAssertNil(ServiceLog.dockerCommand(container: ""))
    }

    func testStripANSIRemovesColorCodes() {
        XCTAssertEqual(ServiceLog.stripANSI("\u{1B}[32mINFO\u{1B}[0m ready \u{1B}[1;31mERR\u{1B}[m \u{1B}[2K"), "INFO ready ERR ")
        XCTAssertEqual(ServiceLog.stripANSI("plain [1] text"), "plain [1] text", "ESC 없는 대괄호는 그대로")
    }

    func testScriptsUseStdinAndPowerShell() {
        XCTAssertEqual(RemoteCommands.query(.services, for: .linux)?.command, "sh -s")
        XCTAssertEqual(RemoteCommands.query(.services, for: .linux)?.stdin, ServicesScript.linux)
        XCTAssertTrue(RemoteCommands.query(.services, for: .windows)?.command.hasPrefix("powershell.exe") == true)
        // 오류 문구는 mktemp 파일로 — /tmp 의 짐작되는 이름(.nexus-err.<pid>)을 쓰지 않고, 못 만들었으면 /dev/null 을 지우지 않는다
        XCTAssertFalse(ServicesScript.linux.contains("/tmp/"))
        XCTAssertTrue(ServicesScript.linux.contains(#"E=$(mktemp 2>/dev/null) || E="""#))
        XCTAssertTrue(ServicesScript.linux.contains(#"[ -n "$E" ] && rm -f "$E""#))
    }
}
