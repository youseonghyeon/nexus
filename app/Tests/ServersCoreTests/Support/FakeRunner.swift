// ServersCore 검증. 실제 명령은 하나도 실행하지 않는다: FakeRunner 가 호출을 기록하고 정해진 응답을 돌려준다.

import Foundation
import XCTest
@testable import ServersCore

let fixture = """
# 테스트용
[network:lan]
service=Test Ethernet
routes=192.0.2.0/255.255.255.0, 198.51.100.0/255.255.255.0
wait_attempts=2
wait_interval=0

[group:acme]
theme=on
db_jump=was
db_host=db.example.test
db_port=5432
db_local=15432
db_name=testdb

[nexus]
group=home
network=tailscale
type=linux
ip=100.64.0.1
user=tester
port=2222
role=Home server   # 값 뒤 주석
env=HOST

[win]
group=home
network=tailscale
type=windows
ip=100.64.0.2
user=tester
port=2222
wol_mac=00:11:22:33:44:55
wol_via=nexus

[ghost]
group=home
network=tailscale
type=linux
ip=100.64.0.9
user=tester
port=2222
check=ssh

[was]
group=acme
network=lan
type=linux
ip=192.0.2.22
user=tester
port=2222
role=WAS server
env=PROD
"""

final class FakeRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let arguments: [String]; var environment: [String: String] = [:] }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var tailscaleBackend = "Running"
    var peers: [(ip: String, online: Bool)] = [("100.64.0.1", true), ("100.64.0.2", true)]
    var lanEnabled = true
    var adapterPresent = true
    var missing: Set<String> = []
    var sshExit: Int32 = 0
    /// ping 응답 (확인 실패 뒤 켜져 있는지 가를 때만 보낸다)
    var pingOK = true
    var sshStderr = ""
    /// ifconfig <장치> 출력. nil 이면 명령 없음(127)
    var ifconfigOutput: String?
    /// "실행파일 인자 …" → 응답. 아래 고정 응답보다 먼저 본다 (diskutil·tmutil·system_profiler 같은 명령별 픽스처)
    var scripted: [String: CommandResult] = [:]
    /// TCP 프로브(check=tcp) 가짜: 호출을 기록하고 tcpOK 를 돌려준다. nc 는 더 이상 쓰지 않는다 (장치에 묶을 수 없어 소켓 프로브로 바꿈).
    var tcpOK = true
    struct Probe: Hashable { let host: String; let port: Int; let device: String? }
    private(set) var probes: [Probe] = []
    var tcpProbe: TCPProbeFunction {
        { [self] host, port, _, device in
            lock.withLock { probes.append(Probe(host: host, port: port, device: device)) }
            return tcpOK
        }
    }

    func hasExecutable(_ name: String) -> Bool { !missing.contains(name) }

    func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        lock.withLock { calls.append(Call(executable: executable, arguments: arguments, environment: environment)) }
        if let reply = scripted[([executable] + arguments).joined(separator: " ")] { return reply }
        switch executable {
        case "tailscale":
            let peerJSON = peers.enumerated().map { i, p in
                #""p\#(i)":{"TailscaleIPs":["\#(p.ip)"],"Online":\#(p.online)}"#
            }.joined(separator: ",")
            return CommandResult(exitCode: 0, stdout: #"{"BackendState":"\#(tailscaleBackend)","Peer":{\#(peerJSON)}}"#)
        case "networksetup":
            switch arguments.first {
            case "-listnetworkserviceorder": return CommandResult(exitCode: 0, stdout: "(\(lanEnabled ? "1" : "*")) Test Ethernet\n(Hardware Port: Ethernet, Device: en9)\n")
            case "-listallhardwareports": return CommandResult(exitCode: 0, stdout: adapterPresent ? "Hardware Port: Ethernet\nDevice: en9\n" : "")
            case "-getinfo": return CommandResult(exitCode: 0, stdout: "Manual Configuration\nIP address: 10.50.10.17\nSubnet mask: 255.255.255.0\nRouter: 10.50.10.254\n")
            default: return CommandResult(exitCode: 0, stdout: "Wi-Fi\n\(lanEnabled ? "" : "*")Test Ethernet\n")
            }
        case "ipconfig": return CommandResult(exitCode: 0, stdout: "10.50.10.17\n")
        case "ssh": return CommandResult(exitCode: sshExit, stderr: sshStderr)
        case "ping": return CommandResult(exitCode: pingOK ? 0 : 2)
        case "ifconfig":
            if let ifconfigOutput { return CommandResult(exitCode: 0, stdout: ifconfigOutput) }
            // 출력을 정하지 않았으면 ifconfig 전체는 어댑터(en9)가 꽂혔는지만 (adapterPresent) — 내부망 어댑터 판정이 이걸 본다
            guard arguments.isEmpty else { return CommandResult(exitCode: 127) }
            return CommandResult(exitCode: 0, stdout: "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\n" + (adapterPresent ? "en9: flags=8863<UP> mtu 1500\n\tstatus: inactive\n" : ""))
        default: return CommandResult(exitCode: 127)
        }
    }
}
