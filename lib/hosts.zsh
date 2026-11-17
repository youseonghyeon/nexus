# 터널 주소용 /etc/hosts 와 루프백 별칭 (zsh). 앱이 넣는 줄에는 '# servers-app' 표식을 붙여 그 줄만 다룬다. root 필요 (sudo 접두사).
#   _hosts_alias IP        lo0 에 127.0.0.x 별칭 추가 (이미 있으면 그대로). 재부팅하면 사라진다
#   _hosts_set NAME IP     hosts 에 "IP NAME # servers-app" 한 줄 (같은 NAME 의 표식 줄은 교체). 다른 줄은 손대지 않는다. 인자가 비면 실패
#   _hosts_remove NAME IP  "IP NAME # servers-app" 과 정확히 같은 줄만 제거 (이름이 같아도 IP 가 다르면 남긴다)
#   _hosts_unalias IP      lo0 별칭 제거 (없으면 그대로)
# HOSTS_FILE 로 대상 파일을 바꿀 수 있다 (테스트용).

: "${HOSTS_FILE:=/etc/hosts}"

_hosts_alias() {
  local ip="$1"
  ifconfig lo0 2>/dev/null | awk -v ip="$ip" '$1 == "inet" && $2 == ip { found = 1 } END { exit !found }' && return 0
  sudo ifconfig lo0 alias "$ip" 255.255.255.255
}

# 파일을 통째로 다시 쓰되 앱 표식 줄만 바꾼다. 소유자·권한은 cp 가 기존 파일 것을 유지한다.
_hosts_write() {
  local tmp
  tmp="$(mktemp)" || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo cp "$tmp" "$HOSTS_FILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  sudo dscacheutil -flushcache 2>/dev/null
  sudo killall -HUP mDNSResponder 2>/dev/null
  return 0
}

# 바뀐 내용을 임시 파일에 다 만든 뒤에 쓴다 — awk 가 실패했는데(파일을 못 읽음) 파이프가 이어져 hosts 가 빈 내용·새 줄 하나로 덮이지 않게.
_hosts_set() {
  local name="$1" ip="$2" next rc
  [[ -n "$name" && -n "$ip" ]] || return 1
  next="$(mktemp)" || return 1
  awk -v n="$name" '!($2 == n && $3 == "#" && $4 == "servers-app")' "$HOSTS_FILE" > "$next" || { rm -f "$next"; return 1; }
  printf '%s\t%s\t# servers-app\n' "$ip" "$name" >> "$next"
  _hosts_write < "$next"; rc=$?
  rm -f "$next"
  return $rc
}

_hosts_remove() {
  local name="$1" ip="$2" next rc
  [[ -n "$name" && -n "$ip" ]] || return 1
  next="$(mktemp)" || return 1
  awk -v n="$name" -v ip="$ip" '!($1 == ip && $2 == n && $3 == "#" && $4 == "servers-app")' "$HOSTS_FILE" > "$next" || { rm -f "$next"; return 1; }
  _hosts_write < "$next"; rc=$?
  rm -f "$next"
  return $rc
}

_hosts_unalias() {
  local ip="$1"
  ifconfig lo0 2>/dev/null | awk -v ip="$ip" '$1 == "inet" && $2 == ip { found = 1 } END { exit !found }' || return 0
  sudo ifconfig lo0 -alias "$ip"
}
