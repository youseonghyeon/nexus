// 패킷 캡처 창의 상태와 tcpdump 프로세스. 창을 열면 바로 시작, 일시정지는 프로세스를 끝내 자원을 쓰지 않는다 (재개는 다시 인증).
// 해석·요약은 ServersCore CaptureStore. 흐름 (2026-11-01 리뷰 반영):
//   읽기 스레드: pcap 조각 → 패킷 (StreamReader, 시작마다 새로·세대 번호) → CapturePipeline 대기열 (밀리면 버리고 센다)
//   전용 큐: 해석·요약 (저장소는 큐만 들고 있다) → 0.4초마다 화면용 가벼운 사본(CaptureSnapshot)을 잠금 변수에 둔다
//   본 스레드: 0.5초마다 그 사본만 읽는다 (큐를 기다리지 않는다). 목록 거르기·검색·상세 대화·.pcap 저장도 큐에 부탁한다

import AppKit
import ServersCore
import SwiftUI

@MainActor
final class PacketCaptureController: ObservableObject {
    enum State: Equatable {
        case idle
        /// sudo 인증·tcpdump 시작을 기다림
        case starting
        case running
        case paused
        case failed(String)
    }

    /// 요약·목록·상세 대화 — 갱신마다 한 번에 바뀐다
    @Published private(set) var snapshot = CaptureSnapshot()
    @Published private(set) var state: State = .idle
    @Published private(set) var device = ""
    /// 지금 캡처에 걸린 필터 (입력칸은 창이 따로 들고, Enter 로 적용)
    @Published private(set) var filter = ""
    @Published private(set) var devices: [String] = []
    @Published var display: CaptureFilter = .all { didSet { if display != oldValue { pipeline.setView(display, search) } } }
    /// 목록 검색 (받은 목록 안에서 — 캡처 필터와 별개)
    @Published var search = "" { didSet { if search != oldValue { pipeline.setView(display, search) } } }
    /// 목록에 그리는 최대 행 수 (최근 것부터)
    nonisolated static let shownLimit = 5_000
    /// 장치 → 하드웨어 포트 이름 (networksetup) — 툴바 장치 칸 "en11 · TPlink 2.5G Ethernet"
    @Published private(set) var portNames: [String: String] = [:]
    /// 적용 전 문법 검사에서 걸린 이유 (고칠 때까지 캡처는 그대로)
    @Published private(set) var filterError: String?
    private var runner: (any CommandRunner)?
    /// 처리가 밀려 버린 패킷 수 (대용량 전송 등)
    @Published private(set) var skipped = 0

    private var process: CaptureProcess?
    private let pipeline = CapturePipeline()
    private var generation = 0
    private var refresh: Task<Void, Never>?
    private var askPassHelper: String?
    private var shownVersion = -1
    /// 지금 프로세스가 비밀번호 창(-A) 단계인가
    private var usingAskPass = false
    private var saving = false

    var isActive: Bool { state == .starting || state == .running }

    /// 창을 열기 전에 장치를 정한다 (진단 카드의 [Capture…]). 이미 그 장치면 그대로
    func prepare(device: String?, askPassHelper: String?) {
        self.askPassHelper = askPassHelper
        guard let device, CaptureCommand.isValidDevice(device), device != self.device else { return }
        if isActive || self.device.isEmpty == false { switchDevice(device) } else { self.device = device }
    }

    /// 창이 보이면 바로 시작 (이미 돌고 있으면 그대로). vendors: 검색·목록에 쓸 제조사 표
    func windowAppeared(defaultDevice: String, runner: any CommandRunner, vendors: OUITable?) {
        if device.isEmpty { device = defaultDevice }
        self.runner = runner
        pipeline.setVendors(vendors)
        Task {
            let result = await runner.run("/usr/sbin/tcpdump", ["-D"], timeout: 5)
            if result.ok { devices = CaptureCommand.parseDevices(result.stdout) }
            let ports = await runner.run("networksetup", ["-listallhardwareports"], timeout: 5)
            if ports.ok { portNames = CaptureCommand.parseHardwarePorts(ports.stdout) }
        }
        if state == .idle || state == .paused { start() }
    }

    /// 창을 닫으면 끝낸다 (목록은 남겨 두고 다음에 열면 이어서)
    func windowClosed() {
        stopProcess()
        if state != .idle { state = .paused }
    }

    /// 지문(sudo, -A 없이) 먼저 — 실패하면 processEnded 가 비밀번호 창(-A)으로 한 번 다시 띄운다
    func start() {
        start(askPass: false)
    }

    private func start(askPass: Bool) {
        guard !isActive else { return }
        // 상태만 실패로 바뀌고 tcpdump 는 살아 있을 수 있다 (.pcap 저장 실패) — 덮어쓰기 전에 끝낸다 (안 끝내면 sudo tcpdump 가 남는다)
        stopProcess()
        guard let arguments = CaptureCommand.arguments(device: device, filter: filter) else {
            state = .failed("필터에 - 로 시작하는 낱말은 쓸 수 없습니다 (tcpdump 옵션으로 읽힘). 장치 이름도 확인하세요.")
            return
        }
        generation += 1
        let stream = StreamReader(generation: generation, pipeline: pipeline)
        pipeline.newStream(generation)
        let process = CaptureProcess()
        process.onData = { chunk in stream.feed(chunk) }
        process.onExit = { [weak self] code, stderr, stopped in
            Task { @MainActor in self?.processEnded(process, code: code, stderr: stderr, stopped: stopped) }
        }
        let environment = askPass ? askPassHelper.map {
            ["SUDO_ASKPASS": $0, "SERVERS_ASKPASS_TITLE": "패킷 캡처 · 관리자 비밀번호"]
        } : nil
        usingAskPass = environment != nil
        do {
            try process.start(tcpdumpArguments: arguments, askPassEnvironment: environment)
        } catch {
            state = .failed("tcpdump 를 실행하지 못했습니다: \(error.localizedDescription)")
            return
        }
        self.process = process
        state = .starting
        startRefresh()
    }

    func pause() {
        guard isActive else { return }
        stopProcess()
        state = .paused
        pullSoon()
    }

    /// 목록·요약만 비운다 (캡처는 계속)
    func reset() {
        pipeline.reset()
        shownVersion = -1
        pull()
        display = .all
    }

    /// Enter·도우미·오른쪽 클릭: 먼저 문법을 검사하고(root 없이), 맞으면 그 조건으로 다시 시작
    func submitFilter(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runner else { applyFilter(trimmed); return }
        let linkType = snapshot.totalPackets > 0 ? snapshot.linkType : CaptureFilterAssist.linkType(forDevice: device)
        Task {
            let problem = await CaptureFilterAssist.validate(trimmed, linkType: linkType, runner: runner)
            filterError = problem
            if problem == nil { applyFilter(trimmed) }
        }
    }

    /// 필터를 바꾸면 그 조건으로 다시 시작 (목록은 유지 — 같은 장치라 링크 종류가 같다)
    func applyFilter(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != filter else { return }
        filter = trimmed
        guard isActive else { return }
        stopProcess()
        state = .idle
        start()
    }

    /// 장치를 바꾸면 목록을 비우고 다시 시작 (장치마다 링크 종류가 달라 한 .pcap 에 섞을 수 없다)
    func switchDevice(_ name: String) {
        guard name != device, CaptureCommand.isValidDevice(name) else { return }
        let wasActive = isActive
        stopProcess()
        device = name
        reset()
        // 돌고 있었으면 새 장치로 이어서, 일시정지 중이었으면 그대로 멈춰 둔다
        if wasActive { state = .idle; start() } else if state != .paused { state = .idle }
    }

    /// 누른 때의 패킷을 큐에서 받아 저장 (저장소는 큐만 들고 있다)
    func savePcap() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            let data = await pipeline.pcapData()
            let panel = NSSavePanel()
            let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                                    timeZone: .current, calendar: .current))
            panel.nameFieldStringValue = "capture-\(device)-\(stamp).pcap"
            panel.allowedContentTypes = [.init(filenameExtension: "pcap") ?? .data]
            // runModal 은 쓰지 않는다 — Task(메인 액터) 안의 모달 런루프는 메인 큐를 비우지 않아 창이 열린 동안 상태 갱신·전송 진행률이 멈춘다
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch {
                state = .failed("저장하지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    /// 상세 카드: 고른 행과 그 대화를 다음 사본에 담게 한다 — 큐가 바로 사본을 만들고 곧장 가져온다
    func select(row id: Int?, conversation: String?) {
        pipeline.setSelection(id, conversation) { [weak self] in Task { @MainActor in self?.pull() } }
    }

    /// 앱 종료
    func stop() {
        stopProcess()
    }

    // MARK: 내부

    private func stopProcess() {
        process?.stop()
        process = nil
        refresh?.cancel()
        refresh = nil
    }

    private func processEnded(_ ended: CaptureProcess, code: Int32, stderr: String, stopped: Bool) {
        // 지금 프로세스의 끝만 본다 — 멈춘·바꾼 뒤 옛 프로세스의 알림이 상태를 덮지 않게 (2026-11-01 리뷰)
        guard ended === process else { return }
        pullSoon()
        process = nil
        refresh?.cancel()
        refresh = nil
        guard !stopped else { return }
        // 지문 단계가 인증을 못 받았으면(취소·지문 없음) 비밀번호 창으로 한 번 더
        if !usingAskPass, askPassHelper != nil, !pipeline.status.started, CaptureCommand.needsPasswordFallback(stderr) {
            state = .idle
            start(askPass: true)
            return
        }
        state = .failed(CaptureCommand.endText(pipelineFailure: pipeline.status.failure, stderr: stderr, code: code))
    }

    private func startRefresh() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.pull()
            }
        }
    }

    /// 멈춘 직후: 큐에 남은 꼬리 패킷이 사본에 들어간 뒤 한 번 더 가져온다 (주기 갱신은 이미 끊겼다 — 2026-11-01 Fable 리뷰)
    private func pullSoon() {
        pull()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.pull()
        }
    }

    /// 화면용 사본이 바뀌었으면 가져온다 (잠금 변수만 읽는다)
    private func pull() {
        pipeline.flushIfNeeded()
        let status = pipeline.status
        if state == .starting, status.started { state = .running }
        if let problem = status.failure, isActive {
            stopProcess()
            state = .failed(problem)
        }
        if skipped != status.skipped { skipped = status.skipped }
        guard status.version != shownVersion else { return }
        shownVersion = status.version
        snapshot = status.snapshot
    }
}

/// 한 번의 시작에 하나: 읽기 스레드에서만 불린다 (조각은 차례로 온다)
private final class StreamReader: @unchecked Sendable {
    private var reader = PcapReader()
    private let generation: Int
    private let pipeline: CapturePipeline
    private var failed = false

    init(generation: Int, pipeline: CapturePipeline) {
        self.generation = generation
        self.pipeline = pipeline
    }

    func feed(_ chunk: [UInt8]) {
        guard !failed else { return }
        do {
            let packets = try reader.feed(chunk)
            if let type = reader.linkType { pipeline.enqueue(packets, linkType: type, generation: generation) }
        } catch {
            failed = true
            pipeline.fail("tcpdump 출력을 읽지 못했습니다 (pcap 형식이 아님)", generation: generation)
        }
    }
}

/// 패킷 → CaptureStore. 저장소는 전용 직렬 큐에서만, 화면용 사본·상태는 잠금 변수로.
private final class CapturePipeline: @unchecked Sendable {
    struct Status {
        /// 화면용 가벼운 사본 (저장소 통째가 아니다 — 통째로 넘기면 다음 패킷에 행·대화·흐름 버퍼 전부가 복사됐다)
        var snapshot = CaptureSnapshot()
        var version = 0
        var started = false
        var failure: String?
        var skipped = 0
    }

    /// 대기열에 쌓인 패킷이 이보다 많으면 새로 온 것을 버린다 (메모리가 끝없이 늘지 않게)
    private static let backlogLimit = 50_000
    private let queue = DispatchQueue(label: "nexus.capture.pipeline", qos: .utility)
    private let lock = NSLock()
    // 잠금으로 지키는 것
    private var shared = Status()
    private var generation = 0
    private var backlog = 0
    // 큐에서만 만지는 것
    private var store = CaptureStore()
    private var streamStarted = false
    private var lastPublish = Date.distantPast
    private var view: (display: CaptureFilter, search: String) = (.all, "")
    private var selection: (row: Int?, conversation: String?) = (nil, nil)
    private var vendors: (@Sendable (String) -> String?)?
    /// 마지막 사본 뒤 바뀐 게 있음 (잠금) — 조용해진 뒤 남은 패킷을 본 스레드가 flush 로 내보낸다
    private var unpublished = false

    var status: Status { lock.withLock { shared } }

    func newStream(_ generation: Int) {
        lock.withLock {
            self.generation = generation
            shared.started = false
            shared.failure = nil
            backlog = 0
        }
        queue.async { [self] in streamStarted = false }
    }

    func enqueue(_ packets: [CapturedPacket], linkType: UInt32, generation: Int) {
        let accepted: Bool = lock.withLock {
            guard generation == self.generation else { return false }   // 멈춘 옛 프로세스의 조각
            if !packets.isEmpty, backlog + packets.count > Self.backlogLimit {
                shared.skipped += packets.count
                return false
            }
            backlog += packets.count
            if !shared.started { shared.started = true }
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            guard lock.withLock({ generation == self.generation }) else { return }
            if !streamStarted {
                // 새 흐름의 링크 종류가 다르면(장치를 바꿈) 앞의 목록과 섞지 않는다
                if linkType != store.linkType, store.totalPackets > 0 { store = CaptureStore(); store.vendorLookup = vendors }
                store.setLinkType(linkType)
                streamStarted = true
            }
            store.ingest(packets)
            lock.withLock { backlog = max(0, backlog - packets.count); unpublished = true }
            publish(force: false)
        }
    }

    /// 목록 거르기·검색이 바뀌면 큐에서 다시 걸러 내보낸다
    func setView(_ display: CaptureFilter, _ search: String) {
        queue.async { [self] in
            view = (display, search)
            publish(force: true)
        }
    }

    /// 고른 행·대화가 바뀌면 큐에서 바로 사본을 만들고 done 을 부른다 (본 스레드가 곧장 가져가게)
    func setSelection(_ row: Int?, _ conversation: String?, done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            selection = (row, conversation)
            publish(force: true)
            done()
        }
    }

    /// .pcap 저장용 바이트 — 큐에서 만든다 (화면 사본엔 행 전체가 없다)
    func pcapData() async -> Data {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                store.trimRows()
                continuation.resume(returning: store.pcapData())
            }
        }
    }

    func setVendors(_ table: OUITable?) {
        guard let table else { return }
        queue.async { [self] in
            guard vendors == nil else { return }
            vendors = { table.vendor(mac: $0) }
            store.vendorLookup = vendors
        }
    }

    func fail(_ message: String, generation: Int) {
        lock.withLock { if generation == self.generation { shared.failure = message } }
    }

    func reset() {
        queue.async { [self] in
            store.reset()
            publish(force: true)
        }
        lock.withLock {
            shared.snapshot = CaptureSnapshot(linkType: shared.snapshot.linkType)
            shared.version += 1
            shared.skipped = 0
        }
    }

    /// 본 스레드 0.5초 주기: 내보내지 않은 변경이 있으면 큐에 사본을 부탁한다 (기다리지 않는다)
    func flushIfNeeded() {
        guard lock.withLock({ unpublished }) else { return }
        queue.async { [self] in publish(force: true) }
    }

    /// 0.4초마다(또는 강제로) 화면용 사본. 저장소는 넘기지 않는다 — 넘긴 사본이 살아 있으면 다음 패킷이 버퍼 전부를 복사한다.
    /// 목록 자르기·거르기·상위 대화 계산도 여기서 (본 스레드에서 하지 않게)
    private func publish(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublish) >= 0.4 else { return }
        lastPublish = now
        lock.withLock { unpublished = false }
        let snapshot = store.snapshot(display: view.display, search: view.search, shown: PacketCaptureController.shownLimit,
                                      selectedRow: selection.row, selectedConversation: selection.conversation)
        lock.withLock {
            shared.snapshot = snapshot
            shared.version += 1
        }
    }
}
