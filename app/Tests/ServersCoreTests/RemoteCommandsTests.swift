// RemoteCommands: 원격 조회 명령 (관리자 스크립트는 LanCommandsTests).

import Foundation
import XCTest
@testable import ServersCore

final class RemoteCommandsTests: XCTestCase {

    // 2단계: 원격 명령어셋
    func testRemoteCommands() {
        XCTAssertEqual(RemoteCommands.query(.spec, for: .linux)?.command, "bash -s")
        XCTAssertNotNil(RemoteCommands.query(.spec, for: .linux)?.stdin)
        let winSpec = RemoteCommands.query(.spec, for: .windows)!
        XCTAssertNil(winSpec.stdin)
        XCTAssertTrue(winSpec.command.hasPrefix("powershell.exe "))
        // Windows Spec 출력(형식 고정)을 Linux 와 같은 파서가 읽는다: 메모리·디스크 게이지, 가동 시간
        let winLines = ["HOSTNAME     DESKTOP-1", "OS           Microsoft Windows 11 Pro (build 26100)", "ARCH         64-bit",
                        "CPU          AMD Ryzen 7 5800X (16 threads)", "MEMORY       31.9Gi total, 20.5Gi available",
                        "ROOT DISK    931G total, 412G used, 519G available (44%)", "UPTIME       3 days, 4 hours, 12 minutes"]
        let items = RemoteInfo.parseSpec(winLines)
        XCTAssertEqual(items.map(\.key), ["HOSTNAME", "OS", "ARCH", "CPU", "MEMORY", "ROOT DISK", "UPTIME"])
        XCTAssertEqual(items.first { $0.key == "MEMORY" }?.usage.map { ($0 * 100).rounded() }, 36)
        XCTAssertEqual(items.first { $0.key == "ROOT DISK" }?.usage, 0.44)
        let ps = RemoteCommands.query(.services, for: .windows)!.command
        XCTAssertTrue(ps.hasPrefix("powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "))
        // base64 → UTF-16LE 디코드가 원문을 돌려준다
        let b64 = String(ps.split(separator: " ").last!)
        let decoded = String(data: Data(base64Encoded: b64)!, encoding: .utf16LittleEndian)!
        XCTAssertTrue(decoded.hasPrefix("[Console]::OutputEncoding = [Text.UTF8Encoding]::new(); Write-Output \"## FAILED\""))
        let cleaned = RemoteCommands.cleanOutput("Tailscale   Running\r\n#< CLIXML\r\n<Objs Version=\"1.1.0.1\"></Objs>\r\nsshd\tRunning\r\n", type: .windows)
        XCTAssertEqual(cleaned, ["Tailscale   Running", "sshd    Running", ""])
        XCTAssertEqual(RemoteCommands.wakeOnLan(mac: "AA:BB:CC:DD:EE:FF"), "wakeonlan AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(RemoteCommands.wakeOnLan(mac: "AA:BB:CC:DD:EE:FF", iface: "br-lan"), "etherwake -i br-lan AA:BB:CC:DD:EE:FF")
    }

    /// PowerShell 은 별칭 → 함수 순으로 이름을 푼다. 스크립트 함수가 기본 별칭과 같은 이름이면 그 별칭이 대신 돈다
    /// (2026-10-05 win Spec 메모리가 "total, available" 로 빈 원인: function Gi 가 gi=Get-Item 에 가렸다).
    func testWindowsScriptFunctionsDoNotShadowAliases() {
        let aliases: Set<String> = [
            "ac", "cat", "cd", "chdir", "clc", "clear", "clhy", "cli", "clp", "cls", "clv", "cnsn", "compare", "copy", "cp", "cpi", "cpp",
            "curl", "cvpa", "dbp", "del", "diff", "dir", "dnsn", "ebp", "echo", "epal", "epcsv", "epsn", "erase", "etsn", "exsn", "fc",
            "fhx", "fl", "foreach", "ft", "fw", "gal", "gbp", "gc", "gcb", "gci", "gcm", "gcs", "gdr", "ghy", "gi", "gin", "gjb", "gl",
            "gm", "gmo", "gp", "gps", "gpv", "group", "gsn", "gsnp", "gsv", "gtz", "gu", "gv", "gwmi", "h", "history", "icm", "iex",
            "ihy", "ii", "ipal", "ipcsv", "ipmo", "ipsn", "irm", "ise", "iwmi", "iwr", "kill", "lp", "ls", "man", "md", "measure", "mi",
            "mount", "move", "mp", "mv", "nal", "ndr", "ni", "nmo", "npssc", "nsn", "nv", "ogv", "oh", "popd", "ps", "pushd", "pwd", "r",
            "rbp", "rcjb", "rcsn", "rd", "rdr", "ren", "ri", "rjb", "rm", "rmdir", "rmo", "rni", "rnp", "rp", "rsn", "rsnp", "rujb", "rv",
            "rvpa", "rwmi", "sajb", "sal", "saps", "sasv", "sbp", "sc", "scb", "select", "set", "shcm", "si", "sl", "sleep", "sls", "sort",
            "sp", "spjb", "spps", "spsv", "start", "stz", "sujb", "sv", "swmi", "tee", "trcm", "type", "wget", "where", "wjb", "write",
        ]
        for script in [RemoteCommands.windowsSpec, RemoteCommands.windowsPorts, ServicesScript.windows, WindowsLive.script, WindowsNetwork.script] {
            for match in script.matches(of: /function\s+([A-Za-z0-9_-]+)/) {
                XCTAssertFalse(aliases.contains(String(match.1).lowercased()), "PowerShell 기본 별칭과 겹치는 함수 이름: \(match.1)")
            }
        }
        XCTAssertTrue(RemoteCommands.windowsSpec.contains("function ToGi("), "이 테스트가 함수를 실제로 찾는지")
        // 2026-11-10: function R 은 r=Invoke-History 에 가려 값 줄이 전부 "위치 매개 변수를 찾을 수 없습니다" 였다
        XCTAssertTrue(WindowsLive.script.contains("function NxRow "))
    }

    /// 탭마다 서버로 보내는 명령과 stdin (종류 × 탭 전부) — 조립하는 코드를 정리해도 보내는 글은 그대로여야 한다
    func testQueryCommandTable() {
        func ps(_ script: String) -> String { RemoteCommands.powerShellCommand(script) }
        let table: [ServerType: [RemoteCommands.Query: (command: String, stdin: String?)]] = [
            .linux: [.spec: ("bash -s", RemoteCommands.linuxSpec), .services: ("sh -s", ServicesScript.linux), .ports: (RemoteCommands.linuxPorts, nil),
                     .live: ("sh -s", LinuxLive.script), .network: ("sh -s", LinuxInfoScripts.network), .schedule: ("sh -s", LinuxInfoScripts.schedule)],
            .windows: [.spec: (ps(RemoteCommands.windowsSpec), nil), .services: (ps(ServicesScript.windows), nil), .ports: (ps(RemoteCommands.windowsPorts), nil),
                       .live: (ps(WindowsLive.script), nil), .network: (ps(WindowsNetwork.script), nil)],
            .openwrt: [.spec: ("sh -s", OpenWrt.specScript), .network: ("sh -s", OpenWrt.networkScript), .firewall: ("sh -s", OpenWrt.firewallScript),
                       .clients: ("sh -s", OpenWrt.clientsScript), .wireguard: ("sh -s", OpenWrt.wireguardScript), .services: ("sh -s", OpenWrt.servicesScript),
                       .ports: (OpenWrt.portsCommand, nil), .live: ("sh -s", LinuxLive.script)],
        ]
        for type in [ServerType.linux, .windows, .openwrt] {
            for query in RemoteCommands.Query.allCases {
                let got = RemoteCommands.query(query, for: type), want = table[type]?[query]
                XCTAssertEqual(got?.command, want?.command, "\(type) \(query)")
                XCTAssertEqual(got?.stdin, want?.stdin, "\(type) \(query)")
                XCTAssertEqual(got == nil, want == nil, "\(type) \(query)")
            }
        }
    }

    func testOutputParsersReadTheLastNonEmptyLine() {
        XCTAssertEqual(RemoteCommands.parseSize("motd\n  1024  \n\n \n"), 1024)
        XCTAssertNil(RemoteCommands.parseSize("1024\nbye"))
        XCTAssertNil(RemoteCommands.parseSize("0"))
        XCTAssertNil(RemoteCommands.parseSize(" \n"))
        XCTAssertEqual(RemoteCommands.parseWriteAccess("banner\r\n writable \r\n"), .writable)
        XCTAssertEqual(RemoteCommands.parseWriteAccess("writable\nreadonly\n\n"), .readonly)
        XCTAssertNil(RemoteCommands.parseWriteAccess(""))
        XCTAssertNil(RemoteCommands.parseWriteAccess("writable\nother"))
        XCTAssertEqual(RemoteCommands.parseHome("motd\n /home/me \n\n", type: .linux), "/home/me")
        XCTAssertNil(RemoteCommands.parseHome("/home/me\nbye", type: .linux))
        XCTAssertNil(RemoteCommands.parseHome("\n \n", type: .openwrt))
    }
}
