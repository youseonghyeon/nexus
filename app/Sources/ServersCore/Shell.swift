// 셸 명령 문자열에 값을 끼울 때의 인용. 원격 명령·스크립트를 조립하는 곳이 함께 쓴다.

import Foundation

/// POSIX 단일 인용. zsh 의 %q 와 달리 어떤 셸에서도 같은 결과다.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
