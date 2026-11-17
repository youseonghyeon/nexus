// 패킷 캡처 창 툴바의 필터 칸(AppKit — 편집 시작·끝을 직접 알린다)과 그 아래 필터 도우미 목록. 후보 계산은 ServersCore CaptureFilterAssist.

import ServersCore
import SwiftUI

/// 툴바의 필터 칸. 편집 시작·끝을 직접 알린다 (툴바 안에서는 SwiftUI 포커스 상태가 켜지지 않았다).
/// Enter = 적용, Esc = 도우미 닫기. 바깥 번호(focusRequest·endRequest)가 바뀌면 포커스를 주거나 거둔다.
struct FilterField: NSViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    let focusRequest: Int
    let endRequest: Int
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusReportingField {
        let field = FocusReportingField()
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.setEditing(true) }
        field.onBlur = { [weak coordinator = context.coordinator] in coordinator?.setEditing(false) }
        context.coordinator.focusRequest = focusRequest
        context.coordinator.endRequest = endRequest
        return field
    }

    func updateNSView(_ field: FocusReportingField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
            }
        }
        if coordinator.endRequest != endRequest {
            coordinator.endRequest = endRequest
            DispatchQueue.main.async {
                if let editor = field.currentEditor(), field.window?.firstResponder === editor { field.window?.makeFirstResponder(nil) }
                coordinator.setEditing(false)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterField
        var focusRequest = 0
        var endRequest = 0
        private var blurTask: Task<Void, Never>?

        init(_ parent: FilterField) { self.parent = parent }

        /// 끝남은 조금 늦게 — 도우미 줄을 누르는 동안 칸이 잠깐 포커스를 잃어도 목록이 먼저 사라지지 않게
        func setEditing(_ value: Bool) {
            blurTask?.cancel()
            if value {
                if !parent.editing { parent.editing = true }
                return
            }
            blurTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.parent.editing else { return }
                self.parent.editing = false
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            setEditing(true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                setEditing(false)
                return true
            }
            return false
        }
    }
}

/// 포커스를 받거나(클릭) 편집이 끝나면(다른 곳 클릭·Tab) 알리는 칸
final class FocusReportingField: NSTextField {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onBlur?()
    }
}

// MARK: 필터 도우미 목록

struct FilterSuggestionPanel: View {
    let suggestions: [FilterSuggestion]
    let text: String
    let pick: (FilterSuggestion) -> Void
    let apply: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, s in
                // 자주 쓰는 것은 따로 묶는다
                if s.kind == .preset, index == 0 || suggestions[index - 1].kind != .preset {
                    Text("자주 쓰는 것").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, index == 0 ? 6 : 8).padding(.bottom, 2)
                }
                Button { pick(s) } label: {
                    HStack(spacing: 10) {
                        Text(s.title).font(.body.monospaced()).fontWeight(.medium)
                        Text(s.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SuggestionRowStyle())
            }
            HStack(spacing: 8) {
                Text(text.trimmingCharacters(in: .whitespaces).isEmpty ? "고르면 다음에 올 것이 이어서 나옵니다" : "적용 전에 문법을 확인합니다")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("닫기 ⎋", action: close)
                Button("적용 ⏎", action: apply)   // 빈 칸 적용 = 필터 없이 전부 받기
            }
            .buttonStyle(CompactButtonStyle())
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .padding(.vertical, 2)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// 마우스를 올리면 옅은 면 (무채색)
private struct SuggestionRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
            .onHover { hovering = $0 }
    }
}
