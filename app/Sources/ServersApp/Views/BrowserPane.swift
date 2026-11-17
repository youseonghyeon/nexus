// 브라우저 탭 화면: 주소창(◀ ▶ ↻ · URL · 차단 안내) + WKWebView. 통신 범위는 BrowserSession/BrowserPolicy 가 정한다.

import ServersCore
import SwiftUI
import WebKit

struct BrowserPane: View {
    @ObservedObject var browser: BrowserSession
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("뒤로").disabled(!browser.canGoBack)
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }.accessibilityLabel("앞으로").disabled(!browser.canGoForward)
                Button { browser.isLoading ? browser.stopLoading() : browser.reload() } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }.accessibilityLabel(browser.isLoading ? "중지" : "새로 고침")
                    .disabled(browser.notice != nil)
                TextField("주소", text: $address)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))   // 테두리 대신 옅은 면 (사이드바 검색칸과 같게)
                    .focused($addressFocused)
                    .onSubmit { browser.load(address); addressFocused = false }
                    .onChange(of: browser.url) { _, url in if !addressFocused { address = url?.absoluteString ?? "" } }
                    .onAppear { address = browser.url?.absoluteString ?? "" }
                Text("프록시: \(browser.server.key)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("이 탭의 통신은 \(browser.server.key) 서버(\(browser.server.ip))로 연 SOCKS 프록시만 지납니다. 갈 수 있는 곳은 그 서버 IP 와 루프백(터널)뿐입니다")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Palette.content)   // 위 탭줄과 한 면으로 이어진다
            if let blocked = browser.blocked {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(StatusTone.warn.color)
                    Text("차단: \(blocked)").lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                .background(StatusTone.warn.color.opacity(0.12))
            }
            Divider()
            ZStack {
                WebViewRepresentable(webView: browser.webView)
                if let notice = browser.notice {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small).opacity(notice.hasSuffix("…") ? 1 : 0)
                        Text(notice).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }
}

/// 세션이 들고 있는 WKWebView 를 그대로 붙인다 (뷰를 다시 만들어도 같은 인스턴스라 상태가 유지된다)
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
