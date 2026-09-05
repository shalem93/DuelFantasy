import Foundation
import MetricKit

/// Dependency-free crash reporting via Apple's MetricKit.
///
/// iOS collects a diagnostic for every crash (and >1s main-thread hang) and
/// hands it to the app on the NEXT launch through `MXMetricManagerSubscriber`.
/// We spool each diagnostic to disk immediately, then upload to the Supabase
/// `crash_reports` table (spooling first means a failed upload — offline,
/// table missing — retries on every subsequent launch, so nothing is lost).
///
/// The payload includes the full crashed-thread call stack as MetricKit JSON:
/// per-frame `binaryName`, `binaryUUID`, `address` and
/// `offsetIntoBinaryTextSegment`. Frames are raw addresses, not symbol names —
/// run `tools/symbolicate_metrickit.py <report.json> <app-or-dSYM>` to turn
/// them into file:line stacks with the matching build's symbols.
///
/// Caveats (Apple platform behavior, not ours):
/// - Diagnostics are only produced on a REAL DEVICE with NO debugger attached
///   (exactly the "it crashed on my phone, not in Xcode" case this is for).
/// - Delivery happens at next launch, not at crash time.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    /// Serializes spool-directory access; uploads run as async tasks off it.
    private let queue = DispatchQueue(label: "crash-reporter", qos: .utility)

    func start() {
        MXMetricManager.shared.add(self)
        installSignalCapture()
        queue.async {
            // Evidence from the PREVIOUS run: an in-process signal capture
            // (Swift trap / abort / bad access) wins; failing that, a
            // heartbeat that ended while the app was active means the run
            // died without any crash record (SIGKILL: watchdog, jetsam,
            // or a stop from Xcode).
            let hadSignalCrash = self.ingestPendingSignalCrash()
            self.ingestPreviousHeartbeat(hadSignalCrash: hadSignalCrash)
            // Retry anything a previous launch failed to upload.
            self.uploadSpooled()
        }
    }

    // MARK: - MXMetricManagerSubscriber

    // Required by the protocol (metrics payloads) — we only care about diagnostics.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async {
            for payload in payloads {
                for crash in payload.crashDiagnostics ?? [] {
                    self.spool(self.row(for: crash, kind: "crash", payload: payload))
                }
                for hang in payload.hangDiagnostics ?? [] {
                    self.spool(self.row(for: hang, kind: "hang", payload: payload))
                }
            }
            self.uploadSpooled()
        }
    }

    // MARK: - Row building

    private func row(for diagnostic: MXDiagnostic, kind: String, payload: MXDiagnosticPayload) -> [String: Any] {
        var row: [String: Any] = [
            "kind": kind,
            "app_version": "\(diagnostic.applicationVersion) (\(diagnostic.metaData.applicationBuildVersion))",
            "os_version": diagnostic.metaData.osVersion,
            "device_model": diagnostic.metaData.deviceType,
            "crashed_at": ISO8601DateFormatter().string(from: payload.timeStampEnd),
        ]
        if let userID = Self.persistedUserID() {
            row["user_id"] = userID
        }
        if let crash = diagnostic as? MXCrashDiagnostic {
            if let signal = crash.signal?.int32Value {
                row["signal"] = Self.signalName(signal)
            }
            if let type = crash.exceptionType?.intValue {
                row["exception_type"] = Self.machExceptionName(type)
            }
            if let code = crash.exceptionCode?.intValue {
                row["exception_code"] = String(code)
            }
            if let reason = crash.terminationReason {
                row["termination_reason"] = reason
            }
            // iOS 17+: for uncaught ObjC/Swift runtime exceptions this carries
            // the human-readable message (e.g. "Index out of range").
            if #available(iOS 17.0, *), let objc = crash.exceptionReason {
                row["termination_reason"] = "\(objc.exceptionName): \(objc.composedMessage)"
            }
            row["call_stack"] = Self.jsonObject(crash.callStackTree.jsonRepresentation())
        } else if let hang = diagnostic as? MXHangDiagnostic {
            row["termination_reason"] = "hang \(hang.hangDuration.converted(to: .seconds).value.rounded())s"
            row["call_stack"] = Self.jsonObject(hang.callStackTree.jsonRepresentation())
        }
        return row
    }

    private static func jsonObject(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    /// The signed-in user's id from the persisted auth session (nil pre-login).
    /// Read directly from UserDefaults so this never depends on view-model
    /// wiring being alive at crash-report time.
    private static func persistedUserID() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "supabase_auth_session"),
              let session = try? JSONDecoder().decode(SupabaseAuthSession.self, from: data) else {
            return nil
        }
        return session.user.id
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"    // Swift fatalError / precondition / index out of range
        case 6: return "SIGABRT"
        case 8: return "SIGFPE"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 9: return "SIGKILL"    // watchdog / jetsam
        default: return "signal \(signal)"
        }
    }

    private static func machExceptionName(_ type: Int) -> String {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 6: return "EXC_BREAKPOINT"  // Swift runtime traps land here
        case 10: return "EXC_CRASH"
        case 13: return "EXC_GUARD"
        default: return "exception \(type)"
        }
    }

    // MARK: - Watchdog hang reports

    /// Immediate hang report from HangWatchdog (detection or recovery).
    /// Spools + uploads through the same channel as MetricKit diagnostics,
    /// so reports land in `crash_reports` with kind "watchdog_hang".
    func reportWatchdogHang(_ reason: String, frames: [String] = []) {
        var sysinfo = utsname()
        uname(&sysinfo)
        let model = withUnsafeBytes(of: &sysinfo.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        var row: [String: Any] = [
            "kind": "watchdog_hang",
            "app_version": "\(version) (\(build))",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "device_model": model,
            "crashed_at": ISO8601DateFormatter().string(from: Date()),
            "termination_reason": reason,
        ]
        if let userID = Self.persistedUserID() {
            row["user_id"] = userID
        }
        if !frames.isEmpty {
            row["call_stack"] = ["main_thread": frames]
        }
        queue.async {
            self.spool(row)
            self.uploadSpooled()
        }
    }

    // MARK: - In-process signal capture (Swift traps, abort, bad access)

    /// C-string path of the signal crash file, prepared up front so the
    /// handler doesn't build strings. 64-slot frame buffer likewise.
    nonisolated(unsafe) static var signalPathC: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)

    private var signalFileURL: URL { spoolDir.appendingPathComponent("signal_crash.txt") }
    private var heartbeatURL: URL { spoolDir.appendingPathComponent("heartbeat.json") }

    /// MetricKit only reports crashes of non-debugger launches, at the NEXT
    /// launch, and not always. This catches the crash in-process: a Swift
    /// runtime trap (index out of range, force unwrap, precondition,
    /// `Dictionary(uniqueKeysWithValues:)` duplicates) arrives as SIGTRAP,
    /// `fatalError`/ObjC exceptions as SIGABRT, bad memory as SIGSEGV/SIGBUS.
    /// The handler writes signal + breadcrumb + the crashing thread's
    /// backtrace with async-signal-safe calls, then re-raises so the OS
    /// still terminates the process normally.
    private func installSignalCapture() {
        Self.signalPathC = strdup(signalFileURL.path)
        // Alternate signal stack: a stack overflow (deep SwiftUI recursion)
        // can't run a handler on the exhausted stack — without this those
        // crashes leave nothing behind.
        var altStack = stack_t()
        altStack.ss_size = 256 * 1024
        altStack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: altStack.ss_size, alignment: 16)
        altStack.ss_flags = 0
        sigaltstack(&altStack, nil)
        for sig in [SIGTRAP, SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashSignalHandler
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.writeUncaughtException(exception)
        }
    }

    private static func writeUncaughtException(_ exception: NSException) {
        guard let path = signalPathC, access(path, F_OK) != 0 else { return }
        let text = "exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
            + "crumb \(PerfBreadcrumb.currentIfAvailable?.crumb ?? "?")\n"
            + exception.callStackSymbols.joined(separator: "\n") + "\n"
        try? text.write(toFile: String(cString: path), atomically: true, encoding: .utf8)
    }

    /// Previous run left a signal capture → one `crash` row.
    private func ingestPendingSignalCrash() -> Bool {
        guard let text = try? String(contentsOf: signalFileURL, encoding: .utf8) else { return false }
        try? FileManager.default.removeItem(at: signalFileURL)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return false }
        let head = lines.removeFirst()
        var crumb = "?"
        if let first = lines.first, first.hasPrefix("crumb ") {
            crumb = String(first.dropFirst(6)); lines.removeFirst()
        }
        let reason: String
        if head.hasPrefix("signal "), let n = Int32(head.dropFirst(7)) {
            reason = "\(Self.signalName(n)) caught in-process — last op: \(crumb)"
        } else {
            reason = "\(head) — last op: \(crumb)"
        }
        let frames = lines.filter { !$0.isEmpty }
        var row = baseRow(kind: "crash")
        row["signal"] = head
        row["termination_reason"] = reason
        row["call_stack"] = ["crashed_thread": frames]
        spool(row)
        print("[CrashReporter] Ingested previous run's signal crash: \(reason)")
        return true
    }

    // MARK: - Heartbeat (abnormal-termination detector)

    /// Written every watchdog cycle. Read once at the next launch.
    func writeHeartbeat() {
        let (crumb, at) = PerfBreadcrumb.current
        let row: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "state": AppRunState.current,
            "crumb": crumb,
            "crumb_age": Date().timeIntervalSince(at),
            "footprint_mb": MemoryFootprint.megabytes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        try? data.write(to: heartbeatURL, options: .atomic)
    }

    private func ingestPreviousHeartbeat(hadSignalCrash: Bool) {
        guard let data = try? Data(contentsOf: heartbeatURL),
              let hb = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? FileManager.default.removeItem(at: heartbeatURL)
        guard !hadSignalCrash else { return }
        let state = hb["state"] as? String ?? "?"
        // Background / inactive / terminating endings are normal (suspend
        // then evict, or the user swiped it away). Only an ACTIVE ending
        // with no crash record is suspicious.
        guard state == "active" || state == "foreground" || state == "launching" else { return }
        let ts = hb["ts"] as? Double ?? 0
        let gap = Date().timeIntervalSince1970 - ts
        let crumb = hb["crumb"] as? String ?? "?"
        let age = hb["crumb_age"] as? Double ?? 0
        let mb = hb["footprint_mb"] as? Int ?? -1
        var row = baseRow(kind: "abnormal_exit")
        row["termination_reason"] = "previous run ended while \(state) with no crash record (SIGKILL: watchdog/jetsam, or stopped from Xcode) — last op: \(crumb) (\(String(format: "%.1f", age))s old), footprint \(mb) MB, last heartbeat \(Int(gap))s before this launch"
        spool(row)
        print("[CrashReporter] Previous run ended abnormally: \(row["termination_reason"] ?? "")")
    }

    private func baseRow(kind: String) -> [String: Any] {
        var sysinfo = utsname()
        uname(&sysinfo)
        let model = withUnsafeBytes(of: &sysinfo.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        var row: [String: Any] = [
            "kind": kind,
            "app_version": "\(version) (\(build))",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "device_model": model,
            "crashed_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let userID = Self.persistedUserID() {
            row["user_id"] = userID
        }
        return row
    }

    // MARK: - Spool + upload

    private var spoolDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CrashReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func spool(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        let file = spoolDir.appendingPathComponent("\(UUID().uuidString).json")
        try? data.write(to: file, options: .atomic)
        print("[CrashReporter] Spooled \(row["kind"] ?? "?") report (\(row["termination_reason"] ?? row["signal"] ?? ""))")
    }

    private func uploadSpooled() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: spoolDir, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" } ?? []
        guard !files.isEmpty else { return }
        print("[CrashReporter] Uploading \(files.count) spooled report(s)")
        for file in files {
            guard let body = try? Data(contentsOf: file) else { continue }
            var request = URLRequest(url: SupabaseConfig.url.appendingPathComponent("rest/v1/crash_reports"))
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(SupabaseConfig.publishableKey)", forHTTPHeaderField: "Authorization")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("[CrashReporter] Upload failed (\(code)) — will retry next launch")
                    return
                }
                try? FileManager.default.removeItem(at: file)
                print("[CrashReporter] Uploaded crash report \(file.lastPathComponent)")
            }
            task.resume()
        }
    }
}

/// Signal handler: async-signal-safe path only — open/write/backtrace_symbols_fd,
/// no Swift allocation beyond the tiny header. Re-raises with the default
/// action so the process still dies the normal way.
private func crashSignalHandler(_ sig: Int32) {
    if let path = CrashReporter.signalPathC {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            var header = "signal \(sig)\ncrumb \(PerfBreadcrumb.currentIfAvailable?.crumb ?? "?")\n"
            header.withUTF8 { buf in _ = write(fd, buf.baseAddress, buf.count) }
            let n = backtrace(CrashReporter.frameBuffer, 64)
            backtrace_symbols_fd(CrashReporter.frameBuffer, n, fd)
            close(fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
