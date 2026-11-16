import Foundation
import LepakKit

/// AI Passport 当麦克风：有程序（比如 Typeless）在用「Lepak 麦克风」时，让设备开麦，把声音送进 Lepak 麦克风；
/// 不用了就关掉，屏幕回到待机页。
///
/// 时机：
/// - 按 OK（设成 Fn）时先开麦，不等 Typeless 打开麦克风，免得开头几个字丢掉。2.5 秒内没人用就关掉。
/// - Typeless 开始读 Lepak 麦克风：开麦（已经开了就接着用），开始放声音。
/// - Typeless 停止读：停止放声音，关麦。
/// - 录音中再按 OK 停止时，缓冲里还有一点没放出去的声音，先等它放完再发 Fn（见 `okDelay`），免得截掉最后一个字。
final class PassportMic: @unchecked Sendable {
    enum Status: Equatable {
        /// 没装 Lepak 麦克风驱动。
        case notInstalled
        /// 装好了，没人在用。
        case ready
        /// 有程序在用 Lepak 麦克风。
        case listening
    }

    var onStatus: ((Status) -> Void)?
    var onNote: ((String) -> Void)?

    private let link: PassportLink
    private let mic = VirtualMic()
    private let queue = DispatchQueue(label: "local.lepak.passport.mic")
    // 以下只在 queue 上读写。
    private var installed = false
    private var listening = false
    private var micOn = false
    private var prestartSerial = 0
    private var upsampler = Upsampler3()
    private var okDelayValue: TimeInterval = 0
    /// 这次开麦收到了多少样本（16 kHz），只用来写日志。
    private var receivedSamples = 0
    /// 这次开麦的音量：最大的 20 毫秒块和所有块的平均功率（0…1），只用来写日志。
    private var peakPower: Float = 0
    private var powerSum: Float = 0
    private var blocks = 0

    private static let prestartTimeout: TimeInterval = 2.5

    init(link: PassportLink) {
        self.link = link
    }

    func start() {
        mic.onNote = { [weak self] line in self?.onNote?(line) }
        mic.onInstalled = { [weak self] installed in
            guard let self else { return }
            queue.async {
                self.installed = installed
                self.reportStatus()
            }
        }
        mic.onListening = { [weak self] on in self?.listeningChanged(on) }
        link.onAudio = { [weak self] samples in self?.audio(samples) }
        mic.start()
    }

    /// OK 键按下（单击设成了 Fn）：提前开麦。
    func voiceKeyPressed() {
        queue.async { [self] in
            guard installed, !listening, !micOn else { return }
            turnOn()
            prestartSerial += 1
            let serial = prestartSerial
            queue.asyncAfter(deadline: .now() + Self.prestartTimeout) { [self] in
                guard serial == prestartSerial, !listening, micOn else { return }
                turnOff()
                onNote?("Lepak 麦克风：按了 OK 但没有程序来读麦克风，已关麦")
            }
        }
    }

    /// OK 键的按下、松开要晚多久再交给按键处理。按下时决定，松开用同一个值，按住的时长不变。
    /// 只有录音中（正在放声音）按下才延后：等缓冲里的声音放完，最多 0.5 秒。
    func okDelay(pressed: Bool) -> TimeInterval {
        queue.sync {
            if pressed {
                okDelayValue = listening ? min(mic.bufferedSeconds + 0.1, 0.5) : 0
            }
            return okDelayValue
        }
    }

    private func listeningChanged(_ on: Bool) {
        queue.async { [self] in
            guard on != listening else { return }
            listening = on
            if on {
                prestartSerial += 1   // 作废提前开麦的超时
                if !micOn { turnOn() }
                mic.setFeeding(true)
                onNote?("Lepak 麦克风：开始被使用，设备开麦")
            } else {
                mic.setFeeding(false)
                let seconds = Double(receivedSamples) / 16_000
                let peak = peakPower > 0 ? 10 * log10(peakPower) : -120
                let average = blocks > 0 && powerSum > 0 ? 10 * log10(powerSum / Float(blocks)) : -120
                onNote?(String(format: "Lepak 麦克风：停止使用，设备关麦（这次收到 %.1f 秒声音，放空 %d 次，音量最大 %.0f dB、平均 %.0f dB）",
                               seconds, mic.underruns, peak, average))
                turnOff()
            }
            reportStatus()
        }
    }

    private func turnOn() {
        micOn = true
        receivedSamples = 0
        peakPower = 0
        powerSum = 0
        blocks = 0
        upsampler.reset()
        mic.clear()
        link.setMic(true)
    }

    private func turnOff() {
        micOn = false
        link.setMic(false)
        mic.clear()
    }

    private func audio(_ samples: [Float]) {
        queue.async { [self] in
            guard micOn else { return }
            receivedSamples += samples.count
            let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(samples.count, 1))
            peakPower = max(peakPower, power)
            powerSum += power
            blocks += 1
            mic.push(upsampler.process(samples))
        }
    }

    private func reportStatus() {
        onStatus?(!installed ? .notInstalled : listening ? .listening : .ready)
    }
}
