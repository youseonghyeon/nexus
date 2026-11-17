// 시트·팝오버 닫기와 사이드바 선택 — 뷰는 모델 속성에 직접 쓰지 않고 이 메서드를 부른다 (AGENTS.md: 쓰기는 AppModel 메서드로).

import Foundation
import ServersCore

extension AppModel {
    func closeActionsEditor() { actionsEditor = nil }
    func closeTunnelInfo() { tunnelInfo = nil }
    func closeTunnelPrompt() { tunnelPrompt = nil }
    func closeUploadPrompt() { uploadPrompt = nil }
    func closeDownloadPrompt() { downloadPrompt = nil }
    func closeTransferInfo() { transferInfo = nil }
    func closeAddServerPrompt() { addServerPrompt = nil }
    func closeServerEditor() { serverEditor = nil }
    func closeQueryResult() { queryResult = nil }

    /// 사이드바 목록의 선택 (nil = 선택 해제)
    func select(key: String?) { selectedKey = key }

    /// 사이드바 검색 칸의 포커스 여부 (그동안 Enter 는 검색 — AppModel.sidebarSearchFocused)
    func setSidebarSearchFocused(_ focused: Bool) { sidebarSearchFocused = focused }
}
