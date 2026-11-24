// 터미널에 포커스가 있을 때 앱의 단축키가 닿는가 — `make check-shortcuts` 가 빌드해 돌린다.
//
// Ghostty 터미널 뷰는 자기 기본 키와 겹치는 ⌘ 키를 메뉴보다 먼저 가져간다 (AppTerminalView.performKeyEquivalent → keyIsBinding).
// 가져간 키의 동작(새 탭 · 설정 열기 · 종료 …)은 터미널 래퍼가 앱에 넘기지 않아, 그 키는 "눌러도 아무 일도 없는" 키가 된다.
// 한글 입력기에서는 글자가 달라 터미널이 못 알아보고 메뉴로 넘어가므로, 같은 키가 입력기에 따라 되기도 안 되기도 한다 (2026-11-24 ⌘T 로 확인).
//
// 이 프로그램은 앱에 들어 있는 libghostty 의 기본 설정에 "이 키가 네 단축키인가"를 직접 묻는다 (화면도 서버도 쓰지 않는다).
// 설정은 앱이 터미널에 주는 것과 같게 읽는다: scripts/terminal-keybinds.conf (앱의 TerminalKeys.unbound 와 같은 내용 — 테스트가 본다).
//   메뉴로 간다     터미널이 가져가지 않는다 (기본 키가 아니거나, 위 설정으로 풀었다)
//   앱이 먼저 받음  키 감시(TerminalShortcuts)가 창에 가기 전에 받는 키 — 터미널이 가져가려 해도 상관없다
//   알려진 미처리   터미널이 가져가서 앱 동작이 안 되는 것을 알고 있는 키 (KNOWN — 지금은 없다. 2026-11-24 여섯을 풀었다)
//   새 충돌         위 둘이 아닌데 터미널이 가져가는 키 → 종료 코드 1
// 단축키를 새로 넣거나 터미널 라이브러리를 올리면 이 표에 줄을 보태고 다시 돌린다.
#include <stdio.h>
#include <string.h>
#include "ghostty.h"

enum { FREE, HANDLED, KNOWN };
typedef struct { const char* keys; const char* what; unsigned keycode; int mods; const char* text; unsigned cp; int expect; } Row;

int main(int argc, char** argv) {
  ghostty_init(0, NULL);
  ghostty_info_s info = ghostty_info();
  ghostty_config_t config = ghostty_config_new();
  if (argc > 1) ghostty_config_load_file(config, argv[1]);   // 앱이 푸는 키 (인자 없이 돌리면 Ghostty 기본값 그대로)
  ghostty_config_finalize(config);
  for (uint32_t i = 0; i < ghostty_config_diagnostics_count(config); i++) printf("설정 경고: %s\n", ghostty_config_get_diagnostic(config, i).message);
  const int C = GHOSTTY_MODS_SUPER, S = GHOSTTY_MODS_SHIFT, O = GHOSTTY_MODS_ALT, T = GHOSTTY_MODS_CTRL;
  // keycode 는 mac 키 코드 (kVK_ANSI_*), text 는 그 키가 찍는 글자 (영문 배열 기준)
  const Row rows[] = {
    // 메뉴 단축키 (ServersApp.swift · SidebarView.swift · PacketCaptureView.swift)
    {"cmd+T", "새 SSH 탭 / 새 로컬 셸", 17, C, "t", 't', FREE},
    {"cmd+shift+T", "새 로컬 셸", 17, C | S, "T", 't', FREE},
    {"cmd+K", "서버 · 터널 검색", 40, C, "k", 'k', FREE},
    {"cmd+,", "설정", 43, C, ",", ',', FREE},
    {"cmd+Q", "종료", 12, C, "q", 'q', FREE},
    {"cmd+ctrl+F", "전체 화면 (시스템 메뉴)", 3, C | T, "f", 'f', FREE},
    {"cmd+R", "지금 확인", 15, C, "r", 'r', FREE},
    {"cmd+shift+R", "servers.conf 다시 읽기", 15, C | S, "R", 'r', FREE},
    {"cmd+opt+P", "패킷 캡처", 35, C | O, "p", 'p', FREE},
    {"cmd+H", "가리기", 4, C, "h", 'h', FREE},
    {"cmd+M", "최소화", 46, C, "m", 'm', FREE},
    {"cmd+`", "창 돌아가기", 50, C, "`", '`', FREE},
    // 키 감시가 먼저 받는 키 (TerminalShortcuts.swift)
    {"cmd+W", "탭 닫기", 13, C, "w", 'w', HANDLED},
    {"cmd+P", "명령 모음", 35, C, "p", 'p', HANDLED},
    {"cmd+F", "터미널에서 찾기", 3, C, "f", 'f', HANDLED},
    {"cmd+G", "다음 찾기", 5, C, "g", 'g', HANDLED},
    {"cmd+shift+G", "이전 찾기", 5, C | S, "G", 'g', HANDLED},
    {"cmd+C", "복사", 8, C, "c", 'c', HANDLED},
    {"cmd+V", "붙여 넣기", 9, C, "v", 'v', HANDLED},
    {"cmd+shift+[", "이전 탭", 33, C | S, "{", '[', HANDLED},
    {"cmd+shift+]", "다음 탭", 30, C | S, "}", ']', HANDLED},
    {"cmd+shift+Return", "전체 화면", 36, C | S, "\r", '\r', HANDLED},
    {"cmd+1", "1번 서버", 18, C, "1", '1', HANDLED}, {"cmd+2", "2번 서버", 19, C, "2", '2', HANDLED}, {"cmd+3", "3번 서버", 20, C, "3", '3', HANDLED},
    {"cmd+4", "4번 서버", 21, C, "4", '4', HANDLED}, {"cmd+5", "5번 서버", 23, C, "5", '5', HANDLED}, {"cmd+6", "6번 서버", 22, C, "6", '6', HANDLED},
    {"cmd+7", "7번 서버", 26, C, "7", '7', HANDLED}, {"cmd+8", "8번 서버", 28, C, "8", '8', HANDLED}, {"cmd+9", "9번 서버", 25, C, "9", '9', HANDLED},
  };
  printf("libghostty %.*s%s 와 앱 단축키\n\n", (int)info.version_len, info.version, argc > 1 ? " + 앱이 푸는 키" : " 기본값");
  int collisions = 0, stale = 0, known = 0;
  for (unsigned i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
    ghostty_input_key_s key = {0};
    key.action = GHOSTTY_ACTION_PRESS; key.mods = rows[i].mods; key.keycode = rows[i].keycode; key.text = rows[i].text; key.unshifted_codepoint = rows[i].cp;
    const int taken = ghostty_config_key_is_binding(config, key);
    const char* verdict;
    if (rows[i].expect == HANDLED) verdict = taken ? "앱이 먼저 받음 (터미널도 쓰는 키)" : "앱이 먼저 받음";
    else if (rows[i].expect == KNOWN && taken) { verdict = "알려진 미처리 — 터미널이 가져가 앱 동작이 안 된다"; known++; }
    else if (rows[i].expect == KNOWN) { verdict = "표가 낡았다 — 이제 터미널이 가져가지 않는다 (KNOWN 에서 FREE 로)"; stale++; }
    else if (taken) { verdict = "새 충돌 — 터미널이 가져간다"; collisions++; }
    else verdict = "메뉴로 간다";
    printf("  %-18s %-26s %s\n", rows[i].keys, rows[i].what, verdict);
  }
  printf("\n알려진 미처리 %d · 새 충돌 %d · 낡은 줄 %d\n", known, collisions, stale);
  if (collisions || stale) {
    printf("\n문제: 터미널에 포커스가 있을 때 닿지 않는 앱 단축키가 새로 생겼거나 표가 실제와 다릅니다\n"
           "해결: 그 키를 TerminalShortcuts 가 먼저 받게 하거나(HANDLED), 터미널 설정에서 그 키를 풀고(keybind = …=unbind, Sessions.swift) 표를 고치세요\n"
           "참조: app/scripts/terminal-keys.c · app/Sources/ServersApp/TerminalShortcuts.swift · AGENTS.md \"터미널과 단축키\"\n");
    return 1;
  }
  return 0;
}
