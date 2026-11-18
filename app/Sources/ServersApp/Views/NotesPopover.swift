// 메모·로그인 팝오버 (탭 막대 오른쪽, 명령 모음 옆의 열쇠 버튼). 선택한 서버의 것만 보인다 — 암호화해 notes.bin 에 둔다 (ServersCore NoteVault).
// 로그인: 누르면 보고 있는 브라우저 탭에 채운다(그 페이지의 로그인일 때만 — 맨 위에 올라온다). 그 밖에는 비밀번호 복사. 줄 끝에서 ID·비밀번호 복사·편집.
// 메모: 누르면 펼쳐 본문을 보인다(가린 메모는 펼쳐야 보인다). 줄 끝에서 복사·편집. 추가·편집·삭제도 이 안에서.
// 키보드: 글자로 거르기 → ↑↓ 로 고르기 → Return.

import ServersCore
import SwiftUI

struct NotesButton: View {
    @Environment(AppModel.self) private var model
    let serverKey: String
    /// 편집 중인 초안. 팝오버 밖에 두어 바깥을 눌러 팝오버가 닫혀도 다시 열면 이어서 쓴다.
    @State private var editing: SecretNote?

    var body: some View {
        @Bindable var model = model   // 팝오버 바인딩($model.notesShown)용
        Button { model.toggleNotes() } label: { Image(systemName: "key") }.accessibilityLabel("메모 · 로그인")
            .buttonStyle(.borderless)
            .padding(.leading, 8)
            .help("메모 · 로그인 — \(serverKey)")
            .popover(isPresented: $model.notesShown, arrowEdge: .bottom) {
                NotesPopover(serverKey: serverKey, editing: $editing) { model.closeNotes() }.environment(model)
            }
            .onDisappear { model.closeNotes() }   // 마지막 탭을 닫거나 서버를 바꿔 버튼이 사라지면, 다음에 탭을 열 때 저절로 뜨지 않게
            .onChange(of: serverKey) { _, _ in editing = nil; model.closeNotes() }   // 다른 서버로 옮겼으면 옛 초안은 버린다 (그 서버에 저장되지 않게)
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
            if NoteVault.fits(note, site: site) { model.fillLogin(note) } else { model.copySecret(note.password, label: "비밀번호") }
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
                Button { editing = SecretNote(kind: site == nil ? .memo : .login, site: site ?? "") } label: { Image(systemName: "plus") }.accessibilityLabel("추가")
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
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .fieldSurface()
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
        .onAppear { searchFocused = true }
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
                    RowIconButton(systemName: "person", help: "ID 복사", visible: hovering) { copy(note.username, "ID") }
                        .disabled(note.username.isEmpty)
                    RowIconButton(systemName: "key", help: "비밀번호 복사", visible: hovering) { copy(note.password, "비밀번호") }
                case .memo:
                    RowIconButton(systemName: "doc.on.doc", help: "복사", visible: hovering) { copy(note.body, "메모") }
                }
                RowIconButton(systemName: "pencil", help: "편집", visible: hovering, action: edit)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(hovering || isSelected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
    }

    @ViewBuilder
    private var detail: some View {
        switch note.kind {
        case .login:
            // 이름을 붙였으면 ID 도 아랫줄에
            Text([note.title.isEmpty ? "" : note.username, BookmarkStore.shortAddress(note.site)].filter { !$0.isEmpty }.joined(separator: " · "))
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

/// 추가·편집. 새것은 종류(로그인·메모)를 고른다. 저장은 ⌘Return (Return 은 메모 칸의 줄바꿈). 삭제는 편집에서만.
private struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: SecretNote
    let serverKey: String
    let isNew: Bool
    let done: () -> Void
    @State private var showPassword = false
    @FocusState private var focused: Field?

    private enum Field { case title, site, username }

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
            HStack {
                if !isNew {
                    Button("삭제") { model.deleteNote(draft.id, for: serverKey); done() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("취소", action: done)
                    .buttonStyle(SecondaryButtonStyle())
                Button("저장") { if model.saveNote(draft, for: serverKey) { done() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.notesError != nil || NoteVault.normalized(draft) == nil)
                    .help("저장 (⌘Return)")
            }
        }
        // 목록에서 바뀌어 들어오는 순간에 주면 무시된다 — 화면이 붙은 다음 차례에
        .onAppear { DispatchQueue.main.async { focused = draft.kind == .memo ? .title : (draft.site.isEmpty ? .site : .username) } }
    }

    private func field(_ placeholder: String, text: Binding<String>, _ field: Field, monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .fieldSurface()
            .focused($focused, equals: field)
    }

    @ViewBuilder
    private var login: some View {
        field("주소 (localhost:3000)", text: $draft.site, .site, monospaced: true)
        field("ID", text: $draft.username, .username, monospaced: true)
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
        field("이름 (비우면 ID)", text: $draft.title, .title)
        Text("주소가 같은 페이지에서만 채웁니다 (http 와 https, 포트가 다르면 다른 곳).")
            .font(.caption).foregroundStyle(.secondary)
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
