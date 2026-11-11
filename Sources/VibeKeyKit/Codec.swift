import Foundation

enum FrameCodec {
    static let key: (UInt32, UInt32, UInt32, UInt32) = (
        0xCAA5_BACA, 0xBC2A_8A6D, 0xCA5A_9EBA, 0x9BB8_8BCA
    )

    static func encrypt(_ plain: [UInt8]) -> [UInt8] {
        transform(plain, decode: false)
    }

    static func decrypt(_ cipher: [UInt8]) -> [UInt8] {
        transform(cipher, decode: true)
    }

    private static func transform(_ bytes: [UInt8], decode: Bool) -> [UInt8] {
        var out = bytes
        let blocks = out.count / 8
        for index in 0..<blocks {
            let base = index * 8
            var v0 = load(out, base)
            var v1 = load(out, base + 4)
            if decode {
                decodeBlock(&v0, &v1)
            } else {
                encodeBlock(&v0, &v1)
            }
            store(v0, into: &out, at: base)
            store(v1, into: &out, at: base + 4)
        }
        return out
    }

    private static func encodeBlock(_ v0: inout UInt32, _ v1: inout UInt32) {
        let delta: UInt32 = 0x9E37_79B9
        let (k0, k1, k2, k3) = key
        var sum: UInt32 = 0
        for _ in 0..<32 {
            sum = sum &+ delta
            v0 = v0 &+ (((v1 << 4) &+ k0) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ k1))
            v1 = v1 &+ (((v0 << 4) &+ k2) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ k3))
        }
    }

    private static func decodeBlock(_ v0: inout UInt32, _ v1: inout UInt32) {
        let delta: UInt32 = 0x9E37_79B9
        let (k0, k1, k2, k3) = key
        var sum: UInt32 = delta &* 32
        for _ in 0..<32 {
            v1 = v1 &- (((v0 << 4) &+ k2) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ k3))
            v0 = v0 &- (((v1 << 4) &+ k0) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ k1))
            sum = sum &- delta
        }
    }

    private static func load(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func store(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

struct DeviceMessage {
    var bytes: [UInt8]

    static func heartbeat() -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x06
        bytes[1] = 0x01
        bytes[2] = 0x23
        bytes[4] = 0x01
        return DeviceMessage(bytes: bytes)
    }

    static func activeQuery() -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x06
        bytes[1] = 0x03
        bytes[2] = 0x0A
        bytes[3] = 0x01
        return DeviceMessage(bytes: bytes)
    }

    static func shortcutQuery(index: UInt8) -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x01
        bytes[1] = 0x06
        bytes[2] = 0x50
        bytes[3] = 0x01
        bytes[4] = index
        return DeviceMessage(bytes: bytes)
    }

    static func batteryQuery() -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x01
        bytes[1] = 0x01
        bytes[2] = 0x02
        bytes[3] = 0x01
        return DeviceMessage(bytes: bytes)
    }
}

public struct PowerStatus: Equatable {
    public var percent: Int
    public var millivolts: Int
    public var charging: Bool

    public var menuVoltage: String {
        String(format: "%.2f V", Double(millivolts) / 1000)
    }
}

enum PowerReport {
    static func parse(_ plain: [UInt8]) -> PowerStatus? {
        guard plain.count >= 12 else { return nil }
        if plain[1] == 0x7B {
            return make(
                percent: Int(plain[5]),
                millivolts: Int(UInt16(plain[2]) | (UInt16(plain[3]) << 8)),
                charging: (plain[4] >> 3) & 0x1 == 1
            )
        }
        if plain[2] == 0x02 {
            return make(
                percent: Int(UInt16(plain[6]) | (UInt16(plain[7]) << 8)),
                millivolts: Int(UInt16(plain[4]) | (UInt16(plain[5]) << 8)),
                charging: plain[10] != 0
            )
        }
        return nil
    }

    private static func make(percent: Int, millivolts: Int, charging: Bool) -> PowerStatus? {
        guard (0...100).contains(percent), (2500...5000).contains(millivolts) else { return nil }
        return PowerStatus(percent: percent, millivolts: millivolts, charging: charging)
    }
}
