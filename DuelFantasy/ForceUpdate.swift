import SwiftUI

/// Checks the App Store for a newer version of the installed build via the
/// public iTunes Search API. No keys, no auth — just GET the lookup JSON
/// for our bundle ID and compare the `version` field against
/// `CFBundleShortVersionString`.
///
/// Used to drive a blocking "Update Required" screen when a critical
/// backend change ships and older clients shouldn't keep running.
actor AppVersionChecker {
    static let shared = AppVersionChecker()

    private var lastCheckAt: Date?
    private let throttle: TimeInterval = 3600 // at most once per hour

    struct VersionInfo: Equatable, Identifiable {
        let installed: String
        let latest: String
        let appStoreURL: URL?
        var id: String { "\(installed)→\(latest)" }
        var isOutdated: Bool {
            AppVersionChecker.compareVersions(installed, latest) == .orderedAscending
        }
    }

    /// Returns version info only when the installed build is BEHIND the
    /// App Store's published version. Returns nil otherwise (already
    /// up-to-date, network failed, throttled within the last hour, etc.).
    func checkForUpdate(force: Bool = false) async -> VersionInfo? {
        if !force, let last = lastCheckAt, Date().timeIntervalSince(last) < throttle {
            return nil
        }
        guard let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let bundleID = Bundle.main.bundleIdentifier,
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)") else {
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let latest = first["version"] as? String else {
            return nil
        }
        lastCheckAt = Date()
        let appStoreURL = (first["trackViewUrl"] as? String).flatMap(URL.init(string:))
        let info = VersionInfo(installed: installed, latest: latest, appStoreURL: appStoreURL)
        return info.isOutdated ? info : nil
    }

    /// Lexicographic numeric comparison: "1.0.2" < "1.0.10" < "1.1".
    /// Missing components are treated as 0 ("1.0" == "1.0.0").
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }
}

/// Full-screen blocking view shown when the installed app is behind the
/// App Store's latest version. No dismiss path — user must tap "Update
/// Now" to open the App Store, install the update, and relaunch.
struct ForceUpdateView: View {
    let installedVersion: String
    let latestVersion: String
    let appStoreURL: URL?

    private var brandPurple: Color { Color(red: 0.48, green: 0.23, blue: 0.93) }
    private var brandGreen: Color { Color(red: 0.05, green: 0.55, blue: 0.40) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [brandPurple, brandGreen],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)

                Text("Update Required")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text("A new version of DuelFantasy is available.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                    Text("Update to keep playing.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("INSTALLED")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(installedVersion)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    Image(systemName: "arrow.right")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                    VStack(spacing: 4) {
                        Text("LATEST")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(latestVersion)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 32)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Spacer()

                Button {
                    Haptics.medium()
                    if let url = appStoreURL {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Update Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white)
                        .foregroundStyle(brandPurple)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }
}
