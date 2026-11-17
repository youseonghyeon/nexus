// ⌘ 번호 (ServersCore QuickSelect): 번호를 보일지와 지금 번호가 붙은 서버. 키는 TerminalShortcuts 가 받아 여기로 넘긴다.
// AppModel 밖에 둔다 — ⌘ 를 누를 때마다 AppModel 을 바꾸면 그것을 보는 화면 전체가 다시 그려진다. 번호 배지(ServerRow)만 이것을 본다.

import ServersCore
import SwiftUI

@MainActor
final class QuickSelectState: ObservableObject {
    static let shared = QuickSelectState()

    @Published private(set) var visible = false
    /// 번호가 붙은 서버 (사이드바가 보이는 순서로 알려 준다 — 1번부터)
    var keys: [String] = []

    private var badges = QuickSelectBadges()
    private var timer: Task<Void, Never>?

    func modifiersChanged(commandOnly: Bool) {
        badges.modifiersChanged(commandOnly: commandOnly, at: Date())
        publish()
        timer?.cancel()
        guard commandOnly, !badges.visible else { return }
        timer = Task {
            do { try await Task.sleep(for: .seconds(QuickSelectBadges.delay)) } catch { return }
            badges.tick(at: Date())
            publish()
        }
    }

    func keyDown(isNumber: Bool) {
        badges.keyDown(isNumber: isNumber)
        publish()
    }

    func reset() {
        timer?.cancel()
        badges.reset()
        publish()
    }

    private func publish() {
        if visible != badges.visible { visible = badges.visible }
    }
}
