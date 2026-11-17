// 패킷 캡처(tcpdump -w -)의 pcap 흐름 읽기·쓰기. 흐름은 조각으로 오므로 읽기는 이어 붙여 가며 다 온 레코드만 낸다.
// 형식: 전역 머리 24바이트(매직 · 버전 · snaplen · 링크 종류) + 레코드(초 · 마이크로/나노초 · 잡은 길이 · 원래 길이 · 바이트).
// macOS tcpdump 는 리틀엔디언 마이크로초(d4c3b2a1)를 쓴다 — 실제 출력: Tests/ServersCoreTests/Fixtures/capture-lo0.pcap

import Foundation

public struct CapturedPacket: Sendable, Equatable {
    /// 1970 기준 초
    public let time: Double
    /// 줄에 실린 원래 길이 (잡은 바이트는 snaplen 까지라 짧을 수 있다)
    public let originalLength: Int
    public let data: [UInt8]

    public init(time: Double, originalLength: Int, data: [UInt8]) {
        self.time = time; self.originalLength = originalLength; self.data = data
    }
}

public struct PcapReader: Sendable {
    public enum ReadError: Error, Equatable { case notPcap }

    /// 전역 머리를 읽은 뒤의 링크 종류 (1 Ethernet · 0 BSD loopback(utun·lo0) · 12/101 raw IP)
    public private(set) var linkType: UInt32?
    private var buffer: [UInt8] = []
    private var offset = 0
    private var bigEndian = false
    private var nanoseconds = false

    public init() {}

    /// 조각을 받아 다 온 패킷만 돌려준다. 매직이 pcap 이 아니면 notPcap (pcapng·오류 문구 등)
    public mutating func feed(_ chunk: [UInt8]) throws -> [CapturedPacket] {
        buffer.append(contentsOf: chunk)
        if linkType == nil {
            guard buffer.count - offset >= 24 else { return [] }
            switch Array(buffer[offset..<offset + 4]) {
            case [0xd4, 0xc3, 0xb2, 0xa1]: bigEndian = false; nanoseconds = false
            case [0xa1, 0xb2, 0xc3, 0xd4]: bigEndian = true; nanoseconds = false
            case [0x4d, 0x3c, 0xb2, 0xa1]: bigEndian = false; nanoseconds = true
            case [0xa1, 0xb2, 0x3c, 0x4d]: bigEndian = true; nanoseconds = true
            default: throw ReadError.notPcap
            }
            linkType = u32(offset + 20)
            offset += 24
        }
        var out: [CapturedPacket] = []
        while buffer.count - offset >= 16 {
            let caplen = Int(u32(offset + 8))
            guard caplen <= 262_144 else { throw ReadError.notPcap }   // 깨진 흐름 — 끝없이 기다리지 않게
            guard buffer.count - offset >= 16 + caplen else { break }
            let seconds = Double(u32(offset)), fraction = Double(u32(offset + 4))
            let time = seconds + fraction / (nanoseconds ? 1_000_000_000 : 1_000_000)
            let data = Array(buffer[offset + 16..<offset + 16 + caplen])
            out.append(CapturedPacket(time: time, originalLength: Int(u32(offset + 12)), data: data))
            offset += 16 + caplen
        }
        // 다 쓴 앞부분은 가끔 한꺼번에 버린다 (매번 지우면 큰 흐름에서 느리다)
        if offset > 65_536 {
            buffer.removeFirst(offset)
            offset = 0
        }
        return out
    }

    private func u32(_ at: Int) -> UInt32 {
        let b0 = UInt32(buffer[at]), b1 = UInt32(buffer[at + 1]), b2 = UInt32(buffer[at + 2]), b3 = UInt32(buffer[at + 3])
        return bigEndian ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
    }
}

public enum PcapWriter {
    /// 리틀엔디언 마이크로초 pcap — Wireshark 가 그대로 연다
    public static func data(linkType: UInt32, snaplen: UInt32, packets: [CapturedPacket]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(24 + packets.reduce(0) { $0 + 16 + $1.data.count })
        func put(_ v: UInt32) { out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
        func put16(_ v: UInt16) { out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
        put(0xa1b2c3d4); put16(2); put16(4); put(0); put(0); put(snaplen); put(linkType)
        for packet in packets {
            let seconds = packet.time.rounded(.down)
            put(UInt32(seconds)); put(UInt32(((packet.time - seconds) * 1_000_000).rounded()).clamped(max: 999_999))
            put(UInt32(packet.data.count)); put(UInt32(max(packet.originalLength, packet.data.count)))
            out.append(contentsOf: packet.data)
        }
        return Data(out)
    }
}

private extension UInt32 {
    func clamped(max limit: UInt32) -> UInt32 { Swift.min(self, limit) }
}
