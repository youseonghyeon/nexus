// 디스크 화면(볼륨·APFS·물리 디스크·입출력) 수집기. 계산은 ServersCore DiskStats.
// 화면이 떠 있고 창이 보일 때만 설정의 간격(기본 2초 — AppPreferences.diskInterval)마다 입출력·마운트를, 30초마다 diskutil·tmutil 인벤토리를 읽는다 (DiskDashboardView 의 .sampling).
// 사이드바 요약(여유 공간)은 창이 보일 때 AppModel 의 5초 갱신이 마운트만(full: false) 읽는다.

import Foundation
import ServersCore

@MainActor
final class DiskMonitor: ObservableObject {
    static let historyLength = 60
    static let inventoryInterval: TimeInterval = 30

    @Published private(set) var rows: [VolumeRow] = []
    @Published private(set) var disks: [PhysicalDisk] = []
    @Published private(set) var containers: [APFSContainer] = []
    @Published private(set) var snapshots: LocalSnapshots?
    @Published private(set) var io: DiskIO?
    @Published private(set) var perDisk: [String: DiskIO] = [:]
    /// 부팅 뒤 누적 (디스크별)
    @Published private(set) var counters: [String: DiskCounters] = [:]
    @Published private(set) var readHistory: [Double] = []
    @Published private(set) var writeHistory: [Double] = []
    @Published private(set) var swap: SwapUsage?
    @Published private(set) var at: Date?
    @Published private(set) var inventoryAt: Date?
    /// 마지막 diskutil apfs list 를 못 읽었다 ("없습니다" 와 구분)
    @Published private(set) var containersFailed = false

    private var lastCounters: (values: [String: DiskCounters], at: Date)?
    private var mounts: [MountedVolume] = []
    private var sampling = false
    /// 인벤토리(diskutil·tmutil)는 따로 돈다 — 잠든 USB 로 오래 걸려도 2초 입출력·마운트 수집을 막지 않게
    private var inventoryRunning = false

    func sample(full: Bool, runner: any CommandRunner) async {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }
        let now = Date()
        mounts = DiskProbe.mounts()
        rebuildRows()
        at = now
        guard full else { return }

        let current = DiskProbe.ioCounters()
        // 화면을 떠났다 오면 직전 표본이 낡았다 — 그 긴 구간의 평균을 지금 값처럼 그리지 않는다
        if let last = lastCounters, now.timeIntervalSince(last.at) > 6 {
            lastCounters = nil
            readHistory = []
            writeHistory = []
        }
        if let last = lastCounters,
           let rates = DiskIO.rates(last.values, current, seconds: now.timeIntervalSince(last.at), excluding: Set(containers.map(\.id))) {
            io = rates.total
            perDisk = rates.perDisk
            append(&readHistory, rates.total.read)
            append(&writeHistory, rates.total.write)
        }
        lastCounters = (current, now)
        counters = current
        swap = SystemProbe.swap()
        if !inventoryRunning, inventoryAt.map({ now.timeIntervalSince($0) >= Self.inventoryInterval }) ?? true {
            inventoryRunning = true
            Task {
                await refreshInventory(runner: runner)
                inventoryRunning = false
            }
        }
    }

    /// diskutil·tmutil (명령마다 10초 제한). 못 읽은 항목은 이전 값을 둔다.
    private func refreshInventory(runner: any CommandRunner) async {
        if let read = await DiskProbe.physicalDisks(runner: runner) { disks = read }
        if let read = await DiskProbe.apfsContainers(runner: runner) {
            containers = read
            containersFailed = false
        } else {
            containersFailed = true
        }
        if let read = await DiskProbe.localSnapshots(runner: runner) { snapshots = read }
        inventoryAt = Date()
        rebuildRows()
    }

    private func rebuildRows() {
        rows = DiskInventory.rows(mounts: mounts, containers: containers, disks: disks)
    }

    private func append(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: 판정 (사이드바·머리글 공통)

    var storage: StorageUsage? { StorageUsage.root(rows: rows) }

    var health: (level: SystemHealth.Level, text: String) { DiskHealth.judge(rows: rows, disks: disks) }

    /// "213 GB 남음 · 57% 사용"
    var summary: String {
        StorageUsage.sidebarSummary(storage)
    }

    /// 루트 볼륨이 든 컨테이너 · 그 물리 디스크
    var rootContainer: APFSContainer? {
        rows.first { $0.mount.mountPoint == "/" }?.container.flatMap { id in containers.first { $0.id == id } }
    }

    var bootDisk: PhysicalDisk? {
        rootContainer?.physicalDisks.first.flatMap { id in disks.first { $0.id == id } }
    }
}
