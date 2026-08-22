import Foundation
import os

/// Last interesting operation STARTED on the main thread — read by the hang
/// watchdog when the main thread stops responding, so a freeze report names
/// the code path instead of just "it hung". The `age` in the report tells
/// whether the crumb is the hang itself (age ≈ 0) or merely the last marked
/// op before un-instrumented code hung (age large).
enum PerfBreadcrumb {
    private static let state = OSAllocatedUnfairLock(initialState: (crumb: "launch", at: Date()))

    static func set(_ crumb: String) {
        state.withLock { $0 = (crumb, Date()) }
    }

    static var current: (crumb: String, at: Date) {
        state.withLock { $0 }
    }
}

/// Background-thread watchdog that detects main-thread hangs (≥2s without
/// servicing the main queue) the moment they happen — unlike MetricKit,
/// which batches hang diagnostics daily and skips Xcode-launched runs.
///
/// On detection it immediately spools a report (breadcrumb + crumb age)
/// through CrashReporter — so even if the user force-quits mid-freeze the
/// evidence survives — and on recovery spools a follow-up with the measured
/// hang duration.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()
    private let lastBeat = OSAllocatedUnfairLock(initialState: Date())

    func start() {
        let thread = Thread { [self] in
            while true {
                DispatchQueue.main.async { [self] in
                    lastBeat.withLock { $0 = Date() }
                }
                Thread.sleep(forTimeInterval: 2.0)
                let last = lastBeat.withLock { $0 }
                guard Date().timeIntervalSince(last) > 2.0 else { continue }

                // Main thread is hung — report NOW (survives force-quit).
                let (crumb, at) = PerfBreadcrumb.current
                let age = Date().timeIntervalSince(at)
                CrashReporter.shared.reportWatchdogHang(
                    "main thread hung ≥2s — last op: \(crumb) (started \(String(format: "%.1f", age))s before)"
                )

                // Wait for recovery, then report how long it actually lasted.
                let hangStart = last
                while true {
                    DispatchQueue.main.async { [self] in
                        lastBeat.withLock { $0 = Date() }
                    }
                    Thread.sleep(forTimeInterval: 1.0)
                    let l2 = lastBeat.withLock { $0 }
                    if Date().timeIntervalSince(l2) < 1.0 {
                        let dur = Date().timeIntervalSince(hangStart)
                        CrashReporter.shared.reportWatchdogHang(
                            "recovered after \(String(format: "%.1f", dur))s — last op: \(crumb)"
                        )
                        break
                    }
                }
            }
        }
        thread.name = "hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
