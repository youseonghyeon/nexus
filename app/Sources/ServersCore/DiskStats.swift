// 이 Mac 의 디스크·볼륨·APFS·입출력 (디스크 화면). ~/.tools/disk.zsh 를 옮긴 것.
//   빠른 값(2초): 앱 안 API — IOKit IOBlockStorageDriver 통계(입출력) · getmntinfo(MNT_NOWAIT, 네트워크 마운트도 막히지 않는다).
//   느린 값(30초): diskutil list/info/apfs list -plist · tmutil listlocalsnapshots — 명령마다 시간 제한, 실패하면 이전 값을 둔다.
//   계산(DiskIO·DiskInventory·DiskHealth)은 순수 함수라 테스트한다. 단위는 10진(KB·MB·GB) — disk.zsh 와 같다.

import Darwin
import Foundation
import IOKit

// MARK: 입출력

public struct DiskCounters: Sendable, Equatable {
    public let bytesRead, bytesWritten, opsRead, opsWritten: UInt64
    public init(bytesRead: UInt64, bytesWritten: UInt64, opsRead: UInt64, opsWritten: UInt64) {
        self.bytesRead = bytesRead; self.bytesWritten = bytesWritten; self.opsRead = opsRead; self.opsWritten = opsWritten
    }

    /// IOBlockStorageDriver 의 "Statistics" 사전
    public static func parse(_ stats: [String: Any]) -> DiskCounters {
        func value(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
        return DiskCounters(bytesRead: value("Bytes (Read)"), bytesWritten: value("Bytes (Write)"),
                            opsRead: value("Operations (Read)"), opsWritten: value("Operations (Write)"))
    }
}

/// 초당 값
public struct DiskIO: Sendable, Equatable {
    public var read: Double = 0
    public var write: Double = 0
    public var readOps: Double = 0
    public var writeOps: Double = 0
    public init() {}
    public var ops: Double { readOps + writeOps }
    /// 한 번에 오간 평균 크기 (바이트). 작업이 없으면 nil.
    public var averageOpSize: Double? { ops > 0 ? (read + write) / ops : nil }

    /// 카운터가 줄었으면(리셋) 그 구간은 0 — disk.zsh 와 같다
    public static func between(_ old: DiskCounters, _ new: DiskCounters, seconds: Double) -> DiskIO? {
        guard seconds > 0 else { return nil }
        func rate(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) / seconds : 0 }
        var io = DiskIO()
        io.read = rate(old.bytesRead, new.bytesRead)
        io.write = rate(old.bytesWritten, new.bytesWritten)
        io.readOps = rate(old.opsRead, new.opsRead)
        io.writeOps = rate(old.opsWritten, new.opsWritten)
        return io
    }

    /// 디스크별 속도와 합계. excluding(APFS 컨테이너 같은 합성 디스크)은 물리 디스크와 겹치므로 합계에서 뺀다. 새로 나타난 디스크는 다음 표본부터.
    public static func rates(_ old: [String: DiskCounters], _ new: [String: DiskCounters], seconds: Double,
                             excluding: Set<String> = []) -> (total: DiskIO, perDisk: [String: DiskIO])? {
        guard seconds > 0 else { return nil }
        var total = DiskIO()
        var perDisk: [String: DiskIO] = [:]
        for (disk, counters) in new {
            guard let before = old[disk], let io = between(before, counters, seconds: seconds) else { continue }
            perDisk[disk] = io
            guard !excluding.contains(disk) else { continue }
            total.read += io.read; total.write += io.write; total.readOps += io.readOps; total.writeOps += io.writeOps
        }
        return (total, perDisk)
    }
}

// MARK: 물리 디스크 · APFS (diskutil -plist)

public struct PhysicalDisk: Sendable, Equatable, Identifiable {
    public let id: String          // disk0
    public let name: String        // APPLE SSD AP0512Z
    public let size: UInt64
    public let isInternal: Bool
    public let solidState: Bool?
    public let bus: String?        // Apple Fabric · USB · PCI-Express
    public let smart: String?      // Verified · Not Supported · Failing …
    public let removable: Bool
    /// SMART 수명 사용률 % (NVMe PERCENTAGE_USED)
    public let lifeUsed: Int?
    /// diskutil info 를 못 읽었다 (잠든 외장 디스크 등)
    public let unavailable: Bool

    public init(id: String, name: String, size: UInt64, isInternal: Bool, solidState: Bool?, bus: String?, smart: String?,
                removable: Bool, lifeUsed: Int?, unavailable: Bool = false) {
        self.id = id; self.name = name; self.size = size; self.isInternal = isInternal; self.solidState = solidState; self.bus = bus
        self.smart = smart; self.removable = removable; self.lifeUsed = lifeUsed; self.unavailable = unavailable
    }

    /// SMART 가 문제를 알렸는가 (Verified·Not Supported·모름은 문제 아님)
    public var smartFailing: Bool {
        guard let smart, !smart.isEmpty else { return false }
        return smart != "Verified" && smart != "Not Supported"
    }

    public var isDiskImage: Bool { bus == "Disk Image" }

    public static func parseInfo(_ plist: [String: Any], id: String) -> PhysicalDisk {
        let smartKeys = plist["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any]
        return PhysicalDisk(id: id, name: plist["MediaName"] as? String ?? id,
                            size: (plist["TotalSize"] as? NSNumber ?? plist["Size"] as? NSNumber)?.uint64Value ?? 0,
                            isInternal: plist["Internal"] as? Bool ?? false, solidState: plist["SolidState"] as? Bool,
                            bus: plist["BusProtocol"] as? String, smart: plist["SMARTStatus"] as? String,
                            removable: (plist["RemovableMedia"] as? Bool ?? false) || (plist["Removable"] as? Bool ?? false),
                            lifeUsed: (smartKeys?["PERCENTAGE_USED"] as? NSNumber)?.intValue)
    }

    /// diskutil list -plist physical 의 WholeDisks
    public static func parseWholeDisks(_ plist: [String: Any]) -> [String] {
        plist["WholeDisks"] as? [String] ?? []
    }
}

public struct APFSVolume: Sendable, Equatable, Identifiable {
    public let id: String          // disk3s1
    public let name: String
    public let used: UInt64
    public let roles: [String]
    public let fileVault: Bool
}

public struct APFSContainer: Sendable, Equatable, Identifiable {
    public let id: String          // disk3
    public let ceiling: UInt64
    public let free: UInt64
    public let physicalStores: [String]   // disk0s2
    public let volumes: [APFSVolume]

    public var used: UInt64 { ceiling > free ? ceiling - free : 0 }
    public var usedFraction: Double { ceiling > 0 ? Double(used) / Double(ceiling) : 0 }
    /// 시스템·데이터 볼륨에 FileVault 가 켜져 있는가
    public var fileVault: Bool { volumes.contains { $0.fileVault } }
    /// 물리 저장소가 있는 디스크 (disk0s2 → disk0)
    public var physicalDisks: [String] { physicalStores.map(DiskInventory.wholeDisk) }

    /// 볼륨이 모두 읽기 전용으로 붙어 있다 — 시뮬레이터 런타임 같은 디스크 이미지 컨테이너라 늘 가득 차 있다 (막대 회색).
    /// 하나라도 쓰기 가능하거나 안 붙어 있으면 false (시동 컨테이너는 System 만 읽기 전용이고 Data 는 쓰기 가능)
    public func isReadOnly(rows: [VolumeRow]) -> Bool {
        !volumes.isEmpty && volumes.allSatisfy { volume in
            rows.contains { $0.mount.device == "/dev/\(volume.id)" && $0.mount.readOnly }
        }
    }

    public static func parseList(_ plist: [String: Any]) -> [APFSContainer] {
        (plist["Containers"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["ContainerReference"] as? String else { return nil }
            let volumes = (c["Volumes"] as? [[String: Any]] ?? []).compactMap { v -> APFSVolume? in
                guard let device = v["DeviceIdentifier"] as? String else { return nil }
                return APFSVolume(id: device, name: v["Name"] as? String ?? device, used: (v["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0,
                                  roles: v["Roles"] as? [String] ?? [], fileVault: v["FileVault"] as? Bool ?? false)
            }
            let stores = (c["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
            return APFSContainer(id: id, ceiling: (c["CapacityCeiling"] as? NSNumber)?.uint64Value ?? 0,
                                 free: (c["CapacityFree"] as? NSNumber)?.uint64Value ?? 0,
                                 physicalStores: stores.isEmpty ? [c["DesignatedPhysicalStore"] as? String].compactMap { $0 } : stores,
                                 volumes: volumes)
        }
    }
}

/// Time Machine 로컬 스냅샷 (tmutil listlocalsnapshots /)
public struct LocalSnapshots: Sendable, Equatable {
    public let count: Int
    public let latest: Date?

    /// "com.apple.TimeMachine.2026-10-01-123456.local" 줄들
    public static func parse(_ text: String) -> LocalSnapshots {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dates = text.split(separator: "\n").compactMap { line -> Date? in
            guard let range = line.range(of: #"com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})"#, options: .regularExpression) else { return nil }
            let stamp = line[range].dropFirst("com.apple.TimeMachine.".count)
            return formatter.date(from: String(stamp))
        }
        return LocalSnapshots(count: dates.count, latest: dates.max())
    }
}

// MARK: 마운트된 볼륨 (getmntinfo)

public struct MountedVolume: Sendable, Equatable {
    public let mountPoint: String
    public let device: String      // /dev/disk3s1s1 · //user@host/share · map auto_home
    public let fsType: String
    public let total: UInt64
    public let used: UInt64
    public let available: UInt64
    public let readOnly: Bool
    public let local: Bool
    /// MNT_DONTBROWSE (nobrowse) — Finder 에 안 보이는 볼륨
    public let dontBrowse: Bool

    public init(mountPoint: String, device: String, fsType: String, total: UInt64, used: UInt64, available: UInt64,
                readOnly: Bool, local: Bool, dontBrowse: Bool) {
        self.mountPoint = mountPoint; self.device = device; self.fsType = fsType; self.total = total; self.used = used
        self.available = available; self.readOnly = readOnly; self.local = local; self.dontBrowse = dontBrowse
    }

    /// df 의 Capacity 와 같은 사용률: used / (used + available). APFS 는 전체가 컨테이너 크기라 이 식이 맞다.
    public var usedFraction: Double {
        let denominator = Double(used) + Double(available)
        return denominator > 0 ? Double(used) / denominator : 0
    }

    /// /dev/disk3s1s1 → disk3s1s1
    public var bsdName: String? { device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : nil }
}

public enum VolumeKind: String, Sendable, Equatable {
    case `internal` = "내장", external = "외장", network = "네트워크", image = "이미지", other = "기타"
}

public struct VolumeRow: Sendable, Equatable, Identifiable {
    public var id: String { mount.mountPoint }
    public let mount: MountedVolume
    public let name: String
    public let kind: VolumeKind
    /// /System/Volumes/*·nobrowse (둘 다 Data 는 제외 — disk.zsh 와 같다) — 기본으로 접는다
    public let hidden: Bool
    /// 이 볼륨이 든 APFS 컨테이너 (disk3)
    public let container: String?

    /// 채워질 수 있는 볼륨인가 — 읽기 전용·이미지(설치 DMG·시뮬레이터 런타임은 내용에 맞춰 만들어 늘 가득)는 아니다.
    /// 판정(DiskHealth)과 사용량 막대 색(회색) 공통
    public var canFill: Bool { kind != .image && !mount.readOnly }
}

public enum DiskInventory {
    static let skippedFileSystems: Set<String> = ["devfs", "autofs", "fdesc", "nullfs"]
    static let networkFileSystems: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs"]

    /// disk3s1s1 · disk0s2 · disk3 → disk3 · disk0 · disk3
    public static func wholeDisk(_ bsd: String) -> String {
        guard let range = bsd.range(of: #"^disk\d+"#, options: .regularExpression) else { return bsd }
        return String(bsd[range])
    }

    /// 봉인된 시스템 스냅샷(disk3s1s1)은 볼륨(disk3s1)으로
    public static func volumeDevice(_ bsd: String) -> String {
        guard let range = bsd.range(of: #"^disk\d+s\d+"#, options: .regularExpression) else { return bsd }
        return String(bsd[range])
    }

    public static func rows(mounts: [MountedVolume], containers: [APFSContainer], disks: [PhysicalDisk]) -> [VolumeRow] {
        let volumeNames = Dictionary(containers.flatMap { c in c.volumes.map { ($0.id, $0.name) } }, uniquingKeysWith: { a, _ in a })
        let containerOf = Dictionary(containers.flatMap { c in c.volumes.map { ($0.id, c) } }, uniquingKeysWith: { a, _ in a })
        let diskByID = Dictionary(disks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return mounts.compactMap { mount in
            guard !skippedFileSystems.contains(mount.fsType) else { return nil }
            let volume = mount.bsdName.map(volumeDevice)
            let container = volume.flatMap { containerOf[$0] }
            let name = volume.flatMap { volumeNames[$0] }
                ?? (mount.mountPoint == "/" ? "/" : (mount.mountPoint as NSString).lastPathComponent)
            let kind: VolumeKind
            if networkFileSystems.contains(mount.fsType) {
                kind = .network
            } else if let physical = (container?.physicalDisks.first ?? mount.bsdName.map(wholeDisk)).flatMap({ diskByID[$0] }) {
                kind = physical.isDiskImage ? .image : (physical.isInternal ? .internal : .external)
            } else {
                kind = .other
            }
            let isData = mount.mountPoint == "/System/Volumes/Data"
            let hidden = !isData && (mount.mountPoint.hasPrefix("/System/Volumes/") || mount.dontBrowse)
            return VolumeRow(mount: mount, name: name, kind: kind, hidden: hidden, container: container?.id)
        }
    }
}

/// 이 Mac 의 저장 공간 (머리글·사이드바): 루트("/")가 든 APFS 컨테이너 단위 — disk.zsh 의 "루트 컨테이너 N% used · X free".
/// "/" 마운트의 statfs 는 크기·여유가 컨테이너 값이라 그대로 쓴다 (5초마다 새 값 — diskutil 은 30초에 한 번이라 쓰지 않는다).
/// "/" 의 used 는 봉인된 시스템 볼륨만의 양이라 쓰지 않고 크기 − 여유로 낸다.
public struct StorageUsage: Sendable, Equatable {
    public let used: UInt64
    public let free: UInt64
    public var total: UInt64 { used + free }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func root(rows: [VolumeRow]) -> StorageUsage? {
        guard let mount = (rows.first { $0.mount.mountPoint == "/" } ?? rows.first { $0.mount.mountPoint == "/System/Volumes/Data" })?.mount else { return nil }
        return StorageUsage(used: mount.total > mount.available ? mount.total - mount.available : 0, free: mount.available)
    }
}

// MARK: 판정 · 표시

public enum DiskHealth {
    /// disk.zsh health_status: SMART 이상이면 빨강, 보이는 볼륨 최고 사용률 90% 이상 빨강 · 80% 이상 노랑.
    /// 네트워크 마운트(OrbStack NFS 등)는 이 Mac 의 디스크가 아니고, 읽기 전용·이미지(설치용 DMG 는 늘 100%)는 채워질 일이 없어 판정에서 뺀다.
    public static func judge(rows: [VolumeRow], disks: [PhysicalDisk]) -> (level: SystemHealth.Level, text: String) {
        if let failing = disks.first(where: \.smartFailing) { return (.bad, "SMART 이상 (\(failing.id))") }
        let worst = rows.filter { !$0.hidden && $0.kind != .network && $0.canFill }.map(\.mount.usedFraction).max() ?? 0
        if worst >= 0.9 { return (.bad, "공간 부족") }
        if worst >= 0.8 { return (.warn, "공간이 차는 중") }
        return (.good, "정상")
    }
}

public enum DiskFormat {
    /// 10진 단위: 100 이상은 정수, 그 아래는 소수 한 자리
    public static func bytes(_ value: Double) -> String { ByteFormat.decimal(value) }

    public static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    public static func rate(_ perSecond: Double) -> String { bytes(perSecond) + "/s" }
}

// MARK: 읽기

public enum DiskProbe {
    /// 디스크(BSD 이름)별 누적 입출력. IOBlockStorageDriver 의 자식 IOMedia 이름으로 바로 짝짓는다 (이름 비교 없이).
    public static func ioCounters() -> [String: DiskCounters] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var out: [String: DiskCounters] = [:]
        while true {
            let driver = IOIteratorNext(iterator)
            guard driver != 0 else { break }
            defer { IOObjectRelease(driver) }
            guard let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            var child: io_registry_entry_t = 0
            guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &child) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(child) }
            guard let bsd = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            out[bsd] = DiskCounters.parse(stats)
        }
        return out
    }

    /// 마운트 목록. MNT_NOWAIT 라 멈춘 네트워크 마운트도 캐시값으로 바로 돌아온다. getmntinfo 버퍼는 libc 가 쥐므로 메인 스레드에서만 부른다.
    public static func mounts() -> [MountedVolume] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { volume(buffer[$0]) }
    }

    /// 볼륨이 실제로 쓰는 양. APFS 는 statfs 의 여유 블록이 컨테이너 기준이라 blocks − free 가 컨테이너 합계가 된다
    /// (/ 가 281 GB 로 보였다). df 처럼 getattrlist(ATTR_VOL_SPACEUSED) 로 읽는다. APFS 에만 — 다른 파일시스템은 blocks − free 가 맞고,
    /// 사용자 공간 파일시스템·네트워크 위 이미지는 속성 조회가 멈출 수 있다 (메인 스레드에서 부른다).
    static func spaceUsed(_ mountPoint: String) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 16)   // u_int32_t 길이 + off_t (4바이트 정렬로 붙어 있다)
        guard getattrlist(mountPoint, &request, &buffer, buffer.count, 0) == 0 else { return nil }
        let length = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length >= 12 else { return nil }   // 속성이 빠져 왔으면 0 이 아니라 nil (blocks − free 로)
        let used = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return used >= 0 ? UInt64(used) : nil
    }

    static func volume(_ s: statfs) -> MountedVolume {
        func text<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let block = UInt64(s.f_bsize)
        let mountPoint = text(s.f_mntonname)
        let local = s.f_flags & UInt32(MNT_LOCAL) != 0
        let fsType = text(s.f_fstypename)
        let blocksUsed = s.f_blocks > s.f_bfree ? (s.f_blocks - s.f_bfree) * block : 0
        let used = (local && fsType == "apfs" ? spaceUsed(mountPoint) : nil) ?? blocksUsed
        return MountedVolume(mountPoint: mountPoint, device: text(s.f_mntfromname), fsType: fsType,
                             total: s.f_blocks * block, used: used, available: s.f_bavail * block,
                             readOnly: s.f_flags & UInt32(MNT_RDONLY) != 0, local: local,
                             dontBrowse: s.f_flags & UInt32(MNT_DONTBROWSE) != 0)
    }

    static func plist(_ result: CommandResult) -> [String: Any]? {
        guard result.ok, let data = result.stdout.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// 물리 디스크 목록 + 디스크마다 info. 목록을 못 읽으면 nil (이전 값 유지). info 를 못 읽은 디스크는 unavailable 행.
    public static func physicalDisks(runner: any CommandRunner) async -> [PhysicalDisk]? {
        guard let list = plist(await runner.run("diskutil", ["list", "-plist", "physical"], timeout: 10)) else { return nil }
        var disks: [PhysicalDisk] = []
        for id in PhysicalDisk.parseWholeDisks(list) {
            if let info = plist(await runner.run("diskutil", ["info", "-plist", id], timeout: 10)) {
                disks.append(PhysicalDisk.parseInfo(info, id: id))
            } else {
                disks.append(PhysicalDisk(id: id, name: id, size: 0, isInternal: false, solidState: nil, bus: nil, smart: nil,
                                          removable: false, lifeUsed: nil, unavailable: true))
            }
        }
        return disks
    }

    public static func apfsContainers(runner: any CommandRunner) async -> [APFSContainer]? {
        plist(await runner.run("diskutil", ["apfs", "list", "-plist"], timeout: 10)).map(APFSContainer.parseList)
    }

    public static func localSnapshots(runner: any CommandRunner) async -> LocalSnapshots? {
        let result = await runner.run("tmutil", ["listlocalsnapshots", "/"], timeout: 10)
        return result.ok ? LocalSnapshots.parse(result.stdout) : nil
    }
}
