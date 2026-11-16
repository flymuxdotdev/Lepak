import Foundation

/// AI Passport 麦克风传来的声音：IMA ADPCM 解码，再从 16 kHz 升到 48 kHz（Lepak 麦克风驱动的采样率）。
///
/// 每块 164 字节 = 4 字节头（int16 小端的预测值、uint8 步长序号、1 字节保留）+ 160 字节数据
/// （320 个 4 位样本，每个字节先低半字节后高半字节）= 20 毫秒、16 kHz 单声道。块和块之间不传递状态。
/// 头里的预测值只是解码的起点，不算一个输出样本。
public enum PassportADPCM {
    public static let blockBytes = 164
    public static let samplesPerBlock = 320

    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
    private static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    /// 解出负载里所有完整的块，返回 -1…1 的浮点样本（16 kHz）。不足一块的尾巴忽略。
    public static func decode(_ payload: Data) -> [Float] {
        let blocks = payload.count / blockBytes
        guard blocks > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(blocks * samplesPerBlock)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for block in 0..<blocks {
                let base = block * blockBytes
                var predictor = Int32(Int16(bitPattern: UInt16(raw[base]) | UInt16(raw[base + 1]) << 8))
                var index = min(Int(raw[base + 2]), 88)
                for offset in 0..<(samplesPerBlock / 2) {
                    let byte = raw[base + 4 + offset]
                    out.append(Float(step(byte & 0x0F, &predictor, &index)) / 32768)
                    out.append(Float(step(byte >> 4, &predictor, &index)) / 32768)
                }
            }
        }
        return out
    }

    @inline(__always)
    private static func step(_ nibble: UInt8, _ predictor: inout Int32, _ index: inout Int) -> Int16 {
        let code = Int(nibble)
        let step = stepTable[index]
        var diff = step >> 3
        if code & 4 != 0 { diff += step }
        if code & 2 != 0 { diff += step >> 1 }
        if code & 1 != 0 { diff += step >> 2 }
        predictor += code & 8 != 0 ? -diff : diff
        predictor = min(max(predictor, -32768), 32767)
        index = min(max(index + indexTable[code], 0), 88)
        return Int16(predictor)
    }

    /// 0…100 的音量，给设备屏幕上的录音动画用。-60 dB 以下算 0。
    public static func level(_ samples: [Float]) -> Int {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        guard power > 0 else { return 0 }
        let db = 10 * log10(power)
        return Int(min(max((db + 60) / 60 * 100, 0), 100))
    }
}

/// 16 kHz → 48 kHz：每个输入样本出 3 个输出样本，用加窗 sinc 低通滤波（多相实现，每相 16 个系数）。
/// 有状态，一路声音用一个；换一次说话（比如重新开麦）调用 `reset()`。
public struct Upsampler3 {
    private static let taps = 16
    private static let phases: [[Float]] = {
        let factor = 3
        let length = taps * factor
        let center = Double(length - 1) / 2
        var prototype = [Double](repeating: 0, count: length)
        for n in 0..<length {
            let x = (Double(n) - center) / Double(factor)
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            // Blackman 窗
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(n) / Double(length - 1))
                + 0.08 * cos(4 * Double.pi * Double(n) / Double(length - 1))
            prototype[n] = sinc * w
        }
        return (0..<factor).map { phase in
            let coefficients = stride(from: phase, to: length, by: factor).map { prototype[$0] }
            let sum = coefficients.reduce(0, +)
            return coefficients.map { Float($0 / sum) }   // 每相增益为 1
        }
    }()

    private var history = [Float](repeating: 0, count: taps)
    private var position = 0

    public init() {}

    public mutating func reset() {
        history = [Float](repeating: 0, count: Self.taps)
        position = 0
    }

    public mutating func process(_ input: [Float]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(input.count * 3)
        let taps = Self.taps
        for sample in input {
            position = (position + taps - 1) % taps
            history[position] = sample
            for phase in Self.phases {
                var sum: Float = 0
                for k in 0..<taps {
                    sum += phase[k] * history[(position + k) % taps]
                }
                out.append(sum)
            }
        }
        return out
    }
}
