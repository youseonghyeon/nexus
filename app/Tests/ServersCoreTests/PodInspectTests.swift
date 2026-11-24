// PodInspect: k3s 파드 줄을 눌렀을 때의 상태 · 이벤트 · 로그.
// Fixtures/pod-inspect-*.txt 는 이 Mac 의 docker 안 rancher/k3s(v1.34.1) 에 시험 파드를 띄우고 PodInspect.command 를 그대로 돌린 실제 출력이다 (2026-11-24):
//   crash  echo 뒤 exit 3 을 되풀이 (CrashLoopBackOff)        oom   메모리 20Mi 제한에서 계속 할당 (OOMKilled)
//   badimg 없는 레지스트리의 이미지 (ImagePullBackOff)         big   메모리 900Gi 요청 (배치 실패 — Pending)
//   duo    컨테이너 둘 (정상)                                   ok    정상

import Foundation
import XCTest
@testable import ServersCore

final class PodInspectTests: XCTestCase {
    private func report(_ name: String) throws -> PodReport {
        try XCTUnwrap(PodInspect.parse(RemoteCommands.cleanOutput(try fixtureText("pod-inspect-\(name)"), type: .linux)))
    }

    func testCrashLoopShowsLastExitAndPreviousLog() throws {
        let r = try report("crash")
        let c = try XCTUnwrap(r.containers.first)
        XCTAssertEqual(c.name, "crash")
        XCTAssertEqual(c.waitingReason, "CrashLoopBackOff")
        XCTAssertGreaterThan(c.restarts, 0)
        XCTAssertEqual(c.lastReason, "Error"); XCTAssertEqual(c.lastExitCode, 3)
        XCTAssertNotNil(c.lastFinishedAgo, "직전 종료 시각을 서버 시각과 견준다")
        XCTAssertTrue(c.waitingMessage?.hasPrefix("back-off ") == true)
        XCTAssertEqual(r.previousLog.sorted(), ["[pod/crash/crash] boom: cannot open config", "[pod/crash/crash] starting up"], "직전 실행 로그 (stdout · stderr)")
        XCTAssertTrue(PodInspect.hasTrouble(r))
        let lines = PodInspect.displayLines(r)
        XCTAssertEqual(lines.first, "── 상태 ──")
        XCTAssertTrue(lines.contains { $0.hasPrefix("crash: CrashLoopBackOff (재시작 ") && $0.contains(" — back-off ") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("crash 직전 종료: Error (exit 3) · ") && ($0.hasSuffix("전") || $0.hasSuffix("방금")) }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("ContainersNotReady") }, "컨테이너 줄이 이미 말한 조건은 적지 않는다")
        XCTAssertTrue(lines.contains("── 직전 실행 로그 (마지막 30줄) ──") && lines.contains("── 로그 (마지막 50줄) ──"))
        // 이벤트는 마지막으로 일어난 순서 — 되풀이되는 BackOff 가 맨 아래(가장 최근 쪽)에 오고, 같은 Pulled 는 한 줄만
        let backoff = try XCTUnwrap(r.events.firstIndex { $0.reason == "BackOff" })
        XCTAssertTrue(r.events[backoff].warning); XCTAssertGreaterThan(r.events[backoff].count, 1)
        XCTAssertEqual(backoff, r.events.count - 1, "가장 최근 이벤트가 마지막")
        XCTAssertEqual(r.events.map { $0.ago ?? -1 }, r.events.map { $0.ago ?? -1 }.sorted(by: >), "오래된 것부터")
        XCTAssertLessThanOrEqual(r.events.count, PodInspect.eventLimit)
        XCTAssertEqual(r.events.filter { $0.reason == "Pulled" }.count, 1, "되풀이된 일반 이벤트는 마지막 것 하나만 (메시지의 걸린 시간이 매번 달라도)")
        XCTAssertTrue(lines.contains { $0.contains("Warning  BackOff ×") }, "\(lines)")
    }

    func testOOMKilledIsNamed() throws {
        let r = try report("oom")
        XCTAssertEqual(r.containers.first?.lastReason, "OOMKilled")
        XCTAssertEqual(r.containers.first?.lastExitCode, 137)
        XCTAssertTrue(PodInspect.displayLines(r).contains { $0.hasPrefix("hog 직전 종료: OOMKilled (exit 137)") })
    }

    func testImagePullAndUnschedulable() throws {
        let bad = try report("badimg")
        XCTAssertEqual(bad.phase, "Pending")
        XCTAssertEqual(bad.containers.first?.waitingReason, "ImagePullBackOff")
        XCTAssertTrue(bad.containers.first?.waitingMessage?.contains("registry.invalid/team/none:1.0") == true, "어느 이미지인지 메시지에 있다")
        XCTAssertTrue(bad.previousLog.isEmpty, "재시작한 적이 없으면 직전 실행 로그를 묻지 않는다")
        XCTAssertTrue(bad.events.contains { $0.reason == "Failed" && $0.warning })
        XCTAssertNotNil(bad.events.first { $0.reason == "Scheduled" }?.ago, "lastTimestamp 가 null 인 이벤트는 처음 시각으로")

        let big = try report("big")
        XCTAssertTrue(big.containers.isEmpty, "배치되지 않아 컨테이너 상태가 없다")
        XCTAssertEqual(big.conditions.first?.type, "PodScheduled")
        XCTAssertEqual(big.conditions.first?.reason, "Unschedulable")
        let lines = PodInspect.displayLines(big)
        XCTAssertTrue(lines.contains { $0.hasPrefix("PodScheduled: Unschedulable — 0/1 nodes are available: 1 Insufficient memory.") }, "\(lines)")
        XCTAssertEqual(lines.last, "(로그가 없습니다)")
    }

    func testHealthyPodsShowOnlyLog() throws {
        for name in ["ok", "duo"] {
            let r = try report(name)
            XCTAssertFalse(PodInspect.hasTrouble(r), name)
            XCTAssertFalse(r.events.contains(where: \.warning), name)
            let lines = PodInspect.displayLines(r)
            XCTAssertEqual(lines.first, "── 로그 (마지막 50줄) ──", "멀쩡한 파드는 상태 · 이벤트 없이 로그만 (\(name))")
        }
        let duo = try report("duo")
        XCTAssertEqual(duo.containers.map(\.name).sorted(), ["sidecar", "web"])
        XCTAssertTrue(duo.log.contains("[pod/duo/web] web ready"), "컨테이너가 여럿이면 줄 앞에 이름")
    }

    func testCommandAndNames() {
        let command = PodInspect.command(namespace: "app", pod: "calapp-server-f6cdff6d5-mt2v2")
        XCTAssertNotNil(command)
        XCTAssertTrue(command?.contains("get pod -n 'app' 'calapp-server-f6cdff6d5-mt2v2'") == true)
        XCTAssertTrue(command?.contains("logs -n 'app' 'calapp-server-f6cdff6d5-mt2v2' --all-containers --prefix --tail=50") == true)
        XCTAssertTrue(command?.contains("--previous --tail=30") == true)
        XCTAssertTrue(command?.contains(#"K="sudo -n k3s kubectl""#) == true, "그냥 안 되면 암호 없이 되는 sudo 로")
        XCTAssertTrue(command?.contains("timeout 8") == true)
        for verb in ["delete", "exec ", "apply", "edit", "patch", "scale", "rollout"] { XCTAssertFalse(command?.contains(verb) == true, "읽기만 (\(verb))") }
        // 이름은 쿠버네티스가 허용하는 글자만 — 따옴표 · 세미콜론 · 대문자 · 밑줄은 명령을 만들지 않는다
        for bad in ["a;rm -rf x", "a'b", "Pod", "a_b", "", "-a", "a-", "a b", "$(id)"] {
            XCTAssertNil(PodInspect.command(namespace: "app", pod: bad), bad)
            XCTAssertNil(PodInspect.command(namespace: bad, pod: "ok"), bad)
        }
        XCTAssertTrue(PodInspect.isValidName("kube-system") && PodInspect.isValidName("a.b-1"))
    }

    func testParseEdges() {
        XCTAssertNil(PodInspect.parse(["garbage"]), "구역 머리가 없으면 nil")
        let denied = PodInspect.parse(["NOW|2026-11-24T07:49:30Z", "## STATUS", "KUBECTL=denied", "## END"])
        XCTAssertEqual(denied?.denied, true)
        XCTAssertEqual(denied.map(PodInspect.displayLines), ["kubectl 을 실행하지 못했습니다 (권한이 없거나 응답이 없음)"])
        // 메시지 안의 "|" · 로그 줄의 "## " 꼴이 아닌 "|" 는 그대로, 시각이 없으면 경과를 적지 않는다
        let r = PodInspect.parse(["## STATUS", "P|Running|", "PM|", "C|web|2||Error|1|||", "CM|web|", "N|Ready|Custom", "NM|Ready|gate a|b not passed",
                                  "## EVENTS", "E|null|null|Warning|Unhealthy|3|Readiness probe failed: HTTP probe failed with statuscode: 503 | retry",
                                  "## PREVIOUS", "## LOG", "a | b", "", "## END"])
        XCTAssertEqual(r?.conditions.first?.message, "gate a|b not passed")
        XCTAssertEqual(r?.events.first?.message, "Readiness probe failed: HTTP probe failed with statuscode: 503 | retry")
        XCTAssertNil(r?.events.first?.ago)
        XCTAssertEqual(r?.log, ["a | b"], "끝의 빈 줄만 뗀다")
        let lines = r.map(PodInspect.displayLines) ?? []
        XCTAssertTrue(lines.contains("web: 재시작 2") && lines.contains("web 직전 종료: Error (exit 1)"), "\(lines)")
        XCTAssertTrue(lines.contains("Ready: Custom — gate a|b not passed"))
        XCTAssertTrue(lines.contains("Warning  Unhealthy ×3  Readiness probe failed: HTTP probe failed with statuscode: 503 | retry"), "\(lines)")
    }
}
