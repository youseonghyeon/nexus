// 테스트가 함께 쓰는 servers.conf 예시.

import Foundation

let fixture = """
# 테스트용
[network:lan]
service=Test Ethernet
routes=192.0.2.0/255.255.255.0, 198.51.100.0/255.255.255.0
wait_attempts=2
wait_interval=0

[group:acme]
theme=on
db_jump=was
db_host=db.example.test
db_port=5432
db_local=15432
db_name=testdb

[nexus]
group=home
network=tailscale
type=linux
ip=100.64.0.1
user=tester
port=2222
role=Home server   # 값 뒤 주석
env=HOST

[win]
group=home
network=tailscale
type=windows
ip=100.64.0.2
user=tester
port=2222
wol_mac=00:11:22:33:44:55
wol_via=nexus

[ghost]
group=home
network=tailscale
type=linux
ip=100.64.0.9
user=tester
port=2222
check=ssh

[was]
group=acme
network=lan
type=linux
ip=192.0.2.22
user=tester
port=2222
role=WAS server
env=PROD
"""
