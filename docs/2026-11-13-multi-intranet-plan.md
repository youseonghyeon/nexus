# 내부망 여러 개 — 구상 (미룸)

2026-11-13 대화에서 정리. **구현하지 않았다.** 두 번째 내부망이 실제로 생기면 그때 시작한다 — 그 망으로 바로 확인할 수 있어 더 안전하다.

## 왜

- 망 종류가 코드에 넷으로 박혀 있다 (`ServerNetwork`: tailscale · lan · vpn · direct).
- `lan` 은 Intranet 으로 지정한 macOS 네트워크 서비스 **하나**만 가리킨다 (`LanStore` · `lan.json`). 내부망이 둘이면 표현할 수 없다.
- `vpn` 만 여러 개가 된다 (서버의 `vpn=이름`).

## 정한 것

- **범위는 내부망 여러 개만.** 이름 붙인 내부망을 추가·제거하고, 서버 등록 때 어느 내부망인지 고른다.
- **Wi-Fi · Ethernet 화면은 그대로.** 망을 추가하지 않아도 이 Mac 의 장치 화면으로 늘 보인다.
- **화면 통합은 하지 않는다.** Wi-Fi · Ethernet · VPN · Tailscale · Intranet 은 보여 주는 값이 달라 각자 따로 둔다 (사용자 결정).
- **Wi-Fi 에 묶는 망 종류는 넣지 않는다.** 필요해지면 그때.
- 내부망마다 켜기/끄기를 따로 둔다 — Intranet 토글은 AI 차단용 물리 스위치라는 규칙은 내부망마다 그대로 (없애거나 상시 켜기 제안 X).

## 그림

- 장치(en0 · 이더넷 어댑터 · utun)와 망(서버에 닿는 경로에 붙인 이름)을 나눈다. 장치는 macOS 가 정하니 자동 나열, 망이 추가·제거 대상.
- 설정: `[network:이름]` 블록 여러 개, 각자 `service=`. 서버는 `network=lan` 대신 그 이름을 가리킨다.
- 옛 설정 옮기기: `[network:lan]` · `lan.json` 의 서비스 하나 → 첫 내부망. `network=lan` 서버는 그 내부망으로.
- 사이드바 NETWORK: 내부망마다 한 줄(상태 · 켜기/끄기) + 추가 [+] · 우클릭 제거. 메뉴바도 같은 줄.
- 내부망 화면 · 진단 카드: 지금의 Intranet 화면을 내부망마다 그대로 쓴다 (어느 내부망인지만 받는다).

## 손대는 곳

`lan` 하나를 전제로 한 곳이 80여 군데 (`grep -rn "\.lan\b" app/Sources`).

| 곳 | 바뀌는 것 |
|---|---|
| `ServerConfig` · `ServerConfigEditor` · `ConfigLocation.template` · servers.conf 머리 주석 | `[network:이름]` 여러 개 읽기·쓰기, 옛 키 옮기기 |
| `LanStore` (`lan.json`) | 서비스 하나 → 내부망별 서비스 |
| `StatusMonitor` (`lanDevice` · `bindInterface`) | 내부망별 장치 · 서버마다 자기 내부망의 장치에 묶기 |
| `ActionAvailability` · `ServerFormCheck` | 서버의 내부망이 켜졌는지로 판정. 상태 표에 내부망 0 · 1 · 2개 |
| 사이드바 `NetworkRow` · 메뉴바 (`MenuBarSwitch`) | 내부망 줄 여러 개, 추가·제거 |
| 서버 추가·편집 창 (`ServerFormSheet`) | 내부망 고르기 |
| Intranet 화면 · `DiagnosticScreen.lan` · `DiagnosticTargets` | 어느 내부망인지 받아 그리기 |

## 순서

1. 망 모델과 설정 읽기 — 화면 변화 없음, 기존 설정 그대로 동작
2. 상태 확인 · 장치 묶기를 내부망 이름 기준으로
3. 사이드바 추가·제거, 서버 등록 창의 내부망 고르기

단계마다 테스트 → 사용자 확인. 추정 2~3시간.

## 위험

- 내부망 연결은 "그 장치에만 묶는다(BindInterface)"가 안전장치다. 묶기가 틀리면 연결이 다른 망으로 새거나, 꺼 둔 내부망에 닿는다.
- AI 는 실제 내부망에 접속해 확인하지 못한다. 켜기 · 끄기 · 접속 · 전송 · 터널은 사용자가 확인한다.
- 읽기를 건너뛰는 조건(내부망이 없으면 안 읽는다)을 넣으면 쓰는 곳을 전부 꼽아 테스트에 적는다 (AGENTS.md — 2026-11-09 첫 vpn 서버 사례).
