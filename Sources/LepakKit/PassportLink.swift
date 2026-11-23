import CoreBluetooth
import Foundation

/// AI Passport 上的三个键。
public enum PassportButton: String, CaseIterable, Sendable {
    case ok, up, down
}

public struct PassportBattery: Sendable, Equatable {
    /// 读不到时为 nil。
    public var percent: Int?
    public var millivolts: Int?
    public var charging: Bool
}

/// 配对过的设备连上了却不肯握手：两边的配对记录对不上。
public enum PassportRejection: Sendable, Equatable {
    /// 设备不认这台 Mac（多半是 Mac 上删了配对，设备还记着）：在设备上长按 ▼ 打开配对，再重新配对。
    case macNotAccepted
    /// 设备那边清掉了配对，Mac 还记着旧的（系统报「对方删除了配对信息」，不会自己重配）：
    /// 先在「系统设置 → 蓝牙」里删掉这台设备，再重新配对。
    case removedOnDevice
}

public enum PassportLinkState: Sendable, Equatable {
    /// 蓝牙关着、没允许 Lepak 用蓝牙、这台 Mac 不支持低功耗蓝牙。
    case bluetoothOff, unauthorized, unsupported
    /// 在找设备，或者等它回到范围内。
    case searching
    /// 蓝牙连上了，在握手。
    case connecting
    /// 握手成功，设备在线。`firmware` 是固件版本。
    case online(firmware: String)
}

/// 通过低功耗蓝牙连接刷了社区固件（InputBetter / FoloVibe Key，协议 v1）的 FoloToy AI Passport。
///
/// 协议见社区项目的 docs/protocol.md：
/// - 一个 GATT 服务，Events（设备 → Mac，通知）和 Commands（Mac → 设备，写入）两个特征，内容都是一行一条的扁平 JSON。
/// - Mac 发 `hello` 握手，之后每 5 秒发 `ping`；设备 15 秒没收到任何命令就当 Mac 离线，离线时不报按键。
/// - 设备报按键原始事件：`down`（按下）、`up`（松开）、`long`（按住 1 秒）。单击、双击、长按由 Lepak 自己判断，所以只用 down / up。
/// - Mac 用 `config`、`state`、`keys` 控制屏幕：熄屏时间、显示的页面、三个键旁边的提示图标。
///
/// 只接收设备自己上报的按键，不碰电脑键盘，不需要「输入监控」。
/// 设备的麦克风只在 Lepak 要的时候开（`setMic`，有程序在用 Lepak 麦克风时），不让设备按 OK 时自己开麦（`config` 里 `mic` 为 0）。
/// 一台设备同时只能被一个程序连着：FoloVibe Key / InputBetter 的 App 开着时，Lepak 连不上。
public final class PassportLink: NSObject, @unchecked Sendable {
    // CBUUID 创建后不再改动，只读。
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "B5E10001-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    nonisolated(unsafe) static let eventsUUID = CBUUID(string: "B5E10002-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    nonisolated(unsafe) static let commandsUUID = CBUUID(string: "B5E10003-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    nonisolated(unsafe) static let audioUUID = CBUUID(string: "B5E10004-5A6C-4E8B-9F2D-7C3A1E0B4D21")

    // 回调在内部队列上调用，start() 之前设好。
    public var onState: ((PassportLinkState) -> Void)?
    public var onBattery: ((PassportBattery) -> Void)?
    /// 键按下（true）或松开（false）。断线时还按着的键会补一个松开。
    public var onButton: ((PassportButton, Bool) -> Void)?
    public var onNote: ((String) -> Void)?
    /// 每次握手报一次设备上的固件版本（`0.1.3`）和构建标识（固件文件哈希的前 8 位，老固件可能没有）。
    public var onFirmware: ((_ version: String, _ build: String?) -> Void)?
    /// 开麦后设备传来的声音：16 kHz 单声道，-1…1（每 20 毫秒一次）。
    public var onAudio: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "local.lepak.passport")
    // 以下只在 queue 上读写。
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commands: CBCharacteristic?
    private var audio: CBCharacteristic?
    /// Lepak 要设备开麦（有程序在用 Lepak 麦克风）。断线重连后照这个恢复。
    private var micWanted = false
    private var audioBlocks = 0
    private var buffer = Data()
    private var state = PassportLinkState.searching
    private var online = false
    private var lastHeard = DispatchTime.now()
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var lastBoot: String?
    private var lastSeq = -1
    private var held: Set<PassportButton> = []
    private var keyIcons: [String: String] = [:]
    private var screenOffSeconds = 60
    private var stopped = false
    /// 配对模式（「添加设备」第二步、「重新配对」）：去连附近的设备、让它配对。平时只连配对过的那一台。
    private var pairing = false
    /// 配对模式里连不上或被拒绝的设备（多半是别人的）：这个时刻之前不再试。
    private var cooldown: [UUID: DispatchTime] = [:]
    /// 配对模式里扫到的设备和信号强度：挑信号最强的（最可能是用户手上那台）去连。
    private var candidates: [UUID: Candidate] = [:]
    private var choosing = false
    private var connectTimeout: DispatchWorkItem?

    private struct Candidate {
        let peripheral: CBPeripheral
        let rssi: Int
        let seen: DispatchTime
    }

    /// 配对过的那台设备（握手成功过的）。平时只连它；Lepak 的固件那边也只认配对过的 Mac。
    private static let rememberedKey = "passport.peripheral"
    private static let pingInterval: TimeInterval = 5
    /// 这么久没收到设备的任何消息，就当连接已经坏了，断开重连。设备那边是 15 秒。
    private static let silenceLimit: UInt64 = 15_000_000_000
    /// 握手之前（设备在等用户在 Mac 上输配对码，不说话）放宽到这么久；设备那边配对窗口是 90 秒。
    private static let pairingSilenceLimit: UInt64 = 95_000_000_000
    /// 配对模式里一台设备连不上 / 没配对上，隔这么久再试。
    private static let pairingCooldown: TimeInterval = 20
    /// 配对模式里连一台设备最多等这么久（设备在广播，正常一两秒就连上）。
    private static let connectAttemptLimit: TimeInterval = 8

    /// 有没有配对过的设备：`start()` 时报一次，之后变了再报（在内部队列上调用）。
    public var onPaired: ((Bool) -> Void)?
    /// 设备固件有没有配对保护（Lepak 固件的 hello 带 `"pair":1`），每次握手报一次。
    public var onPairProtection: ((Bool) -> Void)?
    /// 配对过的设备拒绝握手（见 `PassportRejection`）；握手成功或开始重新配对时报 nil。
    public var onRejection: ((PassportRejection?) -> Void)?

    /// 平时（不在配对模式）连上配对过的设备、却没握手就断开的次数，连续两次就当是被拒绝了。
    private var handshakeFailures = 0
    private var rejection: PassportRejection? {
        didSet { if rejection != oldValue { onRejection?(rejection) } }
    }
    /// 被拒绝时别一直秒重连（设备那边每次都要算一遍，费电），隔这么久再试。
    private static let rejectedRetryDelay: TimeInterval = 10

    private var pairedID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:)) }
        set {
            guard newValue != pairedID else { return }
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: Self.rememberedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
            }
            onPaired?(newValue != nil)
        }
    }

    /// 开始找设备、连上。`stop()` 之后再调用会重新开始（用户把 AI Passport 移除后又添加回来）。
    public func start() {
        queue.async { [self] in
            stopped = false
            onPaired?(pairedID != nil)
            guard central == nil else {
                connectOrScan()
                return
            }
            // 不弹系统的「打开蓝牙」提示，蓝牙关着时设置里会写。
            central = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    /// 退出前、或者用户移除了这台设备时调用：告诉设备 Mac 离线（屏幕切到离线页），再断开、停止扫描。
    public func stop() {
        queue.sync {
            stopped = true
            if online { send(["cmd": "bye"]) }
            timer?.cancel()
            timer = nil
            connectTimeout?.cancel()
            candidates.removeAll()
            if central?.isScanning == true { central?.stopScan() }
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            setState(.searching)
        }
    }

    /// 打开 / 关闭配对模式（「添加设备」第二步、「重新配对」时打开）。
    /// 开着时去连附近信号最强的一台；Lepak 固件会要求配对，Mac 弹出系统的蓝牙配对窗口，输入设备屏幕上的 6 位数字。
    /// 握手成功的那台就是配对过的设备，以后只连它。关掉时断开还没配对上的那台。
    public func setPairing(_ on: Bool) {
        queue.async { [self] in
            guard on != pairing else { return }
            pairing = on
            handshakeFailures = 0
            rejection = nil
            cooldown.removeAll()
            candidates.removeAll()
            connectTimeout?.cancel()
            if !on, let peripheral, peripheral.identifier != pairedID {
                central?.cancelPeripheralConnection(peripheral)
                resetLink()
                self.peripheral = nil
            }
            if central?.isScanning == true { central?.stopScan() }
            connectOrScan()
        }
    }

    /// 「重新配对」：断开并忘掉配对过的那台，之后在配对模式里配上的那台成为新的。
    public func forgetPaired() {
        queue.async { [self] in
            if online { send(["cmd": "bye"]) }
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            resetLink()
            peripheral = nil
            pairedID = nil
            handshakeFailures = 0
            rejection = nil
            setState(.searching)
            connectOrScan()
        }
    }

    /// 三个键旁边的提示图标（键：`ok` / `up` / `down`，值：协议里的图标 id，空字符串隐藏）。设置改了随时调用。
    public func setKeyIcons(_ icons: [PassportButton: String]) {
        queue.async { [self] in
            let next = Dictionary(uniqueKeysWithValues: icons.map { ($0.key.rawValue, $0.value) })
            guard next != keyIcons else { return }
            keyIcons = next
            if online { sendKeys() }
        }
    }

    /// 开 / 关设备的麦克风。开着时屏幕显示「录音中」，声音通过 `onAudio` 送出；关掉回到待机页。
    public func setMic(_ on: Bool) {
        queue.async { [self] in
            guard on != micWanted else { return }
            micWanted = on
            audioBlocks = 0
            if online { sendMicState() }
        }
    }

    // MARK: 连接

    private func setState(_ next: PassportLinkState) {
        guard next != state else { return }
        state = next
        onState?(next)
    }

    /// 平时：只连配对过的那台（先按记住的身份直接连，同时扫描只认它）。别的 AI Passport 一律不理。
    /// 配对模式：扫描，挑信号最强、没被拒过的一台去连（见 `chooseCandidate`）。
    private func connectOrScan() {
        guard let central, central.state == .poweredOn, !stopped else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        setState(.searching)
        if pairing {
            if !central.isScanning {
                // 重复上报：被拒过的设备冷却完了还能再被扫到，信号强度也随时更新。
                central.scanForPeripherals(withServices: [Self.serviceUUID],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
            scheduleChoice()
            return
        }
        guard let id = pairedID else {
            // 还没配对过：不连、也不扫描，不去碰附近别人的设备。等「添加设备」或「重新配对」。
            if central.isScanning { central.stopScan() }
            return
        }
        if peripheral?.identifier != id, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            adopt(known)
        }
        if let peripheral, peripheral.identifier == id {
            // 没有超时：设备不在范围内时一直等着，回来就自动连上。
            central.connect(peripheral)
        }
        if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.serviceUUID])
        }
    }

    /// 配对模式：等一会儿让附近的几台都扫到，再挑。
    private func scheduleChoice() {
        guard pairing, !choosing else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        choosing = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.chooseCandidate() }
    }

    private func chooseCandidate() {
        choosing = false
        guard pairing, !stopped, let central else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        let now = DispatchTime.now()
        let usable = candidates.values.filter {
            now.uptimeNanoseconds - $0.seen.uptimeNanoseconds < 5_000_000_000
                && (cooldown[$0.peripheral.identifier].map { $0 <= now } ?? true)
        }
        guard let best = usable.max(by: { $0.rssi < $1.rssi }) else { return }
        note("配对：连信号最强的一台（\(best.rssi) dBm）")
        adopt(best.peripheral)
        central.connect(best.peripheral)
        armConnectTimeout(best.peripheral.identifier)
    }

    /// 配对模式里一台设备迟迟连不上（走远了、被别的 Mac 占着）：放弃它，换下一台。
    private func armConnectTimeout(_ id: UUID) {
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let peripheral, peripheral.identifier == id, peripheral.state == .connecting else { return }
            note("配对：这台连不上，换下一台")
            cooldown[id] = .now() + Self.pairingCooldown
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            connectOrScan()
        }
        connectTimeout = work
        queue.asyncAfter(deadline: .now() + Self.connectAttemptLimit, execute: work)
    }

    private func adopt(_ next: CBPeripheral) {
        if let peripheral, peripheral.identifier != next.identifier {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = next
        next.delegate = self
    }

    private func resetLink() {
        online = false
        commands = nil
        audio = nil
        buffer.removeAll()
        timer?.cancel()
        timer = nil
        for button in held { onButton?(button, false) }
        held.removeAll()
    }

    private func startTimer() {
        timer?.cancel()
        ticks = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        ticks += 1
        let now = DispatchTime.now()
        // 握手之前设备可能在等用户输配对码（什么都不发），多等一会儿。
        let limit = online ? Self.silenceLimit : Self.pairingSilenceLimit
        if now.uptimeNanoseconds - lastHeard.uptimeNanoseconds > limit {
            note(online ? "设备 15 秒没有回应，断开重连" : "一直没有握手成功（配对没完成？），断开重连")
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            return
        }
        if online {
            send(["cmd": "ping"])
            // 每 5 分钟重发一次 config，校准设备上的时钟。
            if ticks % 60 == 0 { sendConfig() }
        } else {
            // 握手还没成功（比如设备刚开机）：再发一次 hello。
            sendHello()
        }
    }

    // MARK: 收

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
        // 单行最长 511 字节，超过说明丢了换行，清掉重新对齐。
        if buffer.count > 1024 { buffer.removeAll() }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["t"] as? String
        else { return }
        lastHeard = .now()
        switch type {
        case "hello":
            let version = object["ver"] as? String ?? "?"
            let firmware = object["fw"] as? String ?? "?"
            let firstTime = !online
            online = true
            if firstTime { note("握手成功：固件 \(firmware) \(version)") }
            handshakeFailures = 0
            rejection = nil
            // 握手成功的就是配对过的设备：记住它，以后平时只连它。
            if let id = peripheral?.identifier, id != pairedID {
                pairedID = id
                note("记住了这台设备，以后只连它")
            }
            setState(.online(firmware: version))
            onFirmware?(version, object["build"] as? String)
            onPairProtection?((object["pair"] as? Int) == 1)
            sendConfig()
            sendMicState()
            sendKeys()
        case "key":
            handleKey(object)
        case "bat":
            let soc = object["soc"] as? Int
            let mv = object["mv"] as? Int
            let charging = (object["chg"] as? Int ?? 0) == 1
            onBattery?(PassportBattery(percent: soc.flatMap { $0 >= 0 ? $0 : nil },
                                       millivolts: mv.flatMap { $0 >= 0 ? $0 : nil },
                                       charging: charging))
        case "wake":
            // 设备在离线页按了 OK：请求重新握手。
            note("设备请求重新握手")
            sendHello()
        default:
            break
        }
    }

    private func handleKey(_ object: [String: Any]) {
        guard let name = object["k"] as? String, let button = PassportButton(rawValue: name),
              let event = object["e"] as? String
        else { return }
        // 按 (boot, seq) 去重：boot 每次上电随机，seq 本次上电单调递增。
        if let seq = object["seq"] as? Int {
            let boot = object["boot"] as? String ?? ""
            if boot == lastBoot, seq <= lastSeq { return }
            lastBoot = boot
            lastSeq = seq
        }
        switch event {
        case "down":
            if held.contains(button) {
                // 上一次的松开丢了：先补一个松开。
                onButton?(button, false)
            }
            held.insert(button)
            onButton?(button, true)
        case "up":
            guard held.remove(button) != nil else { return }
            onButton?(button, false)
        default:
            break   // long：长按由 Lepak 自己按设置的时长判断
        }
    }

    /// 声音帧：`FF FE type seq len_lo len_hi` + 负载，蓝牙上一次通知一帧，type 0x02 是 IMA ADPCM。
    private func receivedAudio(_ data: Data) {
        guard micWanted else { return }
        var offset = data.startIndex
        while data.endIndex - offset >= 6 {
            guard data[offset] == 0xFF, data[offset + 1] == 0xFE else {
                offset += 1
                continue
            }
            let type = data[offset + 2]
            let length = Int(data[offset + 4]) | Int(data[offset + 5]) << 8
            let start = offset + 6
            guard length > 0, data.endIndex - start >= length else { return }
            if type == 0x02 {
                let samples = PassportADPCM.decode(data.subdata(in: start..<(start + length)))
                if !samples.isEmpty {
                    onAudio?(samples)
                    // 每 60 毫秒给屏幕发一次音量，驱动录音动画。
                    audioBlocks += 1
                    if audioBlocks % 3 == 0 { send(["cmd": "level", "v": PassportADPCM.level(samples)]) }
                }
            }
            offset = start + length
        }
    }

    // MARK: 发

    private func sendHello() {
        send(["cmd": "hello"])
    }

    private func sendConfig() {
        let clock = Int(Date().timeIntervalSince1970) + TimeZone.current.secondsFromGMT()
        send(["cmd": "config", "mic": 0, "engine": "Lepak", "screen_off": screenOffSeconds,
              "clock": clock, "sound": 0])
    }

    /// 设备只在「录音中」页面保持开麦，切到别的页面就停麦，所以开麦时同时切到 rec。
    private func sendMicState() {
        if micWanted {
            send(["cmd": "mic", "on": 1])
            send(["cmd": "state", "st": "rec", "mode": "dict", "msg": ""])
        } else {
            send(["cmd": "mic", "on": 0])
            send(["cmd": "state", "st": "idle", "mode": "dict", "msg": ""])
        }
    }

    private func sendKeys() {
        var command: [String: Any] = ["cmd": "keys"]
        for button in PassportButton.allCases {
            command[button.rawValue] = keyIcons[button.rawValue] ?? ""
        }
        send(command)
    }

    private func send(_ command: [String: Any]) {
        guard let peripheral, let commands, peripheral.state == .connected,
              var data = try? JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        let type: CBCharacteristicWriteType = commands.properties.contains(.write) ? .withResponse : .withoutResponse
        let chunk = max(20, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            peripheral.writeValue(data.subdata(in: offset..<end), for: commands, type: type)
            offset = end
        }
    }

    private func note(_ line: String) {
        onNote?("AI Passport：\(line)")
    }
}

// MARK: CoreBluetooth 回调（都在 queue 上）

extension PassportLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectOrScan()
        case .poweredOff:
            resetLink()
            setState(.bluetoothOff)
        case .unauthorized:
            setState(.unauthorized)
        case .unsupported:
            setState(.unsupported)
        default:
            setState(.searching)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped else { return }
        let id = peripheral.identifier
        if pairing {
            if let until = cooldown[id], until > .now() { return }
            let rssi = RSSI.intValue == 127 ? -100 : RSSI.intValue     // 127 表示读不到
            candidates[id] = Candidate(peripheral: peripheral, rssi: rssi, seen: .now())
            scheduleChoice()
            return
        }
        // 平时只认配对过的那台：附近别人的 AI Passport 不去连。
        guard id == pairedID else { return }
        if let current = self.peripheral, current.identifier == id, current.state != .disconnected { return }
        note("找到配对过的设备，正在连接")
        adopt(peripheral)
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        connectTimeout?.cancel()
        central.stopScan()
        setState(.connecting)
        lastHeard = .now()
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        note("连接失败：\(error?.localizedDescription ?? "未知原因")")
        if pairing { cooldown[peripheral.identifier] = .now() + Self.pairingCooldown }
        if !pairing, Self.peerRemovedPairing(error) { rejection = .removedOnDevice }
        let delay: TimeInterval = rejection == nil ? 2 : Self.rejectedRetryDelay
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connectOrScan() }
    }

    /// 系统说「对方删除了配对信息」（CBError.peerRemovedPairingInformation = 14）：设备清掉了配对，Mac 还记着。
    private static func peerRemovedPairing(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == CBErrorDomain && error.code == 14
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let wasOnline = online
        resetLink()
        if stopped { return }
        if wasOnline { note("蓝牙断开\(error.map { "：\($0.localizedDescription)" } ?? "")") }
        if pairing, !wasOnline {
            // 没握手就断了：设备拒绝了（配过别的 Mac、没开配对），或者用户取消了配对窗口。先换别的设备试。
            note("配对：这台没配上，换下一台")
            cooldown[peripheral.identifier] = .now() + Self.pairingCooldown
        }
        if !pairing, !wasOnline {
            // 平时连的就是配对过的那台，它却不肯握手：两边的配对记录对不上。
            if Self.peerRemovedPairing(error) {
                rejection = .removedOnDevice
            } else {
                handshakeFailures += 1
                if handshakeFailures >= 2, rejection == nil {
                    note("设备不认这台 Mac 了（Mac 上的配对可能被删了），需要重新配对")
                    rejection = .macNotAccepted
                }
            }
        }
        if rejection != nil, !pairing {
            setState(.searching)
            queue.asyncAfter(deadline: .now() + Self.rejectedRetryDelay) { [weak self] in self?.connectOrScan() }
            return
        }
        setState(.searching)
        connectOrScan()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            note("设备上没有 Lepak 认识的服务，可能还是官方固件")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.eventsUUID, Self.commandsUUID, Self.audioUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let events = characteristics.first(where: { $0.uuid == Self.eventsUUID }),
              let commands = characteristics.first(where: { $0.uuid == Self.commandsUUID })
        else {
            note("设备的服务不完整，断开")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        self.commands = commands
        peripheral.setNotifyValue(true, for: events)
        // 声音通知一直订阅着：设备只在开麦时才发。
        if let audio = characteristics.first(where: { $0.uuid == Self.audioUUID }) {
            self.audio = audio
            peripheral.setNotifyValue(true, for: audio)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if characteristic.uuid == Self.audioUUID {
            if !characteristic.isNotifying {
                note("订阅声音失败：\(error?.localizedDescription ?? "未知原因")")
            }
            return
        }
        guard characteristic.uuid == Self.eventsUUID else { return }
        guard characteristic.isNotifying else {
            note("订阅按键通知失败：\(error?.localizedDescription ?? "未知原因")")
            return
        }
        lastHeard = .now()
        sendHello()
        startTimer()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Self.eventsUUID {
            received(value)
        } else if characteristic.uuid == Self.audioUUID {
            receivedAudio(value)
        }
    }
}
