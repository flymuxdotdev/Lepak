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
/// 只接收设备自己上报的按键，不碰电脑键盘，不需要「输入监控」。不开设备的麦克风（`config` 里 `mic` 为 0）。
/// 一台设备同时只能被一个程序连着：FoloVibe Key / InputBetter 的 App 开着时，Lepak 连不上。
public final class PassportLink: NSObject, @unchecked Sendable {
    // CBUUID 创建后不再改动，只读。
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "B5E10001-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    nonisolated(unsafe) static let eventsUUID = CBUUID(string: "B5E10002-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    nonisolated(unsafe) static let commandsUUID = CBUUID(string: "B5E10003-5A6C-4E8B-9F2D-7C3A1E0B4D21")

    // 回调在内部队列上调用，start() 之前设好。
    public var onState: ((PassportLinkState) -> Void)?
    public var onBattery: ((PassportBattery) -> Void)?
    /// 键按下（true）或松开（false）。断线时还按着的键会补一个松开。
    public var onButton: ((PassportButton, Bool) -> Void)?
    public var onNote: ((String) -> Void)?

    private let queue = DispatchQueue(label: "local.lepak.passport")
    // 以下只在 queue 上读写。
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commands: CBCharacteristic?
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

    /// 上次连上的设备，下次启动先直接连它（蓝牙地址不变就不用重新扫描）。
    private static let rememberedKey = "passport.peripheral"
    private static let pingInterval: TimeInterval = 5
    /// 这么久没收到设备的任何消息，就当连接已经坏了，断开重连。设备那边是 15 秒。
    private static let silenceLimit: UInt64 = 15_000_000_000

    public func start() {
        queue.async { [self] in
            stopped = false
            guard central == nil else { return }
            // 不弹系统的「打开蓝牙」提示，蓝牙关着时设置里会写。
            central = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    /// 退出前调用：告诉设备 Mac 离线（屏幕切到离线页），再断开。
    public func stop() {
        queue.sync {
            stopped = true
            if online { send(["cmd": "bye"]) }
            timer?.cancel()
            timer = nil
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
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

    // MARK: 连接

    private func setState(_ next: PassportLinkState) {
        guard next != state else { return }
        state = next
        onState?(next)
    }

    /// 先连上次那台，同时扫描：设备换了（或者重刷后蓝牙身份变了）也能找到。
    private func connectOrScan() {
        guard let central, central.state == .poweredOn, !stopped else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        setState(.searching)
        if peripheral == nil,
           let text = UserDefaults.standard.string(forKey: Self.rememberedKey),
           let id = UUID(uuidString: text),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            adopt(known)
        }
        if let peripheral {
            // 没有超时：设备不在范围内时一直等着，回来就自动连上。
            central.connect(peripheral)
        }
        if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.serviceUUID])
        }
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
        if now.uptimeNanoseconds - lastHeard.uptimeNanoseconds > Self.silenceLimit {
            note("设备 15 秒没有回应，断开重连")
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
            setState(.online(firmware: version))
            sendConfig()
            send(["cmd": "state", "st": "idle", "mode": "dict", "msg": ""])
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

    // MARK: 发

    private func sendHello() {
        send(["cmd": "hello"])
    }

    private func sendConfig() {
        let clock = Int(Date().timeIntervalSince1970) + TimeZone.current.secondsFromGMT()
        send(["cmd": "config", "mic": 0, "engine": "Lepak", "screen_off": screenOffSeconds,
              "clock": clock, "sound": 0])
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
        if let current = self.peripheral {
            if current.identifier == peripheral.identifier || current.state == .connected { return }
        }
        note("找到设备 \(peripheral.name ?? "未命名")，正在连接")
        adopt(peripheral)
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        central.stopScan()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedKey)
        setState(.connecting)
        lastHeard = .now()
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        note("连接失败：\(error?.localizedDescription ?? "未知原因")")
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectOrScan() }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let wasOnline = online
        resetLink()
        if stopped { return }
        if wasOnline { note("蓝牙断开\(error.map { "：\($0.localizedDescription)" } ?? "")") }
        setState(.searching)
        connectOrScan()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            note("设备上没有 Lepak 认识的服务，可能还是官方固件")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.eventsUUID, Self.commandsUUID], for: service)
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
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
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
        guard characteristic.uuid == Self.eventsUUID, let value = characteristic.value else { return }
        received(value)
    }
}
