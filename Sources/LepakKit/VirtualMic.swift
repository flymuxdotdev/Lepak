import CoreAudio
import Foundation

/// Lepak 麦克风（虚拟麦克风驱动 LepakMic.driver，见 Driver/LepakMic）在 Lepak 这一侧的部分。
///
/// - 看驱动装没装：系统里有没有「Lepak 麦克风」。
/// - 看有没有程序在用它（比如 Typeless 开始录音）：`onListening`。只在这时候让 AI Passport 开麦。
/// - 往隐藏的「输入端」写声音（48 kHz 单声道），驱动转给「Lepak 麦克风」。
///
/// 写声音时自己留一点缓冲，抵消蓝牙一包一包到达的抖动：攒够 `primeFrames` 再开始放，放空了重新攒；
/// 攒得太多（超过 `maxFrames`）就丢掉最旧的，免得延迟越来越大。
/// 不需要「麦克风」权限：Lepak 只往输出设备里写，不读任何麦克风。
public final class VirtualMic: @unchecked Sendable {
    public static let micUID = "local.lepak.mic"
    public static let feedUID = "local.lepak.mic.feed"
    static let sampleRate = 48_000.0

    /// 驱动装上 / 卸掉（在内部队列上调用）。
    public var onInstalled: ((Bool) -> Void)?
    /// 有程序开始 / 停止读 Lepak 麦克风（在内部队列上调用）。
    public var onListening: ((Bool) -> Void)?
    public var onNote: ((String) -> Void)?

    private let queue = DispatchQueue(label: "local.lepak.virtualmic")
    // 以下只在 queue 上读写。
    private var micID = AudioObjectID(kAudioObjectUnknown)
    private var feedID = AudioObjectID(kAudioObjectUnknown)
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var ioProc: AudioDeviceIOProcID?
    private var feeding = false
    private var installed = false
    private var listening = false

    private let buffer = SampleBuffer(capacity: 48_000 * 2)

    public init() {}

    public func start() {
        queue.async { [self] in
            var address = Self.address(kAudioHardwarePropertyDevices)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            devicesBlock = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            refresh()
        }
    }

    /// 是否装了驱动（任意线程）。
    public var isInstalled: Bool { queue.sync { installed } }

    /// 是否有程序在读 Lepak 麦克风（任意线程）。
    public var isListening: Bool { queue.sync { listening } }

    /// 现在缓冲里有多少秒还没放出去的声音（任意线程）。
    public var bufferedSeconds: Double { Double(buffer.count) / Self.sampleRate }

    /// 上次 `clear()` 以来放空过几次（声音没跟上，补了静音）。只用来写日志。
    public var underruns: Int { buffer.underruns }

    /// 写入 48 kHz 单声道声音（任意线程）。还没开始放的时候先攒着。
    public func push(_ samples: [Float]) {
        buffer.push(samples)
    }

    /// 丢掉还没放出去的声音。
    public func clear() {
        buffer.clear()
    }

    /// 开始 / 停止往输入端放声音。
    public func setFeeding(_ on: Bool) {
        queue.async { [self] in
            feeding = on
            updateIO()
        }
    }

    // MARK: 设备

    private func refresh() {
        let mic = Self.device(uid: Self.micUID)
        let feed = Self.device(uid: Self.feedUID)
        if mic != micID {
            if let listenerBlock, micID != kAudioObjectUnknown {
                var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                AudioObjectRemovePropertyListenerBlock(micID, &address, queue, listenerBlock)
            }
            micID = mic
            if mic != kAudioObjectUnknown {
                var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.checkListening() }
                listenerBlock = block
                AudioObjectAddPropertyListenerBlock(mic, &address, queue, block)
            }
        }
        if feed != feedID {
            stopIO()
            feedID = feed
        }
        let nowInstalled = mic != kAudioObjectUnknown && feed != kAudioObjectUnknown
        if nowInstalled != installed {
            installed = nowInstalled
            onNote?(nowInstalled ? "Lepak 麦克风：驱动已就绪" : "Lepak 麦克风：没有找到驱动")
            onInstalled?(nowInstalled)
        }
        checkListening()
        updateIO()
    }

    private func checkListening() {
        var running: UInt32 = 0
        if micID != kAudioObjectUnknown {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(micID, &address, 0, nil, &size, &running) != noErr { running = 0 }
        }
        let now = running != 0
        guard now != listening else { return }
        listening = now
        onListening?(now)
    }

    // MARK: 放声音

    private func updateIO() {
        if feeding && installed {
            startIO()
        } else {
            stopIO()
        }
    }

    private func startIO() {
        guard ioProc == nil, feedID != kAudioObjectUnknown else { return }
        let buffer = self.buffer
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, feedID, nil) { _, _, _, output, _ in
            // 实时线程：只拷贝，不分配、不等待。
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            for audio in buffers {
                guard let data = audio.mData else { continue }
                let frames = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
                buffer.pop(into: data.assumingMemoryBound(to: Float.self), count: frames)
            }
        }
        guard status == noErr, let procID else {
            onNote?("Lepak 麦克风：打不开输入端（\(status)）")
            return
        }
        guard AudioDeviceStart(feedID, procID) == noErr else {
            AudioDeviceDestroyIOProcID(feedID, procID)
            onNote?("Lepak 麦克风：输入端启动失败")
            return
        }
        ioProc = procID
    }

    private func stopIO() {
        guard let procID = ioProc else { return }
        AudioDeviceStop(feedID, procID)
        AudioDeviceDestroyIOProcID(feedID, procID)
        ioProc = nil
    }

    // MARK: Core Audio 小工具

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 按 UID 找设备；输入端是隐藏设备，找不到时再从驱动自己的设备列表里找。
    static func device(uid: String) -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var cfUID = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        if status == noErr, id != kAudioObjectUnknown { return id }
        for candidate in pluginDevices() where deviceUID(candidate) == uid {
            return candidate
        }
        return AudioObjectID(kAudioObjectUnknown)
    }

    private static func pluginDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var plugin = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var bundleID = "local.lepak.mic" as CFString
        let status = withUnsafePointer(to: &bundleID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &plugin)
        }
        guard status == noErr, plugin != kAudioObjectUnknown else { return [] }
        var listAddress = Self.address(kAudioPlugInPropertyDeviceList)
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(plugin, &listAddress, 0, nil, &listSize) == noErr, listSize > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(plugin, &listAddress, 0, nil, &listSize, &devices) == noErr else { return [] }
        return devices
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// 放声音用的缓冲区：一边（蓝牙队列）写，一边（音频实时线程）读，用一把很短的锁。
final class SampleBuffer: @unchecked Sendable {
    /// 攒够 100 毫秒才开始放（蓝牙到包的抖动实测超过 40 毫秒）；超过 400 毫秒就丢掉最旧的，留 200 毫秒。
    static let primeFrames = 4_800
    static let maxFrames = 19_200
    /// 没有声音可放时补的底噪幅度（约 -90 dB）。完全的数字静音会被 Typeless 这类软件当成坏掉的麦克风。
    static let ditherAmplitude: Float = 3e-5

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var readIndex = 0
    private var stored = 0
    private var primed = false
    private var underrunCount = 0
    private var noiseState: UInt32 = 0x1234_5678

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var count: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return stored
    }

    var underruns: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return underrunCount
    }

    func clear() {
        os_unfair_lock_lock(lock)
        readIndex = 0
        stored = 0
        primed = false
        underrunCount = 0
        os_unfair_lock_unlock(lock)
    }

    func push(_ samples: [Float]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        for sample in samples {
            if stored == capacity {
                readIndex = (readIndex + 1) % capacity
                stored -= 1
            }
            storage[(readIndex + stored) % capacity] = sample
            stored += 1
        }
        if stored > Self.maxFrames {
            let drop = stored - Self.maxFrames / 2
            readIndex = (readIndex + drop) % capacity
            stored -= drop
        }
    }

    /// 取 count 个样本写进 out；不够的地方补极轻的底噪。
    func pop(into out: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if !primed && stored >= Self.primeFrames { primed = true }
        var written = 0
        if primed {
            let take = min(count, stored)
            for i in 0..<take {
                out[i] = storage[(readIndex + i) % capacity]
            }
            readIndex = (readIndex + take) % capacity
            stored -= take
            written = take
            if stored == 0 {   // 放空了：重新攒
                primed = false
                if take < count { underrunCount += 1 }
            }
        }
        for i in written..<count {
            // xorshift 伪随机数做底噪：实时线程里不分配、不加锁以外的等待。
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 17
            noiseState ^= noiseState << 5
            out[i] = (Float(noiseState) / Float(UInt32.max) * 2 - 1) * Self.ditherAmplitude
        }
    }
}
