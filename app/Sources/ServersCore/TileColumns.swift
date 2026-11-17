// 숫자 타일 줄의 칸 나누기 (앱의 TileRowLayout 이 쓴다).
// 한 줄을 최소 minimumSlots 칸으로 나눠 왼쪽부터 채우고, 타일이 더 많으면 그 수만큼 나눠 줄을 꽉 채운다.
// 좁아서 한 줄에 다 안 들어가면 줄을 바꾸되, 줄마다 타일 수가 비슷하게 나눈다 (4개가 3+1 이 아니라 2+2 — 한 칸만 떨어져 나오지 않게).

import CoreGraphics

public enum TileColumns {
    /// 칸 수와 타일 폭
    public static func layout(width: CGFloat, count: Int, minimum: CGFloat, spacing: CGFloat,
                              minimumSlots: Int = 4) -> (slots: Int, tile: CGFloat) {
        // 폭을 모르는 제안(무한대)·깨진 값: Int(무한대) 는 크래시한다 — 최소 칸·최소 폭으로
        guard width.isFinite else { return (max(1, minimumSlots), minimum) }
        let fit = max(1, Int((width + spacing) / (minimum + spacing)))
        let slots: Int
        if count > fit {
            // 줄 수는 들어가는 칸 수로 정하고, 그 줄 수에 고르게 나눈다
            let rows = (count + fit - 1) / fit
            slots = (count + rows - 1) / rows
        } else {
            slots = min(fit, max(count, minimumSlots))
        }
        return (slots, max(0, (width - spacing * CGFloat(slots - 1)) / CGFloat(slots)))
    }
}
