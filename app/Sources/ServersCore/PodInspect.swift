// k3s 파드 줄을 눌렀을 때: 왜 그 상태인지(컨테이너 상태 · 직전 종료 · 배치 실패 · 최근 이벤트)와 최근 로그를 한 번에 읽는다.
// 죽은 직후 바로 확인하는 용도다 — 이벤트는 쿠버네티스가 한 시간쯤 뒤 지우므로 오래전 일은 서버에서 따로 본다 (2026-11-24 사용자).
// 읽기만 한다: kubectl get pod · get events · logs. 그 계정의 권한으로만 — sudo 는 쓰지 않는다. 안 되면 kubectl 의 오류 글을 그대로 보인다.
// 스크립트는 `sh -s` 의 stdin 으로 보낸다 — 로그인 셸에 그대로 넘기면 zsh 에서는 "$T $K" 가 낱말로 갈리지 않아 명령을 못 찾는다
// (2026-11-24: 그래서 "kubectl 을 실행하지 못했습니다"만 떴다 — 이유도 버리고 있었다. 이제 kubectl 이 낸 오류 글을 그대로 보인다).
// 출력은 "## 구역" 머리 + 줄 (탭은 cleanOutput 이 공백으로 바꾸므로 "|" 로 가른다 — 글(메시지)은 늘 맨 뒤 칸이라 "|" 가 들어 있어도 된다):
//   NOW|<서버 시각 UTC>                         경과("3분 전")는 서버 시각으로 잰다 (이 Mac 과 시계가 달라도)
//   ## STATUS   KUBECTL=failed + ERR|kubectl 이 낸 오류 줄 (못 읽었을 때 — 파드가 없어졌거나 권한이 없거나)
//               P|단계|이유|만든 시각   PM|메시지
//               C|컨테이너|재시작|대기 이유|직전 종료 이유|직전 종료 코드|직전 종료 시각|종료 이유|종료 코드       CM|컨테이너|대기 메시지
//               N|조건|이유            NM|조건|메시지          (False 인 조건만 — PodScheduled 실패 등)
//   ## EVENTS   E|마지막 시각|처음 시각|종류|이유|횟수|메시지      (kubectl 은 처음 생긴 순서로 준다 — 마지막으로 일어난 순서로 다시 세우고 최근 8개만: parse)
//   ## PREVIOUS 직전 실행 로그 30줄 (재시작한 컨테이너가 있을 때만)
//   ## LOG      로그 50줄 (컨테이너가 여럿이면 줄 앞에 [pod/이름/컨테이너])
// 실제 출력: Tests/…/Fixtures/pod-inspect-*.txt (이 Mac 의 docker 안 rancher/k3s v1.34 에 띄운 시험 파드들, 2026-11-24).

import Foundation

public struct PodReport: Sendable, Equatable {
    public struct Container: Sendable, Equatable {
        public let name: String
        public let restarts: Int
        /// 지금 기다리는 이유 (CrashLoopBackOff · ImagePullBackOff · ContainerCreating …) · 그 메시지
        public var waitingReason: String?
        public var waitingMessage: String?
        /// 직전 실행이 끝난 이유 (OOMKilled · Error · Completed) · 종료 코드 · 끝난 지 (초)
        public var lastReason: String?
        public var lastExitCode: Int?
        public var lastFinishedAgo: TimeInterval?
        /// 지금 끝나 있는 이유 · 종료 코드 (다시 뜨지 않는 파드)
        public var terminatedReason: String?
        public var terminatedExitCode: Int?
    }
    public struct Condition: Sendable, Equatable {
        public let type: String
        public let reason: String
        public let message: String
    }
    public struct Event: Sendable, Equatable {
        /// 마지막으로 일어난 지 (초). 시각을 못 읽었으면 nil
        public let ago: TimeInterval?
        public let warning: Bool
        public let reason: String
        public let count: Int
        public let message: String
    }
    public var phase = ""
    /// 파드를 만든 지 (초). 시각을 못 읽었으면 nil
    public var createdAgo: TimeInterval?
    public var reason = ""
    public var message = ""
    public var containers: [Container] = []
    /// 성립하지 않은 조건 (배치 실패 등)
    public var conditions: [Condition] = []
    public var events: [Event] = []
    public var previousLog: [String] = []
    public var log: [String] = []
    /// 파드 상태를 읽지 못했을 때 kubectl 이 낸 오류 줄들 (읽었으면 nil). 파드가 없어졌으면 "… not found", 권한이 없으면 설정 파일 오류 글
    public var failure: [String]?
    /// 그 오류가 "파드가 없다"인가 — 목록을 읽은 뒤 파드가 다시 떠 이름이 바뀐 경우
    public var notFound: Bool { failure?.contains { $0.contains("NotFound") || $0.lowercased().contains("not found") } ?? false }
}

public enum PodInspect {
    /// 네임스페이스 · 파드 이름: 쿠버네티스가 허용하는 글자만 (명령에 그대로 넣으므로) — 소문자 · 숫자 · - · .
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, let last = name.last, name.count <= 253 else { return false }
        func alnum(_ c: Character) -> Bool { c.isASCII && (c.isNumber || (c.isLetter && c.isLowercase)) }
        return alnum(first) && alnum(last) && name.allSatisfy { alnum($0) || $0 == "-" || $0 == "." }
    }

    /// 창에 보일 이벤트 수 (마지막으로 일어난 것부터)
    public static let eventLimit = 8
    public static let logLines = 50
    public static let previousLines = 30

    /// 파드 하나를 읽는 스크립트 (`sh -s` 의 stdin 으로). 이름이 허용 글자를 벗어나면 nil. 멈춘 k3s 가 붙잡지 않게 명령마다 8초.
    public static func script(namespace: String, pod: String) -> String? {
        guard isValidName(namespace), isValidName(pod) else { return nil }
        let target = "-n '\(namespace)' '\(pod)'"
        let status = #"{.status.phase}{"|"}{.status.reason}{"|"}{.metadata.creationTimestamp}{"\n"}PM|{.status.message}{"\n"}"#
            + #"{range .status.initContainerStatuses[*]}C|{.name}|{.restartCount}|{.state.waiting.reason}|{.lastState.terminated.reason}|{.lastState.terminated.exitCode}|{.lastState.terminated.finishedAt}|{.state.terminated.reason}|{.state.terminated.exitCode}{"\n"}CM|{.name}|{.state.waiting.message}{"\n"}{end}"#
            + #"{range .status.containerStatuses[*]}C|{.name}|{.restartCount}|{.state.waiting.reason}|{.lastState.terminated.reason}|{.lastState.terminated.exitCode}|{.lastState.terminated.finishedAt}|{.state.terminated.reason}|{.state.terminated.exitCode}{"\n"}CM|{.name}|{.state.waiting.message}{"\n"}{end}"#
            + #"{range .status.conditions[?(@.status=="False")]}N|{.type}|{.reason}{"\n"}NM|{.type}|{.message}{"\n"}{end}"#
        let events = #"{range .items[*]}E|{.lastTimestamp}|{.metadata.creationTimestamp}|{.type}|{.reason}|{.count}|{.message}{"\n"}{end}"#
        return [
            ###"T=""; command -v timeout >/dev/null 2>&1 && T="timeout 8""###,
            ###"K="k3s kubectl""###,
            ###"echo "NOW|$(date -u +%Y-%m-%dT%H:%M:%SZ)""###,
            ###"echo "## STATUS""###,
            // kubectl 을 그냥 실행하고, 안 되면 kubectl 이 낸 오류 글을 그대로 보인다. sudo 는 쓰지 않는다 (2026-11-24 사용자 — 되는지 보고 안 되면 오류만).
            // 하나만 더 본다: k3s 의 기본 설정 파일을 못 읽는 계정이면(permission denied) 그 계정의 ~/.kube/config 로 한 번 —
            // 터미널에서는 KUBECONFIG 가 걸려 되는데 ssh 로 보낸 스크립트에는 그 환경이 없어서다. 이것도 그 계정의 권한으로 읽는 것이다.
            ###"fail() { echo "KUBECTL=failed"; printf '%s\n' "$1" | tail -n 3 | sed 's/^/ERR|/'; echo "## END"; exit 0; }"###,
            ###"if ! S=$($T $K get pod \###(target) -o jsonpath='P|\###(status)' 2>/dev/null); then"###,
            ###"  E=$($T $K get pod \###(target) 2>&1 >/dev/null)"###,
            ###"  if printf '%s' "$E" | grep -qi "permission denied" && [ -r "$HOME/.kube/config" ]; then"###,
            ###"    export KUBECONFIG="$HOME/.kube/config""###,
            ###"    S=$($T $K get pod \###(target) -o jsonpath='P|\###(status)' 2>/dev/null) || fail "$($T $K get pod \###(target) 2>&1 >/dev/null)""###,
            ###"  else fail "$E"; fi"###,
            ###"fi"###,
            ###"printf '%s\n' "$S""###,
            ###"echo "## EVENTS""###,
            ###"$T $K get events -n '\###(namespace)' --field-selector involvedObject.name='\###(pod)' --sort-by=.metadata.creationTimestamp -o jsonpath='\###(events)' 2>/dev/null | tail -n 60"###,
            ###"echo "## PREVIOUS""###,
            // 재시작한 컨테이너가 있을 때만 (없으면 kubectl 이 "previous terminated container not found" 를 낸다)
            ###"if printf '%s\n' "$S" | awk -F'|' '$1 == "C" && $3 > 0 { found = 1 } END { exit !found }'; then $T $K logs \###(target) --all-containers --prefix --previous --tail=\###(previousLines) 2>&1; fi"###,
            ###"echo "## LOG""###,
            ###"$T $K logs \###(target) --all-containers --prefix --tail=\###(logLines) 2>&1"###,
            ###"echo "## END""###,
        ].joined(separator: "\n") + "\n"
    }

    /// 스크립트 출력 → 보고서. 구역 머리가 없으면 nil
    public static func parse(_ lines: [String]) -> PodReport? {
        guard lines.contains(where: { $0.hasPrefix("## ") }) else { return nil }
        var report = PodReport()
        var now: Date?
        var section = ""
        func ago(_ stamp: String) -> TimeInterval? {
            guard let now, let date = timestamp(stamp) else { return nil }
            return max(0, now.timeIntervalSince(date))
        }
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        for raw in lines {
            if raw.hasPrefix("## ") { section = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
            if section == "PREVIOUS" { report.previousLog.append(raw); continue }
            if section == "LOG" { report.log.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("NOW|") { now = timestamp(String(line.dropFirst(4))); continue }
            if line == "KUBECTL=failed" { report.failure = report.failure ?? []; continue }
            if section == "STATUS", line.hasPrefix("ERR|") { report.failure = (report.failure ?? []) + [String(line.dropFirst(4))]; continue }
            func columns(_ count: Int) -> [String] {
                var parts = line.split(separator: "|", maxSplits: count - 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
                while parts.count < count { parts.append("") }
                return parts
            }
            switch (section, line.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "") {
            case ("STATUS", "P"):
                let p = columns(4); report.phase = p[1]; report.reason = p[2]
                report.createdAgo = timestamp(p[3]).flatMap { created in now.map { max(0, $0.timeIntervalSince(created)) } }
            case ("STATUS", "PM"):
                report.message = columns(2)[1]
            case ("STATUS", "C"):
                let c = columns(9)
                report.containers.append(PodReport.Container(name: c[1], restarts: Int(c[2]) ?? 0, waitingReason: text(c[3]), waitingMessage: nil,
                                                             lastReason: text(c[4]), lastExitCode: Int(c[5]), lastFinishedAgo: ago(c[6]),
                                                             terminatedReason: text(c[7]), terminatedExitCode: Int(c[8])))
            case ("STATUS", "CM"):
                let c = columns(3)
                if let index = report.containers.lastIndex(where: { $0.name == c[1] }) { report.containers[index].waitingMessage = text(c[2]) }
            case ("STATUS", "N"):
                let c = columns(3); report.conditions.append(PodReport.Condition(type: c[1], reason: c[2], message: ""))
            case ("STATUS", "NM"):
                let c = columns(3)
                if let index = report.conditions.lastIndex(where: { $0.type == c[1] }) {
                    report.conditions[index] = PodReport.Condition(type: c[1], reason: report.conditions[index].reason, message: c[2])
                }
            case ("EVENTS", "E"):
                let c = columns(7)
                report.events.append(PodReport.Event(ago: ago(c[1]) ?? ago(c[2]), warning: c[3] == "Warning", reason: c[4], count: Int(c[5]) ?? 1, message: c[6]))
            default: break
            }
        }
        // 이벤트: 마지막으로 일어난 순서로 (같은 시각이면 받은 순서 그대로), 최근 eventLimit 개.
        // 되풀이는 마지막 것만 — 경고는 이유·메시지가 같은 것끼리, 일반(Pulled · Created …)은 이유가 같으면 (메시지에 걸린 시간 같은 숫자가 들어가 매번 다르다)
        var seen: Set<String> = []
        let ordered = report.events.enumerated().sorted { a, b in
            let x = a.element.ago ?? .infinity, y = b.element.ago ?? .infinity
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
        report.events = Array(ordered.reversed().filter { seen.insert($0.warning ? $0.reason + "|" + $0.message : $0.reason).inserted }.prefix(eventLimit).reversed())
        while report.log.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { report.log.removeLast() }
        while report.previousLog.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { report.previousLog.removeLast() }
        return report
    }

    /// "2026-11-24T06:10:00Z"
    static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// 컨테이너가 준비되지 않았다는 조건(Ready · ContainersReady 의 ContainersNotReady)은 컨테이너 줄이 이미 말한다 — 따로 적지 않는다
    static func shownConditions(_ report: PodReport) -> [PodReport.Condition] {
        report.conditions.filter { $0.reason != "ContainersNotReady" && (!$0.reason.isEmpty || !$0.message.isEmpty) }
    }

    /// 눈여겨볼 것이 있는가: 기다리는 컨테이너 · 재시작 · 끝난 컨테이너 · 성립하지 않은 조건(배치 실패 등) — 없으면 "상태" 구역을 보이지 않는다
    public static func hasTrouble(_ report: PodReport) -> Bool {
        !shownConditions(report).isEmpty || !report.reason.isEmpty
            || report.containers.contains { $0.waitingReason != nil || $0.restarts > 0 || ($0.terminatedReason != nil && $0.terminatedReason != "Completed") }
    }

    /// 창에 보일 줄: 상태(문제가 있을 때만) → 최근 이벤트 → 직전 실행 로그 → 로그. 문구는 쿠버네티스가 쓴 영어 그대로 (검색할 수 있게).
    public static func displayLines(_ report: PodReport) -> [String] {
        if let failure = report.failure {
            let reason = failure.filter { !$0.isEmpty }
            if report.notFound { return ["파드를 찾지 못했습니다 — 목록을 읽은 뒤 다시 떠 이름이 바뀌었을 수 있습니다. Services 를 새로 고치세요."] + reason }
            return ["파드 상태를 읽지 못했습니다" + (reason.isEmpty ? " (kubectl 이 응답하지 않음)" : " — kubectl 의 오류:")] + reason
        }
        var out: [String] = []
        func header(_ title: String) { if !out.isEmpty { out.append("") }; out.append("── \(title) ──") }
        func when(_ seconds: TimeInterval?) -> String { seconds.map { " · " + ServicesFormat.ago($0) } ?? "" }
        if hasTrouble(report) {
            header("상태")
            // 목록의 시간은 마지막으로 뜬 뒤부터라, 재시작한 파드는 만든 때를 여기 적는다
            if let created = report.createdAgo, report.containers.contains(where: { $0.restarts > 0 }) { out.append("만든 지 \(ServicesFormat.duration(created))") }
            if !report.reason.isEmpty { out.append("파드: \(report.reason)" + (report.message.isEmpty ? "" : " — \(report.message)")) }
            for c in report.containers {
                if let reason = c.waitingReason {
                    out.append("\(c.name): \(reason)" + (c.restarts > 0 ? " (재시작 \(c.restarts))" : "") + (c.waitingMessage.map { " — \($0)" } ?? ""))
                } else if c.restarts > 0 {
                    out.append("\(c.name): 재시작 \(c.restarts)")
                }
                if let reason = c.lastReason {
                    out.append("\(c.name) 직전 종료: \(reason)" + (c.lastExitCode.map { " (exit \($0))" } ?? "") + when(c.lastFinishedAgo))
                }
                if let reason = c.terminatedReason, reason != "Completed" {
                    out.append("\(c.name) 종료: \(reason)" + (c.terminatedExitCode.map { " (exit \($0))" } ?? ""))
                }
            }
            for condition in shownConditions(report) {
                out.append("\(condition.type): " + [condition.reason, condition.message].filter { !$0.isEmpty }.joined(separator: " — "))
            }
        }
        // 멀쩡한 파드의 이벤트(Scheduled · Pulled · Started)는 보이지 않는다 — 문제가 있거나 경고가 있을 때만
        if !report.events.isEmpty, hasTrouble(report) || report.events.contains(where: \.warning) {
            header("최근 이벤트")
            for event in report.events {
                out.append([event.ago.map { ServicesFormat.ago($0) }, event.warning ? "Warning" : nil,
                            event.reason + (event.count > 1 ? " ×\(event.count)" : ""), event.message].compactMap { $0 }.joined(separator: "  "))
            }
        }
        if !report.previousLog.isEmpty {
            header("직전 실행 로그 (마지막 \(previousLines)줄)")
            out += report.previousLog
        }
        header("로그 (마지막 \(logLines)줄)")
        out += report.log.isEmpty ? ["(로그가 없습니다)"] : report.log
        return out
    }
}
