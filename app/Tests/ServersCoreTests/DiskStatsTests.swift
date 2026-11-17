// DiskStats: 입출력 속도 · diskutil/tmutil 파싱 · 볼륨 분류 · 판정 (disk.zsh 와 같은 값) + 이 Mac 에서 앱 안 API 가 실제로 읽히는지.
// 픽스처는 이 Mac 의 diskutil -plist 출력 모양 그대로 (UUID·일련번호는 뺐다).

import Foundation
import XCTest
@testable import ServersCore

final class DiskStatsTests: XCTestCase {

    private func plistText(_ object: [String: Any]) throws -> String {
        String(decoding: try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0), as: UTF8.self)
    }

    private let infoDisk0: [String: Any] = [
        "MediaName": "APPLE SSD AP0512Z", "TotalSize": 500_277_792_768, "Size": 500_277_792_768, "Internal": true, "SolidState": true,
        "BusProtocol": "Apple Fabric", "SMARTStatus": "Verified", "Removable": false, "RemovableMedia": false,
        "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": ["PERCENTAGE_USED": 1, "AVAILABLE_SPARE": 100],
    ]

    private let apfsList: [String: Any] = ["Containers": [
        ["ContainerReference": "disk1", "CapacityCeiling": 524_288_000, "CapacityFree": 504_184_832, "DesignatedPhysicalStore": "disk0s1",
         "PhysicalStores": [["DeviceIdentifier": "disk0s1", "Size": 524_288_000]],
         "Volumes": [["DeviceIdentifier": "disk1s1", "Name": "iSCPreboot", "CapacityInUse": 6_275_072, "Roles": ["Preboot"], "FileVault": false]]],
        ["ContainerReference": "disk3", "CapacityCeiling": 494_384_795_648, "CapacityFree": 213_071_532_032, "DesignatedPhysicalStore": "disk0s2",
         "PhysicalStores": [["DeviceIdentifier": "disk0s2", "Size": 494_384_795_648]],
         "Volumes": [
            ["DeviceIdentifier": "disk3s1", "Name": "Macintosh HD", "CapacityInUse": 13_660_061_696, "Roles": ["System"], "FileVault": true],
            ["DeviceIdentifier": "disk3s5", "Name": "Data", "CapacityInUse": 254_978_867_200, "Roles": ["Data"], "FileVault": true],
            ["DeviceIdentifier": "disk3s6", "Name": "VM", "CapacityInUse": 20480, "Roles": ["VM"], "FileVault": false],
         ]],
    ]]

    // MARK: 입출력

    func testIORatesSkipResetsAndExcludedDisks() throws {
        let old = ["disk0": DiskCounters(bytesRead: 1000, bytesWritten: 500, opsRead: 10, opsWritten: 5),
                   "disk3": DiskCounters(bytesRead: 100, bytesWritten: 100, opsRead: 1, opsWritten: 1)]
        let new = ["disk0": DiskCounters(bytesRead: 5000, bytesWritten: 100, opsRead: 30, opsWritten: 5),   // 쓰기 카운터 리셋
                   "disk3": DiskCounters(bytesRead: 4100, bytesWritten: 100, opsRead: 21, opsWritten: 1),
                   "disk9": DiskCounters(bytesRead: 999, bytesWritten: 0, opsRead: 9, opsWritten: 0)]          // 새 디스크
        let rates = try XCTUnwrap(DiskIO.rates(old, new, seconds: 2, excluding: ["disk3"]))
        XCTAssertEqual(rates.perDisk["disk0"]?.read, 2000)
        XCTAssertEqual(rates.perDisk["disk0"]?.write, 0, "카운터가 줄면 그 구간은 0")
        XCTAssertNil(rates.perDisk["disk9"], "새로 나타난 디스크는 다음 표본부터")
        XCTAssertEqual(rates.total.read, 2000, "APFS 컨테이너(disk3)는 물리 디스크와 겹쳐 합계에서 뺀다")
        XCTAssertEqual(rates.total.ops, 10)
        XCTAssertEqual(try XCTUnwrap(rates.total.averageOpSize), 200)
        XCTAssertNil(DiskIO().averageOpSize)
        XCTAssertNil(DiskIO.rates(old, new, seconds: 0))
        XCTAssertEqual(DiskCounters.parse(["Bytes (Read)": 245_778_939_904, "Operations (Write)": 13_279_370]),
                       DiskCounters(bytesRead: 245_778_939_904, bytesWritten: 0, opsRead: 0, opsWritten: 13_279_370))
    }

    // MARK: diskutil · tmutil

    func testPhysicalDiskAndAPFSParsing() {
        let disk = PhysicalDisk.parseInfo(infoDisk0, id: "disk0")
        XCTAssertEqual(disk.name, "APPLE SSD AP0512Z")
        XCTAssertEqual(disk.size, 500_277_792_768)
        XCTAssertTrue(disk.isInternal)
        XCTAssertEqual(disk.lifeUsed, 1)
        XCTAssertFalse(disk.smartFailing)
        XCTAssertFalse(PhysicalDisk.parseInfo(["SMARTStatus": "Not Supported"], id: "disk4").smartFailing)
        XCTAssertTrue(PhysicalDisk.parseInfo(["SMARTStatus": "Failing"], id: "disk4").smartFailing)
        XCTAssertEqual(PhysicalDisk.parseWholeDisks(["WholeDisks": ["disk0", "disk4"]]), ["disk0", "disk4"])

        let containers = APFSContainer.parseList(apfsList)
        XCTAssertEqual(containers.map(\.id), ["disk1", "disk3"])
        let main = containers[1]
        XCTAssertEqual(main.used, 494_384_795_648 - 213_071_532_032)
        XCTAssertEqual(main.physicalDisks, ["disk0"])
        XCTAssertTrue(main.fileVault)
        XCTAssertEqual(main.volumes.map(\.name), ["Macintosh HD", "Data", "VM"])
        XCTAssertEqual(APFSContainer.parseList([:]), [])
    }

    func testLocalSnapshots() throws {
        let snapshots = LocalSnapshots.parse("""
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-30-101500.local
        com.apple.TimeMachine.2026-10-01-123456.local
        """)
        XCTAssertEqual(snapshots.count, 2)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: try XCTUnwrap(snapshots.latest))
        XCTAssertEqual([parts.month, parts.day, parts.hour, parts.minute], [10, 1, 12, 34])
        XCTAssertEqual(LocalSnapshots.parse("Snapshots for disk /:\n"), LocalSnapshots(count: 0, latest: nil))
    }

    func testProbeReadsDiskutilThroughRunner() async throws {
        let runner = FakeRunner()
        runner.scripted["diskutil list -plist physical"] = CommandResult(exitCode: 0, stdout: try plistText(["WholeDisks": ["disk0", "disk4"]]))
        runner.scripted["diskutil info -plist disk0"] = CommandResult(exitCode: 0, stdout: try plistText(infoDisk0))
        runner.scripted["diskutil info -plist disk4"] = CommandResult(exitCode: CommandResult.timedOutExitCode)   // 잠든 USB
        runner.scripted["diskutil apfs list -plist"] = CommandResult(exitCode: 0, stdout: try plistText(apfsList))
        let read = await DiskProbe.physicalDisks(runner: runner)
        let disks = try XCTUnwrap(read)
        XCTAssertEqual(disks.map(\.id), ["disk0", "disk4"])
        XCTAssertTrue(disks[1].unavailable, "info 를 못 읽은 디스크는 Unavailable 행으로 남긴다")
        let containers = await DiskProbe.apfsContainers(runner: runner)
        XCTAssertEqual(containers?.count, 2)

        let failing = FakeRunner()
        failing.scripted["diskutil list -plist physical"] = CommandResult(exitCode: 1)
        let none = await DiskProbe.physicalDisks(runner: failing)
        XCTAssertNil(none, "목록을 못 읽으면 nil — 화면은 이전 값을 둔다")
    }

    // MARK: 볼륨 분류 · 판정

    private func mount(_ point: String, _ device: String, fs: String = "apfs", used: UInt64 = 10, available: UInt64 = 90,
                       dontBrowse: Bool = false) -> MountedVolume {
        MountedVolume(mountPoint: point, device: device, fsType: fs, total: 100, used: used, available: available,
                      readOnly: false, local: fs != "nfs", dontBrowse: dontBrowse)
    }

    func testVolumeRowsNamesKindsAndHidden() {
        let disks = [PhysicalDisk.parseInfo(infoDisk0, id: "disk0"),
                     PhysicalDisk(id: "disk4", name: "USB", size: 64, isInternal: false, solidState: nil, bus: "USB", smart: nil, removable: true, lifeUsed: nil),
                     PhysicalDisk(id: "disk6", name: "img", size: 1, isInternal: false, solidState: nil, bus: "Disk Image", smart: nil, removable: false, lifeUsed: nil)]
        let rows = DiskInventory.rows(mounts: [
            mount("/", "/dev/disk3s1s1"),
            mount("/dev", "devfs", fs: "devfs"),
            mount("/System/Volumes/VM", "/dev/disk3s6", dontBrowse: true),
            mount("/System/Volumes/Data", "/dev/disk3s5"),
            mount("/Volumes/USB", "/dev/disk4s1", fs: "msdos"),
            mount("/Volumes/Installer", "/dev/disk6s1", fs: "hfs"),
            mount("/Users/me/OrbStack", "orbstack:/", fs: "nfs"),
        ], containers: APFSContainer.parseList(apfsList), disks: disks)
        XCTAssertEqual(rows.map(\.name), ["Macintosh HD", "VM", "Data", "USB", "Installer", "OrbStack"], "devfs 는 빼고, 봉인 스냅샷은 볼륨 이름으로")
        XCTAssertEqual(rows.map(\.kind), [.internal, .internal, .internal, .external, .image, .network])
        XCTAssertEqual(rows.map(\.hidden), [false, true, false, false, false, false], "/System/Volumes/* 는 Data 만 보인다")
        let data = DiskInventory.rows(mounts: [mount("/System/Volumes/Data", "/dev/disk3s5", dontBrowse: true)], containers: [], disks: [])
        XCTAssertEqual(data.map(\.hidden), [false], "Data 는 nobrowse 여도 보인다 (disk.zsh 와 같은 예외)")
        XCTAssertEqual(rows[0].container, "disk3")
    }

    func testHealthJudgement() {
        let disk = PhysicalDisk.parseInfo(infoDisk0, id: "disk0")
        func rows(_ fractions: [Double], hiddenFull: Bool = false, networkFull: Bool = false) -> [VolumeRow] {
            var mounts = fractions.enumerated().map { i, f in mount("/v\(i)", "/dev/disk3s\(i + 1)", used: UInt64(f * 100), available: UInt64((1 - f) * 100)) }
            if hiddenFull { mounts.append(mount("/System/Volumes/VM", "/dev/disk3s6", used: 99, available: 1)) }
            if networkFull { mounts.append(mount("/net", "host:/x", fs: "nfs", used: 99, available: 1)) }
            return DiskInventory.rows(mounts: mounts, containers: [], disks: [disk])
        }
        XCTAssertEqual(DiskHealth.judge(rows: rows([0.5]), disks: [disk]).level, .good)
        XCTAssertEqual(DiskHealth.judge(rows: rows([0.5, 0.85]), disks: [disk]).text, "공간이 차는 중")
        XCTAssertEqual(DiskHealth.judge(rows: rows([0.95]), disks: [disk]).level, .bad)
        XCTAssertEqual(DiskHealth.judge(rows: rows([0.5], hiddenFull: true, networkFull: true), disks: [disk]).level, .good,
                       "숨긴 시스템 볼륨·네트워크 마운트는 판정에서 뺀다")
        let dmg = MountedVolume(mountPoint: "/Volumes/Installer", device: "/dev/disk6s1", fsType: "hfs", total: 100, used: 100, available: 0,
                                readOnly: true, local: true, dontBrowse: false)
        XCTAssertEqual(DiskHealth.judge(rows: rows([0.5]) + DiskInventory.rows(mounts: [dmg], containers: [], disks: [disk]), disks: [disk]).level, .good,
                       "읽기 전용 이미지(늘 100%)는 판정에서 뺀다")
        let failing = PhysicalDisk.parseInfo(["SMARTStatus": "Failing"], id: "disk0")
        XCTAssertEqual(DiskHealth.judge(rows: rows([0.1]), disks: [failing]).text, "SMART 이상 (disk0)")
    }

    /// 2026-11-01 실제: 시뮬레이터 런타임 묶음(disk5)·시스템(disk7)은 볼륨이 읽기 전용으로만 붙어 97% — 회색 막대 대상.
    /// 시동 컨테이너는 System 만 읽기 전용(봉인 스냅샷 disk3s1s1)이고 Data 는 쓰기 가능 → 아님. 안 붙은 볼륨이 있어도 아님
    func testReadOnlyContainerAndCanFill() {
        func ro(_ point: String, _ device: String) -> MountedVolume {
            MountedVolume(mountPoint: point, device: device, fsType: "apfs", total: 100, used: 97, available: 3, readOnly: true, local: true, dontBrowse: true)
        }
        let rows = DiskInventory.rows(mounts: [
            ro("/Library/Developer/CoreSimulator/Volumes/iOS_22G86", "/dev/disk7s1"),
            ro("/", "/dev/disk3s1s1"),
            mount("/System/Volumes/Data", "/dev/disk3s5"),
            ro("/Volumes/Mixed RO", "/dev/disk10s1"),
            mount("/Volumes/Mixed RW", "/dev/disk10s2"),
        ], containers: [], disks: [])
        func container(_ id: String, _ volumes: [String]) -> APFSContainer {
            APFSContainer(id: id, ceiling: 100, free: 3, physicalStores: [], volumes: volumes.map { APFSVolume(id: $0, name: $0, used: 97, roles: [], fileVault: false) })
        }
        XCTAssertTrue(container("disk7", ["disk7s1"]).isReadOnly(rows: rows))
        XCTAssertFalse(container("disk3", ["disk3s1", "disk3s5"]).isReadOnly(rows: rows), "시동: System 읽기 전용 + Data 쓰기 가능")
        XCTAssertFalse(container("disk10", ["disk10s1", "disk10s2"]).isReadOnly(rows: rows), "한 볼륨이라도 쓰기 가능하면 아님")
        XCTAssertFalse(container("disk9", ["disk9s1"]).isReadOnly(rows: rows), "안 붙은 볼륨은 모른다 → 경고 색 그대로")
        XCTAssertFalse(container("disk8", []).isReadOnly(rows: rows))
        XCTAssertEqual(rows.map(\.canFill), [false, false, true, false, true])
    }

    func testRootStorageIsContainerLevelFromLiveMount() throws {
        // "/" 의 statfs: 크기 100(컨테이너) · 여유 40(컨테이너) · used 6(봉인 시스템 볼륨만)
        let mounts = [mount("/", "/dev/disk3s1s1", used: 6, available: 40), mount("/System/Volumes/Data", "/dev/disk3s5", used: 54, available: 40)]
        let rows = DiskInventory.rows(mounts: mounts, containers: [], disks: [])
        XCTAssertEqual(StorageUsage.root(rows: rows), StorageUsage(used: 60, free: 40), "크기 − 여유 (시스템 볼륨만의 6 이 아니라 컨테이너 사용)")
        XCTAssertEqual(StorageUsage.root(rows: Array(rows.dropFirst())), StorageUsage(used: 60, free: 40), "/ 가 없으면 Data")
        XCTAssertNil(StorageUsage.root(rows: []))
    }

    func testDecimalFormatAndDeviceNames() {
        XCTAssertEqual(DiskFormat.bytes(UInt64(213_071_532_032)), "213 GB")
        XCTAssertEqual(DiskFormat.bytes(UInt64(5_368_664_064)), "5.4 GB")
        XCTAssertEqual(DiskFormat.bytes(UInt64(1_500)), "1.5 KB")
        XCTAssertEqual(DiskFormat.bytes(UInt64(12)), "12 B")
        XCTAssertEqual(DiskFormat.rate(2_500_000), "2.5 MB/s")
        XCTAssertEqual(DiskInventory.wholeDisk("disk3s1s1"), "disk3")
        XCTAssertEqual(DiskInventory.volumeDevice("disk3s1s1"), "disk3s1")
        XCTAssertEqual(DiskInventory.volumeDevice("disk4"), "disk4")
    }

    // MARK: 이 Mac 에서 실제로 읽히는지

    func testProbesReadThisMac() {
        let mounts = DiskProbe.mounts()
        let root = mounts.first { $0.mountPoint == "/" }
        XCTAssertNotNil(root, "루트 볼륨")
        XCTAssertGreaterThan(root?.total ?? 0, 0)
        XCTAssertTrue(root?.bsdName?.hasPrefix("disk") ?? false)
        // 볼륨마다 df 와 같은 사용량 (APFS 캐시값이 컨테이너 합계로 나오던 것 — 루트가 281 GB 로 보였다)
        for point in ["/", "/System/Volumes/Data"] {
            guard let volume = mounts.first(where: { $0.mountPoint == point }) else { continue }
            let df = Process(); df.executableURL = URL(fileURLWithPath: "/bin/df"); df.arguments = ["-k", point]
            let pipe = Pipe(); df.standardOutput = pipe
            guard (try? df.run()) != nil else { continue }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            df.waitUntilExit()
            guard let line = text.split(separator: "\n").last, let usedKB = Double(line.split(separator: " ", omittingEmptySubsequences: true)[2]) else { continue }
            XCTAssertEqual(Double(volume.used) / 1024, usedKB, accuracy: max(usedKB * 0.02, 1024 * 64), "\(point) 사용량이 df 와 맞다")
        }
        let counters = DiskProbe.ioCounters()
        XCTAssertFalse(counters.isEmpty, "입출력 통계가 있는 디스크가 하나는 있다")
        XCTAssertTrue(counters.keys.allSatisfy { $0.hasPrefix("disk") })
    }
}
