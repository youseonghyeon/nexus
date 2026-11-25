// 브라우저 탭 화면: 주소창(◀ ▶ ↻ ⌂ · URL · ☆ 즐겨찾기, 아래에 진행 줄) + WKWebView (그 위에 비밀번호 저장 카드·저장한 로그인 목록 — BrowserOverlays). 통신은 BrowserSession/BrowserPolicy — 그 서버에서 켠 브라우저처럼.

import ServersCore
import SwiftUI
import WebKit

struct BrowserPane: View {
    @ObservedObject var browser: BrowserSession
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    /// 웹 화면 크기 (칸 아래 목록이 화면 밖으로 나가지 않게 — LoginForms.dropdownFrame)
    @State private var webSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("뒤로").disabled(!browser.canGoBack)
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }.accessibilityLabel("앞으로").disabled(!browser.canGoForward)
                Button { browser.isLoading ? browser.stopLoading() : browser.reload() } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }.accessibilityLabel(browser.isLoading ? "중지" : "새로 고침")
                    .disabled(browser.notice != nil)
                Button { browser.openStart() } label: { Image(systemName: "house") }.accessibilityLabel("시작 페이지").help("시작 페이지 — 이 서버의 열린 포트")
                    .disabled(browser.notice != nil)
                TextField("검색어 또는 주소", text: $address)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))   // 테두리 대신 옅은 면 (사이드바 검색칸과 같게)
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
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { webSize = $0 }
            // 웹 화면 위에 덧그리는 것 (BrowserOverlays) — 있을 때만 얹는다 (없을 때는 웹 화면 위에 아무 뷰도 없다)
            // 비밀번호 저장 카드: 로그인이 된 것 같을 때(비밀번호 칸이 사라짐) 오른쪽 위에. 정할 때까지 남는다
            .overlay(alignment: .topTrailing) {
                if let offer = browser.loginOffer {
                    LoginSaveCard(offer: offer, accept: { browser.acceptLoginOffer() }, decline: { browser.declineLoginOffer() })
                        .padding(12)
                }
            }
            // 저장한 로그인 목록: 로그인 칸에 포커스가 있을 때 그 칸 바로 아래에
            .overlay(alignment: .topLeading) {
                if let prompt = browser.fillPrompt {
                    let frame = LoginForms.dropdownFrame(field: prompt.field, container: (Double(webSize.width), Double(webSize.height)),
                                                         contentHeight: Double(LoginFillList.height(rows: prompt.logins.count)))
                    LoginFillList(logins: prompt.logins, fill: { browser.fill($0) }, hover: { browser.setFillPromptHovered($0) })
                        .frame(width: frame.width)
                        .offset(x: frame.x, y: frame.y)
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
