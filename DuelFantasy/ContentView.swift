import SwiftUI
import UIKit
import PhotosUI
import SensitiveContentAnalysis

/// Lightweight haptic helper — call `Haptics.light()` or `.medium()` on any button tap.
enum Haptics {
    private static let light_gen = UIImpactFeedbackGenerator(style: .light)
    private static let medium_gen = UIImpactFeedbackGenerator(style: .medium)
    static func light() { light_gen.impactOccurred() }
    static func medium() { medium_gen.impactOccurred() }
}

/// File-backed `Data` storage with the same surface as `@AppStorage`.
///
/// Why: CFPreferences rejects writes >= 4 MB and silently degrades the whole
/// defaults domain into "direct mode" — at which point unrelated writes
/// (like the rotated Supabase refresh token in `persistSession`) also fail,
/// leaving the user stuck in an "Invalid Refresh Token: Already Used" loop
/// forever. Large blobs (`dfs_history_data`, `history_data`) belong on disk,
/// not in NSUserDefaults.
///
/// On first read, transparently migrates any legacy UserDefaults value for
/// the same key into the file store and removes the defaults entry.
@propertyWrapper
struct FileBlob: DynamicProperty {
    @State private var storage: Data
    private let key: String

    init(_ key: String) {
        self.key = key
        self._storage = State(initialValue: FileBlobStore.shared.load(key: key))
    }

    var wrappedValue: Data {
        get { storage }
        nonmutating set {
            storage = newValue
            FileBlobStore.shared.save(key: key, data: newValue)
        }
    }

    var projectedValue: Binding<Data> {
        Binding(get: { storage }, set: { wrappedValue = $0 })
    }
}

final class FileBlobStore: @unchecked Sendable {
    static let shared = FileBlobStore()

    private let queue = DispatchQueue(label: "FileBlobStore", attributes: .concurrent)
    private var cache: [String: Data] = [:]

    /// One-time-per-launch sweep. UserDefaults has a hard 4MB CFPreferences
    /// ceiling; past it, ALL writes fail silently AND reads return corrupt data
    /// (`decode: bad range`), which scrambled the live RR aggregation. Legacy
    /// cache blobs (Tiers bot fields, etc.) that were never migrated to disk —
    /// because their owning tournament was never re-opened this session — keep
    /// the domain bloated. Delete any oversized value outright: caches
    /// regenerate, and every real setting (session, rr_score, profile) is tiny.
    static func sweepOversizedDefaults(thresholdBytes: Int = 262_144) {
        let defaults = UserDefaults.standard
        var removed = 0
        var freed = 0
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let data = value as? Data, data.count > thresholdBytes else { continue }
            defaults.removeObject(forKey: key)
            removed += 1
            freed += data.count
            print("[FileBlobStore] swept oversized UserDefaults key '\(key)' (\(data.count) bytes)")
        }
        if removed > 0 {
            print("[FileBlobStore] sweep removed \(removed) oversized key(s), freed ~\(freed / 1024)KB — UserDefaults back under the 4MB ceiling")
        }
    }

    func load(key: String) -> Data {
        queue.sync {
            if let cached = cache[key] { return cached }
            let url = Self.url(for: key)
            if let onDisk = try? Data(contentsOf: url) {
                cache[key] = onDisk
                return onDisk
            }
            // One-time migration from UserDefaults — the legacy storage
            // that overflowed CFPreferences. Move it to disk and scrub
            // the defaults entry so subsequent writes don't try to push
            // the same bloated blob through CFPreferences again.
            let defaults = UserDefaults.standard
            if let legacy = defaults.data(forKey: key), !legacy.isEmpty {
                cache[key] = legacy
                do {
                    try legacy.write(to: url, options: .atomic)
                    defaults.removeObject(forKey: key)
                    print("[FileBlobStore] migrated \(key) (\(legacy.count) bytes) from UserDefaults → \(url.lastPathComponent)")
                } catch {
                    print("[FileBlobStore] migration write failed for \(key): \(error.localizedDescription)")
                }
                return legacy
            }
            cache[key] = Data()
            return Data()
        }
    }

    func save(key: String, data: Data) {
        queue.async(flags: .barrier) {
            self.cache[key] = data
            let url = Self.url(for: key)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("[FileBlobStore] write failed for \(key) (\(data.count) bytes): \(error.localizedDescription)")
            }
            // Defensive: if a legacy defaults entry was re-shadowed by some
            // call site we missed, clear it so the next process launch
            // doesn't reload the wrong source of truth.
            if UserDefaults.standard.data(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private static func url(for key: String) -> URL {
        let manager = FileManager.default
        let base: URL
        do {
            base = try manager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        } catch {
            base = manager.temporaryDirectory
        }
        let dir = base.appendingPathComponent("DuelFantasy", isDirectory: true)
        try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).bin")
    }
}

/// ViewModifier that observes per-sport DFS rrScore, historyData, and settledTournamentData
/// and fans changes out to all sibling view models. Extracted to reduce body type-check complexity.
private struct DFSSyncModifiers: ViewModifier {
    @Bindable var dfs: DFSViewModel
    @Bindable var nhl: DFSViewModel
    @Bindable var mlb: DFSViewModel
    @Bindable var pga: DFSViewModel
    @Bindable var playoffTiers: PlayoffTiersViewModel
    @Bindable var tennisBracket: TennisBracketViewModel
    @Bindable var golfTiers: GolfTiersViewModel
    @Bindable var soccerTiers: SoccerTiersViewModel
    var syncRR: (Int) -> Void
    var syncHistory: (Data) -> Void
    var syncSettled: (Data) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(RRSyncModifier(dfs: dfs, nhl: nhl, mlb: mlb, pga: pga, playoffTiers: playoffTiers, tennisBracket: tennisBracket, golfTiers: golfTiers, soccerTiers: soccerTiers, syncRR: syncRR))
            .modifier(HistorySyncModifier(dfs: dfs, nhl: nhl, mlb: mlb, pga: pga, playoffTiers: playoffTiers, tennisBracket: tennisBracket, golfTiers: golfTiers, soccerTiers: soccerTiers, syncHistory: syncHistory))
            .modifier(SettledSyncModifier(dfs: dfs, nhl: nhl, mlb: mlb, pga: pga, playoffTiers: playoffTiers, tennisBracket: tennisBracket, golfTiers: golfTiers, soccerTiers: soccerTiers, syncSettled: syncSettled))
    }
}

private struct RRSyncModifier: ViewModifier {
    @Bindable var dfs: DFSViewModel
    @Bindable var nhl: DFSViewModel
    @Bindable var mlb: DFSViewModel
    @Bindable var pga: DFSViewModel
    @Bindable var playoffTiers: PlayoffTiersViewModel
    @Bindable var tennisBracket: TennisBracketViewModel
    @Bindable var golfTiers: GolfTiersViewModel
    @Bindable var soccerTiers: SoccerTiersViewModel
    var syncRR: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: dfs.rrScore) { _, v in syncRR(v) }
            .onChange(of: nhl.rrScore) { _, v in syncRR(v) }
            .onChange(of: mlb.rrScore) { _, v in syncRR(v) }
            .onChange(of: pga.rrScore) { _, v in syncRR(v) }
            .onChange(of: playoffTiers.rrScore) { _, v in syncRR(v) }
            .onChange(of: tennisBracket.rrScore) { _, v in syncRR(v) }
            .onChange(of: golfTiers.rrScore) { _, v in syncRR(v) }
            .onChange(of: soccerTiers.rrScore) { _, v in syncRR(v) }
    }
}

private struct HistorySyncModifier: ViewModifier {
    @Bindable var dfs: DFSViewModel
    @Bindable var nhl: DFSViewModel
    @Bindable var mlb: DFSViewModel
    @Bindable var pga: DFSViewModel
    @Bindable var playoffTiers: PlayoffTiersViewModel
    @Bindable var tennisBracket: TennisBracketViewModel
    @Bindable var golfTiers: GolfTiersViewModel
    @Bindable var soccerTiers: SoccerTiersViewModel
    var syncHistory: (Data) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: dfs.dfsHistoryData) { _, v in syncHistory(v) }
            .onChange(of: nhl.dfsHistoryData) { _, v in syncHistory(v) }
            .onChange(of: mlb.dfsHistoryData) { _, v in syncHistory(v) }
            .onChange(of: pga.dfsHistoryData) { _, v in syncHistory(v) }
            .onChange(of: playoffTiers.dfsHistoryData) { _, v in syncHistory(v) }
            .onChange(of: tennisBracket.dfsHistoryData) { _, v in syncHistory(v) }
            .onChange(of: golfTiers.dfsHistoryData) { _, v in syncHistory(v) }
            .onChange(of: soccerTiers.dfsHistoryData) { _, v in syncHistory(v) }
    }
}

private struct SettledSyncModifier: ViewModifier {
    @Bindable var dfs: DFSViewModel
    @Bindable var nhl: DFSViewModel
    @Bindable var mlb: DFSViewModel
    @Bindable var pga: DFSViewModel
    @Bindable var playoffTiers: PlayoffTiersViewModel
    @Bindable var tennisBracket: TennisBracketViewModel
    @Bindable var golfTiers: GolfTiersViewModel
    @Bindable var soccerTiers: SoccerTiersViewModel
    var syncSettled: (Data) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: dfs.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: nhl.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: mlb.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: pga.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: playoffTiers.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: tennisBracket.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: golfTiers.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: soccerTiers.settledTournamentData) { _, v in syncSettled(v) }
    }
}

/// Settled-set write-back for the DFS view models that SettledSyncModifier
/// doesn't cover (epl, ucl, wc, ufc, nfl, cfb, ncaam, wnba). ONLY the settled
/// set — NOT history. History write-back from these VMs caused a clobber storm
/// (syncHistoryData is a plain overwrite and applyServerHistory prunes), so
/// history persists via the cross-sport merge instead. But the settled set is
/// tiny and effectively append-only, and it's the durable half of
/// `isTournamentFinished`. Without this, a self-healed WNBA/NCAAM contest's
/// settled flag never reached the shared store, so a graded contest kept
/// wobbling between a Past Result and a LIVE 0.0 card as syncs re-ran.
private struct ExtraSettledSyncModifier: ViewModifier {
    @Bindable var epl: DFSViewModel
    @Bindable var ucl: DFSViewModel
    @Bindable var wc: DFSViewModel
    @Bindable var ufc: DFSViewModel
    @Bindable var nfl: DFSViewModel
    @Bindable var cfb: DFSViewModel
    @Bindable var ncaam: DFSViewModel
    @Bindable var wnba: DFSViewModel
    var syncSettled: (Data) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: epl.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: ucl.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: wc.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: ufc.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: nfl.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: cfb.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: ncaam.settledTournamentData) { _, v in syncSettled(v) }
            .onChange(of: wnba.settledTournamentData) { _, v in syncSettled(v) }
    }
}

struct ContentView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("profile_name") private var profileName: String = ""
    @AppStorage("profile_avatar_url") private var profileAvatarURL: String = ""
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var avatarUploading: Bool = false
    @State private var avatarBlockedAlert: String?
    @AppStorage("odds_api_key") private var oddsAPIKey: String = AppSecrets.defaultOddsAPIKey
    @AppStorage("rr_score") private var rrScore: Int = 1000
    // Last fully-synced total RR, shown instantly on launch so the number is
    // stable from the first frame instead of climbing as async sources load.
    @AppStorage("last_stable_rr") private var lastStableRR: Int = 1000
    @State private var rrSyncReady = false
    // Last DFS-RR delta from AFTER the launch settle completed (the correct,
    // fully-loaded value — e.g. with both WC lineups). Shown on the DFS pill
    // instantly so the home screen reads the right number from the first frame
    // instead of the under-counted live value that takes ~15s to re-derive on a
    // flaky connection. Int.min = no snapshot yet (fall back to live).
    @AppStorage("last_stable_dfs_rr") private var lastStableDfsRR: Int = Int.min
    @State private var dfsSettleReady = false
    // Fire the token-change fallback history sync at most once. The token
    // thrashes (refreshes repeatedly), and re-spawning the cross-sport sync on
    // every change flooded the network and starved the real sync.
    @State private var didFireTokenHistorySync = false
    @AppStorage("wins") private var wins: Int = 0
    @AppStorage("losses") private var losses: Int = 0
    // File-backed so the encoded history blob can grow past the 4 MB
    // CFPreferences limit without poisoning the rest of the defaults
    // domain (which would silently break `persistSession` writes).
    @FileBlob("history_data") private var historyData: Data
    @FileBlob("dfs_history_data") private var dfsHistoryData: Data
    // Settled-set must live on disk too: when the UserDefaults domain crosses
    // the 4MB CFPreferences ceiling, AppStorage writes fail SILENTLY, so the
    // settled flags never persisted and finished contests (e.g. the RBC PGA
    // ones) reappeared as LIVE 0.0 cards every launch until the self-heal
    // re-settled them. FileBlob auto-migrates the existing UserDefaults value.
    @FileBlob("dfs_settled_tournaments") private var settledTournamentData: Data
    @AppStorage("dfs_settlement_version") private var dfsSettlementVersion: Int = 0
    @AppStorage("last_user_id") private var lastUserID: String = ""

    @State private var draftName: String = ""

    // On disk, not UserDefaults: these pick blobs grow with every pick the user
    // makes and were helping push the CFPreferences domain past its 4MB ceiling,
    // which silently dropped EVERY UserDefaults write — including tiny keys like
    // `rr_score`. That's why the RR counter loaded stale and visibly climbed to
    // the real value on each launch. FileBlob auto-migrates the existing keys.
    @FileBlob("picks_by_match") private var picksByMatchData: Data
    @FileBlob("resolved_matches") private var resolvedMatchesData: Data
    @FileBlob("pick_details") private var pickDetailsData: Data
    @State private var picksByMatch: [String: String] = [:]
    @State private var resolvedMatches: Set<String> = []
    @State private var pickDetails: [String: PickDetail] = [:]
    @State private var knownMatchesByID: [String: Match] = [:]
    @State private var matches: [Match] = []
    @State private var isLoadingMatches: Bool = false
    @State private var matchesError: String?
    @State private var selectedLeagueFilter: String? = nil
    @State private var lastGlobalSettlement: Date = .distantPast

    @State private var dfsViewModel = DFSViewModel()
    @State private var nhlDFSViewModel = DFSViewModel(
        sport: "NHL",
        slateProvider: ESPNNHLDFSSlateProvider(),
        scoringProvider: ESPNNHLDFSLiveScoringProvider()
    )
    @State private var mlbDFSViewModel = DFSViewModel(
        sport: "MLB",
        slateProvider: ESPNMLBDFSSlateProvider(),
        scoringProvider: ESPNMLBDFSLiveScoringProvider()
    )
    @State private var eplDFSViewModel = DFSViewModel(
        sport: "EPL",
        slateProvider: ESPNSoccerDFSSlateProvider(league: .epl),
        scoringProvider: ESPNSoccerDFSLiveScoringProvider(league: .epl)
    )
    @State private var uclDFSViewModel = DFSViewModel(
        sport: "UCL",
        slateProvider: ESPNSoccerDFSSlateProvider(league: .ucl),
        scoringProvider: ESPNSoccerDFSLiveScoringProvider(league: .ucl)
    )
    @State private var wcDFSViewModel = DFSViewModel(
        sport: "WC",
        slateProvider: ESPNSoccerDFSSlateProvider(league: .worldCup),
        scoringProvider: ESPNSoccerDFSLiveScoringProvider(league: .worldCup)
    )
    @State private var pgaDFSViewModel = DFSViewModel(
        sport: "PGA",
        slateProvider: ConfiguredGolfDFSSlateProvider(),
        scoringProvider: ESPNPGADFSLiveScoringProvider()
    )
    @State private var ufcDFSViewModel = DFSViewModel(
        sport: "UFC",
        slateProvider: ESPNUFCDFSSlateProvider(),
        scoringProvider: ESPNUFCDFSLiveScoringProvider()
    )
    @State private var nflDFSViewModel = DFSViewModel(
        sport: "NFL",
        slateProvider: ESPNNFLDFSSlateProvider(),
        scoringProvider: ESPNNFLDFSLiveScoringProvider()
    )
    @State private var cfbDFSViewModel = DFSViewModel(
        sport: "CFB",
        slateProvider: ESPNNCAAFBDFSSlateProvider(),
        scoringProvider: ESPNNCAAFBDFSLiveScoringProvider()
    )
    @State private var ncaamDFSViewModel = DFSViewModel(
        sport: "NCAAM",
        slateProvider: ESPNNCAAMDFSSlateProvider(),
        scoringProvider: ESPNNCAAMDFSLiveScoringProvider()
    )
    @State private var wnbaDFSViewModel = DFSViewModel(
        sport: "WNBA",
        slateProvider: ESPNWNBADFSSlateProvider(),
        scoringProvider: ESPNWNBADFSLiveScoringProvider()
    )
    @State private var bestBallViewModel = BestBallViewModel()
    @State private var playoffTiersViewModel = PlayoffTiersViewModel()
    @State private var tennisBracketViewModel = TennisBracketViewModel()
    @State private var golfTiersViewModel = GolfTiersViewModel()
    @State private var soccerTiersViewModel = SoccerTiersViewModel()
    @State private var selectedTab: Int = 0
    @State private var selectedDFSResult: DFSResult? = nil

    // Friends & Leaderboard
    @State private var leaderboardProfiles: [LeaderboardProfile] = []
    @State private var friendships: [FriendshipRecord] = []
    @State private var friendProfiles: [String: LeaderboardProfile] = [:]
    @State private var isLoadingLeaderboard: Bool = false
    @State private var showAddFriend: Bool = false
    @State private var showDeleteAccountConfirm: Bool = false
    @State private var isDeletingAccount: Bool = false
    @State private var deleteAccountError: String? = nil
    /// Set when the App Store has a newer version than the installed build.
    /// Drives the blocking `ForceUpdateView` cover at the root.
    @State private var pendingUpdate: AppVersionChecker.VersionInfo? = nil
    @State private var friendSearchText: String = ""
    @State private var friendSearchResults: [LeaderboardProfile] = []
    @State private var isSearchingFriends: Bool = false
    @State private var lastLeaderboardLoad: Date = .distantPast
    @State private var isRunningLeaderboardLoad: Bool = false
    @State private var hasPerformedInitialSync: Bool = false
    @State private var needsRRRecompute: Bool = false
    // Persisted (not @State): the home-screen "Pick'em +N" pill reads this,
    // and it used to sit at +0 from launch until the first successful
    // settled-picks fetch — or indefinitely during a server outage.
    @AppStorage("serverPickemRRDelta") private var serverPickemRRDelta: Int = 0

    // Time-filtered leaderboard
    enum LeaderboardTimeFrame: String, CaseIterable {
        case weekly = "Weekly"
        case monthly = "Monthly"
        case allTime = "All Time"
    }
    enum LeaderboardGameFilter: String, CaseIterable {
        case all = "All"
        case pickem = "Pick'em"
        case dfs = "DFS"
    }
    @State private var leaderboardTimeFrame: LeaderboardTimeFrame = .allTime
    @State private var leaderboardGameFilter: LeaderboardGameFilter = .all
    @State private var timeFilteredLeaderboard: [LeaderboardProfile] = []
    @State private var timeFilteredFriendProfiles: [String: LeaderboardProfile] = [:]
    @State private var isLoadingTimeFiltered: Bool = false
    /// Per-(game filter, time frame) cache of aggregated leaderboard profiles.
    /// Flipping the segmented pickers re-fired full cross-user scans of
    /// pickem_picks + dfs_tournament_results on EVERY tap — this keeps a tab
    /// tour to at most one fetch per combination per TTL window.
    @State private var timeFilteredCache: [String: (profiles: [LeaderboardProfile], fetchedAt: Date)] = [:]
    private static let timeFilteredCacheTTL: TimeInterval = 120

    private var matchProvider: MatchProvider {
        ConfiguredMatchProvider(apiKey: oddsAPIKey)
    }

    private let resultProvider: MatchResultProvider = ESPNMatchResultProvider()

    @State private var predictionHistory: [PredictionRecord] = []

    private var winRate: Int {
        let total = wins + losses
        guard total > 0 else { return 0 }
        return Int((Double(wins) / Double(total)) * 100.0)
    }

    /// Pick'em RR delta: computed from server settled picks (set during loadLeaderboardAndFriends)
    private var pickemRRDelta: Int {
        serverPickemRRDelta
    }

    /// DFS RR delta: sum of stored rrDelta values from local DFS history,
    /// merged across all sport view models and deduplicated by canonical
    /// owner. Previously this only summed `dfsViewModel.dfsHistory` (NBA's
    /// history), so Pick'em screen showed e.g. "+366" while the Contests
    /// page (which already merges all sports) showed "+501". The mismatch
    /// was the difference between NBA-only and full cross-sport totals.
    private var dfsRRDelta: Int {
        let sources: [DFSViewModel] = [
            dfsViewModel, nhlDFSViewModel, mlbDFSViewModel, pgaDFSViewModel,
            eplDFSViewModel, uclDFSViewModel, wcDFSViewModel,
            ufcDFSViewModel, nflDFSViewModel, cfbDFSViewModel,
            ncaamDFSViewModel, wnbaDFSViewModel
        ]
        func canonicalVM(for tid: String) -> DFSViewModel? {
            if tid.hasPrefix("pga-") { return pgaDFSViewModel }
            if tid.hasPrefix("nhl-") { return nhlDFSViewModel }
            if tid.hasPrefix("ncaam-") { return ncaamDFSViewModel }
            if tid.hasPrefix("wnba-") { return wnbaDFSViewModel }
            if tid.hasPrefix("mlb-") { return mlbDFSViewModel }
            if tid.hasPrefix("epl-") { return eplDFSViewModel }
            if tid.hasPrefix("ucl-") { return uclDFSViewModel }
            if tid.hasPrefix("wc-")  { return wcDFSViewModel  }
            if tid.hasPrefix("ufc-") { return ufcDFSViewModel }
            if tid.hasPrefix("nfl-") { return nflDFSViewModel }
            if tid.hasPrefix("cfb-") { return cfbDFSViewModel }
            if tid.hasPrefix("nba-") { return dfsViewModel    }
            return nil
        }
        // Mirror `unifiedMyContestsContent`'s dedup key (DFSContestView.swift):
        //   • SG tid → `<sport>-sg-<gameID>-<entryCount>#<ln>` (date stripped)
        //   • Otherwise → full `<tid>#<ln>`
        // Without this, home-screen DFS total drifts from My Contests because
        // the old slate-identity collapse rolled H2H/5-Man/2000-person into
        // one row by largest size, dropping the small-contest RR deltas
        // (e.g. a -10 5-Man) from the home-screen accumulator.
        var byKey: [String: DFSResult] = [:]
        for vm in sources {
            for result in vm.dfsHistory {
                let tid = result.tournamentId ?? result.id.uuidString
                if let owner = canonicalVM(for: tid), owner !== vm {
                    continue
                }
                let ln = result.lineupNumber ?? 1
                let key: String = {
                    var stripped = tid
                    if let range = stripped.range(of: #"-i\d+$"#, options: .regularExpression) {
                        stripped.removeSubrange(range)
                    }
                    if let sgRange = stripped.range(of: "-sg-"),
                       let firstDash = stripped.firstIndex(of: "-") {
                        let sport = String(stripped[..<firstDash])
                        let afterSG = String(stripped[sgRange.upperBound...])
                        return "\(sport)-sg-\(afterSG)#\(ln)"
                    }
                    return "\(stripped)#\(ln)"
                }()
                if byKey[key] == nil {
                    byKey[key] = result
                }
            }
        }
        return byKey.values.reduce(0) { $0 + $1.rrDelta }
    }

    /// Displayed total RR — always derived from components so the pills add up.
    /// This avoids drift from incremental rrScore += delta between syncs.
    private var displayedRR: Int {
        1000 + pickemRRDelta + dfsRRDelta
    }

    /// DFS-RR delta shown on the home pill. Before the launch settle finishes
    /// (which re-derives slow-to-load rows like a 2nd WC lineup over a flaky
    /// connection), show the post-settle snapshot from last session so the
    /// number is correct from the first frame; switch to live once settled.
    private var shownDfsRR: Int {
        if dfsSettleReady || lastStableDfsRR == Int.min { return dfsRRDelta }
        return lastStableDfsRR
    }

    /// Diagnostic: dump the per-sport row breakdown + the WC/PGA rows in detail
    /// so we can DIFF the home vs My Contests state and see exactly which rows
    /// only appear on one screen.
    func logRRBreakdown(_ context: String) {
        let vms: [(String, DFSViewModel)] = [
            ("nba", dfsViewModel), ("nhl", nhlDFSViewModel), ("mlb", mlbDFSViewModel),
            ("pga", pgaDFSViewModel), ("epl", eplDFSViewModel), ("ucl", uclDFSViewModel),
            ("wc", wcDFSViewModel), ("ufc", ufcDFSViewModel), ("nfl", nflDFSViewModel),
            ("cfb", cfbDFSViewModel), ("ncaam", ncaamDFSViewModel), ("wnba", wnbaDFSViewModel)
        ]
        print("=== [RR-DEBUG \(context)] dfsRRDelta=\(dfsRRDelta) pickem=\(pickemRRDelta) displayed=\(displayedRR) ===")
        for (name, vm) in vms {
            let rows = vm.dfsHistory.filter { ($0.tournamentId ?? "").hasPrefix(name + "-") }
            guard !rows.isEmpty else { continue }
            let sum = rows.reduce(0) { $0 + $1.rrDelta }
            print("  [\(name)] \(rows.count) rows, rrSum=\(sum)")
            if name == "wc" || name == "pga" {
                for r in rows {
                    print("    tid=\(r.tournamentId ?? "?") ln=\(r.lineupNumber.map(String.init) ?? "nil") rr=\(r.rrDelta) pts=\(r.lineupPoints)")
                }
            }
        }
    }

    /// The RR actually shown in the UI. `displayedRR` is recomputed live from
    /// history that loads ASYNCHRONOUSLY on launch (pickem picks + 12 DFS VMs),
    /// so before the first full sync completes it reads LOW (a sport's rows
    /// aren't loaded yet) and visibly climbs as each source lands — the
    /// "374 → 399 on entering My Contests" the user kept seeing. To present a
    /// stable number from the first frame, we show the persisted last-stable RR
    /// until `rrSyncReady`, then switch to the live value (and keep persisting
    /// it). The persisted value is last session's fully-synced total, so the
    /// home screen and My Contests agree immediately.
    private var shownRR: Int {
        // Total pill, consistent with the DFS pill: uses the post-settle DFS-RR
        // snapshot until the live settle catches up. Server pushes still use the
        // live `displayedRR`, so persistence stays accurate.
        1000 + pickemRRDelta + shownDfsRR
    }

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.94, green: 0.98, blue: 0.95),
                Color(red: 0.95, green: 0.97, blue: 1.00),
                Color(red: 0.98, green: 0.99, blue: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        mainTabView
            .fullScreenCover(item: $pendingUpdate) { info in
                ForceUpdateView(
                    installedVersion: info.installed,
                    latestVersion: info.latest,
                    appStoreURL: info.appStoreURL
                )
                .interactiveDismissDisabled(true)
            }
            .task {
                // Check on launch. Throttled to once per hour inside the
                // checker so re-renders during a session don't spam the
                // iTunes Search API.
                if let info = await AppVersionChecker.shared.checkForUpdate() {
                    await MainActor.run { pendingUpdate = info }
                }
            }
            .modifier(DFSSyncModifiers(
                dfs: dfsViewModel, nhl: nhlDFSViewModel,
                mlb: mlbDFSViewModel, pga: pgaDFSViewModel,
                playoffTiers: playoffTiersViewModel,
                tennisBracket: tennisBracketViewModel,
                golfTiers: golfTiersViewModel,
                soccerTiers: soccerTiersViewModel,
                syncRR: syncRRScore, syncHistory: syncHistoryData, syncSettled: syncSettledData
            ))
            .modifier(ExtraSettledSyncModifier(
                epl: eplDFSViewModel, ucl: uclDFSViewModel, wc: wcDFSViewModel,
                ufc: ufcDFSViewModel, nfl: nflDFSViewModel, cfb: cfbDFSViewModel,
                ncaam: ncaamDFSViewModel, wnba: wnbaDFSViewModel,
                syncSettled: syncSettledData
            ))
            .onChange(of: dfsHistoryData) { _, v in syncHistoryData(v) }
            .onChange(of: settledTournamentData) { _, v in syncSettledData(v) }
            .onChange(of: picksByMatch) { _, newValue in
                picksByMatchData = (try? JSONEncoder().encode(newValue)) ?? Data()
            }
            .onChange(of: resolvedMatches) { _, newValue in
                resolvedMatchesData = (try? JSONEncoder().encode(newValue)) ?? Data()
            }
            .onChange(of: historyData) { _, newValue in
                predictionHistory = Self.deduplicatedHistory(from: newValue)
            }
            .onAppear {
                predictionHistory = Self.deduplicatedHistory(from: historyData)
            }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            pickemTab
                .tabItem {
                    Label("Pick'em", systemImage: "sportscourt")
                }
                .tag(0)

            DFSContestView(viewModel: dfsViewModel, nhlViewModel: nhlDFSViewModel, mlbViewModel: mlbDFSViewModel, pgaViewModel: pgaDFSViewModel, eplViewModel: eplDFSViewModel, uclViewModel: uclDFSViewModel, wcViewModel: wcDFSViewModel, ufcViewModel: ufcDFSViewModel, nflViewModel: nflDFSViewModel, cfbViewModel: cfbDFSViewModel, ncaamViewModel: ncaamDFSViewModel, wnbaViewModel: wnbaDFSViewModel, onDeletePastContest: { tid in deletePastDFSContest(tournamentID: tid) }, onRegradePastContest: { tid in regradePastDFSContest(tournamentID: tid) })
                .tabItem {
                    Label("DFS", systemImage: "person.3")
                }
                .tag(1)

            FantasyHubView(bestBallViewModel: bestBallViewModel, playoffTiersViewModel: playoffTiersViewModel, tennisBracketViewModel: tennisBracketViewModel, golfTiersViewModel: golfTiersViewModel, soccerTiersViewModel: soccerTiersViewModel)
                .tabItem {
                    Label("Fantasy", systemImage: "star.circle")
                }
                .tag(2)

            ChatListView(bestBallViewModel: bestBallViewModel, golfTiersViewModel: golfTiersViewModel, playoffTiersViewModel: playoffTiersViewModel, soccerTiersViewModel: soccerTiersViewModel, tennisBracketViewModel: tennisBracketViewModel)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(3)

            profileTab
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(4)
        }
        .tint(brandPurple)
        // Dedicated cross-sport history sync that fires whenever the access
        // token resolves (including the initial mount when it's already
        // loaded from keychain). The launch `.task` below can fire BEFORE
        // auth is ready, and `.onChange(of: auth.accessToken)` doesn't fire
        // if the token was already set at first render — so without this,
        // UCL/UFC/etc. only loaded when the user navigated to DFS, which is
        // exactly the symptom the user kept hitting.
        // Keyed on the STABLE userID, NOT accessToken. The token thrashes
        // (refreshes repeatedly), and keying on it cancelled the in-flight
        // history sync before it could finish — so on the home screen the
        // golf/past rows never loaded and the DFS RR read low until the DFS tab
        // ran its own sync. userID is stable per session, so this fires once and
        // runs to completion; the token is read at call time and 401s retry
        // inside SupabaseService.
        .task(id: auth.userID) {
            guard let userID = auth.userID, let token = auth.accessToken else { return }
            print("[DFS-SharedSync] task(id: userID) fired — userID=\(userID.prefix(8))…")
            let allVMs: [DFSViewModel] = [
                dfsViewModel, nhlDFSViewModel, mlbDFSViewModel, pgaDFSViewModel,
                eplDFSViewModel, uclDFSViewModel, wcDFSViewModel,
                ufcDFSViewModel, nflDFSViewModel, cfbDFSViewModel,
                ncaamDFSViewModel, wnbaDFSViewModel
            ]
            await DFSViewModel.syncAllSportsHistoryFromServer(
                vms: allVMs, userID: userID, accessToken: token,
                onMergedHistory: { blob in
                    syncHistoryData(blob)
                }
            )
            // Full history is now loaded — switch the pill to the live value and
            // snapshot it so the next launch shows the correct total immediately.
            await MainActor.run {
                rrSyncReady = true
                lastStableRR = displayedRR
                logRRBreakdown("HOME/shared-sync-done")
            }
        }
        .task {
            syncAuthToViewModel()
            // Run leaderboard sync and pick settlement concurrently.
            // Settlement uses resolvedMatches (populated by leaderboard) to avoid
            // double-counting, but settlePick itself is idempotent on the server
            // (returns false if already settled), so concurrent execution is safe.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await loadLeaderboardAndFriends(force: true) }
                group.addTask { @MainActor in
                    await reconcileCompletedPicks()
                    if Date().timeIntervalSince(lastGlobalSettlement) >= 60 {
                        await reconcileAllPicks()
                        lastGlobalSettlement = Date()
                    }
                }
            }
            // Push corrected RR to server if v18 migration just fired.
            if needsRRRecompute, let uid = auth.userID, let token = auth.accessToken {
                needsRRRecompute = false
                await pushCorrectedStats(userID: uid, accessToken: token)
            }
            // Cross-sport DFS history sync at LAUNCH so the Pick'em home
            // "DFS +X" breakdown isn't missing UCL/UFC/WC/NFL/CFB until
            // the user wanders into My Contests. All 10 fetches run in
            // parallel and write to their OWN VM's `dfsHistoryData` — we
            // deliberately skip the per-iteration `syncHistoryData` fan-out
            // that was causing the "20-second ratcheting number" effect
            // (each iteration broadcast a blob that overwrote others
            // mid-sync, forcing N intermediate UI updates). The unified
            // RR delta + Contests page already use a canonical-owner
            // merge across all VMs, so each one keeping its own results
            // is sufficient.
            Task { @MainActor in
                // MUST include ncaam + wnba. The merged blob this produces is
                // written back as the source of truth (syncHistoryData), and the
                // merge only contributes rows from the VMs passed here. Omitting
                // the WNBA/NCAAM VMs meant a freshly self-healed WNBA Past Result
                // (which lives only on the WNBA VM until it propagates) was
                // dropped from the merged blob and overwritten — flipping the
                // settled contest back to a LIVE 0.0 card.
                let allVMs: [DFSViewModel] = [
                    dfsViewModel, nhlDFSViewModel, mlbDFSViewModel, pgaDFSViewModel,
                    eplDFSViewModel, uclDFSViewModel, wcDFSViewModel,
                    ufcDFSViewModel, nflDFSViewModel, cfbDFSViewModel,
                    ncaamDFSViewModel, wnbaDFSViewModel
                ]
                if let userID = auth.userID, let token = auth.accessToken {
                    await DFSViewModel.syncAllSportsHistoryFromServer(
                        vms: allVMs, userID: userID, accessToken: token,
                        onMergedHistory: { blob in
                            syncHistoryData(blob)
                        }
                    )
                }
            }
        }
        .onAppear {
            if draftName.isEmpty {
                draftName = profileName
            }
            syncAuthToViewModel()
            if dfsSettlementVersion < 14 {
                // Clean up all bad DFS history entries and reset RR to baseline.
                settledTournamentData = Data()
                dfsHistoryData = Data()
                rrScore = 1000
            }
            if dfsSettlementVersion < 18 {
                // v18: Hard correction — previous recompute counted pre-v14 settled
                // picks from the server, inflating the score. Set the known-correct
                // value and push to server. Double-counting bug is fixed, so
                // incremental settlement will keep it accurate going forward.
                dfsSettlementVersion = 18
                rrScore = 1284
                wins = 211
                losses = 230
                needsRRRecompute = true  // triggers server push
            }
            if dfsSettlementVersion < 19 {
                // v19: recovery from the "empty fetch wrote 0-0 to server"
                // bug. Don't hard-code values — just clear the throttle so
                // the next leaderboard sync runs immediately and the new
                // empty-fetch guard preserves whatever it actually finds.
                // If the server has settled picks, they'll be adopted; if
                // it doesn't, the local 0-0 stays put (no further damage).
                dfsSettlementVersion = 19
                lastLeaderboardLoad = .distantPast
                hasPerformedInitialSync = false
            }
            initDFSViewModels()
            restorePersistedPicks()

            // Self-heal wins/losses AND Pick'em RR delta from local
            // prediction history. If the server-overwrite bug zeroed the
            // counters but `history_data` is still populated (i.e., Recent
            // Results renders just fine but the stat tiles show 0-0 and
            // the RR breakdown shows Pick'em +0), reconstruct everything
            // from the local rrDelta column. Positive delta = win,
            // negative = loss, sum = total Pick'em RR contribution.
            if wins == 0 && losses == 0 && serverPickemRRDelta == 0 {
                let restored = Self.deduplicatedHistory(from: historyData)
                if !restored.isEmpty {
                    let derivedWins = restored.filter { $0.rrDelta > 0 }.count
                    let derivedLosses = restored.filter { $0.rrDelta < 0 }.count
                    let derivedDelta = restored.reduce(0) { $0 + $1.rrDelta }
                    if derivedWins + derivedLosses > 0 {
                        print("[Pick'em] Self-heal: rebuilt from history — W=\(derivedWins), L=\(derivedLosses), RR delta=\(derivedDelta), from \(restored.count) records")
                        wins = derivedWins
                        losses = derivedLosses
                        serverPickemRRDelta = derivedDelta
                    }
                }
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            // When returning to Pick'em tab, settle any completed picks so
            // the RR display stays current. Don't re-fetch from server here
            // (that causes RR to jump from competing recalculation paths).
            if newTab == 0 {
                Task { await reconcileCompletedPicks() }
            }
        }
        // Pick'em settlement — loop runs every 60s in the foreground.
        // Previously 30s, but picks don't grade fast enough to matter and
        // every cycle hits Supabase for unresolved/active picks. Skipped
        // entirely when app is backgrounded (scenePhase != .active) so the
        // user's device isn't pinging the DB while asleep.
        .task(id: "pickem-settlement-timer") {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                if scenePhase == .active {
                    await reconcileCompletedPicks()
                    if Date().timeIntervalSince(lastGlobalSettlement) >= 120 {
                        await reconcileAllPicks()
                        lastGlobalSettlement = Date()
                    }
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        // DFS settlement — slower loop (every 60s) for slate loading, tournament
        // settlement, history sync, and live refresh.
        .task(id: "dfs-settlement-timer") {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                // Settle past contests FIRST, before the slow/serial slate loads
                // below. Those 9 loadSlateIfNeeded calls hit flaky external APIs
                // and can take 10s+ (or get cancelled), which used to delay the
                // PGA settle so long that the home-screen RR never picked up
                // finished golf contests — it only updated once the DFS tab ran
                // its own settle pass. checkAndSettle needs no slate, so run it
                // up front and include EVERY sport (wc/wnba/ncaam were missing).
                // Run all sports' settlement CONCURRENTLY (My Contests already
                // does this via parallel initSportPipeline, which is why its RR
                // is right). Serial here meant the multi-lineup fix for a
                // mid-list sport like WC rarely finished before the user looked,
                // so the home DFS-RR pill under-counted (e.g. a 2nd WC lineup
                // missing → 374 vs the correct 399). Each VM settles only its
                // own sport's rows; dfsRRDelta reads each sport from its owner
                // VM, so concurrency is safe for the total.
                await withTaskGroup(of: Void.self) { group in
                    for vm in [dfsViewModel, nhlDFSViewModel, mlbDFSViewModel, pgaDFSViewModel,
                               eplDFSViewModel, uclDFSViewModel, wcDFSViewModel, ufcDFSViewModel,
                               nflDFSViewModel, cfbDFSViewModel, ncaamDFSViewModel, wnbaDFSViewModel] {
                        group.addTask { await vm.checkAndSettleUnsettledTournaments() }
                    }
                }
                await dfsViewModel.syncHistoryFromServer()
                logRRBreakdown("HOME/launch-settle-done")
                // Settle finished — this dfsRRDelta is the fully-loaded value.
                // Snapshot it and switch the pill to live; next launch shows it
                // instantly instead of the slow re-derive.
                dfsSettleReady = true
                lastStableDfsRR = dfsRRDelta

                await dfsViewModel.loadSlateIfNeeded()
                await nhlDFSViewModel.loadSlateIfNeeded()
                await mlbDFSViewModel.loadSlateIfNeeded()
                await pgaDFSViewModel.loadSlateIfNeeded()
                await eplDFSViewModel.loadSlateIfNeeded()
                await uclDFSViewModel.loadSlateIfNeeded()
                await ufcDFSViewModel.loadSlateIfNeeded()
                await nflDFSViewModel.loadSlateIfNeeded()
                await cfbDFSViewModel.loadSlateIfNeeded()
                // wc/ncaam/wnba were missing here — without their periodic
                // refreshLive, World Cup never re-probed confirmed XIs or re-ran
                // bot late-swap while the app was open, so confirmed starters and
                // bot lineups only updated on a cold launch (force-quit). That's
                // what left staggered-slate bots stuck on the first game and
                // stale single-game lineups holding non-starters.
                await wcDFSViewModel.loadSlateIfNeeded()
                await ncaamDFSViewModel.loadSlateIfNeeded()
                await wnbaDFSViewModel.loadSlateIfNeeded()
                if dfsViewModel.tournament != nil && !dfsViewModel.fieldEntries.isEmpty {
                    await dfsViewModel.refreshLive()
                }
                if nhlDFSViewModel.tournament != nil && !nhlDFSViewModel.fieldEntries.isEmpty {
                    await nhlDFSViewModel.refreshLive()
                }
                if mlbDFSViewModel.tournament != nil && !mlbDFSViewModel.fieldEntries.isEmpty {
                    await mlbDFSViewModel.refreshLive()
                }
                if pgaDFSViewModel.tournament != nil && !pgaDFSViewModel.fieldEntries.isEmpty {
                    await pgaDFSViewModel.refreshLive()
                }
                if eplDFSViewModel.tournament != nil && !eplDFSViewModel.fieldEntries.isEmpty {
                    await eplDFSViewModel.refreshLive()
                }
                if uclDFSViewModel.tournament != nil && !uclDFSViewModel.fieldEntries.isEmpty {
                    await uclDFSViewModel.refreshLive()
                }
                if ufcDFSViewModel.tournament != nil && !ufcDFSViewModel.fieldEntries.isEmpty {
                    await ufcDFSViewModel.refreshLive()
                }
                if nflDFSViewModel.tournament != nil && !nflDFSViewModel.fieldEntries.isEmpty {
                    await nflDFSViewModel.refreshLive()
                }
                if cfbDFSViewModel.tournament != nil && !cfbDFSViewModel.fieldEntries.isEmpty {
                    await cfbDFSViewModel.refreshLive()
                }
                if wcDFSViewModel.tournament != nil && !wcDFSViewModel.fieldEntries.isEmpty {
                    await wcDFSViewModel.refreshLive()
                }
                if ncaamDFSViewModel.tournament != nil && !ncaamDFSViewModel.fieldEntries.isEmpty {
                    await ncaamDFSViewModel.refreshLive()
                }
                if wnbaDFSViewModel.tournament != nil && !wnbaDFSViewModel.fieldEntries.isEmpty {
                    await wnbaDFSViewModel.refreshLive()
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onChange(of: auth.accessToken) { _, newToken in
            syncAuthToViewModel()
            if newToken != nil {
                Task {
                    await loadLeaderboardAndFriends(force: true)
                    syncAuthToViewModel()
                }
                // Auth just became available — fire the cross-sport DFS
                // history sync now in case the launch `.task` ran before
                // the token was set. Without this, UCL/UFC/etc. only loaded
                // when the user navigated to My Contests (which triggered
                // its own per-VM sync). The shared fetch hits Postgres
                // exactly twice across all 10 sports, so re-firing is cheap.
                Task { @MainActor in
                    // Only ONCE — token churn must not re-spawn this (the
                    // primary sync is the .task(id: userID) above).
                    guard !didFireTokenHistorySync else { return }
                    // Include ncaam + wnba (see the launch sync above) — the
                    // merged blob overwrites the source of truth, so a VM left
                    // out here has its rows erased.
                    let allVMs: [DFSViewModel] = [
                        dfsViewModel, nhlDFSViewModel, mlbDFSViewModel, pgaDFSViewModel,
                        eplDFSViewModel, uclDFSViewModel, wcDFSViewModel,
                        ufcDFSViewModel, nflDFSViewModel, cfbDFSViewModel,
                        ncaamDFSViewModel, wnbaDFSViewModel
                    ]
                    if let userID = auth.userID, let token = auth.accessToken {
                        didFireTokenHistorySync = true
                        print("[DFS-SharedSync] auth.accessToken changed — firing shared sync (once)")
                        await DFSViewModel.syncAllSportsHistoryFromServer(
                            vms: allVMs, userID: userID, accessToken: token,
                            onMergedHistory: { blob in
                                syncHistoryData(blob)
                            }
                        )
                    }
                }
            }
        }
        .onChange(of: profileName) { _, newValue in
            dfsViewModel.profileName = newValue
            nhlDFSViewModel.profileName = newValue
            mlbDFSViewModel.profileName = newValue
            pgaDFSViewModel.profileName = newValue
            eplDFSViewModel.profileName = newValue
            uclDFSViewModel.profileName = newValue
            ufcDFSViewModel.profileName = newValue
            nflDFSViewModel.profileName = newValue
            cfbDFSViewModel.profileName = newValue
            ncaamDFSViewModel.profileName = newValue
            wnbaDFSViewModel.profileName = newValue
            bestBallViewModel.profileName = newValue
            playoffTiersViewModel.profileName = newValue
            tennisBracketViewModel.profileName = newValue
            golfTiersViewModel.profileName = newValue
            soccerTiersViewModel.profileName = newValue
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // Returning to the foreground: immediately re-probe confirmed XIs
            // and re-run bot late-swap for any live contest. Confirmed lineups
            // drop while the app is backgrounded; without this the user had to
            // force-quit to see them update (the 60s poll loop also covers it,
            // but only after up to a minute, and only once it resumes).
            Task {
                for vm in [dfsViewModel, nhlDFSViewModel, mlbDFSViewModel, pgaDFSViewModel,
                           eplDFSViewModel, uclDFSViewModel, wcDFSViewModel, ufcDFSViewModel,
                           nflDFSViewModel, cfbDFSViewModel, ncaamDFSViewModel, wnbaDFSViewModel] {
                    if vm.tournament != nil && !vm.fieldEntries.isEmpty {
                        await vm.refreshLive()
                    }
                }
            }
        }
    }

    private func syncAuthToViewModel() {
        dfsViewModel.accessToken = auth.accessToken
        dfsViewModel.userID = auth.userID
        dfsViewModel.userEmail = auth.userEmail
        nhlDFSViewModel.accessToken = auth.accessToken
        nhlDFSViewModel.userID = auth.userID
        nhlDFSViewModel.userEmail = auth.userEmail
        mlbDFSViewModel.accessToken = auth.accessToken
        mlbDFSViewModel.userID = auth.userID
        mlbDFSViewModel.userEmail = auth.userEmail
        pgaDFSViewModel.accessToken = auth.accessToken
        pgaDFSViewModel.userID = auth.userID
        pgaDFSViewModel.userEmail = auth.userEmail
        eplDFSViewModel.accessToken = auth.accessToken
        eplDFSViewModel.userID = auth.userID
        eplDFSViewModel.userEmail = auth.userEmail
        uclDFSViewModel.accessToken = auth.accessToken
        uclDFSViewModel.userID = auth.userID
        uclDFSViewModel.userEmail = auth.userEmail
        ufcDFSViewModel.accessToken = auth.accessToken
        ufcDFSViewModel.userID = auth.userID
        ufcDFSViewModel.userEmail = auth.userEmail
        nflDFSViewModel.accessToken = auth.accessToken
        nflDFSViewModel.userID = auth.userID
        nflDFSViewModel.userEmail = auth.userEmail
        cfbDFSViewModel.accessToken = auth.accessToken
        cfbDFSViewModel.userID = auth.userID
        cfbDFSViewModel.userEmail = auth.userEmail
        ncaamDFSViewModel.accessToken = auth.accessToken
        ncaamDFSViewModel.userID = auth.userID
        ncaamDFSViewModel.userEmail = auth.userEmail
        wnbaDFSViewModel.accessToken = auth.accessToken
        wnbaDFSViewModel.userID = auth.userID
        wnbaDFSViewModel.userEmail = auth.userEmail
        bestBallViewModel.accessToken = auth.accessToken
        bestBallViewModel.userID = auth.userID
        bestBallViewModel.profileName = profileName
        playoffTiersViewModel.accessToken = auth.accessToken
        playoffTiersViewModel.userID = auth.userID
        playoffTiersViewModel.profileName = profileName
        tennisBracketViewModel.accessToken = auth.accessToken
        tennisBracketViewModel.userID = auth.userID
        tennisBracketViewModel.profileName = profileName
        golfTiersViewModel.accessToken = auth.accessToken
        golfTiersViewModel.userID = auth.userID
        golfTiersViewModel.userEmail = auth.userEmail
        golfTiersViewModel.profileName = profileName
        soccerTiersViewModel.accessToken = auth.accessToken
        soccerTiersViewModel.userID = auth.userID
        soccerTiersViewModel.profileName = profileName
    }

    private func initDFSViewModels() {
        // One-time cleanup: deduplicate history data that may contain stale duplicates
        // from previous settlement/sync bugs.
        if !dfsHistoryData.isEmpty {
            dfsHistoryData = dfsViewModel.encodedDFSHistoryFromRaw(dfsHistoryData)
        }

        dfsViewModel.dfsHistoryData = dfsHistoryData
        dfsViewModel.settledTournamentData = settledTournamentData
        dfsViewModel.rrScore = rrScore
        dfsViewModel.profileName = profileName
        nhlDFSViewModel.dfsHistoryData = dfsHistoryData
        nhlDFSViewModel.settledTournamentData = settledTournamentData
        nhlDFSViewModel.rrScore = rrScore
        nhlDFSViewModel.profileName = profileName
        mlbDFSViewModel.dfsHistoryData = dfsHistoryData
        mlbDFSViewModel.settledTournamentData = settledTournamentData
        mlbDFSViewModel.rrScore = rrScore
        mlbDFSViewModel.profileName = profileName
        pgaDFSViewModel.dfsHistoryData = dfsHistoryData
        pgaDFSViewModel.settledTournamentData = settledTournamentData
        pgaDFSViewModel.rrScore = rrScore
        pgaDFSViewModel.profileName = profileName
        eplDFSViewModel.dfsHistoryData = dfsHistoryData
        eplDFSViewModel.settledTournamentData = settledTournamentData
        eplDFSViewModel.rrScore = rrScore
        eplDFSViewModel.profileName = profileName
        uclDFSViewModel.dfsHistoryData = dfsHistoryData
        uclDFSViewModel.settledTournamentData = settledTournamentData
        uclDFSViewModel.rrScore = rrScore
        uclDFSViewModel.profileName = profileName
        ufcDFSViewModel.dfsHistoryData = dfsHistoryData
        ufcDFSViewModel.settledTournamentData = settledTournamentData
        ufcDFSViewModel.rrScore = rrScore
        ufcDFSViewModel.profileName = profileName
        nflDFSViewModel.dfsHistoryData = dfsHistoryData
        nflDFSViewModel.settledTournamentData = settledTournamentData
        nflDFSViewModel.rrScore = rrScore
        nflDFSViewModel.profileName = profileName
        cfbDFSViewModel.dfsHistoryData = dfsHistoryData
        cfbDFSViewModel.settledTournamentData = settledTournamentData
        cfbDFSViewModel.rrScore = rrScore
        cfbDFSViewModel.profileName = profileName
        ncaamDFSViewModel.dfsHistoryData = dfsHistoryData
        ncaamDFSViewModel.settledTournamentData = settledTournamentData
        ncaamDFSViewModel.rrScore = rrScore
        ncaamDFSViewModel.profileName = profileName
        wnbaDFSViewModel.dfsHistoryData = dfsHistoryData
        wnbaDFSViewModel.settledTournamentData = settledTournamentData
        wnbaDFSViewModel.rrScore = rrScore
        wnbaDFSViewModel.profileName = profileName
        playoffTiersViewModel.dfsHistoryData = dfsHistoryData
        playoffTiersViewModel.settledTournamentData = settledTournamentData
        playoffTiersViewModel.rrScore = rrScore
        playoffTiersViewModel.profileName = profileName
        tennisBracketViewModel.dfsHistoryData = dfsHistoryData
        tennisBracketViewModel.settledTournamentData = settledTournamentData
        tennisBracketViewModel.rrScore = rrScore
        tennisBracketViewModel.profileName = profileName
        golfTiersViewModel.dfsHistoryData = dfsHistoryData
        golfTiersViewModel.settledTournamentData = settledTournamentData
        golfTiersViewModel.rrScore = rrScore
        golfTiersViewModel.profileName = profileName
        soccerTiersViewModel.dfsHistoryData = dfsHistoryData
        soccerTiersViewModel.settledTournamentData = settledTournamentData
        soccerTiersViewModel.rrScore = rrScore
        soccerTiersViewModel.profileName = profileName
    }

    private func restorePersistedPicks() {
        if let decoded = try? JSONDecoder().decode([String: String].self, from: picksByMatchData) {
            picksByMatch = decoded
        }
        if let decoded = try? JSONDecoder().decode(Set<String>.self, from: resolvedMatchesData) {
            resolvedMatches = decoded
        }
        if let decoded = try? JSONDecoder().decode([String: PickDetail].self, from: pickDetailsData) {
            pickDetails = decoded
        }
    }

    private func syncRRScore(_ value: Int) {
        rrScore = value
        dfsViewModel.rrScore = value
        nhlDFSViewModel.rrScore = value
        mlbDFSViewModel.rrScore = value
        pgaDFSViewModel.rrScore = value
        eplDFSViewModel.rrScore = value
        uclDFSViewModel.rrScore = value
        ufcDFSViewModel.rrScore = value
        nflDFSViewModel.rrScore = value
        cfbDFSViewModel.rrScore = value
        ncaamDFSViewModel.rrScore = value
        wnbaDFSViewModel.rrScore = value
        playoffTiersViewModel.rrScore = value
        tennisBracketViewModel.rrScore = value
        golfTiersViewModel.rrScore = value
        soccerTiersViewModel.rrScore = value
    }

    private func syncHistoryData(_ value: Data) {
        // Plain distribution. (An earlier "union" version recomputed a new blob
        // and re-set every VM, which retriggered onChange(of: vm.dfsHistoryData)
        // → syncHistory → syncHistoryData in a feedback loop that could spin
        // forever and crash the app. Keep this a simple idempotent fan-out.)
        dfsHistoryData = value
        dfsViewModel.dfsHistoryData = value
        nhlDFSViewModel.dfsHistoryData = value
        mlbDFSViewModel.dfsHistoryData = value
        pgaDFSViewModel.dfsHistoryData = value
        eplDFSViewModel.dfsHistoryData = value
        uclDFSViewModel.dfsHistoryData = value
        ufcDFSViewModel.dfsHistoryData = value
        nflDFSViewModel.dfsHistoryData = value
        cfbDFSViewModel.dfsHistoryData = value
        ncaamDFSViewModel.dfsHistoryData = value
        wnbaDFSViewModel.dfsHistoryData = value
        playoffTiersViewModel.dfsHistoryData = value
        tennisBracketViewModel.dfsHistoryData = value
        golfTiersViewModel.dfsHistoryData = value
        soccerTiersViewModel.dfsHistoryData = value
    }

    private func syncSettledData(_ value: Data) {
        settledTournamentData = value
        dfsViewModel.settledTournamentData = value
        nhlDFSViewModel.settledTournamentData = value
        mlbDFSViewModel.settledTournamentData = value
        pgaDFSViewModel.settledTournamentData = value
        eplDFSViewModel.settledTournamentData = value
        uclDFSViewModel.settledTournamentData = value
        ufcDFSViewModel.settledTournamentData = value
        nflDFSViewModel.settledTournamentData = value
        cfbDFSViewModel.settledTournamentData = value
        ncaamDFSViewModel.settledTournamentData = value
        wnbaDFSViewModel.settledTournamentData = value
        playoffTiersViewModel.settledTournamentData = value
        tennisBracketViewModel.settledTournamentData = value
        golfTiersViewModel.settledTournamentData = value
        soccerTiersViewModel.settledTournamentData = value
    }

    /// Checks whether the current user has ANY server DFS results.
    /// If the server returns zero results but local history has entries,
    /// those entries are stale (from a previous account on the same device)
    /// and are wiped. This avoids fetching with a large limit — a single
    /// small request with limit=1 is enough to distinguish "new account" from
    /// "returning account".
    private func cleanStaleLocalDFSHistory() async {
        guard let token = auth.accessToken, let userID = auth.userID else { return }
        let localHistory = dfsViewModel.dfsHistory
        guard !localHistory.isEmpty else { return }  // nothing to clean
        do {
            // Fetch just 1 result to check if this user has ANY server DFS history
            let probe = try await SupabaseService.shared.fetchUserDFSHistory(userID: userID, limit: 1, accessToken: token)
            if probe.isEmpty {
                // Server has zero results for this user — wipe all local DFS data
                syncHistoryData(Data())
                syncSettledData(Data())
            }
        } catch {
            print("[DFS] cleanStaleLocalDFSHistory failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pick'em Tab

    private var pickemTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    rankHeroCard
                    statsCard
                    matchesSection
                    recentResultsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(appBackground.ignoresSafeArea())
            .navigationTitle("Pick'em")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        Task { await loadMatches(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await loadMatchesIfNeeded()
            // Match-fetch loop: 60s in foreground, paused in background.
            // Pick'em tab is also gated on `selectedTab == 0` so the loop
            // doesn't keep hammering ESPN+Supabase when the user is on a
            // different tab (most cycle's cost is the 18-request ESPN fan-
            // out, but the settlement that follows also hits Supabase).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard scenePhase == .active, selectedTab == 0 else { continue }
                await loadMatches(force: true)
            }
        }
    }

    @ViewBuilder
    private var deleteAccountSection: some View {
        Button {
            Haptics.medium()
            showDeleteAccountConfirm = true
        } label: {
            Text(isDeletingAccount ? "Deleting…" : "Delete Account")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.12))
                .foregroundStyle(.red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isDeletingAccount)

        Text("Deleting your account permanently removes your profile, picks, DFS entries, and stats. This cannot be undone.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
    }

    // MARK: - Profile Tab

    private var profileTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Profile hero card
                    VStack(spacing: 16) {
                        // Avatar — tap to pick a new photo. Replaces the
                        // letter-initial fallback whenever the user has
                        // uploaded an avatar.
                        PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                            ZStack {
                                if !profileAvatarURL.isEmpty,
                                   let url = URL(string: profileAvatarURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().scaledToFill()
                                        default:
                                            Circle().fill(brandPurple)
                                            Text(String((profileName.isEmpty ? auth.userEmail : profileName).prefix(1)).uppercased())
                                                .font(.title.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                    .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(brandPurple)
                                        .frame(width: 72, height: 72)
                                    Text(String((profileName.isEmpty ? auth.userEmail : profileName).prefix(1)).uppercased())
                                        .font(.title.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                                if avatarUploading {
                                    Circle()
                                        .fill(.black.opacity(0.4))
                                        .frame(width: 72, height: 72)
                                    ProgressView().tint(.white)
                                }
                                // Camera badge in the corner to signal it's editable.
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(brandPurple)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                    .offset(x: 26, y: 26)
                            }
                        }
                        .onChange(of: avatarPickerItem) { _, newItem in
                            guard let newItem else { return }
                            Task { await handleAvatarSelection(newItem) }
                        }
                        .alert("Photo Blocked", isPresented: Binding(
                            get: { avatarBlockedAlert != nil },
                            set: { if !$0 { avatarBlockedAlert = nil } }
                        ), actions: {
                            Button("OK", role: .cancel) {}
                        }, message: {
                            Text(avatarBlockedAlert ?? "")
                        })

                        Text(profileName.isEmpty ? (auth.userEmail.isEmpty ? "Player" : auth.userEmail) : profileName)
                            .font(.title2.weight(.bold))

                        Text(auth.userEmail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        // RR badge
                        HStack(spacing: 6) {
                            Image(systemName: "trophy.fill")
                                .foregroundStyle(.yellow)
                            Text("\(shownRR) RR")
                                .font(.headline.monospacedDigit())
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                    // Stats grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        profileStatCard(title: "Record", value: "\(wins)-\(losses)", icon: "chart.bar.fill", color: .blue)
                        profileStatCard(title: "Win Rate", value: "\(winRate)%", icon: "percent", color: .purple)
                        profileStatCard(title: "DFS Played", value: "\(dfsViewModel.dfsHistory.count)", icon: "person.3.fill", color: .orange)
                        profileStatCard(
                            title: "Best Rank",
                            value: dfsViewModel.dfsHistory.map { $0.rank }.min().map { "#\($0)" } ?? "-",
                            icon: "star.fill",
                            color: .yellow
                        )
                    }

                    // Analytics
                    NavigationLink {
                        AnalyticsView(userID: auth.userID ?? "", accessToken: auth.accessToken ?? "")
                    } label: {
                        HStack {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundStyle(brandPurple)
                            Text("Analytics")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    }

                    // Pick'em Activity
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pick'em")
                            .font(.headline)

                        // Live picks — filter out resolved picks, then deduplicate by display name
                        // (same real-world match can have different IDs: espn- vs odds-)
                        let rawActivePicks = picksByMatch.filter { !resolvedMatches.contains($0.key) }
                        var seenActiveNames = Set<String>()
                        // Build set of recently settled display names so we can suppress
                        // duplicate IDs for the same game that weren't marked resolved.
                        // Only use the 20 most recent to avoid suppressing rematches.
                        let recentResultNames = Set(predictionHistory.prefix(20).map(\.matchName))
                        let activePicks: [(id: String, team: String, displayName: String, isLive: Bool, dateLabel: String)] = rawActivePicks
                            .sorted(by: { $0.key < $1.key }) // espn- sorts before odds-
                            .compactMap { matchID, team in
                                let match = knownMatchesByID[matchID]
                                let rawDisplayName = match.map { matchDisplayName(for: $0) }
                                    ?? pickDetails[matchID]?.matchName
                                    ?? matchID
                                // If we can't resolve the match to a real display name,
                                // use the picked team name as a fallback so it stays visible.
                                let displayName: String
                                if rawDisplayName.hasPrefix("odds-") || rawDisplayName.hasPrefix("espn-") {
                                    displayName = team
                                } else {
                                    displayName = rawDisplayName
                                }
                                // Skip if this game was recently settled under a different ID
                                // (duplicate from odds-/espn- dedup that wasn't cleaned up).
                                // Only suppress if we can confirm the match is actually finished
                                // (state == "post"). Default to keeping the pick visible if we
                                // can't verify — avoids hiding valid picks for same-name rematches
                                // or when the match data isn't in knownMatchesByID.
                                if recentResultNames.contains(displayName) {
                                    let isConfirmedFinished = match?.state == "post"
                                    if isConfirmedFinished {
                                        return nil
                                    }
                                }
                                // Skip duplicates (same game, different ID)
                                guard seenActiveNames.insert(displayName).inserted else { return nil }
                                let isLive = match?.state == "in"
                                // Format date label (e.g. "4/19")
                                let dateLabel: String = {
                                    let startDate = match?.startsAt ?? pickDetails[matchID]?.startsAt
                                    guard let startDate else { return "" }
                                    let cal = Calendar.current
                                    let month = cal.component(.month, from: startDate)
                                    let day = cal.component(.day, from: startDate)
                                    return "\(month)/\(day)"
                                }()
                                return (id: matchID, team: team, displayName: displayName, isLive: isLive, dateLabel: dateLabel)
                            }
                        if !activePicks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ACTIVE PICKS")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)

                                ForEach(activePicks, id: \.id) { pick in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(pick.isLive ? .red : .orange)
                                            .frame(width: 6, height: 6)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(pick.displayName)
                                                .font(.subheadline)
                                            if !pick.dateLabel.isEmpty {
                                                Text(pick.dateLabel)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(pick.team)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(brandPurple.opacity(0.15))
                                            .foregroundStyle(brandPurple)
                                            .clipShape(Capsule())
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(.bottom, 4)
                        }

                        // Recent results
                        if !predictionHistory.isEmpty {
                            if !activePicks.isEmpty {
                                Divider()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("RECENT RESULTS")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)

                                ForEach(predictionHistory.prefix(10)) { record in
                                    HStack {
                                        Image(systemName: record.rrDelta > 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(record.rrDelta > 0 ? .green : .red)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(record.matchName)
                                                .font(.subheadline)
                                            HStack(spacing: 4) {
                                                Text("Picked \(record.pickedTeam)")
                                                Text("•")
                                                Text(record.loggedAt.formatted(.dateTime.month(.defaultDigits).day()))
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("\(record.rrDelta >= 0 ? "+" : "")\(record.rrDelta)")
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(record.rrDelta >= 0 ? .green : .red)
                                    }
                                    .padding(.vertical, 2)
                                }

                                if predictionHistory.count > 3 {
                                    NavigationLink {
                                        AnalyticsView(userID: auth.userID ?? "", accessToken: auth.accessToken ?? "")
                                    } label: {
                                        Text("See All Picks")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(brandPurple)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                    }
                                }
                            }
                        }

                        if activePicks.isEmpty && predictionHistory.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "sportscourt")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text("No picks yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                    // DFS Results
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DFS Results")
                            .font(.headline)

                        if dfsViewModel.dfsHistory.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "person.3")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                                Text("No DFS results yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        } else {
                            ForEach(dfsViewModel.dfsHistory.prefix(10)) { result in
                                Button {
                                    Haptics.light()
                                    // If this is today's tournament, switch to DFS tab
                                    if result.tournamentTitle == dfsViewModel.tournament?.title {
                                        selectedTab = 1
                                    } else {
                                        selectedDFSResult = result
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(result.tournamentTitle)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text("#\(result.rank)/\(result.totalEntries) • \(String(format: "%.1f", result.lineupPoints)) pts • \(result.loggedAt.formatted(.dateTime.month(.defaultDigits).day()))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta)")
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(result.rrDelta >= 0 ? .green : .red)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 4)
                                if result.id != dfsViewModel.dfsHistory.prefix(10).last?.id {
                                    Divider()
                                }
                            }

                            if dfsViewModel.dfsHistory.count > 3 {
                                NavigationLink {
                                    AnalyticsView(userID: auth.userID ?? "", accessToken: auth.accessToken ?? "", initialTab: 1)
                                } label: {
                                    Text("See All DFS Results")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(brandPurple)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                    // Leaderboard game type filter
                    Picker("Game Type", selection: $leaderboardGameFilter) {
                        ForEach(LeaderboardGameFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: leaderboardGameFilter) { _, _ in
                        if leaderboardGameFilter != .all || leaderboardTimeFrame != .allTime {
                            Task { await loadTimeFilteredLeaderboard() }
                        }
                    }

                    // Leaderboard time filter
                    Picker("Time Frame", selection: $leaderboardTimeFrame) {
                        ForEach(LeaderboardTimeFrame.allCases, id: \.self) { frame in
                            Text(frame.rawValue).tag(frame)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: leaderboardTimeFrame) { _, _ in
                        if leaderboardGameFilter != .all || leaderboardTimeFrame != .allTime {
                            Task { await loadTimeFilteredLeaderboard() }
                        }
                    }

                    // Friends section
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Friends")
                                .font(.headline)
                            Spacer()
                            ShareLink(
                                item: URL(string: "https://apps.apple.com/app/duelfantasy")!,
                                subject: Text("Join me on DuelFantasy!"),
                                message: Text("Download DuelFantasy and compete with me in Pick'em and DFS! My username is \(profileName.isEmpty ? "Player" : profileName).")
                            ) {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Invite")
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray5))
                                .foregroundStyle(.primary)
                                .clipShape(Capsule())
                            }
                            Button {
                                Haptics.light()
                                showAddFriend = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.badge.plus")
                                    Text("Add")
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(brandPurple)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                            }
                        }

                        // Pending requests
                        if !pendingRequests.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Friend Requests")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)

                                ForEach(pendingRequests, id: \.id) { request in
                                    let senderName = friendProfiles[request.requesterID]?.username ?? "User"
                                    HStack {
                                        Text(senderName)
                                            .font(.subheadline.weight(.medium))
                                        Spacer()
                                        Button("Accept") {
                                            Haptics.medium()
                                            Task {
                                                guard let token = auth.accessToken else { return }
                                                try? await SupabaseService.shared.acceptFriendRequest(friendshipID: request.id, accessToken: token)
                                                await loadLeaderboardAndFriends()
                                            }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(brandPurple)
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())

                                        Button("Decline") {
                                            Haptics.light()
                                            Task {
                                                guard let token = auth.accessToken else { return }
                                                try? await SupabaseService.shared.removeFriend(friendshipID: request.id, accessToken: token)
                                                await loadLeaderboardAndFriends()
                                            }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color(.systemGray5))
                                        .foregroundStyle(.primary)
                                        .clipShape(Capsule())
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(.bottom, 4)
                        }

                        // Accepted friends list
                        if displayedFriends.isEmpty && pendingRequests.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "person.2")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text("No friends yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Tap \"Add\" to find players by username")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        } else {
                            // Header
                            HStack {
                                Text("#")
                                    .frame(width: 24, alignment: .leading)
                                Text("PLAYER")
                                Spacer()
                                // DFS has no win-loss record — the column is
                                // pick'em-only and read "0-0" noise under the
                                // DFS filter.
                                if leaderboardGameFilter != .dfs {
                                    Text("W-L")
                                        .frame(width: 65, alignment: .trailing)
                                }
                                Text(leaderboardTimeFrame == .allTime ? "RR" : "+/−")
                                    .frame(width: 70, alignment: .trailing)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .opacity(0)
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                            ForEach(Array(displayedFriends.enumerated()), id: \.element.id) { index, friend in
                                NavigationLink {
                                    UserProfileView(profile: friend, accessToken: auth.accessToken ?? "")
                                } label: {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption.weight(.medium).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, alignment: .leading)
                                        Text(friend.username)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if leaderboardGameFilter != .dfs {
                                            Text("\(friend.wins)-\(friend.losses)")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 65, alignment: .trailing)
                                        }
                                        if leaderboardTimeFrame == .allTime {
                                            Text("\(friend.rrScore)")
                                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                                .frame(width: 70, alignment: .trailing)
                                        } else {
                                            Text(friend.rrScore >= 0 ? "+\(friend.rrScore)" : "\(friend.rrScore)")
                                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                                .foregroundStyle(friend.rrScore > 0 ? brandPurple : (friend.rrScore < 0 ? .red : .secondary))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                                .frame(width: 70, alignment: .trailing)
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                    // Global Leaderboard
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Top 100")
                                .font(.headline)
                            Spacer()
                            if isLoadingLeaderboard || (leaderboardTimeFrame != .allTime && isLoadingTimeFiltered) {
                                ProgressView()
                            }
                        }

                        if displayedLeaderboard.isEmpty {
                            Text(leaderboardTimeFrame == .allTime
                                 ? "No leaderboard data yet"
                                 : "No activity this \(leaderboardTimeFrame == .weekly ? "week" : "month")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        } else {
                            // Header
                            HStack {
                                Text("#")
                                    .frame(width: 28, alignment: .leading)
                                Text("PLAYER")
                                Spacer()
                                // DFS has no win-loss record — the column is
                                // pick'em-only and read "0-0" noise under the
                                // DFS filter.
                                if leaderboardGameFilter != .dfs {
                                    Text("W-L")
                                        .frame(width: 65, alignment: .trailing)
                                }
                                Text(leaderboardTimeFrame == .allTime ? "RR" : "+/−")
                                    .frame(width: 70, alignment: .trailing)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .opacity(0)
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                            ForEach(Array(displayedLeaderboard.enumerated()), id: \.element.id) { index, profile in
                                let isMe = profile.id == auth.userID
                                if isMe {
                                    leaderboardRow(index: index, profile: profile, isMe: true)
                                } else {
                                    NavigationLink {
                                        UserProfileView(profile: profile, accessToken: auth.accessToken ?? "")
                                    } label: {
                                        leaderboardRow(index: index, profile: profile, isMe: false)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                    // Sign out
                    Button {
                        Haptics.medium()
                        Task {
                            await auth.signOut()
                            clearLocalUserData()
                        }
                    } label: {
                        Text("Sign Out")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.systemGray6))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Delete account (Apple App Review 5.1.1(v) requires
                    // an in-app deletion path for any app that supports
                    // account creation).
                    deleteAccountSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(appBackground.ignoresSafeArea())
            .navigationTitle("Profile")
            .alert("Delete Account?", isPresented: $showDeleteAccountConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        isDeletingAccount = true
                        let ok = await auth.deleteAccount()
                        isDeletingAccount = false
                        if ok {
                            clearLocalUserData()
                        } else {
                            deleteAccountError = auth.errorMessage ?? "Couldn't delete account. Please try again."
                        }
                    }
                }
            } message: {
                Text("This permanently removes your account, profile, picks, DFS entries, and stats. This cannot be undone.")
            }
            .alert("Couldn't Delete Account", isPresented: Binding(
                get: { deleteAccountError != nil },
                set: { if !$0 { deleteAccountError = nil } }
            )) {
                Button("OK", role: .cancel) { deleteAccountError = nil }
            } message: {
                Text(deleteAccountError ?? "")
            }
            .task {
                await loadLeaderboardAndFriends()
                // Quick check: if this user has zero server DFS results but local
                // history has entries, wipe the stale data (from a previous account).
                await cleanStaleLocalDFSHistory()
                // Sync DFS history from server for EVERY sport. Run in
                // parallel so the user sees one update instead of the RR
                // number ratcheting through 10 intermediate states. Each
                // VM only fetches results matching its own sport prefix
                // and writes to its own `dfsHistoryData` — the unified
                // RR + Contests page already merge across VMs via the
                // canonical-owner filter, so we don't need to fan the
                // updated blob back to every other VM during the sync.
                // Include ncaam + wnba: this merge writes the FileBlob via
                // syncHistoryData, so it must carry the WNBA/NCAAM VMs or it
                // can never capture their freshly-settled rows into the shared
                // blob (and the contest cards keep flashing in/out).
                let allDFSVMs: [DFSViewModel] = [
                    dfsViewModel, nhlDFSViewModel, mlbDFSViewModel, pgaDFSViewModel,
                    eplDFSViewModel, uclDFSViewModel, wcDFSViewModel,
                    ufcDFSViewModel, nflDFSViewModel, cfbDFSViewModel,
                    ncaamDFSViewModel, wnbaDFSViewModel
                ]
                if let userID = auth.userID, let token = auth.accessToken {
                    await DFSViewModel.syncAllSportsHistoryFromServer(
                        vms: allDFSVMs, userID: userID, accessToken: token,
                        onMergedHistory: { blob in
                            syncHistoryData(blob)
                        }
                    )
                }
                // Also run settlement so stale active picks get resolved
                if Date().timeIntervalSince(lastGlobalSettlement) >= 60 {
                    await reconcileAllPicks()
                    lastGlobalSettlement = Date()
                }
            }
            .sheet(isPresented: $showAddFriend) {
                addFriendSheet
            }
            .sheet(item: $selectedDFSResult) { result in
                dfsResultDetailSheet(result)
            }
        }
    }

    // MARK: - DFS Result Detail Sheet

    private func dfsResultDetailSheet(_ result: DFSResult) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Result hero card
                    VStack(spacing: 16) {
                        Text(result.tournamentTitle)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)

                        HStack(spacing: 24) {
                            VStack(spacing: 4) {
                                Text("RANK")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text("#\(result.rank)")
                                    .font(.title.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                                Text("of \(result.totalEntries)")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))
                            }

                            VStack(spacing: 4) {
                                Text("SCORE")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(String(format: "%.1f", result.lineupPoints))
                                    .font(.title.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                Text("FPTS")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))
                            }

                            VStack(spacing: 4) {
                                Text("RR")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta)")
                                    .font(.title.weight(.bold).monospacedDigit())
                                    .foregroundStyle(result.rrDelta >= 0 ? Color(red: 0.4, green: 1.0, blue: 0.5) : Color(red: 1.0, green: 0.5, blue: 0.5))
                                Text("delta")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.12, blue: 0.22),
                                Color(red: 0.15, green: 0.20, blue: 0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)

                    // Details card
                    VStack(spacing: 12) {
                        detailRow(label: "Tournament", value: result.tournamentTitle)
                        Divider()
                        detailRow(label: "Your Rank", value: "#\(result.rank) of \(result.totalEntries)")
                        Divider()
                        detailRow(label: "Points", value: String(format: "%.1f", result.lineupPoints))
                        Divider()
                        detailRow(label: "RR Change", value: "\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta)")
                        Divider()
                        detailRow(label: "Date", value: result.loggedAt.formatted(date: .abbreviated, time: .shortened))
                        Divider()
                        detailRow(label: "Percentile", value: "\(Int((1.0 - Double(result.rank) / Double(max(1, result.totalEntries))) * 100))%")
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                    // View live button if it's today's tournament
                    if result.tournamentTitle == dfsViewModel.tournament?.title {
                        Button {
                            Haptics.light()
                            selectedDFSResult = nil
                            selectedTab = 1
                        } label: {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("View Live Contest")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(16)
            }
            .background(appBackground.ignoresSafeArea())
            .navigationTitle("DFS Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedDFSResult = nil }
                }
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Add Friend Sheet

    private var addFriendSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    TextField("Search by username...", text: $friendSearchText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Search") {
                        Haptics.light()
                        Task { await searchFriends() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 16)

                if isSearchingFriends {
                    ProgressView()
                        .padding(.top, 20)
                } else if friendSearchResults.isEmpty && !friendSearchText.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No users found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                } else {
                    List(friendSearchResults) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.username)
                                    .font(.subheadline.weight(.medium))
                                Text("\(profile.rrScore) RR • \(profile.wins)-\(profile.losses)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            if friendshipID(with: profile.id) != nil {
                                Text("Added")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Add") {
                                    Haptics.medium()
                                    Task {
                                        guard let uid = auth.userID, let token = auth.accessToken else { return }
                                        try? await SupabaseService.shared.sendFriendRequest(fromUserID: uid, toUserID: profile.id, accessToken: token)
                                        await loadLeaderboardAndFriends()
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(brandPurple)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                Spacer()
            }
            .padding(.top, 8)
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showAddFriend = false
                        friendSearchText = ""
                        friendSearchResults = []
                    }
                }
            }
        }
    }

    private func leaderboardRow(index: Int, profile: LeaderboardProfile, isMe: Bool) -> some View {
        HStack {
            Text("\(index + 1)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(index < 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                .frame(width: 28, alignment: .leading)
            Text(profile.username)
                .font(.subheadline.weight(isMe ? .bold : .medium))
                .foregroundStyle(isMe ? brandPurple : .primary)
            Spacer()
            if leaderboardGameFilter != .dfs {
                Text("\(profile.wins)-\(profile.losses)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 65, alignment: .trailing)
            }
            Group {
                if leaderboardTimeFrame == .allTime {
                    Text("\(profile.rrScore)")
                        .foregroundStyle(isMe ? brandPurple : .primary)
                } else {
                    Text(profile.rrScore >= 0 ? "+\(profile.rrScore)" : "\(profile.rrScore)")
                        .foregroundStyle(profile.rrScore > 0 ? brandPurple : (profile.rrScore < 0 ? .red : .secondary))
                }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 70, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(isMe ? 0 : 1)
        }
        .padding(.vertical, 3)
        .background(isMe ? brandPurple.opacity(0.08) : .clear)
    }

    // MARK: - Time-Filtered Leaderboard

    private func leaderboardCutoffDate(for timeFrame: LeaderboardTimeFrame) -> Date? {
        switch timeFrame {
        case .allTime:
            return nil
        case .monthly:
            return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .weekly:
            // Week starts Monday 3:00 AM EST
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            let now = Date()
            // Find this week's Monday
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            comps.weekday = 2 // Monday
            comps.hour = 3
            comps.minute = 0
            comps.second = 0
            guard let monday3am = cal.date(from: comps) else { return nil }
            // If now is before this week's Monday 3 AM, go back one week
            if monday3am > now {
                return cal.date(byAdding: .weekOfYear, value: -1, to: monday3am)
            }
            return monday3am
        }
    }

    private var displayedLeaderboard: [LeaderboardProfile] {
        if leaderboardGameFilter == .all && leaderboardTimeFrame == .allTime {
            return leaderboardProfiles
        }
        return timeFilteredLeaderboard
    }

    private var displayedFriends: [LeaderboardProfile] {
        if leaderboardGameFilter == .all && leaderboardTimeFrame == .allTime {
            return acceptedFriends
        }
        guard let userID = auth.userID else { return [] }
        return friendships
            .filter { $0.status == "accepted" }
            .compactMap { ship in
                let friendID = ship.requesterID == userID ? ship.addresseeID : ship.requesterID
                return timeFilteredFriendProfiles[friendID]
            }
            .sorted { $0.rrScore > $1.rrScore }
    }

    private func loadTimeFilteredLeaderboard() async {
        // Skip only when both filters are at default (All + All Time)
        guard leaderboardGameFilter != .all || leaderboardTimeFrame != .allTime else { return }
        guard let token = auth.accessToken else { return }

        // Serve from cache when this filter combination was fetched recently —
        // the aggregation scans every user's rows, so it shouldn't re-run on
        // every picker tap.
        let cacheKey = "\(leaderboardGameFilter.rawValue)|\(leaderboardTimeFrame.rawValue)"
        if let cached = timeFilteredCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < Self.timeFilteredCacheTTL {
            applyTimeFilteredProfiles(cached.profiles)
            return
        }

        // One in-flight aggregation at a time; rapid picker taps otherwise
        // stack concurrent cross-user scans. The trailing re-run below picks
        // up whatever combo is selected once the in-flight fetch finishes.
        guard !isLoadingTimeFiltered else { return }
        isLoadingTimeFiltered = true
        defer { isLoadingTimeFiltered = false }

        // Snapshot the requested combo — the user can flip pickers mid-fetch,
        // and mixing live state into the query/caching produced hybrid rows.
        let requestedGameFilter = leaderboardGameFilter
        let requestedTimeFrame = leaderboardTimeFrame

        let sinceISO: String
        if requestedTimeFrame == .allTime {
            sinceISO = "2020-01-01T00:00:00Z"
        } else if let cutoff = leaderboardCutoffDate(for: requestedTimeFrame) {
            sinceISO = ISO8601DateFormatter().string(from: cutoff)
        } else {
            return
        }

        do {
            var allPicks: [AllUserSettledPick] = []
            var allDFS: [AllUserDFSResult] = []

            switch requestedGameFilter {
            case .pickem:
                allPicks = try await SupabaseService.shared.fetchAllSettledPicksSince(sinceISO: sinceISO, accessToken: token)
            case .dfs:
                allDFS = try await SupabaseService.shared.fetchAllDFSResultsSince(sinceISO: sinceISO, accessToken: token)
            case .all:
                async let picksFetch = SupabaseService.shared.fetchAllSettledPicksSince(sinceISO: sinceISO, accessToken: token)
                async let dfsFetch = SupabaseService.shared.fetchAllDFSResultsSince(sinceISO: sinceISO, accessToken: token)
                let (picks, dfs) = try await (picksFetch, dfsFetch)
                allPicks = picks
                allDFS = dfs
            }

            // Aggregate per user
            var userStats: [String: (rr: Int, wins: Int, losses: Int)] = [:]

            for pick in allPicks {
                var stats = userStats[pick.userID, default: (rr: 0, wins: 0, losses: 0)]
                stats.rr += pick.rrDelta
                if pick.result == "win" { stats.wins += 1 }
                else if pick.result == "loss" { stats.losses += 1 }
                userStats[pick.userID] = stats
            }

            // Aggregate DFS the same way the home-screen pill derives its
            // total — raw row sums ran ~2x high (profile +3600 vs home +1800):
            //  1. Re-settles INSERT the user's row again with a fresh UUID id,
            //     so the same lineup's RR appears multiple times. Dedupe on
            //     (user, tournament, lineup) keeping the LATEST row.
            //  2. Fantasy modes (tiers/brackets) share dfs_tournament_results
            //     but aren't DFS RR — drop their tids (incl. #group- rows).
            //  3. Admin-excluded contests are filtered from the current
            //     user's local history — apply the same exclusions here.
            let excludedTids = DFSViewModel.excludedTournamentIDs
            var latestByKey: [String: AllUserDFSResult] = [:]
            for dfs in allDFS {
                let tid = dfs.tournamentID ?? UUID().uuidString
                let baseTid = tid.components(separatedBy: "#group-").first ?? tid
                guard !DFSViewModel.isFantasyModeTid(baseTid), !tid.contains("#group-") else { continue }
                guard !excludedTids.contains(tid) else { continue }
                let key = "\(dfs.userID)|\(tid)|\(dfs.lineupOrdinal)"
                if let existing = latestByKey[key] {
                    if (dfs.createdAt ?? .distantPast) > (existing.createdAt ?? .distantPast) {
                        latestByKey[key] = dfs
                    }
                } else {
                    latestByKey[key] = dfs
                }
            }
            for dfs in latestByKey.values {
                var stats = userStats[dfs.userID, default: (rr: 0, wins: 0, losses: 0)]
                stats.rr += dfs.rrDelta
                userStats[dfs.userID] = stats
            }

            // Build LeaderboardProfile entries using usernames from existing profiles
            let usernameMap = Dictionary(uniqueKeysWithValues: leaderboardProfiles.map { ($0.id, $0.username) })
            // Also include friend profiles that might not be in the top 100
            let allUsernames = usernameMap.merging(friendProfiles.mapValues { $0.username }) { existing, _ in existing }

            let avatarsByID = Dictionary(uniqueKeysWithValues: leaderboardProfiles.map { ($0.id, $0.avatarUrl) })
            var profiles: [LeaderboardProfile] = userStats.compactMap { (userID, stats) in
                guard let username = allUsernames[userID] else { return nil }
                return LeaderboardProfile(
                    id: userID,
                    username: username,
                    rrScore: stats.rr,
                    wins: stats.wins,
                    losses: stats.losses,
                    avatarUrl: avatarsByID[userID] ?? nil
                )
            }

            profiles.sort { $0.rrScore > $1.rrScore }

            // Ensure current user appears even with 0 activity
            if let userID = auth.userID,
               !profiles.contains(where: { $0.id == userID }) {
                let username = allUsernames[userID] ?? profileName
                profiles.append(LeaderboardProfile(
                    id: userID,
                    username: username.isEmpty ? "You" : username,
                    rrScore: 0,
                    wins: 0,
                    losses: 0,
                    avatarUrl: avatarsByID[userID] ?? nil
                ))
            }

            timeFilteredCache[cacheKey] = (profiles: profiles, fetchedAt: Date())

            // Only publish if the user is still on the combo we fetched;
            // otherwise the stale result would overwrite the current view.
            if requestedGameFilter == leaderboardGameFilter && requestedTimeFrame == leaderboardTimeFrame {
                applyTimeFilteredProfiles(profiles)
            }
        } catch {
            print("[Leaderboard] Failed to load time-filtered data: \(error.localizedDescription)")
        }

        // If the selection moved while we were fetching, load it now (cache
        // makes this a no-op when the new combo was fetched recently).
        if requestedGameFilter != leaderboardGameFilter || requestedTimeFrame != leaderboardTimeFrame {
            isLoadingTimeFiltered = false
            await loadTimeFilteredLeaderboard()
        }
    }

    /// Publishes an aggregated profile list into the time-filtered
    /// leaderboard + friends state (shared by the fetch and cache-hit paths).
    private func applyTimeFilteredProfiles(_ profiles: [LeaderboardProfile]) {
        timeFilteredLeaderboard = Array(profiles.prefix(100))
        timeFilteredFriendProfiles = Dictionary(uniqueKeysWithValues:
            profiles.map { ($0.id, $0) }
        )
    }

    /// Reads the picked image, compresses to a small JPEG, uploads to the
    /// `avatars` bucket, persists the URL on the profile, and stores it in
    /// AppStorage so the new avatar shows everywhere immediately.
    private func handleAvatarSelection(_ item: PhotosPickerItem) async {
        guard let userID = auth.userID, let token = auth.accessToken else { return }
        await MainActor.run { avatarUploading = true }
        defer { Task { @MainActor in avatarUploading = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }

            // Block nudity / explicit content before the upload via Apple's
            // on-device SensitiveContentAnalysis. Only effective when the
            // user has "Sensitive Content Warning" enabled in iOS Settings;
            // when disabled, the analyzer's policy is `.disabled` and we
            // pass through — server-side scanning would be needed to cover
            // that case.
            if let cg = image.cgImage {
                let analyzer = SCSensitivityAnalyzer()
                if analyzer.analysisPolicy != .disabled {
                    if let analysis = try? await analyzer.analyzeImage(cg),
                       analysis.isSensitive {
                        await MainActor.run {
                            avatarBlockedAlert = "This image was blocked because it appears to contain explicit content. Please choose a different photo."
                            avatarPickerItem = nil
                        }
                        return
                    }
                }
            }

            // Cap longest edge at 512px — avatars are rendered ~72px tall,
            // so anything bigger is wasted bytes + slower download.
            let maxSide: CGFloat = 512
            let scale = min(1.0, maxSide / max(image.size.width, image.size.height))
            let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return }
            let url = try await SupabaseService.shared.uploadAvatar(
                userID: userID, jpegData: jpeg, accessToken: token
            )
            try await SupabaseService.shared.updateProfileAvatarURL(
                userID: userID, avatarURL: url, accessToken: token
            )
            await MainActor.run { profileAvatarURL = url }
        } catch {
            print("[Profile] Avatar upload failed: \(error.localizedDescription)")
        }
    }

    private func profileStatCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - Pick'em Sections

    private var rankHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profileName.isEmpty ? "Welcome to DuelFantasy" : "Welcome, \(profileName)")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Pick winners. Earn RR. No real money.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("\(shownRR)")
                        .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("Total RR")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [brandPurple, Color(red: 0.05, green: 0.55, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: brandPurple.opacity(0.3), radius: 12, y: 6)
    }

    private var statsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pickemStatPill(label: "Record", value: "\(wins)-\(losses)")
                Divider().frame(height: 28)
                pickemStatPill(label: "Win Rate", value: "\(winRate)%")
                Divider().frame(height: 28)
                pickemStatPill(label: "Streak", value: streakText)
            }
            .padding(.vertical, 12)

            Divider().padding(.horizontal, 16)

            // Pick'em vs DFS RR breakdown
            HStack(spacing: 16) {
                rrBreakdownPill(label: "Pick'em", delta: pickemRRDelta)
                rrBreakdownPill(label: "DFS", delta: shownDfsRR)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func rrBreakdownPill(label: String, delta: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(delta >= 0 ? "+" : "")\(delta)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(delta >= 0 ? .green : .red)
        }
        .frame(maxWidth: .infinity)
    }

    private func pickemStatPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var streakText: String {
        let history = predictionHistory
        guard !history.isEmpty else { return "-" }
        let firstResult = history.first!.rrDelta >= 0
        var count = 0
        for record in history {
            if (record.rrDelta >= 0) == firstResult {
                count += 1
            } else {
                break
            }
        }
        return "\(firstResult ? "W" : "L")\(count)"
    }

    private var availableLeagues: [String] {
        let leagues = Set(matches.map { $0.league })
        // WNBA is lowest priority — it goes dead last, after every other league
        // including World Cup (which lands in `rest`). So it's intentionally NOT
        // in the priority `order` list and is appended at the very end.
        let order = ["NBA", "MLB", "NHL", "NFL", "NCAAF", "NCAAB", "EPL", "UCL", "ATP", "WTA"]
        let sorted = order.filter { leagues.contains($0) }
        let rest = leagues.subtracting(Set(order)).subtracting(["WNBA"]).sorted()
        let wnba = leagues.contains("WNBA") ? ["WNBA"] : []
        return sorted + rest + wnba
    }

    private var filteredMatches: [Match] {
        // Shared rule used by every filter branch: hide live/final games the
        // user didn't pick — they just clutter the feed with games whose
        // outcome doesn't affect the user's RR. Pre-game matches always
        // pass through (still pickable).
        let pickedOrPregame: (Match) -> Bool = { match in
            if match.isLive || match.isFinal {
                return picksByMatch[match.id] != nil
            }
            return true
        }
        guard let filter = selectedLeagueFilter else {
            return matches.filter(pickedOrPregame)
        }
        if filter == "Live" {
            return matches.filter { $0.isLive && picksByMatch[$0.id] != nil }
        }
        if filter == "Final" {
            return matches.filter { $0.isFinal && picksByMatch[$0.id] != nil }
        }
        return matches.filter { $0.league == filter && pickedOrPregame($0) }
    }

    private var matchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live & Upcoming")
                .font(.headline)

            // League filter pills
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        leagueFilterPill("All", filter: nil)
                        if matches.contains(where: { $0.isLive && picksByMatch[$0.id] != nil }) {
                            leagueFilterPill("Live", filter: "Live", isLive: true)
                        }
                        if matches.contains(where: { $0.isFinal && picksByMatch[$0.id] != nil }) {
                            leagueFilterPill("Final", filter: "Final")
                        }
                        ForEach(availableLeagues, id: \.self) { league in
                            leagueFilterPill(league, filter: league)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if isLoadingMatches && matches.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading games...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let matchesError {
                VStack(spacing: 10) {
                    Text(matchesError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Haptics.light()
                        Task { await loadMatches(force: true) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if matches.isEmpty {
                Text("No live/upcoming games available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else if filteredMatches.isEmpty {
                Text("No games for this filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredMatches) { match in
                        matchCard(match)
                    }
                }
            }
        }
    }

    private func leagueFilterPill(_ label: String, filter: String?, isLive: Bool = false) -> some View {
        let isSelected = selectedLeagueFilter == filter
        return Button {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedLeagueFilter = filter
            }
        } label: {
            HStack(spacing: 4) {
                if isLive {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? brandPurple : Color(.systemGray6))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func matchCard(_ match: Match) -> some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text(match.league)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(brandPurple)
                    .clipShape(Capsule())

                Spacer()

                if match.isLive {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                        if !match.statusDetail.isEmpty && match.statusDetail.uppercased() != "IN" {
                            Text("• \(match.statusDetail)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.red.opacity(0.8))
                        }
                    }
                } else if match.isFinal {
                    Text("Final")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(statusText(for: match))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Teams + score
            HStack {
                VStack(spacing: 4) {
                    Text(match.awayTeam)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(match.isFinal ? .secondary : .primary)
                    if (match.isLive || match.isFinal), let score = match.awayScore {
                        Text("\(score)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(match.isFinal && match.awayScore ?? 0 > match.homeScore ?? 0 ? .primary : match.isFinal ? .secondary : .primary)
                    }
                }
                .frame(maxWidth: .infinity)

                let isTennis = match.league == "ATP" || match.league == "WTA"
                Text(isTennis ? "vs" : "@")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text(match.homeTeam)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(match.isFinal ? .secondary : .primary)
                    if (match.isLive || match.isFinal), let score = match.homeScore {
                        Text("\(score)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(match.isFinal && match.homeScore ?? 0 > match.awayScore ?? 0 ? .primary : match.isFinal ? .secondary : .primary)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Pick buttons
            HStack(spacing: match.options.count > 2 ? 6 : 10) {
                ForEach(match.options) { option in
                    let isSelected = picksByMatch[match.id] == option.team
                    let isResolved = resolvedMatches.contains(match.id)
                    Button {
                        guard !isResolved, !match.isLocked else { return }
                        Haptics.medium()
                        let removing = picksByMatch[match.id] == option.team
                        if removing {
                            picksByMatch[match.id] = nil
                            pickDetails[match.id] = nil
                        } else {
                            picksByMatch[match.id] = option.team
                            pickDetails[match.id] = PickDetail(
                                matchName: matchDisplayName(for: match),
                                team: option.team,
                                gainRR: option.gainRR,
                                lossRR: option.lossRR,
                                startsAt: match.startsAt
                            )
                        }
                        persistPickDetails()
                        // Sync to Supabase with retry
                        if let uid = auth.userID, let token = auth.accessToken {
                            Task {
                                for attempt in 1...3 {
                                    do {
                                        if removing {
                                            try await SupabaseService.shared.deletePick(userID: uid, matchID: match.id, accessToken: token)
                                        } else {
                                            try await SupabaseService.shared.upsertPick(
                                                userID: uid, matchID: match.id,
                                                pickedTeam: option.team,
                                                matchName: matchDisplayName(for: match),
                                                gainRR: option.gainRR, lossRR: option.lossRR,
                                                accessToken: token
                                            )
                                        }
                                        break // success
                                    } catch {
                                        print("[Pick'em] Sync attempt \(attempt) failed: \(error.localizedDescription)")
                                        if attempt < 3 {
                                            try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text(option.team)
                                .font(match.options.count > 2 ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("+\(option.gainRR) / -\(option.lossRR)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isSelected ? brandPurple : Color(.systemGray6))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(match.isLocked || isResolved)
                }
            }

            // Status text
            if let selected = picksByMatch[match.id] {
                if resolvedMatches.contains(match.id) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                        Text("Settled")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if match.isLocked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                        Text("Locked: \(selected)")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("Your pick: \(selected)")
                        .font(.caption)
                        .foregroundStyle(brandPurple)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private var recentResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Results")
                .font(.headline)

            if predictionHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No results yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Make picks on live games to see results here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(predictionHistory.prefix(8)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.matchName)
                                .font(.subheadline.weight(.medium))
                            Text("Picked \(record.pickedTeam) • Winner: \(record.winnerTeam)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(record.rrDelta >= 0 ? "+" : "")\(record.rrDelta)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(record.rrDelta >= 0 ? .green : .red)
                    }
                    .padding(.vertical, 4)
                    if record.id != predictionHistory.prefix(8).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Helpers

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(for match: Match) -> String {
        if match.isLive {
            return "Live • \(match.statusDetail)"
        }
        if match.state == "pre" {
            return match.startsAt.formatted(date: .abbreviated, time: .shortened)
        }
        if match.state == "post" {
            return "Final"
        }
        if !match.statusDetail.isEmpty {
            return match.statusDetail
        }
        return match.startsAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func settleResolvedMatch(matchID: String, winner: String) {
        guard !resolvedMatches.contains(matchID) else { return }
        guard let selectedTeam = picksByMatch[matchID] else { return }

        // Resolve RR values from knownMatchesByID or persisted pickDetails
        let matchName: String
        let gainRR: Int
        let lossRR: Int

        if let match = knownMatchesByID[matchID],
           let selectedOption = match.options.first(where: { $0.team == selectedTeam }) {
            matchName = matchDisplayName(for: match)
            gainRR = selectedOption.gainRR
            lossRR = selectedOption.lossRR
        } else if let detail = pickDetails[matchID] {
            matchName = detail.matchName
            gainRR = detail.gainRR
            lossRR = detail.lossRR
        } else {
            // No match data available — skip settlement entirely.
            // Settling without proper pick data creates phantom results with raw IDs
            // (e.g. espn-tennis_wta-174456) and incorrect RR deltas.
            // The server-side reconciliation in loadLeaderboardAndFriends will handle
            // these picks correctly once the full data is available.
            print("[Pick'em] No match/pickDetails for \(matchID) — skipping local settlement")
            return
        }

        // Exact match first; fall back to name-word-set match for tennis (odds- IDs)
        // where ESPN might use a different name order than the Odds API
        // (e.g. "Zhizhen Zhang" on Odds API vs "Zhang Zhizhen" on ESPN).
        var didWin = selectedTeam == winner
        if !didWin && matchID.hasPrefix("odds-") {
            let selectedWords = Set(selectedTeam.lowercased().split(separator: " ").map(String.init))
            let winnerWords = Set(winner.lowercased().split(separator: " ").map(String.init))
            let common = selectedWords.intersection(winnerWords)
            if common.count >= min(selectedWords.count, winnerWords.count) && !common.isEmpty {
                didWin = true
            }
        }
        let delta = didWin ? gainRR : -lossRR

        rrScore += delta
        serverPickemRRDelta += delta
        if didWin {
            wins += 1
        } else {
            losses += 1
        }
        resolvedMatches.insert(matchID)

        // Also resolve any duplicate IDs for the same game (e.g. odds- vs espn-).
        // Without this, the duplicate stays in picksByMatch and shows in active picks
        // even though the game is settled.
        let settledDisplayName = matchName
        for (otherID, otherTeam) in picksByMatch where otherID != matchID {
            guard otherTeam == selectedTeam else { continue }
            let otherName = knownMatchesByID[otherID].map { matchDisplayName(for: $0) }
                ?? pickDetails[otherID]?.matchName
            if otherName == settledDisplayName {
                resolvedMatches.insert(otherID)
                picksByMatch[otherID] = nil
                pickDetails[otherID] = nil
            }
        }

        // Use the match start date (not settlement time) so the displayed date
        // reflects when the game was actually played.
        let matchDate = knownMatchesByID[matchID]?.startsAt
            ?? pickDetails[matchID]?.startsAt
            ?? Date()

        var updatedHistory = predictionHistory
        updatedHistory.insert(
            PredictionRecord(
                id: UUID(),
                matchName: matchName,
                pickedTeam: selectedTeam,
                winnerTeam: winner,
                rrDelta: delta,
                loggedAt: matchDate
            ),
            at: 0
        )
        historyData = encodedPredictionHistory(Array(updatedHistory.prefix(200)))

        // Clean up settled pick details
        pickDetails[matchID] = nil
        persistPickDetails()

        // Sync updated stats and settled pick to Supabase with retry
        if let uid = auth.userID, let token = auth.accessToken {
            let currentRR = displayedRR
            let currentWins = wins
            let currentLosses = losses
            let result = didWin ? "win" : "loss"
            Task {
                for attempt in 1...3 {
                    do {
                        async let statsSync: () = SupabaseService.shared.syncProfileStats(
                            userID: uid, rrScore: currentRR, wins: currentWins, losses: currentLosses, accessToken: token
                        )
                        async let pickSettle: Bool = SupabaseService.shared.settlePick(
                            userID: uid, matchID: matchID,
                            result: result,
                            rrDelta: delta, winnerTeam: winner, accessToken: token
                        )
                        _ = try await (statsSync, pickSettle)
                        break // success
                    } catch {
                        print("[Pick'em] Settlement sync attempt \(attempt) failed: \(error.localizedDescription)")
                        if attempt < 3 {
                            try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                        }
                    }
                }
            }
        }
    }

    private func reconcileCompletedPicks() async {
        let now = Date()
        let allUnresolved = Set(picksByMatch.keys).subtracting(resolvedMatches)
        // Filter to only settleable matches:
        // 1. Must have started (future matches can't have results)
        // 2. Must have pick details OR be in knownMatches (ghost entries without
        //    details can never be settled locally and just cause log spam)
        var ghostCount = 0
        var futureCount = 0
        let unresolved = allUnresolved.filter { matchID in
            // Ghost check: no known match AND no pick details → unsettleable
            if knownMatchesByID[matchID] == nil && pickDetails[matchID] == nil {
                ghostCount += 1
                return false
            }
            // Future match check
            if let match = knownMatchesByID[matchID], match.startsAt > now {
                futureCount += 1
                return false
            }
            return true
        }
        if !allUnresolved.isEmpty {
            print("[Pick'em] reconcile: \(allUnresolved.count) total unresolved, \(unresolved.count) settleable, \(futureCount) future, \(ghostCount) ghost")
        }
        guard !unresolved.isEmpty else { return }

        var winners: [String: String]
        do {
            winners = try await resultProvider.fetchCompletedWinners(matchIDs: unresolved)
        } catch {
            print("[Pick'em] fetchCompletedWinners failed: \(error.localizedDescription)")
            winners = [:]
        }
        if !unresolved.isEmpty {
            let unsettled = unresolved.filter { winners[$0] == nil }
            if !unsettled.isEmpty {
                print("[Pick'em] \(winners.count)/\(unresolved.count) resolved; still waiting: \(unsettled.map { $0.prefix(40) }.joined(separator: ", "))")
            }
        }

        for (matchID, winner) in winners {
            settleResolvedMatch(matchID: matchID, winner: winner)
        }

        // Cross-reference unresolved odds- tennis picks with ESPN scoreboard.
        // Uses pickDetails for match names since this is the local-only path.
        let unresolvedOdds = unresolved.filter { $0.hasPrefix("odds-") && winners[$0] == nil }
        if !unresolvedOdds.isEmpty {
            var matchNamesByID: [String: String] = [:]
            for matchID in unresolvedOdds {
                if let detail = pickDetails[matchID] {
                    let name = detail.matchName
                    if name.contains(" vs ") || name.contains(" @ ") {
                        matchNamesByID[matchID] = name
                    } else {
                        // matchName is a raw ID — use the picked team as fallback
                        matchNamesByID[matchID] = detail.team
                    }
                }
            }
            if !matchNamesByID.isEmpty {
                let espnWinners = await resolveOddsTennisViaESPN(matchNames: matchNamesByID)
                for (matchID, winner) in espnWinners {
                    settleResolvedMatch(matchID: matchID, winner: winner)
                }
            }
        }
    }

    /// Settle ALL unsettled picks across all users so profiles and leaderboard stay current.
    private func reconcileAllPicks() async {
        guard let token = auth.accessToken else {
            print("[Pick'em Global] No access token — skipping reconcileAllPicks")
            return
        }

        // 1. Fetch all unsettled picks from the database
        let allUnsettled: [UnsettledPickRecord]
        do {
            allUnsettled = try await SupabaseService.shared.fetchAllUnsettledPicks(accessToken: token)
        } catch {
            print("[Pick'em Global] fetchAllUnsettledPicks failed: \(error)")
            return
        }
        guard !allUnsettled.isEmpty else {
            print("[Pick'em Global] No unsettled picks found")
            return
        }
        print("[Pick'em Global] Found \(allUnsettled.count) unsettled pick(s)")

        // 2. Group by match_id to minimize ESPN API calls
        let picksByMatchID = Dictionary(grouping: allUnsettled, by: \.matchId)
        let matchIDs = Set(picksByMatchID.keys)

        // 3. Fetch completed winners from ESPN
        var winners: [String: String] = [:]
        let winnerStart = Date()
        do {
            winners = try await resultProvider.fetchCompletedWinners(matchIDs: matchIDs)
        } catch {
            print("[Pick'em Global] fetchCompletedWinners failed: \(error)")
            // Don't return — still need to run stale pick cleanup below
        }
        let oddsCount = matchIDs.filter { $0.hasPrefix("odds-") }.count
        let winnerElapsed = Date().timeIntervalSince(winnerStart)
        print("[Pick'em Global] fetchCompletedWinners resolved \(winners.count)/\(matchIDs.count) matches (\(oddsCount) odds- IDs) in \(String(format: "%.1f", winnerElapsed))s")

        // 4. Settle each pick — fire all DB writes in parallel, then apply local state
        struct SettlementJob: Sendable {
            let userID: String
            let matchID: String
            let result: String
            let rrDelta: Int
            let didWin: Bool
            let matchName: String
            let pickedTeam: String
            let winner: String
            let createdAt: Date?
        }

        // Build settlement jobs (pure computation, no I/O)
        var jobs: [SettlementJob] = []
        for (matchID, winner) in winners {
            guard let picks = picksByMatchID[matchID] else { continue }
            for pick in picks {
                var didWin = pick.pickedTeam == winner
                if !didWin && matchID.hasPrefix("odds-") {
                    let pickedWords = Set(pick.pickedTeam.lowercased().split(separator: " ").map(String.init))
                    let winnerWords = Set(winner.lowercased().split(separator: " ").map(String.init))
                    let common = pickedWords.intersection(winnerWords)
                    if common.count >= min(pickedWords.count, winnerWords.count) && !common.isEmpty {
                        didWin = true
                    }
                }
                let delta = didWin ? pick.gainRr : -pick.lossRr
                jobs.append(SettlementJob(
                    userID: pick.userId, matchID: matchID,
                    result: didWin ? "win" : "loss", rrDelta: delta, didWin: didWin,
                    matchName: pick.matchName, pickedTeam: pick.pickedTeam,
                    winner: winner, createdAt: pick.createdAt
                ))
            }
        }

        // Fire all settlePick DB writes in parallel (up to 10 concurrent)
        struct SettleResult: Sendable {
            let job: SettlementJob
            let wasSettled: Bool
        }
        let settledResults: [SettleResult] = await withTaskGroup(of: SettleResult.self) { group in
            for job in jobs {
                group.addTask { @Sendable in
                    let wasSettled: Bool
                    do {
                        wasSettled = try await SupabaseService.shared.settlePick(
                            userID: job.userID, matchID: job.matchID,
                            result: job.result, rrDelta: job.rrDelta,
                            winnerTeam: job.winner, accessToken: token
                        )
                    } catch {
                        print("[Pick'em Global] settlePick failed for \(job.userID.prefix(8))/\(job.matchID): \(error.localizedDescription)")
                        return SettleResult(job: job, wasSettled: false)
                    }
                    return SettleResult(job: job, wasSettled: wasSettled)
                }
            }
            var results: [SettleResult] = []
            for await r in group { results.append(r) }
            return results
        }

        // Apply local state and accumulate per-user deltas (must be sequential on MainActor)
        var userDeltas: [String: (rrDelta: Int, wins: Int, losses: Int)] = [:]
        for r in settledResults where r.wasSettled {
            let job = r.job
            var current = userDeltas[job.userID] ?? (0, 0, 0)
            current.rrDelta += job.rrDelta
            current.wins += job.didWin ? 1 : 0
            current.losses += job.didWin ? 0 : 1
            userDeltas[job.userID] = current

            if job.userID == auth.userID, !resolvedMatches.contains(job.matchID) {
                rrScore += job.rrDelta
                serverPickemRRDelta += job.rrDelta
                if job.didWin { wins += 1 } else { losses += 1 }
                resolvedMatches.insert(job.matchID)

                let matchDate = knownMatchesByID[job.matchID]?.startsAt
                    ?? pickDetails[job.matchID]?.startsAt
                    ?? job.createdAt
                    ?? Date()
                var updatedHistory = predictionHistory
                updatedHistory.insert(
                    PredictionRecord(
                        id: UUID(),
                        matchName: job.matchName,
                        pickedTeam: job.pickedTeam,
                        winnerTeam: job.winner,
                        rrDelta: job.rrDelta,
                        loggedAt: matchDate
                    ),
                    at: 0
                )
                historyData = encodedPredictionHistory(Array(updatedHistory.prefix(200)))

                pickDetails[job.matchID] = nil
                persistPickDetails()
            }
        }

        // 5. Update profile stats for each affected user — in parallel
        if !userDeltas.isEmpty {
            print("[Pick'em Global] Settled picks for \(userDeltas.count) user(s)")
            await withTaskGroup(of: Void.self) { group in
                for (userID, deltas) in userDeltas {
                    if userID == auth.userID {
                        group.addTask { @Sendable in
                            try? await SupabaseService.shared.syncProfileStats(
                                userID: userID, rrScore: self.displayedRR, wins: self.wins, losses: self.losses,
                                accessToken: token
                            )
                        }
                    } else {
                        group.addTask { @Sendable in
                            try? await SupabaseService.shared.adjustProfileStats(
                                userID: userID, rrDelta: deltas.rrDelta,
                                winsDelta: deltas.wins, lossesDelta: deltas.losses,
                                accessToken: token
                            )
                        }
                    }
                }
            }
        }

        // 5b. Cross-reference unresolved odds- tennis picks with ESPN scoreboard.
        // The Odds API only has 3 days of scores, but ESPN has 7 days. For tennis
        // picks that used an odds- ID, try to find the same match on ESPN by
        // matching player last names from the stored matchName.
        let unresolvedOddsTennis = allUnsettled.filter { pick in
            pick.matchId.hasPrefix("odds-") && winners[pick.matchId] == nil
        }
        print("[Pick'em Global] Unresolved odds- picks: \(unresolvedOddsTennis.count)")
        for pick in unresolvedOddsTennis {
            print("[Pick'em Global]   odds- pick: \(pick.matchId.prefix(30)) matchName=\"\(pick.matchName)\" picked=\"\(pick.pickedTeam)\"")
        }
        if !unresolvedOddsTennis.isEmpty {
            // Collect unique matchIDs and their player names from matchName.
            // Also include pickedTeam as a fallback name source in case matchName is a raw ID.
            var matchNamesByID: [String: String] = [:]
            for pick in unresolvedOddsTennis {
                // If matchName looks like a proper name (contains " vs " or " @ "), use it.
                // Otherwise, fall back to constructing a searchable name from pickedTeam.
                if pick.matchName.contains(" vs ") || pick.matchName.contains(" @ ") {
                    matchNamesByID[pick.matchId] = pick.matchName
                } else {
                    // matchName is a raw ID or garbage — use pickedTeam as single-player search
                    matchNamesByID[pick.matchId] = pick.pickedTeam
                    print("[Pick'em Global]   ⚠ matchName is not a name, using pickedTeam: \(pick.pickedTeam)")
                }
            }
            // Search ESPN tennis for completed matches with matching player names
            let espnTennisWinners = await resolveOddsTennisViaESPN(matchNames: matchNamesByID)
            print("[Pick'em Global] ESPN cross-ref resolved \(espnTennisWinners.count) of \(matchNamesByID.count) odds- tennis picks")
            for (matchID, winner) in espnTennisWinners {
                winners[matchID] = winner
            }
            // Settle the newly resolved picks in parallel (same pattern as step 4).
            var espnJobs: [SettlementJob] = []
            for (matchID, winner) in espnTennisWinners {
                guard let picks = picksByMatchID[matchID] else { continue }
                let winnerWords = Set(winner.lowercased().split(separator: " ").map(String.init))
                for pick in picks {
                    let pickedWords = Set(pick.pickedTeam.lowercased().split(separator: " ").map(String.init))
                    let common = pickedWords.intersection(winnerWords)
                    let didWin = !common.isEmpty && common.count >= min(pickedWords.count, winnerWords.count)
                    let delta = didWin ? pick.gainRr : -pick.lossRr
                    espnJobs.append(SettlementJob(
                        userID: pick.userId, matchID: matchID,
                        result: didWin ? "win" : "loss", rrDelta: delta, didWin: didWin,
                        matchName: pick.matchName, pickedTeam: pick.pickedTeam,
                        winner: winner, createdAt: pick.createdAt
                    ))
                }
            }
            let espnResults: [SettleResult] = await withTaskGroup(of: SettleResult.self) { group in
                for job in espnJobs {
                    group.addTask { @Sendable in
                        let wasSettled = (try? await SupabaseService.shared.settlePick(
                            userID: job.userID, matchID: job.matchID,
                            result: job.result, rrDelta: job.rrDelta,
                            winnerTeam: job.winner, accessToken: token
                        )) ?? false
                        return SettleResult(job: job, wasSettled: wasSettled)
                    }
                }
                var results: [SettleResult] = []
                for await r in group { results.append(r) }
                return results
            }
            for r in espnResults where r.wasSettled {
                let job = r.job
                var current = userDeltas[job.userID] ?? (0, 0, 0)
                current.rrDelta += job.rrDelta
                current.wins += job.didWin ? 1 : 0
                current.losses += job.didWin ? 0 : 1
                userDeltas[job.userID] = current
                if job.userID == auth.userID, !resolvedMatches.contains(job.matchID) {
                    rrScore += job.rrDelta
                    serverPickemRRDelta += job.rrDelta
                    if job.didWin { wins += 1 } else { losses += 1 }
                    resolvedMatches.insert(job.matchID)
                    pickDetails[job.matchID] = nil
                    persistPickDetails()
                }
            }
            // Update profile stats for users affected by the ESPN cross-reference
            if userDeltas.contains(where: { $0.key == auth.userID }) {
                try? await SupabaseService.shared.syncProfileStats(
                    userID: auth.userID!, rrScore: displayedRR, wins: wins, losses: losses,
                    accessToken: token
                )
            }
        }

        // 6. Expire stale picks that are too old to ever be settled (>7 days).
        // Fire all expiration writes in parallel.
        let staleThreshold: TimeInterval = 7 * 24 * 3600
        let now = Date()
        let stalePicks = allUnsettled.filter { pick in
            guard winners[pick.matchId] == nil else { return false }
            guard let createdAt = pick.createdAt else { return true }
            return now.timeIntervalSince(createdAt) > staleThreshold
        }
        if !stalePicks.isEmpty {
            print("[Pick'em Global] Expiring \(stalePicks.count) stale pick(s) older than 7 days")
            await withTaskGroup(of: Void.self) { group in
                for pick in stalePicks {
                    group.addTask { @Sendable in
                        _ = try? await SupabaseService.shared.settlePick(
                            userID: pick.userId, matchID: pick.matchId,
                            result: "expired", rrDelta: 0, accessToken: token
                        )
                    }
                }
            }
            // Update local state for current user's stale picks
            for pick in stalePicks where pick.userId == auth.userID {
                resolvedMatches.insert(pick.matchId)
                picksByMatch.removeValue(forKey: pick.matchId)
                pickDetails[pick.matchId] = nil
            }
            if stalePicks.contains(where: { $0.userId == auth.userID }) {
                persistPickDetails()
            }
        }
    }

    /// Cross-reference odds- tennis picks with ESPN scoreboard by matching player last names.
    /// Returns [matchID: winnerName] for any matches found on ESPN.
    private func resolveOddsTennisViaESPN(matchNames: [String: String]) async -> [String: String] {
        var resolved: [String: String] = [:]
        guard !matchNames.isEmpty else { return resolved }

        // Extract name word sets from each matchName for fuzzy matching.
        // Uses ALL words in each player name (not just last name) to handle
        // East Asian name ordering differences (e.g. "Zhizhen Zhang" on Odds API
        // vs "Zhang Zhizhen" on ESPN — both produce the set {"zhizhen", "zhang"}).
        struct PendingMatch {
            let matchID: String
            let playerNameSets: [Set<String>] // each player's name words, lowercased
        }
        var pending: [PendingMatch] = []
        for (matchID, matchName) in matchNames {
            let parts = matchName
                .replacingOccurrences(of: " vs ", with: "|")
                .replacingOccurrences(of: " @ ", with: "|")
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let nameSets: [Set<String>] = parts.compactMap { fullName -> Set<String>? in
                let words = Set(fullName.lowercased().split(separator: " ").map(String.init))
                return words.isEmpty ? nil : words
            }
            guard !nameSets.isEmpty, nameSets.count <= 2 else {
                print("[Pick'em] ESPN cross-ref: skipping \(matchID) — could not parse names from \"\(matchName)\"")
                continue
            }
            pending.append(PendingMatch(matchID: matchID, playerNameSets: nameSets))
        }
        guard !pending.isEmpty else {
            print("[Pick'em] ESPN cross-ref: no parseable pending matches")
            return resolved
        }
        print("[Pick'em] ESPN cross-ref: searching for \(pending.count) match(es)")

        // Search ESPN ATP and WTA scoreboards over the last 30 days.
        // Fetch all league/day combos in parallel for speed.
        struct ESPNCompletedMatch: Sendable {
            let compNameSets: [Set<String>]
            let winnerName: String
        }
        let cal = Calendar(identifier: .gregorian)
        let nowDate = Date()
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyyMMdd"

        let allCompleted: [ESPNCompletedMatch] = await withTaskGroup(of: [ESPNCompletedMatch].self) { group in
            for league in ["atp", "wta"] {
                for dayOffset in stride(from: 0, through: -30, by: -1) {
                    guard let date = cal.date(byAdding: .day, value: dayOffset, to: nowDate) else { continue }
                    let dateKey = df.string(from: date)
                    group.addTask { @Sendable in
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/tennis/\(league)/scoreboard?dates=\(dateKey)"),
                              let (data, _) = try? await URLSession.shared.data(from: url),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let events = json["events"] as? [[String: Any]] else { return [] }

                        var matches: [ESPNCompletedMatch] = []
                        for event in events {
                            var allCompetitions: [[String: Any]] = []
                            if let groupings = event["groupings"] as? [[String: Any]] {
                                for g in groupings {
                                    if let comps = g["competitions"] as? [[String: Any]] {
                                        allCompetitions.append(contentsOf: comps)
                                    }
                                }
                            }
                            if let comps = event["competitions"] as? [[String: Any]] {
                                allCompetitions.append(contentsOf: comps)
                            }
                            for competition in allCompetitions {
                                guard let status = competition["status"] as? [String: Any],
                                      let statusType = status["type"] as? [String: Any],
                                      statusType["state"] as? String == "post" else { continue }
                                guard let competitors = competition["competitors"] as? [[String: Any]],
                                      competitors.count == 2 else { continue }
                                let compNameSets: [Set<String>] = competitors.compactMap { comp in
                                    let athlete = comp["athlete"] as? [String: Any]
                                    let name = athlete?["displayName"] as? String
                                        ?? comp["displayName"] as? String ?? ""
                                    let words = Set(name.lowercased().split(separator: " ").map(String.init))
                                    return words.isEmpty ? nil : words
                                }
                                guard compNameSets.count == 2 else { continue }
                                if let winner = competitors.first(where: { ($0["winner"] as? Bool) == true }) {
                                    let athlete = winner["athlete"] as? [String: Any]
                                    let winnerName = athlete?["displayName"] as? String
                                        ?? winner["displayName"] as? String
                                    if let winnerName {
                                        matches.append(ESPNCompletedMatch(compNameSets: compNameSets, winnerName: winnerName))
                                    }
                                }
                            }
                        }
                        return matches
                    }
                }
            }
            var all: [ESPNCompletedMatch] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }

        // Match fetched results against pending picks
        for completed in allCompleted {
            for p in pending where resolved[p.matchID] == nil {
                let matchesNames = p.playerNameSets.allSatisfy { pendingSet in
                    completed.compNameSets.contains { espnSet in
                        let common = pendingSet.intersection(espnSet)
                        return !common.isEmpty && common.count >= min(pendingSet.count, espnSet.count)
                    }
                }
                if matchesNames {
                    resolved[p.matchID] = completed.winnerName
                    print("[Pick'em] ESPN cross-ref resolved odds- tennis match \(p.matchID.prefix(30)) → winner: \(completed.winnerName)")
                }
            }
        }
        let unresolvedCount = pending.filter { resolved[$0.matchID] == nil }.count
        if unresolvedCount > 0 {
            print("[Pick'em] ESPN cross-ref: \(unresolvedCount) match(es) still unresolved after searching 30 days")
            for p in pending where resolved[p.matchID] == nil {
                print("[Pick'em]   unresolved: \(p.matchID.prefix(30)) names=\(p.playerNameSets)")
            }
        }
        return resolved
    }

    /// Push the locally-corrected RR/wins/losses to the server profile.
    /// Used by v18 migration after setting the known-correct values in .onAppear.
    private func pushCorrectedStats(userID: String, accessToken: String) async {
        print("[RR Fix] Pushing corrected stats to server: RR=\(displayedRR), W=\(wins), L=\(losses)")
        hasPerformedInitialSync = true  // prevent server sync from overwriting corrected values
        do {
            try await SupabaseService.shared.syncProfileStats(
                userID: userID, rrScore: displayedRR, wins: wins, losses: losses, accessToken: accessToken
            )
            print("[RR Fix] Successfully pushed corrected stats to server")
        } catch {
            print("[RR Fix] Failed to push corrected stats: \(error)")
        }
    }

    private func persistPickDetails() {
        pickDetailsData = (try? JSONEncoder().encode(pickDetails)) ?? Data()
    }

    private func encodedPredictionHistory(_ value: [PredictionRecord]) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    /// Decode prediction history from Data, removing duplicates by matchName+pickedTeam.
    /// Keeps the first (most recent) occurrence when sorted by loggedAt descending.
    private static func deduplicatedHistory(from data: Data) -> [PredictionRecord] {
        guard let records = try? JSONDecoder().decode([PredictionRecord].self, from: data) else { return [] }
        var seen = Set<String>()
        return records.filter { record in
            let key = "\(record.matchName)|\(record.pickedTeam)"
            return seen.insert(key).inserted
        }
    }

    private func encodedDFSHistory(_ value: [DFSResult]) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    /// ADMIN ONLY. Permanently remove a past DFS contest (all the user's
    /// lineups in it) and claw back the RR it contributed. Used to scrub
    /// contests whose bot field was broken and handed out undeserved RR.
    func deletePastDFSContest(tournamentID: String) {
        // 1. Exclude it permanently. The read-time filter in `dfsHistory`
        //    keeps it gone even if the server re-imports or re-settles it —
        //    the root cause of "deleted results keep coming back".
        DFSViewModel.excludeTournament(tournamentID)

        // 2. Drop the rows from the persisted blob now so the UI updates
        //    immediately (changing the blob also triggers the observers).
        let remaining = dfsViewModel.dfsHistory.filter { $0.tournamentId != tournamentID }
        syncHistoryData(encodedDFSHistory(remaining))

        // 3. Keep it settled so a later slate load can't re-settle it.
        var settled = (try? JSONDecoder().decode(Set<String>.self, from: settledTournamentData)) ?? []
        settled.insert(tournamentID)
        syncSettledData((try? JSONEncoder().encode(settled)) ?? settledTournamentData)

        // 4. Reconcile the incremental RR mirror to the corrected derived total.
        syncRRScore(displayedRR)

        // 5. Server: delete the result rows and push corrected profile stats.
        if let token = auth.accessToken, let userID = auth.userID {
            let correctedRR = displayedRR
            let w = wins, l = losses
            Task {
                try? await SupabaseService.shared.deleteTournamentResults(tournamentID: tournamentID, accessToken: token)
                try? await SupabaseService.shared.syncProfileStats(userID: userID, rrScore: correctedRR, wins: w, losses: l, accessToken: token)
            }
        }
    }

    /// ADMIN: re-grade a settled contest (regenerate bots + re-score with the
    /// current fixed logic) instead of deleting it. Routes to the owning sport
    /// view model.
    func regradePastDFSContest(tournamentID tid: String) {
        let owner: DFSViewModel = {
            if tid.hasPrefix("nhl-") { return nhlDFSViewModel }
            if tid.hasPrefix("ncaam-") { return ncaamDFSViewModel }
            if tid.hasPrefix("wnba-") { return wnbaDFSViewModel }
            if tid.hasPrefix("mlb-") { return mlbDFSViewModel }
            if tid.hasPrefix("pga-") { return pgaDFSViewModel }
            if tid.hasPrefix("epl-") { return eplDFSViewModel }
            if tid.hasPrefix("ucl-") { return uclDFSViewModel }
            if tid.hasPrefix("wc-")  { return wcDFSViewModel }
            if tid.hasPrefix("ufc-") { return ufcDFSViewModel }
            if tid.hasPrefix("nfl-") { return nflDFSViewModel }
            if tid.hasPrefix("cfb-") { return cfbDFSViewModel }
            return dfsViewModel
        }()
        Task { await owner.adminRegradeContest(tournamentID: tid) }
    }

    private func loadMatchesIfNeeded() async {
        if matches.isEmpty {
            await loadMatches(force: false)
        }
    }

    private func loadMatches(force: Bool) async {
        if isLoadingMatches {
            return
        }
        if !force && !matches.isEmpty {
            return
        }

        isLoadingMatches = true
        matchesError = nil
        do {
            let fetchedMatches = try await matchProvider.fetchMatches()
            if !fetchedMatches.isEmpty {
                // Merge fetched matches into the existing set.
                // Fetched matches update or add entries; matches that already exist
                // locally but are absent from this fetch are KEPT (they may have been
                // missing due to a partial/degraded API response).
                var mergedByID: [String: Match] = [:]
                // Start with existing matches
                for m in matches { mergedByID[m.id] = m }
                // Overlay with fresh data
                for m in fetchedMatches { mergedByID[m.id] = m }
                // Also update knownMatchesByID (accumulates forever)
                for m in fetchedMatches { knownMatchesByID[m.id] = m }

                // Remove matches that are finished AND were not in the latest fetch
                // (a game that's "post" and no longer returned by ESPN can be pruned)
                let fetchedIDs = Set(fetchedMatches.map(\.id))
                for (id, m) in mergedByID {
                    if m.isFinal && !fetchedIDs.contains(id) {
                        mergedByID.removeValue(forKey: id)
                    }
                }

                // Deduplicate matches that share the same teams + date but have
                // different IDs (e.g. espn-tennis_wta-X vs odds-Y for the same game).
                // Prefer the espn- prefixed ID.
                // IMPORTANT: Include the calendar day in the key so that back-to-back
                // games between the same teams (e.g. NHL/MLB series) are NOT merged.
                let dedupDateFormatter: DateFormatter = {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.timeZone = TimeZone(secondsFromGMT: 0)
                    return f
                }()
                var seenGames: [String: String] = [:]   // dedup key → kept match ID
                var duplicateIDs: [String] = []
                let sorted = mergedByID.values.sorted { $0.id < $1.id } // espn- sorts before odds-
                for m in sorted {
                    let dateKey = dedupDateFormatter.string(from: m.startsAt)
                    let key = "\(m.awayTeam)|\(m.homeTeam)|\(m.league)|\(dateKey)"
                    if let keptID = seenGames[key] {
                        duplicateIDs.append(m.id)
                        // Migrate any pick stored under the removed ID to the kept ID.
                        // If pickDetails exists, migrate it too. If not, rebuild details
                        // from the kept match so the pick can be settled and displayed.
                        if let pickedTeam = picksByMatch[m.id], picksByMatch[keptID] == nil {
                            picksByMatch[keptID] = pickedTeam
                            if var detail = pickDetails[m.id] {
                                // Ensure startsAt is set from the kept match if missing
                                if detail.startsAt == nil, let keptMatch = mergedByID[keptID] {
                                    detail.startsAt = keptMatch.startsAt
                                }
                                pickDetails[keptID] = detail
                            } else if let keptMatch = mergedByID[keptID],
                                      let option = keptMatch.options.first(where: { $0.team == pickedTeam }) {
                                // Rebuild details from the kept match data
                                pickDetails[keptID] = PickDetail(
                                    matchName: matchDisplayName(for: keptMatch),
                                    team: pickedTeam,
                                    gainRR: option.gainRR,
                                    lossRR: option.lossRR,
                                    startsAt: keptMatch.startsAt
                                )
                            }
                            picksByMatch[m.id] = nil
                            pickDetails[m.id] = nil
                        }
                    } else {
                        seenGames[key] = m.id
                    }
                }
                for id in duplicateIDs { mergedByID.removeValue(forKey: id) }

                // Repair pass: fix picks that were incorrectly migrated to a future
                // game by the old date-less dedup logic. If a pick is under a match
                // that hasn't started yet, but a same-teams match that already started
                // (or is today) also exists, move the pick back to the earlier match.
                let now = Date()
                let allMatchesByTeams: [String: [Match]] = {
                    var grouped: [String: [Match]] = [:]
                    for m in mergedByID.values {
                        let teamKey = "\(m.awayTeam)|\(m.homeTeam)|\(m.league)"
                        grouped[teamKey, default: []].append(m)
                    }
                    return grouped
                }()
                for (matchID, _) in picksByMatch {
                    guard let currentMatch = mergedByID[matchID] ?? knownMatchesByID[matchID] else { continue }
                    // Only repair if the pick's match is in the future (hasn't started)
                    guard currentMatch.startsAt > now else { continue }
                    let teamKey = "\(currentMatch.awayTeam)|\(currentMatch.homeTeam)|\(currentMatch.league)"
                    guard let sameTeamMatches = allMatchesByTeams[teamKey], sameTeamMatches.count > 1 else { continue }
                    // Find the earliest match that already started or is today
                    let pastOrToday = sameTeamMatches
                        .filter { $0.startsAt <= now && $0.id != matchID }
                        .sorted { $0.startsAt > $1.startsAt }  // most recent past game first
                    if let correctMatch = pastOrToday.first, picksByMatch[correctMatch.id] == nil {
                        let pickedTeam = picksByMatch[matchID]!
                        picksByMatch[correctMatch.id] = pickedTeam
                        if let detail = pickDetails[matchID] {
                            pickDetails[correctMatch.id] = detail
                        } else if let option = correctMatch.options.first(where: { $0.team == pickedTeam }) {
                            pickDetails[correctMatch.id] = PickDetail(
                                matchName: matchDisplayName(for: correctMatch),
                                team: pickedTeam,
                                gainRR: option.gainRR,
                                lossRR: option.lossRR,
                                startsAt: correctMatch.startsAt
                            )
                        }
                        picksByMatch[matchID] = nil
                        pickDetails[matchID] = nil
                        print("[Pick'em] Repaired pick for \(pickedTeam): moved from future match \(matchID.prefix(40)) to past match \(correctMatch.id.prefix(40))")
                    }
                }

                // Note: previously had aggressive tennis repair that deleted picks on future
                // tennis matches. This was removed because it incorrectly deleted legitimate
                // pre-match picks. The general repair pass above already handles remapping
                // picks that were migrated to incorrect future matches.

                matches = mergedByID.values.sorted(by: { $0.startsAt < $1.startsAt })

                // Backfill pickDetails for existing picks that don't have details yet
                for match in fetchedMatches {
                    if let pickedTeam = picksByMatch[match.id],
                       pickDetails[match.id] == nil,
                       let option = match.options.first(where: { $0.team == pickedTeam }) {
                        pickDetails[match.id] = PickDetail(
                            matchName: matchDisplayName(for: match),
                            team: pickedTeam,
                            gainRR: option.gainRR,
                            lossRR: option.lossRR,
                            startsAt: match.startsAt
                        )
                    }
                }
                persistPickDetails()

                // Merge active picks from Supabase — ensures picks made on other devices appear
                // Build a reverse lookup: dedup key → displayed match ID so we can map server
                // picks whose matchId was deduplicated (e.g. odds- replaced by espn-).
                let displayedKeyToID: [String: String] = {
                    var map: [String: String] = [:]
                    for m in matches {
                        let dateKey = dedupDateFormatter.string(from: m.startsAt)
                        map["\(m.awayTeam)|\(m.homeTeam)|\(m.league)|\(dateKey)"] = m.id
                    }
                    return map
                }()
                // Reverse lookup: display name → displayed match ID for tennis remapping
                let displayedNameToID: [String: String] = {
                    var map: [String: String] = [:]
                    for m in matches where m.league == "ATP" || m.league == "WTA" {
                        map[matchDisplayName(for: m)] = m.id
                    }
                    return map
                }()

                if let uid = auth.userID, let token = auth.accessToken {
                    if let serverPicks = try? await SupabaseService.shared.fetchUserPicks(userID: uid, accessToken: token) {
                        var didChange = false
                        for pick in serverPicks {
                            // Resolve the effective match ID: if the server's matchId isn't in the
                            // displayed matches, check if a match with the same teams exists under
                            // a different ID (deduplication replaced odds- with espn-).
                            var effectiveID = pick.matchId
                            if mergedByID[effectiveID] == nil {
                                if let knownMatch = knownMatchesByID[pick.matchId] {
                                    let dateKey = dedupDateFormatter.string(from: knownMatch.startsAt)
                                    let key = "\(knownMatch.awayTeam)|\(knownMatch.homeTeam)|\(knownMatch.league)|\(dateKey)"
                                    if let displayedID = displayedKeyToID[key] {
                                        effectiveID = displayedID
                                    }
                                } else {
                                    // Fallback: match the picked team name against displayed matches
                                    // (handles case where the odds- match is no longer fetched at all).
                                    // For tennis: use display name lookup (exact match name → displayed ID)
                                    // to avoid cross-date remapping for recurring matchups.
                                    // For other sports: match by team name, restricted to already-started games.
                                    if let displayedID = displayedNameToID[pick.matchName] {
                                        effectiveID = displayedID
                                    } else if let found = matches.first(where: { m in
                                        m.startsAt <= Date()
                                        && m.options.contains(where: { $0.team == pick.pickedTeam })
                                        && (pick.matchName.contains(m.awayTeam) || pick.matchName.contains(m.homeTeam))
                                    }) {
                                        effectiveID = found.id
                                    }
                                }
                            }

                            // Server says this pick is still active — remove from resolvedMatches
                            // in case it was incorrectly marked as settled locally
                            if resolvedMatches.contains(effectiveID) {
                                resolvedMatches.remove(effectiveID)
                                didChange = true
                            }
                            if resolvedMatches.contains(pick.matchId) {
                                resolvedMatches.remove(pick.matchId)
                                didChange = true
                            }
                            // Server picks win for any match we don't already have a local pick for.
                            // Only add if effectiveID maps to a displayed match (prevents ghost entries
                            // when the server pick's ID couldn't be resolved to a displayed match).
                            if picksByMatch[effectiveID] == nil && mergedByID[effectiveID] != nil {
                                picksByMatch[effectiveID] = pick.pickedTeam
                                pickDetails[effectiveID] = PickDetail(
                                    matchName: pick.matchName,
                                    team: pick.pickedTeam,
                                    gainRR: pick.gainRr,
                                    lossRR: pick.lossRr,
                                    startsAt: mergedByID[effectiveID]?.startsAt
                                )
                                didChange = true
                            }
                        }
                        if didChange {
                            persistPickDetails()
                        }
                    }
                }
            } else if matches.isEmpty {
                matchesError = "No live/upcoming games right now. Pull to refresh shortly."
            }
        } catch {
            if matches.isEmpty {
                matchesError = "Unable to load games right now. Please try again."
            }
        }

        // Always attempt settlement, even if match fetching failed
        await reconcileCompletedPicks()

        // Global settlement: settle all users' unsettled picks (throttled to every 60s)
        if Date().timeIntervalSince(lastGlobalSettlement) >= 60 {
            await reconcileAllPicks()
            lastGlobalSettlement = Date()
        }

        isLoadingMatches = false
    }

    // MARK: - Friends & Leaderboard

    private func loadLeaderboardAndFriends(force: Bool = false) async {
        guard let token = auth.accessToken, let userID = auth.userID else { return }
        // Prevent concurrent runs and throttle to once per 60 seconds
        guard !isRunningLeaderboardLoad else { return }
        if !force && Date().timeIntervalSince(lastLeaderboardLoad) < 60 { return }
        isRunningLeaderboardLoad = true
        defer { isRunningLeaderboardLoad = false; lastLeaderboardLoad = Date() }
        isLoadingLeaderboard = true

        let isSameUser = (lastUserID == userID)
        if isSameUser {
            // Merge settled picks from server into local resolvedMatches so we don't re-settle
            // Fetch ALL settled picks (paginated) to get accurate counts.
            // Track whether the walk finished cleanly: a page failure mid-way
            // yields a PARTIAL list that passes the "not empty" guard below —
            // adopting it used to shrink RR/W-L on the home screen and then
            // syncProfileStats cemented the truncated numbers on the server.
            var allSettledPicks: [SettledPickRecord] = []
            var settledFetchComplete = true
            var offset = 0
            let pageSize = 200
            while true {
                guard let page = try? await SupabaseService.shared.fetchSettledPicks(userID: userID, limit: pageSize, offset: offset, accessToken: token) else {
                    settledFetchComplete = false
                    break
                }
                allSettledPicks.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
            }
            if !settledFetchComplete {
                print("[Pick'em] Sync: settled-picks pagination failed after \(allSettledPicks.count) rows — skipping RR/record adoption this pass")
            }

            // Update Pick'em RR delta from server settled picks (used by home
            // screen breakdown). NEVER on an empty or partial fetch: a
            // timeout/outage used to zero or shrink the pill ("Pick'em +0").
            if !allSettledPicks.isEmpty && settledFetchComplete {
                serverPickemRRDelta = allSettledPicks.reduce(0) { $0 + $1.rrDelta }
            }

            // Recompute rrScore from Pick'em server data + local DFS history.
            // Server Pick'em records are authoritative for picks.
            // Local DFS history is authoritative for DFS (server records can have
            // duplicates from re-settlement, making server-side sums unreliable).
            if !needsRRRecompute {
                hasPerformedInitialSync = true
                let settledWins = allSettledPicks.filter { $0.result == "win" }.count
                let settledLosses = allSettledPicks.filter { $0.result == "loss" }.count
                let pickemDelta = allSettledPicks.reduce(0) { $0 + $1.rrDelta }
                let localDFSDelta = dfsViewModel.dfsHistory.reduce(0) { $0 + $1.rrDelta }
                let fullRR = 1000 + pickemDelta + localDFSDelta

                // Safety guard: if the server fetch came back EMPTY or
                // PARTIAL but we have a non-zero local record, treat it as
                // a transient failure and DON'T overwrite. Without this, a
                // single bad fetch (RLS hiccup, paging error, etc.) used to
                // wipe or shrink the user's record and then syncProfileStats
                // cemented it on the server, requiring manual recovery.
                let serverReturnedNothing = allSettledPicks.isEmpty
                let haveLocalRecord = wins > 0 || losses > 0
                if !settledFetchComplete || (serverReturnedNothing && haveLocalRecord) {
                    print("[Pick'em] Sync: settled-picks fetch \(settledFetchComplete ? "empty" : "incomplete") (local W=\(wins)/L=\(losses)) — keeping local record (likely transient fetch issue)")
                } else {
                    if rrScore != fullRR || wins != settledWins || losses != settledLosses {
                        print("[Pick'em] Sync: adopting RR=\(fullRR) (pickem=\(pickemDelta), dfs=\(localDFSDelta)) was \(rrScore). W=\(settledWins) (was \(wins)), L=\(settledLosses) (was \(losses))")
                    }
                    rrScore = fullRR
                    wins = settledWins
                    losses = settledLosses
                    try? await SupabaseService.shared.syncProfileStats(
                        userID: userID, rrScore: fullRR, wins: settledWins, losses: settledLosses, accessToken: token
                    )
                }
            }

            // Merge server settled picks into resolvedMatches and history.
            // Only on a COMPLETE fetch: rewriting historyData from a partial
            // list can drop server-only records that didn't make the page.
            if !allSettledPicks.isEmpty && settledFetchComplete {
                // Build a set of all settled match IDs so we can distinguish remapped IDs
                // from completely different games that happen to share a team name.
                let settledMatchIDs = Set(allSettledPicks.map(\.matchId))
                var restoredHistory: [PredictionRecord] = []
                for pick in allSettledPicks {
                    resolvedMatches.insert(pick.matchId)
                    // Also mark the LOCAL key as resolved if the pick exists under a
                    // remapped ID (e.g. server has odds-X, local has espn-Y after dedup).
                    // Without this, reconcileCompletedPicks re-settles the espn-Y pick.
                    // IMPORTANT: Only match picks for the SAME game — not different games
                    // where the user picked the same team. Check that the local key is NOT
                    // already in settledMatchIDs (it would be its own settled entry) and
                    // is NOT an active pick for a future game.
                    if picksByMatch[pick.matchId] == nil,
                       let localEntry = picksByMatch.first(where: { $0.value == pick.pickedTeam && $0.key != pick.matchId }),
                       !settledMatchIDs.contains(localEntry.key) {
                        // Only remap if the local key is truly a duplicate of the same game
                        // (e.g. odds- vs espn- for the exact same real-world match).
                        // Verify by comparing display names — two IDs for the same game will
                        // produce the same "Team A vs Team B" / "Player X vs Player Y" string.
                        let localKey = localEntry.key
                        let localDisplayName = knownMatchesByID[localKey].map { matchDisplayName(for: $0) }
                            ?? pickDetails[localKey]?.matchName
                        let settledDisplayName = pick.matchName
                        let isSameGame = localDisplayName != nil && localDisplayName == settledDisplayName
                        // Check if the local pick is for a future match — never mark future games as settled
                        let isFutureMatch = knownMatchesByID[localKey].map { $0.startsAt > Date() } ?? false
                        if isSameGame && !isFutureMatch {
                            resolvedMatches.insert(localKey)
                        }
                    }
                    restoredHistory.append(PredictionRecord(
                        id: UUID(),
                        matchName: pick.matchName,
                        pickedTeam: pick.pickedTeam,
                        winnerTeam: restoredWinnerLabel(for: pick),
                        rrDelta: pick.rrDelta,
                        loggedAt: pick.createdAt ?? pick.settledAt ?? Date()
                    ))
                }
                // Preserve locally-settled picks that haven't synced to the server.
                // These are in predictionHistory but not in allSettledPicks.
                let serverSettledNames2 = Set(allSettledPicks.map(\.matchName))
                let unsyncedLocalHistory = predictionHistory.filter { record in
                    !serverSettledNames2.contains(record.matchName)
                }
                let mergedHistory = restoredHistory + unsyncedLocalHistory
                historyData = (try? JSONEncoder().encode(Array(mergedHistory.prefix(500)))) ?? Data()
            }

            // Clean up stale duplicate IDs: if a pick's display name matches a
            // settled pick's match name AND falls on the same date, the pick is a
            // duplicate under a different ID (e.g. odds- vs espn- for the same game).
            // Mark it as resolved and remove it from picksByMatch.
            if !allSettledPicks.isEmpty && settledFetchComplete {
                // Build settled names WITH dates to avoid false matches across different days
                // (e.g. same tennis players meeting in consecutive tournament rounds).
                let settledNamesWithDates: Set<String> = {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd"
                    fmt.timeZone = TimeZone(secondsFromGMT: 0)
                    var set = Set<String>()
                    for pick in allSettledPicks {
                        // Use settledAt as a proxy for match date (picks are settled on game day)
                        let dateKey = pick.settledAt.map { fmt.string(from: $0) } ?? ""
                        set.insert("\(pick.matchName)||\(dateKey)")
                    }
                    return set
                }()
                // Also keep a name-only set as fallback for non-dated comparisons
                let settledNamesOnly = Set(allSettledPicks.map(\.matchName))
                let dateFmt = DateFormatter()
                dateFmt.dateFormat = "yyyy-MM-dd"
                dateFmt.timeZone = TimeZone(secondsFromGMT: 0)
                var staleIDs: [String] = []
                for (matchID, team) in picksByMatch where !resolvedMatches.contains(matchID) {
                    let displayName = knownMatchesByID[matchID].map { matchDisplayName(for: $0) }
                        ?? pickDetails[matchID]?.matchName
                    guard let name = displayName else { continue }
                    // First check: name must match a settled pick
                    guard settledNamesOnly.contains(name) else { continue }
                    // Make sure this isn't a future match
                    let isFuture = knownMatchesByID[matchID].map { $0.startsAt > Date() } ?? false
                    if isFuture { continue }
                    // Second check: verify date matches too (prevents deleting today's pick
                    // when yesterday's same-name match is settled).
                    // If we know the match date, require it to match a settled pick's date.
                    if let matchDate = knownMatchesByID[matchID]?.startsAt {
                        let dateKey = dateFmt.string(from: matchDate)
                        let nameWithDate = "\(name)||\(dateKey)"
                        if settledNamesWithDates.contains(nameWithDate) {
                            staleIDs.append(matchID)
                            print("[Pick'em] Cleaning up stale duplicate: \(matchID.prefix(40)) (\(team)) — '\(name)' already settled on \(dateKey)")
                        }
                    } else {
                        // No match data — can't verify date. Only clean up if the match ID
                        // itself looks like a remapped version (odds-/espn- prefix mismatch).
                        let hasRemappedPeer = allSettledPicks.contains { sp in
                            sp.matchName == name &&
                            ((matchID.hasPrefix("odds-") && !sp.matchId.hasPrefix("odds-")) ||
                             (!matchID.hasPrefix("odds-") && sp.matchId.hasPrefix("odds-")))
                        }
                        if hasRemappedPeer {
                            staleIDs.append(matchID)
                            print("[Pick'em] Cleaning up stale duplicate (remapped): \(matchID.prefix(40)) (\(team)) — '\(name)' already settled")
                        }
                    }
                }
                for id in staleIDs {
                    resolvedMatches.insert(id)
                    picksByMatch.removeValue(forKey: id)
                    pickDetails[id] = nil
                }
                if !staleIDs.isEmpty { persistPickDetails() }
            }

            // Merge active picks from server — catches picks made on other devices
            // AND removes local picks that the server has already settled.
            if let serverActivePicks = try? await SupabaseService.shared.fetchActivePicks(userID: userID, accessToken: token) {
                var didChange = false
                var serverActiveIDs = Set(serverActivePicks.map(\.matchId))

                // Also track server active picks by picked team so we can recognize
                // local picks whose IDs were remapped by deduplication (e.g. odds- → espn-).
                let serverActiveTeams = Set(serverActivePicks.map(\.pickedTeam))

                for pick in serverActivePicks {
                    // Server says this pick is still active.
                    // If we already settled it locally (in resolvedMatches), that means
                    // the server sync was interrupted (app killed before Task completed).
                    // Do NOT remove from resolvedMatches — reconcileAllPicks will handle
                    // the server-side settlement without double-counting the local RR.
                    if resolvedMatches.contains(pick.matchId) {
                        print("[Pick'em] Server-active pick \(pick.matchId.prefix(30)) already settled locally — keeping in resolvedMatches, server will be synced by reconcileAllPicks")
                        // Remove from serverActiveIDs so downstream code doesn't treat it as active
                        serverActiveIDs.remove(pick.matchId)
                        continue
                    }
                    // If the local pick exists under a DIFFERENT (remapped) ID,
                    // recognize that ID as server-active too.
                    if let localID = picksByMatch.first(where: { $0.value == pick.pickedTeam && $0.key != pick.matchId })?.key,
                       !serverActiveIDs.contains(localID) {
                        serverActiveIDs.insert(localID)
                        if resolvedMatches.contains(localID) {
                            // Same case — locally settled under remapped ID, server sync failed
                            print("[Pick'em] Server-active pick \(pick.matchId.prefix(30)) locally settled as \(localID.prefix(30)) — keeping in resolvedMatches")
                            serverActiveIDs.remove(pick.matchId)
                            continue
                        }
                    }
                    if picksByMatch[pick.matchId] == nil {
                        // Only add under the server ID if no local pick for the same team
                        // already exists (it may have been remapped to a different displayed ID)
                        let alreadyHasPick = picksByMatch.values.contains(pick.pickedTeam)
                        if !alreadyHasPick {
                            picksByMatch[pick.matchId] = pick.pickedTeam
                            pickDetails[pick.matchId] = PickDetail(
                                matchName: pick.matchName,
                                team: pick.pickedTeam,
                                gainRR: pick.gainRr,
                                lossRR: pick.lossRr,
                                startsAt: knownMatchesByID[pick.matchId]?.startsAt
                            )
                            didChange = true
                        }
                    }
                }
                // Remove local picks that the server has settled (no longer active).
                // Collect IDs first to avoid mutating during iteration.
                // A local pick is safe if: it's in resolvedMatches, its ID is in
                // serverActiveIDs (including remapped IDs), its picked team
                // matches a server active pick (handles any remaining ID mismatches),
                // OR the game hasn't started yet (can't be settled if not played),
                // OR the pick has local pickDetails but the server doesn't know about it
                // (server sync may have failed — preserve locally-made picks).
                let settledMatchIDs2 = Set(allSettledPicks.map(\.matchId))
                let localUnresolved = picksByMatch.filter { entry in
                    guard !resolvedMatches.contains(entry.key) else { return false }
                    guard !serverActiveIDs.contains(entry.key) else { return false }
                    guard !serverActiveTeams.contains(entry.value) else { return false }
                    // Never mark a future match as settled — the game hasn't happened yet
                    if let match = knownMatchesByID[entry.key], match.startsAt > Date() {
                        return false
                    }
                    // If the pick has local details but the server doesn't know about it
                    // at ALL (not in settled, not in active), then the server sync likely
                    // failed when the pick was submitted. Preserve it so it stays visible
                    // in active picks and reconcileCompletedPicks can settle it properly.
                    if pickDetails[entry.key] != nil && !settledMatchIDs2.contains(entry.key) {
                        print("[Pick'em] Preserving local-only pick \(entry.key.prefix(40)) (\(entry.value)) — server doesn't know about it")
                        return false
                    }
                    return true
                }
                for (matchID, _) in localUnresolved {
                    resolvedMatches.insert(matchID)
                    picksByMatch.removeValue(forKey: matchID)
                    pickDetails[matchID] = nil
                    didChange = true
                }
                if didChange {
                    persistPickDetails()
                }
            }
        } else {
            // Different user (just signed in) — clear device-local data from previous account
            // then adopt the new user's server profile data.
            lastUserID = userID
            dfsHistoryData = Data()
            settledTournamentData = Data()
            serverPickemRRDelta = 0
            picksByMatch = [:]
            resolvedMatches = []
            pickDetails = [:]
            picksByMatchData = Data()
            resolvedMatchesData = Data()
            pickDetailsData = Data()
            // Push cleared DFS data to all view models so they don't use stale history
            syncHistoryData(Data())
            syncSettledData(Data())

            if let serverProfile = try? await SupabaseService.shared.fetchProfiles(userIDs: [userID], accessToken: token).first,
               let serverRR = serverProfile.rrScore, let serverW = serverProfile.wins, let serverL = serverProfile.losses {
                rrScore = serverRR
                wins = serverW
                losses = serverL
                if !serverProfile.username.isEmpty, serverProfile.username != "Player" {
                    profileName = serverProfile.username
                    draftName = serverProfile.username
                }
                if let avatar = serverProfile.avatarUrl, !avatar.isEmpty {
                    profileAvatarURL = avatar
                }
            }

            // Restore prediction history and resolved matches from settled picks.
            // Paginate so we get every settled pick — the breakdown pill on
            // the home screen reads `serverPickemRRDelta`, which has to sum
            // ALL picks. The previous single-page (limit: 200) fetch also
            // only set `historyData` and `resolvedMatches`, leaving
            // `serverPickemRRDelta` at 0 — that's why fresh-install +
            // first-login showed "Pick'em +0" until you relaunched (the
            // relaunch took the same-user branch which paginates AND sets
            // the delta).
            var firstLoginSettledPicks: [SettledPickRecord] = []
            var firstLoginOffset = 0
            let firstLoginPageSize = 200
            while true {
                guard let page = try? await SupabaseService.shared.fetchSettledPicks(
                    userID: userID, limit: firstLoginPageSize, offset: firstLoginOffset, accessToken: token
                ) else { break }
                firstLoginSettledPicks.append(contentsOf: page)
                if page.count < firstLoginPageSize { break }
                firstLoginOffset += page.count
            }
            if !firstLoginSettledPicks.isEmpty {
                let restoredHistory = firstLoginSettledPicks.map { pick in
                    PredictionRecord(
                        id: UUID(),
                        matchName: pick.matchName,
                        pickedTeam: pick.pickedTeam,
                        winnerTeam: restoredWinnerLabel(for: pick),
                        rrDelta: pick.rrDelta,
                        loggedAt: pick.createdAt ?? pick.settledAt ?? Date()
                    )
                }
                historyData = (try? JSONEncoder().encode(restoredHistory)) ?? Data()
                for pick in firstLoginSettledPicks {
                    resolvedMatches.insert(pick.matchId)
                }
                serverPickemRRDelta = firstLoginSettledPicks.reduce(0) { $0 + $1.rrDelta }
            }

            // Restore active picks from server
            if let serverActivePicks = try? await SupabaseService.shared.fetchActivePicks(userID: userID, accessToken: token) {
                for pick in serverActivePicks {
                    // Server says active — must NOT be in resolvedMatches
                    resolvedMatches.remove(pick.matchId)
                    picksByMatch[pick.matchId] = pick.pickedTeam
                    pickDetails[pick.matchId] = PickDetail(
                        matchName: pick.matchName,
                        team: pick.pickedTeam,
                        gainRR: pick.gainRr,
                        lossRR: pick.lossRr,
                        startsAt: knownMatchesByID[pick.matchId]?.startsAt
                    )
                }
                if !serverActivePicks.isEmpty {
                    persistPickDetails()
                }
            }
        }

        async let topProfiles = SupabaseService.shared.fetchTopProfiles(limit: 100, accessToken: token)
        async let userFriendships = SupabaseService.shared.fetchFriendships(userID: userID, accessToken: token)

        do {
            let (profiles, ships) = try await (topProfiles, userFriendships)
            leaderboardProfiles = profiles
            friendships = ships

            // Always sync profileName from server to stay current with the logged-in user
            if let myProfile = profiles.first(where: { $0.id == userID }),
               !myProfile.username.isEmpty, myProfile.username != "Player" {
                profileName = myProfile.username
                draftName = myProfile.username
            }

            // Fetch all related user profiles (friends + pending requesters)
            let allRelatedIDs = Set(ships.map { $0.requesterID == userID ? $0.addresseeID : $0.requesterID })

            if !allRelatedIDs.isEmpty {
                let dfsProfiles = try await SupabaseService.shared.fetchProfiles(userIDs: Array(allRelatedIDs), accessToken: token)
                friendProfiles = Dictionary(uniqueKeysWithValues: dfsProfiles.compactMap { p -> (String, LeaderboardProfile)? in
                    guard let rr = p.rrScore, let w = p.wins, let l = p.losses else { return nil }
                    return (p.id, LeaderboardProfile(id: p.id, username: p.username, rrScore: rr, wins: w, losses: l, avatarUrl: p.avatarUrl))
                })
            }
        } catch {
            print("[Social] Failed to load leaderboard/friends: \(error.localizedDescription)")
        }

        isLoadingLeaderboard = false
    }

    private var acceptedFriends: [LeaderboardProfile] {
        guard let userID = auth.userID else { return [] }
        return friendships
            .filter { $0.status == "accepted" }
            .compactMap { ship in
                let friendID = ship.requesterID == userID ? ship.addresseeID : ship.requesterID
                return friendProfiles[friendID]
            }
            .sorted { $0.rrScore > $1.rrScore }
    }

    private var pendingRequests: [FriendshipRecord] {
        guard let userID = auth.userID else { return [] }
        return friendships.filter { $0.status == "pending" && $0.addresseeID == userID }
    }

    private func friendshipID(with otherUserID: String) -> String? {
        friendships.first(where: { ($0.requesterID == otherUserID || $0.addresseeID == otherUserID) })?.id
    }

    private func searchFriends() async {
        let query = friendSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let token = auth.accessToken else { return }
        isSearchingFriends = true
        do {
            let results = try await SupabaseService.shared.findUserByUsername(username: query, accessToken: token)
            friendSearchResults = results.filter { $0.id != auth.userID }
        } catch {
            friendSearchResults = []
        }
        isSearchingFriends = false
    }

    // MARK: - Clear Local User Data on Sign Out

    private func clearLocalUserData() {
        profileName = ""
        draftName = ""
        rrScore = 1000
        wins = 0
        losses = 0
        historyData = Data()
        dfsHistoryData = Data()
        settledTournamentData = Data()
        // Note: dfsSettlementVersion is NOT reset — it's a one-time schema migration flag, not user data
        picksByMatchData = Data()
        resolvedMatchesData = Data()
        pickDetailsData = Data()
        lastUserID = ""
        leaderboardProfiles = []
        friendships = []
        friendProfiles = [:]
        picksByMatch = [:]
        resolvedMatches = []
        pickDetails = [:]
    }
}

private struct PredictionRecord: Codable, Identifiable {
    let id: UUID
    let matchName: String
    let pickedTeam: String
    let winnerTeam: String
    let rrDelta: Int
    let loggedAt: Date
}

/// Winner label for a settled pick restored from the server. Prefers the
/// stored `winner_team` (captured at settle time — covers losses). For legacy
/// rows settled before the column existed, derive where unambiguous:
/// - a WIN's winner is the pick itself
/// - a tennis "A vs B" LOSS: no draws, the other player won
/// - a team-sport "A @ B" LOSS in a draw-free sport (MLB/WNBA/NBA/NFL —
///   identified via the ESPN match id): the other team won
/// - soccer LOSSES stay "—" (the opponent won OR it was a draw), as do
///   Draw picks.
private func restoredWinnerLabel(for pick: SettledPickRecord) -> String {
    if let stored = pick.winnerTeam, !stored.isEmpty { return stored }
    if pick.result == "win" { return pick.pickedTeam }
    guard pick.result == "loss" else { return "—" }
    let players = pick.matchName.components(separatedBy: " vs ")
    if players.count == 2 {
        if players[0] == pick.pickedTeam { return players[1] }
        if players[1] == pick.pickedTeam { return players[0] }
    }
    let isSoccer = pick.matchId.lowercased().contains("soccer")
    if !isSoccer {
        let teams = pick.matchName.components(separatedBy: " @ ")
        if teams.count == 2 {
            if teams[0] == pick.pickedTeam { return teams[1] }
            if teams[1] == pick.pickedTeam { return teams[0] }
        }
    }
    return "—"
}

private struct PickDetail: Codable {
    let matchName: String
    let team: String
    let gainRR: Int
    let lossRR: Int
    var startsAt: Date?
}

private func matchDisplayName(for match: Match) -> String {
    let separator = (match.league == "ATP" || match.league == "WTA") ? "vs" : "@"
    return "\(match.awayTeam) \(separator) \(match.homeTeam)"
}

#Preview {
    ContentView()
        .environmentObject(AuthViewModel())
}
