import Foundation
import UIKit
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

    /// Non-blocking read for the crash signal handler (the crashing thread
    /// may be the one holding the lock).
    static var currentIfAvailable: (crumb: String, at: Date)? {
        state.withLockIfAvailable { $0 }
    }
}

/// Foreground/background state mirrored from UIApplication notifications so
/// background threads (watchdog, heartbeat) can read it without touching
/// UIKit. A suspended (backgrounded) process stops servicing the main queue
/// too — without this, every trip to the home screen read as a "hang".
enum AppRunState {
    private static let state = OSAllocatedUnfairLock(initialState: "launching")
    static var current: String { state.withLock { $0 } }

    /// Call on the main thread at launch.
    static func observe() {
        let pairs: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.willTerminateNotification, "terminating"),
        ]
        for (name, value) in pairs {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                state.withLock { $0 = value }
            }
        }
    }
}

enum MemoryFootprint {
    /// Resident footprint in MB (what jetsam judges), -1 if unavailable.
    static var megabytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_048_576)
    }
}

/// Samples the MAIN thread's call stack from the watchdog thread: suspend it,
/// read its register state, walk the frame-pointer chain, resume — then
/// symbolicate (after resume, so dladdr's dyld lock can't deadlock against a
/// suspended main thread that holds it). No allocation happens while the
/// main thread is suspended (it may hold the malloc lock): frames land in a
/// pre-sized buffer. Frames read "DuelFantasy.debug.dylib+0x1a2b3c $s…" —
/// `atos -o <dylib> -arch arm64 -l 0 0x1a2b3c` or `swift demangle` resolves
/// app frames; system frames resolve with `atos -o <DeviceSupport symbol>
/// -arch arm64e -offset 0x…`.
enum MainThreadSampler {
    private static let port = OSAllocatedUnfairLock<thread_act_t>(initialState: 0)

    /// Call on the main thread at launch.
    static func captureMainThread() {
        let me = mach_thread_self()
        port.withLock { $0 = me }
    }

    static func sample(maxFrames: Int = 48) -> [String] {
        #if arch(arm64)
        let thread = port.withLock { $0 }
        guard thread != 0 else { return [] }
        var pcs = [UInt64](repeating: 0, count: maxFrames + 2)
        var n = 0
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { ptr in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(thread, ARM_THREAD_STATE64, raw, &count)
            }
        }
        if kr == KERN_SUCCESS {
            pcs[n] = state.__pc; n += 1
            pcs[n] = state.__lr; n += 1
            var fp = state.__fp
            while n < pcs.count, fp != 0, fp % 8 == 0,
                  let next = readWord(fp), let ret = readWord(fp + 8), ret != 0 {
                pcs[n] = ret; n += 1
                guard next > fp else { break }
                fp = next
            }
        }
        thread_resume(thread)
        return (0..<n).map { symbolicate(pcs[$0]) }
        #else
        return []
        #endif
    }

    /// Safe read of one 64-bit word from the (suspended) main thread's stack.
    private static func readWord(_ address: UInt64) -> UInt64? {
        var value: UInt64 = 0
        var outSize: vm_size_t = 0
        let kr = withUnsafeMutablePointer(to: &value) { ptr in
            vm_read_overwrite(mach_task_self_, vm_address_t(address), 8,
                              vm_address_t(UInt(bitPattern: ptr)), &outSize)
        }
        return kr == KERN_SUCCESS && outSize == 8 ? value : nil
    }

    private static func symbolicate(_ pc: UInt64) -> String {
        var info = Dl_info()
        guard let ptr = UnsafeRawPointer(bitPattern: UInt(pc)), dladdr(ptr, &info) != 0,
              let base = info.dli_fbase else {
            return String(format: "0x%llx", pc)
        }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let offset = pc - UInt64(UInt(bitPattern: base))
        let sym = info.dli_sname.map { " " + String(cString: $0) } ?? ""
        return "\(image)+0x\(String(offset, radix: 16))\(sym)"
    }
}

/// Background-thread watchdog that detects main-thread hangs the moment they
/// happen — unlike MetricKit, which batches hang diagnostics daily and skips
/// Xcode-launched runs.
///
/// Each cycle enqueues a numbered beat on BOTH the main dispatch queue and the
/// main actor, sleeps 2s, and checks whether that specific beat ran. (The old
/// "beat timestamp older than 2s" check flagged an idle main thread whenever
/// the sleep overslept by a few ms — every such report sampled the main thread
/// sitting in `__CFRunLoopServiceMachPort`.) Reports carry the breadcrumb,
/// which channel starved, the app run state, memory footprint, and a sampled
/// main-thread stack; nothing is reported while the app isn't active (a
/// suspended process services nothing).
///
/// It also writes a heartbeat file every cycle (state, crumb, footprint) that
/// CrashReporter reads at the NEXT launch: if the previous run's last
/// heartbeat says "active" and no crash was recorded, the run died without a
/// trace — a SIGKILL (watchdog / jetsam) or a stop from Xcode — and a row
/// says so with the last known state.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()
    private let dispatchBeat = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let actorBeat = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    func start() {
        if Thread.isMainThread {
            MainThreadSampler.captureMainThread()
            AppRunState.observe()
        } else {
            DispatchQueue.main.async {
                MainThreadSampler.captureMainThread()
                AppRunState.observe()
            }
        }
        let thread = Thread { [self] in
            var seq: UInt64 = 0
            while true {
                seq += 1
                let expected = seq
                sendBeats(expected)
                Thread.sleep(forTimeInterval: 2.0)
                CrashReporter.shared.writeHeartbeat()
                let dispatchRan = dispatchBeat.withLock { $0 } >= expected
                let actorRan = actorBeat.withLock { $0 } >= expected
                if dispatchRan && actorRan { continue }

                // Main thread is hung (or the process is suspended — the run
                // state tells which). Report NOW so force-quit can't lose it.
                let hangStart = Date().addingTimeInterval(-2.0)
                let stateAtDetect = AppRunState.current
                let (crumb, at) = PerfBreadcrumb.current
                let age = Date().timeIntervalSince(at)
                let channels = "dispatch beat \(dispatchRan ? "ran" : "starved"), actor beat \(actorRan ? "ran" : "starved")"
                if stateAtDetect == "active" {
                    let frames = MainThreadSampler.sample()
                    CrashReporter.shared.reportWatchdogHang(
                        "main thread hung ≥2s [\(channels)] — last op: \(crumb) (started \(String(format: "%.1f", age))s before), footprint \(MemoryFootprint.megabytes) MB",
                        frames: frames
                    )
                }

                // Wait for THAT beat to run, then report the measured duration.
                var resampled = false
                while true {
                    Thread.sleep(forTimeInterval: 1.0)
                    CrashReporter.shared.writeHeartbeat()
                    let d = dispatchBeat.withLock { $0 } >= expected
                    let a = actorBeat.withLock { $0 } >= expected
                    let now = AppRunState.current
                    if d && a {
                        if stateAtDetect == "active" {
                            let dur = Date().timeIntervalSince(hangStart)
                            CrashReporter.shared.reportWatchdogHang(
                                "recovered after \(String(format: "%.1f", dur))s — last op: \(crumb), state \(stateAtDetect) → \(now)"
                            )
                        }
                        break
                    }
                    // Still hung ~8s in: a second sample tells whether it's
                    // ONE long operation or a chain of them (the watchdog
                    // kill lands around 20s — this is the last evidence).
                    if !resampled, stateAtDetect == "active", now == "active",
                       Date().timeIntervalSince(hangStart) >= 8 {
                        resampled = true
                        let frames = MainThreadSampler.sample()
                        let d2 = dispatchBeat.withLock { $0 } >= expected
                        let a2 = actorBeat.withLock { $0 } >= expected
                        CrashReporter.shared.reportWatchdogHang(
                            "still hung after \(String(format: "%.1f", Date().timeIntervalSince(hangStart)))s [dispatch beat \(d2 ? "ran" : "starved"), actor beat \(a2 ? "ran" : "starved")] — last op: \(PerfBreadcrumb.current.crumb), footprint \(MemoryFootprint.megabytes) MB",
                            frames: frames
                        )
                    }
                }
            }
        }
        thread.name = "hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func sendBeats(_ n: UInt64) {
        DispatchQueue.main.async { [self] in
            dispatchBeat.withLock { $0 = max($0, n) }
        }
        Task { @MainActor [self] in
            actorBeat.withLock { $0 = max($0, n) }
        }
    }
}
