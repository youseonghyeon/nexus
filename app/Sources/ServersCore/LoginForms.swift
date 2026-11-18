// 브라우저 탭의 로그인 폼 읽기·채우기 스크립트 (NoteVault 의 로그인 항목). BrowserSession 이 페이지와 분리된 영역(WKContentWorld)에서 돌린다 —
// 페이지의 스크립트는 이 코드도, 앱으로 보내는 통로(handler)도 볼 수 없다. 맨 위 프레임에서만.
//   잡기: 폼 제출 · 입력칸의 Enter · 버튼 클릭 때, 값이 든 비밀번호 칸이 딱 하나면 그 값과 앞의 글자 칸(ID)을 보낸다 (둘 이상이면 가입·비밀번호 변경이라 안 보낸다).
//         보낸 뒤 비밀번호 칸이 사라지면(주소가 안 바뀌는 화면의 로그인 성공) gone 을 보낸다. 페이지가 통째로 넘어가면 앱이 visibleScript 로 다시 본다.
//   알리기: 비밀번호 칸이 보이는지를 field 로 보낸다 (열 때 한 번 · 바뀔 때마다).
//           로그인 칸(비밀번호 칸 · 그 앞의 ID 칸)에 포커스가 가거나 그 칸을 누르면 칸의 자리를 focus 로 보낸다 — 앱이 그 아래에 저장한 로그인 목록을 띄운다.
//           포커스가 떠나거나 · 글자를 치거나 · 스크롤·창 크기가 바뀌면 blur (목록을 내린다 — 자리가 어긋난다. 칸을 다시 누르면 뜬다).
//   채우기: 보이는 첫 비밀번호 칸과 그 앞의 글자 칸에 값을 넣고 input·change 를 낸다. 비밀번호 칸이 없으면(ID 먼저 묻는 화면) ID 칸만.
// 키워드로 찾는 것이라 다 맞지는 않는다 — 못 잡은 것은 팝오버에서 직접 넣는다.

import Foundation

public enum LoginForms {
    /// 스크립트가 도는 영역 이름 · 앱으로 보내는 통로 이름
    public static let world = "nexusLogin"
    public static let handler = "nexusLogin"

    /// 칸 찾기 (잡기·채우기·확인이 같이 쓴다). 보이는 칸만 — 숨긴 칸에 채우거나 거기서 읽지 않는다.
    static let helpers = """
        const visible = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && !el.disabled; };
        const passwords = scope => [...scope.querySelectorAll('input[type=password]')].filter(visible);
        const named = el => ['text', 'email'].includes(el.type) && visible(el)
            && /user|login|email|account|(^|[^a-z])id($|[^a-z])/i.test([el.name, el.id, el.autocomplete].join(' '));
        const userFor = pw => {
            let found = null;
            for (const el of (pw.form || document).querySelectorAll('input')) {
                if (el === pw) break;
                if (['text', 'email', 'tel', 'number'].includes(el.type) && visible(el)) found = el;
            }
            return found;
        };
        """

    /// 페이지마다 문서가 다 읽힌 뒤 넣는다
    public static let captureScript = """
        (() => {
            if (window.__nexusLoginWatch) return;
            window.__nexusLoginWatch = true;
            \(helpers)
            const post = body => { try { window.webkit.messageHandlers.\(handler).postMessage(body); } catch (e) {} };
            let timers = [];
            const send = scope => {
                const filled = passwords(scope).filter(el => el.value);
                if (filled.length !== 1) return;
                const user = userFor(filled[0]);
                post({ username: user ? user.value : '', password: filled[0].value });
                timers.forEach(clearTimeout);
                timers = [1500, 4000].map(ms => setTimeout(() => { if (passwords(document).length === 0) post({ gone: true }); }, ms));
            };
            // 비밀번호 칸이 보이기 시작했다·사라졌다 (주소가 안 바뀌고 화면만 갈리는 페이지도 — 바뀔 때만, 0.3초에 한 번까지만 본다)
            let shown = null, pending = null;
            const check = () => { pending = null; const now = passwords(document).length > 0; if (now !== shown) { shown = now; post({ field: now }); } };
            check();
            new MutationObserver(() => { if (pending === null) pending = setTimeout(check, 300); })
                .observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'style', 'class', 'hidden', 'disabled'] });
            // 로그인 칸인가: 보이는 비밀번호 칸 · 그 앞의 ID 칸 · (비밀번호 칸이 없는 화면에서) 이름으로 보아 ID 칸
            const loginField = el => {
                if (!(el instanceof HTMLInputElement) || !visible(el)) return false;
                const all = passwords(document);
                return all.includes(el) || all.some(pw => userFor(pw) === el) || (all.length === 0 && named(el));
            };
            let open = false;
            const show = el => { const r = el.getBoundingClientRect(); open = true; post({ focus: { x: r.left, y: r.top, width: r.width, height: r.height } }); };
            const hide = () => { if (open) { open = false; post({ blur: true }); } };
            document.addEventListener('focusin', e => { if (loginField(e.target)) show(e.target); else hide(); }, true);
            document.addEventListener('mousedown', e => { if (loginField(e.target)) show(e.target); }, true);
            document.addEventListener('focusout', () => setTimeout(() => { if (!loginField(document.activeElement)) hide(); }, 100), true);
            document.addEventListener('input', hide, true);
            window.addEventListener('scroll', hide, true);
            window.addEventListener('resize', hide);
            if (loginField(document.activeElement)) show(document.activeElement);
            const scopeOf = el => (el && el.closest && el.closest('form')) || document;
            document.addEventListener('submit', e => send(e.target instanceof HTMLFormElement ? e.target : document), true);
            document.addEventListener('keydown', e => {
                if (e.key === 'Enter' && !e.isComposing && e.target instanceof HTMLInputElement) send(scopeOf(e.target));
            }, true);
            document.addEventListener('click', e => {
                const button = e.target && e.target.closest && e.target.closest('button, input[type=submit], input[type=button], [role=button], a');
                if (button) send(scopeOf(button));
            }, true);
        })();
        """

    /// 지금 페이지에 비밀번호 칸이 보이는가 (callAsyncJavaScript — true/false)
    public static let visibleScript = """
        \(helpers)
        return passwords(document).length > 0;
        """

    /// 채우기 (callAsyncJavaScript, 인자 username·password). 돌려주는 값은 Filled 의 글자.
    /// 값은 입력칸의 원래 setter 로 넣고 input·change 를 낸다 — 값을 따로 들고 있는 화면(React 등)도 바뀐 줄 안다.
    public static let fillScript = """
        \(helpers)
        const set = (el, value) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const pw = passwords(document)[0];
        let user = pw ? userFor(pw) : null;
        if (!pw) {
            const candidates = [...document.querySelectorAll('input')].filter(named);
            if (candidates.length === 1) user = candidates[0];
        }
        if (user && username) set(user, username);
        if (pw) { set(pw, password); pw.focus(); }
        return pw ? 'filled' : (user && username ? 'user' : 'none');
        """

    public enum Filled: String, Sendable {
        /// 비밀번호(와 ID)를 넣었다
        case filled
        /// 비밀번호 칸이 없어 ID 만 넣었다
        case user
        /// 넣을 칸을 못 찾았다
        case none
    }

    /// 페이지가 보낸 것
    public enum Message: Equatable, Sendable {
        case candidate(username: String, password: String)
        /// 잡은 뒤 비밀번호 칸이 사라졌다
        case gone
        /// 비밀번호 칸이 보인다(로그인 화면) · 안 보인다 — 바뀔 때마다, 페이지를 열 때 한 번
        case field(Bool)
        /// 로그인 칸에 포커스가 갔다·그 칸을 눌렀다 — 칸의 자리 (웹 화면 왼쪽 위 기준)
        case focus(Rect)
        /// 로그인 칸을 떠났다 · 글자를 쳤다 · 스크롤했다
        case blur
    }

    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    }

    /// 칸 아래에 띄울 목록의 자리 (웹 화면 안, 왼쪽 위 기준). 폭은 칸에 맞추되 너무 좁지 않게, 화면 밖으로 나가면 안으로 당긴다.
    /// 아래에 자리가 없으면 칸 위로 — 위에도 없으면 아래에 둔다 (잘려도 칸은 가리지 않는다).
    public static func dropdownFrame(field: Rect, container: (width: Double, height: Double), contentHeight: Double,
                                     minWidth: Double = 240, gap: Double = 4, margin: Double = 8) -> Rect {
        let width = max(min(max(field.width, minWidth), container.width - margin * 2), 0)
        let x = max(min(field.x, container.width - margin - width), margin)
        var y = field.y + field.height + gap
        let above = field.y - gap - contentHeight
        if y + contentHeight > container.height - margin, above >= margin { y = above }
        return Rect(x: x, y: y, width: width, height: contentHeight)
    }

    public static func parse(_ body: Any) -> Message? {
        guard let body = body as? [String: Any] else { return nil }
        if body["gone"] as? Bool == true { return .gone }
        if let field = body["field"] as? Bool { return .field(field) }
        if body["blur"] as? Bool == true { return .blur }
        if let rect = body["focus"] as? [String: Any] {
            let values = ["x", "y", "width", "height"].compactMap { (rect[$0] as? NSNumber)?.doubleValue }.filter(\.isFinite)
            guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
            return .focus(Rect(x: values[0], y: values[1], width: values[2], height: values[3]))
        }
        guard let password = body["password"] as? String, !password.isEmpty else { return nil }
        return .candidate(username: body["username"] as? String ?? "", password: password)
    }
}
