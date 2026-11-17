// SystemStats: CPU·메모리·페이징·온도·GPU·전원·프로세스 계산 (stats.zsh 와 같은 값) + 이 Mac 에서 앱 안 API 가 실제로 읽히는지.

import Foundation
import IOKit.ps
import XCTest
@testable import ServersCore

final class SystemStatsTests: XCTestCase {

    // MARK: CPU

    func testCPUUsageFromTickDeltas() throws {
        let old = [CoreTicks(user: 100, system: 50, idle: 850, nice: 0), CoreTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let new = [CoreTicks(user: 160, system: 70, idle: 870, nice: 0),   // +60 +20 +20 → 80% 바쁨
                   CoreTicks(user: 0, system: 0, idle: 1100, nice: 0)]     // 놀기만
        let usage = try XCTUnwrap(CPUUsage.between(old, new))
        XCTAssertEqual(usage.cores, [80, 0])
        XCTAssertEqual(usage.total, 40, accuracy: 0.001, "전체는 모든 코어의 틱을 합쳐서")
        XCTAssertEqual(usage.user, 30, accuracy: 0.001)
        XCTAssertEqual(usage.system, 10, accuracy: 0.001)
        XCTAssertEqual(usage.idle, 60, accuracy: 0.001)
    }

    func testCPUUsageHandlesCounterWrapAndMismatch() throws {
        let old = [CoreTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let new = [CoreTicks(user: 10, system: 0, idle: 20, nice: 0)]   // user 는 넘어가서 +20
        let usage = try XCTUnwrap(CPUUsage.between(old, new))
        XCTAssertEqual(usage.cores[0], 50, accuracy: 0.001, "32비트 카운터가 넘어가도 음수가 아니다")
        XCTAssertNil(CPUUsage.between([], new), "첫 표본은 기준값만")
        XCTAssertNil(CPUUsage.between(old, new + new), "코어 수가 바뀌면 계산하지 않는다")
        XCTAssertNil(CPUUsage.between(new, new), "시간이 흐르지 않았으면 nil")
    }

    func testCoreNamesEfficiencyFirst() {
        let m4 = SystemStatic(chip: "Apple M4", cores: 10, performanceCores: 4, efficiencyCores: 6, memory: 0, pageSize: 16384, osVersion: "", bootTime: nil)
        XCTAssertEqual((0..<10).map(m4.coreName), ["E0", "E1", "E2", "E3", "E4", "E5", "P0", "P1", "P2", "P3"])
        let intel = SystemStatic(chip: "Intel", cores: 4, performanceCores: 0, efficiencyCores: 0, memory: 0, pageSize: 4096, osVersion: "", bootTime: nil)
        XCTAssertEqual(intel.coreName(2), "C2")
    }

    // MARK: 메모리

    func testMemoryBreakdownMatchesStatsScript() throws {
        var vm = VMCounts()
        vm.internal = 1000; vm.purgeable = 100       // 앱 900 페이지
        vm.wired = 200; vm.compressor = 50; vm.uncompressedInCompressor = 150; vm.external = 300
        let page: UInt64 = 16384, total: UInt64 = 4000 * page
        let memory = MemoryBreakdown.from(vm, pageSize: page, total: total)
        XCTAssertEqual(memory.app, 900 * page)
        XCTAssertEqual(memory.used, (900 + 200 + 50) * page, "사용 = 앱 + 와이어드 + 압축")
        XCTAssertEqual(memory.cached, 300 * page)
        XCTAssertEqual(memory.free, (4000 - 1150 - 300) * page, "여유 = 전체 − 사용 − 캐시")
        XCTAssertEqual(try XCTUnwrap(memory.compressionRatio), 3, accuracy: 0.001)
        XCTAssertEqual(memory.usedFraction, 1150.0 / 4000, accuracy: 0.0001)

        var odd = VMCounts(); odd.internal = 10; odd.purgeable = 20; odd.external = 99_999
        let clamped = MemoryBreakdown.from(odd, pageSize: page, total: 100 * page)
        XCTAssertEqual(clamped.app, 0, "purgeable 이 더 크면 0")
        XCTAssertEqual(clamped.free, 0, "음수가 되지 않는다")
        XCTAssertNil(clamped.compressionRatio, "압축 페이지가 없으면 비율 없음")
    }

    func testPagingRatesAndPressure() throws {
        var a = VMCounts(), b = VMCounts()
        a.pageins = 100; b.pageins = 300; a.swapouts = 10; b.swapouts = 5   // 줄어든 카운터는 0
        let rates = try XCTUnwrap(PagingRates.between(a, b, seconds: 2))
        XCTAssertEqual(rates.pageins, 100)
        XCTAssertEqual(rates.swapouts, 0)
        XCTAssertNil(PagingRates.between(a, b, seconds: 0))
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warning)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertEqual(MemoryPressure(level: 0), .unknown)
    }

    func testSamplerNeedsTwoSamplesForRates() {
        let info = SystemStatic(chip: "", cores: 1, performanceCores: 0, efficiencyCores: 0, memory: 1 << 30, pageSize: 16384, osVersion: "", bootTime: nil)
        var sampler = SystemSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        let first = sampler.step(ticks: [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)], vm: VMCounts(), info: info, swap: nil, load: [],
                                 pressure: .normal, freeLevel: 60, at: t0)
        XCTAssertNil(first.cpu, "첫 표본은 기준값만")
        XCTAssertNil(first.paging)
        XCTAssertNotNil(first.memory, "메모리는 첫 표본부터")
        let second = sampler.step(ticks: [CoreTicks(user: 50, system: 0, idle: 50, nice: 0)], vm: VMCounts(), info: info, swap: nil, load: [],
                                  pressure: .normal, freeLevel: 60, at: t0.addingTimeInterval(2))
        XCTAssertEqual(second.cpu?.total ?? -1, 50, accuracy: 0.001)
        XCTAssertNotNil(second.paging)
    }

    // MARK: 온도 · GPU · 전원

    func testTemperatureGroupsLikeStatsScript() throws {
        XCTAssertNil(TemperatureSummary.from(["Tp01": 0, "Te01": -1]).cpuMax, "0 이하(쉬는 센서)는 뺀다 — 0°C 로 보이지 않게")
        let summary = TemperatureSummary.from(["Tp01": 60, "Tp05": 70, "Te04": 50, "Tg0f": 45, "TG0D": 47, "TC0P": 0.0 / 0.0, "Te09": 0,
                                               "TaLP": 30, "TCXC": 99])   // 묶음 밖 키(Ta·TCX)는 뺀다
        XCTAssertEqual(summary.cpuMax, 70)
        XCTAssertEqual(try XCTUnwrap(summary.cpuAverage), 60, accuracy: 0.001)
        XCTAssertEqual(summary.performanceMax, 70)
        XCTAssertEqual(summary.efficiencyMax, 50)
        XCTAssertEqual(summary.gpuMax, 47)
        XCTAssertEqual(summary.sensors, 5, "못 읽은 값(NaN)·묶음 밖 키는 세지 않는다")
        XCTAssertNil(TemperatureSummary.from([:]).cpuMax)
        XCTAssertEqual(TemperatureSummary.group("TC1C"), .cpu)
        XCTAssertNil(TemperatureSummary.group("Tp1"), "키는 4글자")
    }

    func testGPUAndPowerParsing() {
        let gpu = GPUStats.parse(["Device Utilization %": 12, "Renderer Utilization %": 9, "Tiler Utilization %": 3,
                                  "In use system memory": 317_128_704, "Alloc system memory": 5_314_609_152], model: "Apple M4", cores: 10)
        XCTAssertEqual(gpu.device, 12)
        XCTAssertEqual(gpu.memoryInUse, 317_128_704)
        XCTAssertEqual(gpu.cores, 10)
        XCTAssertNil(GPUStats.parse([:], model: nil, cores: nil).device)

        let battery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100,
                                      kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: false, kIOPSIsChargedKey: false]
        XCTAssertEqual(PowerInfo.parse([battery], providing: kIOPSACPowerValue), PowerInfo(onAC: true, batteryPercent: 80, charging: false, charged: false))
        XCTAssertEqual(PowerInfo.parse([battery], providing: kIOPSBatteryPowerValue).onAC, false)
        XCTAssertEqual(PowerInfo.parse([], providing: kIOPSACPowerValue), PowerInfo(onAC: true, batteryPercent: nil, charging: false, charged: false),
                       "배터리 없는 Mac")

        // 2026-10-05 이 Mac 의 AppleSmartBattery 값 (공칭이 설계보다 커도 100 상한)
        let mac: [String: Any] = ["CycleCount": 184, "DesignCycleCount9C": 1000, "MaxCapacity": 100,
                                  "BatteryData": ["NominalChargeCapacity": 6319, "DesignCapacity": 6249, "FullChargeCapacity": 6167]]
        XCTAssertEqual(BatteryHealth.parse(mac), BatteryHealth(maxCapacityPercent: 100, cycleCount: 184, designCycles: 1000))
        let worn = BatteryHealth.parse(["CycleCount": 900, "BatteryData": ["NominalChargeCapacity": 4800, "DesignCapacity": 6249]])
        XCTAssertEqual(worn?.maxCapacityPercent, 77)
        XCTAssertEqual(worn?.needsService, true, "80% 미만은 교체 권장")
        XCTAssertNil(BatteryHealth.parse([:]), "배터리 없는 Mac")

        // 배터리 전력: Amperage 는 부호 있는 값이 UInt64 로 온다 (2026-10-05 이 Mac 방전 중)
        let discharging = BatteryFlow.watts(voltage: NSNumber(value: 11857), amperage: NSNumber(value: UInt64(18446744073709550963)))
        XCTAssertEqual(discharging ?? 0, -7.742, accuracy: 0.01)
        XCTAssertEqual(BatteryFlow.text(discharging), "방전 7.7W")
        XCTAssertEqual(BatteryFlow.text(BatteryFlow.watts(voltage: NSNumber(value: 12600), amperage: NSNumber(value: 2010))), "충전 25.3W")
        XCTAssertNil(BatteryFlow.text(BatteryFlow.watts(voltage: NSNumber(value: 12600), amperage: NSNumber(value: 0))), "0W 는 적지 않는다")
        XCTAssertNil(BatteryFlow.watts(voltage: nil, amperage: NSNumber(value: 1)), "배터리 없는 Mac")

        // 전원 줄 (상태·전력은 같은 표본)
        let onBattery = PowerInfo(onAC: false, batteryPercent: 71, charging: false, charged: false)
        XCTAssertEqual(onBattery.text(watts: -7.7), "배터리 사용 중 · 71% · 방전 7.7W")
        XCTAssertEqual(onBattery.text(watts: nil), "배터리 사용 중 · 71%")
        XCTAssertEqual(PowerInfo(onAC: true, batteryPercent: 80, charging: true, charged: false).text(watts: 25.3), "전원 어댑터 · 배터리 80% · 충전 25.3W")
        XCTAssertEqual(PowerInfo(onAC: true, batteryPercent: 80, charging: true, charged: false).text(watts: 0.05), "전원 어댑터 · 배터리 80% · 충전 중")
        XCTAssertEqual(PowerInfo(onAC: true, batteryPercent: 100, charging: false, charged: true).text(watts: 0), "전원 어댑터 · 배터리 100% · 충전 완료")
        XCTAssertEqual(PowerInfo(onAC: true, batteryPercent: 80, charging: false, charged: false).text(watts: nil), "전원 어댑터 · 배터리 80% · 충전 안 함", "최적화 충전 보류")
        XCTAssertEqual(PowerInfo(onAC: true, batteryPercent: nil, charging: false, charged: false).text(watts: nil), "전원 어댑터", "배터리 없는 Mac")

        // 팬 (2026-10-05 이 Mac: 1개, 정지, 최대 6550)
        XCTAssertNil(FanReading.text([]), "팬 없는 Mac 은 줄을 숨긴다")
        XCTAssertEqual(FanReading.text([FanReading(rpm: 0, maxRPM: 6550)]), "정지 · 최대 6,550 RPM")
        XCTAssertEqual(FanReading.text([FanReading(rpm: 2400, maxRPM: 6550)]), "2,400 RPM (37%)")
        XCTAssertEqual(FanReading.text([FanReading(rpm: 2400, maxRPM: nil), FanReading(rpm: nil, maxRPM: nil)]), "1번 2,400 RPM · 2번 읽지 못했습니다")
        XCTAssertEqual(FanReading.text([FanReading(rpm: .infinity, maxRPM: 6550)]), "읽지 못했습니다", "이상값에 멈추지 않는다")
        XCTAssertEqual(FanReading.text([FanReading(rpm: 2400, maxRPM: .infinity)]), "2,400 RPM", "최대값이 이상하면 비율을 빼고")
        // 실제 SMC: 읽히면 모양만 본다
        if let fans = SystemProbe.fans() {
            XCTAssertTrue(fans.allSatisfy { ($0.rpm ?? 0) >= 0 && ($0.maxRPM ?? 0) < 20_000 })
        }
        // 실제 레지스트리: 배터리가 있으면 모양만 본다
        if let real = SystemProbe.batteryHealth(), let percent = real.maxCapacityPercent {
            XCTAssertTrue((1...100).contains(percent))
        }
    }

    // MARK: 프로세스

    func testProcessListParsingAndRates() throws {
        XCTAssertEqual(ProcessList.seconds("11:43.18") ?? 0, 703.18, accuracy: 0.001)
        XCTAssertEqual(ProcessList.seconds("161:33.89") ?? 0, 9693.89, accuracy: 0.001, "분이 60 을 넘는다")
        XCTAssertEqual(ProcessList.seconds("1:02:03") ?? 0, 3723, accuracy: 0.001)
        XCTAssertEqual(ProcessList.seconds("2-01:00:00") ?? 0, 2 * 86400 + 3600, accuracy: 0.001)
        XCTAssertNil(ProcessList.seconds("x:1"))

        let rows = ProcessList.parse("""
        56185  37.2  11:43.18 642656 S+   claude
         1340   6.1  56:07.37 1268384 Ss   /Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper
        garbage line
        """)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].pid, 1340)
        XCTAssertEqual(rows[1].memory, 1_268_384 * 1024)
        XCTAssertEqual(rows[1].name, "OrbStack Helper", "공백 있는 경로도 끝까지, 이름은 마지막 부분")
        XCTAssertEqual(rows[0].state, "S+")

        var sampler = SystemSampler()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(sampler.processes(rows, at: t0).map(\.cpu), [37.2, 6.1], "첫 표본은 ps 의 %CPU")
        let later = [ProcessRow(pid: 56185, cpu: 37.2, cpuTime: 703.18 + 1.0, memory: 0, state: "R", command: "claude"),
                     ProcessRow(pid: 99, cpu: 4, cpuTime: 1, memory: 0, state: "S", command: "new")]
        let rated = sampler.processes(later, at: t0.addingTimeInterval(2))
        XCTAssertEqual(rated[0].cpu, 50, accuracy: 0.001, "2초 동안 CPU 1초 = 50%")
        XCTAssertEqual(rated[1].cpu, 4, "새 프로세스는 ps 값")
    }

    // MARK: 이 Mac 에서 실제로 읽히는지 (값의 범위만 본다)

    func testProbesReadThisMac() throws {
        let info = SystemProbe.staticInfo()
        XCTAssertGreaterThan(info.cores, 0)
        XCTAssertGreaterThan(info.memory, 0)
        XCTAssertGreaterThan(info.pageSize, 0)
        XCTAssertNotNil(info.bootTime)
        let ticks = try XCTUnwrap(SystemProbe.cpuTicks())
        XCTAssertEqual(ticks.count, info.cores, "코어마다 한 줄")
        let memory = MemoryBreakdown.from(try XCTUnwrap(SystemProbe.vmCounts()), pageSize: info.pageSize, total: info.memory)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, info.memory)
        XCTAssertNotEqual(SystemProbe.pressure(), .unknown)
        XCTAssertNotNil(SystemProbe.swap())
        XCTAssertEqual(SystemProbe.loadAverage().count, 3)
    }

    func testTemperatureProbeReadsSMC() throws {
        guard let keys = SystemProbe.temperatureKeys() else { throw XCTSkip("AppleSMC 를 열 수 없는 환경") }
        let summary = TemperatureSummary.from(keys)
        guard summary.sensors > 0 else { throw XCTSkip("이 Mac 에 묶음에 드는 온도 키가 없다") }
        XCTAssertTrue((1...150).contains(summary.cpuMax ?? 0))
        let again = SystemProbe.temperatures(Array(keys.keys.prefix(5)))
        XCTAssertEqual(again.count, min(5, keys.count))
        XCTAssertTrue(again.values.contains { !$0.isNaN }, "기억한 키를 다시 읽을 수 있다")
    }
}

final class SystemHealthFormatTests: XCTestCase {
    func testJudgeOrder() {
        XCTAssertEqual(SystemHealth.judge(cpu: 10, pressure: .normal, thermal: .nominal).level, .good)
        XCTAssertEqual(SystemHealth.judge(cpu: 95, pressure: .normal, thermal: .nominal).text, "CPU 바쁨")
        XCTAssertEqual(SystemHealth.judge(cpu: 95, pressure: .normal, thermal: .nominal).level, .bad, "타일 색(90 이상 빨강)과 같다")
        XCTAssertEqual(SystemHealth.judge(cpu: 95, pressure: .warning, thermal: .nominal).text, "CPU 바쁨", "빨강이 노랑보다 먼저")
        XCTAssertEqual(SystemHealth.judge(cpu: 50, pressure: .warning, thermal: .nominal).text, "메모리 압력 경고")
        XCTAssertEqual(SystemHealth.judge(cpu: 10, pressure: .warning, thermal: .critical).level, .bad)
        XCTAssertEqual(SystemHealth.judge(cpu: nil, pressure: .unknown, thermal: .nominal).level, .good, "첫 표본(CPU 없음)은 정상")
        XCTAssertEqual(SystemHealth.level(79, warn: 80, bad: 90), .good)
        XCTAssertEqual(SystemHealth.level(80, warn: 80, bad: 90), .warn)
        XCTAssertEqual(SystemHealth.level(95, warn: 80, bad: 90), .bad)
    }

    /// 막대·타일 색과 머리글 결론이 같은 숫자를 쓴다 — 막대는 빨강인데 결론은 "정상" 이 되지 않게
    func testGaugesMatchJudge() {
        XCTAssertEqual(SystemHealth.level(69, .cpu), .good)
        XCTAssertEqual(SystemHealth.level(70, .cpu), .warn)
        XCTAssertEqual(SystemHealth.level(90, .cpu), .bad)
        XCTAssertEqual(SystemHealth.level(80, .usage), .warn)
        XCTAssertEqual(SystemHealth.level(90, .usage), .bad)
        XCTAssertEqual(SystemHealth.level(94, .temperature), .warn)
        XCTAssertEqual(SystemHealth.level(95, .temperature), .bad)
        let cpuBad = SystemHealth.Gauge.cpu.bad
        XCTAssertEqual(SystemHealth.judge(cpu: cpuBad, pressure: .normal, thermal: .nominal).level, .bad)
        XCTAssertEqual(SystemHealth.judge(cpu: cpuBad - 0.1, pressure: .normal, thermal: .nominal).level, .good)
    }

    func testFormats() {
        XCTAssertEqual(SystemFormat.bytes(34_359_738_368), "32.0 GiB")
        XCTAssertEqual(SystemFormat.bytes(317_128_704), "302 MiB")
        XCTAssertEqual(SystemFormat.bytes(2048), "2 KiB")
        XCTAssertEqual(SystemFormat.bytes(12), "12 B")
        XCTAssertEqual(SystemFormat.uptime(2 * 86400 + 3 * 3600 + 4 * 60 + 5), "2일 3시간 4분")
        XCTAssertEqual(SystemFormat.uptime(3 * 3600 + 60), "3시간 1분")
        XCTAssertEqual(SystemFormat.uptime(-5), "0분")
        XCTAssertEqual(SystemFormat.cpuTime(703.18), "11:43")
        XCTAssertEqual(SystemFormat.cpuTime(9693.89), "2:41:33")
    }
}
