// 메뉴바 패널이 뜰 자리 — 아이콘 바로 아래, 왼쪽 끝을 아이콘에 맞추고 화면 밖으로 나가지 않게.
// 내용이 화면보다 길면 높이를 줄인다 (패널 안에서 스크롤). 화면(MenuBarController)은 이 값을 그대로 쓴다.

import Foundation

public enum MenuBarPanelPlacement {
    /// 아이콘과 패널 사이
    public static let gap: CGFloat = 6
    /// 화면 가장자리와 패널 사이
    public static let margin: CGFloat = 8

    /// - anchor: 메뉴바 아이콘(화면 좌표, 원점 왼쪽 아래)
    /// - content: 패널 내용이 원하는 크기
    /// - visible: 아이콘이 있는 화면의 쓸 수 있는 영역 (메뉴바·Dock 제외)
    public static func frame(anchor: CGRect, content: CGSize, visible: CGRect) -> CGRect {
        // 위는 아이콘 아래 — 전체 화면에서 내려온 메뉴바처럼 아이콘이 쓸 수 있는 영역 안에 있어도, 밖(위)에 있어도 그 아래
        let top = min(anchor.minY, visible.maxY) - gap
        let room = max(0, top - (visible.minY + margin))
        let height = min(content.height, room)
        let width = min(content.width, max(0, visible.width - margin * 2))
        let x = max(visible.minX + margin, min(anchor.minX, visible.maxX - margin - width))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// 누른 자리가 아이콘 위인가 — 아이콘을 다시 누른 것은 "밖을 눌러 닫기"가 아니라 여닫기(togglePanel)가 맡는다.
    /// 둘 다 닫으려 들면 닫힌 직후 다시 열려, 아이콘으로는 패널이 닫히지 않는다.
    public static func isOnIcon(_ point: CGPoint, anchor: CGRect) -> Bool {
        anchor.contains(point)
    }
}
