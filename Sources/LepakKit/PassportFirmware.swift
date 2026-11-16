import CryptoKit
import Foundation
import IOKit

/// 给 AI Passport 装社区固件（InputBetter，协议 v1）：从官网的固件清单下载、校验，再用 esptool 通过 USB 写进设备。
///
/// 安全约束（和社区项目的刷写脚本、网页刷写一致）：
/// - 只写 bootloader（0x0）、分区表（0x8000）、应用（0x10000）三段，不擦除整片 Flash，从不写 `cardid` 分区
///   （0x356000，设备出厂身份数据）。清单里的地址、大小和要写的新分区表都先检查，对不上就不装。
/// - 写之前确认设备是 ESP32-C3、8 MB Flash，并且设备现在的分区表里有 `cardid`（是 AI Passport，不是别的开发板）。
/// - 每台设备（按 MAC）第一次装之前，把整片 8 MB Flash 备份到本机，可用来恢复原来的固件。备份里有设备身份数据，不外传。
/// - 只用乐鑫芯片的 USB 串口（VID 0x303A），不碰键盘，不需要「输入监控」。
///
/// esptool 是乐鑫官方的独立版（GPL-2.0），作为单独的程序调用，跟着 App 放在 Contents/Helpers（见 scripts/fetch-esptool.sh）。
public enum PassportFirmware {
    /// InputBetter 官网的固件清单（社区项目 scripts/package-firmware.sh 生成）。
    public static let manifestURL = URL(string: "https://input.0os.io/firmware/manifest.json")!
    /// Lepak 只认协议 v1，清单里的 `proto` 不是 1 就不装。
    public static let protocolVersion = 1

    static let flashSize = 0x80_0000
    static let cardIDOffset: UInt32 = 0x35_6000
    static let cardIDSize: UInt32 = 0x4000
    static let bootloaderOffset: UInt32 = 0x0
    static let tableOffset: UInt32 = 0x8000
    static let appOffset: UInt32 = 0x1_0000
    /// 分区表最长 0xC00 字节（ESP-IDF 的上限），读设备上的分区表也读这么多。
    static let tableLength = 0xC00

    // MARK: 清单

    public struct Manifest: Sendable, Equatable {
        public struct Image: Sendable, Equatable {
            public let offset: UInt32
            public let url: URL
            public let size: Int
            public let sha256: String
        }

        public let version: String
        public let build: String
        public let images: [Image]

        public init(version: String, build: String, images: [Image]) {
            self.version = version
            self.build = build
            self.images = images
        }

        /// 解析并检查清单。协议版本不对时抛 `.incompatible`，其他不对劲的地方抛 `.badManifest`。
        public static func parse(_ data: Data, base: URL) throws -> Manifest {
            guard data.count < 64 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FirmwareError.badManifest("不是有效的清单")
            }
            guard let version = object["version"] as? String, Self.isToken(version),
                  let build = object["build"] as? String, Self.isToken(build) else {
                throw FirmwareError.badManifest("缺少版本号")
            }
            guard (object["proto"] as? Int) == PassportFirmware.protocolVersion else {
                throw FirmwareError.incompatible(version: version)
            }
            guard (object["chip"] as? String) == "ESP32-C3", (object["flashSize"] as? String) == "8MB" else {
                throw FirmwareError.badManifest("芯片型号不对")
            }
            guard let list = object["images"] as? [[String: Any]], list.count == 3 else {
                throw FirmwareError.badManifest("镜像数量不对")
            }
            var images: [Image] = []
            for entry in list {
                guard let offsetText = entry["offset"] as? String, offsetText.hasPrefix("0x"),
                      let offset = UInt32(offsetText.dropFirst(2), radix: 16),
                      let path = entry["path"] as? String, Self.isRelativePath(path),
                      let url = URL(string: path, relativeTo: base)?.absoluteURL,
                      url.scheme == "https", url.host == base.host,
                      let size = entry["size"] as? Int, size > 0,
                      let sha = entry["sha256"] as? String, sha.count == 64,
                      sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
                else { throw FirmwareError.badManifest("镜像信息不完整") }
                // 每段只能写在自己的区域里：bootloader 在分区表之前，分区表在 nvs（0x9000）之前，应用在 cardid 之前。
                let limit: UInt32
                switch offset {
                case PassportFirmware.bootloaderOffset: limit = PassportFirmware.tableOffset
                case PassportFirmware.tableOffset: limit = PassportFirmware.tableOffset + UInt32(PassportFirmware.tableLength)
                case PassportFirmware.appOffset: limit = PassportFirmware.cardIDOffset
                default: throw FirmwareError.badManifest("写入地址 \(offsetText) 不在允许范围")
                }
                guard UInt64(offset) + UInt64(size) <= UInt64(limit) else {
                    throw FirmwareError.badManifest("\(offsetText) 这一段太大")
                }
                images.append(Image(offset: offset, url: url, size: size, sha256: sha))
            }
            guard Set(images.map(\.offset)).count == 3 else { throw FirmwareError.badManifest("写入地址重复") }
            return Manifest(version: version, build: build, images: images.sorted { $0.offset < $1.offset })
        }

        static func isToken(_ text: String) -> Bool {
            !text.isEmpty && text.count <= 32 && text.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._+-".unicodeScalars.contains($0)
            }
        }

        /// 只接受 `0.1.3-4d1c6c61/app.bin` 这样的相对路径：没有 `..`，不能跳到别的网站。
        static func isRelativePath(_ path: String) -> Bool {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return !parts.isEmpty && parts.count <= 4 && parts.allSatisfy { part in
                part != "." && part != ".." && isToken(String(part))
            }
        }
    }

    /// 比较两个版本号（`0.1.3` 和 `0.1.10`），按数字逐段比；有非数字的段时按字符串比。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) }
        let b = current.split(separator: ".").map { Int($0) }
        guard !a.contains(nil), !b.contains(nil) else { return candidate.compare(current, options: .numeric) == .orderedDescending }
        let x = a.compactMap { $0 }, y = b.compactMap { $0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// 从官网取最新的固件清单（不下载镜像）。
    public static func fetchManifest() async throws -> Manifest {
        let request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FirmwareError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FirmwareError.network("服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try Manifest.parse(data, base: manifestURL)
    }

    // MARK: 下载

    /// 下载好、校验过的一套镜像，放在临时文件夹里。用完调用 `discard()`。
    public struct Download: Sendable {
        public let manifest: Manifest
        let files: [(offset: UInt32, file: URL)]
        let folder: URL

        public func discard() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// 下载清单里的三段镜像，逐个核对大小和 SHA-256，并检查要写的新分区表。`progress` 收到 0…1。
    public static func download(_ manifest: Manifest, progress: @escaping @Sendable (Double) -> Void) async throws -> Download {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LepakFirmware-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let total = Double(manifest.images.reduce(0) { $0 + $1.size })
            var done = 0
            var files: [(offset: UInt32, file: URL)] = []
            for image in manifest.images {
                try Task.checkCancellation()
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(from: image.url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw FirmwareError.network(error.localizedDescription)
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw FirmwareError.network("服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                guard data.count == image.size, sha256(data) == image.sha256 else {
                    throw FirmwareError.checksum
                }
                if image.offset == tableOffset {
                    let app = manifest.images.first { $0.offset == appOffset }?.size ?? 0
                    guard let table = PartitionTable(data), table.isSafeToWrite(appSize: app) else {
                        throw FirmwareError.badManifest("分区表不对")
                    }
                }
                let file = folder.appendingPathComponent(String(format: "0x%05x.bin", image.offset))
                try data.write(to: file)
                files.append((image.offset, file))
                done += image.size
                progress(Double(done) / max(total, 1))
            }
            return Download(manifest: manifest, files: files, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: USB

    /// 插在这台 Mac 上的乐鑫 USB 串口（AI Passport 是 ESP32-C3，USB 口 VID 0x303A），比如 `/dev/cu.usbmodem101`。
    /// 只看 IOKit 里的串口列表，不打开它。
    public static func usbPorts() -> [String] {
        // "IOSerialBSDClient" 就是 kIOSerialBSDServiceValue。
        guard let matching = IOServiceMatching("IOSerialBSDClient") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports: [String] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            // "IOCalloutDevice" 是 kIOCalloutDeviceKey：/dev/cu.* 那个路径。
            guard let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            let vendor = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault,
                                                         IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            if (vendor as? Int) == 0x303A {
                ports.append(path)
            }
        }
        return ports.sorted()
    }

    // MARK: 安装

    public enum Step: Sendable, Equatable {
        /// 让设备进入下载模式，读芯片、Flash 大小、分区表。
        case connecting
        /// 第一次装这台设备：整片备份。
        case backingUp(Double)
        case writing(Double)
    }

    public struct InstallResult: Sendable {
        public let mac: String
        /// 这次新做的备份；以前备份过就是 nil。
        public let newBackup: URL?
    }

    /// 备份文件名按 MAC 区分，同一台设备只备份一次。
    public static func backupFile(in folder: URL, mac: String) -> URL {
        folder.appendingPathComponent("passport-\(mac)-flash.bin")
    }

    /// 把下载好的固件写进 USB 上的设备。写完设备自己重启，进入新固件。
    /// 写入开始之前可以取消（取消会让设备重启回原来的固件）；开始写之后不要取消。
    public static func install(
        _ firmware: Download,
        port: String,
        esptool: Esptool,
        backupFolder: URL,
        onStep: @escaping @Sendable (Step) -> Void
    ) async throws -> InstallResult {
        let common = ["--chip", "esp32c3", "--port", port]
        // 进下载模式后一直停在那里（--after no-reset），免得原来的固件在两步之间启动；最后写完才重启。
        let stay = ["--before", "default-reset", "--after", "no-reset"]
        var connected = false
        do {
            onStep(.connecting)
            let info = try await esptool.run(common + stay + ["flash-id"], timeout: 90)
            connected = info.text.contains("Connected to")
            try info.check(else: { .notConnected($0) })
            guard let mac = info.mac else { throw FirmwareError.notConnected("没读到设备编号") }
            guard info.flashSize == "8MB" else { throw FirmwareError.notPassport }

            let backup = backupFile(in: backupFolder, mac: mac)
            var newBackup: URL?
            let table: Data
            if let size = fileSize(backup), size == flashSize {
                let file = firmware.folder.appendingPathComponent("device-table.bin")
                let read = try await esptool.run(common + stay + ["read-flash", hex(tableOffset), hex(UInt32(tableLength)), file.path],
                                                 timeout: 90)
                try read.check(else: { .notConnected($0) })
                table = try Data(contentsOf: file)
            } else {
                onStep(.backingUp(0))
                try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
                let partial = backup.appendingPathExtension("partial")
                try? FileManager.default.removeItem(at: partial)
                let read = try await esptool.run(common + stay + ["read-flash", "0x0", hex(UInt32(flashSize)), partial.path],
                                                 timeout: 900) { onStep(.backingUp($0)) }
                guard read.status == 0, fileSize(partial) == flashSize, let data = try? Data(contentsOf: partial) else {
                    try? FileManager.default.removeItem(at: partial)
                    try read.check(else: { .backupFailed($0) })
                    throw FirmwareError.backupFailed("备份文件大小不对")
                }
                table = data.subdata(in: Int(tableOffset)..<(Int(tableOffset) + tableLength))
                guard PartitionTable(table)?.isPassport == true else {
                    try? FileManager.default.removeItem(at: partial)
                    throw FirmwareError.notPassport
                }
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.moveItem(at: partial, to: backup)
                try? "\(sha256(data))  \(backup.lastPathComponent)\n"
                    .write(to: backup.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
                newBackup = backup
            }
            guard PartitionTable(table)?.isPassport == true else { throw FirmwareError.notPassport }

            // 写之前最后核对一遍：只有允许的三段，每段都在自己的区域里，文件大小和清单一致。
            try Task.checkCancellation()
            var args = common + ["--before", "default-reset", "--after", "hard-reset", "write-flash",
                                 "--flash-mode", "keep", "--flash-freq", "keep", "--flash-size", "keep"]
            for (offset, file) in firmware.files {
                guard let image = firmware.manifest.images.first(where: { $0.offset == offset }),
                      fileSize(file) == image.size else { throw FirmwareError.checksum }
                args += [hex(offset), file.path]
            }
            guard firmware.files.count == 3 else { throw FirmwareError.checksum }
            onStep(.writing(0))
            let write = try await esptool.run(args, timeout: 600) { onStep(.writing($0)) }
            try write.check(else: { .writeFailed($0) })
            return InstallResult(mac: mac, newBackup: newBackup)
        } catch {
            // 出错或取消时设备可能还停在下载模式：重启一下，让它回到 Flash 里的固件。不受取消影响，所以放在单独的任务里。
            if connected {
                _ = await Task.detached {
                    try? await esptool.run(common + ["--before", "default-reset", "--after", "hard-reset", "read-mac"], timeout: 60)
                }.value
            }
            // esptool 打不开串口时只说「被占用或不存在」：线已经拔了就别让用户去找占用的程序。
            if case FirmwareError.portBusy = error, !FileManager.default.fileExists(atPath: port) {
                throw FirmwareError.notConnected("USB 线断开了")
            }
            throw error
        }
    }

    static func hex(_ value: UInt32) -> String { String(format: "0x%x", value) }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

// MARK: 错误

public enum FirmwareError: Error, LocalizedError, Equatable {
    case network(String)
    case badManifest(String)
    case incompatible(version: String)
    case checksum
    case toolMissing
    case portBusy
    case notConnected(String)
    case notPassport
    case backupFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .network(let detail): return "下载固件失败：\(detail)"
        case .badManifest(let detail): return "官网的固件信息有问题（\(detail)），为了安全没有安装。"
        case .incompatible(let version): return "官网最新的固件（\(version)）和这个版本的 Lepak 不配套，先不安装。"
        case .checksum: return "下载的固件不完整，请重试。"
        case .toolMissing: return "这个版本的 Lepak 没有带安装工具。"
        case .portBusy: return "USB 连接被别的程序占着（比如 InputBetter），先退出它再试。"
        case .notConnected(let detail): return "连不上设备：\(detail)。拔掉 USB 线重新插上，或者重新开机后再试。"
        case .notPassport: return "这台设备看起来不是 AI Passport，为了安全没有安装。"
        case .backupFailed(let detail): return "备份没有完成：\(detail)。设备没有改动。"
        case .writeFailed(let detail): return "写入没有完成：\(detail)。可以再试一次。"
        }
    }
}

// MARK: 分区表

/// ESP-IDF 分区表：每项 32 字节（魔数 AA 50、类型、子类型、偏移、大小、16 字节名字、标志），以 MD5 项（EB EB）或 FF 结束。
struct PartitionTable {
    struct Entry {
        let label: String
        let type: UInt8
        let subtype: UInt8
        let offset: UInt32
        let size: UInt32
    }

    let entries: [Entry]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var entries: [Entry] = []
        var position = 0
        while position + 32 <= bytes.count {
            let magic = (bytes[position], bytes[position + 1])
            if magic == (0xEB, 0xEB) || magic == (0xFF, 0xFF) { break }
            guard magic == (0xAA, 0x50) else { return nil }
            func word(_ at: Int) -> UInt32 {
                (0..<4).reduce(0) { $0 | UInt32(bytes[position + at + $1]) << (8 * $1) }
            }
            let name = bytes[(position + 12)..<(position + 28)].prefix { $0 != 0 }
            guard let label = String(bytes: name, encoding: .ascii) else { return nil }
            entries.append(Entry(label: label, type: bytes[position + 2], subtype: bytes[position + 3],
                                 offset: word(4), size: word(8)))
            position += 32
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    /// 是 AI Passport：有出厂身份分区 `cardid`（data / nvs，0x356000，16 KB）。
    var isPassport: Bool {
        entries.contains {
            $0.label == "cardid" && $0.type == 1 && $0.subtype == 2
                && $0.offset == PassportFirmware.cardIDOffset && $0.size == PassportFirmware.cardIDSize
        }
    }

    /// 要写进设备的新分区表：保留 `cardid`、别的分区都不和它重叠、都在 8 MB 以内，应用分区从 0x10000 开始且放得下应用。
    func isSafeToWrite(appSize: Int) -> Bool {
        guard isPassport else { return false }
        let cardEnd = UInt64(PassportFirmware.cardIDOffset) + UInt64(PassportFirmware.cardIDSize)
        for entry in entries {
            let end = UInt64(entry.offset) + UInt64(entry.size)
            guard end <= UInt64(PassportFirmware.flashSize) else { return false }
            if entry.label != "cardid", UInt64(entry.offset) < cardEnd, end > UInt64(PassportFirmware.cardIDOffset) {
                return false
            }
        }
        return entries.contains {
            $0.type == 0 && $0.offset == PassportFirmware.appOffset && Int($0.size) >= appSize
        }
    }
}

// MARK: esptool

/// 乐鑫官方的 esptool 独立版。每次调用都是一个子进程（启动要几秒），输出合在一起收下来，从中解析进度百分比。
public struct Esptool: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    struct Output: Sendable {
        let status: Int32
        let text: String
        let timedOut: Bool

        var mac: String? {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("MAC:") else { continue }
                let value = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
                if value.count == 12, value.allSatisfy(\.isHexDigit) { return value.lowercased() }
            }
            return nil
        }

        var flashSize: String? {
            for line in text.split(whereSeparator: \.isNewline) {
                if let range = line.range(of: "Detected flash size:") {
                    return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        /// 出错时最有用的一行：esptool 的 "A fatal error occurred: …"，没有就取最后一行。
        var reason: String {
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if timedOut { return "等太久没有反应" }
            let line = lines.last { $0.localizedCaseInsensitiveContains("error") } ?? lines.last ?? "未知错误"
            return String(line.replacingOccurrences(of: "A fatal error occurred: ", with: "").prefix(160))
        }

        /// 退出码不是 0 时抛错：端口被占用单独报，其他按 `kind` 包一层。
        func check(else kind: (String) -> FirmwareError) throws {
            guard status != 0 else { return }
            if text.localizedCaseInsensitiveContains("port is busy") || text.localizedCaseInsensitiveContains("Resource busy") {
                throw FirmwareError.portBusy
            }
            throw kind(reason)
        }
    }

    /// 运行一次 esptool。超时或取消时结束子进程。
    func run(_ arguments: [String], timeout: TimeInterval, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Output {
        let job = Job(url: url, arguments: arguments, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                job.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            job.stop()
        }
    }

    /// 一次子进程。Process / Pipe 不是 Sendable，包在这里，只通过锁和它们打交道。
    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let pipe = Pipe()
        private let lock = NSLock()
        private var text = ""
        private var pending = ""
        private var timedOut = false
        private var stopped = false
        private let progress: (@Sendable (Double) -> Void)?

        init(url: URL, arguments: [String], progress: (@Sendable (Double) -> Void)?) {
            self.progress = progress
            process.executableURL = url
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            // 不要颜色和动态刷新的进度条，宽一点免得一行被折断。
            environment["NO_COLOR"] = "1"
            environment["TERM"] = "dumb"
            environment["COLUMNS"] = "200"
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
        }

        func start(timeout: TimeInterval, continuation: CheckedContinuation<Output, Error>) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { self.append(data) }
            }
            // 两个回调都强引用自己，进程结束时清掉，循环引用就断了。
            process.terminationHandler = { process in
                process.terminationHandler = nil
                self.pipe.fileHandleForReading.readabilityHandler = nil
                self.append(self.pipe.fileHandleForReading.readDataToEndOfFile())
                let output = self.lock.withLock { Output(status: process.terminationStatus, text: self.text, timedOut: self.timedOut) }
                continuation.resume(returning: output)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: FirmwareError.toolMissing)
                return
            }
            if lock.withLock({ stopped }) { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.lock.withLock { self.timedOut = true }
                self.process.terminate()
            }
        }

        func stop() {
            lock.withLock { stopped = true }
            if process.isRunning { process.terminate() }
        }

        private func append(_ data: Data) {
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            // 进度条用 \r 刷新，\r 也当换行。
            let lines: [Substring] = lock.withLock {
                text += chunk
                pending += chunk
                let parts = pending.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
                pending = String(parts.last ?? "")
                return Array(parts.dropLast())
            }
            guard let progress else { return }
            for line in lines {
                if let value = Self.percent(in: line) { progress(value) }
            }
        }

        /// 一行里最后一个百分比，比如 "Writing at 0x00010000 [====>   ] 35.2% 442368/1251760 bytes" 里的 35.2%。
        static func percent(in line: Substring) -> Double? {
            guard let sign = line.lastIndex(of: "%") else { return nil }
            var start = sign
            while start > line.startIndex {
                let previous = line.index(before: start)
                guard line[previous].isNumber || line[previous] == "." else { break }
                start = previous
            }
            guard start < sign, let value = Double(line[start..<sign]) else { return nil }
            return min(max(value / 100, 0), 1)
        }
    }
}
