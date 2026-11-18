# AGENTS.md — Nexus

이 저장소 작업 규칙의 권위 소스. 사용자용 소개는 `README.md`, 화면·동작별 세부 규칙은 `docs/REFERENCE.md`, 릴리스 절차는 `RELEASING.md`, 설정 형식은 `servers.conf` 머리 주석(새 목록용 사본 `ConfigLocation.template` — 함께 고친다).

## 구조

- `app/` Nexus.app (SwiftPM). `Sources/ServersCore` 는 UI 없는 로직(테스트 대상), `Sources/ServersApp` 는 SwiftUI.
- 서버 목록은 앱 저장소의 `servers.conf` (`ConfigLocation` — 없으면 첫 실행 때 옛 위치 `~/.config/servers/servers.conf` 를 복사하거나 `ConfigLocation.template` 으로 만든다). 
  `lib/*.zsh` 는 번들 `Contents/Resources/lib` 에 들어가 앱이 런타임에 `source` 한다 — 앱 번들만 받아도 동작해야 한다.
- 공개 저장소다 (2026-11-17, Homebrew cask + 앱 안 업데이트 Sparkle — 화면은 사이드바 띠 `UpdateBanner`, 상태는 ServersCore `AppUpdate`).
  실제 환경의 값(공인 IP · 회사·장비 고유 이름 · 실제 MAC · 계정 · tailnet 이름)을 코드·주석·테스트·픽스처에 넣지 않는다 — 문서용 대역(192.0.2.0/24 · 198.51.100.0/24 · 203.0.113.0/24)과 가상의 이름으로.
  새 목록(`ConfigLocation.template`)에는 서버를 넣지 않는다. 저장소의 `servers.conf` 는 형식을 보여 주는 예시다(앱은 읽지 않는다).
- 앱 상태는 `~/Library/Application Support/Servers/` (servers.conf · passwords.bin · identities.json · recent.json · hosts.json · lan.json · snippets.json · bookmarks.json · notes.bin).

## 검증 — 실제 서버에 접속하지 않는다

- 검증은 `cd app && make test` (ServersCore 단위 테스트, `Tests/ServersCoreTests/Support/FakeRunner.swift` 가 ssh·tailscale·networksetup 을 흉내 냄)와 `zsh -n lib/lan.zsh` 로만.
  서버에서 돌 리눅스 스크립트(`LinuxLive`)는 로컬 `docker run --rm -i ubuntu:24.04 sh -s < 스크립트` 로 실제 출력을 확인한다 (이 Mac 안 컨테이너 — 서버 아님).
  그 출력은 `Tests/ServersCoreTests/Fixtures/` 에 두고 테스트가 읽는다.
- 사용자의 서버 목록에 있는 실제 장비(집·회사 서버)로 ssh·scp·nc·TCP 확인이 나가는 명령을 실행하지 않는다. 실제 동작 확인은 사용자가 한다.
- 앱을 `--conf <픽스처>` 로 띄우지 않고, 검증용 인스턴스를 따로 띄우지 않는다 — 2026-09-16 픽스처 실행이 passwords.bin 을 지웠다(복구 불가).
  예외는 데모 모드 하나 (`--demo`, 2026-11-17 사용자 승인 — README 스크린샷용, ServersCore `DemoMode`): 상태 폴더는 임시 폴더, 금고 키는 메모리, 명령은 프로세스를 띄우지 않는 `DemoRunner`, 값은 모두 가상.
  찍는 법: `make release` → `open -g -n build/Nexus.app --args --demo --sample-hidden --select <서버 키|lan|system…> -ApplePersistenceIgnoreState YES`(실제 앱의 창을 닫아 둔 상태면 이 옵션 없이는 데모 창이 안 뜬다) → 창 크기 1360×940 → `screencapture -x -o -l <창 번호>` → `docs/images/`. 끝나면 데모만 끈다.
  데모에서 SSH 탭·터널·전송·패킷 캡처를 열지 않는다(러너를 거치지 않고 프로세스를 직접 띄운다). UserDefaults 는 실제 앱과 같이 쓰므로 설정을 바꾸지 않는다. 데모가 남긴 창 크기 기억값은 그대로 둔다 — `defaults write` 로 되돌리지 않는다 (2026-11-17 되돌리는 스크립트가 문자열 값을 배열로 써서, 떠 있던 실제 앱이 창 위치를 저장하다 죽었다).
  새 화면이 실제 값(SSID·기기 이름·공인 IP)을 러너 밖에서 읽으면 데모 분기를 함께 넣는다 (`WiFiMonitor.refresh`).
- Intranet(내부망) 켜기·끄기 토글(사이드바 NETWORK·메뉴바)은 AI 가 내부망에 닿지 못하게 하는 물리 차단기다. 켜지 말고, 없애거나 상시 켜 두자고 제안하지 않는다.
- 커밋 전 게이트는 종료 코드로 본다: `make test` 를 `| grep`·`| tail` 에 넣지 않는다 (파이프 종료 코드는 tail 의 0 — 깨진 커밋이 두 번 나갔다).
- 리뷰(서브에이전트)가 도는 동안 그 코드를 고치지 않는다. 결과 반영 → 테스트 → 다음 단계.
- 앱 안 업데이트 시험은 낮은 버전 빌드를 `/Applications/Nexus.app` 에 같은 이름·같은 자리로 넣어서 한다 — Sparkle 은 앱이 놓인 자리에서 그대로 바꿔치기하므로 brew 로 깐 사용자와 같은 조건이 된다 (2026-11-17).
  순서: `Info.plist` 두 버전 키를 잠깐 낮춤 → `make release` → 버전 되돌림 → 떠 있는 앱 종료(세션 없을 때만) → `build/Nexus.app` 을 `/Applications/Nexus.app` 으로 교체 → 실행. `~/Applications` 나 다른 이름으로 두고 시험하지 않는다.

## 빌드·디자인

- API 기준은 macOS 27. 배포 타깃도 27 (`Package.swift`·`Info.plist`). 과거 버전용 `#available` 폴백을 만들지 않는다.
- 화면 톤 (2026-09-29 시안에서 고른 포인트): 색은 상태 점·운영/스테이징 태그·경고에만 — 주 버튼·탭 선택은 무채색(`PrimaryButtonStyle`·`PlainSegmented`).
  예외 (2026-10-02): 사용량 막대·그래프(시스템·디스크·블루투스 화면)는 정상 초록 · 경고 노랑 · 위험 빨강 — 회색은 탁해 보였다. 숫자 글자는 그대로(경고 이상만 색).
  면은 네 단계(사이드바 < 본문 < 카드 < 조작부)에 머리카락 선(`Palette.hairline`)을 더한다 — 카드는 `cardSurface()`(모서리 14, `Metrics`).
  섹션 머리·카드 제목은 작고 굵은 회색 글씨(`Font.cardTitle`, 대문자 X), 화면 제목은 `Font.screenTitle`. 알림은 오른쪽 아래 토스트(`StatusToast`) —
  경고는 실패·불가 문구(`StatusNotice`)로 가르므로 새 오류 메시지는 "실패/없습니다/못 …" 표현을 쓴다.
  바탕은 시스템 재질 대신 `Palette`(다크: 사이드바 #0F1012 < 본문 #141517 < 카드 #1B1C1F < 조작부 #27282C — 아주 약하게 차가운 회색).
  상태 색은 시스템 원색이 아니라 `StatusTone` 의 것(초록 #3FD68A · 노랑 #F2BE4A · 빨강 #FF6B60, 라이트는 진하게) — `.green`·`.orange` 를 직접 쓰지 않는다.
  상태 표시는 `StatusDot`(고리 달린 점)·`StatusPill`(결론 알약), 버튼은 `PrimaryButtonStyle`·`SecondaryButtonStyle`·`CompactButtonStyle`(카드 안 작은 버튼) — 시스템 `.bordered` 를 쓰지 않는다.
  모든 상세 화면은 대표 카드(`HeroCard`)로 시작한다: 위는 제목·결론, 아래 띠는 가장 먼저 볼 것 — 서버는 접속 버튼 줄(`ServerHero`·`ConnectActions`),
  망·이 Mac 화면은 수치 칸(띠 안의 `MetricTile` 은 카드 면 없이 선으로 가른 칸). 전원·파일은 아래 카드. 나란한 카드 쌍은 높이를 맞춘다(`fillingHeight()`).
  치수는 `Metrics` 에서: 모서리 다섯 단계(카드 14 · 카드 안의 면 10 · 조작부 8 · 작은 조작부 6 · 배지 4, 감싸는 면은 안쪽 반경 + 여백), 카드 사이 12(카드 안 여백 16 보다 한 단계 좁게), 라벨–값 열 간격 14 — 숫자를 화면에 다시 적지 않는다. 여백은 정수(반 포인트는 1x 화면에서 위아래가 갈린다).
  격자의 라벨은 값보다 한 단계 작게(`Font.fieldLabel`). 고른 것(탭 칸·활성 탭·사이드바 행)은 "올라온 면 + 가는 선"(`Palette.raised`·`sidebarSelection` — 시스템 선택 강조는 끈다), 입력칸은 `fieldSurface()`.
  앱 강조색(`AppleAccentColor`)은 바꾸지 않는다 — Graphite 로 하면 창의 신호등 버튼까지 회색이 된다. 토글·고르개는 화면 뿌리의 `tint`(`Palette.neutralTint`)로 무채색. 계속 도는 애니메이션은 넣지 않는다(경로 그림의 흐르는 막대가 CPU 27% 를 썼다) — 바뀔 때 한 번 움직이는 것만(탭 칸 미끄러짐). 주기적으로 바뀌는 숫자에는 넘김 효과(`numericText`)도 넣지 않는다 — 타일 숫자 넘김이 System 화면 CPU 20% 중 15%p 였다(2026-11-12 측정).
  자주 갱신되며 위에 행이 끼어드는 `Table` 은 행을 내용 번호가 아니라 자리(0 = 맨 위)로 구분한다(`CaptureSlots` — 패킷 목록). 번호로 구분하면 갱신마다 보이는 행 전체를 치우고 다시 만든다 — 스크래치 표(5천 행, 0.5초 갱신, 초당 60행) CPU 25% → 13%, 갱신 애니메이션 끄기·행 수 줄이기는 효과 없음(2026-11-16 측정).
  창 최소 폭(900)에서 확인한다: 타일은 줄마다 고르게 나뉘고(`TileColumns`), 탭이 안 들어가면 아랫줄로 내려 가로로 민다. 내용을 `fixedSize()` 로 카드보다 넓히면 창 전체가 옆으로 밀린다.
  진단 카드는 도구(ping·HTTP·TCP·DNS·ARP)를 제목 줄 탭으로 고르고 고른 도구의 입력칸 한 줄만 보인다(다섯 줄을 늘 펼치면 화면 높이를 먹었다). 표 머리 줄 아래엔 가는 선.
  사이드바 행 머리는 무채색 아이콘 + 모서리 상태 점(`StatusIcon`, SF Symbols — 서버는 `ServerIcon` 이 type 에서 정한다, 2026-11-15 시안). 터널·전송 행은 점만, 자리 폭은 같게(`Metrics.sidebarIcon`).
  상태 점에 번지는 고리를 두지 않는다(뿌옇게 보였다), 타일 값은 글자 수에 따라 크기를 줄인다(`Font.metricValue(_:)`) — 2026-11-10 사용자 지적 (`design-overhaul` 브랜치).
  윗줄은 툴바다(2026-10-12, `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`): 사이드바 칸에 토글·지금 확인, 본문 칸에 탭 막대 —
  사이드바를 접으면 토글·지금 확인이 탭 앞으로. 항목은 유리 캡슐 없이(`sharedBackgroundVisibility(.hidden)`), 창 모드는 띠 없이(`toolbarBackgroundVisibility(.hidden)`).
  툴바를 빼지 않는다 — 전체 화면에서 내려오는 신호등 줄은 툴바 영역만 클릭을 받아, 툴바가 없으면 신호등 클릭이 본창으로 빠졌다(빨강 → 사이드바 토글).
  전체 화면 툴바는 macOS 가 별도 창에 회색으로 그리고 수식어가 닿지 않는다 — 받아들이기로 했다. 확인은 창 활성·비활성·전체 화면 셋 다.
  툴바 항목은 내용 크기만큼만 커진다 — 탭 막대 폭은 본문 폭을 재서 준다(`DetailView`). 넘치면 툴바가 항목을 » 메뉴로 접으니 여백을 넉넉히.
- swiftbuild 는 바이너리의 SDK 버전을 배포 타깃으로 찍는다 → 타깃을 낮추면 macOS 가 옛 디자인(불투명 제목줄)으로 그린다.
  확인: `vtool -show-build build/Nexus.app/Contents/MacOS/Nexus`.
- `make install` 은 `/Applications/Nexus.app` 에 넣는다 (brew 로 깐 자리 — 사용자가 띄우는 앱. 2026-11-18: `~/Applications` 에 넣고 "설치했다"고 해, 재시작해도 옛 빌드가 떴다). 보고 전에 떠 있는 앱의 경로가 설치한 자리인지 본다(`ps -axo comm | grep Nexus.app`).
- `make install` 뒤 반영은 사용자가 앱을 재시작해야 한다. 재시작하면 터미널 세션·터널이 끊기므로 대신 끄지 않는다.

## 코드 규칙

- 판정·파싱처럼 UI 없는 로직은 ServersCore 에 두고 테스트를 붙인다 (예: `PowerWatch`, `TransferNotice`). 앱 쪽은 연결만.
- AI 가 직접 조작해 볼 수 없는 동작(끌기·마우스 상호작용)은 동작 전체(위치·끝 제한·판정)를 ServersCore 순수 로직으로 옮기고,
  코딩 전에 엣지케이스(폭 다른 탭·양 끝·되돌아가기·경계 떨림)를 꼽아 **과정을 순서대로 흉내 내는 테스트**를 먼저 짠다 (예: `TabDrag`).
  테스트는 일부러 옛 버그로 되돌려 실패하는지까지 본다. 화면은 스크래치 시험 앱에 같은 로직을 넣어 값을 흘려 캡처로 확인.
  사용자 손 확인은 마지막 한 번 — 2026-10-06 탭 끌기에서 확인 없이 내보내 떨림·튐·넓은 탭 못 넘음이 차례로 나왔다.
- 망·접속 상태가 얽힌 버튼 가능 여부(`.disabled`)는 화면·AppModel 에 조건을 적지 않고 ServersCore `ActionAvailability` 에 두고 상태 표로 테스트한다(`ActionAvailabilityTests`).
  표에는 빈 상태(그 종류의 첫 항목을 추가할 때)를 꼭 넣는다. 화면이 `status.bindInterface`·`lacksVPNBind`·`blocksSSH` 를 직접 쓰면 테스트가 막는다.
- 읽기를 건너뛰는 조건("…가 없으면 안 읽는다")을 넣을 때는 그 값을 쓰는 곳을 전부 꼽아, 건너뛴 상태에서 각각 어떻게 되는지 테스트에 적는다 (`testConsumersWhenVPNReadIsSkipped`).
  2026-11-09: vpn 서버가 없으면 VPN 을 안 읽는 최적화는 테스트가 있었지만 쓰는 쪽(서버 추가 창)은 없어, 첫 vpn 서버를 추가할 때 Ping 이 늘 꺼져 있었다.
- `AppModel` 의 저장 속성은 `AppModel.swift` 에만. 뷰는 읽기만 하고 쓰기는 AppModel 메서드로.
- 오류·진단 메시지는 [문제 / 해결 / 참조] (`ConfigError`).
- `servers.conf` 는 `ServerConfigEditor` 로 해당 `[키]` 블록만 고친다. 새 키를 넣으면 파일 머리 주석·`ConfigLocation.template`·README 에도 적는다.
- 주석은 한국어, 주변 코드의 밀도에 맞춘다. 화면 문구는 한국어를 고집하지 않는다 (2026-10-14 사용자 지적 — "지터·이름 풀이" 같은 번역어가 투박했다):
  업계 용어·약어는 영어 그대로(Jitter·DNS·TCP·TLS·TTFB·Download·Total), 사이드바 행 이름도 영어(Tailscale VPN·Intranet·Wi-Fi·Ethernet·System·Disk·Bluetooth). 문장형 안내·오류는 한국어.

## 사용자가 정한 것 — 다시 제안하지 않는다

- 못 하는 동작은 비활성만 한다. "<서버> 에 닿지 않음" 같은 이유 문구를 쓰지 않는다 (새 문구는 `grep -rn "닿지" app/Sources` 로 확인).
- 메뉴바 아이콘을 누르면 뜨는 것은 "이 Mac 의 상태·로컬 동작만". Wake·Shutdown·SSH·전송·상세 수치를 넣지 않는다.
  2026-11-14 부터 NSMenu 대신 패널(`MenuBarController` + `MenuBarPanelView`, 본창과 같은 면·상태 점): Network 스위치·VPN · Servers(누르면 본창의 그 서버) · Tunnels.
  Bluetooth 는 제어 센터와 겹쳐 뺐다. 아이콘은 Intranet 이 켜져 있으면 채운 모양. 패널 모양은 값만 받는 `MenuBarPanelView` 를 스크래치에서 비트맵으로 뽑아 확인한다.
- 모니터 깨우기(옛 `monitor` 명령, nexus 경유 WOL)는 따로 작동시키므로 앱에 넣지 않는다.
- 알림은 서버 켜짐·꺼짐(`notify=on`)과 전송 완료·실패만. 터널 끊김·Tailscale 인증 만료 알림, 로그인 자동 실행, Dock 아이콘 숨기기, 남은 빌드 경고 정리는 하지 않기로 했다 (2026-09-29).
- nexus 전송 약 2.3MB/s 는 Tailscale SSH(tailscaled CPU) 상한이고 사용자가 받아들였다. sshd 켜기·LAN 직결 같은 우회를 먼저 꺼내지 않는다.
- 서버 이름 터널이 Safari 에서만 안 열리는 건 Safari 이름 풀이 문제로 좁혀졌다. 터널·hosts 를 다시 파지 말고 크롬이나 IP 직접(127.0.0.x:포트)을 안내한다.
