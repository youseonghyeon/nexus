// 명령 모음 팝오버 (탭 막대 오른쪽 끝 · ⌘P). 선택한 서버 종류(windows·linux)·이 Mac 로컬 셸(mac)의 명령을 보여 주고, 누르면 보고 있는 터미널에 입력한다.
// "바로 실행" 명령만 Enter 까지 보낸다. 터미널이 안 보이면(Dashboard·브라우저 탭) 누르면 복사. 추가·편집·삭제도 이 안에서.
// 키보드만으로: ⌘P → 글자로 거르기 → ↑↓ 로 고르기 → Return. 빈칸 {{이름}} 이 있으면 값을 물은 뒤 입력한다.
// 민감한 명령(재부팅·삭제 등)은 터미널에 넣기 전에 서버 이름(이 Mac 은 "mac")을 쳐서 확인한다 — 엉뚱한 서버에서 실행하는 실수를 막으려고. 복사는 그대로.

import ServersCore
import SwiftUI

struct SnippetsButton: View {
    @Environment(AppModel.self) private var model
    let type: SnippetKind
    /// 편집 중인 초안. 팝오버 밖에 두어 바깥을 눌러 팝오버가 닫혀도 다시 열면 이어서 쓴다.
    @State private var editing: CommandSnippet?

    var body: some View {
        @Bindable var model = model   // 팝오버 바인딩($model.snippetsShown)용
        Button { model.toggleSnippets() } label: { Image(systemName: "list.bullet.rectangle") }.accessibilityLabel("명령 모음")
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .help("명령 모음 (⌘P)")
            .popover(isPresented: $model.snippetsShown, arrowEdge: .bottom) {
                SnippetsPopover(type: type, editing: $editing) { model.closeSnippets() }.environment(model)
            }
            .onDisappear { model.closeSnippets() }   // 마지막 탭을 닫거나 서버를 바꿔 버튼이 사라지면, 다음에 탭을 열 때 저절로 뜨지 않게
            .onChange(of: model.snippetsShown) { _, shown in
                if shown, editing.map({ $0.type != type }) ?? false { editing = nil }   // 다른 종류 서버로 옮겼으면 옛 초안은 버린다
            }
    }
}

/// 누르면 할 일. 빈칸이 있으면 값을 받은 뒤에 한다.
private enum SnippetAction { case type, copy }

struct SnippetsPopover: View {
    @Environment(AppModel.self) private var model
    let type: SnippetKind
    /// 편집 중인 명령 (nil 이면 목록). 새것은 아직 목록에 없는 id.
    @Binding var editing: CommandSnippet?
    let close: () -> Void
    @State private var query = ""
    /// ↑↓ 로 고른 줄 (거른 목록 안의 위치)
    @State private var selected = 0
    /// 빈칸 값을 받는 중인 명령과, 받은 뒤 할 일
    @State private var filling: (snippet: CommandSnippet, action: SnippetAction)?
    /// 민감한 명령: 서버 이름 확인을 기다리는 명령 (빈칸은 채운 뒤)
    @State private var confirming: CommandSnippet?
    @FocusState private var searchFocused: Bool

    private var all: [CommandSnippet] { SnippetStore.snippets(for: type, in: model.snippets) }
    private var shown: [CommandSnippet] { all.filter { SnippetStore.matches($0, query) } }
    private var typeName: String { type.title }
    /// 민감한 명령 확인에 칠 낱말: 서버 키 · 이 Mac 은 "mac"
    private var confirmWord: String { type == .mac ? "mac" : (model.selectedServer?.key ?? "") }
    private var canType: Bool { model.visibleTerminal != nil }

    var body: some View {
        Group {
            if let draft = editing {
                SnippetEditor(draft: Binding(get: { editing ?? draft }, set: { editing = $0 }),
                              isNew: !all.contains { $0.id == draft.id }) { editing = nil }
                    .id(draft.id)
            } else if let confirming {
                SnippetConfirm(word: confirmWord, run: confirming.runImmediately,
                               confirm: { self.confirming = nil; close(); model.typeSnippet(confirming) },
                               cancel: { self.confirming = nil })
                    .id(confirming.id)
            } else if let filling {
                SnippetFill(snippet: filling.snippet, action: filling.action,
                            perform: { command in perform(filling.snippet, command: command, filling.action) },
                            cancel: { self.filling = nil })
                    .id(filling.snippet.id)
            } else {
                list
            }
        }
        .padding(12)
        .frame(width: 400)
    }

    /// 빈칸이 없으면 바로, 있으면 값 받는 화면으로
    private func activate(_ snippet: CommandSnippet, _ action: SnippetAction) {
        if SnippetTemplate.variables(in: snippet.command).isEmpty {
            perform(snippet, command: snippet.command, action)
        } else {
            filling = (snippet, action)
        }
    }

    private func perform(_ snippet: CommandSnippet, command: String, _ action: SnippetAction) {
        switch action {
        case .type:
            var filled = snippet
            filled.command = command
            if SnippetStore.needsConfirm(snippet, filled: command) {
                filling = nil
                confirming = filled
                return
            }
            close()
            model.typeSnippet(filled)
        case .copy:
            model.copy(command)
            close()
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(typeName) 명령 · \(canType ? "누르면 터미널에 입력" : "누르면 복사")")
                    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                Button { editing = CommandSnippet(type: type) } label: { Image(systemName: "plus") }.accessibilityLabel("명령 추가")
                    .buttonStyle(.borderless)
                    .disabled(model.snippetsError != nil)
                    .help("명령 추가")
            }
            if let error = model.snippetsError {
                Text(error.description).font(.caption).foregroundStyle(StatusTone.warn.color).textSelection(.enabled)
            } else if all.isEmpty {
                Text("등록한 명령이 없습니다. + 로 추가하세요.").font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                TextField("검색 · ↑↓ 고르기 · Return", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .fieldSurface()
                    .focused($searchFocused)
                    .onSubmit {
                        guard shown.indices.contains(selected) else { return }
                        activate(shown[selected], canType ? .type : .copy)
                    }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: query) { _, _ in selected = 0 }
                    .onChange(of: shown.count) { _, count in selected = min(selected, max(count - 1, 0)) }   // 지운 뒤 범위 밖이면 Return 이 안 먹는다
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, snippet in
                                SnippetRow(snippet: snippet, canType: canType, isSelected: index == selected,
                                           type: { activate(snippet, .type) },
                                           copy: { activate(snippet, .copy) },
                                           edit: { editing = snippet })
                                    .id(snippet.id)
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
                    Text("맞는 명령이 없습니다").font(.callout).foregroundStyle(.secondary)
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

/// 한 줄: 이름 + 명령 미리보기. 누르면 터미널에 입력(터미널이 없으면 복사), 마우스를 올리면 복사·편집 아이콘.
/// 바로 실행 명령은 이름 옆 ↵ 표시 — 누르면 Enter 까지 간다. ↑↓ 로 고른 줄은 마우스를 올린 것과 같은 면.
private struct SnippetRow: View {
    let snippet: CommandSnippet
    let canType: Bool
    let isSelected: Bool
    let type: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snippet.displayTitle).font(.callout).lineLimit(1)
                    if snippet.runImmediately {
                        Image(systemName: "return").font(.caption2).foregroundStyle(.secondary).help("바로 실행 — Enter 까지 보냅니다")
                    }
                    if snippet.sensitive {
                        Image(systemName: "exclamationmark.shield").font(.caption2).foregroundStyle(.secondary).help("민감한 명령 — 입력 전에 서버 이름을 확인합니다")
                    }
                }
                Text(snippet.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                RowIconButton(systemName: "doc.on.doc", help: "복사", visible: hovering, action: copy)
                RowIconButton(systemName: "pencil", help: "편집", visible: hovering, action: edit)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(hovering || isSelected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: canType ? type : copy)
        .contextMenu {
            Button(snippet.runImmediately ? "터미널에서 실행" : "터미널에 입력", action: type).disabled(!canType)
            Button("복사", action: copy)
            Button("편집…", action: edit)
        }
    }
}

/// 줄 끝 작은 버튼: 24pt 정사각형 누름 영역, 마우스를 올리면 그 칸만 줄보다 한 단계 진한 면 — 어디를 누르는지 보이게.
/// 감춰져 있어도(줄에 마우스가 없을 때) 누름 영역은 남긴다 — 팝오버가 열릴 때 이미 그 자리에 있던 커서로 눌러도 입력이 아니라 이 동작이 되게.
private struct RowIconButton: View {
    let systemName: String
    let help: String
    let visible: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .background(hovering ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.primary : Color.secondary)
        .opacity(visible || hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 민감한 명령 확인: "확인하려면 nexus 를 입력하세요" + 입력 칸 하나. 맞게 쳐야 [입력]·Return 이 된다.
private struct SnippetConfirm: View {
    let word: String
    let run: Bool
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var ok: Bool { SnippetStore.confirms(typed, server: word) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("확인하려면 \(Text(word).bold()) 를 입력하세요").font(.callout)
            TextField(word, text: $typed)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .fieldSurface()
                .focused($focused)
                .onSubmit { if ok { confirm() } }
            HStack {
                Spacer()
                Button("취소", action: cancel)
                    .buttonStyle(SecondaryButtonStyle())
                Button(run ? "실행" : "입력", action: confirm)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!ok)
            }
        }
        // 목록에서 바뀌어 들어오는 순간에 주면 무시된다 — 화면이 붙은 다음 차례에
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// 빈칸 {{이름}} 값 받기. Return 은 다음 칸, 마지막 칸이면 입력. 모든 칸을 채워야 입력·복사가 된다.
/// 값은 앱이 켜져 있는 동안 이름별로 기억해 다음에 채워 둔다 (AppModel.snippetValues).
private struct SnippetFill: View {
    @Environment(AppModel.self) private var model
    let snippet: CommandSnippet
    let action: SnippetAction
    let perform: (String) -> Void
    let cancel: () -> Void
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    private var names: [String] { SnippetTemplate.variables(in: snippet.command) }
    /// 앞뒤 공백·줄바꿈은 뗀 값 (붙여 넣은 줄바꿈이 셸에서 Enter 가 되지 않게)
    private var trimmed: [String: String] { values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    private var complete: Bool { names.allSatisfy { !(trimmed[$0] ?? "").isEmpty } }
    private var filled: String { SnippetTemplate.fill(snippet.command, values: trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snippet.displayTitle).font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            ForEach(names, id: \.self) { name in
                HStack(spacing: 8) {
                    Text(name).font(.callout).frame(minWidth: 60, alignment: .leading)
                    TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .fieldSurface()
                        .focused($focused, equals: name)
                        .onSubmit { next(after: name) }
                }
            }
            Text(filled)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("취소", action: cancel)
                    .buttonStyle(SecondaryButtonStyle())
                Button(action == .copy ? "복사" : (snippet.runImmediately ? "실행" : "입력"), action: submit)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!complete)
            }
        }
        .onAppear {
            values = model.snippetValues.filter { names.contains($0.key) }
            let first = names.first { (values[$0] ?? "").isEmpty } ?? names.first
            DispatchQueue.main.async { focused = first }   // 확인 화면과 같은 이유로 다음 차례에
        }
    }

    private func next(after name: String) {
        if let i = names.firstIndex(of: name), i + 1 < names.count {
            focused = names[i + 1]
        } else {
            submit()
        }
    }

    private func submit() {
        guard complete else { return }
        model.rememberSnippetValues(trimmed)
        perform(filled)
    }
}

/// 추가·편집. 명령이 비면 저장 비활성. 삭제는 편집에서만 (목록에서 실수로 지우지 않게).
/// 저장은 ⌘Return — Return 은 명령 칸의 줄바꿈이고, 팝오버가 키 창이 아닐 때 본 창의 기본 버튼(SSH)으로 새지 않게 한다.
private struct SnippetEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: CommandSnippet
    let isNew: Bool
    let done: () -> Void
    @FocusState private var titleFocused: Bool
    @State private var sensitiveTouched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? "명령 추가" : "명령 편집").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            TextField("이름 (비우면 명령 첫 줄)", text: $draft.title)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .fieldSurface()
                .focused($titleFocused)
            TextEditor(text: $draft.command)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 110)
                .fieldSurface()
            Text("{{이름}} 은 빈칸 — 누를 때 값을 묻습니다 (예: Get-Service {{서비스}})")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("바로 실행 — 누르면 Enter 까지 보냅니다", isOn: $draft.runImmediately)
                .toggleStyle(.checkbox)
                .font(.callout)
            // 재부팅·삭제 같은 글자가 보이면 저절로 켠다 (직접 바꾸면 그 뒤로는 손대지 않는다)
            Toggle("민감한 명령 — 입력 전에 서버 이름을 확인합니다", isOn: Binding(get: { draft.sensitive }, set: { draft.sensitive = $0; sensitiveTouched = true }))
                .toggleStyle(.checkbox)
                .font(.callout)
                .onChange(of: draft.command) { _, command in
                    if !sensitiveTouched { draft.sensitive = SnippetStore.looksSensitive(command) }   // 고치다 민감한 글자가 빠지면 다시 끈다
                }
            // 붙여 넣기 모드를 안 쓰는 셸(cmd·sh 등)은 안쪽 줄바꿈을 Enter 로 받는다 — 체크를 꺼도 막을 수 없다
            if draft.command.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline) {
                Text("여러 줄 명령은 셸에 따라 체크를 꺼도 줄마다 실행될 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if !isNew {
                    Button("삭제") { model.deleteSnippet(draft.id); done() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("취소", action: done)
                    .buttonStyle(SecondaryButtonStyle())
                Button("저장") { if model.saveSnippet(draft) { done() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(SnippetStore.normalized(draft) == nil)
                    .help("저장 (⌘Return)")
            }
        }
        .onAppear {
            titleFocused = true
            // 글자로는 민감한데 꺼져 있으면 예전에 사용자가 끈 것 — 명령을 고쳐도 다시 켜지 않는다
            sensitiveTouched = !draft.sensitive && SnippetStore.looksSensitive(draft.command)
        }
    }
}
