// 저장 키(비밀번호·키 파일: 기본 계정 `키`, 추가 계정 `키@계정`) 옮기기 — 이름 바꾸기·편집·계정 순서 변경·합치기 때.
// 파일 텍스트는 건드리지 않고 {저장 키: 값} 사전만 바꾼 사본을 돌려준다.

import Foundation

extension ServerConfigEditor {
    /// 파일에 이름을 쓰기 전에 저장할 값: 옛 자리도 두고 새 자리에 복사한다. 파일을 쓴 뒤 죽거나 저장이 실패해도, 어느 쪽이든 다음에 목록을 읽을 때 주인 없는 쪽만 빠진다.
    /// known(앱이 아는 목록)과 onDisk(지금 파일)의 계정 순서가 다르면(파일을 직접 고치고 다시 읽기 전) 먼저 계정을 따라 맞춘다 — 접두사만 바꾸면 다른 계정으로 간다.
    public static func stagingRename<Value>(_ values: [String: Value], known: ServerConfig, onDisk: ServerConfig, from old: String, to new: String) -> [String: Value] {
        let aligned = rekeyingCredentials(values, from: known, to: onDisk)
        return aligned.merging(renamingCredentials(aligned, from: old, to: new)) { _, renamed in renamed }
    }

    /// 비밀번호·키 파일의 저장 키를 새 이름으로 옮긴 사본 (기본 계정 `키`, 추가 계정 `키@계정` — @ 까지 봐서 이름이 비슷한 서버는 건드리지 않는다).
    public static func renamingCredentials<Value>(_ values: [String: Value], from old: String, to new: String) -> [String: Value] {
        var moved: [String: Value] = [:]
        for (key, value) in values {
            if key == old {
                moved[new] = value
            } else if key.hasPrefix("\(old)@") {
                moved[new + key.dropFirst(old.count)] = value
            } else {
                moved[key] = value
            }
        }
        return moved
    }

    /// 편집으로 지울 비밀번호의 저장 키 (파일에 쓴 뒤, 목록을 다시 읽기 전에 지운다): 다른 장비로 옮기면 모든 계정, 아니면 사라진 계정의 값만 —
    /// 옛 비밀번호를 새 곳으로 보내지 않게. 남은 계정의 값은 지우지 않는다 (순서가 바뀌면 rekeyingCredentials 가 옮긴다).
    public static func clearedCredentials(_ original: Server, _ edited: NewServer) -> [String] {
        if original.ip != edited.ip { return original.credentialKeys }
        let kept = [edited.user] + edited.extraUsers
        return original.accounts.filter { !kept.contains($0) }.map(original.credentialKey(for:))
    }

    /// 목록을 다시 읽을 때: 계정 순서(user= ↔ extra_users=)가 바뀌면 저장 키가 바뀐다 — 값이 계정을 따라가게 옮긴 사본.
    /// 없으면 서버 키 자리의 값이 새 기본 계정의 로그인에 쓰이고, 추가 계정의 값은 주인 없는 키가 되어 지워진다.
    /// 기본 계정이 목록에서 사라지고 다른 계정이 올라오면 그 자리의 옛 값은 버린다. 처음 보는 사용자로 바꾸기만 하면 그대로 (계정 하나인 서버의 사용자 변경).
    public static func rekeyingCredentials<Value>(_ values: [String: Value], from old: ServerConfig, to new: ServerConfig) -> [String: Value] {
        var out = values
        var moved: [String: Value] = [:]
        for before in old.servers {
            guard let after = new.server(before.key) else { continue }
            for name in before.accounts where after.accounts.contains(name) {
                let from = before.credentialKey(for: name), to = after.credentialKey(for: name)
                guard from != to else { continue }
                if let value = values[from] { moved[to] = value }
                out[from] = nil
            }
            // 기본 계정이 사라지고 추가 계정이 올라왔다 — 서버 키 자리의 값은 사라진 계정의 것
            if !after.accounts.contains(before.primaryUser), before.accounts.contains(after.primaryUser) { out[before.key] = nil }
        }
        return out.merging(moved) { _, new in new }
    }

    /// 합친 source 의 계정별 값(비밀번호·키 파일)을 target 의 계정 자리로 옮긴 사본. 값이 없는 계정은 만들지 않는다.
    public static func movingCredentials<Value>(_ values: [String: Value], from source: Server, into targetKey: String) -> [String: Value] {
        var moved = values
        for name in source.accounts {
            if let value = moved.removeValue(forKey: source.credentialKey(for: name)) { moved["\(targetKey)@\(name)"] = value }
        }
        return moved
    }
}
