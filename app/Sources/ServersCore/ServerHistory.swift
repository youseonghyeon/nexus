// 변화 기록 (2026-11-18): 원격 정보(Spec · Ports · Services)를 받을 때마다 견줄 값만 추려 두고, 지난번과 달라진 것을 사건으로 남긴다.
// "보안 업데이트 1개가 왜 사라졌지?", "9090 이 언제부터 열렸지?" 를 서버 로그를 뒤지지 않고 답하려는 것. 서버에는 아무것도 더 보내지 않는다 —
// 이미 받은 결과를 견줄 뿐이다 (서버 화면의 "변화 기록" 카드).
//   견주는 것: Spec 의 OS · Kernel · 재부팅 필요 · 올릴 수 있는 패키지 / 열린 포트 / 실패한 서비스 · 컨테이너(이미지).
//   처음 본 구역은 기준만 잡고 사건을 만들지 않는다. 못 읽은 구역(권한 없음 · 형식 모름 · 너무 많아 잘림)은 견주지 않는다 — 못 읽은 것을 "사라짐"으로 적지 않게.
// 저장: ~/Library/Application Support/Servers/history.json (저장소 밖). 서버마다 마지막 값과 사건 최근 200개. 깨졌으면 빈 상태로 시작한다 (다시 쌓이는 값이다).
// 이 파일은 견주기와 목록 바꾸기만 (순수 함수, 테스트 대상).

import Foundation

/// 한 서버의 견줄 값. 구역마다 nil = 아직 본 적 없음(또는 이번에 못 읽음)
public struct ServerSnapshot: Codable, Sendable, Equatable {
    public struct Package: Codable, Sendable, Equatable {
        /// 올라갈 버전
        public var version: String
        public var security: Bool
        public init(version: String, security: Bool) { self.version = version; self.security = security }
    }
    /// Spec 의 견줄 값: 키(OS · KERNEL · REBOOT) → 화면 값
    public var spec: [String: String]?
    /// 올릴 수 있는 패키지: 이름 → 올라갈 버전 (linux)
    public var updates: [String: Package]?
    /// 열린 포트: 번호(글자) → 이름표 (없으면 빈 글)
    public var ports: [String: String]?
    /// 실패한 서비스 이름
    public var failed: [String]?
    /// docker 컨테이너: "docker|이름" → 이미지 (파드는 넣지 않는다 — 이름이 뜰 때마다 바뀐다)
    public var containers: [String: String]?

    public init(spec: [String: String]? = nil, updates: [String: Package]? = nil, ports: [String: String]? = nil,
                failed: [String]? = nil, containers: [String: String]? = nil) {
        self.spec = spec; self.updates = updates; self.ports = ports; self.failed = failed; self.containers = containers
    }

    var isEmpty: Bool { spec == nil && updates == nil && ports == nil && failed == nil && containers == nil }
}

public struct HistoryEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case system, reboot, packages, portOpened, portClosed, serviceFailed, serviceRecovered, containerAdded, containerRemoved, containerImage
    }
    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), at: Date, kind: Kind, text: String) { self.id = id; self.at = at; self.kind = kind; self.text = text }

    /// 눈여겨볼 사건 (경고색): 서비스 실패 · 재부팅 필요해짐
    public var warning: Bool { kind == .serviceFailed || (kind == .reboot && text.hasSuffix("필요해짐")) }
}

public struct HistoryState: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var snapshot = ServerSnapshot()
        /// 최근 것이 앞
        public var events: [HistoryEvent] = []
        public init(snapshot: ServerSnapshot = ServerSnapshot(), events: [HistoryEvent] = []) { self.snapshot = snapshot; self.events = events }
    }
    public var servers: [String: Entry] = [:]
    public init(servers: [String: Entry] = [:]) { self.servers = servers }
}

public enum ServerHistory {
    public static let eventLimit = 200
    /// 한 사건에 이름을 늘어놓는 수 (넘으면 "외 N")
    static let nameLimit = 4
    /// Spec 에서 견주는 키와 사건에 쓸 이름
    static let specKeys: [(key: String, label: String)] = [("OS", "OS"), ("KERNEL", "Kernel")]

    public static var defaultURL: URL { AppSupport.baseURL.appendingPathComponent("history.json") }

    public static func load(from url: URL = defaultURL) -> HistoryState {
        guard let data = try? Data(contentsOf: url) else { return HistoryState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(HistoryState.self, from: data)) ?? HistoryState()
    }

    public static func save(_ state: HistoryState, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    // MARK: 받은 결과 → 견줄 값

    /// 원격 정보 결과에서 견줄 구역만 추린다. 견줄 것이 없는 탭 · 못 읽은 결과면 nil.
    public static func observe(_ parsed: ParsedRemoteInfo, type: ServerType) -> ServerSnapshot? {
        switch parsed {
        case let .spec(items, updates):
            var spec: [String: String] = [:]
            for item in items where specKeys.contains(where: { $0.key == item.key }) || item.key == "REBOOT" { spec[item.key] = item.value }
            guard !spec.isEmpty else { return nil }
            // 패키지 목록은 Spec 에 업데이트 줄이 있을 때만 믿는다 (apt 가 없거나 못 읽었으면 줄이 없다 — 빈 목록을 "다 올라감"으로 읽지 않게)
            let listed = type == .linux && items.contains { $0.key == "UPDATES" }
            let packages = Dictionary(updates.map { ($0.name, ServerSnapshot.Package(version: $0.version, security: $0.security)) }) { first, _ in first }
            return ServerSnapshot(spec: spec, updates: listed ? packages : nil)
        case let .ports(items):
            // ssh 로 들어온 서버에 열린 포트가 하나도 없을 수는 없다 — 빈 목록은 못 읽은 것
            guard !items.isEmpty else { return nil }
            return ServerSnapshot(ports: Dictionary(items.map { (String($0.port), $0.label ?? $0.process ?? "") }) { first, _ in first })
        case let .services(report):
            guard let report else { return nil }
            // 컨테이너는 출처를 다 읽었을 때만 (권한 없음 · 데몬 꺼짐 · 잘림이면 목록이 비거나 모자라다)
            let complete = report.truncated.isEmpty && report.sources.values.allSatisfy { $0 == .ok }
            // docker 컨테이너만: 파드는 이름에 해시가 붙어 다시 뜰 때마다(CronJob 은 돌 때마다) 새 이름이라 사건이 쏟아진다
            let containers = Dictionary(report.containers.filter { $0.kind == .docker }.map { ($0.id, $0.detail) }) { first, _ in first }
            let snapshot = ServerSnapshot(failed: report.noSystemd ? nil : report.failed.map(\.name).sorted(), containers: complete ? containers : nil)
            return snapshot.isEmpty ? nil : snapshot
        default:
            return nil
        }
    }

    // MARK: 견주기

    /// 이번에 본 구역(partial 에서 nil 이 아닌 것)만 지난 값과 견줘 사건을 만든다. 지난 값이 없는 구역은 기준만 잡는다.
    static func diff(old: ServerSnapshot, new partial: ServerSnapshot, at: Date) -> [HistoryEvent] {
        var events: [HistoryEvent] = []
        func add(_ kind: HistoryEvent.Kind, _ text: String) { events.append(HistoryEvent(at: at, kind: kind, text: text)) }

        if let was = old.spec, let now = partial.spec {
            for (key, label) in specKeys {
                if let a = was[key], let b = now[key], a != b { add(.system, "\(label) \(a) → \(b)") }
            }
            if let a = was["REBOOT"], let b = now["REBOOT"], a != b { add(.reboot, b == "필요" ? "재부팅 필요해짐" : "재부팅 필요 없어짐") }
        }
        if let was = old.updates, let now = partial.updates {
            // 목록에서 빠진 것 = 설치됐다 (보류가 풀려 올라간 것 포함). 올라갈 버전만 바뀐 것은 적지 않는다 (같은 패키지의 다음 판)
            let gone = was.keys.filter { now[$0] == nil }.sorted()
            if !gone.isEmpty {
                let security = gone.filter { was[$0]?.security == true }.count
                add(.packages, "업데이트 설치됨 \(gone.count)개" + (security > 0 ? " (보안 \(security))" : "") + ": " + names(gone))
            }
            let fresh = now.keys.filter { was[$0] == nil }.sorted()
            if !fresh.isEmpty {
                let security = fresh.filter { now[$0]?.security == true }.count
                add(.packages, "새 업데이트 \(fresh.count)개" + (security > 0 ? " (보안 \(security))" : "") + ": " + names(fresh))
            }
        }
        if let was = old.ports, let now = partial.ports {
            let order: (String, String) -> Bool = { (Int($0) ?? 0) < (Int($1) ?? 0) }
            for port in now.keys.filter({ was[$0] == nil }).sorted(by: order) {
                add(.portOpened, "포트 \(port) 열림" + (now[port].flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""))
            }
            for port in was.keys.filter({ now[$0] == nil }).sorted(by: order) {
                add(.portClosed, "포트 \(port) 닫힘" + (was[port].flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""))
            }
        }
        if let was = old.failed, let now = partial.failed {
            for name in now.filter({ !was.contains($0) }) { add(.serviceFailed, "서비스 실패: \(name)") }
            for name in was.filter({ !now.contains($0) }) { add(.serviceRecovered, "서비스 실패 풀림: \(name)") }
        }
        if let was = old.containers, let now = partial.containers {
            for id in now.keys.filter({ was[$0] == nil }).sorted() {
                add(.containerAdded, "컨테이너 생김: \(containerName(id))" + (now[id].flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""))
            }
            for id in was.keys.filter({ now[$0] == nil }).sorted() { add(.containerRemoved, "컨테이너 사라짐: \(containerName(id))") }
            for id in now.keys.sorted() {
                if let a = was[id], let b = now[id], a != b, !a.isEmpty, !b.isEmpty { add(.containerImage, "컨테이너 이미지 바뀜: \(containerName(id)) \(a) → \(b)") }
            }
        }
        return events
    }

    private static func names(_ list: [String]) -> String {
        list.prefix(nameLimit).joined(separator: ", ") + (list.count > nameLimit ? " 외 \(list.count - nameLimit)" : "")
    }

    /// "docker|web" → "web"
    private static func containerName(_ id: String) -> String {
        id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? id
    }

    /// 이번에 본 구역을 기록한다: 달라진 것은 사건으로(최근 것이 앞, eventLimit 까지), 본 구역은 새 값으로 바꾼다. 안 본 구역은 그대로.
    public static func record(_ partial: ServerSnapshot, serverKey: String, at: Date = Date(), in state: HistoryState) -> (state: HistoryState, events: [HistoryEvent]) {
        guard !partial.isEmpty else { return (state, []) }
        var entry = state.servers[serverKey] ?? HistoryState.Entry()
        let events = diff(old: entry.snapshot, new: partial, at: at)
        if let spec = partial.spec { entry.snapshot.spec = spec }
        if let updates = partial.updates { entry.snapshot.updates = updates }
        if let ports = partial.ports { entry.snapshot.ports = ports }
        if let failed = partial.failed { entry.snapshot.failed = failed }
        if let containers = partial.containers { entry.snapshot.containers = containers }
        entry.events = Array((events.reversed() + entry.events).prefix(eventLimit))
        var next = state
        next.servers[serverKey] = entry
        return (next, events)
    }

    public static func events(for serverKey: String, in state: HistoryState) -> [HistoryEvent] { state.servers[serverKey]?.events ?? [] }

    /// 새 사건을 알리는 한 줄 (토스트): "web01: 포트 9090 열림 (grafana) 외 2"
    public static func notice(_ events: [HistoryEvent], serverKey: String) -> String? {
        guard let first = events.first else { return nil }
        return "\(serverKey): \(first.text)" + (events.count > 1 ? " 외 \(events.count - 1)" : "")
    }

    /// 사건의 시각: 오늘이면 "오늘 14:02", 어제면 "어제 09:10", 그 밖은 "11-17 09:10", 해가 다르면 "2025-11-17"
    public static func timeText(_ at: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let day = calendar.startOfDay(for: at), today = calendar.startOfDay(for: now)
        let gap = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if gap == 0 { return "오늘 \(clock)" }
        if gap == 1 { return "어제 \(clock)" }
        if parts.year != calendar.component(.year, from: now) { return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) }
        return String(format: "%02d-%02d \(clock)", parts.month ?? 0, parts.day ?? 0)
    }

    /// 사건만 지운다 (카드의 [비우기]) — 마지막 값은 남겨 지금 상태가 다시 사건으로 쏟아지지 않게
    public static func clearingEvents(_ serverKey: String, in state: HistoryState) -> HistoryState {
        var next = state
        next.servers[serverKey]?.events = []
        return next
    }

    /// 서버 이름을 바꿨다: 옛 이름의 것을 새 이름으로. 옛 것이 없으면 새 이름에 남은 값(지운 서버의 것)도 지운다
    public static func renamingServer(from old: String, to new: String, in state: HistoryState) -> HistoryState {
        guard old != new else { return state }
        var next = state
        next.servers[new] = next.servers.removeValue(forKey: old)
        return next
    }

    /// 서버를 목록에서 지웠다 · 접속 정보가 바뀌어 같은 이름이 다른 장비를 가리킨다
    public static func removingServer(_ key: String, from state: HistoryState) -> HistoryState {
        var next = state
        next.servers[key] = nil
        return next
    }
}
