// LinuxLive: 서버 "실시간" 탭의 원격 스크립트 출력 파싱과 계산 (stats.sh · disk.sh 와 같은 식).
// Fixtures/linux-live-{1,2}.txt 는 이 스크립트를 로컬 ubuntu:24.04 컨테이너에서 1초 간격으로 두 번 돌린 실제 출력이다
// (sh 로 바쁜 루프를 돌려 둔 채라 CPU 가 오른 프로세스가 있다). 스크립트를 고치면 다시 뜬다 — 2026-11-10 @BLK 거르기 · @CORES 더한 뒤 다시 떴다.
// 실제 서버에는 접속하지 않는다.

import Foundation
import XCTest
@testable import ServersCore

final class LinuxLiveTests: XCTestCase {
    private func fixture(_ n: Int) throws -> String {
        try fixtureText("linux-live-\(n)")
    }

    // MARK: 실제 출력

    func testParsesRealOutputAndComputesDeltas() throws {
        let first = try XCTUnwrap(LinuxRaw.parse(try fixture(1)))
        let second = try XCTUnwrap(LinuxRaw.parse(try fixture(2)))
        XCTAssertEqual(first.clockTicks, 100)
        XCTAssertEqual(first.pageSize, 4096)
        XCTAssertGreaterThan(first.cores.count, 0)
        XCTAssertNotNil(first.cpu)
        XCTAssertGreaterThan(first.memory["MemTotal"] ?? 0, 0)
        XCTAssertEqual(first.load.count, 3)
        XCTAssertNotNil(first.uptime)
        XCTAssertTrue(first.volumes.contains { $0.mountPoint == "/" }, "overlay 라도 / 는 보인다")
        XCTAssertFalse(first.volumes.contains { $0.fsType == "tmpfs" || $0.mountPoint.hasPrefix("/proc/") || $0.mountPoint.hasPrefix("/dev") },
                       "tmpfs·/proc·/dev 는 숨긴다")
        XCTAssertFalse(first.processes.isEmpty)
        // @BLK: loop·nbd·zram 은 스크립트가 읽기 전에 거른다. 남은 통째 디스크는 크기까지
        XCTAssertFalse(try fixture(1).contains("\nloop0 "))
        XCTAssertFalse(first.diskInfo.isEmpty)
        XCTAssertTrue(first.diskInfo.values.allSatisfy { $0.size > 0 })
        XCTAssertEqual(Set(first.disks.keys), Set(first.diskInfo.keys), "diskstats 는 @BLK 에 있는 통째 디스크만")

        var sampler = LinuxLiveSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        let a = sampler.step(first, at: t0)
        XCTAssertNil(a.cpu, "첫 표본은 기준값만")
        XCTAssertTrue(a.processes.allSatisfy { $0.cpu == 0 })
        XCTAssertNotNil(a.memory)
        let b = sampler.step(second, at: t0.addingTimeInterval(1))
        let cpu = try XCTUnwrap(b.cpu)
        XCTAssertTrue((0...100).contains(cpu.total))
        XCTAssertEqual(cpu.total + cpu.idle + cpu.iowait, 100, accuracy: 0.5, "바쁨 + 쉼 + iowait = 100")
        XCTAssertEqual(cpu.cores.count, second.cores.count)
        let busiest = try XCTUnwrap(b.processes.first)
        XCTAssertGreaterThan(busiest.cpu, 30, "사이에 돌린 바쁜 루프(sh)가 맨 위: \(busiest)")
        XCTAssertEqual(busiest.command, "sh")
        XCTAssertGreaterThan(busiest.memory, 0, "RSS 페이지 × PAGESIZE")
    }

    /// 물리 코어 수(@CORES): 컨테이너는 ARM VM 이라 /proc/cpuinfo 에 core id 가 없어 구역이 빈다 → "코어 N개" 그대로.
    /// awk 줄은 x86 꼴 견본(소켓 2 × 코어 2 × 스레드 2)으로 ubuntu:24.04 · busybox 컨테이너에서 4 를 내는 것을 확인했다 (2026-11-10).
    func testPhysicalCores() throws {
        let real = try XCTUnwrap(LinuxRaw.parse(try fixture(1)))
        XCTAssertTrue(try fixture(1).contains("\n@CORES\n@STAT\n"), "ARM: 구역은 있고 값은 없다")
        XCTAssertNil(real.physicalCores)
        var sampler = LinuxLiveSampler()
        let arm = sampler.step(real, at: Date())
        XCTAssertEqual(arm.coresText, "코어 \(real.cores.count)개")

        func snapshot(cores: String) -> LiveSnapshot? {
            let stat = (["cpu  1 0 1 1 0 0 0 0"] + (0..<16).map { "cpu\($0) 1 0 1 1 0 0 0 0" }).joined(separator: "\n")
            var s = LinuxLiveSampler()
            return LinuxRaw.parse("@INFO\n100\n4096\n@CORES\n\(cores)\n@STAT\n\(stat)\n@END\n").map { s.step($0, at: Date()) }
        }
        XCTAssertEqual(snapshot(cores: "8")?.coresText, "8코어 16스레드")
        XCTAssertEqual(snapshot(cores: "16")?.coresText, "코어 16개", "하이퍼스레딩이 없으면 그대로")
        XCTAssertEqual(snapshot(cores: "0")?.coresText, "코어 16개", "0 · 글자는 못 읽은 것")
        XCTAssertEqual(snapshot(cores: "x")?.coresText, "코어 16개")
        // @CORES 구역이 아예 없는 옛 출력 (OpenWrt 픽스처)
        XCTAssertNil(LinuxRaw.parse("@INFO\n100\n4096\n@END\n")?.physicalCores)
    }

    func testTruncatedOutputIsRejected() throws {
        let text = try fixture(1)
        XCTAssertNil(LinuxRaw.parse(String(text.prefix(text.count / 2))), "@END 가 없으면 잘린 출력 — 버린다")
        XCTAssertNil(LinuxRaw.parse(""))
    }

    /// 원격 스크립트 구역 나누기 (Linux Live · OpenWrt 공용): 머리줄은 "@" + 대문자·숫자만 — 데이터 줄 "@foo"·"@A b" 는 구역이 아니다
    func testScriptSections() {
        let text = "@INFO\nx\n\n@foo\n@A b\n@NET2\ny\n@END\n"
        XCTAssertEqual(ScriptSections.parse(text, dropEmpty: true), ["INFO": ["x", "@foo", "@A b"], "NET2": ["y"]])
        XCTAssertEqual(ScriptSections.parse(text, dropEmpty: false)?["INFO"], ["x", "", "@foo", "@A b"])
        XCTAssertNil(ScriptSections.parse("@INFO\nx\n", dropEmpty: true), "@END 가 없으면 잘린 출력")
    }

    func testLiveQueryPerType() {
        XCTAssertEqual(RemoteCommands.query(.live, for: .linux)?.command, "sh -s", "스크립트는 stdin 으로")
        XCTAssertEqual(RemoteCommands.query(.live, for: .linux)?.stdin, LinuxLive.script)
        XCTAssertEqual(RemoteCommands.query(.live, for: .openwrt)?.stdin, LinuxLive.script, "OpenWrt 도 같은 스크립트 (busybox)")
        XCTAssertEqual(RemoteCommands.query(.live, for: .windows)?.command.hasPrefix("powershell.exe "), true, "Windows 는 WindowsLive (2026-11-10)")
        XCTAssertEqual(RemoteCommands.Query.live.title, "Live")
    }

    /// 서버에서 도는 셸 스크립트 전부: 문법만 본다 (sh -n — 실행하지 않는다)
    func testScriptIsValidPOSIXShell() throws {
        let scripts: [(String, String)] = [
            ("LinuxLive.script", LinuxLive.script), ("LinuxInfoScripts.network", LinuxInfoScripts.network), ("LinuxInfoScripts.schedule", LinuxInfoScripts.schedule),
            ("ServicesScript.linux", ServicesScript.linux), ("OpenWrt.specScript", OpenWrt.specScript), ("OpenWrt.networkScript", OpenWrt.networkScript),
            ("OpenWrt.firewallScript", OpenWrt.firewallScript), ("OpenWrt.clientsScript", OpenWrt.clientsScript),
            ("OpenWrt.wireguardScript", OpenWrt.wireguardScript), ("OpenWrt.servicesScript", OpenWrt.servicesScript),
        ]
        for (name, script) in scripts {
            XCTAssertEqual(try shellSyntaxStatus("/bin/sh", script, quiet: true), 0, name)
        }
        // @BLK: 디스크가 아닌 장치는 읽기 전에 거르고, 값은 내장 read 로 (장치마다 cat 을 띄우지 않는다)
        XCTAssertTrue(LinuxLive.script.contains(#"case "$b" in loop*|ram*|zram*|nbd*|fd*|sr*|mmcblk*boot*|mmcblk*rpmb) continue ;; esac"#))
        XCTAssertFalse(LinuxLive.script.contains(#"$(cat "$d/"#))
        XCTAssertFalse(LinuxLive.script.contains("sudo"), "root 없이")
        XCTAssertFalse(LinuxLive.script.contains(" ps "), "procps 없이 /proc 만")
    }

    /// 네트워크 마운트는 스크립트가 로컬 df 뒤에 따로 읽어 붙인다 (머리글 없이, 열 폭이 달라진다).
    /// 아래 줄은 로컬 컨테이너 안에서 자기 자신을 NFS 로 마운트해 얻은 실제 출력 (2026-11-14) — 서버가 멈추면 nfs4 줄만 빠지고 로컬은 남았다.
    func testNetworkMountsAppendedAfterLocal() throws {
        let df = """
        overlay        overlay    214433792  10400712 204033080       5% /
        tmpfs          tmpfs          65536         0     65536       0% /dev
        127.0.0.1:/    nfs4       65536     0     65536       0% /mnt/nas
        127.0.0.1:/    nfs4       65536     0     65536       0% /mnt/share two
        //nas/public   cifs      1000 250 750 25% /mnt/smb
        """
        let raw = try XCTUnwrap(LinuxRaw.parse(output(stat: "cpu 0 0 0 1000 0 0 0 0", df: df)))
        XCTAssertEqual(raw.volumes.map(\.mountPoint), ["/", "/mnt/nas", "/mnt/share two", "/mnt/smb"])
        XCTAssertEqual(raw.volumes.map(\.fsType), ["overlay", "nfs4", "nfs4", "cifs"])
        XCTAssertEqual(raw.volumes[1].size, 65536 * 1024)
        XCTAssertEqual(raw.volumes[3].percent, 25)
        // 응답 없는 마운트: 네트워크 줄이 통째로 빠져도 로컬은 그대로
        let local = try XCTUnwrap(LinuxRaw.parse(output(stat: "cpu 0 0 0 1000 0 0 0 0", df: "overlay overlay 1000 100 900 10% /")))
        XCTAssertEqual(local.volumes.map(\.mountPoint), ["/"])
        // 스크립트가 로컬(-l)과 네트워크(-t)를 따로 읽는지 — -l 을 그냥 빼면 멈춘 NFS 하나에 디스크 전체가 빈다
        XCTAssertTrue(LinuxLive.script.contains("df -kPTl"))
        XCTAssertTrue(LinuxLive.script.contains("-t nfs -t nfs4 -t cifs"))
    }

    // MARK: 식 (stats.sh · disk.sh)

    private func output(stat: String, mem: String = "MemTotal: 1000 kB\nMemFree: 100 kB\n", disk: String = "", blk: String = "",
                        df: String = "", proc: String = "", uptime: String = "100.0") -> String {
        "@INFO\n100\n4096\nTest CPU\n@UP\n\(uptime) 50.0\n@STAT\n\(stat)\n@LOAD\n0.50 0.40 0.30 1/100 42\n@MEM\n\(mem)@PSI\n@DISK\n\(disk)\n@BLK\n\(blk)\n@DF\nFilesystem Type 1024-blocks Used Available Capacity Mounted on\n\(df)\n@TEMP\n55000\n0\n@PROC\n\(proc)\n@END\n"
    }

    func testCPUFormula() throws {
        // user nice system idle iowait irq softirq steal
        let a = try XCTUnwrap(LinuxRaw.parse(output(stat: "cpu 100 0 100 700 100 0 0 0\ncpu0 100 0 100 700 100 0 0 0")))
        let b = try XCTUnwrap(LinuxRaw.parse(output(stat: "cpu 150 10 120 780 120 5 5 10\ncpu0 150 10 120 780 120 5 5 10")))
        // Δ: user 50 nice 10 sys 20 idle 80 iowait 20 irq 5 softirq 5 steal 10 → 전체 200, 바쁨 100
        let cpu = try XCTUnwrap(LiveCPUUsage.between(try XCTUnwrap(a.cpu), try XCTUnwrap(b.cpu), oldCores: a.cores, newCores: b.cores))
        XCTAssertEqual(cpu.total, 50, accuracy: 0.001)
        XCTAssertEqual(cpu.user, 30, accuracy: 0.001, "user + nice")
        XCTAssertEqual(cpu.system, 15, accuracy: 0.001, "system + irq + softirq")
        XCTAssertEqual(cpu.iowait, 10, accuracy: 0.001, "iowait 은 바쁨이 아니다")
        XCTAssertEqual(cpu.steal, 5, accuracy: 0.001)
        XCTAssertEqual(cpu.idle, 40, accuracy: 0.001)
        XCTAssertEqual(cpu.cores, [50])
        XCTAssertNil(LiveCPUUsage.between(try XCTUnwrap(a.cpu), try XCTUnwrap(a.cpu), oldCores: [], newCores: []), "시간이 흐르지 않았으면 nil")
    }

    func testMemoryHtopFormulaAndPressure() throws {
        let kb: [String: UInt64] = ["MemTotal": 1000, "MemFree": 100, "Buffers": 50, "Cached": 300, "SReclaimable": 50, "Shmem": 20,
                                    "MemAvailable": 400, "SwapTotal": 200, "SwapFree": 150]
        let memory = try XCTUnwrap(LiveMemory.from(kb))
        XCTAssertEqual(memory.used, (1000 - 100 - 50 - 300 - 50) * 1024, "전체 − free − buffers − cached − SReclaimable")
        XCTAssertEqual(memory.cache, (300 + 50 - 20) * 1024, "cached + SReclaimable − Shmem")
        XCTAssertEqual(memory.available, 400 * 1024)
        XCTAssertEqual(memory.swapUsed, 50 * 1024)
        XCTAssertEqual(memory.pressure(psiSome: 5, psiFull: 0), .normal)
        XCTAssertEqual(memory.pressure(psiSome: 12, psiFull: 0), .warning)
        XCTAssertEqual(memory.pressure(psiSome: 12, psiFull: 10), .critical)
        XCTAssertEqual(memory.pressure(psiSome: 55, psiFull: nil), .critical)
        let tight = try XCTUnwrap(LiveMemory.from(["MemTotal": 1000, "MemFree": 10, "MemAvailable": 40]))
        XCTAssertEqual(tight.pressure(psiSome: nil, psiFull: nil), .critical, "PSI 없으면 남은 메모리 5% 미만 → 위험")
        XCTAssertNil(LiveMemory.from([:]))
        XCTAssertEqual(LiveMemory.from(["MemTotal": 100, "MemFree": 10])?.available, 10 * 1024, "MemAvailable 이 없으면 MemFree")
    }

    func testDisksVolumesTemperaturesAndProcesses() throws {
        let disk1 = """
         259       0 nvme0n1 100 0 2000 0 50 0 1000 0 0 0 0
         259       1 nvme0n1p1 100 0 2000 0 50 0 1000 0 0 0 0
           7       0 loop0 9 0 99 0 0 0 0 0 0 0 0
         253       0 dm-0 9 0 99 0 0 0 0 0 0 0 0
           8       0 sda 10 0 100 0 10 0 100 0 0 0 0
        """
        let disk2 = disk1.replacingOccurrences(of: "nvme0n1 100 0 2000 0 50 0 1000", with: "nvme0n1 110 0 4000 0 60 0 3000")
        let blk = "nvme0n1 0 0 100 \nloop0 0 0 100 \ndm-0 0 0 100 \nsda 1 1 100 "   // sda 는 RAID 구성원(slaves 있음)이라 제외
        let df = """
        /dev/nvme0n1p2 ext4 1000 900 50 95% /
        tmpfs tmpfs 100 0 100 0% /run
        /dev/loop1 squashfs 10 10 0 100% /snap/core/1
        /dev/nvme0n1p1 vfat 100 10 90 10% /boot/efi
        /dev/sdb1 ext4 1000 100 900 10% /mnt/data disk
        """
        let proc1 = "10\tS\t100\t2\t25\t500\tjava\n11\tS\t5\t1\t10\t600\tnginx: worker"
        let proc2 = "10\tR\t150\t2\t25\t500\tjava\n11\tS\t5\t1\t10\t999\tnginx: worker"   // 11 은 pid 재사용 (starttime 다름)
        let stat1 = "cpu 0 0 0 1000 0 0 0 0\ncpu0 0 0 0 500 0 0 0 0\ncpu1 0 0 0 500 0 0 0 0"
        let stat2 = "cpu 50 0 0 1150 0 0 0 0\ncpu0 50 0 0 550 0 0 0 0\ncpu1 0 0 0 600 0 0 0 0"
        let a = try XCTUnwrap(LinuxRaw.parse(output(stat: stat1, disk: disk1, blk: blk, df: df, proc: proc1)))
        let b = try XCTUnwrap(LinuxRaw.parse(output(stat: stat2, disk: disk2, blk: blk, df: df, proc: proc2)))
        XCTAssertEqual(Set(a.disks.keys), ["nvme0n1"], "통째 디스크만 (파티션·loop·dm·RAID 구성원 제외)")
        XCTAssertEqual(a.disks["nvme0n1"]?.bytesRead, 2000 * 512, "섹터는 항상 512 바이트")
        XCTAssertEqual(a.volumes.map(\.mountPoint), ["/", "/mnt/data disk"], "tmpfs·snap·/boot/efi 숨김, 공백 있는 마운트 경로")
        XCTAssertEqual(a.volumes[0].percent, 95, "df 의 Use% 처럼 used/(used+avail) 올림")
        XCTAssertEqual(a.temperatures, [55], "밀리도 → °C, 0 은 버린다")

        var sampler = LinuxLiveSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = sampler.step(a, at: t0)
        let s = sampler.step(b, at: t0.addingTimeInterval(2))
        XCTAssertEqual(s.disk?.read, 2000 * 512 / 2, "Δ바이트 / 초")
        XCTAssertEqual(s.disk?.readOps, 5)
        XCTAssertEqual(s.processes.first?.command, "java")
        XCTAssertEqual(s.processes.first?.cpu ?? 0, 50 * 2 / 200 * 100, accuracy: 0.001, "Δticks × 코어 수 / Δjiffies × 100")
        XCTAssertEqual(s.processes.first?.memory, 25 * 4096)
        XCTAssertEqual(s.processes.first?.cpuTime ?? 0, 1.5, accuracy: 0.001, "ticks / CLK_TCK")
        XCTAssertEqual(s.processes.first(where: { $0.pid == 11 })?.cpu, 0, "pid 가 재사용되면 이전 값과 빼지 않는다")
        XCTAssertEqual(s.processes.last?.command, "nginx: worker", "이름에 공백·콜론")
        XCTAssertEqual(LiveHealth.judge(s).text, "공간 부족", "/ 가 95%")
        XCTAssertEqual(s.running, 1, "상태가 R 인 프로세스 수 (stats.sh)")

        // 서버 uptime 차이가 있으면 그걸로 나눈다 — Mac 이 받은 시각(여기선 2초)은 ssh 왕복 편차가 섞인다
        var timed = LinuxLiveSampler()
        _ = timed.step(try XCTUnwrap(LinuxRaw.parse(output(stat: stat1, disk: disk1, blk: blk, uptime: "100.0"))), at: t0)
        let u = timed.step(try XCTUnwrap(LinuxRaw.parse(output(stat: stat2, disk: disk2, blk: blk, uptime: "104.0"))), at: t0.addingTimeInterval(2))
        XCTAssertEqual(u.disk?.read, 2000 * 512 / 4, "서버 시간 4초 기준")
        // 한쪽 uptime 을 못 읽었으면 Mac 시각으로 — nil 을 0 으로 치면 차이가 uptime 전체(104초)가 됐다
        for missingFirst in [true, false] {
            var before = try XCTUnwrap(LinuxRaw.parse(output(stat: stat1, disk: disk1, blk: blk, uptime: "100.0")))
            var after = try XCTUnwrap(LinuxRaw.parse(output(stat: stat2, disk: disk2, blk: blk, uptime: "104.0")))
            if missingFirst { before.uptime = nil } else { after.uptime = nil }
            var partial = LinuxLiveSampler()
            _ = partial.step(before, at: t0)
            XCTAssertEqual(partial.step(after, at: t0.addingTimeInterval(2)).disk?.read, 2000 * 512 / 2, "Mac 시각 2초 기준 (첫 표본 uptime 없음: \(missingFirst))")
        }
    }

    func testHealthOrder() {
        var s = LiveSnapshot(at: Date())
        XCTAssertEqual(LiveHealth.judge(s).level, .good)
        s.volumes = [LiveVolume(device: "d", fsType: "ext4", size: 100, used: 85, available: 15, mountPoint: "/")]
        XCTAssertEqual(LiveHealth.judge(s).text, "공간이 차는 중")
        s.pressure = .warning
        XCTAssertEqual(LiveHealth.judge(s).text, "메모리 압력 경고")
        s.pressure = .critical
        XCTAssertEqual(LiveHealth.judge(s).level, .bad)
    }
}

final class LinuxLiveExtrasTests: XCTestCase {
    func testRAIDHealthyDegradedAndRecovering() {
        let raids = LinuxRAID.parse("""
        Personalities : [raid1] [raid6] [raid5] [raid4]
        md0 : active raid1 sdb1[1] sda1[0]
              976630464 blocks super 1.2 [2/2] [UU]
              bitmap: 1/8 pages [4KB], 65536KB chunk

        md1 : active raid5 sdd1[3](F) sdc1[1] sde1[0]
              1953260544 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [UU_]

        md2 : active raid1 sdf1[2] sdg1[0]
              976630464 blocks super 1.2 [2/1] [U_]
              [==>..................]  recovery = 12.6% (123456/976630464) finish=80.2min speed=176000K/sec

        unused devices: <none>
        """.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty })
        XCTAssertEqual(raids.map(\.name), ["md0", "md1", "md2"])
        XCTAssertEqual(raids[0].level, "raid1")
        XCTAssertFalse(raids[0].degraded)
        XCTAssertEqual(raids[0].total, 2)
        XCTAssertTrue(raids[1].degraded, "(F) 구성원")
        XCTAssertEqual(raids[1].failedMembers, 1)
        XCTAssertTrue(raids[2].degraded, "(F) 없이 [U_] 로만 빠진 것도 손상")
        XCTAssertEqual(raids[2].progress, "복구 12.6%")
        XCTAssertEqual(LinuxRAID.parse([]), [])

        var s = LiveSnapshot(at: Date())
        s.raids = [raids[0]]
        XCTAssertEqual(LiveHealth.judge(s).level, .good)
        s.raids = raids
        XCTAssertEqual(LiveHealth.judge(s).text, "RAID 손상 · md1", "RAID 손상이 맨 먼저")
        s.raids = [LinuxRAID(name: "md3", level: "raid1", active: true, members: [], failedMembers: 0, total: 2, working: 2, progress: "검사 3.0%",
                             checking: true, external: false)]
        XCTAssertEqual(LiveHealth.judge(s).level, .good, "매달 도는 정기 검사는 경고가 아니다")
        s.raids = [raids[2]]
        XCTAssertEqual(LiveHealth.judge(s).text, "RAID 손상 · md2")

        let more = LinuxRAID.parse(["md127 : inactive sda[1](S) sdb[0](S)", "      5104 blocks super external:imsm",
                                    "md4 : active raid1 sdc1[1] sdd1[0]", "      100 blocks [2/2] [UU]", "        resync=PENDING",
                                    "md5 : active raid6 sde[0] sdf[1] sdg[2] sdh[3]", "      200 blocks [4/4] [UUUU]",
                                    "      [=>...................]  repair =  7.5% (1/2) finish=1min speed=1K/sec",
                                    "md6 : inactive sdi1[0](S)", "      100 blocks"])
        XCTAssertFalse(more[0].degraded, "IMSM 외부 메타데이터 컨테이너는 원래 inactive")
        XCTAssertEqual(more[1].progress, "동기화 대기")
        XCTAssertEqual(more[2].progress, "복구 검사 7.5%")
        XCTAssertFalse(more[2].checking)
        XCTAssertTrue(more[3].degraded, "보통 배열이 inactive 면 손상")
    }

    func testNetworkInterfacesRatesAndTotal() throws {
        func out(_ uptime: String, _ eth: String, _ ts: String) -> String {
            "@INFO\n@UP\n\(uptime) 1.0\n@NET\neth0 1 up 1000 \(eth)\ndocker0 0 up - 500 500\nveth12ab 0 up 10000 9 9\ntailscale0 0 unknown - \(ts)\nenp3s0 1 down - 0 0\n@END\n"
        }
        var sampler = LinuxLiveSampler()
        _ = sampler.step(try XCTUnwrap(LinuxRaw.parse(out("10.0", "1000 2000", "100 100"))), at: Date())
        let s = sampler.step(try XCTUnwrap(LinuxRaw.parse(out("12.0", "5000 4000", "300 500"))), at: Date())
        XCTAssertEqual(s.interfaces.map(\.name), ["eth0", "tailscale0", "enp3s0"], "물리 + VPN 만 (docker0·veth 숨김)")
        let eth = try XCTUnwrap(s.interfaces.first)
        XCTAssertEqual(eth.rx, 2000, "Δ바이트 / 서버 시간 2초")
        XCTAssertEqual(eth.tx, 1000)
        XCTAssertEqual(eth.speedMbps, 1000)
        XCTAssertNil(s.interfaces[2].speedMbps, "꺼진 랜카드는 속도 모름")
        XCTAssertEqual(s.networkTotal, LiveTraffic(rx: 2000, tx: 1000), "합계는 물리만 — tailscale0 은 같은 트래픽을 한 번 더 센다")
        let odd = try XCTUnwrap(LinuxRaw.parse("@INFO\n@NET\neth1 1 up 4294967295 1 1\ntunl0 0 unknown - 1 1\n@END\n"))
        XCTAssertNil(odd.interfaces.first?.speedMbps, "옛 커널의 모름 값")
        XCTAssertFalse(odd.interfaces[1].shown, "Calico tunl0 은 VPN 이 아니다")
    }

    func testDiskInfoFrequencyThrottle() throws {
        let text = "@INFO\n100\n4096\n@UP\n10.0 1.0\n@STAT\ncpu 1 0 1 10 0 0 0 0\ncpu0 1 0 1 10 0 0 0 0\n@BLK\nnvme0n1 0 0 2000409264 Samsung SSD 980 PRO 1TB\nsda 0 1 3907029168 WDC WD40EFRX\nloop0 0 0 100\nsdb 1 0 100 member\n@MD\n@FREQ\n3200000\n2400000\n@THROTTLE\n2\n1\n@PROC\n@END\n"
        let raw = try XCTUnwrap(LinuxRaw.parse(text))
        XCTAssertEqual(raw.diskInfo["nvme0n1"], LiveDiskInfo(rotational: false, size: 2_000_409_264 * 512, model: "Samsung SSD 980 PRO 1TB"), "모델에 공백")
        XCTAssertEqual(raw.diskInfo["sda"]?.rotational, true, "HDD")
        XCTAssertNil(raw.diskInfo["loop0"], "loop 제외")
        XCTAssertNil(raw.diskInfo["sdb"], "RAID 구성원(slaves) 제외")
        var sampler = LinuxLiveSampler()
        let s = sampler.step(raw, at: Date())
        XCTAssertEqual(s.frequencyAverage ?? 0, 2800, accuracy: 0.001, "kHz → MHz 평균")
        XCTAssertEqual(s.frequencyMax ?? 0, 3200, accuracy: 0.001)
        XCTAssertEqual(s.throttleEvents, 3, "코어별 합")
        let none = try XCTUnwrap(LinuxRaw.parse("@INFO\n@THROTTLE\n@END\n"))
        XCTAssertNil(none.throttleEvents, "파일이 없으면(ARM·VM) 모름")
    }
}
