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
        // Retry anything a previous launch failed to upload.
        queue.async { self.uploadSpooled() }
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
