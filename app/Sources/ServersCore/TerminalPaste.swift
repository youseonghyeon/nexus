// 터미널에 이미지·문서 넣기 (Ghostty 앱처럼): ⌘V·끌어 놓기로 받은 파일·클립보드 이미지를 경로로 입력한다.
//   로컬 셸  파일은 그 경로 그대로, 클립보드 이미지(스크린샷 등 경로 없는 데이터)는 임시 파일로 저장해 그 경로.
//   SSH 탭  이미지·문서(isUploadable — imageExtensions·documentExtensions)만 서버 임시 폴더로 올린 뒤(scp) 서버 쪽 경로를 입력한다 — Mac 경로는 서버에서 쓸 수 없다.
// 판정(plan)·이름·경로만 여기 두고, 클립보드 읽기·저장·전송·입력은 앱(AppModel+TerminalPaste)이 한다.

import Foundation

public enum TerminalPaste {
    /// 무엇을 할지. none 이면 앱이 손대지 않는다 (⌘V 는 Ghostty 기본 붙여 넣기, 끌어 놓기는 받지 않음).
    public enum Plan: Equatable, Sendable {
        case none
        /// 이 경로들을 그대로 입력 (로컬 셸)
        case pastePaths([String])
        /// 이 파일들(이미지·문서)을 서버로 올리고 서버 경로를 입력 (SSH 탭)
        case upload([String])
        /// 클립보드 이미지 데이터를 임시 파일로 저장한 뒤 — upload 면 서버로 올려서 — 그 경로를 입력
        case stageImage(upload: Bool)
    }

    /// files: 클립보드·끌어 놓기의 파일 경로들. hasText: 클립보드에 글자가 있는가. hasImageData: 경로 없는 이미지 데이터가 있는가.
    /// 순서는 Ghostty 와 같다 — 파일 먼저, 그다음 글자. 이미지 데이터는 글자가 없을 때만 (표 복사처럼 글자와 그림이 함께 오면 글자).
    public static func plan(remote: Bool, files: [String], hasText: Bool, hasImageData: Bool) -> Plan {
        if !files.isEmpty {
            guard remote else { return .pastePaths(files) }
            return files.allSatisfy(isUploadable) ? .upload(files) : .none   // 그 밖의 파일·폴더는 올리지 않는다 (⌘V 는 원래대로 Mac 경로)
        }
        if hasText { return .none }
        return hasImageData ? .stageImage(upload: remote) : .none
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    /// SSH 탭에서 함께 올리는 문서 — Claude Code 등이 경로로 바로 읽는 것만 (2026-11-09 추가). 압축·실행 파일·폴더는 터미널에 놓아 올리지 않는다.
    static let documentExtensions: Set<String> = ["pdf", "txt", "md", "csv", "json", "log", "yaml", "yml", "xml", "html"]

    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// SSH 탭에 놓거나 ⌘V 했을 때 서버로 올리는 파일인가 (이미지·문서)
    public static func isUploadable(_ path: String) -> Bool {
        isImage(path) || documentExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Ghostty 의 Shell.escape 와 같은 글자들 앞에 \ — 프롬프트에 친 경로처럼 (libghostty TerminalShellEscape 는 공개되지 않아 옮겨 둠)
    private static let escapedCharacters: Set<Character> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
        "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]

    public static func shellEscape(_ path: String) -> String {
        var result = ""
        for character in path {
            if escapedCharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// 입력할 글자: 경로마다 escape, 공백으로 잇는다 (Ghostty 가 파일 여러 개를 붙일 때와 같다)
    public static func pasteText(_ paths: [String]) -> String {
        paths.map(shellEscape).joined(separator: " ")
    }

    /// 임시·서버 파일 이름: "nexus-<stamp>-<원래 이름>.<확장자>". 원래 이름은 영문·숫자·. _ - 만 남겨(나머지는 -) 서버 셸에서 escape 없이 읽히게.
    /// 영문이 하나도 안 남으면(한글 스크린샷 이름 등) 원래 이름 대신 "image"(이미지 아닌 파일은 "file"). 여러 개면 원래 이름 앞에 순번 (같은 이름 덮어쓰기 방지).
    public static func stagedName(original: String, stamp: String, index: Int, count: Int) -> String {
        let ext = (original as NSString).pathExtension.lowercased()
        let stem = (original as NSString).deletingPathExtension
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var cleaned = ""
        for character in stem {
            if allowed.contains(character) { cleaned.append(character) }
            else if !cleaned.hasSuffix("-") { cleaned.append("-") }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if cleaned.rangeOfCharacter(from: .letters) == nil { cleaned = ext.isEmpty || imageExtensions.contains(ext) ? "image" : "file" }
        let number = count > 1 ? "\(index + 1)-" : ""
        return "nexus-\(stamp)-\(number)\(cleaned)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// 2026-10-19 10:31:59 → "20261019-103159" (이 Mac 시간대)
    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// 올릴 서버 폴더 (scp 대상 — 이미 있는 폴더라 파일이 그 안에 들어간다). Windows 는 홈 기준 상대 경로(SFTP)로 %TEMP%.
    public static func remoteDirectory(type: ServerType) -> String {
        switch type {
        case .linux, .openwrt: return "/tmp"
        case .windows: return "AppData/Local/Temp"
        }
    }

    /// 올린 파일의 서버 경로 (입력할 것). Windows 는 홈(parseHome 의 "/C:/Users/me")을 알면 "C:\Users\me\AppData\Local\Temp\이름",
    /// 모르면 홈 기준 상대 경로 (ssh 는 홈에서 시작한다).
    public static func remotePath(name: String, type: ServerType, home: String?) -> String {
        switch type {
        case .linux, .openwrt:
            return "\(remoteDirectory(type: .linux))/\(name)"
        case .windows:
            var base = remoteDirectory(type: .windows)
            if let home {
                base = (home.hasPrefix("/") ? String(home.dropFirst()) : home) + "/" + base
            }
            return (base + "/" + name).replacingOccurrences(of: "/", with: "\\")
        }
    }

    /// 서버에 입력할 글자. 이름은 stagedName 이라 escape 가 필요 없다 — Windows 경로의 \ 를 escape 하면 안 되므로 그대로 잇되,
    /// 홈에 공백이 있으면(C:\Users\John Smith) 그 경로만 "…" 로 감싼다 (PowerShell·cmd 모두 인자 하나로 읽는다).
    public static func remotePasteText(_ paths: [String]) -> String {
        paths.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}
