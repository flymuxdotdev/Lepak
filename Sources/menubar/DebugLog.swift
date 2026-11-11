import Foundation

enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VibeKey.log")
    private static let lock = NSLock()

    static func stamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince1970)
    }

    static func write(_ line: String) {
        let text = stamp() + " " + line + "\n"
        print(text, terminator: "")
        fflush(stdout)
        let data = Data(text.utf8)
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
