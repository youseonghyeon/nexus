// 디스크 화면: 사이드바 LOCAL 의 Disk 행. ~/.tools/disk.zsh 를 옮긴 것 (읽기 전용 — 꺼내기·마운트 해제 같은 동작은 원본에도 없다).
// 머리글(부팅 디스크 체인 · 상태) → 수치 타일(읽기·쓰기·IOPS·여유 공간·스왑) → 볼륨 → APFS 컨테이너 → 물리 디스크.
// 화면이 떠 있고 창이 보일 때만 설정한 간격(AppPreferences.diskInterval, 기본 2초)마다 입출력·마운트, 30초마다 diskutil 인벤토리를 읽는다 (DiskMonitor).

import ServersCore
import SwiftUI

struct DiskDashboardView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var monitor: DiskMonitor
    @AppStorage(AppPreferences.diskInterval.key) private var interval = AppPreferences.diskInterval.defaultValue
    /// /System/Volumes/* · nobrowse 볼륨도 보기 (disk.zsh 의 a)
    @State private var showHidden = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HeroCard { header } strip: { metrics }
                volumesCard
                containersCard
                disksCard
            }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sampling(every: { AppSettings.interval(AppPreferences.diskInterval) }) { await monitor.sample(full: true, runner: model.runner) }
    }

    // MARK: 머리글

    private var header: some View {
        let health = monitor.health
        // 루트 볼륨 이름(Macintosh HD)은 APFS 인벤토리를 읽은 뒤에 안다 — 그 전엔 "Disk" (사이드바 행 이름)
        let rootName = monitor.rows.first { $0.mount.mountPoint == "/" }?.name
        return LocalHeader(title: rootName.flatMap { $0 == "/" ? nil : $0 } ?? "Disk",
                           subtitle: subtitle, tone: monitor.rows.isEmpty ? .muted : health.level.tone, conclusion: health.text,
                           checkedAt: monitor.at, interval: "\(Int(AppPreferences.diskInterval.resolve(interval)))초 간격")
    }

    /// "APPLE SSD AP0512Z · 500 GB · 내장 SSD · Apple Fabric · disk0 → disk3"
    private var subtitle: String {
        guard let disk = monitor.bootDisk else { return "이 Mac 의 디스크" }
        var parts = [disk.name, DiskFormat.bytes(disk.size), diskKind(disk)]
        if let bus = disk.bus { parts.append(bus) }
        if let container = monitor.rootContainer { parts.append("\(disk.id) → \(container.id)") }
        return parts.joined(separator: " · ")
    }

    private func diskKind(_ disk: PhysicalDisk) -> String {
        let place = disk.isDiskImage ? "이미지" : (disk.isInternal ? "내장" : "외장")
        switch disk.solidState {
        case true?: return "\(place) SSD"
        case false?: return "\(place) HDD"
        case nil: return place
        }
    }

    // MARK: 수치 타일

    private var metrics: some View {
        MetricGrid {
            MetricTile(title: "읽기", value: monitor.io.map { DiskFormat.rate($0.read) } ?? "–", caption: monitor.io == nil ? "측정 중…" : nil,
                       tone: .muted, systemImage: "arrow.down.doc") {
                Sparkline(values: monitor.readHistory, tone: .good)
            }
            MetricTile(title: "쓰기", value: monitor.io.map { DiskFormat.rate($0.write) } ?? "–", caption: monitor.io == nil ? "측정 중…" : nil,
                       tone: .muted, systemImage: "arrow.up.doc") {
                Sparkline(values: monitor.writeHistory, tone: .good)
            }
            MetricTile(title: "IOPS", value: monitor.io.map { String(format: "%.0f", $0.ops) } ?? "–", unit: "/s",
                       caption: monitor.io?.averageOpSize.map { "평균 \(DiskFormat.bytes($0))/회" } ?? (monitor.io == nil ? "측정 중…" : "오간 작업 없음"),
                       tone: .muted, systemImage: "speedometer")
            storageTile
            MetricTile(title: "Swap", value: monitor.swap.map { $0.used > 0 ? DiskFormat.bytes($0.used) : "0" } ?? "–",
                       caption: monitor.swap.map { $0.total > 0 ? "전체 \(DiskFormat.bytes($0.total))\($0.encrypted ? " · 암호화" : "")" : "사용 안 함" },
                       tone: .muted, systemImage: "arrow.left.arrow.right")
        }
    }

    @ViewBuilder
    private var storageTile: some View {
        if let storage = monitor.storage {
            let level = SystemHealth.level(storage.usedFraction * 100, .usage)
            MetricTile(title: "여유 공간", value: DiskFormat.bytes(storage.free),
                       caption: "\(DiskFormat.bytes(storage.total)) 중 \(Int((storage.usedFraction * 100).rounded()))% 사용",
                       tone: level.valueTone, systemImage: "internaldrive") {
                MeterBar(level: storage.usedFraction, tone: level.tone)
            }
        } else {
            MetricTile(title: "여유 공간", value: "–", caption: "확인 중…", tone: .muted, systemImage: "internaldrive")
        }
    }

    // MARK: 볼륨

    private var volumesCard: some View {
        let visible = monitor.rows.filter { showHidden || !$0.hidden }
        let hiddenCount = monitor.rows.filter(\.hidden).count
        return InfoCard(title: "볼륨") {
            if monitor.rows.isEmpty {
                Text("확인 중…").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("이름"); Text("마운트"); Text("종류"); Text("FS")
                            Text("사용 · 여유").gridColumnAlignment(.trailing)
                            Text("사용률")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
                        ForEach(visible) { row in volumeRow(row) }
                    }
                    if hiddenCount > 0 {
                        Button(showHidden ? "시스템 볼륨 숨기기" : "시스템 볼륨 \(hiddenCount)개 보기") { showHidden.toggle() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private func volumeRow(_ row: VolumeRow) -> some View {
        let fraction = row.mount.usedFraction
        let level = row.kind == .network ? .good : SystemHealth.level(fraction * 100, .usage)
        let fixed = row.kind != .network && !row.canFill   // 읽기 전용·이미지: 늘 가득이라 경고 색 없이 회색
        return GridRow {
            HStack(spacing: 6) {
                Text(row.name).fontWeight(.medium).lineLimit(1)
                if row.mount.readOnly { StatusChip(text: "읽기 전용", tone: .muted) }
            }
            Text(row.mount.mountPoint).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                .help(row.mount.device)
            Text(row.kind.rawValue).foregroundStyle(.secondary)
            Text(row.mount.fsType).font(.callout.monospaced()).foregroundStyle(.secondary)
            // 사용률은 df 처럼 사용 / (사용 + 여유) — APFS 는 크기가 컨테이너 전체라 "사용 / 크기" 로 쓰면 % 와 안 맞아 보인다
            Text("\(DiskFormat.bytes(row.mount.used)) · \(DiskFormat.bytes(row.mount.available))").monospacedDigit()
            HStack(spacing: 8) {
                MeterBar(level: fraction, tone: fixed ? .muted : level.tone).frame(width: 90)
                Text("\(Int((fraction * 100).rounded()))%").monospacedDigit().foregroundStyle(level == .good || fixed ? Color.secondary : level.tone.color)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: APFS 컨테이너

    private var containersCard: some View {
        InfoCard(title: "APFS 컨테이너") {
            if monitor.containers.isEmpty {
                Text(monitor.inventoryAt == nil ? "확인 중…" : (monitor.containersFailed ? "APFS 컨테이너를 읽지 못했습니다." : "APFS 컨테이너가 없습니다."))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(monitor.containers) { container in containerBlock(container) }
                }
            }
        }
    }

    private func containerBlock(_ container: APFSContainer) -> some View {
        let isRoot = container.id == monitor.rootContainer?.id
        let level = SystemHealth.level(container.usedFraction * 100, .usage)
        let readOnly = container.isReadOnly(rows: monitor.rows)   // 시뮬레이터 런타임 같은 이미지 — 늘 가득이라 회색
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(container.id).fontWeight(.medium)
                Text(([DiskFormat.bytes(container.ceiling), "볼륨 \(container.volumes.count)개"] + container.physicalStores.map { "\($0) 위" })
                    .joined(separator: " · ")).foregroundStyle(.secondary)
                if isRoot { StatusChip(text: "시동", tone: .muted) }
                if readOnly { StatusChip(text: "읽기 전용", tone: .muted) }
                Spacer()
                Text(container.fileVault ? "FileVault 켜짐" : "FileVault 꺼짐").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                MeterBar(level: container.usedFraction, tone: readOnly ? .muted : level.tone)
                Text("\(DiskFormat.bytes(container.used)) 사용 · \(DiskFormat.bytes(container.free)) 여유").font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary).fixedSize()
            }
            Text(container.volumes.map { "\($0.name) \(DiskFormat.bytes($0.used))" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            if isRoot { Text(snapshotText).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var snapshotText: String {
        guard let snapshots = monitor.snapshots else { return "Time Machine 로컬 스냅샷: –" }
        guard snapshots.count > 0, let latest = snapshots.latest else { return "Time Machine 로컬 스냅샷 없음" }
        return "Time Machine 로컬 스냅샷 \(snapshots.count)개 · 최신 \(latest.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: 물리 디스크

    private var disksCard: some View {
        InfoCard(title: "물리 디스크") {
            if monitor.disks.isEmpty {
                Text(monitor.inventoryAt == nil ? "확인 중…" : "물리 디스크를 읽지 못했습니다.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(monitor.disks) { disk in diskBlock(disk) }
                }
            }
        }
    }

    private func diskBlock(_ disk: PhysicalDisk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(disk.unavailable ? "\(disk.id) · 읽지 못했습니다" : disk.name).fontWeight(.medium)
                if !disk.unavailable {
                    Text([disk.id, DiskFormat.bytes(disk.size), diskKind(disk), disk.bus].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let smart = disk.smart {
                    StatusChip(text: smart == "Verified" ? "SMART 정상" : "SMART \(smart)",
                               tone: disk.smartFailing ? .bad : .muted)
                }
            }
            let lines = [disk.lifeUsed.map { "건강 상태 \(max(0, 100 - $0))%" },   // NVMe 수명 사용률은 100 을 넘을 수 있다 (수명을 넘겨 씀 → 0%)
                         monitor.counters[disk.id].map { "누적 읽기 \(DiskFormat.bytes($0.bytesRead)) · 쓰기 \(DiskFormat.bytes($0.bytesWritten))" },   // 내장은 부팅 뒤, 외장은 연결 뒤부터
                         monitor.disks.count > 1 ? monitor.perDisk[disk.id].map { "지금 ↓ \(DiskFormat.rate($0.read)) · ↑ \(DiskFormat.rate($0.write))" } : nil]
                .compactMap { $0 }
            if !lines.isEmpty {
                Text(lines.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
