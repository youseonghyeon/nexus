// 브라우저 탭 화면: 주소창(◀ ▶ ↻ ⌂ · URL · ☆ 즐겨찾기, 아래에 진행 줄) + 로그인 저장 띠(물을 때만) + WKWebView. 통신은 BrowserSession/BrowserPolicy — 그 서버에서 켠 브라우저처럼.

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
                Button { browser.showStart() } label: { Image(systemName: "house") }.accessibilityLabel("시작 페이지").help("시작 페이지 — 이 서버의 열린 포트")
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
                // 즐겨찾기 별: 이 서버의 즐겨찾기에 넣고 뺀다 (시작 페이지 맨 위에 보인다)
                Button { browser.toggleBookmark() } label: { Image(systemName: browser.bookmarked ? "star.fill" : "star") }
                    .accessibilityLabel(browser.bookmarked ? "즐겨찾기에서 빼기" : "즐겨찾기에 넣기")
                    .help(browser.bookmarked ? "즐겨찾기에서 빼기" : "즐겨찾기에 넣기 — \(browser.server.key) 의 시작 페이지에 보입니다")
                    .disabled(!browser.canBookmark)
                Text("프록시: \(browser.server.key)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("이 탭은 \(browser.server.key) 서버(\(browser.server.ip))에서 브라우저를 켠 것처럼 동작합니다. 127.0.0.1 은 그 서버 자신입니다")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Palette.content)   // 위 탭줄과 한 면으로 이어진다
            // 진행 줄: 페이지를 받는 동안 주소창 아래에 받은 만큼 찬다 (X 버튼만으로는 가는 중인지 알기 어려웠다 — 2026-11-17).
            // 값이 바뀔 때만 움직인다 (계속 도는 스피너는 쓰지 않는다). 주소창 면 안쪽에 그린다 — 아래 WKWebView 위로 넘기면 가려진다.
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Rectangle().fill(Palette.neutralTint)
                        .frame(width: geometry.size.width * browser.progress, height: 2)
                        .animation(.easeOut(duration: 0.2), value: browser.progress)
                }
                .frame(height: 2)
                .opacity(browser.isLoading && browser.notice == nil ? 1 : 0)
                .allowsHitTesting(false)
            }
            // 로그인 저장 띠: 로그인이 된 것 같을 때(비밀번호 칸이 사라짐) 묻는다 — 정할 때까지 남는다
            if let offer = browser.loginOffer {
                HStack(spacing: 8) {
                    Image(systemName: "key").foregroundStyle(.secondary)
                    Text(offer.isUpdate ? "저장한 비밀번호를 바꿀까요?" : "이 로그인을 저장할까요?").font(.callout)
                    Text([offer.note.username, BookmarkStore.shortAddress(offer.note.site)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("안 함") { browser.declineLoginOffer() }.buttonStyle(CompactButtonStyle())
                    Button(offer.isUpdate ? "바꾸기" : "저장") { browser.acceptLoginOffer() }.buttonStyle(CompactButtonStyle())
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.card)
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
