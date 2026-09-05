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

/// Samples the MAIN thread's call stack from the watchdog thread: suspend it,
/// read its register state, walk the frame-pointer chain, resume — then
/// symbolicate (after resume, so dladdr's dyld lock can't deadlock against a
/// suspended main thread that holds it). No allocation happens while the
/// main thread is suspended (it may hold the malloc lock): frames land in a
/// pre-sized buffer. Frames read "DuelFantasy.debug.dylib+0x1a2b3c $s…" —
/// `atos -o <dylib> -arch arm64 -l 0 0x1a2b3c` or `swift demangle` resolves them.
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
        if Thread.isMainThread {
            MainThreadSampler.captureMainThread()
        } else {
            DispatchQueue.main.async { MainThreadSampler.captureMainThread() }
        }
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
                let frames = MainThreadSampler.sample()
                CrashReporter.shared.reportWatchdogHang(
                    "main thread hung ≥2s — last op: \(crumb) (started \(String(format: "%.1f", age))s before)",
                    frames: frames
                )

                // Wait for recovery, then report how long it actually lasted.
                let hangStart = last
                var resampled = false
                while true {
                    DispatchQueue.main.async { [self] in
                        lastBeat.withLock { $0 = Date() }
                    }
                    Thread.sleep(forTimeInterval: 1.0)
                    let l2 = lastBeat.withLock { $0 }
                    // Still hung ~8s in: a second sample tells whether it's
                    // ONE long operation or a chain of them (the watchdog
                    // kill lands around 20s — this is the last evidence).
                    if !resampled, Date().timeIntervalSince(hangStart) >= 8 {
                        resampled = true
                        let frames = MainThreadSampler.sample()
                        CrashReporter.shared.reportWatchdogHang(
                            "still hung after \(String(format: "%.1f", Date().timeIntervalSince(hangStart)))s — last op: \(PerfBreadcrumb.current.crumb)",
                            frames: frames
                        )
                    }
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
