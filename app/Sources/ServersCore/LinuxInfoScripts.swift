// 리눅스 원격 정보 스크립트 (Network · Schedule). 컨테이너에서 픽스처를 뜬 셸 파일에서 생성했다 —
// 고치면 같은 스크립트로 Tests/ServersCoreTests/Fixtures/linux-*.txt 를 다시 뜬다 (docker run --rm -i ubuntu:24.04 sh -s < 스크립트). sudo 는 쓰지 않는다 (2026-11-07).
// 파일 내용은 cat 대신 `awk 1` 로 낸다 — 마지막 줄에 줄바꿈이 없는 파일(손으로 고친 resolv.conf 등)이면 다음 "@구역" 머리가 그 줄 끝에 붙어
// 구역이 사라지고, @END 가 붙으면 탭 전체가 원문으로 떨어졌다. awk 1 은 줄바꿈이 있는 파일은 그대로, 없으면 채워 낸다 (출력이 같아 픽스처는 그대로).

import Foundation

public enum LinuxInfoScripts {
    /// @ADDR(ip -j -s addr) · @RULES · @ROUTES · @DNS·@DOMAIN(resolvectl — 링크마다 한 줄) · @RESOLV (LinuxNetwork.parse)
    public static let network =     """
    echo @ADDR; ip -j -s addr show 2>/dev/null
    echo @RULES; ip rule show 2>/dev/null
    echo @ROUTES; ip -4 route show table all 2>/dev/null | grep -vE '^(local|broadcast|multicast) ' | head -n 200
    echo @DNS; command -v resolvectl >/dev/null 2>&1 && resolvectl dns 2>/dev/null
    echo @DOMAIN; command -v resolvectl >/dev/null 2>&1 && resolvectl domain 2>/dev/null
    echo @RESOLV; awk 1 /etc/resolv.conf 2>/dev/null
    echo @END
    """

    /// @NOW · @TIMERS(json, 못 읽으면 @NOTIMERS) · @CRONTAB(내 것) · @ETC · @CROND · @PERIODIC (ScheduleReport.parse)
    public static let schedule =     """
    echo @NOW; date +%s
    echo @TIMERS
    if command -v systemctl >/dev/null 2>&1 && systemctl list-timers --all --output=json 2>/dev/null; then :; else echo @NOTIMERS; fi
    echo @CRONTAB; crontab -l 2>/dev/null | awk 1
    echo @ETC; awk 1 /etc/crontab 2>/dev/null
    echo @CROND; for f in /etc/cron.d/*; do [ -f "$f" ] || continue; echo "== $f"; awk 1 "$f" 2>/dev/null; done
    echo @PERIODIC; for d in hourly daily weekly monthly; do echo "== $d"; ls -1 "/etc/cron.$d" 2>/dev/null; done
    echo @END
    """
}
