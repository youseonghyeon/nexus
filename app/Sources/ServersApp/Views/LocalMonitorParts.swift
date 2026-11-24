// LOCAL 의 시스템·디스크·블루투스 화면이 같이 쓰는 부품: 보이는 동안만 도는 수집 루프 · 머리글 · 비율 막대.
// 서버 Live 탭과 같이 쓰는 것: 코어 막대 한 줄(CoreBar) · 메모리 구성 행의 네모와 숫자 칸.

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

    /// 메모리 구성 행의 네모 (System 화면 · 서버 Live 탭): 농도 0 은 빈 칸 테두리 (여유)
    static func legend(_ shade: Double) -> some View {
        Swatch(opacity: shade).overlay(shade == 0 ? RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.5)) : nil)
    }
}

/// 메모리 구성 행(GridRow)의 숫자 두 칸: 크기 · 전체에서의 몫 (System 화면 · 서버 Live 탭)
@ViewBuilder
func memoryShareCells(_ value: UInt64, of total: UInt64) -> some View {
    Text(SystemFormat.bytes(value)).monospacedDigit().gridColumnAlignment(.trailing)
    Text(total > 0 ? "\(Int((Double(value) / Double(total) * 100).rounded()))%" : "–").monospacedDigit().foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
}

/// 코어 하나의 막대 한 줄: 이름 · 막대 · 퍼센트 (System 화면 · 서버 Live 탭). 이름 · 숫자 칸 폭은 화면마다 다르다
struct CoreBar: View {
    let label: String
    let labelWidth: CGFloat
    let value: Double
    let valueWidth: CGFloat
    /// 설정의 코어 애니메이션
    let animated: Bool

    var body: some View {
        let level = SystemHealth.level(value, .cpu)
        HStack(spacing: 8) {
            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
            // 갱신 간격(기본 3초)마다 오는 값으로 짧게(0.4초) 이어 움직인다 — 한 번에 뛰면 딱딱해 보였고, 길게 하면 그리는 부담이 컸다
            MeterBar(level: value / 100, tone: level.tone,
                     animation: animated ? .easeInOut(duration: 0.4) : nil)
            // 숫자는 바로 바꾼다 — 굴러가는 효과(numericText)는 프레임마다 글자를 CPU 로 다시 그려 화면 하나에 코어 10% 넘게 썼다
            Text("\(Int(value.rounded()))%").font(.caption).monospacedDigit().frame(width: valueWidth, alignment: .trailing)
        }
    }
}
