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
}
