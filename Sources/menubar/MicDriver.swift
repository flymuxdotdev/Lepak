import Foundation

/// Lepak 麦克风驱动（Driver/LepakMic）的安装、更新和卸载。
///
/// 打包时驱动放在 Lepak.app/Contents/PlugIns/LepakMic.driver（见 scripts/package-app.sh）。
/// 安装就是把它复制到 /Library/Audio/Plug-Ins/HAL，再重启系统音频服务（coreaudiod）让它加载；
/// 这两步都要管理员权限，用系统自带的管理员密码框（osascript 的 `with administrator privileges`）。
/// 在后台线程等密码框，不卡主线程：AU05 的心跳在主线程上，停 3 秒就会出问题。
enum MicDriver {
    enum State: Equatable {
        case notInstalled
        case installed
        /// 装的和 Lepak 自带的不一样（Lepak 更新过驱动），可以更新。
        case outdated
    }

    enum Outcome: Sendable {
        case done
        case canceled
        case failed(String)
    }

    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/LepakMic.driver")

    /// Lepak 自带的驱动。直接 `swift build` 跑的开发版没有。
    static var bundledURL: URL? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("LepakMic.driver"),
              FileManager.default.fileExists(atPath: binary(of: url).path) else { return nil }
        return url
    }

    /// 看文件：装没装、和自带的是不是同一个（比较驱动的可执行文件，约 100 KB）。
    static func state() -> State {
        guard let installed = try? Data(contentsOf: binary(of: installedURL)) else { return .notInstalled }
        guard let bundled = bundledURL, let fresh = try? Data(contentsOf: binary(of: bundled)) else { return .installed }
        return installed == fresh ? .installed : .outdated
    }

    /// 安装或更新。完成后在后台线程回调。
    static func install(completion: @escaping @Sendable (Outcome) -> Void) {
        guard let source = bundledURL else {
            completion(.failed("这个版本的 Lepak 没有带驱动。"))
            return
        }
        let target = quote(installedURL.path)
        let steps = [
            "/bin/mkdir -p \(quote(installedURL.deletingLastPathComponent().path))",
            "/bin/rm -rf \(target)",
            "/bin/cp -R \(quote(source.path)) \(target)",
            "/usr/sbin/chown -R root:wheel \(target)",
            "/usr/bin/xattr -cr \(target)",
        ]
        // coreaudiod 被结束后系统会马上重新启动它，并加载新驱动。
        let command = "{ \(steps.joined(separator: " && ")); } || exit 1; /usr/bin/killall coreaudiod; exit 0"
        runAsAdmin(command, prompt: "Lepak 要安装「Lepak 麦克风」驱动。安装时声音会中断一两秒。", completion: completion)
    }

    static func uninstall(completion: @escaping @Sendable (Outcome) -> Void) {
        let command = "/bin/rm -rf \(quote(installedURL.path)) || exit 1; /usr/bin/killall coreaudiod; exit 0"
        runAsAdmin(command, prompt: "Lepak 要卸载「Lepak 麦克风」驱动。卸载时声音会中断一两秒。", completion: completion)
    }

    private static func binary(of driver: URL) -> URL {
        driver.appendingPathComponent("Contents/MacOS/LepakMic")
    }

    private static func runAsAdmin(_ command: String, prompt: String, completion: @escaping @Sendable (Outcome) -> Void) {
        let script = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                completion(.failed(error.localizedDescription))
                return
            }
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                completion(.done)
                return
            }
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // 用户在密码框里点了「取消」：AppleScript 报 -128。
            if message.contains("-128") {
                completion(.canceled)
            } else {
                completion(.failed(message.isEmpty ? "未知错误（\(process.terminationStatus)）" : message))
            }
        }
    }

    /// 给 shell 用的单引号字符串。
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 放进 AppleScript 双引号字符串里。
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
