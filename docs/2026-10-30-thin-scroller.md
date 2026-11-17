# 앱 전체 스크롤바를 얇게 (2026-10-30)

## 요청

- 스크롤바가 너무 넓다 → 얇게, 색은 옅게, 배경(홈)은 없애기
- 앱 전체에 한 번에 적용

## 결과

- 새 파일 `app/Sources/ServersApp/ThinScroller.swift`
- `app/Sources/ServersApp/AppDelegate.swift` 의 `applicationWillFinishLaunching` 에 `ThinScroller.install()` 한 줄 추가
- 모양: 두께 6pt 둥근 막대, 색 `NSColor.tertiaryLabelColor`(다크에서 흰색 약 25%), 양 끝을 칸 끝에서 3pt 띄움, 배경 없음
- 적용 범위: SwiftUI `ScrollView`·`List`, 직접 만든 `NSScrollView`(예: `RemoteEntryTable`) 전부. 터미널(libghostty)은 스크롤뷰가 없어 해당 없음
- 칸 폭은 시스템 기본 그대로다(배경을 안 그려 눈에 보이지 않음)

## 동작 방식

1. 앱 시작 때 `NSScrollView.tile()` 을 바꿔치기한다(method swizzling).
2. 스크롤뷰가 배치될 때마다 세로·가로 스크롤바가 `ThinScroller` 가 아니면 `ThinScroller` 로 바꿔 끼운다(controlSize·scrollerStyle·knobStyle 복사).
3. `ThinScroller`(NSScroller 서브클래스)
   - `drawKnobSlot` — 아무것도 그리지 않음 → 배경 없음
   - `drawKnob` — `rect(for: .knob)` 가운데에 얇은 둥근 막대, `backingAlignedRect` 로 픽셀 격자에 맞춤
   - `isCompatibleWithOverlayScrollers = true` — 트랙패드만 연결된 경우(overlay 모드)에도 같은 모양

## 거쳐 온 문제와 원인

### 1차: NSScroller 자체 그리기를 바꿔치기 → 효과 없음

- 시도: `NSScroller` 의 `drawKnob`·`drawKnobSlot`·`scrollerWidth` 를 swizzling
- 결과: 폭만 줄고 손잡이·배경은 시스템 모양 그대로, 손잡이가 잘림
- 원인: 기본 `NSScroller` 는 시스템이 직접(레이어로) 그리고 `drawKnob` 을 부르지 않는다. 서브클래스가 그리기를 override 해야 직접 그린다.
- 조치: 서브클래스(`ThinScroller`)를 만들고 스크롤뷰마다 바꿔 끼우는 방식으로 변경

### 2차: 손잡이 끝이 잘려 보임 ("왜 잘렸어?")

- 증상: 막대 양 끝이 둥글지 않고 네모나게, 잘린 듯 보임 (사용자 화면은 1x 외장 모니터)
- 헛짚은 가설 (재현 안 됨): 끝까지 스크롤, 휠로 조금씩 스크롤 중 부분 다시 그리기, 사이드바 아래 고정 줄(`safeAreaBar`)에 가림, 5초 갱신으로 내용 높이 변화
- 진짜 원인: 칸 폭을 15 → 10 으로 줄인 것.
  시스템은 손잡이 영역(`rect(for: .knob)`)을 기본 폭(17) 기준으로 계산하고 그 영역 밖은 잘라내고 그린다.
  폭 10 칸에서 손잡이 영역이 x −4…7 로 밀려, 그 가운데에 그린 막대의 한쪽 열이 잘렸다.
  - 손잡이 영역 가운데에 그리면 → 왼쪽(x<0)이 칸 밖이라 잘림
  - 칸 가운데에 그리면 → 오른쪽(x≥7)이 손잡이 영역 클립에 잘림
- 조치: 칸 폭 줄이기(`scrollerWidth` override)를 제거. 배경이 없으니 칸 폭은 보이지 않는다.
  두께 5 → 6, 끝 여백 2 → 3, 픽셀 격자 맞춤 추가 → 1x 에서도 끝이 둥글게 보임

## 검증

- 1차 이후: 스크래치 시험 앱(SwiftUI `ScrollView` + `NSScrollView`)을 띄워 캡처 — 얇은 손잡이·배경 없음, legacy·overlay 둘 다 확인
- 2차 원인 찾기: 실제 Nexus 창을 `screencapture -l` 로 캡처해 손잡이 끝 픽셀 밝기를 찍음 → 한쪽 열만 늘 잘려 있음을 확인,
  시험 앱에서 `rect(for: .knob)`·`frame` 을 찍어 손잡이 영역이 x −4 로 밀린 것을 확인
- 최종: 창 없이 `cacheDisplay` 로 스크롤바만 비트맵에 그려 픽셀 확인 — 세로·가로 모두 좌우 대칭, 위·아래 끝 둥금
- `make test` 통과(474개, 실패 0), `make install` 완료. 사용자가 재시작 후 확인("이제야 됐네")

## 알려진 한계·주의

- 칸 폭은 시스템 기본이라 항상 보이는(legacy) 모드에서 내용 오른쪽에 그만큼 자리가 남는다(비어 보일 뿐).
- 칸 폭을 다시 줄이려면 `rect(for: .knob)` 기준이 어긋나는 문제를 같이 풀어야 한다 — 단순히 `scrollerWidth` 만 바꾸면 막대가 잘린다.
- `NSScrollView.tile` swizzling 이라 시스템 동작이 바뀌면(새 macOS) 다시 확인이 필요하다.
- 라이트 모드 색은 실제 화면에서 확인하지 않았다(`tertiaryLabelColor` 라 자동으로 어둡게 바뀜).

## 작업 방식에서 고칠 점

- 시험 창을 화면에 여러 번 띄워 방해가 됐다 → 그리기 확인은 창 없이 `cacheDisplay` 비트맵으로 (메모리에 기록함)
- 원인을 좁히기 전에 가설별 재현부터 돌려 시간이 걸렸다 → 그리기가 이상하면 먼저 좌표(`frame`·`rect(for:)`)와 픽셀 값을 찍는다
- 커밋은 아직 하지 않음
