// 브라우저 탭의 뒤로 버튼(‹ · 마우스 옆 버튼)을 누를 수 있는가.
// 시작 페이지도 기록의 한 항목이다(빈 문서로 이동해 만든다 — BrowserSession.openStart). 그래서 기록에 앞 항목이 있으면 어디서든 갈 수 있고,
// 앞 항목이 없어도 시작 페이지가 아니면 시작 페이지로 간다(오류 페이지처럼 기록 없이 뜬 화면). 시작 페이지를 한 번도 못 띄웠으면(연결 중) 갈 곳이 없다.

public enum BrowserHistory {
    public static func canGoBack(started: Bool, showingStart: Bool, historyHasBack: Bool) -> Bool {
        started && (historyHasBack || !showingStart)
    }
}
