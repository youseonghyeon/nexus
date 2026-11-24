// 리눅스 원격 정보: Spec 업데이트 목록 · Network · Schedule. 입력은 ubuntu:24.04 컨테이너의 실제 출력 (Fixtures/linux-*.txt).

import Foundation
import XCTest
@testable import ServersCore

final class LinuxInfoTests: XCTestCase {
    private func lines(_ name: String) throws -> [String] {
        RemoteCommands.cleanOutput(try fixtureText(name), type: .linux)
    }

    // MARK: Spec 업데이트 목록

    func testUpdatesListAndCount() throws {
        let spec = try lines("linux-spec-updates")
        let items = RemoteInfo.parseSpec(spec)
        XCTAssertEqual(items.map(\.key), ["UPDATES"], "UPDATE 줄은 Spec 항목이 아니다")
        XCTAssertEqual(items.first?.value, "3개 (보안 3)")
        XCTAssertTrue(items.first?.warning == true)
        let updates = RemoteInfo.parseUpdates(spec)
        XCTAssertEqual(updates.map(\.name), ["apt", "libapt-pkg6.0t64", "libpcre2-8-0"])
        XCTAssertEqual(updates[0].installed, "2.8.3")
        XCTAssertEqual(updates[0].version, "2.8.4ubuntu0.1")
        XCTAssertTrue(updates.allSatisfy(\.security))
        XCTAssertEqual(RemoteInfo.parseUpdates(["UPDATES      0;0"]), [])
    }

    /// apt 와 libapt 를 hold 한 컨테이너 출력: apt-check 는 4, 목록은 6 — 차이 2개가 보류 (2026-11-13 nexus 에서 "3개" 인데 목록이 6줄이던 것)
    func testDeferredUpdatesAreCountedAndSortedLast() throws {
        let spec = try lines("linux-spec-updates-held")
        let items = RemoteInfo.parseSpec(spec)
        XCTAssertEqual(items.map(\.key), ["UPDATES"], "UPDATE · INSTALLS 줄은 Spec 항목이 아니다")
        XCTAssertEqual(items.first?.value, "4개 (보안 4) · 보류 2")
        let updates = RemoteInfo.parseUpdates(spec)
        XCTAssertEqual(updates.map(\.name), ["libc-bin", "libc6", "libpcre2-8-0", "perl-base", "apt", "libapt-pkg6.0t64"], "보류는 뒤로")
        XCTAssertEqual(updates.map(\.deferred), [false, false, false, false, true, true])
    }

    func testDeferredUpdatesEdgeCases() {
        let update = "UPDATE       snapd/noble-updates 2.78+ubuntu24.04 amd64 [upgradable from: 2.77.1+ubuntu24.04]"
        // INSTALLS 줄이 없다 (모의 실행 실패·옛 출력): 보류를 가리지 않는다
        XCTAssertEqual(RemoteInfo.parseUpdates([update]).map(\.deferred), [false])
        XCTAssertEqual(RemoteInfo.parseSpec(["UPDATES      1;0", update]).first?.value, "1개")
        // 줄은 있는데 이름이 없다: 전부 보류 (cleanOutput 이 끝 공백을 떼도 같다)
        XCTAssertEqual(RemoteInfo.parseUpdates([update, "INSTALLS     "]).map(\.deferred), [true])
        XCTAssertEqual(RemoteInfo.parseUpdates([update, "INSTALLS"]).map(\.deferred), [true])
        // 이름이 다른 패키지의 앞부분이어도 섞이지 않는다 (snapd ≠ snapd-extra)
        XCTAssertEqual(RemoteInfo.parseUpdates([update, "INSTALLS     snapd-extra"]).map(\.deferred), [true])
        XCTAssertEqual(RemoteInfo.parseUpdates([update, "INSTALLS     snapd"]).map(\.deferred), [false])
        // 보안 없이 보류만
        XCTAssertEqual(RemoteInfo.parseSpec(["UPDATES      3;0", update, "INSTALLS     docker-ce"]).first?.value, "3개 · 보류 1")
    }

    func testUpdatesSecurityFirst() {
        let updates = RemoteInfo.parseUpdates([
            "UPDATE       zlib1g/noble-updates 1.3 amd64 [upgradable from: 1.2]",
            "UPDATE       openssl/noble-updates,noble-security 3.0.13 amd64 [upgradable from: 3.0.12]",
            "UPDATE       bash/noble-updates 5.2 amd64 [upgradable from: 5.1]",
        ])
        XCTAssertEqual(updates.map(\.name), ["openssl", "bash", "zlib1g"])
        XCTAssertEqual(updates.map(\.security), [true, false, false])
    }

    func testParsedSpecCarriesUpdatesOnlyForLinux() throws {
        let spec = try lines("linux-spec-updates")
        XCTAssertEqual(ParsedRemoteInfo.parse(.spec, lines: spec, type: .linux), .spec(RemoteInfo.parseSpec(spec), updates: RemoteInfo.parseUpdates(spec)))
        XCTAssertEqual(ParsedRemoteInfo.parse(.spec, lines: spec, type: .windows), .spec(RemoteInfo.parseSpec(spec), updates: []))
    }

    // MARK: Network

    func testNetworkInterfacesRoutesAndDNS() throws {
        let network = try XCTUnwrap(LinuxNetwork.parse(try lines("linux-network")))
        XCTAssertEqual(network.interfaces.map(\.name), ["eth0", "br-test", "veth-b", "veth-a"], "lo 는 뺀다 · IPv4 있는 것 먼저")
        XCTAssertEqual(network.layout.visibleItems.map(\.id), ["eth0"], "브리지·veth 는 접힘")
        XCTAssertEqual(network.layout.foldedItems.map(\.id), ["br-test", "veth-b", "veth-a"])
        XCTAssertEqual(network.interfaces[3].master, "br-test")
        let eth0 = network.interfaces[0]
        XCTAssertTrue(eth0.up)
        XCTAssertEqual(eth0.addresses, ["192.168.215.2/24"])
        XCTAssertNotNil(eth0.mac)
        XCTAssertEqual(eth0.mtu, 1500)
        XCTAssertTrue((eth0.rxBytes ?? 0) > 0)
        XCTAssertNil(eth0.kind)
        XCTAssertEqual(network.interfaces[1].kind, "bridge")
        XCTAssertEqual(network.interfaces[1].addresses, ["10.99.0.1/24"])

        let routing = try XCTUnwrap(network.routing)
        XCTAssertEqual(routing.defaultRoutes.map(\.gateway), ["192.168.215.1"])
        XCTAssertTrue(routing.policyRules.isEmpty, "기본 규칙 셋뿐")
        let eth0Item = network.layout.items[0]
        XCTAssertEqual(eth0Item.routes.map(\.destination), ["default"], "게이트웨이 경로는 행 아래")
        XCTAssertEqual(eth0Item.subnetRoutes.map(\.destination), ["192.168.215.0/24"], "자기 대역은 펼쳐야")
        XCTAssertEqual(network.layout.items[1].subnetRoutes.map(\.destination), ["10.99.0.0/24"])
        XCTAssertTrue(network.layout.otherRoutes.isEmpty)
        XCTAssertEqual(network.dns, ["0.250.250.200"], "resolvectl 이 없으면 resolv.conf")
        XCTAssertEqual(network.searchDomains, [])
        XCTAssertEqual(ParsedRemoteInfo.parse(.network, lines: try lines("linux-network"), type: .linux), .linuxNetwork(network))
    }

    func testNetworkPrefersResolvectlAndSkipsLinkLocal() {
        let (servers, domains) = LinuxNetwork.dns(servers: ["Global: 1.1.1.1 8.8.8.8", "Link 2 (eth0): 192.168.8.1 fd00::1", "Link 3 (docker0):"],
                                                  domains: ["Global:", "Link 2 (eth0): corp.example ~."], resolv: ["nameserver 127.0.0.53", "search stub"])
        XCTAssertEqual(servers, ["1.1.1.1", "8.8.8.8", "192.168.8.1", "fd00::1"], "IPv6 의 ':' 에 안 걸린다")
        XCTAssertEqual(domains, ["corp.example"], "~. 은 빼고 resolv.conf 는 안 본다")
        XCTAssertEqual(LinuxNetwork.dns(servers: [], domains: [], resolv: ["nameserver 10.0.0.1", "search a.example b.example"]).servers, ["10.0.0.1"])
        let json = #"[{"ifindex":3,"ifname":"wg0","flags":["POINTOPOINT","NOARP","UP","LOWER_UP"],"mtu":1420,"operstate":"UNKNOWN","link_type":"none","addr_info":[{"family":"inet","local":"10.0.0.2","prefixlen":24,"scope":"global"},{"family":"inet6","local":"fe80::1","prefixlen":64,"scope":"link"},{"family":"inet6","local":"fd00::2","prefixlen":64,"scope":"global"}]},{"ifindex":4,"ifname":"veth1","flags":["BROADCAST","UP","LOWER_UP"],"operstate":"UP","link_type":"ether","address":"aa:bb:cc:dd:ee:ff","master":"docker0","addr_info":[]}]"#
        let network = LinuxNetwork.parse(["@ADDR", json, "@RULES", "@ROUTES", "@DNS", "@DOMAIN", "@RESOLV", "@END"])
        XCTAssertEqual(network?.interfaces.map(\.name), ["wg0", "veth1"])
        XCTAssertEqual(network?.layout.visibleItems.map(\.id), ["wg0"], "터널은 보이고 veth 는 접힌다")
        let unplugged = #"[{"ifindex":3,"ifname":"wlp2s0","flags":["BROADCAST","MULTICAST"],"operstate":"DOWN","link_type":"ether","address":"aa:bb:cc:00:11:22","addr_info":[]}]"#
        let down = LinuxNetwork.parse(["@ADDR", unplugged, "@RULES", "@ROUTES", "@DNS", "@DOMAIN", "@RESOLV", "@END"])
        XCTAssertEqual(down?.layout.visibleItems.map(\.id), ["wlp2s0"], "안 꽂힌 실제 NIC 는 본 목록에 (회색 점)")
        XCTAssertEqual(down?.interfaces.first?.up, false)
        XCTAssertEqual(network?.interfaces[0].kind, "wireguard")
        XCTAssertTrue(network?.interfaces[0].up == true, "tun · wireguard 는 operstate UNKNOWN 이어도 UP 플래그로")
        XCTAssertEqual(network?.interfaces[0].addresses, ["10.0.0.2/24", "fd00::2/64"], "fe80 은 뺀다")
        XCTAssertEqual(network?.interfaces[1].descriptors, ["veth", "in docker0"])
        XCTAssertNil(network?.routing, "경로를 하나도 못 읽으면 nil")
        XCTAssertNil(LinuxNetwork.parse(["@ADDR", "ip: command not found", "@END"]), "JSON 이 아니면 원문")
    }

    func testOtherRoutesAndUnknownDevices() {
        let json = #"[{"ifindex":2,"ifname":"eth0","flags":["UP","LOWER_UP"],"operstate":"UP","link_type":"ether","addr_info":[{"family":"inet","local":"10.1.0.5","prefixlen":16,"scope":"global"}]}]"#
        let network = LinuxNetwork.parse(["@ADDR", json, "@RULES", "0:\tfrom all lookup local", "100:\tfrom 10.1.0.5 lookup 200", "32766:\tfrom all lookup main", "@ROUTES",
                                          "default via 10.1.0.1 dev eth0 proto static metric 100", "10.1.0.0/16 dev eth0 proto kernel scope link src 10.1.0.5",
                                          "172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown", "default via 10.1.0.254 dev eth0 table 200",
                                          "blackhole 192.0.2.0/24 table 200", "@DNS", "@DOMAIN", "@RESOLV", "@END"])
        let item = network?.layout.items.first
        XCTAssertEqual(item?.routes.map(\.destination), ["default"])
        XCTAssertEqual(item?.subnetRoutes.map(\.destination), ["10.1.0.0/16"])
        XCTAssertEqual(network?.layout.otherRoutes.map(\.destination), ["172.17.0.0/16", "default", "192.0.2.0/24"], "목록에 없는 장치 · 다른 테이블 · blackhole")
        XCTAssertEqual(network?.routing?.policyRules.map(\.condition), ["from 10.1.0.5"])
    }

    func testIPv4Prefix() {
        XCTAssertTrue(IPv4Prefix.sameNetwork("192.168.8.103/24", "192.168.8.0/24"))
        XCTAssertFalse(IPv4Prefix.sameNetwork("192.168.8.103/24", "192.168.9.0/24"))
        XCTAssertFalse(IPv4Prefix.sameNetwork("192.168.8.103/24", "192.168.8.0/25"), "접두사가 다르면 다른 경로")
        XCTAssertFalse(IPv4Prefix.sameNetwork("192.168.8.103/24", "default"))
        XCTAssertTrue(IPv4Prefix.sameNetwork("10.0.0.2/0", "0.0.0.0/0"))
    }

    // MARK: Schedule

    func testScheduleWithSystemd() throws {
        let report = try XCTUnwrap(ScheduleReport.parse(try lines("linux-schedule")))
        XCTAssertEqual(report.now, Date(timeIntervalSince1970: 1794054528))
        let timers = try XCTUnwrap(report.timers)
        XCTAssertEqual(timers.count, 7)
        XCTAssertEqual(timers.first?.unit, "systemd-tmpfiles-clean.timer", "다음 실행이 가까운 순")
        XCTAssertEqual(timers.first?.next, Date(timeIntervalSince1970: 1794055426.283640))
        XCTAssertNil(timers.first?.last, "0 = 한 번도 안 돌았다")
        XCTAssertEqual(timers.last?.unit, "fstrim.timer", "예정 없는 것은 뒤")
        XCTAssertNil(timers.last?.next)
        XCTAssertEqual(timers.first?.name, "systemd-tmpfiles-clean")
        XCTAssertNil(timers.first?.activatesIfDifferent)
        XCTAssertEqual(SystemdTimer(unit: "logrotate.timer", activates: "logrotate-all.service", next: nil, last: nil).activatesIfDifferent, "logrotate-all.service")

        XCTAssertEqual(report.cron.filter { $0.source == "crontab" }.map(\.command), ["/usr/local/bin/backup.sh"])
        XCTAssertNil(report.cron[0].user, "내 crontab — 화면이 접속 계정을 넣는다")
        let etc = report.cron.filter { $0.source == "/etc/crontab" }
        XCTAssertEqual(etc.count, 4)
        XCTAssertEqual(etc[0].schedule, "17 * * * *")
        XCTAssertEqual(etc[0].user, "root")
        XCTAssertTrue(etc[0].command.hasPrefix("cd / && run-parts --report /etc/cron.hourly"))
        XCTAssertEqual(etc[2].description, "매주 일 06:47", "dow 7 은 일요일")
        let crond = report.cron.filter { $0.source == "/etc/cron.d/e2scrub_all" }
        XCTAssertEqual(crond.map(\.schedule), ["30 3 * * 0", "10 3 * * *"])
        XCTAssertEqual(report.cronBySource.map(\.source), ["crontab", "/etc/crontab", "/etc/cron.d/e2scrub_all"])
        XCTAssertEqual(report.periodic.map(\.period), ["daily"], "빈 주기는 뺀다")
        XCTAssertEqual(report.periodic[0].jobs, ["apt-compat", "dpkg"])
        XCTAssertEqual(ParsedRemoteInfo.parse(.schedule, lines: try lines("linux-schedule"), type: .linux), .schedule(report))
    }

    func testScheduleWithoutSystemdAndOtherUsers() throws {
        let report = try XCTUnwrap(ScheduleReport.parse(try lines("linux-schedule-nosystemd")))
        XCTAssertNil(report.timers, "systemd 없음")
        XCTAssertEqual(report.cron.first?.schedule, "45 23 * * 5")
        XCTAssertEqual(report.cron.first?.description, "매주 금 23:45")
        let weekly = try XCTUnwrap(report.cron.first { $0.source == "/etc/cron.d/weekly-report" })
        XCTAssertEqual(weekly.user, "tester")
        XCTAssertEqual(weekly.command, "/home/tester/weekly.sh")
        XCTAssertEqual(weekly.description, "매주 월 02:30")
        XCTAssertFalse(report.cron.contains { $0.source == "/etc/cron.d/empty" }, "주석뿐인 파일")
        XCTAssertEqual(report.periodic.first { $0.period == "daily" }?.jobs, ["apt-compat", "dpkg", "myjob"])

        // 변수 줄 · @ 주기 · 표를 찍는 옛 systemd(json 아님)
        let plain = ScheduleReport.parse(["@NOW", "100", "@TIMERS", "NEXT LEFT LAST PASSED UNIT ACTIVATES", "@CRONTAB", "MAILTO=ops@example", "@reboot /opt/agent", "*/5 * * * * /opt/check", "@ETC", "@CROND", "@PERIODIC", "@END"])
        XCTAssertNil(plain?.timers, "JSON 이 아니면 못 읽은 것")
        XCTAssertEqual(plain?.cron.map(\.user), [nil, nil])
        XCTAssertEqual(plain?.cron.map(\.schedule), ["@reboot", "*/5 * * * *"])
        XCTAssertEqual(plain?.cron.map(\.command), ["/opt/agent", "/opt/check"])
        XCTAssertEqual(ScheduleReport.parse(["@NOW", "100", "@TIMERS", "[]", "@CRONTAB", "@ETC", "@CROND", "@PERIODIC", "@END"])?.timers, [], "systemd 는 있는데 타이머가 없다")
        XCTAssertNil(ScheduleReport.parse(["garbage"]), "@NOW 가 없으면 원문")
    }

    func testCronScheduleDescriptions() {
        let cases: [(String, String?)] = [
            ("0 3 * * *", "매일 03:00"), ("*/15 * * * *", "15분마다"), ("* * * * *", "매분"), ("30 * * * *", "매시 30분"),
            ("0 */6 * * *", "6시간마다 00분"), ("30 2 * * 1", "매주 월 02:30"), ("47 6 * * 7", "매주 일 06:47"), ("52 6 1 * *", "매월 1일 06:52"),
            ("0 9 1 1 *", "매년 1월 1일 09:00"), ("@reboot", "부팅 때"), ("@daily", "매일 00:00"), ("@weekly", "매주 일 00:00"),
            ("0 9 * * 1-5", nil), ("0,30 * * * *", nil), ("5 4 * * sun", nil), ("bad", nil),
        ]
        for (schedule, expected) in cases { XCTAssertEqual(CronSchedule.describe(schedule), expected, schedule) }
    }

    // MARK: 쿼리 연결

    func testQueriesPerType() {
        XCTAssertNotNil(RemoteCommands.query(.network, for: .linux))
        XCTAssertNotNil(RemoteCommands.query(.schedule, for: .linux))
        XCTAssertNil(RemoteCommands.query(.schedule, for: .windows))
        XCTAssertEqual(RemoteCommands.query(.ports, for: .linux)?.command, RemoteCommands.linuxPorts, "Ports 는 그대로 (프로세스 칸은 뺐다)")
        XCTAssertTrue(RemoteCommands.linuxSpec.contains("LC_ALL=C timeout 8 apt list --upgradable"), "번역된 apt 출력에 안 걸리게")
        XCTAssertFalse(RemoteCommands.linuxSpec.contains("sudo") || LinuxInfoScripts.schedule.contains("sudo") || LinuxInfoScripts.network.contains("sudo"), "sudo 는 쓰지 않는다")
    }

    // MARK: 줄바꿈 없이 끝나는 파일

    /// 마지막 줄에 줄바꿈이 없는 resolv.conf: cat 으로 내면 "nameserver 9.9.9.9@END" 가 되어 @END 를 못 찾고 탭 전체가 원문으로 떨어졌다.
    /// 스크립트를 이 Mac 의 sh 로 돌려 본다 (경로만 임시 파일로 바꿈 — ip·resolvectl 은 없어도 구역 머리는 나온다)
    func testFileWithoutTrailingNewlineKeepsSections() throws {
        let file = tempPath("nexus-resolv")
        try Data("search corp.example\nnameserver 9.9.9.9".utf8).write(to: file)
        XCTAssertTrue(LinuxInfoScripts.network.contains("/etc/resolv.conf"))
        let script = LinuxInfoScripts.network.replacingOccurrences(of: "/etc/resolv.conf", with: "'\(file.path)'")
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let sections = try XCTUnwrap(ScriptSections.parse(text, dropEmpty: false), text)
        XCTAssertEqual(sections["RESOLV"], ["search corp.example", "nameserver 9.9.9.9"])
        let dns = LinuxNetwork.dns(servers: [], domains: [], resolv: sections["RESOLV"] ?? [])
        XCTAssertEqual(dns.servers, ["9.9.9.9"])
        XCTAssertEqual(dns.domains, ["corp.example"])
        // 파일 내용을 그대로 잇는 cat 이 남아 있지 않다 (crontab · /etc/crontab · cron.d 도 같은 문제)
        for script in [LinuxInfoScripts.network, LinuxInfoScripts.schedule] {
            XCTAssertFalse(script.contains("cat "), script)
        }
        XCTAssertTrue(LinuxInfoScripts.schedule.contains("crontab -l 2>/dev/null | awk 1"))
        // 예전 출력(붙어 버린 머리)은 파서가 살릴 수 없다 — 스크립트가 막아야 하는 이유
        XCTAssertNil(LinuxNetwork.parse(["@ADDR", "[]", "@RULES", "@ROUTES", "@DNS", "@DOMAIN", "@RESOLV", "nameserver 9.9.9.9@END"]))
    }
}
