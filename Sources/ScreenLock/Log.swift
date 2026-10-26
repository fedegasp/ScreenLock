//
//  Log.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import Foundation
import OSLog

/// Unified logging for the whole app. Every message goes to two places:
///
/// 1. the macOS unified log, subsystem `com.fgasperini.screenlock` (Console.app,
///    `log stream`/`log show`) — but **both of those need an administrator
///    account**: on a standard account `log` answers "Must be admin to run
///    'stream' command" / "Could not open local log store";
/// 2. a plain text file in the user's own home, which needs no privileges at all:
///
///        tail -f ~/Library/Logs/ScreenLock/ScreenLock.log
///
/// Values are logged in clear on purpose: nothing here is sensitive (never a
/// password, never what is on screen), and `<private>` placeholders would make the
/// log useless for diagnosing a lock that will not engage or will not release.
///
/// Crashes are covered too, see [CrashReporter.swift](CrashReporter.swift).
enum Log {
    /// Launch, status item, menu, termination.
    static let app = AppLog(category: "app")
    /// Lock/unlock state machine and focus re-assertion.
    static let lock = AppLog(category: "lock")
    /// LocalAuthentication (Touch ID / login password).
    static let auth = AppLog(category: "auth")
    /// Full-screen windows, one per display.
    static let window = AppLog(category: "window")
    /// Carbon global hotkey registration and events.
    static let hotkey = AppLog(category: "hotkey")
    /// IOKit power assertions and the idle-timer heartbeat.
    static let power = AppLog(category: "power")
    /// macOS lock screen (distributed notifications + session state).
    static let systemLock = AppLog(category: "systemLock")
    /// Persisted user preferences.
    static let preferences = AppLog(category: "preferences")
    /// Abnormal terminations caught by `CrashReporter`.
    static let crash = AppLog(category: "crash")

    /// Where the readable copy of the log lives, for the launch message.
    static var fileURL: URL? { FileLog.shared.fileURL }

    /// Opens the log file. Called once at launch, before anything else is logged,
    /// so the crash handler has a descriptor to write to from the very beginning.
    static func start() {
        FileLog.shared.open()
    }
}

enum LogLevel: String {
    case debug = "DEBUG"
    case notice = "NOTICE"
    case error = "ERROR"
}

/// Raw descriptor of the log file, or -1. The crash handler writes straight to it:
/// inside a signal handler only async-signal-safe calls like `write(2)` may be
/// used, so `FileLog`'s normal path (locks, Foundation, allocation) is off limits.
private(set) var logFileDescriptor: Int32 = -1

/// One logging category, writing to both sinks.
struct AppLog {
    static let subsystem = "com.fgasperini.screenlock"

    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    /// Step-by-step detail: useful when reproducing a problem, noisy otherwise.
    func debug(_ message: String) { emit(.debug, message) }

    /// The normal flow: lock, unlock, authentication outcome, system lock screen.
    func notice(_ message: String) { emit(.notice, message) }

    /// Something that actually breaks the lock, or a system call that failed.
    func error(_ message: String) { emit(.error, message) }

    private func emit(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
        FileLog.shared.write(level: level, category: category, message: message)
    }
}

/// Appends log lines to `~/Library/Logs/ScreenLock/ScreenLock.log`, rotating to a
/// single `.1` backup so the file can never grow without bound.
///
/// Writes are **synchronous** and go through `write(2)` on a descriptor opened with
/// `O_APPEND`: a buffered or queued write would lose exactly the lines that matter
/// most, the last ones before a crash.
private final class FileLog {
    static let shared = FileLog()

    /// Rotate at 1 MB, keeping one previous file: a couple of weeks of normal use.
    private static let maxBytes: off_t = 1024 * 1024

    let fileURL: URL?
    private let rotatedURL: URL?
    private let lock = NSLock()
    private let formatter: DateFormatter
    /// Set if the file cannot be opened, so a broken setup does not produce one
    /// failure message per logged line.
    private var isDisabled = false

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/ScreenLock", isDirectory: true)

        fileURL = directory?.appendingPathComponent("ScreenLock.log")
        rotatedURL = directory?.appendingPathComponent("ScreenLock.log.1")
    }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        openLocked()
    }

    private func openLocked() {
        guard !isDisabled, logFileDescriptor < 0, let fileURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            isDisabled = true
            Logger(subsystem: AppLog.subsystem, category: "app")
                .error("File log disabled, cannot create the directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        let descriptor = fileURL.path.withCString { path in
            // O_APPEND keeps every write atomic at the end of the file, which is
            // what lets the signal handler share the descriptor safely.
            Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }

        guard descriptor >= 0 else {
            isDisabled = true
            Logger(subsystem: AppLog.subsystem, category: "app")
                .error("File log disabled, cannot open \(fileURL.path, privacy: .public): errno \(errno, privacy: .public)")
            return
        }

        logFileDescriptor = descriptor
    }

    func write(level: LogLevel, category: String, message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(category)] \(level.rawValue) \(message)\n"

        lock.lock()
        defer { lock.unlock() }

        openLocked()
        guard logFileDescriptor >= 0 else { return }

        let bytes = Array(line.utf8)
        var written = 0
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while written < buffer.count {
                let count = Darwin.write(logFileDescriptor, base + written, buffer.count - written)
                if count < 0 {
                    // Interrupted before writing anything: retry. Anything else is
                    // not worth a second attempt.
                    if errno == EINTR { continue }
                    return
                }
                written += count
            }
        }

        rotateIfNeededLocked()
    }

    private func rotateIfNeededLocked() {
        guard logFileDescriptor >= 0, let fileURL, let rotatedURL else { return }

        var info = stat()
        guard fstat(logFileDescriptor, &info) == 0, info.st_size > Self.maxBytes else { return }

        let manager = FileManager.default
        try? manager.removeItem(at: rotatedURL)
        guard (try? manager.moveItem(at: fileURL, to: rotatedURL)) != nil else { return }

        close(logFileDescriptor)
        logFileDescriptor = -1
        openLocked()
    }
}

/// Decimal + hex form of an `OSStatus`/`IOReturn`. Carbon and IOKit codes are
/// usually published in hex, so logging both makes a failure searchable without
/// converting it by hand.
func describe(status: Int32) -> String {
    String(format: "%d (0x%08X)", status, UInt32(bitPattern: status))
}
