// TCP 포트 열림 확인 (nc -z 대신). nc 는 소켓을 장치에 묶는 옵션이 없어, 시스템 경로 없이 내부망 장치의 스코프 기본 경로로 가려면
// 직접 소켓을 만들어 IP_BOUND_IF 를 걸어야 한다. 비차단 connect + poll 로 타임아웃을 지킨다. IPv4 만 — 이름(ip=호스트 이름)은 IPv4 주소로 풀어 쓴다.

import Foundation

public enum TCPProbe {
    /// host:port 에 timeout 초 안에 연결되면 true. device(en10 등)를 주면 그 인터페이스에 묶는다 (없는 장치면 false).
    /// poll 로 막히는 동안 협력 스레드 풀을 쥐지 않게 전용 스레드에서 돈다 (응답 없는 서버가 여럿이면 다른 async 작업이 굶는다).
    public static func connect(host: String, port: Int, timeout: TimeInterval, device: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            blockingThread("tcp.probe") {
                continuation.resume(returning: connectBlocking(host: host, port: port, timeout: timeout, device: device))
            }
        }
    }

    /// StatusMonitor 의 TCPProbeFunction 모양 (위치 인자)
    public static func probe(_ host: String, _ port: Int, _ timeout: TimeInterval, _ device: String?) async -> Bool {
        await connect(host: host, port: port, timeout: timeout, device: device)
    }

    /// IPv4 주소 그대로, 아니면 이름을 IPv4 로 푼 첫 주소 (getaddrinfo). 못 풀면 nil. 이름 풀이 시간은 timeout 에 들지 않는다.
    static func resolveIPv4(_ host: String) -> in_addr? {
        var literal = in_addr()
        if inet_pton(AF_INET, host, &literal) == 1 { return literal }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        guard first.pointee.ai_family == AF_INET, let address = first.pointee.ai_addr else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    static func connectBlocking(host: String, port: Int, timeout: TimeInterval, device: String?) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        guard let resolved = resolveIPv4(host) else { return false }
        address.sin_addr = resolved

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        if let device, !device.isEmpty {
            var index = if_nametoindex(device)
            guard index != 0 else { return false }
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return false }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(max(1, timeout * 1000))) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
