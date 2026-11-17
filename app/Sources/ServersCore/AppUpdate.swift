// 앱 업데이트 띠(사이드바 아래)의 상태. 업데이트 엔진(Sparkle)이 알리는 일을 순서대로 받아 화면 값으로 바꾼다 — 화면(UpdateBanner)은 그리기만.
// 새 버전이 없으면 띠 자체가 없다(.none). 실패는 띠에 남겨 다시 시도할 수 있게 한다.

public enum AppUpdate: Equatable, Sendable {
    case none
    case available(version: String)
    /// expected 가 0 이면 크기를 아직 모른다 (진행률 없음)
    case downloading(version: String, received: UInt64, expected: UInt64)
    /// 받은 것을 풀고 검증하는 중
    case preparing(version: String)
    /// 앱을 바꾸는 중 — 곧 꺼졌다 다시 켜진다
    case installing(version: String)
    case failed(version: String)

    public enum Event: Equatable, Sendable {
        case found(version: String)
        case downloadStarted
        case expected(UInt64)
        case received(UInt64)
        case extracting
        case installing
        case failed
        /// 확인했더니 새 버전이 없다 (실패 띠에서 다시 시도한 결과일 수 있다)
        case notFound
        /// 엔진이 한 번의 확인·설치 과정을 끝냈다 (성공·취소·오류 뒤 모두 온다)
        case dismissed
    }

    public var version: String? {
        switch self {
        case .none: return nil
        case .available(let v), .downloading(let v, _, _), .preparing(let v), .installing(let v), .failed(let v): return v
        }
    }

    /// 받기·설치가 진행 중 (그동안 새 "발견" 알림으로 띠를 되돌리지 않는다)
    public var isWorking: Bool {
        switch self {
        case .downloading, .preparing, .installing: return true
        case .none, .available, .failed: return false
        }
    }

    public func applying(_ event: Event) -> AppUpdate {
        switch event {
        case .found(let version):
            return isWorking ? self : .available(version: version)
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
        case .installing:
            guard let version else { return self }
            return .installing(version: version)
        case .failed:
            guard let version else { return self }
            return .failed(version: version)
        case .notFound:
            return isWorking ? self : .none
        case .dismissed:
            // 실패는 남긴다 (다시 시도). 나머지는 과정이 끝났으니 띠를 치운다 — 아직 남은 새 버전은 다음 확인 때 다시 온다
            if case .failed = self { return self }
            return .none
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
        case .downloading: return progress.map { "받는 중 \(Int($0 * 100))%" } ?? "받는 중…"
        case .preparing: return "설치 준비 중…"
        case .installing: return "설치 중 · 곧 다시 시작합니다"
        case .failed: return "업데이트 실패"
        }
    }

    /// 띠의 버튼 글자. 진행 중엔 버튼이 없다
    public var buttonTitle: String? {
        switch self {
        case .available: return "업데이트"
        case .failed: return "다시 시도"
        case .none, .downloading, .preparing, .installing: return nil
        }
    }

    /// 업데이트는 앱을 다시 시작한다 — 끊길 것이 있으면 누르기 전에 알릴 문구, 없으면 nil (바로 시작)
    public static func restartWarning(tabs: Int, tunnels: Int, transfers: Int) -> String? {
        let parts = [(tabs, "터미널 탭"), (tunnels, "터널"), (transfers, "진행 중인 전송")]
            .filter { $0.0 > 0 }.map { "\($0.1) \($0.0)개" }
        guard !parts.isEmpty else { return nil }
        return "업데이트하면 앱이 다시 시작되어 \(parts.joined(separator: " · "))가 끊깁니다."
    }
}
