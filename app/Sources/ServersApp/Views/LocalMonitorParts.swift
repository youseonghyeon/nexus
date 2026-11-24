// LOCAL 의 시스템·디스크·블루투스 화면이 같이 쓰는 부품: 보이는 동안만 도는 수집 루프 · 머리글 · 비율 막대.

import ServersCore
import SwiftUI

extension View {
    /// 이 화면이 떠 있는 동안 seconds() 마다 body 를 부른다 (화면을 떠나면 멈춘다). 창이 숨겨져 있거나 가려져 있으면 건너뛴다.
    /// 간격은 돌 때마다 다시 읽는다 — 설정 창에서 바꾸면 다음 대기부터.
    func sampling(every seconds: @escaping @MainActor () -> Double, _ body: @escaping @MainActor () async -> Void) -> some View {
        task {
            while !Task.isCancelled {
                if AppModel.mainWindowVisible { await body() }
                try? await Task.sleep(for: .seconds(seconds()))
            }
        }
    }
}

extension SystemHealth.Level {
    var tone: StatusTone {
        switch self {
        case .good: return .good
        case .warn: return .warn
        case .bad: return .bad
        }
    }

    /// 수치 글자 색: 평소엔 무채색, 경고 이상만 색. 막대·그래프는 tone 그대로 (정상 초록 · 경고 노랑 · 위험 빨강 — 2026-10-02 회색이 탁해 보여 바꿈)
    var valueTone: StatusTone { self == .good ? .muted : tone }
}

/// 망 Dashboard 와 같은 머리글: 큰 제목 · 부제 | 상태 점 + 결론 · 확인 시각
struct LocalHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let tone: StatusTone
    let conclusion: String
    var checkedAt: Date?
    var interval: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.screenTitle).tracking(-0.6)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(text: conclusion, tone: tone)
                if let checkedAt {
                    Text(["\(checkedAt.formatted(date: .omitted, time: .shortened)) 확인", interval].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                accessory.padding(.top, 2)
            }
        }
    }
}

extension LocalHeader where Accessory == EmptyView {
    init(title: String, subtitle: String, tone: StatusTone, conclusion: String, checkedAt: Date? = nil, interval: String? = nil) {
        self.init(title: title, subtitle: subtitle, tone: tone, conclusion: conclusion, checkedAt: checkedAt, interval: interval) { EmptyView() }
    }
}

/// 여러 몫을 한 줄에 이어 칠한 막대 (메모리 구성·디스크 사용). 몫마다 무채색 농도로 가른다. 남는 자리는 바탕.
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let opacity: Double
    }
    let segments: [Segment]
    let total: Double
    /// 마우스가 올라간 몫의 id (벗어나면 nil). 풀이를 바로 띄우려는 쪽이 받는다 — 시스템 풀이말(.help)은 5초쯤 지나야 뜬다
    var onHover: ((String?) -> Void)?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(Color.primary.opacity(segment.opacity))
                        .frame(width: total > 0 ? max(0, geo.size.width * segment.value / total - 1) : 0)
                        .onHover { inside in onHover?(inside ? segment.id : nil) }
                }
                Spacer(minLength: 0)
            }
            .background(Palette.track)
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

/// 막대 몫의 범례 칸 (몫과 같은 농도의 작은 네모)
struct Swatch: View {
    let opacity: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(opacity)).frame(width: 9, height: 9)
    }
}
