// 브라우저 탭의 웹 화면 위에 앱이 덧그리는 것 (2026-11-18 — 주소창 아래 띠는 눈에 안 들어왔다):
//   저장한 로그인 목록: 로그인 칸에 포커스가 있을 때 그 칸 바로 아래. 누르면 채운다. 자리는 ServersCore LoginForms.dropdownFrame.
//   비밀번호 저장 카드: 로그인한 뒤 웹 화면 오른쪽 위. [저장]/[바꾸기] · [나중에].
// 페이지 안(HTML)에 넣지 않는다 — 페이지의 스크립트가 저장한 계정 이름을 읽을 수 있고 사이트 CSS 에 모양이 깨진다.

import ServersCore
import SwiftUI

/// 웹 화면 위에 뜨는 면: 카드 면 + 가는 선 + 그림자 (다크에서도 — 페이지 위에 떠 보여야 한다)
private struct FloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).fill(Palette.card)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            }
            .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).strokeBorder(Palette.hairline))
    }
}

struct LoginFillList: View {
    let logins: [SecretNote]
    let fill: (SecretNote) -> Void
    /// 마우스가 목록 위에 있다·떠났다 (그동안 칸이 포커스를 잃어도 목록을 남긴다)
    let hover: (Bool) -> Void

    private static let rowHeight: CGFloat = 40
    private static let padding: CGFloat = 4
    /// 한 번에 보이는 줄 수 (넘으면 목록 안에서 민다)
    private static let maxRows = 5

    /// 목록의 높이 — 자리 계산(칸 위·아래)에 쓴다
    static func height(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), maxRows)) * rowHeight + padding * 2
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(logins) { note in
                    LoginFillRow(note: note) { fill(note) }.frame(height: Self.rowHeight)
                }
            }
        }
        .scrollIndicators(logins.count > Self.maxRows ? .automatic : .hidden)
        .padding(Self.padding)
        .frame(height: Self.height(rows: logins.count))
        .modifier(FloatingSurface())
        .onHover(perform: hover)
        .onDisappear { hover(false) }
    }
}

private struct LoginFillRow: View {
    let note: SecretNote
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "key").font(.callout).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.displayTitle).font(.callout).lineLimit(1)
                    // 이름을 붙였으면 ID 를 아랫줄에, 아니면 주소
                    Text(note.title.isEmpty || note.username.isEmpty ? note.siteSummary : note.username)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(hovering ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.smallRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(note.displayTitle) 채우기")
    }
}

struct LoginSaveCard: View {
    let offer: BrowserSession.LoginOffer
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "key").foregroundStyle(.secondary).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.isUpdate ? "저장한 비밀번호를 바꿀까요?" : "비밀번호를 저장할까요?").font(.callout).fontWeight(.medium)
                    Text([offer.note.username, BookmarkStore.shortAddress(offer.site)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            // 하는 쪽이 먼저 (2026-11-18 사용자 지정)
            HStack(spacing: 6) {
                Spacer()
                Button(offer.isUpdate ? "바꾸기" : "저장", action: accept).buttonStyle(CompactButtonStyle())
                Button("나중에", action: decline).buttonStyle(CompactButtonStyle())
            }
        }
        .padding(12)
        .frame(width: 280)
        .modifier(FloatingSurface())
    }
}
