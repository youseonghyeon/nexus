// ServerHistory: 받은 결과 → 견줄 값 · 지난번과 견주기(처음 본 구역 · 못 읽은 구역은 사건 없음) · 기록 · 저장 · 시각 글.

import Foundation
import XCTest
@testable import ServersCore

final class ServerHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func spec(os: String = "Ubuntu 24.04.5 LTS", kernel: String = "6.8.0-139-generic", reboot: String = "필요 없음", updatesLine: Bool = true) -> [SpecItem] {
        var items = [SpecItem(key: "HOSTNAME", value: "web01", usage: nil, label: "호스트"), SpecItem(key: "OS", value: os, usage: nil, label: "OS"),
                     SpecItem(key: "KERNEL", value: kernel, usage: nil, label: "Kernel"), SpecItem(key: "REBOOT", value: reboot, usage: nil, label: "재부팅"),
                     SpecItem(key: "UPTIME", value: "12일 22시간", usage: nil, label: "가동 시간"), SpecItem(key: "MEM", value: "15Gi total", usage: 0.37, label: "메모리")]
        if updatesLine { items.append(SpecItem(key: "UPDATES", value: "2개", usage: nil, label: "업데이트")) }
        return items
    }
    private func update(_ name: String, _ version: String = "2.0", security: Bool = false) -> UpdateItem {
        UpdateItem(name: name, suites: security ? "noble-updates,noble-security" : "noble-updates", version: version, installed: "1.0")
    }
    private func port(_ number: Int, _ label: String? = nil) -> PortItem { PortItem(port: number, addresses: ["*"], label: label, tunnelAddress: "127.0.0.1") }
    private func unit(_ name: String) -> ServiceUnit {
        ServiceUnit(name: name, description: "", uptime: nil, restarts: nil, state: "failed", result: "exit-code", changedAgo: 10, basic: false)
    }
    /// 한 서버에 결과를 차례로 넣으며 생긴 사건 글만 모은다
    private func feed(_ steps: [ParsedRemoteInfo], type: ServerType = .linux) -> (state: HistoryState, texts: [[String]]) {
        var state = HistoryState(), texts: [[String]] = []
        for (i, parsed) in steps.enumerated() {
            guard let observed = ServerHistory.observe(parsed, type: type) else { texts.append(["(견주지 않음)"]); continue }
            let result = ServerHistory.record(observed, serverKey: "web01", at: t0.addingTimeInterval(Double(i) * 3600), in: state)
            state = result.state
            texts.append(result.events.map(\.text))
        }
        return (state, texts)
    }

    // MARK: 견줄 값

    func testObserveKeepsOnlyComparableValues() {
        let observed = ServerHistory.observe(.spec(spec(), updates: [update("curl", security: true)]), type: .linux)
        XCTAssertEqual(observed?.spec, ["OS": "Ubuntu 24.04.5 LTS", "KERNEL": "6.8.0-139-generic", "REBOOT": "필요 없음"], "가동 시간·메모리처럼 늘 바뀌는 값은 견주지 않는다")
        XCTAssertEqual(observed?.updates, ["curl": .init(version: "2.0", security: true)])
        XCTAssertNil(observed?.ports); XCTAssertNil(observed?.failed)
        XCTAssertNil(ServerHistory.observe(.spec(spec(updatesLine: false), updates: []), type: .linux)?.updates, "업데이트 줄이 없으면(apt 를 못 읽음) 빈 목록을 믿지 않는다")
        XCTAssertNil(ServerHistory.observe(.spec(spec(), updates: []), type: .windows)?.updates, "패키지 목록은 linux 만")
        XCTAssertNil(ServerHistory.observe(.spec([], updates: []), type: .linux))
        XCTAssertEqual(ServerHistory.observe(.ports([port(22, "ssh"), port(9090)]), type: .linux)?.ports, ["22": "ssh", "9090": ""])
        XCTAssertNil(ServerHistory.observe(.ports([]), type: .linux), "빈 포트 목록은 못 읽은 것")
        for other in [ParsedRemoteInfo.none, .schedule(nil), .services(nil), .linuxNetwork(nil)] { XCTAssertNil(ServerHistory.observe(other, type: .linux)) }
    }

    func testObserveServicesSkipsWhatItCouldNotRead() {
        var report = ServicesReport()
        report.failed = [unit("nginx"), unit("backup")]
        report.containers = [ContainerItem(kind: .docker, name: "web", status: "Up", detail: "nginx:1.27"), ContainerItem(kind: .pod, name: "app/api-7d9f-x2k", status: "Running")]
        report.sources = ["docker": .ok, "k3s": .ok]
        let full = ServerHistory.observe(.services(report), type: .linux)
        XCTAssertEqual(full?.failed, ["backup", "nginx"])
        XCTAssertEqual(full?.containers, ["docker|web": "nginx:1.27"], "파드는 넣지 않는다 — 이름이 뜰 때마다 바뀐다")
        report.sources["docker"] = .denied
        XCTAssertNil(ServerHistory.observe(.services(report), type: .linux)?.containers, "권한이 없어 못 읽었으면 컨테이너는 견주지 않는다")
        XCTAssertNotNil(ServerHistory.observe(.services(report), type: .linux)?.failed)
        report.sources["docker"] = .ok; report.truncated = ["docker": 500]
        XCTAssertNil(ServerHistory.observe(.services(report), type: .linux)?.containers, "잘린 목록도")
        report.truncated = [:]; report.noSystemd = true; report.failed = []
        XCTAssertNil(ServerHistory.observe(.services(report), type: .linux)?.failed, "systemd 가 없으면 서비스는 견주지 않는다")
    }

    // MARK: 견주기

    /// 처음 본 구역은 기준만 잡는다 — 새 서버를 열었다고 열린 포트 전부가 "열림"으로 쏟아지지 않는다
    func testFirstObservationOfEachSectionMakesNoEvents() {
        var report = ServicesReport(); report.failed = [unit("nginx")]; report.sources = ["docker": .ok]
        let result = feed([.spec(spec(), updates: [update("curl")]), .ports([port(22), port(80)]), .services(report)])
        XCTAssertEqual(result.texts, [[], [], []])
        XCTAssertEqual(result.state.servers["web01"]?.events, [])
        XCTAssertEqual(result.state.servers["web01"]?.snapshot.ports, ["22": "", "80": ""])
    }

    func testSpecAndPackageChanges() {
        let result = feed([
            .spec(spec(), updates: [update("docker-ce"), update("needrestart", security: true), update("snapd")]),
            .spec(spec(), updates: [update("docker-ce"), update("needrestart", security: true), update("snapd")]),               // 그대로
            .spec(spec(reboot: "필요"), updates: [update("docker-ce"), update("snapd", "3.0")]),                                   // 보안 패치가 들어갔다 · 올라갈 버전만 바뀐 것은 조용히
            .spec(spec(kernel: "6.8.0-140-generic"), updates: [update("docker-ce"), update("snapd", "3.0"), update("curl"), update("openssl", security: true)]),
            .spec(spec(kernel: "6.8.0-140-generic"), updates: []),
        ])
        XCTAssertEqual(result.texts[1], [])
        XCTAssertEqual(result.texts[2], ["재부팅 필요해짐", "업데이트 설치됨 1개 (보안 1): needrestart"])
        XCTAssertEqual(result.texts[3], ["Kernel 6.8.0-139-generic → 6.8.0-140-generic", "재부팅 필요 없어짐", "새 업데이트 2개 (보안 1): curl, openssl"])
        XCTAssertEqual(result.texts[4], ["업데이트 설치됨 4개 (보안 1): curl, docker-ce, openssl, snapd"])
        // 기록은 최근 것이 앞
        XCTAssertEqual(result.state.servers["web01"]?.events.first?.text, "업데이트 설치됨 4개 (보안 1): curl, docker-ce, openssl, snapd")
        XCTAssertEqual(result.state.servers["web01"]?.events.last?.text, "재부팅 필요해짐")
        XCTAssertTrue(result.state.servers["web01"]?.events.last?.warning ?? false)
        XCTAssertFalse(result.state.servers["web01"]?.events.first?.warning ?? true)
    }

    func testManyPackageNamesAreCut() {
        let many = (1...7).map { update("pkg\($0)") }
        let result = feed([.spec(spec(), updates: many), .spec(spec(), updates: [])])
        XCTAssertEqual(result.texts[1], ["업데이트 설치됨 7개: pkg1, pkg2, pkg3, pkg4 외 3"])
    }

    /// 업데이트 줄을 못 읽은 회차는 패키지를 견주지 않고, 지난 기준도 지우지 않는다
    func testUnreadSectionKeepsBaseline() {
        let result = feed([
            .spec(spec(), updates: [update("curl")]),
            .spec(spec(updatesLine: false), updates: []),     // apt 를 못 읽었다
            .ports([]),                                        // 못 읽은 포트
            .spec(spec(), updates: [update("curl")]),
        ])
        XCTAssertEqual(result.texts, [[], [], ["(견주지 않음)"], []], "못 읽은 것을 '설치됨'·'닫힘'으로 적지 않는다")
        XCTAssertEqual(result.state.servers["web01"]?.snapshot.updates?.keys.sorted(), ["curl"])
    }

    func testPortsServicesContainers() {
        func services(failed: [String], containers: [(String, String)]) -> ParsedRemoteInfo {
            var report = ServicesReport()
            report.failed = failed.map(unit); report.sources = ["docker": .ok]
            report.containers = containers.map { ContainerItem(kind: .docker, name: $0.0, status: "Up", detail: $0.1) }
            return .services(report)
        }
        let result = feed([
            .ports([port(22, "ssh"), port(80), port(5432, "postgres")]),
            .ports([port(22, "ssh"), port(9090, "grafana"), port(443)]),
            services(failed: [], containers: [("web", "nginx:1.27"), ("db", "postgres:16")]),
            services(failed: ["nginx"], containers: [("web", "nginx:1.28"), ("cache", "redis:7")]),
            services(failed: [], containers: [("web", "nginx:1.28"), ("cache", "redis:7")]),
        ])
        XCTAssertEqual(result.texts[1], ["포트 443 열림", "포트 9090 열림 (grafana)", "포트 80 닫힘", "포트 5432 닫힘 (postgres)"], "번호순 — 열린 것 먼저")
        XCTAssertEqual(result.texts[2], [], "서비스 구역은 처음 본다")
        XCTAssertEqual(result.texts[3], ["서비스 실패: nginx", "컨테이너 생김: cache (redis:7)", "컨테이너 사라짐: db", "컨테이너 이미지 바뀜: web nginx:1.27 → nginx:1.28"])
        XCTAssertEqual(result.texts[4], ["서비스 실패 풀림: nginx"])
        XCTAssertEqual(result.state.servers["web01"]?.events.filter(\.warning).map(\.text), ["서비스 실패: nginx"])
    }

    // MARK: 기록 · 저장

    func testRecordLimitsEventsAndIsPerServer() {
        var state = HistoryState()
        for i in 0..<130 {
            state = ServerHistory.record(ServerSnapshot(ports: [String(1000 + i): "", "22": ""]), serverKey: "web01", at: t0.addingTimeInterval(Double(i)), in: state).state
        }
        let events = ServerHistory.events(for: "web01", in: state)
        XCTAssertEqual(events.count, ServerHistory.eventLimit, "가장 오래된 것부터 버린다")
        XCTAssertEqual(events.first?.text, "포트 1128 닫힘")
        XCTAssertEqual(ServerHistory.events(for: "db01", in: state), [], "서버마다 따로")
        XCTAssertEqual(ServerHistory.record(ServerSnapshot(), serverKey: "web01", in: state).state, state, "본 구역이 없으면 그대로")
    }

    func testNoticeClearRenameRemove() {
        var state = feed([.ports([port(22)]), .ports([port(22), port(80), port(443)])]).state
        let events = ServerHistory.events(for: "web01", in: state)
        XCTAssertEqual(ServerHistory.notice(Array(events.reversed()), serverKey: "web01"), "web01: 포트 80 열림 외 1")
        XCTAssertEqual(ServerHistory.notice([events[0]], serverKey: "web01"), "web01: 포트 443 열림")
        XCTAssertNil(ServerHistory.notice([], serverKey: "web01"))

        let cleared = ServerHistory.clearingEvents("web01", in: state)
        XCTAssertEqual(cleared.servers["web01"]?.events, [])
        XCTAssertEqual(cleared.servers["web01"]?.snapshot.ports?.count, 3, "기준은 남는다 — 지금 상태가 다시 쏟아지지 않게")
        XCTAssertEqual(ServerHistory.record(ServerSnapshot(ports: ["22": "", "80": "", "443": ""]), serverKey: "web01", in: cleared).events, [])

        state = ServerHistory.renamingServer(from: "web01", to: "www", in: state)
        XCTAssertEqual(Array(state.servers.keys), ["www"])
        XCTAssertEqual(ServerHistory.renamingServer(from: "ghost", to: "www", in: state).servers, [:], "옛 것이 없으면 새 이름에 남은 값도 지운다")
        XCTAssertEqual(ServerHistory.removingServer("www", from: state).servers, [:])
    }

    func testSaveLoadRoundTripAndBrokenFileStartsEmpty() throws {
        let url = tempPath("history").appendingPathComponent("Servers/history.json")
        XCTAssertEqual(ServerHistory.load(from: url), HistoryState())
        let state = feed([.ports([port(22)]), .ports([port(22), port(80)]), .spec(spec(), updates: [update("curl", security: true)])]).state
        try ServerHistory.save(state, to: url)
        XCTAssertEqual(ServerHistory.load(from: url), state)
        try Data("{broken".utf8).write(to: url)
        XCTAssertEqual(ServerHistory.load(from: url), HistoryState(), "다시 쌓이는 값이라 깨졌으면 빈 상태로")
    }

    func testTimeText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
        let now = date(2026, 11, 18, 16, 30)
        XCTAssertEqual(ServerHistory.timeText(date(2026, 11, 18, 9, 5), now: now, calendar: calendar), "오늘 09:05")
        XCTAssertEqual(ServerHistory.timeText(date(2026, 11, 17, 23, 59), now: now, calendar: calendar), "어제 23:59", "달력 날짜로 가른다 (24시간이 안 지났어도)")
        XCTAssertEqual(ServerHistory.timeText(date(2026, 11, 16, 0, 0), now: now, calendar: calendar), "11-16 00:00")
        XCTAssertEqual(ServerHistory.timeText(date(2025, 12, 31, 12, 0), now: now, calendar: calendar), "2025-12-31")
        XCTAssertEqual(ServerHistory.timeText(date(2026, 1, 1, 0, 0), now: date(2026, 1, 2, 0, 0), calendar: calendar), "어제 00:00")
    }
}
