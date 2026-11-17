// 자식 프로세스 로케일. Finder/Dock 으로 뜬 GUI 앱에는 LANG 이 없어 자식이 전부 C 로케일로 돈다 —
// OpenSSH 계열(scp 진행률·sftp ls)이 한글을 \355\225\234 식 8진수로 이스케이프하고, 원격에도 SendEnv 로 로케일이 안 간다.
// 앱 시작 때 한 번 environ 에 넣고(install), Process 를 만들 때도 명시적으로 넣는다 — ProcessInfo.environment 는 시작 시점 스냅샷이라 setenv 를 못 본다.

import Foundation

public enum ProcessLocale {
    /// 시스템 언어(예 ko_KR) + .UTF-8 이 /usr/share/locale 에 있으면 그것, 아니면 en_US.UTF-8 (libghostty 와 같은 규칙).
    /// 이미 LANG 이 있으면(터미널에서 띄운 경우) 그대로 쓴다.
    public static let lang: String = {
        if let existing = ProcessInfo.processInfo.environment["LANG"], !existing.isEmpty { return existing }
        return preferred(candidates: [Locale.current.identifier] + Locale.preferredLanguages, localeDir: "/usr/share/locale")
    }()

    /// 후보(ko_KR, ko-KR, ko_KR@calendar=… 등)를 ll_CC 로 다듬어 <ll_CC>.UTF-8 디렉터리가 있는 첫 것. 없으면 en_US.UTF-8.
    static func preferred(candidates: [String], localeDir: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        for raw in candidates {
            let base = raw.split(whereSeparator: { $0 == "@" || $0 == "." }).first.map(String.init) ?? raw
            let id = base.replacingOccurrences(of: "-", with: "_")
            guard id.range(of: #"^[a-z]{2,3}_[A-Z]{2}$"#, options: .regularExpression) != nil else { continue }
            let name = id + ".UTF-8"
            if exists(localeDir + "/" + name) { return name }
        }
        return "en_US.UTF-8"
    }

    /// 자식에게 줄 환경: 현재 환경 + LANG + 덧씌울 것. LANG 이 이미 있으면 유지.
    /// 숫자는 C (LC_NUMERIC) — 소수점이 쉼표인 언어(독일어 등)면 ps·zsh printf 가 "53,2" 로 찍어 파싱이 깨진다. 터미널 탭(install)은 건드리지 않는다.
    public static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        environment(base: ProcessInfo.processInfo.environment, adding: extra)
    }

    static func environment(base: [String: String], adding extra: [String: String] = [:]) -> [String: String] {
        var env = base
        // LC_ALL 은 LC_NUMERIC 을 덮는다 — 터미널에서 LC_ALL 로 띄웠으면 그 값을 LANG 으로 옮긴다 (LC_ALL 이 LANG 보다 앞서니 나머지는 같다)
        if let all = env.removeValue(forKey: "LC_ALL"), !all.isEmpty { env["LANG"] = all }
        if env["LANG"]?.isEmpty != false { env["LANG"] = lang }
        env["LC_NUMERIC"] = "C"
        return env.merging(extra) { _, new in new }
    }

    /// 앱 시작 시 한 번: environ 에 LANG 을 넣어 libghostty 처럼 environ 을 직접 읽어 자식을 띄우는 쪽도 물려받게 한다. 있으면 덮지 않는다.
    public static func install() {
        setenv("LANG", lang, 0)
    }
}
