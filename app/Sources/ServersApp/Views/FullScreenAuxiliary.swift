// 보조 창(설정·패킷 캡처)을 전체 화면 위에 띄우는 부품.

import AppKit
import SwiftUI

/// 설정 창을 전체 화면 위에 바로 띄운다 — 보통 창은 전체 화면에서 열면 macOS 가 옆 데스크톱으로 넘어가 거기 띄웠다 (2026-10-15).
/// 창에 붙는 순간(보이기 전) fullScreenAuxiliary 를 준다.
struct FullScreenAuxiliary: NSViewRepresentable {   // 패킷 캡처 창도 쓴다
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}
