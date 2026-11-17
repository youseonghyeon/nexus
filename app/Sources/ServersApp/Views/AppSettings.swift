// 저장된 설정 값 읽기 (UserDefaults) — 키·고를 수 있는 값·기본값은 ServersCore AppPreferences.

import Foundation
import ServersCore

enum AppSettings {
    /// 저장된 간격 (목록 밖이면 기본값)
    static func interval(_ preference: IntervalPreference) -> Double {
        preference.resolve(UserDefaults.standard.object(forKey: preference.key) as? Double)
    }
}
