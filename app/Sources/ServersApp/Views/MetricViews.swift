// 수치 표시용 작은 부품들: 큰 숫자 타일 · 신호 막대 · 스파크라인 · 상태 칩.
// 망 Dashboard 가 숫자만 늘어놓지 않게 한다.

import ServersCore
import SwiftUI

/// 큰 숫자 하나 + 단위 + 아래 설명. 오른쪽에 막대·그래프 같은 장식을 넣을 수 있다.
struct MetricTile<Accessory: View>: View {
    let title: String
    let value: String
    var unit: String?
    var caption: String?
    var tone: StatusTone = .muted
    var systemImage: String?
    @ViewBuilder var accessory: Accessory
    @Environment(\.inHeroStrip) private var inHeroStrip

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium)) }
                Text(title).font(.cardTitle)
            }
            .foregroundStyle(.secondary)
            .frame(height: 14)   // 아이콘 모양에 따라 줄 높이가 달라지면 그 타일만 제목·숫자가 1pt 내려앉는다 — 높이를 고정
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                // 숫자는 바로 바꾼다 — 넘김 효과(numericText)는 움직이는 0.25초 동안 창 전체를 프레임마다 다시 배치해, 2~3초마다 갱신되는 화면에서 CPU 15%p 를 썼다
                Text(value).font(.metricValue(value)).tracking(-0.4).monospacedDigit().foregroundStyle(tone == .muted ? .primary : tone.color)
                if let unit { Text(unit).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary) }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(height: 28, alignment: .bottomLeading)   // 값 글자 크기가 달라도(긴 글은 작게) 한 줄의 타일끼리 밑줄이 맞게
            // 장식(막대·게이지·그래프·칩)은 종류마다 높이가 달라 자리를 같은 높이로 고정한다 → 한 줄의 타일 높이가 같아진다
            accessory.frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(TileSurface(cell: inHeroStrip))
    }
}

/// 타일의 면: 따로 놓이면 카드, 대표 카드 띠 안이면 면 없이 오른쪽·아래 선으로만 가른 칸 (맨 끝 선은 카드 테두리와 겹친다)
private struct TileSurface: ViewModifier {
    let cell: Bool

    func body(content: Content) -> some View {
        if cell {
            content
                .padding(.horizontal, 18).padding(.vertical, 10)
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        } else {
            content.padding(14).cardSurface()
        }
    }
}

extension MetricTile where Accessory == EmptyView {
    init(title: String, value: String, unit: String? = nil, caption: String? = nil,
         tone: StatusTone = .muted, systemImage: String? = nil) {
        self.init(title: title, value: value, unit: unit, caption: caption, tone: tone,
                  systemImage: systemImage) { EmptyView() }
    }
}

/// Wi-Fi 신호 막대 4칸 (0...1)
struct SignalBars: View {
    let level: Double
    var tone: StatusTone = .good

    var body: some View {
        let filledCount = SignalMeter.filledBars(level: level, bars: 4)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                let filled = index < filledCount
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(filled ? tone.color : Palette.track)
                    .frame(width: 5, height: 6 + CGFloat(index) * 4)
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}

/// 가로 게이지 (0...1)
struct MeterBar: View {
    let level: Double
    var tone: StatusTone = .good
    /// tone 대신 직접 칠할 색 (Spec 게이지의 무채색)
    var fill: Color?
    /// 값이 바뀔 때 길이를 이어서 움직인다 (자주 갱신되는 막대 — 시스템 화면의 코어). nil 이면 바로 바뀐다.
    var animation: Animation?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(fill ?? tone.color).frame(width: max(2, geo.size.width * min(1, max(0, level))))
                    .animation(animation, value: level)
            }
        }
        .frame(height: 4)
    }
}

/// 최근 값 흐름. 값이 2개 미만이면 빈 자리만 차지한다.
struct Sparkline: View {
    let values: [Double]
    var tone: StatusTone = .good
    /// 축 위 끝을 고정한다 (CPU·GPU % 는 100). nil 이면 값의 최대에 맞춘다.
    var ceiling: Double?

    var body: some View {
        GeometryReader { geo in
            let maximum = ceiling ?? max(values.max() ?? 0, 1)
            Path { path in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * step
                    let y = geo.size.height * (1 - CGFloat(value / maximum))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(tone.color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: 18)
    }
}

/// 짧은 상태 꼬리표 ("좋음", "손실 20%")
struct StatusChip: View {
    let text: String
    var tone: StatusTone = .good

    var body: some View {
        Text(text)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tone.color.opacity(0.15), in: Capsule())
            .foregroundStyle(tone.color)
            .lineLimit(1).fixedSize()   // 딱지는 줄이지 않는다 — 표(Grid) 칸이 좁게 잡히면 "기본…" 처럼 잘렸다 (2026-11-02)
    }
}

/// 타일을 폭에 맞춰 줄바꿈하는 격자 (TileRowLayout)
struct MetricGrid<Content: View>: View {
    var minimum: CGFloat = 150
    @ViewBuilder var content: Content
    @Environment(\.inHeroStrip) private var inHeroStrip

    var body: some View {
        TileRowLayout(minimum: minimum, spacing: inHeroStrip ? 0 : Metrics.gap) { content }
            // 띠 안에서는 맨 오른쪽 칸의 오른쪽 선·맨 아래 줄의 아래 선이 카드 테두리와 나란히 겹쳐 두 줄로 보인다(라이트에서 또렷) — 1pt 밖으로 밀어 잘라 낸다
            .padding(.trailing, inHeroStrip ? -1 : 0).padding(.bottom, inHeroStrip ? -1 : 0)
    }
}

/// 칸 나누기는 ServersCore TileColumns (최소 4칸, 더 많으면 그 수만큼 나눠 꽉 채움, 좁으면 줄바꿈).
/// 적응형 격자(최소 폭)는 넓은 창에서 칸이 7개쯤 생겨 타일 4개짜리 화면의 오른쪽이 비었다 (2026-10-19).
/// 한 줄의 타일은 가장 높은 타일에 높이를 맞춘다.
struct TileRowLayout: Layout {
    var minimum: CGFloat
    var spacing: CGFloat
    var minimumSlots = 4

    private func columns(_ width: CGFloat, count: Int) -> (slots: Int, tile: CGFloat) {
        TileColumns.layout(width: width, count: count, minimum: minimum, spacing: spacing, minimumSlots: minimumSlots)
    }

    private func rowHeights(_ subviews: Subviews, slots: Int, tile: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: slots).map { start in
            subviews[start..<min(start + slots, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minimum * CGFloat(minimumSlots) + spacing * CGFloat(minimumSlots - 1)
        let (slots, tile) = columns(width, count: subviews.count)
        let heights = rowHeights(subviews, slots: slots, tile: tile)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(heights.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let (slots, tile) = columns(bounds.width, count: subviews.count)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, slots: slots, tile: tile).enumerated() {
            for column in 0..<slots {
                let index = row * slots + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (tile + spacing), y: y),
                                      proposal: ProposedViewSize(width: tile, height: height))
            }
            y += height + spacing
        }
    }
}

// MARK: 값 → 표시 도우미

/// 문턱은 ServersCore SignalGrade · LatencyGrade · SignalMeter. 여기는 단계 → 글자·색만
enum SignalScale {
    /// RSSI(dBm) → 0...1
    static func level(rssi: Int) -> Double {
        SignalMeter.level(rssi: rssi)
    }

    static func label(rssi: Int) -> String {
        switch SignalGrade(rssi: rssi) {
        case .excellent: return "매우 좋음"
        case .good: return "좋음"
        case .fair: return "보통"
        case .weak: return "약함"
        }
    }

    static func tone(rssi: Int) -> StatusTone {
        switch SignalGrade(rssi: rssi) {
        case .excellent, .good: return .good
        case .fair: return .warn
        case .weak: return .bad
        }
    }

    /// 응답 시간(ms) → 색
    static func latencyTone(_ ms: Double) -> StatusTone {
        switch LatencyGrade(ms: ms) {
        case .fast: return .good
        case .slow: return .warn
        case .poor: return .bad
        }
    }
}
