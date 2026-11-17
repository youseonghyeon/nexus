// 비밀번호 입력칸 (AppKit NSSecureTextField): 포커스 동안 입력기를 로마자로 묶는다.

import SwiftUI

/// 비밀번호 칸: 포커스되면 입력기를 로마자로 강제한다 (한글 상태에서 아무것도 안 쳐지는 것 방지). 나가면 원래 입력기로 돌아간다.
final class RomanSecureTextField: NSSecureTextField {
    /// 클릭했을 때만 포커스를 받는다 — 창을 열거나 사이드바를 접을 때 AppKit 이 저절로 이 칸을 잡아 커서가 깜빡이지 않게
    var clickToFocus = false
    private var clicked = false

    override var acceptsFirstResponder: Bool { !clickToFocus || clicked }

    override func mouseDown(with event: NSEvent) {
        clicked = true
        super.mouseDown(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        clicked = false
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        let restrict: () -> Void = { [weak self] in self?.currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier] }
        restrict()
        DispatchQueue.main.async { restrict() }   // 필드 에디터가 한 박자 늦게 붙는 경우
        return ok
    }
}

/// SwiftUI 용 RomanSecureTextField. SecureField 와 같은 쓰임(placeholder · text · onSubmit).
struct RomanSecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void
    /// 테두리·바탕·포커스 링 없이 (바탕은 SwiftUI 쪽에서 칠한다)
    var plain = false

    init(_ placeholder: String, text: Binding<String>, plain: Bool = false, onSubmit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        _text = text
        self.plain = plain
        self.onSubmit = onSubmit
    }

    func makeNSView(context: Context) -> RomanSecureTextField {
        let field = RomanSecureTextField()
        field.placeholderString = placeholder
        if plain {
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.clickToFocus = true
        } else {
            field.bezelStyle = .roundedBezel
        }
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: RomanSecureTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RomanSecureField
        init(_ parent: RomanSecureField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
