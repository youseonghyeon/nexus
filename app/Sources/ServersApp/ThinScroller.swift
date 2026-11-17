// 앱 전체 스크롤바 모양: 얇고 옅은 손잡이만, 홈(배경)은 그리지 않는다.
// NSScrollView 가 배치(tile)할 때 스크롤바를 ThinScroller 로 바꿔 끼워 SwiftUI ScrollView·NSScrollView 모두에 걸린다.
// (NSScroller 자체의 그리기를 바꿔치기하면 시스템이 레이어로 그려 무시된다 — 서브클래스여야 직접 그린다.)

import AppKit
import ObjectiveC

final class ThinScroller: NSScroller {
    /// 손잡이 두께 — 1x 화면에서도 끝이 둥글게 보이게 6
    static let knobThickness: CGFloat = 6
    /// 손잡이 양 끝을 칸 끝에서 띄우는 거리 (창 모서리·가장자리에 깎이지 않게)
    static let knobEndInset: CGFloat = 3

    /// 앱 시작 때 한 번 (AppDelegate.applicationWillFinishLaunching)
    @MainActor static func install() {
        guard let a = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
              let b = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.thin_tile)) else { return }
        method_exchangeImplementations(a, b)
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// 홈(배경) — 그리지 않는다
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    /// 손잡이 — 칸 가운데 얇은 둥근 막대
    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let t = Self.knobThickness, e = Self.knobEndInset
        let vertical = bounds.height >= bounds.width
        // 손잡이 영역 가운데, 픽셀 격자에 맞춰 1x 화면에서도 끝이 둥글게.
        // (칸 폭은 줄이지 않는다 — 시스템이 손잡이 영역을 기본 폭 기준으로 잡고 그 밖은 잘라내, 줄이면 막대가 깎였다)
        let bar = backingAlignedRect(vertical
            ? NSRect(x: knob.midX - t / 2, y: knob.minY + e, width: t, height: max(knob.height - 2 * e, t))
            : NSRect(x: knob.minX + e, y: knob.midY - t / 2, width: max(knob.width - 2 * e, t), height: t),
            options: .alignAllEdgesNearest)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: t / 2, yRadius: t / 2).fill()
    }
}

extension NSScrollView {
    /// 교환 뒤라 thin_tile 호출이 원래 tile. 기본 스크롤바면 ThinScroller 로 바꾼 뒤 배치한다.
    @objc fileprivate func thin_tile() {
        if hasVerticalScroller, let old = verticalScroller, !(old is ThinScroller) {
            verticalScroller = ThinScroller.replacing(old)
        }
        if hasHorizontalScroller, let old = horizontalScroller, !(old is ThinScroller) {
            horizontalScroller = ThinScroller.replacing(old)
        }
        thin_tile()
    }
}

private extension ThinScroller {
    static func replacing(_ old: NSScroller) -> ThinScroller {
        let s = ThinScroller(frame: old.frame)
        s.controlSize = old.controlSize
        s.scrollerStyle = old.scrollerStyle
        s.knobStyle = old.knobStyle
        return s
    }
}
