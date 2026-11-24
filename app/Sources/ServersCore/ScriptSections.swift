// 원격 스크립트 출력을 "@이름" 구역으로 나눈다 (LinuxLive · WindowsLive · OpenWrt 공용).

import Foundation

/// 원격 스크립트 출력의 구역: "@이름"(대문자·숫자) 줄부터 다음 머리줄까지, "@END" 에서 끝. Linux Live · OpenWrt 공용.
public enum ScriptSections {
    /// @END 가 없으면(출력이 중간에 끊김) nil. dropEmpty: 빈 줄을 뺀다 (OpenWrt 는 JSON 을 그대로 잇느라 남긴다).
    public static func parse(_ text: String, dropEmpty: Bool) -> [String: [String]]? {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.count > 1, line.hasPrefix("@"), line.dropFirst().allSatisfy({ $0.isUppercase || $0.isNumber }) {
                let name = String(line.dropFirst())
                if name == "END" { return result }
                current = name
                result[name] = result[name] ?? []
            } else if let current, !(dropEmpty && line.isEmpty) {
                result[current, default: []].append(line)
            }
        }
        return nil
    }
}
