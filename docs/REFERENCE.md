# Nexus 상세 설명

화면·동작 하나하나의 세부 규칙을 적어 둔 문서입니다 (개발 참고용). 처음 쓰는 분은 [README](../README.md) 를 보세요.
괄호 안의 `이름` 은 그 판정·파싱을 맡은 코드(`app/Sources/ServersCore`)입니다. 예시의 서버 이름·주소는 가상의 값입니다.

- 사이드바: 맨 위 검색(⌘K — 서버는 이름·IP·역할·태그·그룹, 터널·전송은 글자로 거름, Esc 로 지움) · Network(Tailscale VPN·내부망·Wi-Fi 켜기/끄기, 누르면 망 Dashboard. Tailscale VPN 행은 tailscale 이 설치돼 있으면 서버가 없어도 보임(앱을 켠 직후 확인 전엔 숨김) · 그 아래 VPN 행 하나에 시스템 설정의 VPN(`scutil --nc`, Tailscale 제외)을 모아 켜기/끄기만(행 버튼: 켜진 게 있으면 그것 전부 끄기, 없으면 켜기 — 여럿이면 메뉴로 고름, `SystemVPNs.rowAction`. 연결된 VPN 은 타일 — 연결 시간·Server·받기/보내기 속도·누적 — 과 상태·주소 카드: Interface/MTU·나가는 장치(암호화한 패킷이 실제로 나가는 물리 장치·게이트웨이 — 라우팅 테이블엔 안 보여 VPN 확장 프로세스 소켓을 `nettop` 으로 읽음, `VPNEgress`)·인터넷 경로·On-Demand·속도(그 utun 으로만 `networkQuality` — 지정한 경로만 가는 VPN 이면 실패) · IPv4/IPv6·경로·DNS. 주소 카드 맨 위에 공인 IP — 그 utun 으로만 나가 본 주소와 위치(도시 · AS)를 요청 한 번으로(ip-api.com, HTTP · 연결 2초·전체 4초에서 끊음, 안 되면 ipify 로 주소만 · 지정한 경로만 가는 VPN·막힌 망이면 "가져오지 못했습니다", `IPLocate.selfLookup`). 공개키·handshake 는 WireGuard 앱에서만) — 구성은 각 VPN 앱에서, 메뉴바 패널엔 VPN 마다 스위치.
  일부러 꺼 둔 내부망은 회색 "비활성") · Local(this Mac · System · Disk · Bluetooth) · 그룹별 서버(상태 점 — 초록 응답 · 빨강 켜졌는데 SSH·포트 안 됨(linux 는 ping 응답) · 회색 꺼짐·확인 안 함, 태그 배지 — 운영 빨강·스테이징 파랑, 표는 `ServerTags`) · Tunnels · Transfers.
  맨 아래 고정 줄은 마지막 확인 시각·주기, 창 윗줄의 ↻ 는 지금 확인(⌘R). 상태 메시지는 오른쪽 아래 토스트(경고는 주황, 같은 글 반복은 ×N, 5초 뒤 닫힘)
  Wi-Fi 이름(SSID)은 macOS 위치 권한이 있어야 읽혀 Wi-Fi 화면을 처음 열 때 권한을 묻는다 (거부하면 안내 + 시스템 설정 열기)
  유선 서비스 상태는 스냅숏 하나(`WiredSnapshot` — 5초마다 서비스 순서·ifconfig·서비스별 getinfo, 수동 IP 는 게이트웨이 ping/ARP)와 판정 하나(`ServiceLink`)로
  Ethernet 행·화면·서비스 카드·Intranet 화면·사이드바가 같이 쓴다. 서비스 값(IP·서브넷·게이트웨이·구성)은 그 서비스 것, NIC 값(링크·받기/보내기·인터넷 응답·공인 IP·DNS)은 그 서비스가 연결됨일 때만.
  Ethernet 행·타일·어댑터 카드는 서비스 기준: 활성 유선 서비스 중 Intranet 으로 지정한 서비스 하나만 뺀 것(같은 장치의 다른 서비스는 남음), 그중 어댑터가 꽂힌 것만 —
  주소는 그 서비스의 IP(getinfo), 대표는 인터넷이 나가는 서비스 → 연결된 서비스 → 링크 → 첫 번째, 링크 속도·받기/보내기는 물리 NIC 값 (`Ethernet`). 서비스 카드에는 유선 서비스 전부(꺼진 것·같은 어댑터의 여러 서비스 포함):
  상태는 켜짐과 연결됨을 가른다(비활성 · 활성·어댑터 없음 · 활성·링크 없음 · 활성·주소 없음 · 연결됨·IP — 그 서비스의 IP 가 장치에 붙었는지, `ServiceLink`) ·
  [활성화]/[비활성화](관리자 인증, 모든 유선 서비스 공통 — Intranet 스위치도 지정한 서비스로 같은 함수, 활성화 뒤 주소가 붙을 때까지 행에 스피너) ·
  "인터넷 경로" 딱지(표시만 — VPN 이 기본 경로면 그 아래 회선의 서비스) · [Intranet 으로 지정](확인 창 "순서를 맨 뒤로 옮깁니다 · 관리자 인증" → 검사 없이 기록만 — lan.json, 처음이면 servers.conf 에 [network:lan],
  그리고 서비스 순서 맨 뒤로 한 번(이미 맨 뒤면 인증 없이 건너뜀). 켜고 끄지 않는다) ·
  [서비스 추가…](링크 있는 유선 어댑터에 수동 IP·DNS(선택) 서비스 — 비활성 상태로 순서 맨 뒤, 실패하면 지움, `NetworkServiceDraft`).
  Intranet 도 그냥 유선 서비스 — 2026-10-15 단순화로 IP·링크 대기, 실패 시 되돌리기, 게이트웨이 확인, 전환([적용]), 켤 때 순서 이동·끌 때 되돌리기, 예전 추가 경로 지우기는 뺐다
  Wi-Fi·Ethernet 화면의 응답·공인 IP·속도 측정·DNS(Intranet 화면은 DNS·게이트웨이 응답 — DNS 는 scutil --dns 읽기, 게이트웨이는 ping -b) 는 그 장치로만 잰 값(기본 경로가 VPN·다른 망이어도) — 실제로 나가는 기본 경로·DNS·공인 IP 는 this Mac 화면. 공인 IP 줄 아래에는 위치(도시 · AS — 주소와 함께 ip-api.com 요청 한 번, HTTP · 안 되면 ipify 로 주소만, `IPLocate.selfLookup`).
  Routes 카드 표 옆(좁으면 아래)에 경로 그림: 이 Mac → 장치마다 한 갈래 → 그 장치로 나가는 목적지. 인터넷이 타는 갈래는 초록, VPN 터널은 타고 나가는 물리 장치를 경유 마디로(`utun6` → `en0` → 인터넷), 묶여 대기 중인 default 는 흐리게. IP 를 넣으면 그 주소가 타는 갈래만 또렷해진다(가장 긴 대역이 이김, 묶인 default 는 후보 아님 — `RouteGraph`). 리눅스·OpenWrt 서버의 Network 탭에도 같은 그림(Routes 구역): main 테이블과 조건 없는 트래픽이 타는 줄만 그리고 컨테이너 배선(veth·브리지)은 뺀다. 정책 규칙이 기본 셋뿐인 서버만 IP 입력칸이 있다(정책 라우팅이 있으면 주소만으로 판정할 수 없어 그림만)
  this Mac 화면 Routes 카드: IPv4 라우팅 테이블(`netstat -rn -f inet`, root 불필요) — default·대역·라우터 거치는 호스트 경로만 (호스트 캐시·ARP·멀티캐스트·lo0·169.254·브로드캐스트·라우터 없는 묶인 default 는 뺌), 대역은 Linux 처럼 네 옥텟(`10.1.0.0/24` — netstat 은 `10.1/24`), 같은 대역이 여러 장치면 한 줄, 게이트웨이 없으면 On-link, 쓰이는 default 에 "기본 경로" 딱지·장치에 묶인(I) default 는 옅게, default 앞 번호는 우선순위(1 = 쓰이는 default, 나머지는 `scutil --nwi` 서비스 순서), `0.0.0.0/1`·`128.0.0.0/1` 짝(VPN 이 default 를 이기는 방식)이 있으면 맨 위에 딱지, VPN 터널 줄 끝엔 나가는 물리 장치(`→ en11`) (`RouteTable`).
  this Mac 화면 Hosts 카드(주소 카드 옆): `/etc/hosts` 읽기만 — 기본 줄(localhost·broadcasthost) 빼고 파일 순서, 앱의 서버 이름 터널 줄(`# servers-app`)에 "터널" 딱지, 같은 이름이 앞 줄에 있어 쓰이지 않는 이름은 옅게 (`HostsFile`). 그 아래 도메인별 DNS(`/etc/resolver/*`·VPN 이 넣는 도메인 — `scutil --dns`, 있을 때만).
  패킷 캡처 창(윈도우 ▸ Packet Capture ⌥⌘P · 망 화면 진단 카드 [Capture…] — 그 화면 장치로): 열면 바로 `sudo tcpdump -w -`(지문, 안 되면 비밀번호 창) — 닫으면 끝, 일시정지는 프로세스를 끝내 자원 0(재개는 다시 인증)·초기화·장치/필터(tcpdump 식, Enter) 바꾸면 다시 시작·.pcap 저장(Wireshark 로).
  요약: 대화(바이트 순 · TLS SNI·WireGuard 등 이름표 · SYN→SYN/ACK 시간) · TCP 문제(거부 · 닫은 뒤 RST(연결하자마자 닫는 확인 — 정상) · RST · 재전송 · Win=0 · 응답 없는 SYN) · DNS(질의·답·걸린 시간·NXDOMAIN) · WireGuard(상대별 마지막 핸드셰이크) — 누르면 목록을 그것만.
  목록은 최근 2만 개(패킷마다 앞 256 바이트, 요약은 전부 셈), 최근 것이 위(그리는 건 거른 뒤 최근 5천) · 목록 검색(주소·포트·프로토콜·Info·제조사, 여러 낱말 — 캡처는 그대로) · 행을 고르면 목록 고정 + 계층별 상세(넓으면 옆, 좁으면 아래 — Ethernet·IP·TCP 옵션·상대 Seq/Ack·DNS·TLS·HTTP·WireGuard·판정 이유). hex·계층 트리는 없음 (`Pcap` · `PacketDecoder` · `CaptureStore` · `PacketDetails`). 표의 행은 패킷 번호가 아니라 자리로 구분 — 새 패킷이 와도 행을 끼워 넣지 않고 내용만 바꾼다(`CaptureSlots`).
  캡처 필터 도우미: 필터 칸을 누르면 다음 낱말(host·port·net·tcp…)과 값 후보(servers.conf·게이트웨이·DNS·지금 캡처의 상대·포트·이 Mac 대역)·자주 쓰는 것, 고르면 다음 것이 이어서. 목록 행·대화 줄 오른쪽 클릭으로 거꾸로 만들기(이 대화만·주소·포트·빼기). Enter 전에 문법 검사(헤더만 있는 pcap 으로 `tcpdump -r … -d`, root 불필요) (`CaptureFilterAssist`).
  this Mac 화면의 그 밖: Spec 에 모델(`system_profiler SPHardwareDataType`), Address 카드에 시스템 프록시(`scutil --proxy`, 켜져 있을 때만), Ports 카드 제목 줄에 방화벽(`socketfilterfw` — 켜짐·Stealth·들어오는 연결 모두 차단) (`LocalNetworkPolicy`).
  Intranet·Wi-Fi·Ethernet·VPN 화면의 진단 카드 (그 화면의 장치로만 — Intranet 은 내부망 장치, Wi-Fi 는 연결된 Wi-Fi, Ethernet 은 대표 어댑터, VPN 은 첫 번째로 연결된 VPN 의 utun): ping 줄 — IP·이름을 넣고 [실행] → 5회(`ping -b`) + 경로(`traceroute -I -i`, 최대 30홉 — 앞 15홉만 보이고 [더보기 (N홉)]로 나머지, 새로 재면 다시 접힘) (`PingTest`) — 경로가 끝나면 [주소 검색]: 공인 IP 홉만 ip-api.com batch 에 요청 한 번(그 장치로, 키 없음·HTTP) → 홉 끝에 `도시, 시·도, 국가 · AS · 조직`(우편번호·좌표는 받지 않음)(DB 추정 — 등록지로 나올 수 있음, `IPLocate`) ·
  ping 대상이 IPv4 이고 같은 대역이면 ping 뒤 ARP 캐시를 본다(`arp -n -i` — MAC 이 있으면 ping 이 막혀도 장비는 켜져 있다, 게이트웨이 너머면 "같은 대역 아님") ·
  TCP 줄 — IPv4:포트에 그 장치로만 연결 한 번(3초, `TCPProbe` — 로그인 없음, ping 이 막혀도 포트가 열렸는지) ·
  DNS 줄 — 그 화면 장치의 DNS 서버에 이름 하나(`dig -b <서비스 IP> @<DNS>`, A — CNAME 이면 경로도, TTL·IPv6 주소(AAAA), NXDOMAIN·응답 없음 구분, 그 이름을 관리하는 영역의 네임서버(NS — 하위 이름이면 SOA 를 따라 올라감, 알려진 곳은 서비스 이름 `DNSProvider`), `DNSLookup`) ·
  ARP 줄 [Scan] — 그 화면 서비스 대역(/24 이하)의 주소에 ping 을 한 번씩 병렬로(동시 64개, 1초) 보낸 뒤 ARP 표를 읽어 응답한 장비(MAC)만 (`N대 응답 / M개 확인`,
  ARP 표는 최근 통신한 상대만 기억하므로 먼저 채운다 · 더 넓은 대역은 표만, VPN 화면엔 ARP 표·ping 결과의 ARP 줄 없음(utun 은 ARP 가 없다), `Arp`) — 장비마다 제조사(MAC 앞자리를 IEEE 배정 목록 `app/Resources/oui/oui.tsv` 에서, 오프라인)·
  사설(임의) MAC 표시·DNS 이름(그 화면 DNS 서버에 PTR, 1초)·Windows 이름(NetBIOS, `smbutil status`, 2초 — `DeviceIdentity`)·
  UPnP 이름(SSDP M-SEARCH 한 번·2초 → 그 장비 자신의 http 설명 XML 의 friendlyName, `SSDP`) — 답이 없으면 빈칸, 같은 이름은 한 번만. 앱 안에서 표가 비면 [관리자 권한으로 다시 읽기] · 결과마다 [초기화] ·
  결과 옆 복사 아이콘은 결과 전체를 텍스트로(경로는 접힌 홉까지, `reportText`) ·
  HTTP 줄 — URL(스킴 없으면 http)을 넣고 [실행] → 요청 한 번(`curl --interface`, 프록시 안 탐, 본문은 받아서 버림·최대 10초, 리다이렉트 안 따라감) — 상태 코드·이동 위치·붙은 IP·단계별 시간, 인증서 문제는 검사를 끄지 않고 "인증서 확인 실패" (`HTTPTest`)
  Wi-Fi 접속 세부의 [상세 보기]는 Touch ID·암호로 `sudo wdutil info` 를 한 번 읽어 채널 혼잡도·MCS·공간 스트림·가드 인터벌·국가 코드를 채운다(`WiFiDetail`, 화면을 떠나면 지움)
- 서버 정보 화면: 결론 한 줄 → 상태 파이프라인(망→피어→SSH) → 접속·액션 카드 → 원격 정보 카드([Spec | Network | Services | Ports | Schedule | Live] — 서버 종류에 따라,
  게이지·상태색·포트 이름·[Tunnel…]) → 터널 카드(활성·닫힘, 열기)
  Spec 은 모델(DMI·가상화 — VM/컨테이너 구분, Lenovo 는 제품 이름) · CPU 모델명 · 재부팅 필요(주황) · 대기 업데이트(Ubuntu apt-check, 보안이 있으면 주황) ·
  가동 시간(서비스와 같은 "N일 N시간"). 원시 값은 스크립트가, 한국어·경고는 `RemoteInfo.formatSpec` 이
  Services 는 정해 둔 목록이 아니라 서버가 실제로 돌리는 것: 실패(재시작 반복 포함)를 맨 위에, 실행 중 전체(가동 시간·메모리·재시작 횟수,
  OS 기본 서비스는 접음), docker 컨테이너·k3s 파드. 리눅스는 서비스 줄을 누르면 최근 로그 50줄(`sudo -n journalctl` → 안 되면 그냥). docker 컨테이너 줄도 누르면 최근 로그 50줄(`docker logs --tail 50` → 안 되면 `sudo -n`, 이름 복사는 우클릭). 로그는 독립 창에 뜬다 (크기·위치를 기억, 본창을 계속 쓸 수 있다).
  스크립트·파서는 `ServicesReport` (리눅스 출력은 로컬 컨테이너의 systemd 에서 뜬 픽스처로 테스트)
  Windows 는 [Spec | Network | Services | Ports | Live] — PowerShell 로 읽기만 한다(2026-11-10). Spec 은 고정 드라이브 전부(게이지)·물리 디스크(모델·SSD/HDD·상태)·GPU(VRAM),
  Network 는 어댑터(설명·링크 속도, Hyper-V·WSL 가상 어댑터는 접음)·경로 그림·DNS, Ports 는 포트를 연 프로세스 이름, Live 는 CPU·코어·메모리·페이지 파일·디스크·네트워크·GPU(nvidia-smi)·상위 프로세스.
  Live 는 원시 누적 카운터만 읽고 사용률은 앱이 직전 표본과의 차이로 낸다(서버에서 기다리지 않음 — 0.4초). 스크립트·파서는 `WindowsLive`·`WindowsNetwork`,
  픽스처는 실제 Windows 11 출력(`Fixtures/windows-*.txt`). PowerShell 함수 이름은 기본 별칭과 겹치면 별칭이 대신 돈다(`R` → Invoke-History) — 테스트가 막는다.
  OpenWrt 공유기(`type=openwrt`)는 [Spec | Network | Firewall | Clients | WireGuard | Services | Ports | Live] — bash·systemd·ss 대신 ash·ubus·uci·procd 로 읽기만 한다.
  Spec 은 OpenWrt 버전(GL.iNet 펌웨어면 그 버전)·보드 이름·메모리·루트(overlay) · Network 는 인터페이스(wan·lan·wg…: 켜짐·가동 시간·주소·받기/보내기·포트 속도) 한 줄에 경로와 포트를 모은다 — 게이트웨이를 타는 IPv4 경로(`ip route show table all`, 조건 없는 트래픽이 타는 줄에 "기본 경로" 딱지)는 행 아래에 늘 보이고, 행을 누르면 주소(누르면 복사)·DNS·자기 대역 On-link·물리 포트(내부 스위치가 있으면 `swconfig`·`board.json` 으로 실제 포트별 링크 — 스위치로 가는 내부 연결은 빼고, 읽지 못하면 내부 연결 그대로). 다른 테이블·blackhole·모르는 장치의 경로와 인터페이스에 안 묶인 포트는 Other routes·Other ports 로, Policy rules(`ip rule` 중 기본 규칙 셋을 뺀 것)는 경로 없는 테이블을 보는 규칙을 접어 둔다
  · Firewall 은 `uci show firewall` 로 존 매트릭스(어디서 어디로 새 IPv4 연결을 낼 수 있나 — 조건 없는 규칙이 있으면 칸은 그 규칙의 결과, 칸을 누르면 기본 정책과 그 방향의 규칙을 적용 순서대로)·포트 포워딩(GL.iNet 관리 화면의 `port_forward` 포함, 켜짐은 설정값), 접어 둔 전체 규칙(설정 순서 그대로)과 규칙을 직접 넣을 수 있어 목록에 안 보이는 include 스크립트 · Clients 는 DHCP 임대 + 고정 할당 + LAN 브리지 이웃(초록 = `ip neigh` REACHABLE 등 방금 확인 — ARP 표는 STALE 도 완성으로 찍어 쓰지 않음, ip 가 없으면 ARP 표), 이름은 GL.iNet 별칭(`gl-client`) → 장비가 알린 이름 → 고정 할당 이름, 제조사는 MAC 앞자리(MAC·고정 할당의 임대 시간은 마우스를 올리면, 유동 임대에만 `DHCP` 와 남은 시간) · WireGuard 는 피어별 연결 상태(마지막 핸드셰이크 3분 안이면 초록, 시각은 마우스를 올리면)·끝점·허용 IP·주고받은 양, 이름은 uci description — 개인 키·사전 공유 키는 공유기에서 지우고 받는다 ·
  Services 는 procd 서비스(켜 뒀는데 멈춘 것 맨 위, 일회성·꺼 둔 것은 접음), 누르면 `logread` 최근 50줄. 스크립트·파서는 `OpenWrt`
  (출력은 로컬 openwrt/rootfs 컨테이너를 procd 로 부팅해 받은 픽스처로 테스트)
- 서버 추가·지우기: 사이드바 그룹 헤더(home·acme) 옆 [+] 로 그 그룹·망이 채워진 입력창을 열거나 서버 ▸ 서버 추가…(서버가 없어도 늘 — 고른 서버의 그룹을 채움)로 열어 `servers.conf` 끝에 블록을 붙이고(망은 Direct/Intranet/VPN/Tailscale 선택 — 목록에 `[network:lan]` 이 없으면 Intranet 을 고를 때 서비스도 골라 블록을 함께 쓴다 — Direct(`network=direct`, 줄을 빼도 같음)는 망 설정 없이 이 Mac 의 기본 경로로 바로 확인: VPN 너머·공인 IP 장비, 확인 기본값 tcp — VPN(`network=vpn`, `vpn=<시스템 VPN 이름>` · 빼면 연결된 첫 VPN)은 그 VPN 이 연결돼 있을 때만 확인하고 SSH·전송·터널·상태 확인을 그 utun 에 묶는다: 꺼져 있으면 비활성, VPN 화면에 서버 카드),
  입력창: Tailscale 이면 IP 옆 목록에서 아직 등록하지 않은 피어를 골라 IP·종류(·빈 이름)를 채움(`TailscalePeers`, 이 Mac 의 tailscaled 에만 물음) · 그룹은 칸 옆 ▾ 로 있는 그룹에서 ·
  태그는 사이드바와 같은 색 배지로 미리 · 포트 옆 [확인] 은 누를 때만 IP:포트에 TCP 연결 한 번 · 켜짐·꺼짐 알림(`notify=on`)도 추가할 때 켤 수 있음 · 빈 필수 칸은 버튼 아래 안내.
  서버 ▸ 서버 가져오기… 는 다른 사람이 내보낸 servers.conf 에서 없는 서버만 붙인다(이름이 같으면 건너뜀, 그 서버들의 [group:*]·[network:lan] 은 없을 때만, `ServerConfigEditor.merging`),
  서버 내보내기… 는 지금 servers.conf 를 파일로(비밀번호는 passwords.bin 이라 들어가지 않음).
  서버 우클릭·Server 메뉴의 목록에서 제거… 로 그 블록만 지운다(다른 줄·주석은 그대로). 다른 서버의 `wol_via`·그룹의 `db_jump` 가 가리키던 서버면 그 참조도 함께 뺀다(확인 창에 미리 표시, 부팅 경로가 다 빠지면 `wol_mac` 도). 마지막 서버를 지우면 빈 목록(본문에 [서버 추가]). 판정·편집은 `ServerConfigEditor`
- 한 서버의 여러 계정(`extra_users=k3s-master,deploy`, `user=` 가 기본 계정, 개수 제한 없음 — 4개부터 사용자 칸이 메뉴로): 서버 정보 접속 카드의 사용자 칸 [+] 로 추가(비밀번호·키 파일을 넣기 전엔 그 계정으로 저절로 로그인을 시도하지 않는다), 계정 우클릭으로 기본 계정으로·계정 제거…(그 계정으로 연 터널은 끊겨 목록에서 빠진다). 서버 추가·편집 창은 사용자 하나만 받는다. 사이드바엔 한 줄이고, 사용자 칸에서 계정을 고르면 그 아래 비밀번호·키 파일과 이제부터 여는 SSH·전송·터널·원격 정보가 그 계정을 쓴다(고른 계정은 다시 켜도 유지). 열린 탭·터널은 연 계정 그대로 — 탭 이름에 `키 · 계정`, 끊긴 터널의 다시 연결도 연 계정으로. 서버 우클릭 SSH ▸ 계정 은 고른 계정을 바꾸지 않고 바로 연다. 상태 확인은 늘 기본 계정. 비밀번호·키 파일 저장 키는 기본 계정이 `키`, 추가 계정이 `키@계정`. `user=`·`extra_users=` 순서를 바꾸면 값이 계정을 따라 옮겨 가고, 지우는 건 사라진 계정(또는 IP 를 바꿨을 때 전부)의 비밀번호뿐이다(`rekeyingCredentials`·`clearedCredentials`).
  같은 장비를 계정별로 두 항목에 등록해 둔 목록은 서버 우클릭 계정으로 합치기 ▸ <서버> 에 합치기… (주소·포트·종류·망·그룹이 같고 사용자가 겹치지 않을 때만 보임): 계정을 `extra_users` 로 옮기고 블록을 지우며, 저장한 비밀번호·키 파일도 옮기고, 다른 서버의 `wol_via`·그룹의 `db_jump` 는 합친 서버로 돌린다(`ServerConfigEditor.mergingAccount`) — 태그·터널 바로가기는 더하고, 없는 역할·알림·프록시·부팅은 가져온다. 합쳐지는 쪽의 열린 탭·터널은 닫힌다.
- 서버 순서: 사이드바 순서는 `servers.conf` 의 블록 순서. 서버 우클릭·Server 메뉴의 위로 이동 / 아래로 이동 으로 같은 그룹의 이웃 서버와 블록(바로 위에 붙은 주석 포함)을 맞바꾼다. 그룹 끝이면 비활성
  그룹 순서는 그룹의 첫 서버 블록이 나오는 순서 — 그룹 머리 우클릭 위로 이동 / 아래로 이동 은 그 그룹(또는 이웃 그룹)의 서버 블록 전부를 이웃 그룹의 첫 블록 앞으로 옮긴다
- 서버 편집: 서버 우클릭·Server 메뉴의 서버 편집… · 접속 카드의 연필 → 이름·네트워크·IP·사용자·종류·포트·그룹·역할·태그·알림. 이름을 바꾸면 `[키]` 머리와 다른 서버의 `wol_via`·그룹의 `db_jump`, 저장한 비밀번호·키 파일(계정별)·고른 계정·깨우기 경로·앱 안 브라우저 쿠키·터널 기록·hosts 주소 배정·Chrome 프록시 프로필을 함께 옮긴다(`ServerConfigEditor.renaming`). 열린 탭은 닫히고 터널은 끊겨 목록에 닫힌 채 남는다(창에 미리 표시). `servers.conf` 에서 머리만 직접 고치면 지운 서버로 보여 저장한 비밀번호가 지워지니 앱에서 바꾼다.
  창에서 바꾼 줄만 지금 파일 위에 쓴다(안 바꾼 줄은 뒤 주석까지 그대로, 창을 연 뒤 파일을 직접 고친 줄도 덮지 않음).
  IP·사용자를 바꾸면 저장한 비밀번호는 지운다(창에서 미리 알림). 접속 정보가 바뀌면 그 서버로 열린 터널·프록시는 끊기고 [다시 연결]은 새 설정으로.
  그룹의 `db_jump` 서버는 그룹을 못 옮긴다(DB Tunnel 이 사라지므로). 검사는 바꾼 칸만
- 서버별 액션 편집: 서버 우클릭·Server 메뉴의 액션 편집… · 액션 카드의 조절 아이콘 → 터널 바로가기(`tunnel_ports`)·Chrome 프록시(`proxy_port`)·부팅(`wol_mac`/`wol_via`, 경로마다 한 줄)를
  추가·제거. 바뀐 줄만 쓰고(그대로인 줄의 뒤 주석은 유지) 새 줄은 블록 끝에. SSH·Tunnel… 같은 기본 액션과 type 으로 정해지는 액션(Shutdown 등)·DB Tunnel(그룹 설정)은 대상 아님
- 리눅스 서버의 원격 정보 탭(읽기만 — 재시작·로그 같은 조치는 넣지 않고 sudo 도 쓰지 않기로, 2026-11-07): Spec 의 "업데이트 N개" 줄을 누르면 apt 패키지 목록(보안 먼저, `LC_ALL=C apt list --upgradable`, 개수가 0이면 안 읽음 — 목록에는 있지만 지금은 안 올라가는 패키지(순차 배포 차례 전·hold)는 "3개 (보류 3)" 로 세고 뒤쪽에 흐리게, `apt-get -s dist-upgrade` 모의 실행으로 가린다) ·
  Network 탭(인터페이스별 주소·경로·정책 규칙·DNS — `ip -j addr`·`ip route`·`ip rule`·`resolvectl dns/domain`, 경로 판정은 OpenWrt 와 같은 `OpenWrtRouting`; veth·브리지는 "컨테이너 네트워크 N개" 로 접어 두고 안 꽂힌 NIC 는 회색 점으로 그대로) ·
  Schedule 탭(systemd 타이머 `list-timers --output=json` 다음·지난 실행, 내 crontab·/etc/crontab·cron.d·cron.{hourly…} — 다른 사용자의 crontab 은 root 만 읽을 수 있어 뺌. 주기는 "매일 03:00" 처럼 풀어 쓰고 못 풀면 원문). 스크립트는 `LinuxInfoScripts`, 파서는 `LinuxInfo`, 실측 출력은 `Fixtures/linux-*.txt`.
- 켜짐·꺼짐 알림: `servers.conf` 서버 블록에 `notify=on` 이면 5초 상태 확인이 연속으로 바뀔 때(켜짐 2회·꺼짐 4회) "<키> 켜짐"/"<키> 꺼짐" macOS 알림.
  꺼짐은 같은 망의 다른 서버가 응답할 때만 믿는다(이 Mac 의 인터넷이 끊긴 걸 꺼짐으로 오인하지 않게). 앱 시작 때 상태·이 Mac 쪽 사정으로 모르는 회차·
  잠자기에서 깬 뒤 30초·5분 넘게 모른 사이의 변화는 알리지 않음. 누르면 창을 열고 그 서버를 고른다. 판정은 `PowerWatch`
- 전송 알림: 파일 전송이 실패하면 항상, 완료는 10초 넘게 걸린 것만 macOS 알림 (취소는 알리지 않음). 문구는 `TransferNotice`
- ⌘T 새 SSH 탭 · ⌘⇧T 로컬 셸 탭 · ⌘W 보이는 탭(그 셸)만 닫기(터미널에 포커스가 있어도, 한글 입력기에서도) · 탭이 없으면 창 숨기기 · 터미널에서 드래그하면 바로 복사 · 터미널의 http(s) 주소는 ⌘+클릭으로 기본 브라우저에 열기(마우스를 잡는 프로그램 — Claude Code·tmux — 안에서도, 화면 폭에 꺾여 찍힌 주소도 이어서 · `TerminalLink`) · ⌘⇧[ / ⌘⇧] 이전·다음 탭(Dashboard 포함, 양 끝에서 돎) · ⌘⇧Enter 전체화면 켜기/끄기 · ⌘R 상태 확인 · ⌘⇧R servers.conf 다시 읽기 · ⌘ 를 누르고 있으면 사이드바 서버에 1–9 번호(보이는 순서, 접힌 그룹 제외) — ⌘1–⌘9 로 그 서버 고르기. `exit` 하면 탭이 닫히고,
  ssh 가 실패로 끝나면 종료 코드를 보여주고 키 입력을 기다림. 탭은 항상 마운트되어 서버·탭을 오가도 세션이 끊기지 않음.
  창의 닫기 버튼은 창을 숨기기만 하며(세션·터널 유지) Dock 아이콘으로 다시 엽니다. 종료는 ⌘Q
- 터미널에 이미지 넣기 (Ghostty 처럼): 터미널에 파일·스크린샷 썸네일(file promise — `TerminalDropView`)을 끌어 놓거나 ⌘V 하면 경로가 입력됨(붙여 넣기 모드 — Claude Code 등이 이미지로 받음). 스크린샷처럼 경로 없는
  클립보드 이미지는 이 Mac 임시 폴더(`$TMPDIR/nexus-paste`)에 png 로 저장해 그 경로. SSH 탭은 이미지(png·jpg·gif·webp·heic·tiff·bmp)와 문서(pdf·txt·md·csv·json·log·yaml·yml·xml·html)만 서버 `/tmp`
  (Windows `%TEMP%`)에 `nexus-<시각>-<이름>` 으로 올린 뒤(TRANSFERS 에 진행률) 서버 경로를 입력. 그 밖의 파일·폴더는 SSH 탭에서 올리지 않음(⌘V 는 원래대로). 판정은 `TerminalPaste`
- 설정 창(⌘,): 화면 모드 · 터널을 서버 이름으로 열기 · 원격 숨김 파일 보기 · 갱신 간격(서버 상태 확인 3/5/10/30초, 서버 Live 탭, System·Disk·Bluetooth 화면) ·
  터미널 색(미적용 = 테마 그룹 SSH 탭만 Rosé Pine·나머지 기본색 / 밝음 = Rosé Pine Dawn / 어두움 = Rosé Pine — 이 앱 터미널 탭에만, 열린 탭에도 바로, 테마 그룹의 원격 프롬프트·vim 색은 새 접속부터 `TerminalPalette`) ·
  코어 막대 애니메이션 · 비밀번호 키 · 부팅 경로(`wol_via` 에 경로가 둘 이상인 서버만, 기본 첫 경로) · 버전. 키·고를 수 있는 값·기본값은 `AppPreferences` (목록 밖 값은 기본값)
- 보기 ▸ 화면 모드: System(macOS 따라감)·Light·Dark 를 이 앱만 따로 고정. 고른 값은 다음 실행에도 남는다 (터미널 탭 색은 그대로)
- 액션(메뉴 막대의 서버 메뉴 · 우클릭 · 정보 화면): SSH · Tunnel… · DB Tunnel · Boot(꺼져 있을 때만) · Moonlight(Windows) ·
  Shutdown…(켜져 있을 때만, 확인) · 주소 복사. Spec·Network·Services·Ports·Schedule·Live 는 정보 화면 탭에만. 망 제어는 메뉴 막대의 네트워크 메뉴 · NETWORK 섹션
  서버 우클릭 공유 연결 끊기: 마지막 사용 뒤 10분 남는 공유 연결(ControlPersist)을 계정 전부 `ssh -O stop` 으로 내린다 — 다음 접속은 새로 인증하고, 이미 열린 SSH 탭·전송은 그대로. 소켓이 없으면 비활성(`SharedConnection`)
- 명령 모음: 탭 막대 오른쪽 끝 목록 아이콘(⌘P — 글자로 거르고 ↑↓·Return) → 서버 종류(Windows·Linux)·이 Mac 로컬 셸(macOS)별로 등록한 명령. 누르면 보고 있는 터미널에 붙여 넣고
  ("바로 실행" 체크한 명령만 Enter 까지), 터미널이 안 보이면 복사. 복사 아이콘·우클릭으로도 복사. [+]·연필로 추가·편집·삭제.
  민감한 명령(재부팅·삭제·서비스 중지 등 — 글자를 보고 저절로 켜고 끌 수 있음)은 터미널에 넣기 전에 서버 이름(이 Mac 은 `mac`)을 쳐서 확인. 복사는 그대로.
  명령 안의 `{{이름}}` 은 빈칸 — 누를 때 값을 묻고(앱이 켜져 있는 동안 이름별로 마지막 값을 채워 둠) 채운 뒤 입력. 중괄호 하나는 셸 문법, docker `{{.Names}}` 같은 Go 템플릿도 빈칸이 아니다. `~/Library/Application Support/Servers/snippets.json` 에 저장 — 깨진 파일은 덮지 않고 편집을 막는다
- 원격 동작은 BatchMode 로 조용히 먼저 시도하고, 비밀번호가 필요하면 macOS 경고창(`servers-askpass` 헬퍼, `SSH_ASKPASS`·`SUDO_ASKPASS`)으로
  받음. 취소하면 즉시 중단, 오답은 두 번까지. 한 번 인증하면 공유 연결이 10분간 유지
- 접속 카드의 네트워크 줄: `Direct · utun6` 처럼 나가는 장치를 함께 — Intranet·VPN 은 연결을 묶는 장치, Direct·Tailscale 은 `route -n get <ip>` 가 고르는 장치(VPN 이 경로를 가져가면 utun). 상태 확인 라운드마다 다시 본다
- 서버 정보 화면 접속 카드에 비밀번호를 넣어 두면 그 서버의 SSH 탭·spec/services/ports·터널·전송·Boot 경유가 창 없이 대입한다.
  `~/Library/Application Support/Servers/passwords.bin` 에 AES-GCM 으로 저장(0600). 키는 설치마다 무작위로 만들어 로그인 키체인
  ("Nexus 비밀번호 키")에 둔다 — 파일·앱만으로는 못 푼다. 옛 고정 키 파일은 첫 실행에 새 키로 옮기고, 키체인을 못 쓰면 고정 키로 돌아간다.
  설정(⌘,) > 비밀번호 > [키 새로 만들기] 는 새 키를 만들고 저장한 비밀번호를 모두 지운다. 틀리면 "Saved password was rejected" 창으로 다시 묻는다. Mac 관리자 비밀번호(내부망)는 저장하지 않음.
  최근 터널은 같은 폴더의 `recent.json` 에 남아 다음 실행에 닫힘 상태로 올라오고 터널 카드·Tunnels 에서 열기/다시 연결한다
- 같은 접속 카드의 키 파일: 기본 키(`~/.ssh/id_*`)가 아닌 개인키(.pem 등)를 서버마다 골라 두면 SSH 탭·상태 확인·전송·파일 목록·터널이 모두
  `-i <파일> -o IdentitiesOnly=yes` 로 쓴다. 파일은 복사하지 않고 경로만 `identities.json` 에(이 Mac 값이라 servers.conf 에 넣지 않음).
  개인키가 아니면 등록하지 않고, 권한이 열려 있으면(ssh 가 거부) 600 으로 바꿀지 묻는다. ~/.ssh 밖(다운로드 폴더 등)에서 고르면 ~/.ssh 로 옮겨
  등록할지 묻는다(복사 아님 — 같은 이름이 있으면 내용이 같을 때만 그것을 씀). 파일이 없어지면 "파일 없음" 표시와 함께 키 없이 접속
- 터널은 터미널이 아니라 Tunnels 목록 항목(전용 `ssh -N`, 워치독 셸이 앱과 함께 죽어 고아 프로세스가 남지 않음).
  누를 때마다 하나씩 생기고 로컬 포트가 쓰이면 다음 빈 포트(0.0.0.0 리스너도 사용 중으로 봄), 1024 미만은 +8000 제안(443→8443).
  입력창의 원격 호스트 칸에 IP·이름을 쓰면 서버를 거쳐 그 주소로(비우면 서버 자신). Ports 카드의 [Tunnel…]은 바인딩 주소가 특정 인터페이스면 그 주소가 채워진다. 행 클릭으로 접속 정보(JDBC·psql), 앱을 끄면 모두 끊김
- 내부망 서비스는 앱 저장소 `~/Library/Application Support/Servers/lan.json`(지정한 서비스 이름 하나)이 원천. 첫 실행 때 `servers.conf` 의 `service=` 로 만들고,
  지정은 Ethernet 화면 서비스 카드(Intranet 화면은 표시 + [변경…] → Ethernet). Intranet 상태 = 지정한 서비스가 활성인가
- 서버 정보 카드의 Live 탭(리눅스·OpenWrt 서버 — Windows 는 위 `WindowsLive`): CPU·코어·클럭·메모리·스왑·부하·디스크 사용/입출력·장치(모델·SSD/HDD)·RAID(mdstat)·네트워크(물리·VPN)·온도·
  상위 프로세스. `~/.tools/linux/` 의 stats.sh·disk.sh·net.sh 와 같은 식. 요약 줄의 코어는 물리 코어 수를 알면 "8코어 16스레드"(x86 — ARM·OpenWrt 는 "코어 N개").
  그 탭이 보일 때만 간격(기본 5초, 설정 창)마다 ssh 한 번(공유 연결)으로 `/proc` 원문을 읽는다 — 서버에 설치 없음, root·procps 불필요, `df` 는 로컬만·3초 제한(busybox df 는 -l 이 없어 없이).
  비밀번호 창은 띄우지 않고, 인증에 실패하면 멈춘 뒤 [다시 시도]로만 다시 묻는다(계정 잠금 방지). 스크립트·계산은 `LinuxLive`
- Local 의 System·Disk·Bluetooth 는 `~/.tools` 의 stats·disk·bt TUI 를 옮긴 화면 (같은 값·같은 계산). 화면이 떠 있고 창이 보일 때만 읽는다 —
  System 3초(CPU·코어·메모리 구성·GPU·온도·팬 RPM(AppleSMC, C 모듈 `CSMC`)·전원(배터리 충전·방전 W, 최대 용량·충전 사이클)·상위 프로세스 `ps`), Disk 2초(입출력·볼륨, 30초마다 `diskutil`·`tmutil`),
  Bluetooth 5초(`system_profiler -json`, HID 배터리, 전원 소스 배터리 `pmset -g accps` — 소니 헤드셋 등, 60초마다 GATT 배터리 — 처음 열 때 macOS 블루투스 권한을 묻는다). 사이드바 요약은 창이 보일 때만
  (System·Disk 5초, Bluetooth 30초). Disk 는 읽기 전용(볼륨이 모두 읽기 전용인 APFS 컨테이너·이미지 — 시뮬레이터 런타임 등 늘 가득 — 는 사용량 막대 회색), Bluetooth 는 연결/끊기·전원(끄기·끊기는 확인). `--sample-hidden` 으로 띄우면 창이 가려져도 읽는다(화면 확인용)
- 서버 정보의 [Browser] 는 **앱 안 브라우저 탭**(WKWebView) — **그 서버에서 브라우저를 켠 것처럼** 동작한다(2026-11-17). 탭의 모든 요청은 **앱 안 SOCKS 중계**(`SocksRelay`, 127.0.0.1)를 거쳐
  그 서버로 연 `ssh -D`(Tunnels 에 "<서버> proxy")로 가고, 이름 풀이도 서버가 한다. 막는 주소는 없다(서버가 닿는 다른 내부 서버·인터넷도 열린다). 이 Mac 의 터널은 관여하지 않는다.
  `127.0.0.1`·`localhost` 는 그 서버 자신: WebKit 이 루프백을 프록시에 보내지 않으므로 앱이 별칭 이름(`127-0-0-1.server.localhost`)으로 바꿔 열고 중계가 서버의 루프백으로 연결한다 —
  주소창엔 입력한 주소 그대로, `/etc/hosts`·관리자 인증과 무관(`BrowserPolicy`). 서버가 받는 Host 헤더는 별칭이고, 페이지 안에 루프백 절대 주소로 박힌 하위 요청은 못 바꾼다. 마지막 브라우저 탭을 닫으면 proxy 터널도 끊는다.
  탭은 **시작 페이지**로 열린다(주소창의 ⌂ 로 다시): 대표 카드(서버 이름·태그·주소·역할·접속 상태) · 주소칸(주소나 포트 번호를 치고 Enter) · **웹** 타일 · **제목 없는 응답** 칩 · **그 밖** 목록 —
  앱이 그려 탭에 넣는 것이고 서버에는 아무것도 띄우지 않는다(`BrowserStartPage`). 포트 목록은 Ports 탭과 같은 값(처음이면 조용히 읽는다, 시작 페이지의 ↻ 는 다시 읽기).
  웹인지는 실제로 물어 가른다(`WebProbe`): 번호로 아는 비웹 포트(22 ssh·5432 postgres 등)는 건드리지 않고, 나머지에 브라우저와 같은 길로 HTTP 를 한 번 보내 본다.
  제목(`<title>`)과 함께 답하면 **타일**(화면이 있는 것): 아이콘(24) · 제목 · 아랫줄에 포트 · `https` 표시 · 상태 코드. 제목 없이 답하면(API·리다이렉트·오류) **칩** 한 줄, 답이 없으면 그 밖.
  오류 응답(4xx·5xx)의 제목은 쓰지 않는다("404 Not Found" 는 서비스 이름이 아니다). 상태 코드는 2xx 가 아닐 때만 숫자로 보이고 5xx 만 경고색 — 가르는 데는 쓰지 않는다.
  아이콘은 제목 있는 페이지에서만 받는다: `<link rel="icon">` → 없으면 `/favicon.ico`, 같은 호스트·포트의 것만, 64KB 미만의 그림만(머리 바이트로 확인) — 앱이 받아 data: 주소로 심는다. 없으면 무채색 자리 그림.
  주소는 타일에 적지 않는다(포트가 말하고 거의 다 127.0.0.1) — 특정 주소에만 묶인 포트만 그 주소. 타일·칩은 서버 쪽 주소(`localhost:<포트>`, 묶인 포트는 그 주소)를 답한 스킴으로 연다.
  `tunnel_ports` 의 이름 붙은 포트는 답이 없어도 늘 타일 맨 위(이름 + 페이지 제목). 웹 확인은 SOCKS 터널이 열려 시작 페이지를 띄운 뒤에만 보낸다(그 전에 물으면 전부 실패한 채로 굳는다), 서버당 한 번 — ↻ 가 다시 묻는다.
  시작 주소는 그 서버로 열린 첫 포트 터널의 원격 포트로 `http://<IP>:<포트>/`. 쿠키·로그인은 서버별 영구 스토어, 다운로드는 ~/Downloads,
  Safari Web Inspector 사용 가능. 확장 프로그램(Bitwarden 등)은 없다. 판정은 `BrowserPolicy`(순수), WebKit 연결은 `BrowserSession`
- 내부망은 **시스템 경로(분할 라우팅)를 넣지 않는다**. 대신 이 앱이 `network=lan` 서버로 여는 연결(SSH 탭·터널의 바깥쪽·scp·sftp·상태 확인)만
  그 서비스의 장치(`en10` 등)에 묶는다(`ssh -o BindInterface`, TCP 프로브는 `IP_BOUND_IF`) → 장치의 스코프 기본 경로(내부망 라우터)로 나간다.
  다른 프로그램은 경로가 없어 내부망에 닿지 않고, 터널의 로컬 리스너(127.0.0.x)는 어디서나 붙는다. 소프트 격리 — 스스로 그 장치에 묶는 프로그램은 막지 못한다.
  내부망 서비스는 지정할 때 서비스 순서 맨 뒤로 보내 둔다 — 켜도 인터넷 기본 경로가 내부망 이더넷으로 잡히지 않게 (이 앱을 만든 이유)
- 터널은 "서버 주소로 열기"(기본 켬)를 고르면 서버별 고정 루프백 별칭(127.0.0.2 …)에 **원격과 같은 포트**로 열리고 `/etc/hosts` 에
  `<서버키>.<그룹>`(DB 터널은 `<서버키>-db.<그룹>`) 이름이 붙는다 → `db.acme:5432` 처럼 서버와 같은 주소로 접속. 배정표는 앱 저장소 `hosts.json`,
  hosts 줄은 `# servers-app` 표식이 붙은 것만 앱이 다룬다(`lib/hosts.zsh`). 별칭·hosts 줄이 없을 때만 root 인증 한 번(별칭은 재부팅 뒤 다시)
- LAN On/Off 등 관리자 작업은 Touch ID sudo(`pam_tid`)가 설정돼 있으면 Touch ID 로, 없거나 쓸 수 없으면(클램셸·취소) macOS 관리자 승인 창(암호)으로 인증. Touch ID 를 쓰려면 터미널에서 한 번:
  `sudo sh -c 'printf "auth       sufficient     pam_tid.so\n" > /etc/pam.d/sudo_local'`
- `SERVERS_CONF=<파일>` 또는 `--conf <파일>` 로 다른 목록을, `--run '<명령>'` 으로 시작 시 로컬 탭에서 명령 실행
- 서명: 키체인의 Developer ID Application 인증서로 번들 전체를 서명(hardened runtime·timestamp, 위치 권한 entitlement `Nexus.entitlements`).
  없으면 `make cert` 의 로컬 인증서 "Servers Local", 그것도 없으면 ad-hoc. GhosttyTerminal 리소스 번들은 `Contents/Resources` (`Bundle.module` 이 resourceURL 부터 찾음).
