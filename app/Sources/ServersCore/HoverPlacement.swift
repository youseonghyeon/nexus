// 마우스를 올리면 바로 뜨는 설명 팝업(앱 쪽 HoverNote)이 놓일 자리. 화면 좌표(y 는 위로 커진다)로 받아 화면 좌표로 돌려준다.
// 기본은 기준(ⓘ 기호) 바로 아래 · 왼쪽 맞춤. 아래가 모자라면 위로 뒤집고, 좌우는 화면 안으로 민다.

import Foundation

public enum HoverPlacement {
    /// 팝업의 왼쪽 아래 모서리. gap 은 기준과의 틈, inset 은 화면 가장자리와의 틈.
    public static func origin(anchor: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 6, inset: CGFloat = 8) -> CGPoint {
        let left = screen.minX + inset
        let x = max(left, min(anchor.minX, screen.maxX - inset - size.width))   // 화면보다 넓으면 왼쪽 끝에
        let bottom = screen.minY + inset
        var y = anchor.minY - gap - size.height
        if y < bottom {
            // 아래가 모자라면 위로 — 위도 모자라면(화면보다 높음) 아래 끝에 붙인다
            let above = anchor.maxY + gap
            y = above + size.height <= screen.maxY - inset ? above : bottom
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}
