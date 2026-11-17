# 내부망(macOS 네트워크 서비스) 명령어셋 (zsh). 앱이 관리자 권한 스크립트(LanCommands.privilegedScript)에서 source 한다.
# Intranet 도 그냥 유선 서비스다 (2026-10-15 단순화): 켜기·끄기는 다른 유선과 같은 networksetup -setnetworkserviceenabled 로 앱이 직접 하고,
# 여기엔 순서 맨 뒤로 보내기만 남았다 — Intranet 으로 지정할 때·서비스를 추가할 때 한 번.
#   _lan_move_last SERVICE     서비스 순서에서 맨 뒤로 (sudo). 내부망 서비스가 켜져도 기본 경로가 Wi-Fi·이더넷 등 위쪽 서비스에 남게 한다
# 비활성 서비스는 목록에서 '*' 접두사가 붙는다.

# 서비스 순서(비활성 포함) 이름만, 순서대로.
_lan_service_names() {
  networksetup -listnetworkserviceorder 2>/dev/null | sed -nE 's/^\((\*|[0-9]+)\) (.+)$/\2/p'
}

# -ordernetworkservices 는 전체 목록을 다시 넘겨야 하므로 나머지 순서는 유지하고 SERVICE 만 뒤로 보낸다. 이미 맨 뒤면 그대로.
# 이름은 글자 그대로 비교한다 (${array:#$name} 의 $name 은 패턴으로 쓰이지 않는다 — 괄호가 든 이름도 된다).
_lan_move_last() {
  local service="$1"
  local -a names rest
  names=( "${(@f)$(_lan_service_names)}" )
  (( ${#names} )) || return 1
  [[ "${names[-1]}" == "$service" ]] && return 0
  rest=( "${(@)names:#$service}" )
  (( ${#rest} == ${#names} )) && return 1   # 목록에 없음
  sudo networksetup -ordernetworkservices "${rest[@]}" "$service"
}
