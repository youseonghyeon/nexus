// 설명 팝업: ⓘ 기호에 마우스를 올리면 바로 뜨고 벗어나면 사라진다.
// 무엇을 뜻하는지 알려 주는 글은 시스템 도움말(.help)로 넣지 않는다 — 뜨기까지 5초쯤 걸려 없는 것처럼 보였다 (2026-11-24 사용자 지적).
// 본창에 딸린 테두리 없는 패널에 그린다: 카드·스크롤 영역에 잘리지 않고, 아래 줄에 덮이지 않고, 키 입력·마우스를 가져가지 않는다.
// 자리는 ServersCore HoverPlacement (기호 아래 왼쪽 맞춤 · 아래가 모자라면 위 · 화면 안으로).

import AppKit
import ServersCore
import SwiftUI

/// 작은 ⓘ 기호. 올리면 content 가 팝업으로 뜬다. label 은 손쉬운 사용에 읽힐 한 줄.
struct HoverNote<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .padding(3).contentShape(Rectangle()).padding(-3)   // 작은 기호라 닿는 자리를 조금 넓힌다 (배치는 그대로)
            .onHover { hovering = $0 }
            .background(HoverPanelAnchor(shown: hovering) { HoverNoteSurface { content } })
            .accessibilityLabel(label)
    }
}

/// 팝업의 면: 웹 화면 위 목록·탭 막대 패널과 같은 떠 있는 면 (FloatingSurface)
private struct HoverNoteSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .modifier(FloatingSurface())
            .padding(HoverPanelAnchor<EmptyView>.margin)   // 그림자가 패널 가장자리에 잘리지 않게
            .tint(Palette.neutralTint)
    }
}

/// 기호 자리를 재서 패널을 띄우고 치운다
private struct HoverPanelAnchor<Content: View>: NSViewRepresentable {
    /// 내용 둘레에 두는 그림자 자리
    static var margin: CGFloat { 16 }

    let shown: Bool
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        if shown { context.coordinator.show(from: view, content: AnyView(content)) } else { context.coordinator.hide() }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.hide() }

    @MainActor final class Coordinator {
        private var panel: NSPanel?

        func show(from anchor: NSView, content: AnyView) {
            guard let window = anchor.window, let screen = window.screen ?? NSScreen.main else { return }
            let panel = self.panel ?? Self.makePanel()
            let host = NSHostingView(rootView: content)
            panel.appearance = window.effectiveAppearance   // 앱의 라이트·다크를 따른다
            panel.contentView = host
            let size = host.fittingSize
            let margin = HoverPanelAnchor.margin
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            // 자리는 그림자 자리를 뺀 내용 기준으로 잡고, 패널은 그만큼 바깥으로
            let inner = CGSize(width: size.width - margin * 2, height: size.height - margin * 2)
            let origin = HoverPlacement.origin(anchor: rect, size: inner, screen: screen.visibleFrame)
            panel.setFrame(NSRect(x: origin.x - margin, y: origin.y - margin, width: size.width, height: size.height), display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)   // 본창과 함께 움직이고 본창 위에
            }
            panel.orderFront(nil)
            self.panel = panel
        }

        func hide() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }

        private static func makePanel() -> NSPanel {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false            // 그림자는 면(FloatingSurface)이 그린다
            panel.ignoresMouseEvents = true    // 팝업이 마우스를 받으면 기호에서 벗어난 것으로 쳐 깜박인다
            panel.hidesOnDeactivate = true
            panel.animationBehavior = .none    // 바로 뜨고 바로 사라진다
            panel.isReleasedWhenClosed = false
            return panel
        }
    }
}
