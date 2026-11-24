// 메모·로그인 (탭 막대 오른쪽, 명령 모음 옆의 열쇠 버튼). 앱이 그리는 패널에 들어간다 (TabBarPanels).
// 선택한 서버의 것만 보인다 — 암호화해 notes.bin 에 둔다 (ServersCore NoteVault).
// 로그인: 누르면 보고 있는 브라우저 탭에 채운다(주소가 달라도 — 그 페이지의 로그인은 맨 위에 "채우기" 표시). 보는 웹 페이지가 없으면 비밀번호 복사. 줄 끝에서 ID·PW 복사(글자 붙은 버튼)·편집.
// 메모: 누르면 펼쳐 본문을 보인다(가린 메모는 펼쳐야 보인다). 줄 끝에서 복사·편집. 추가·편집·삭제도 이 안에서.
// 키보드: 글자로 거르기 → ↑↓ 로 고르기 → Return.

import ServersCore
import SwiftUI

struct NotesButton: View {
    @Environment(AppModel.self) private var model
    let serverKey: String

    var body: some View {
        Button { model.toggleNotes() } label: { Image(systemName: "key.horizontal") }.accessibilityLabel("메모 · 로그인")
            .buttonStyle(TabBarIconButtonStyle(active: model.notesShown))
            .padding(.leading, 6)
            .help("메모 · 로그인 — \(serverKey)")
            .onDisappear { model.closeNotes() }   // 마지막 탭을 닫거나 서버를 바꿔 버튼이 사라지면, 다음에 탭을 열 때 저절로 뜨지 않게
    }
}

struct NotesPopover: View {
    @Environment(AppModel.self) private var model
    let serverKey: String
    /// 편집 중인 항목 (nil 이면 목록). 새것은 아직 목록에 없는 id.
    @Binding var editing: SecretNote?
    let close: () -> Void
    @State private var query = ""
    /// ↑↓ 로 고른 줄 (거른 목록 안의 위치)
    @State private var selected = 0
    /// 펼친 메모
    @State private var expanded: UUID?
    @FocusState private var searchFocused: Bool

    /// 보고 있는 브라우저 탭의 주소 (없으면 nil — 채우기 대신 복사)
    private var site: String? { model.visibleBrowser?.site }
    private var stored: [SecretNote] { NoteVault.notes(for: serverKey, in: model.notes) }
    private var all: [SecretNote] { NoteVault.ordered(stored, site: site) }
    private var shown: [SecretNote] { all.filter { NoteVault.matches($0, query) } }

    var body: some View {
        Group {
            if let draft = editing {
                NoteEditor(draft: Binding(get: { editing ?? draft }, set: { editing = $0 }), serverKey: serverKey,
                           isNew: !stored.contains { $0.id == draft.id }) { editing = nil }
                    .id(draft.id)
            } else {
                list
            }
        }
        .padding(12)
        .frame(width: 400)
    }

    /// 줄을 눌렀다 · Return
    private func activate(_ note: SecretNote) {
        switch note.kind {
        case .memo:
            expanded = expanded == note.id ? nil : note.id
        case .login:
            if NoteVault.canFill(note, site: site) { model.fillLogin(note) } else { model.copySecret(note.password, label: "비밀번호") }
            close()
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(serverKey) 메모 · 로그인")
                    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                // 브라우저 탭에서 열었으면 그 페이지의 로그인부터
                Button { editing = SecretNote(kind: site == nil ? .memo : .login, sites: site.map { [$0] } ?? []) } label: { Image(systemName: "plus") }.accessibilityLabel("추가")
                    .buttonStyle(.borderless)
                    .disabled(model.notesError != nil)
                    .help("추가")
            }
            if let error = model.notesError {
                Text(error.description).font(.caption).foregroundStyle(StatusTone.warn.color).textSelection(.enabled)
            } else if all.isEmpty {
                Text("저장한 것이 없습니다. + 로 추가하세요.").font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                TextField("검색 · ↑↓ 고르기 · Return", text: $query)
                    .panelField()
                    .focused($searchFocused)
                    .onSubmit { if shown.indices.contains(selected) { activate(shown[selected]) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: query) { _, _ in selected = 0 }
                    .onChange(of: shown.count) { _, count in selected = min(selected, max(count - 1, 0)) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, note in
                                NoteRow(note: note, fits: NoteVault.fits(note, site: site), isSelected: index == selected, isExpanded: expanded == note.id,
                                        activate: { activate(note) },
                                        copy: { text, label in model.copySecret(text, label: label); close() },
                                        edit: { editing = note })
                                    .id(note.id)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selected) { _, index in
                        if shown.indices.contains(index) { proxy.scrollTo(shown[index].id) }
                    }
                }
                if shown.isEmpty {
                    Text("맞는 것이 없습니다").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }   // 패널이 붙은 다음 차례에
    }

    private func move(_ step: Int) {
        guard !shown.isEmpty else { return }
        selected = min(max(selected + step, 0), shown.count - 1)
    }
}

/// 한 줄. 로그인: 이름(또는 ID) + 짧은 주소, 이 페이지의 것이면 "채우기" 표시. 메모: 제목 + 본문 미리보기(가린 메모는 점), 펼치면 본문 전체.
/// 마우스를 올리면 줄 끝에 복사·편집 아이콘. ↑↓ 로 고른 줄은 마우스를 올린 것과 같은 면.
private struct NoteRow: View {
    let note: SecretNote
    let fits: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let activate: () -> Void
    /// (값, 토스트에 적을 이름)
    let copy: (String, String) -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note.kind == .login ? "person.crop.circle" : "note.text")
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(note.displayTitle).font(.callout).lineLimit(1)
                    if fits {
                        Text("채우기").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: Metrics.chipRadius))
                            .help("누르면 이 페이지의 로그인 칸에 넣습니다")
                    }
                }
                detail
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                switch note.kind {
                case .login:
                    // 그림만으로는 어느 쪽인지 알 수 없었다 (사람·열쇠 — 2026-11-18 사용자 지적): 복사 그림 + 글자
                    RowCopyButton(title: "ID", help: "ID 복사", visible: hovering) { copy(note.username, "ID") }
                        .disabled(note.username.isEmpty)
                    RowCopyButton(title: "PW", help: "비밀번호 복사", visible: hovering) { copy(note.password, "비밀번호") }
                case .memo:
                    RowIconButton(systemName: "doc.on.doc", help: "복사", visible: hovering) { copy(note.body, "메모") }
                }
                RowIconButton(systemName: "pencil", help: "편집", visible: hovering, action: edit)
            }
        }
        .panelRowSurface(highlighted: hovering || isSelected)
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
    }

    @ViewBuilder
    private var detail: some View {
        switch note.kind {
        case .login:
            // 이름을 붙였으면 ID 도 아랫줄에
            Text([note.title.isEmpty ? "" : note.username, note.siteSummary].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        case .memo:
            if isExpanded {
                Text(note.body.isEmpty ? "(본문 없음)" : note.body)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if note.concealed {
                Text("••••••  누르면 보기").font(.caption).foregroundStyle(.secondary)
            } else if !note.title.isEmpty, !note.body.isEmpty {
                Text(note.body).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// 줄 끝의 글자 붙은 복사 버튼 ("⧉ ID" · "⧉ PW"). 누름 영역·올린 면은 RowIconButton 과 같게 (높이 24, 감춰져 있어도 누름 영역은 남는다).
private struct RowCopyButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let help: String
    let visible: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(hovering && isEnabled ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.smallRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering && isEnabled ? Color.primary : Color.secondary)
        .opacity(!(visible || hovering) ? 0 : (isEnabled ? 1 : 0.4))
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 추가·편집. 새것은 종류(로그인·메모)를 고른다. 저장은 ⌘Return (Return 은 메모 칸의 줄바꿈). 삭제는 편집에서만.
/// 로그인은 칸마다 왼쪽에 이름표 — 이름 · ID · PW · URL 순서. URL 은 여러 줄(같은 계정으로 들어가는 주소들): ⊕ 로 아래에 줄을 보태고 ⊖ 로 뺀다(한 줄은 남는다).
private struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: SecretNote
    let serverKey: String
    let isNew: Bool
    let done: () -> Void
    @State private var showPassword = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case title, username, site(Int) }
    /// 이름표 열의 폭 ("이름"·"URL" 이 들어간다)
    private static let labelWidth: CGFloat = 30

    /// URL 줄들 — 하나도 없으면 빈 줄 하나를 보인다
    private var sites: [String] { draft.sites.isEmpty ? [""] : draft.sites }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isNew ? "추가" : "편집").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                if isNew {
                    PlainSegmented(items: [SecretNote.Kind.login, .memo], selection: $draft.kind, title: { $0 == .login ? "로그인" : "메모" })
                }
            }
            switch draft.kind {
            case .login: login
            case .memo: memo
            }
            PanelEditorFooter(delete: isNew ? nil : { model.deleteNote(draft.id, for: serverKey); done() }, cancel: done,
                              save: { if model.saveNote(draft, for: serverKey) { done() } },
                              saveDisabled: model.notesError != nil || NoteVault.normalized(draft) == nil)
        }
        // 목록에서 바뀌어 들어오는 순간에 주면 무시된다 — 화면이 붙은 다음 차례에. 주소가 채워져 있으면(브라우저에서 연 새 로그인) ID 부터
        .onAppear { DispatchQueue.main.async { focused = draft.kind == .memo ? .title : (sites[0].isEmpty ? .site(0) : .username) } }
    }

    private func field(_ placeholder: String, text: Binding<String>, _ field: Field, monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .fieldSurface()
            .focused($focused, equals: field)
    }

    /// 이름표 + 칸 한 줄
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.fieldLabel).foregroundStyle(.secondary).frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    private func setSite(_ index: Int, _ value: String) {
        var next = sites
        next[index] = value
        draft.sites = next
    }

    @ViewBuilder
    private var login: some View {
        row("이름") { field("비우면 ID", text: $draft.title, .title) }
        row("ID") { field("ID", text: $draft.username, .username, monospaced: true) }
        row("PW") {
            HStack(spacing: 4) {
                Group {
                    if showPassword {
                        TextField("비밀번호", text: $draft.password).textFieldStyle(.plain).font(.system(.callout, design: .monospaced))
                    } else {
                        RomanSecureField("비밀번호", text: $draft.password, plain: true)
                    }
                }
                .frame(height: 18)
                Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showPassword ? "비밀번호 가리기" : "비밀번호 보기")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .fieldSurface()
        }
        ForEach(Array(sites.enumerated()), id: \.offset) { index, site in
            row(index == 0 ? "URL" : "") {
                field("localhost:3000", text: Binding(get: { site }, set: { setSite(index, $0) }), .site(index), monospaced: true)
                if sites.count > 1 {
                    Button { draft.sites = sites.enumerated().filter { $0.offset != index }.map(\.element) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("이 주소 빼기").help("이 주소 빼기")
                }
            }
        }
        row("") {
            Button { draft.sites = sites + [""]; DispatchQueue.main.async { focused = .site(sites.count - 1) } } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("주소 추가").help("주소 추가 — 같은 계정으로 들어가는 다른 주소")
            Text("적어 둔 주소에서만 채웁니다 — 스킴·포트까지 같아야 합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var memo: some View {
        field("제목 (비우면 본문 첫 줄)", text: $draft.title, .title)
        TextEditor(text: $draft.body)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: 130)
            .fieldSurface()
        Toggle("가리기 — 목록에서 본문을 감추고, 눌러야 보입니다", isOn: $draft.concealed)
            .toggleStyle(.checkbox)
            .font(.callout)
    }
}
