// 메뉴바 아이콘: 앱 아이콘(`>_` + 오른쪽 위 3노드 연결점)을 18pt 템플릿으로 줄인 것 (2026-10-07 시안 D12).
// 둥근 틀 안에 선으로 그린 `>_`, 틀 오른쪽 위 바깥에 점 셋 — 점 둘레는 지워서 틀과 붙어 보이지 않게.
// 템플릿 이미지라 메뉴바 밝기에 맞춰 검정·흰색이 저절로 바뀐다.

import AppKit

enum MenuBarIcon {
    static let image = make(filled: false)
    /// Intranet 이 켜져 있을 때: 틀을 채우고 `>_` 를 파낸 것 — 메뉴를 열지 않아도 내부망이 열려 있는지 보인다.
    static let intranetOnImage = make(filled: true)

    private static func make(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(filled: filled)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = filled ? "Nexus — Intranet 켜짐" : "Nexus"
        return image
    }

    // 좌표는 pt, 원점 왼쪽 아래. 획은 옆 시스템 아이콘(Wi-Fi·배터리)과 맞춘 1.5.
    private static let box = NSRect(x: 1.0, y: 2.5, width: 13.0, height: 11.0)
    private static let stroke: CGFloat = 1.5
    private static let hub = CGPoint(x: 14.5, y: 16.25)   // 점 묶음이 캔버스 오른쪽 위(여백 0.4)에 붙는 자리
    private static let leafLength: CGFloat = 3.8
    private static let leafAngles: [CGFloat] = [210, 300]  // 앱 아이콘과 같은 각도
    private static let hubRadius: CGFloat = 1.35
    private static let leafRadius: CGFloat = 1.2
    private static let link: CGFloat = 0.7
    private static let gap: CGFloat = 1.0

    private static func draw(filled: Bool) {
        NSColor.black.set()
        let context = NSGraphicsContext.current
        if filled {
            NSBezierPath(roundedRect: box, xRadius: 3.75, yRadius: 3.75).fill()
            context?.compositingOperation = .clear   // 채운 틀에서 `>_` 를 파낸다
        } else {
            let frame = NSBezierPath(roundedRect: box.insetBy(dx: stroke / 2, dy: stroke / 2), xRadius: 3, yRadius: 3)
            frame.lineWidth = stroke
            frame.stroke()
        }

        // `>_` — 글꼴 대신 선으로 (18pt 에서 또렷하게)
        let h = box.height * 0.36, w = h * 0.62
        let x = box.minX + box.width * 0.24, y = box.minY + box.height * 0.30
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: x, y: y + h))
        chevron.line(to: CGPoint(x: x + w, y: y + h / 2))
        chevron.line(to: CGPoint(x: x, y: y))
        let underscore = NSBezierPath()
        underscore.move(to: CGPoint(x: x + w + 1.6, y: y))
        underscore.line(to: CGPoint(x: x + w + 1.6 + h * 0.75, y: y))
        for path in [chevron, underscore] {
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        context?.compositingOperation = .sourceOver

        // 3노드 연결점: 먼저 둘레를 gap 만큼 지우고 그린다
        let leaves = leafAngles.map { CGPoint(x: hub.x + leafLength * cos($0 * .pi / 180), y: hub.y + leafLength * sin($0 * .pi / 180)) }
        let nodes = [(hub, hubRadius)] + leaves.map { ($0, leafRadius) }
        for clearing in [true, false] {
            context?.compositingOperation = clearing ? .clear : .sourceOver
            let pad = clearing ? gap : 0
            for leaf in leaves {
                let line = NSBezierPath()
                line.move(to: hub)
                line.line(to: leaf)
                line.lineWidth = link + pad * 2
                line.lineCapStyle = .round
                line.stroke()
            }
            for (center, radius) in nodes {
                let r = radius + pad
                NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
            }
        }
        context?.compositingOperation = .sourceOver
    }
}
