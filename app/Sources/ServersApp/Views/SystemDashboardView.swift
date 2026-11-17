// 시스템 화면: 사이드바 LOCAL 의 "시스템" 행. ~/.tools/stats.zsh 를 옮긴 것.
// 머리글(칩·코어·메모리·가동) → 수치 타일(CPU·메모리·GPU·온도·부하) → 코어 · 메모리 구성(스왑·페이징) → 프로세스 → 전원·열.
// 화면이 떠 있고 창이 보일 때만 읽는다 (SystemMonitor). 간격은 설정의 갱신 간격 — 기본 3초 (2초에서 늘림, CPU 부담).

import ServersCore
import SwiftUI

struct SystemDashboardView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var monitor: SystemMonitor
    @AppStorage(AppPreferences.systemInterval.key) private var interval = AppPreferences.systemInterval.defaultValue
    @AppStorage(AppPreferences.coreAnimationKey) private var coreAnimation = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HeroCard { header } strip: { metrics }
                // 카드의 이상 폭을 고정해 둔다 — 안 그러면 매 표본 길이가 바뀌는 문구(페이징) 폭으로 두 열·한 열이 번갈아 바뀐다
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Metrics.gap) {
                        coresCard.fillingHeight().frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity, alignment: .topLeading)
                        memoryCard.fillingHeight().frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity, alignment: .topLeading)
                    }
                    .fixedSize(horizontal: false, vertical: true)   // 두 카드 높이를 맞춘다
                    VStack(alignment: .leading, spacing: Metrics.gap) {
                        coresCard
                        memoryCard
                    }
                }
                processCard
                powerCard
            }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sampling(every: { AppSettings.interval(AppPreferences.systemInterval) }) { await monitor.sample(full: true, runner: model.runner) }
    }

    private var info: SystemStatic { monitor.info }
    private var snapshot: SystemSnapshot? { monitor.snapshot }

    // MARK: 머리글

    private var header: some View {
        let health = monitor.health
        return LocalHeader(title: info.chip, subtitle: subtitle, tone: health.level.tone, conclusion: health.text,
                           checkedAt: snapshot?.at, interval: "\(Int(AppPreferences.systemInterval.resolve(interval)))초 간격")
    }

    private var subtitle: String {
        var parts = [info.performanceCores > 0 ? "코어 \(info.cores)개 (성능 \(info.performanceCores) · 효율 \(info.efficiencyCores))" : "코어 \(info.cores)개"]
        parts.append(SystemFormat.bytes(info.memory))
        parts.append(info.osVersion)
        if let boot = info.bootTime { parts.append("가동 \(SystemFormat.uptime(Date().timeIntervalSince(boot)))") }
        return parts.joined(separator: " · ")
    }

    // MARK: 수치 타일

    private var metrics: some View {
        MetricGrid {
            cpuTile
            memoryTile
            gpuTile
            temperatureTile
            loadTile
        }
    }

    private var cpuTile: some View {
        let cpu = snapshot?.cpu
        let level = cpu.map { SystemHealth.level($0.total, .cpu) } ?? .good
        return MetricTile(title: "CPU", value: cpu.map { "\(Int($0.total.rounded()))" } ?? "–", unit: "%",
                          caption: cpu.map { "User \(Int($0.user.rounded()))% · System \(Int($0.system.rounded()))%" } ?? "측정 중…",
                          tone: level.valueTone, systemImage: "cpu") {
            Sparkline(values: monitor.cpuHistory, tone: level.tone, ceiling: 100)
        }
    }

    private var memoryTile: some View {
        let memory = snapshot?.memory
        let percent = (memory?.usedFraction ?? 0) * 100
        let level = SystemHealth.level(percent, .usage)
        return MetricTile(title: "메모리", value: memory.map { _ in "\(Int(percent.rounded()))" } ?? "–", unit: "%",
                          // Pressure 는 정상이 아닐 때만 붙인다 (영어 표기로 길어져 타일에서 잘렸다 — 정상 값은 메모리 카드에)
                          caption: memory.map { "\(SystemFormat.bytes($0.used)) / \(SystemFormat.bytes($0.total))" + (snapshot?.pressure == .warning || snapshot?.pressure == .critical ? " · Pressure \(pressureText)" : "") },
                          tone: level.valueTone, systemImage: "memorychip") {
            MeterBar(level: memory?.usedFraction ?? 0, tone: level.tone)
        }
    }

    private var gpuTile: some View {
        let gpu = monitor.gpu
        return MetricTile(title: "GPU", value: gpu?.device.map { "\(Int($0.rounded()))" } ?? "–", unit: "%",
                          // 메모리를 앞에: 다른 곳에 없는 값. Renderer·Tiler 는 큰 숫자와 비슷해 잘려도 덜 아깝다 (영어 표기로 길어져 끝이 잘렸다)
                          caption: [gpu?.memoryInUse.map { "메모리 \(SystemFormat.bytes($0))" }, gpu?.renderer.map { "Renderer \(Int($0.rounded()))%" },
                                    gpu?.tiler.map { "Tiler \(Int($0.rounded()))%" }].compactMap { $0 }.joined(separator: " · "),
                          tone: .muted, systemImage: "square.stack.3d.up") {
            Sparkline(values: monitor.gpuHistory, tone: .good, ceiling: 100)
        }
    }

    @ViewBuilder
    private var temperatureTile: some View {
        if let temperatures = monitor.temperatures, let cpu = temperatures.cpuMax {
            let level = SystemHealth.level(cpu, .temperature)
            MetricTile(title: "CPU 온도", value: "\(Int(cpu.rounded()))", unit: "°C",
                       caption: [temperatures.gpuMax.map { "GPU \(Int($0.rounded()))°" }, temperatures.cpuAverage.map { "평균 \(Int($0.rounded()))°" }]
                           .compactMap { $0 }.joined(separator: " · "),
                       tone: level.valueTone, systemImage: "thermometer.medium") {
                MeterBar(level: cpu / 110, tone: level.tone)
            }
        } else {
            MetricTile(title: "CPU 온도", value: "–", caption: monitor.temperaturesUnavailable ? "센서를 읽지 못했습니다" : "측정 중…",
                       tone: .muted, systemImage: "thermometer.medium")
        }
    }

    private var loadTile: some View {
        let load = snapshot?.load ?? []
        return MetricTile(title: "부하", value: load.first.map { String(format: "%.2f", $0) } ?? "–",
                          caption: load.count == 3 ? String(format: "5분 %.2f · 15분 %.2f", load[1], load[2]) : nil,
                          tone: .muted, systemImage: "gauge.with.dots.needle.33percent")
    }

    private var pressureText: String { (snapshot?.pressure ?? .unknown).text }

    // MARK: 코어

    private var coresCard: InfoCard<some View, EmptyView> {
        InfoCard(title: "코어") {
            let cores = snapshot?.cpu?.cores ?? []
            if cores.isEmpty {
                Text("측정 중…").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if info.performanceCores > 0, info.performanceCores + info.efficiencyCores == cores.count {
                        let firstP = cores.count - info.performanceCores
                        HStack(alignment: .top, spacing: 24) {
                            coreColumn("성능", indices: Array(firstP..<cores.count), cores: cores)
                            coreColumn("효율", indices: Array(0..<firstP), cores: cores)
                        }
                    } else {
                        coreColumn(nil, indices: Array(cores.indices), cores: cores)
                    }
                    if let cpu = snapshot?.cpu {
                        Text("User \(Int(cpu.user.rounded()))% · System \(Int(cpu.system.rounded()))% · Idle \(Int(cpu.idle.rounded()))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func coreColumn(_ title: String?, indices: [Int], cores: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            ForEach(indices, id: \.self) { index in
                let value = cores[index]
                let level = SystemHealth.level(value, .cpu)
                HStack(spacing: 8) {
                    Text(info.coreName(index)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                    // 갱신 간격(기본 3초)마다 오는 값으로 짧게(0.4초) 이어 움직인다 — 한 번에 뛰면 딱딱해 보였고, 길게 하면 그리는 부담이 컸다
                    MeterBar(level: value / 100, tone: level.tone,
                             animation: coreAnimation ? .easeInOut(duration: 0.4) : nil)
                    // 숫자는 바로 바꾼다 — 굴러가는 효과(numericText)는 프레임마다 글자를 CPU 로 다시 그려 화면 하나에 코어 10% 넘게 썼다
                    Text("\(Int(value.rounded()))%").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 메모리 구성

    private static let shades: (app: Double, wired: Double, compressed: Double, cached: Double) = (0.7, 0.5, 0.35, 0.2)

    private var memoryCard: InfoCard<some View, EmptyView> {
        InfoCard(title: "메모리") {
            if let memory = snapshot?.memory {
                VStack(alignment: .leading, spacing: 10) {
                    StackedBar(segments: [
                        .init(id: "app", value: Double(memory.app), opacity: Self.shades.app),
                        .init(id: "wired", value: Double(memory.wired), opacity: Self.shades.wired),
                        .init(id: "compressed", value: Double(memory.compressed), opacity: Self.shades.compressed),
                        .init(id: "cached", value: Double(memory.cached), opacity: Self.shades.cached),
                    ], total: Double(memory.total))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        memoryRow("App", memory.app, of: memory.total, shade: Self.shades.app)
                        memoryRow("Wired", memory.wired, of: memory.total, shade: Self.shades.wired)
                        memoryRow("Compressed", memory.compressed, of: memory.total, shade: Self.shades.compressed,
                                  note: memory.compressionRatio.map { String(format: "원래 %@ · %.1f배", SystemFormat.bytes(memory.stored), $0) })
                        memoryRow("Cached", memory.cached, of: memory.total, shade: Self.shades.cached)
                        memoryRow("Free", memory.free, of: memory.total, shade: 0)
                    }
                    Divider().opacity(0.5)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        InfoRow("Pressure", [pressureText, snapshot?.freeLevel.map { "커널 여유 수준 \($0)%" }].compactMap { $0 }.joined(separator: " · "))
                        InfoRow("Swap", swapText)
                        InfoRow("Paging", pagingText)
                    }
                }
            } else {
                Text("측정 중…").foregroundStyle(.secondary)
            }
        }
    }

    private func memoryRow(_ label: String, _ value: UInt64, of total: UInt64, shade: Double, note: String? = nil) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Swatch(opacity: shade).overlay(shade == 0 ? RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.5)) : nil)
                Text(label)
            }
            Text(SystemFormat.bytes(value)).monospacedDigit().gridColumnAlignment(.trailing)
            Text(total > 0 ? "\(Int((Double(value) / Double(total) * 100).rounded()))%" : "–").monospacedDigit().foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(note ?? "").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var swapText: String {
        guard let swap = snapshot?.swap else { return "–" }
        guard swap.total > 0 else { return "사용 안 함" }
        return "\(SystemFormat.bytes(swap.used)) / \(SystemFormat.bytes(swap.total))" + (swap.encrypted ? " · 암호화" : "")
    }

    private var pagingText: String {
        guard let paging = snapshot?.paging else { return "측정 중…" }
        func rate(_ value: Double) -> String { String(format: "%.0f", value) }
        // 초당 값 — /s 는 끝에 한 번 (항목마다 붙이면 영어 표기로 길어져 줄이 넘어갔다)
        return "In \(rate(paging.pageins)) · Out \(rate(paging.pageouts)) · Compress \(rate(paging.compressions)) · Decompress \(rate(paging.decompressions)) · Swap In \(rate(paging.swapins)) · Swap Out \(rate(paging.swapouts)) /s"
    }

    // MARK: 프로세스

    private var processCard: some View {
        InfoCard(title: "프로세스") {
            if monitor.processes.isEmpty {
                Text("측정 중…").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("PID").gridColumnAlignment(.trailing)
                            Text("이름")
                            Text("CPU").gridColumnAlignment(.trailing)
                            Text("실제 메모리").gridColumnAlignment(.trailing)
                            Text("상태")
                            Text("CPU 시간").gridColumnAlignment(.trailing)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
                        ForEach(monitor.processes) { row in
                            GridRow {
                                Text(verbatim: "\(row.pid)").monospacedDigit().foregroundStyle(.secondary)
                                Text(row.name).lineLimit(1).truncationMode(.middle).help(row.command)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(String(format: "%.1f", row.cpu)).monospacedDigit()
                                    .foregroundStyle(row.cpu >= 90 ? StatusTone.warn.color : Color.primary)
                                Text(SystemFormat.bytes(row.memory)).monospacedDigit()
                                Text(row.state).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(SystemFormat.cpuTime(row.cpuTime)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("프로세스 \(monitor.processCount)개 · 실행 중 \(monitor.runningCount)개 · CPU 는 코어 하나 = 100% · 메모리는 실제 메모리(RSS)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        } accessory: {
            PlainSegmented(items: [SystemMonitor.ProcessSort.cpu, .memory],
                           selection: Binding(get: { monitor.processSort }, set: { monitor.resort($0) }),
                           title: { $0 == .cpu ? "CPU" : "메모리" })
        }
    }

    // MARK: 전원 · 열

    private var powerCard: some View {
        InfoCard(title: "전원 · 열") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                InfoRow("전원", powerText)
                if let health = monitor.batteryHealth { InfoRow("배터리 건강", batteryHealthText(health)) }
                InfoRow("열 상태", SystemHealth.thermalText(monitor.thermal))
                InfoRow("온도", temperatureText)
                if let fans = monitor.fans, let text = FanReading.text(fans) { InfoRow("팬", text) }
            }
        }
    }

    private var powerText: String {
        monitor.power?.text(watts: monitor.batteryWatts) ?? "–"
    }

    /// "최대 용량 100% · 충전 사이클 184 / 1000" (80% 미만이면 교체 권장)
    private func batteryHealthText(_ health: BatteryHealth) -> String {
        let cycles = health.cycleCount.map { count in "충전 사이클 \(count)" + (health.designCycles.map { " / \($0)" } ?? "") }
        return [health.maxCapacityPercent.map { "최대 용량 \($0)%" }, cycles, health.needsService ? "교체 권장" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var temperatureText: String {
        if monitor.temperaturesUnavailable { return "온도 센서를 읽지 못했습니다" }
        guard let t = monitor.temperatures else { return "측정 중…" }
        func degrees(_ label: String, _ value: Double?) -> String? { value.map { "\(label) \(Int($0.rounded()))°" } }
        return ([degrees("성능 코어", t.performanceMax), degrees("효율 코어", t.efficiencyMax), degrees("GPU", t.gpuMax)].compactMap { $0 }
                + ["센서 \(t.sensors)개"]).joined(separator: " · ")
    }
}
