// 서버 추가·편집 창의 [Ping]·포트 [확인] 옆 연결 그림.

import SwiftUI

/// 포트 [확인] 옆 연결 그림: 이 Mac ● ─ ○ 서버. 확인 중엔 점이 서버 쪽으로 흘러가고,
/// 응답 있으면 선이 끝까지 이어지며 초록(서버 점 톡), 없으면 중간에서 끊기고 전부 빨강 — ✕ 가 짧게 흔들린다.
struct PortProbeLine: View {
    enum Phase: Equatable { case checking, open, closed }
    let phase: Phase
    var width: CGFloat = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 12, dot: CGFloat = 8
    private var start: CGFloat { dot + 2 }
    private var end: CGFloat { width - dot - 2 }
    private var mid: CGFloat { (start + end) / 2 }
    /// ✕ 양옆 틈 (✕ 반폭 5 + 틈 3) — 선이 ✕ 에 붙으면 끊긴 게 안 보였다
    private let gap: CGFloat = 8
    /// 실선이 간 끝 · 점선이 시작하는 곳 (선 길이 비율). 겹치면 반투명 실선 사이로 점선이 비쳐 줄무늬가 됐다
    private var solidTo: CGFloat {
        switch phase {
        case .checking: return 0
        case .open: return 1
        case .closed: return (mid - gap - start) / (end - start)
        }
    }
    private var dashedFrom: CGFloat {
        switch phase {
        case .checking: return 0
        case .open: return 1
        case .closed: return (mid + gap - start) / (end - start)
        }
    }
    private var tint: Color {
        switch phase {
        case .checking: return .secondary
        case .open: return StatusTone.good.color
        case .closed: return StatusTone.bad.color
        }
    }

    var body: some View {
        ZStack {
            // 아직 안 간 구간
            segment.trim(from: dashedFrom, to: 1)
                .stroke(phase == .closed ? AnyShapeStyle(tint.opacity(0.4)) : AnyShapeStyle(.secondary.opacity(0.4)),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            // 간 구간
            segment.trim(from: 0, to: solidTo).stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            if phase == .checking, !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                        .position(x: start + (end - start) * t, y: height / 2)
                        .opacity(sin(t * .pi))
                }
            }
            Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(StatusTone.bad.color)
                .position(x: mid, y: height / 2)
                .opacity(phase == .closed ? 1 : 0)
                .keyframeAnimator(initialValue: CGFloat(0), trigger: phase) { view, x in view.offset(x: x) } keyframes: { _ in
                    KeyframeTrack {
                        for x: CGFloat in phase == .closed ? [-2, 2, -1, 0] : [0] { CubicKeyframe(x, duration: 0.06) }
                    }
                }
            // 이 Mac
            Circle().fill(tint).frame(width: dot, height: dot).position(x: dot / 2, y: height / 2)
            // 서버
            Circle().strokeBorder(tint, lineWidth: phase == .open ? 0 : 1.5)
                .background(Circle().fill(phase == .open ? tint : .clear))
                .frame(width: dot, height: dot)
                .keyframeAnimator(initialValue: CGFloat(1), trigger: phase) { view, s in view.scaleEffect(s) } keyframes: { _ in
                    KeyframeTrack {
                        for s: CGFloat in phase == .open ? [1.7, 1] : [1] { SpringKeyframe(s, duration: 0.2) }
                    }
                }
                .position(x: width - dot / 2, y: height / 2)
        }
        .frame(width: width, height: height)
        .animation(.easeOut(duration: 0.3), value: phase)
        .accessibilityHidden(true)
    }

    private var segment: Path {
        Path { $0.move(to: CGPoint(x: start, y: height / 2)); $0.addLine(to: CGPoint(x: end, y: height / 2)) }
    }
}
