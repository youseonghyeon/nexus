// 서버 정보 카드의 Live 탭 (리눅스 · Windows 서버 — Windows 에 없는 줄은 snapshot.system 으로 뺀다): 요약 수치 → 코어 → 메모리 · 디스크(RAID·장치) → 네트워크 → 상위 프로세스.
// ~/.tools/linux/stats.sh · disk.sh 를 옮긴 것. 카드 안이라 타일 바탕 없이 줄과 막대로만. 탭이 보이는 동안만 읽는다 (ServerLiveMonitor).

import ServersCore
import SwiftUI

struct ServerLiveView: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @ObservedObject var monitor: ServerLiveMonitor
    @AppStorage(AppPreferences.coreAnimationKey) private var coreAnimation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = monitor.error {
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(StatusTone.warn.color)
                    if monitor.authBlocked {
                        Button("다시 시도") { Task { await monitor.retry(server, model: model) } }
                            .buttonStyle(CompactButtonStyle())
                    }
                }
            }
            if let s = monitor.snapshot {
                summary(s)
                metrics(s)
                Divider().opacity(0.4)
                cores(s)
                Divider().opacity(0.4)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        memory(s).frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity, alignment: .topLeading)
                        disks(s).frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        memory(s)
                        disks(s)
                    }
                }
                if !s.interfaces.isEmpty {
                    Divider().opacity(0.4)
                    network(s)
                }
                Divider().opacity(0.4)
                processes(s)
            } else if monitor.error == nil {
                Text(model.isReachable(server) ? "읽는 중…" : "지금은 가져올 수 없습니다.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .sampling(every: { AppSettings.interval(AppPreferences.serverLiveInterval) }) {
            if model.isReachable(server) { await monitor.sample(server, model: model) }
        }
    }

    // MARK: 요약 줄

    /// Windows 는 부하 평균 · iowait · 버퍼/캐시 구분 · 프로세스 상태 글자가 없다
    private func windows(_ s: LiveSnapshot) -> Bool { s.system == .windows }

    private func summary(_ s: LiveSnapshot) -> some View {
        let health = LiveHealth.judge(s)
        return HStack(spacing: 8) {
            Circle().fill(health.level.tone.color).frame(width: 8, height: 8)
            Text(health.text).fontWeight(.medium)
            Text([s.model, s.coresText, s.uptime.map { "가동 \(SystemFormat.uptime($0))" },
                  windows(s) ? "프로세스 \(s.processCount)개 · 스레드 \(s.threads)" : "프로세스 \(s.processCount)개 · 실행 \(s.running) · 스레드 \(s.threads)"].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(s.at.formatted(date: .omitted, time: .standard)) · \(Int(AppSettings.interval(AppPreferences.serverLiveInterval)))초 간격")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: 수치

    private func metrics(_ s: LiveSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 12) {
            let cpuLevel = SystemHealth.level(s.cpu?.total ?? 0, .cpu)
            LiveMetric(title: "CPU", value: s.cpu.map { "\(Int($0.total.rounded()))%" } ?? "–", tone: cpuLevel.valueTone,
                       caption: s.cpu.map { "User \(Int($0.user.rounded())) · System \(Int($0.system.rounded()))" + (windows(s) ? "" : " · iowait \(Int($0.iowait.rounded()))") } ?? "측정 중…") {
                Sparkline(values: monitor.cpuHistory, tone: cpuLevel.tone, ceiling: 100)
            }
            let memoryLevel = SystemHealth.level((s.memory?.usedFraction ?? 0) * 100, .usage)
            LiveMetric(title: "메모리", value: s.memory.map { "\(Int(($0.usedFraction * 100).rounded()))%" } ?? "–", tone: memoryLevel.valueTone,
                       caption: s.memory.map { "\(SystemFormat.bytes($0.used)) / \(SystemFormat.bytes($0.total))" }) {
                MeterBar(level: s.memory?.usedFraction ?? 0, tone: memoryLevel.tone)
            }
            if !windows(s) {
                LiveMetric(title: "부하", value: s.load.first.map { String(format: "%.2f", $0) } ?? "–",
                           caption: s.load.count == 3 ? String(format: "5분 %.2f · 15분 %.2f", s.load[1], s.load[2]) : nil) { EmptyView() }
            }
            LiveMetric(title: "디스크 읽기 · 쓰기", value: s.disk.map { DiskFormat.rate($0.read) } ?? "–",
                       caption: s.disk.map { "쓰기 \(DiskFormat.rate($0.write)) · \(Int($0.ops.rounded())) IOPS" } ?? "측정 중…") { EmptyView() }
            if !s.interfaces.isEmpty {
                LiveMetric(title: "네트워크 받기 · 보내기", value: s.networkTotal.map { DiskFormat.rate($0.rx) } ?? "–",
                           caption: s.networkTotal.map { "보내기 \(DiskFormat.rate($0.tx))" } ?? "측정 중…") { EmptyView() }
            }
            if let average = s.frequencyAverage {
                // 열 스로틀은 부팅 뒤 누적 (x86) — 0 이 아니면 노랑
                let throttled = (s.throttleEvents ?? 0) > 0
                LiveMetric(title: "CPU 클럭", value: String(format: "%.1f GHz", average / 1000),
                           tone: throttled ? .warn : .muted,
                           caption: [s.frequencyMax.map { String(format: "최고 %.1f GHz", $0 / 1000) },
                                     s.throttleEvents.map { $0 > 0 ? "Throttle \($0)회" : "Throttle 없음" }].compactMap { $0 }.joined(separator: " · ")) { EmptyView() }
            }
            // GPU (Windows · nvidia-smi): 사용률과 VRAM, 온도와 전력
            ForEach(s.gpus) { gpu in
                let level = SystemHealth.level(gpu.utilization ?? 0, .cpu)
                LiveMetric(title: s.gpus.count > 1 ? gpu.name : "GPU", value: gpu.utilization.map { "\(Int($0.rounded()))%" } ?? "–", tone: level.valueTone,
                           caption: gpu.memoryUsed.flatMap { used in gpu.memoryTotal.map { "VRAM \(SystemFormat.bytes(used)) / \(SystemFormat.bytes($0))" } }) {
                    MeterBar(level: (gpu.utilization ?? 0) / 100, tone: level.tone)
                }
                if let temperature = gpu.temperature {
                    let heat = SystemHealth.level(temperature, .temperature)
                    LiveMetric(title: "GPU 온도", value: "\(Int(temperature.rounded()))°C", tone: heat.valueTone,
                               caption: gpu.power.map { "\(Int($0.rounded())) W" }) {
                        MeterBar(level: temperature / 110, tone: heat.tone)
                    }
                }
            }
            if let temperature = s.temperatureMax {
                let level = SystemHealth.level(temperature, .temperature)
                LiveMetric(title: "CPU 온도", value: "\(Int(temperature.rounded()))°C", tone: level.valueTone,
                           caption: s.temperatureAverage.map { "평균 \(Int($0.rounded()))°" }) {
                    MeterBar(level: temperature / 110, tone: level.tone)
                }
            }
        }
    }

    // MARK: 코어

    private func cores(_ s: LiveSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("코어").font(.caption).foregroundStyle(.secondary)
            if let values = s.cpu?.cores, !values.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        let level = SystemHealth.level(value, .cpu)
                        HStack(spacing: 8) {
                            Text("C\(index)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                            MeterBar(level: value / 100, tone: level.tone,
                                     animation: coreAnimation ? .easeInOut(duration: 0.4) : nil)
                            Text("\(Int(value.rounded()))%").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            } else {
                Text("측정 중…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 메모리 · 디스크

    private func memory(_ s: LiveSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("메모리").font(.caption).foregroundStyle(.secondary)
            if let m = s.memory {
                // 구성 막대: 사용 · 공유 · 버퍼 · 캐시 (나머지는 여유). 리눅스는 캐시가 필요하면 비워지므로 "사용"과 나눠 봐야 실제 여유가 보인다.
                // 시스템 화면 메모리 카드와 같은 무채색 농도 (구성은 상태가 아니라 항목 구분)
                // Windows 는 사용 · 사용 가능 둘뿐 (대기 캐시는 "사용 가능" 에 들어 있다)
                StackedBar(segments: windows(s) ? [.init(id: "used", value: Double(m.used), opacity: Self.shades.used)] : [
                    .init(id: "used", value: Double(m.used), opacity: Self.shades.used),
                    .init(id: "shared", value: Double(m.shared), opacity: Self.shades.shared),
                    .init(id: "buffers", value: Double(m.buffers), opacity: Self.shades.buffers),
                    .init(id: "cache", value: Double(m.cache), opacity: Self.shades.cache),
                ], total: Double(m.total))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Used", m.used, of: m.total, shade: Self.shades.used)
                    if windows(s) {
                        row("Available", m.available, of: m.total, shade: 0)
                    } else {
                        row("Shared", m.shared, of: m.total, shade: Self.shades.shared)
                        row("Buffers", m.buffers, of: m.total, shade: Self.shades.buffers)
                        row("Cache", m.cache, of: m.total, shade: Self.shades.cache)
                        row("Free", m.free, of: m.total, shade: 0)
                        row("Available", m.available, of: m.total, shade: nil)
                    }
                    GridRow {
                        HStack(spacing: 6) { Color.clear.frame(width: 9, height: 9); Text(windows(s) ? "Page file" : "Swap").foregroundStyle(.secondary) }   // 네모 자리만큼 맞춘다
                        Text(m.swapTotal > 0 ? "\(SystemFormat.bytes(m.swapUsed)) / \(SystemFormat.bytes(m.swapTotal))" : "사용 안 함").monospacedDigit()
                            .gridCellColumns(2)
                    }
                    if m.swapTotal > 0 {
                        // 스왑이 차는 건 메모리가 모자란다는 신호 — 사용량 색 (정상 초록 · 80% 노랑 · 90% 빨강)
                        let fraction = Double(m.swapUsed) / Double(m.swapTotal)
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            MeterBar(level: fraction, tone: SystemHealth.level(fraction * 100, .usage).tone).gridCellColumns(2)
                        }
                    }
                    GridRow {
                        HStack(spacing: 6) { Color.clear.frame(width: 9, height: 9); Text("Pressure").foregroundStyle(.secondary) }   // 네모 자리만큼 맞춘다
                        Text(s.pressure.text).foregroundStyle(s.pressure == .normal ? Color.primary : (s.pressure == .critical ? StatusTone.bad.color : StatusTone.warn.color))
                            .gridCellColumns(2)
                    }
                }
                .font(.callout)
            }
        }
    }

    private static let shades: (used: Double, shared: Double, buffers: Double, cache: Double) = (0.7, 0.5, 0.35, 0.2)

    /// shade: 막대 몫과 같은 농도의 네모 (0 = 빈 칸 테두리 · 여유, nil = 네모 없음 · 사용 가능처럼 막대에 없는 값)
    private func row(_ label: String, _ value: UInt64, of total: UInt64, shade: Double?) -> some View {
        GridRow {
            HStack(spacing: 6) {
                if let shade {
                    Swatch(opacity: shade).overlay(shade == 0 ? RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.5)) : nil)
                } else {
                    Color.clear.frame(width: 9, height: 9)
                }
                Text(label).foregroundStyle(.secondary)
            }
            Text(SystemFormat.bytes(value)).monospacedDigit().gridColumnAlignment(.trailing)
            Text(total > 0 ? "\(Int((Double(value) / Double(total) * 100).rounded()))%" : "–").monospacedDigit().foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
    }

    private func disks(_ s: LiveSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("디스크").font(.caption).foregroundStyle(.secondary)
            // RAID 는 손상이 가장 중요한 경고라 맨 위 (disk.sh 도 공간보다 먼저 본다)
            ForEach(s.raids) { raid in
                HStack(spacing: 6) {
                    Text(raid.name).fontWeight(.medium)
                    Text([raid.level, raid.total.flatMap { t in raid.working.map { "\($0)/\(t)" } }].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if raid.degraded {
                        StatusChip(text: raid.failedMembers > 0 ? "손상 · 고장 \(raid.failedMembers)" : "손상", tone: .bad)
                    } else if let progress = raid.progress {
                        StatusChip(text: progress, tone: raid.checking ? .muted : .warn)   // 정기 검사는 경고가 아니다
                    } else {
                        StatusChip(text: "정상", tone: .good)
                    }
                }
                .font(.callout)
            }
            if s.volumes.isEmpty {
                Text("볼륨을 읽지 못했습니다.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(s.volumes) { volume in
                let level = SystemHealth.level(Double(volume.percent), .usage)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(volume.mountPoint).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text(volume.fsType).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(DiskFormat.bytes(volume.used)) / \(DiskFormat.bytes(volume.size))").monospacedDigit().foregroundStyle(.secondary)
                        Text("\(volume.percent)%").monospacedDigit().foregroundStyle(level == .good ? Color.primary : level.tone.color)
                            .frame(width: 38, alignment: .trailing)
                    }
                    MeterBar(level: Double(volume.percent) / 100, tone: level.tone)
                }
                .font(.callout)
                .help(volume.device)
            }
            // 장치: 모델 · SSD/HDD · 크기 · 지금 속도 (disk.sh 의 장치 목록)
            ForEach(s.diskInfo.keys.sorted(), id: \.self) { name in
                let info = s.diskInfo[name]
                let io = s.perDisk[name]
                Text([name, info?.model, info?.rotational.map { $0 ? "HDD" : "SSD" }, info.map { DiskFormat.bytes($0.size) },
                      info?.healthy.map { $0 ? "상태 정상" : "상태 이상" },
                      io.map { "↓ \(DiskFormat.rate($0.read)) ↑ \(DiskFormat.rate($0.write))" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: 네트워크

    private func network(_ s: LiveSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("네트워크").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(s.interfaces) { i in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(i.state == "up" || i.state == "unknown" ? StatusTone.good.color : StatusTone.muted.color).frame(width: 6, height: 6)
                            Text(i.name).fontWeight(.medium)
                        }
                        Text([i.physical ? nil : "VPN·가상", i.state == "down" ? "연결 안 됨" : nil, i.speedMbps.map(Ethernet.speedLabel(mbps:))]
                            .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                        Text("↓ \(DiskFormat.rate(i.rx))").monospacedDigit().gridColumnAlignment(.trailing)
                        Text("↑ \(DiskFormat.rate(i.tx))").monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: 프로세스

    private func processes(_ s: LiveSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("프로세스").font(.caption).foregroundStyle(.secondary)
                Spacer()
                PlainSegmented(items: [ServerLiveMonitor.ProcessSort.cpu, .memory], selection: $monitor.processSort,
                               title: { $0 == .cpu ? "CPU" : "메모리" })
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("PID").gridColumnAlignment(.trailing)
                    Text("이름")
                    Text("CPU").gridColumnAlignment(.trailing)
                    Text("실제 메모리").gridColumnAlignment(.trailing)
                    if !windows(s) { Text("상태") }
                    Text("스레드").gridColumnAlignment(.trailing)
                    Text("CPU 시간").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
                ForEach(monitor.processes) { p in
                    GridRow {
                        Text(verbatim: "\(p.pid)").monospacedDigit().foregroundStyle(.secondary)
                        Text(p.command).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f", p.cpu)).monospacedDigit().foregroundStyle(p.cpu >= 90 ? StatusTone.warn.color : Color.primary)
                        Text(SystemFormat.bytes(p.memory)).monospacedDigit()
                        if !windows(s) { Text(p.state).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        Text(verbatim: "\(p.threads)").monospacedDigit().foregroundStyle(.secondary)
                        Text(SystemFormat.cpuTime(p.cpuTime)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            Text("CPU 는 코어 하나 = 100%").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// 카드 안 수치 하나 (타일 바탕 없이): 작은 제목 · 큰 값 · 장식 · 설명
struct LiveMetric<Accessory: View>: View {
    let title: String
    let value: String
    var tone: StatusTone = .muted
    var caption: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.medium).monospacedDigit().foregroundStyle(tone == .muted ? Color.primary : tone.color)
                .lineLimit(1).minimumScaleFactor(0.7)
            accessory.frame(maxWidth: .infinity, minHeight: 8, alignment: .leading)
            if let caption { Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
        }
    }
}
