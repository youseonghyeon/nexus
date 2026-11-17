// 앱 업데이트 띠(사이드바 아래)의 상태. 업데이트 엔진(Sparkle)이 알리는 일을 순서대로 받아 화면 값으로 바꾼다 — 화면(UpdateBanner)은 그리기만.
// 새 버전이 없으면 띠 자체가 없다(.none). 한번 뜬 띠는 설치가 끝나 앱이 다시 시작될 때까지 남는다:
// 실패하면 [다시 시도], 과정이 중간에 닫히면(권한 창 취소 등) 다시 [업데이트].

public enum AppUpdate: Equatable, Sendable {
    case none
    case available(version: String)
    /// [다시 시도] 뒤 새 버전을 다시 확인하는 중
    case checking(version: String)
    /// expected 가 0 이면 크기를 아직 모른다 (진행률 없음)
    case downloading(version: String, received: UInt64, expected: UInt64)
    /// 받은 것을 풀고 검증하는 중
    case preparing(version: String)
    /// 설치 준비가 끝났지만 다시 시작을 미뤘다 — 받는 사이 새 작업(탭·터널·전송)이 생겨 한 번 더 묻는다
    case ready(version: String)
    /// 앱을 바꾸는 중 — 곧 꺼졌다 다시 켜진다
    case installing(version: String)
    case failed(version: String)

    public enum Event: Equatable, Sendable {
        case found(version: String)
        /// [다시 시도] 를 눌러 다시 확인을 시작했다
        case retrying
        case downloadStarted
        case expected(UInt64)
        case received(UInt64)
        case extracting
        /// 설치 준비 끝 — 다시 시작을 사용자에게 다시 묻느라 미뤘다
        case readyHeld
        case installing
        case failed
        /// 확인했더니 새 버전이 없다 (실패 띠에서 다시 시도한 결과일 수 있다)
        case notFound
        /// 엔진이 한 번의 확인·설치 과정을 끝냈다 (취소·오류 뒤 모두 온다 — 성공하면 그 전에 앱이 꺼진다)
        case dismissed
    }

    public var version: String? {
        switch self {
        case .none: return nil
        case .available(let v), .checking(let v), .downloading(let v, _, _), .preparing(let v), .ready(let v), .installing(let v), .failed(let v): return v
        }
    }

    /// 받기·설치가 진행 중 (그동안 새 "발견" 알림으로 띠를 되돌리지 않는다)
    public var isWorking: Bool {
        switch self {
        case .downloading, .preparing, .ready, .installing: return true
        case .none, .available, .checking, .failed: return false
        }
    }

    public func applying(_ event: Event) -> AppUpdate {
        switch event {
        case .found(let version):
            return isWorking ? self : .available(version: version)
        case .retrying:
            guard let version, !isWorking else { return self }
            return .checking(version: version)
        case .downloadStarted:
            guard let version, !isWorking else { return self }
            return .downloading(version: version, received: 0, expected: 0)
        case .expected(let total):
            guard case .downloading(let version, let received, _) = self else { return self }
            return .downloading(version: version, received: min(received, total), expected: total)
        case .received(let count):
            guard case .downloading(let version, let received, let expected) = self else { return self }
            // 압축 전송이면 받은 양이 알린 크기를 넘는다 — 100% 를 넘기지 않는다
            let sum = received &+ count
            return .downloading(version: version, received: expected > 0 ? min(sum, expected) : sum, expected: expected)
        case .extracting:
            guard let version, self != .failed(version: version) else { return self }
            return .preparing(version: version)
        case .readyHeld:
            guard let version else { return self }
            return .ready(version: version)
        case .installing:
            guard let version else { return self }
            return .installing(version: version)
        case .failed:
            guard let version else { return self }
            return .failed(version: version)
        case .notFound:
            return isWorking ? self : .none
        case .dismissed:
            // 실패는 남긴다 (다시 시도). 진행 중에 닫혔으면(권한 창 취소 등 — 오류 없이 닫힌다) 새 버전은 그대로 있으니 처음 띠로 되돌린다.
            // 아무것도 안 한 채 닫힌 띠만 치운다 — 새 버전이 남아 있으면 다음 확인 때 다시 온다
            switch self {
            case .failed, .none: return self
            case .checking(let v), .downloading(let v, _, _), .preparing(let v), .ready(let v), .installing(let v): return .available(version: v)
            case .available: return .none
            }
        }
    }

    // MARK: 화면 값

    /// 띠 윗줄 ("Nexus 1.2.0")
    public func title(appName: String) -> String? { version.map { "\(appName) \($0)" } }

    /// 0…1. 크기를 모르거나 받는 중이 아니면 nil
    public var progress: Double? {
        guard case .downloading(_, let received, let expected) = self, expected > 0 else { return nil }
        return Double(received) / Double(expected)
    }

    /// 띠 아랫줄
    public var subtitle: String? {
        switch self {
        case .none: return nil
        case .available: return "새 버전이 있습니다"
        case .checking: return "확인 중…"
        case .downloading: return progress.map { "받는 중 \(Int($0 * 100))%" } ?? "받는 중…"
        case .preparing: return "설치 준비 중…"
        case .ready: return "다시 시작하면 적용됩니다"
        case .installing: return "설치 중 · 곧 다시 시작합니다"
        case .failed: return "업데이트 실패"
        }
    }

    /// 띠의 버튼 글자. 진행 중엔 버튼이 없다
    public var buttonTitle: String? {
        switch self {
        case .available: return "업데이트"
        case .ready: return "다시 시작"
        case .failed: return "다시 시도"
        case .none, .checking, .downloading, .preparing, .installing: return nil
        }
    }

    /// 화면에 보이는 것이 같은가 — 받는 중 알림은 조각마다 오지만 띠는 퍼센트가 바뀔 때만 다시 그리면 된다
    public func looksSame(as other: AppUpdate) -> Bool {
        version == other.version && subtitle == other.subtitle && buttonTitle == other.buttonTitle
    }

    /// 메뉴에서 확인을 눌렀는데 이미 띠가 떠 있을 때 알릴 문구 (띠를 못 본 경우 — 사이드바를 접었거나 창을 숨김). 띠가 없으면 nil
    public var reminder: String? {
        guard let version, let subtitle else { return nil }
        switch self {
        case .available, .ready: return "새 버전 \(version) · 사이드바 아래의 [\(buttonTitle ?? "업데이트")] 를 누르세요"
        default: return "새 버전 \(version) · \(subtitle)"
        }
    }

    // MARK: 다시 시작 전 확인

    /// 업데이트는 앱을 다시 시작한다 — 끊길 것이 있으면 누르기 전에 알릴 문구, 없으면 nil (바로 시작)
    public static func restartWarning(tabs: Int, tunnels: Int, transfers: Int) -> String? {
        let parts = [(tabs, "터미널 탭"), (tunnels, "터널"), (transfers, "진행 중인 전송")]
            .filter { $0.0 > 0 }.map { "\($0.1) \($0.0)개" }
        guard !parts.isEmpty else { return nil }
        return "업데이트하면 앱이 다시 시작되어 \(parts.joined(separator: " · "))가 끊깁니다."
    }

    /// 설치 준비가 끝났을 때 바로 다시 시작해도 되는가. 사용자는 [업데이트]를 누를 때 본(확인한) 만큼만 끊기는 데 동의했다 —
    /// 받는 사이 탭·터널·전송이 늘었으면 미루고 한 번 더 묻는다.
    public static func restartsImmediately(confirmed: Int, now: Int) -> Bool { now <= confirmed }
}
