//
//  CrashReporter.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import Foundation

/// Records abnormal terminations in the app's own log, so that
/// `~/Library/Logs/ScreenLock/ScreenLock.log` shows *why* the app disappeared
/// instead of just stopping mid-sentence.
///
/// This does not replace macOS's own crash reports: the full stack trace stays in
/// `~/Library/Logs/DiagnosticReports/ScreenLock-<date>.ips` (readable without
/// administrator rights, and also shown by Console.app under "Crash Reports").
/// What is added here is a marker in the same timeline as the lock/unlock events,
/// which is what tells you whether the app died *while the screen was locked*.
///
/// `SIGKILL` (`kill -9`, Force Quit from another account, the watchdog) cannot be
/// caught by any process: in that case the log simply ends, with no final line.
enum CrashReporter {
    /// Signals that mean the process is going down. `SIGTERM` is not a crash — it
    /// is the polite "please quit", e.g. plain `killall ScreenLock` — but it is
    /// worth distinguishing from a real one in the log.
    private static let fatalSignals: [Int32] = [
        SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP, SIGTERM
    ]

    /// Must run before anything can crash, i.e. first thing at launch.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            // A still-running process: the full Foundation API is available here.
            let name = exception.name.rawValue
            let reason = exception.reason ?? "no reason"
            Log.crash.error("Uncaught exception \(name): \(reason)")
            Log.crash.error("Stack: \(exception.callStackSymbols.joined(separator: " | "))")
        }

        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = handleFatalSignal
            action.sa_flags = 0
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }

        Log.crash.debug("Crash handlers installed")
    }
}

/// Signal handler. Only async-signal-safe calls are allowed in here: no
/// allocation, no locks, no Foundation — just `write(2)` on the descriptor
/// `FileLog` already opened, which is why the line is assembled by hand.
private func handleFatalSignal(_ signal: Int32) {
    let descriptor = logFileDescriptor
    if descriptor >= 0 {
        writeRaw(descriptor, "=== ScreenLock terminated by ")
        writeRaw(descriptor, name(of: signal))
        writeRaw(descriptor, " at epoch ")
        writeDecimal(descriptor, Int(time(nil)))
        writeRaw(descriptor, ", see ~/Library/Logs/DiagnosticReports ===\n")
    }

    // Restore the default handler and re-raise, so macOS still produces the full
    // .ips crash report and the exit status stays truthful.
    var action = sigaction()
    action.__sigaction_u.__sa_handler = SIG_DFL
    sigemptyset(&action.sa_mask)
    sigaction(signal, &action, nil)
    raise(signal)
}

private func name(of signal: Int32) -> StaticString {
    switch signal {
    case SIGABRT: return "SIGABRT (abort, e.g. a Swift fatalError or an uncaught exception)"
    case SIGBUS: return "SIGBUS (bad memory access)"
    case SIGFPE: return "SIGFPE (arithmetic error)"
    case SIGILL: return "SIGILL (illegal instruction)"
    case SIGSEGV: return "SIGSEGV (segmentation fault)"
    case SIGSYS: return "SIGSYS (bad system call)"
    case SIGTRAP: return "SIGTRAP (trap, e.g. a failed precondition)"
    case SIGTERM: return "SIGTERM (asked to quit, e.g. killall)"
    default: return "an unexpected signal"
    }
}

/// `StaticString` keeps the bytes in the binary: no allocation at signal time.
private func writeRaw(_ descriptor: Int32, _ text: StaticString) {
    text.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = write(descriptor, base, buffer.count)
    }
}

/// Minimal `itoa` into a stack buffer, so the line can carry a timestamp without
/// calling anything unsafe.
private func writeDecimal(_ descriptor: Int32, _ value: Int) {
    // A stack buffer: allocating an Array here would call malloc, which is not
    // async-signal-safe and can deadlock if the crash happened inside the
    // allocator itself.
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { buffer in
        var remaining = max(0, value)
        var index = buffer.count

        repeat {
            index -= 1
            buffer[index] = UInt8(48 + remaining % 10)
            remaining /= 10
        } while remaining > 0 && index > 0

        guard let base = buffer.baseAddress else { return }
        _ = write(descriptor, base + index, buffer.count - index)
    }
}
