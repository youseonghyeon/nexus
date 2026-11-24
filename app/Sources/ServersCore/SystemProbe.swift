// 이 Mac 의 원자료 읽기 (앱 안 API) — host_processor_info · host_statistics64 · sysctl · IOKit(IOAccelerator·AppleSMC·전원).
// 읽은 값의 타입과 계산은 SystemStats.swift.

import CSMC
import Darwin
import Foundation
import IOKit
import IOKit.ps

public enum SystemProbe {
    private static let host = mach_host_self()

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlValue<T>(_ name: String, _ type: T.Type) -> T? {
        var value = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    public static func staticInfo() -> SystemStatic {
        let cores = sysctlValue("hw.ncpu", Int32.self).map(Int.init) ?? ProcessInfo.processInfo.processorCount
        var bootTime: Date?
        if let boot = sysctlValue("kern.boottime", timeval.self) {
            bootTime = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemStatic(chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
                            cores: cores,
                            performanceCores: sysctlValue("hw.perflevel0.logicalcpu", Int32.self).map(Int.init) ?? 0,
                            efficiencyCores: sysctlValue("hw.perflevel1.logicalcpu", Int32.self).map(Int.init) ?? 0,
                            memory: sysctlValue("hw.memsize", UInt64.self) ?? ProcessInfo.processInfo.physicalMemory,
                            pageSize: UInt64(sysctlValue("hw.pagesize", Int64.self) ?? Int64(getpagesize())),
                            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
                            bootTime: bootTime)
    }

    /// 코어별 누적 틱 (percore 헬퍼와 같은 host_processor_info)
    public static func cpuTicks() -> [CoreTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    public static func vmCounts() -> VMCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var vm = VMCounts()
        vm.wired = UInt64(stats.wire_count)
        vm.purgeable = UInt64(stats.purgeable_count)
        vm.compressor = UInt64(stats.compressor_page_count)
        vm.uncompressedInCompressor = stats.total_uncompressed_pages_in_compressor
        vm.external = UInt64(stats.external_page_count)
        vm.internal = UInt64(stats.internal_page_count)
        vm.pageins = stats.pageins
        vm.pageouts = stats.pageouts
        vm.swapins = stats.swapins
        vm.swapouts = stats.swapouts
        vm.compressions = stats.compressions
        vm.decompressions = stats.decompressions
        return vm
    }

    public static func swap() -> SwapUsage? {
        guard let usage = sysctlValue("vm.swapusage", xsw_usage.self) else { return nil }
        return SwapUsage(total: usage.xsu_total, used: usage.xsu_used, encrypted: usage.xsu_encrypted != 0)
    }

    public static func loadAverage() -> [Double] {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? load : []
    }

    public static func pressure() -> MemoryPressure {
        MemoryPressure(level: sysctlValue("kern.memorystatus_vm_pressure_level", Int32.self).map(Int.init) ?? 0)
    }

    public static func freeLevel() -> Int? {
        sysctlValue("kern.memorystatus_level", Int32.self).map(Int.init)
    }

    /// 첫 GPU (IOAccelerator) 의 사용률·메모리
    public static func gpu() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        guard let stats = property("PerformanceStatistics") as? [String: Any] else { return nil }
        return GPUStats.parse(stats, model: property("model") as? String, cores: (property("gpu-core-count") as? NSNumber)?.intValue)
    }

    public static func power() -> PowerInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerInfo(onAC: true, batteryPercent: nil, charging: false, charged: false)
        }
        let sources = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        return PowerInfo.parse(sources, providing: providing)
    }

    public static func batteryHealth() -> BatteryHealth? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatteryHealth.parse(dict)
    }

    /// 지금 배터리 전력 (W, 충전 + · 방전 −). 배터리가 없으면 nil. 두 값만 읽어 가볍다 (화면 표본마다).
    public static func batteryWatts() -> Double? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        return BatteryFlow.watts(voltage: property("Voltage"), amperage: property("Amperage"))
    }

    /// 팬 RPM. AppleSMC 를 못 열면 nil, 팬 없는 Mac 은 빈 목록.
    public static func fans() -> [FanReading]? {
        var actual = [Double](repeating: .nan, count: 4)
        var maximum = [Double](repeating: .nan, count: 4)
        let count = csmc_read_fans(&actual, &maximum, 4)
        guard count >= 0 else { return nil }
        return (0..<Int(count)).map { i in
            FanReading(rpm: actual[i].isNaN ? nil : actual[i], maxRPM: maximum[i].isNaN ? nil : maximum[i])
        }
    }

    /// 온도 센서 목록 (키·값). 무거워서(키 수백 개) 한 번만 부르고 키를 기억해 둔다. AppleSMC 를 못 열면 nil.
    public static func temperatureKeys() -> [String: Double]? {
        let max = 512
        var keys = [CChar](repeating: 0, count: max * 5)
        var values = [Double](repeating: 0, count: max)
        let count = csmc_list_temperatures(&keys, &values, Int32(max))
        guard count >= 0 else { return nil }
        var out: [String: Double] = [:]
        for i in 0..<Int(count) {
            let name = keys[(i * 5)..<(i * 5 + 4)].map { Character(UnicodeScalar(UInt8(bitPattern: $0))) }
            out[String(name)] = values[i]
        }
        return out
    }

    /// 기억해 둔 키만 다시 읽는다. 못 읽은 키는 NaN.
    public static func temperatures(_ keys: [String]) -> [String: Double] {
        let valid = keys.filter { $0.utf8.count == 4 }
        guard !valid.isEmpty else { return [:] }
        var joined = Array(valid.joined().utf8CString)
        var values = [Double](repeating: .nan, count: valid.count)
        guard csmc_read_temperatures(&joined, Int32(valid.count), &values) >= 0 else { return [:] }
        return Dictionary(zip(valid, values), uniquingKeysWith: { a, _ in a })
    }

    public static func processes(runner: any CommandRunner) async -> [ProcessRow] {
        ProcessList.parse(await runner.run("ps", ProcessList.psArguments, timeout: 5).stdout)
    }
}
