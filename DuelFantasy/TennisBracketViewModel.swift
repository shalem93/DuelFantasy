import Foundation

@MainActor @Observable
final class TennisBracketViewModel {
    // MARK: - Tournament State
    var tournament: TennisBracketTournament?
    var drawPlayers: [TennisBracketPlayer] = []       // 128 players from draw_data
    var userPicks: [String: String] = [:]              // slot → player name (127 picks)
    var results: [String: String] = [:]                // actual results from ESPN
    var leaderboardEntries: [TennisBracketLeaderboardEntry] = []
    var fieldEntries: [TennisBracketEntry] = []

    var isLoading: Bool = false
    var hasAttemptedLoad: Bool = false
    var error: String?
    var hasSubmitted: Bool = false
    /// Whether the user has submitted an ATP bracket for the current slam season.
    var hasSubmittedATP: Bool = false
    /// Whether the user has submitted a WTA bracket for the current slam season.
    var hasSubmittedWTA: Bool = false
    /// Per-draw cached rank / status used to populate the FantasyHub active-contest
    /// cards for both ATP and WTA simultaneously, regardless of which draw the
    /// viewModel currently has loaded as the "active" tournament.
    var atpUserRank: Int?
    var wtaUserRank: Int?
    var atpIsLive: Bool = false
    var wtaIsLive: Bool = false
    var isSubmitting: Bool = false
    var submitError: String?
    var drawAvailable: Bool = false

    // MARK: - Selection
    /// Default to whichever slam is in-progress or next-upcoming so users
    /// land on the relevant tournament instead of always-frenchOpen, which
    /// would dump them on a completed bracket after the final.
    var selectedGrandSlam: GrandSlam = GrandSlam.currentOrUpcoming()
    var selectedDrawType: DrawType = .atp

    /// Monotonic load token. Incremented on each loadTournament call so any
    /// in-flight load whose token no longer matches can detect it's been
    /// superseded and bail out before writing stale results. Without this,
    /// tapping WTA mid-ATP-load was a no-op (blocked by isLoading) and the
    /// ATP load eventually completed and overwrote the WTA pill's data.
    private var currentLoadToken: Int = 0

    /// Tournament ID of the most recent SUCCESSFUL load. Used by
    /// loadTournament to decide whether to wipe per-tournament state.
    /// Without this, every re-entry into loadTournament reset
    /// userPicks/results/fieldEntries to empty even when reloading the
    /// SAME tournament — and if the subsequent fetch transient-failed,
    /// the user's bracket vanished until they re-toggled the draw type.
    private var lastLoadedTournamentID: String?

    /// Tournament IDs we've already tried to late-bind restore picks for.
    /// Without this, restoreUserPicksIfMissing loops forever for users
    /// who legitimately don't have an entry (WTA case): the function
    /// returns immediately, but isLoading toggling causes the lobby body
    /// to unmount the live view, which cancels its .task; when isLoading
    /// flips back the live view remounts and re-fires the task → infinite
    /// "no server entry" log spam and -999 cancellations on every other
    /// in-flight request (loadMyGroups, etc.).
    private var restoreAttemptedTournamentIDs: Set<String> = []

    // MARK: - Persisted History (synced from ContentView)
    var dfsHistoryData: Data = Data()
    var settledTournamentData: Data = Data()

    // MARK: - Auth (synced from ContentView)
    var userID: String?
    var accessToken: String?
    var profileName: String = ""
    var rrScore: Int = 1000

    // MARK: - Groups State
    var myGroups: [TennisBracketGroup] = []
    var currentGroup: TennisBracketGroup?
    var currentGroupMembers: [TennisBracketGroupMember] = []
    /// Standings for the currently-open group, computed by fetching the group's
    /// tournament entries + results directly — independent of which tournament
    /// is currently selected in the main view model.
    var currentGroupStandings: [TennisBracketLeaderboardEntry] = []
    /// Results dictionary for the currently-open group's tournament, used to
    /// color pick status badges in the entry-detail sheet regardless of which
    /// tournament the main view model has loaded.
    var currentGroupResults: [String: String] = [:]
    var groupError: String?
    var isCreatingGroup: Bool = false
    var isJoiningGroup: Bool = false

    // MARK: - Providers
    private let espnProvider = ESPNTennisResultsProvider()
    private var fieldGenerated = false
    private var lastRefreshDate: Date?

    // MARK: - Local Bot Cache
    //
    // 999 generated bot brackets blow past iOS's 4MB UserDefaults hard cap
    // and silently corrupt the entire CFPreferences domain — which then
    // takes out every other @AppStorage write in the app (DFS history,
    // pickem state, settled flags). Cache to the Caches directory instead;
    // iOS can evict it under disk pressure, but it's freely regenerable.
    private static let botCacheKey = "tennis_bracket_bot_cache"

    private static func botCacheFileURL(tournamentID: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("\(botCacheKey)_\(tournamentID).json")
    }

    private func saveBotCacheLocally(_ botPicksData: [[String: Any]], tournamentID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: botPicksData),
              let url = Self.botCacheFileURL(tournamentID: tournamentID) else { return }
        // Clean up any legacy UserDefaults copy that may already be over the
        // 4MB limit and poisoning the domain.
        UserDefaults.standard.removeObject(forKey: "\(Self.botCacheKey)_\(tournamentID)")
        try? data.write(to: url, options: .atomic)
    }

    private func loadBotCacheLocally(tournamentID: String) -> [[String: Any]]? {
        if let url = Self.botCacheFileURL(tournamentID: tournamentID),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return parsed
        }
        // Legacy fallback: drain any old UserDefaults blob into the file
        // cache and clear it from UserDefaults so the next launch is clean.
        if let data = UserDefaults.standard.data(forKey: "\(Self.botCacheKey)_\(tournamentID)"),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            if let url = Self.botCacheFileURL(tournamentID: tournamentID) {
                try? data.write(to: url, options: .atomic)
            }
            UserDefaults.standard.removeObject(forKey: "\(Self.botCacheKey)_\(tournamentID)")
            return parsed
        }
        return nil
    }

    // MARK: - Local Pick Progress
    private static let pickProgressKey = "tennis_bracket_pick_progress"

    private func savePickProgress() {
        guard let tournament else { return }
        guard !userPicks.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(userPicks) else { return }
        UserDefaults.standard.set(data, forKey: "\(Self.pickProgressKey)_\(tournament.id)")
    }

    private func loadPickProgress() {
        guard let tournament else { return }
        // Only load saved progress if we haven't already loaded picks from server
        guard userPicks.isEmpty else { return }
        guard let data = UserDefaults.standard.data(forKey: "\(Self.pickProgressKey)_\(tournament.id)"),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        userPicks = saved
        print("[TennisBracket] Restored \(saved.count) picks from local progress")
    }

    private func clearPickProgress() {
        guard let tournament else { return }
        UserDefaults.standard.removeObject(forKey: "\(Self.pickProgressKey)_\(tournament.id)")
    }

    // MARK: - Computed Properties

    var isLocked: Bool {
        guard let tournament else { return false }
        return tournament.status == "locked" || tournament.status == "live" || tournament.status == "settled"
    }

    var isLive: Bool {
        guard let tournament else { return false }
        return tournament.status == "live"
    }

    var isSettled: Bool {
        tournament?.isSettled ?? false
    }

    var allPicksMade: Bool {
        userPicks.count == TennisBracketEngine.totalPicks
    }

    var lockTimeRemaining: String? {
        guard let lockTime = tournament?.lockTime else { return nil }
        let remaining = lockTime.timeIntervalSince(Date())
        guard remaining > 0 else { return nil }
        let days = Int(remaining) / 86400
        let hours = (Int(remaining) % 86400) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    var hasLiveData: Bool { lastRefreshDate != nil }

    var userRank: Int? {
        // Don't surface a rank until at least one real match result is in. Otherwise
        // every entry is tied at 0 → everyone shows "Rank #1" briefly before the live
        // data lands. Better to show nothing than flash a wrong value.
        guard hasLiveData, !results.isEmpty,
              let entry = leaderboardEntries.first(where: { $0.isCurrentUser }),
              entry.totalPoints > 0 || leaderboardEntries.contains(where: { $0.totalPoints > 0 })
        else { return nil }
        return entry.rank
    }

    var userTotalPoints: Double? {
        guard hasLiveData, !results.isEmpty else { return nil }
        return leaderboardEntries.first(where: { $0.isCurrentUser })?.totalPoints
    }

    var completedMatches: Int { results.count }

    var currentRound: String {
        // Return the HIGHEST round that has any matches in play (any completed).
        // Earlier logic returned the lowest incomplete round, so a single
        // postponed R2 match would pin the display to "Round 2" even while
        // R3 was being played. Tennis Slams play rounds in parallel near
        // the bottom of the draw, so we want the leading edge of progress.
        var highestActive = TennisBracketEngine.rounds[0]
        var anyComplete = false
        for (roundIndex, round) in TennisBracketEngine.rounds.enumerated() {
            let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
            var roundComplete = 0
            for matchNum in 1...matchCount {
                let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
                if results[slot] != nil { roundComplete += 1 }
            }
            if roundComplete > 0 {
                anyComplete = true
                highestActive = round
            }
        }
        return anyComplete ? highestActive : TennisBracketEngine.rounds[0]
    }

    var currentRoundProgress: (completed: Int, total: Int) {
        let round = currentRound
        guard let roundIndex = TennisBracketEngine.rounds.firstIndex(of: round) else { return (0, 0) }
        let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
        var completed = 0
        for matchNum in 1...matchCount {
            let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
            if results[slot] != nil { completed += 1 }
        }
        return (completed, matchCount)
    }

    /// Group standings — read directly from `currentGroupStandings` which is
    /// populated by `loadGroupStandings`. Falls back to filtering the current
    /// view model's leaderboardEntries if the dedicated load hasn't run yet.
    var groupLeaderboard: [TennisBracketLeaderboardEntry] {
        if !currentGroupStandings.isEmpty { return currentGroupStandings }
        guard currentGroup != nil else { return [] }
        // Fallback path (legacy): filter the currently-loaded leaderboard by member IDs.
        // This works only when the current tournament matches the group's tournament
        // AND every member's entry is in fieldEntries.
        let memberIDs = Set(currentGroupMembers.map { $0.userID.lowercased() })
        let filtered = leaderboardEntries.filter { entry in
            if entry.isCurrentUser { return true }
            if let field = fieldEntries.first(where: { $0.id == entry.id }),
               let uid = field.userID?.lowercased(), memberIDs.contains(uid) {
                return true
            }
            return false
        }
        return filtered.enumerated().map { index, entry in
            TennisBracketLeaderboardEntry(
                id: entry.id, entryName: entry.entryName, picks: entry.picks,
                totalPoints: entry.totalPoints, rank: index + 1,
                isCurrentUser: entry.isCurrentUser, roundBreakdown: entry.roundBreakdown,
                maxPossiblePoints: entry.maxPossiblePoints
            )
        }
    }

    /// Robustly compute the group standings by fetching the group's tournament
    /// entries and results directly. This is independent of which tournament is
    /// currently selected in the view model — so opening a group always shows
    /// correct scores even if the user is browsing a different bracket.
    func loadGroupStandings(group: TennisBracketGroup) async {
        guard let token = accessToken else { return }
        let groupTournamentID = group.tournamentID

        async let resultsFetch = SupabaseService.shared.fetchTennisBracketResults(
            tournamentID: groupTournamentID, accessToken: token
        )
        async let entriesFetch = SupabaseService.shared.fetchTennisBracketEntries(
            tournamentID: groupTournamentID, accessToken: token
        )

        let storedResults = (try? await resultsFetch) ?? [:]
        let records = (try? await entriesFetch) ?? []
        currentGroupResults = storedResults

        let memberIDs = Set(currentGroupMembers.map { $0.userID.lowercased() })
        let uid = userID?.lowercased()

        // Filter to members' entries (matched by user_id, case-insensitive).
        // The current user is always included even if their UUID case differs.
        let memberEntries = records.filter { rec in
            guard let rid = rec.userID?.lowercased() else { return false }
            return memberIDs.contains(rid) || rid == uid
        }

        // Score each entry against current results and rank.
        var scored: [(record: TennisBracketEntryRecord, points: Double, breakdown: [String: Int], maxPossible: Double)] = []
        for rec in memberEntries {
            let (total, breakdown) = TennisBracketEngine.scoreBracket(picks: rec.picks, results: storedResults)
            let maxPossible = TennisBracketEngine.maxPossibleScore(picks: rec.picks, results: storedResults)
            scored.append((rec, total, breakdown, maxPossible))
        }
        scored.sort { $0.points > $1.points }

        // Standard competition ranking.
        var ranks: [Int] = []
        for index in scored.indices {
            if index > 0, scored[index].points == scored[index - 1].points {
                ranks.append(ranks[index - 1])
            } else {
                ranks.append(index + 1)
            }
        }

        let board: [TennisBracketLeaderboardEntry] = scored.enumerated().map { idx, item in
            TennisBracketLeaderboardEntry(
                id: UUID(uuidString: item.record.id) ?? UUID(),
                entryName: item.record.entryName,
                picks: item.record.picks,
                totalPoints: item.points,
                rank: ranks[idx],
                isCurrentUser: item.record.userID?.lowercased() == uid,
                roundBreakdown: item.breakdown,
                maxPossiblePoints: item.maxPossible
            )
        }

        currentGroupStandings = board
    }

    // MARK: - Tournament ID

    static func currentTournamentID(grandSlam: GrandSlam, drawType: DrawType) -> String {
        let year = Calendar.current.component(.year, from: Date())
        return "\(grandSlam.rawValue)-\(drawType.rawValue)-\(year)"
    }

    static func currentSeasonTitle(grandSlam: GrandSlam, drawType: DrawType) -> String {
        let year = Calendar.current.component(.year, from: Date())
        return "\(year) \(grandSlam.displayName) — \(drawType.shortName)"
    }

    /// Estimate the lock time for a Grand Slam based on typical R1 start dates.
    /// Picks lock at 5:00 AM ET on the first day of main draw play.
    static func estimatedLockTime(grandSlam: GrandSlam, year: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        // Approximate R1 start dates (these shift year-to-year by a day or two)
        let (month, day): (Int, Int)
        switch grandSlam {
        case .australianOpen: (month, day) = (1, 14)   // Mid January
        case .frenchOpen:     (month, day) = (5, 24)   // Late May (2026: R1 starts Sun May 24)
        case .wimbledon:      (month, day) = (6, 30)   // Late June
        case .usOpen:         (month, day) = (8, 25)   // Late August
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 5
        components.minute = 0
        return calendar.date(from: components)
    }

    // MARK: - Load Tournament

    func loadTournament() async {
        // Bump the load token. Any in-flight previous load whose token
        // doesn't match this one anymore is "stale" and must NOT write
        // results when it eventually finishes.
        currentLoadToken += 1
        let myToken = currentLoadToken
        let myDrawType = selectedDrawType
        isLoading = true
        error = nil

        let tournamentID = Self.currentTournamentID(grandSlam: selectedGrandSlam, drawType: selectedDrawType)
        // Only blow away per-tournament state when we're actually switching
        // to a different tournament. Reloading the SAME tournament (e.g. a
        // duplicate task fire on first appearance, or a manual refresh)
        // used to wipe userPicks/results/fieldEntries unconditionally —
        // and if the subsequent server fetch transient-failed, the user's
        // bracket would disappear until they re-toggled draw types.
        let isSwitchingTournament = lastLoadedTournamentID != tournamentID
        if isSwitchingTournament {
            drawAvailable = false
            hasSubmitted = false
            userPicks = [:]
            results = [:]
            drawPlayers = []
            leaderboardEntries = []
            fieldEntries = []
            fieldGenerated = false
            myGroups = []
            currentGroup = nil
            currentGroupMembers = []
            // Clear restore-attempted gate for the new tournament so
            // the late-bind fetch runs at least once for it.
            restoreAttemptedTournamentIDs.remove(tournamentID)
        }

        // Create a local tournament object so we always have one even if Supabase fails
        let year = Calendar.current.component(.year, from: Date())
        let estimatedLockTime = Self.estimatedLockTime(grandSlam: selectedGrandSlam, year: year)
        let fallbackTournament = TennisBracketTournament(
            id: tournamentID,
            title: Self.currentSeasonTitle(grandSlam: selectedGrandSlam, drawType: selectedDrawType),
            grandSlam: selectedGrandSlam,
            drawType: selectedDrawType,
            season: "\(year)",
            status: "open",
            lockTime: estimatedLockTime,
            entryCount: 1000,
            isSettled: false,
            createdAt: Date()
        )

        do {
            // Try to load existing tournament from Supabase
            var loadedTournament: TennisBracketTournament?
            if let token = accessToken {
                if let record = try? await SupabaseService.shared.fetchTennisBracketTournament(
                    tournamentID: tournamentID, accessToken: token
                ) {
                    loadedTournament = TennisBracketTournament(
                        id: record.id,
                        title: record.title,
                        grandSlam: GrandSlam(rawValue: record.grandSlam) ?? selectedGrandSlam,
                        drawType: DrawType(rawValue: record.drawType) ?? selectedDrawType,
                        season: record.season,
                        status: record.status,
                        lockTime: record.lockTime,
                        entryCount: record.entryCount ?? 1000,
                        isSettled: record.isSettled ?? false,
                        createdAt: record.createdAt ?? Date()
                    )
                }
            }

            // Pull the lockTime forward if our current estimate is earlier than the stored value,
            // or if the stored value is missing entirely.
            if let loaded = loadedTournament,
               loaded.status == "open",
               let estimated = estimatedLockTime,
               (loaded.lockTime == nil || estimated < loaded.lockTime!) {
                let corrected = TennisBracketTournament(
                    id: loaded.id, title: loaded.title, grandSlam: loaded.grandSlam,
                    drawType: loaded.drawType, season: loaded.season, status: loaded.status,
                    lockTime: estimated, entryCount: loaded.entryCount,
                    isSettled: loaded.isSettled, createdAt: loaded.createdAt
                )
                loadedTournament = corrected
                if let token = accessToken {
                    let record = TennisBracketTournamentRecord(
                        id: corrected.id, title: corrected.title,
                        grandSlam: corrected.grandSlam.rawValue, drawType: corrected.drawType.rawValue,
                        season: corrected.season, status: corrected.status, lockTime: estimated
                    )
                    try? await SupabaseService.shared.upsertTennisBracketTournament(
                        record: record, accessToken: token
                    )
                }
            }

            // Detect and undo a false settlement: a Grand Slam takes ~14 days. If the
            // tournament is flagged settled but lockTime was less than 13 days ago, the
            // settle() call was triggered by polluted cross-tournament results. Reset.
            if let loaded = loadedTournament,
               loaded.isSettled || loaded.status == "settled",
               let lock = loaded.lockTime ?? estimatedLockTime,
               Date().timeIntervalSince(lock) < 13 * 24 * 3600 {
                print("[TennisBracket] Detected false settlement (lockTime only \(Int(Date().timeIntervalSince(lock) / 3600))h ago) — resetting")
                let corrected = TennisBracketTournament(
                    id: loaded.id, title: loaded.title, grandSlam: loaded.grandSlam,
                    drawType: loaded.drawType, season: loaded.season, status: "live",
                    lockTime: loaded.lockTime, entryCount: loaded.entryCount,
                    isSettled: false, createdAt: loaded.createdAt
                )
                loadedTournament = corrected
                if let token = accessToken {
                    try? await SupabaseService.shared.updateTennisBracketResults(
                        tournamentID: loaded.id, results: [:], accessToken: token
                    )
                    // Upsert with is_settled=false so the row's settlement flag is cleared.
                    let record = TennisBracketTournamentRecord(
                        id: corrected.id, title: corrected.title,
                        grandSlam: corrected.grandSlam.rawValue, drawType: corrected.drawType.rawValue,
                        season: corrected.season, status: "live", lockTime: corrected.lockTime,
                        entryCount: corrected.entryCount, isSettled: false
                    )
                    try? await SupabaseService.shared.upsertTennisBracketTournament(
                        record: record, accessToken: token
                    )
                }
                results = [:]
            }

            // Staleness check: if the user has tapped the other draw pill
            // since we started, abandon this load before we overwrite the
            // newer load's state.
            guard myToken == currentLoadToken, myDrawType == selectedDrawType else { return }

            tournament = loadedTournament ?? fallbackTournament

            // Only upsert if we created a new tournament (no existing record found)
            if loadedTournament == nil, let token = accessToken {
                let record = TennisBracketTournamentRecord(
                    id: fallbackTournament.id,
                    title: fallbackTournament.title,
                    grandSlam: fallbackTournament.grandSlam.rawValue,
                    drawType: fallbackTournament.drawType.rawValue,
                    season: fallbackTournament.season,
                    status: fallbackTournament.status,
                    lockTime: fallbackTournament.lockTime
                )
                try? await SupabaseService.shared.upsertTennisBracketTournament(
                    record: record, accessToken: token
                )
            }

            // Fetch draw data: Supabase → hardcoded → ESPN scrape
            if let token = accessToken {
                let draw = (try? await SupabaseService.shared.fetchTennisBracketDrawData(
                    tournamentID: tournamentID, accessToken: token
                )) ?? []
                let year = Calendar.current.component(.year, from: Date())
                let hardcodedCandidate = TennisBracketDrawData.hardcodedDraw(
                    grandSlam: selectedGrandSlam, drawType: selectedDrawType, year: year
                )

                // Validate the Supabase draw against the known-good hardcoded
                // draw. If overlap is low (<30%), the Supabase record was
                // contaminated (e.g. a previous bug wrote ATP players into the
                // WTA tournament's draw row, which is exactly how the WTA
                // bots ended up showing Jannik Sinner / Hubert Hurkacz et al.
                // in the user's WTA leaderboard). Reject and rewrite from
                // hardcoded.
                let supabaseDrawIsValid: Bool = {
                    guard draw.count == 128 else { return false }
                    guard let hardcoded = hardcodedCandidate, hardcoded.count == 128 else {
                        // No hardcoded baseline — trust Supabase by default.
                        return true
                    }
                    let normalize = TennisBracketEngine.normalizedName
                    let hardcodedNames = Set(hardcoded.map { normalize($0.name) })
                    let supabaseNames = draw.map { normalize($0.name) }
                    let overlap = supabaseNames.filter { hardcodedNames.contains($0) }.count
                    let overlapRate = Double(overlap) / 128.0
                    if overlapRate < 0.3 {
                        print("[TennisBracket] Supabase draw for \(tournamentID) only \(Int(overlapRate * 100))% overlaps the hardcoded \(selectedDrawType.rawValue) draw — treating as corrupted and falling back to hardcoded")
                        return false
                    }
                    return true
                }()

                if supabaseDrawIsValid {
                    drawPlayers = draw
                    drawAvailable = true
                    print("[TennisBracket] Draw loaded from Supabase: \(draw.count) players")
                } else if let hardcoded = hardcodedCandidate, hardcoded.count == 128 {
                    drawPlayers = hardcoded
                    drawAvailable = true
                    print("[TennisBracket] Draw loaded from hardcoded data: \(hardcoded.count) players — overwriting Supabase to heal corruption")
                    // Overwrite Supabase with the correct draw so other
                    // devices stop pulling the contaminated record.
                    try? await SupabaseService.shared.updateTennisBracketDrawData(
                        tournamentID: tournamentID, draw: hardcoded, accessToken: token
                    )
                    // The cached bot field was generated against the bad
                    // draw — clear it so the next refreshLive / settled
                    // load regenerates against the correct hardcoded draw.
                    UserDefaults.standard.removeObject(forKey: "\(Self.botCacheKey)_\(tournamentID)")
                    if let url = Self.botCacheFileURL(tournamentID: tournamentID) {
                        try? FileManager.default.removeItem(at: url)
                    }
                    fieldEntries = []
                    fieldGenerated = false
                } else {
                    // Fallback: try fetching from ESPN bracket page HTML
                    print("[TennisBracket] No hardcoded draw — fetching from ESPN...")
                    let fetcher = ESPNTennisDrawFetcher()
                    let espnDraw = await fetcher.fetchDraw(grandSlam: selectedGrandSlam, drawType: selectedDrawType)
                    if espnDraw.count == 128 {
                        drawPlayers = espnDraw
                        drawAvailable = true
                        print("[TennisBracket] Draw fetched from ESPN: \(espnDraw.count) players — saving to Supabase")
                        try? await SupabaseService.shared.updateTennisBracketDrawData(
                            tournamentID: tournamentID, draw: espnDraw, accessToken: token
                        )
                    } else {
                        print("[TennisBracket] ESPN draw fetch returned \(espnDraw.count) players (need 128)")
                    }
                }
            }

            // Check if user already has an entry
            if let token = accessToken, let uid = userID {
                if let existingEntry = try? await SupabaseService.shared.fetchUserTennisBracketEntry(
                    tournamentID: tournamentID, userID: uid, accessToken: token
                ) {
                    hasSubmitted = true
                    userPicks = existingEntry.picks
                    print("[TennisBracket] Restored \(existingEntry.picks.count) picks from server")
                }

                // Also probe the OTHER draw type so the active-contests list can show
                // both ATP and WTA cards on the home screen even when only one is loaded.
                let year = Calendar.current.component(.year, from: Date())
                let atpID = "\(selectedGrandSlam.rawValue)-\(DrawType.atp.rawValue)-\(year)"
                let wtaID = "\(selectedGrandSlam.rawValue)-\(DrawType.wta.rawValue)-\(year)"
                async let atpEntry = SupabaseService.shared.fetchUserTennisBracketEntry(
                    tournamentID: atpID, userID: uid, accessToken: token
                )
                async let wtaEntry = SupabaseService.shared.fetchUserTennisBracketEntry(
                    tournamentID: wtaID, userID: uid, accessToken: token
                )
                let atpEntryRec = try? await atpEntry
                let wtaEntryRec = try? await wtaEntry
                hasSubmittedATP = atpEntryRec != nil
                hasSubmittedWTA = wtaEntryRec != nil

                // Also fetch each draw's live status so both home-screen cards reflect
                // LIVE/LOCKED correctly without needing to open both views.
                async let atpTournament = SupabaseService.shared.fetchTennisBracketTournament(
                    tournamentID: atpID, accessToken: token
                )
                async let wtaTournament = SupabaseService.shared.fetchTennisBracketTournament(
                    tournamentID: wtaID, accessToken: token
                )
                if let atpT = try? await atpTournament {
                    atpIsLive = atpT.status == "live"
                }
                if let wtaT = try? await wtaTournament {
                    wtaIsLive = wtaT.status == "live"
                }

                // Compute the user's rank for the OTHER draw in background so both
                // active-contest cards show real ranks. We compute the currently-loaded
                // draw's rank via the main pipeline; only the off-draw needs prefetch.
                let otherDrawType: DrawType = selectedDrawType == .atp ? .wta : .atp
                let otherID = otherDrawType == .atp ? atpID : wtaID
                let otherEntry = otherDrawType == .atp ? atpEntryRec : wtaEntryRec
                if let otherEntry, !otherEntry.picks.isEmpty {
                    Task { [otherID, otherEntry, otherDrawType] in
                        // Fetch the field + results for the off-draw, compute leaderboard,
                        // pull out the user's rank.
                        async let resultsFetch = SupabaseService.shared.fetchTennisBracketResults(
                            tournamentID: otherID, accessToken: token
                        )
                        async let entriesFetch = SupabaseService.shared.fetchTennisBracketEntries(
                            tournamentID: otherID, accessToken: token
                        )
                        let storedResults = (try? await resultsFetch) ?? [:]
                        let records = (try? await entriesFetch) ?? []
                        guard !records.isEmpty, !storedResults.isEmpty else { return }
                        let entries = records.map { rec in
                            TennisBracketEntry(
                                id: UUID(uuidString: rec.id) ?? UUID(),
                                tournamentID: rec.tournamentID, userID: rec.userID,
                                entryName: rec.entryName, picks: rec.picks,
                                totalPoints: rec.totalPoints ?? 0,
                                rank: rec.rank ?? 0,
                                isBot: rec.isBot ?? false,
                                isCurrentUser: rec.userID == uid
                            )
                        } + [TennisBracketEntry(
                            id: UUID(), tournamentID: otherID, userID: uid,
                            entryName: self.profileName.isEmpty ? "Player" : self.profileName,
                            picks: otherEntry.picks,
                            totalPoints: 0, rank: 0, isBot: false, isCurrentUser: true
                        )]
                        let board = TennisBracketEngine.computeLeaderboard(
                            entries: entries, results: storedResults, currentUserID: uid
                        )
                        guard let userRow = board.first(where: { $0.isCurrentUser }) else { return }
                        // Only surface the rank if real scoring has happened (someone scored > 0).
                        let anyScored = board.contains(where: { $0.totalPoints > 0 })
                        guard anyScored else { return }
                        await MainActor.run {
                            if otherDrawType == .atp { self.atpUserRank = userRow.rank }
                            else { self.wtaUserRank = userRow.rank }
                        }
                    }
                }
            }

            // If no server entry, try to restore from local progress
            if !hasSubmitted {
                loadPickProgress()
            }
            // Mirror the currently-loaded draw's submitted state into the dual flags
            // for the case where loadPickProgress restored picks locally.
            if hasSubmitted {
                if selectedDrawType == .atp { hasSubmittedATP = true }
                else { hasSubmittedWTA = true }
            }

            // Fetch stored results
            if let token = accessToken {
                let storedResults = (try? await SupabaseService.shared.fetchTennisBracketResults(
                    tournamentID: tournamentID, accessToken: token
                )) ?? [:]
                // Staleness check before writing — guards against the
                // stale ATP load shoving its results into a now-WTA state.
                guard myToken == currentLoadToken, myDrawType == selectedDrawType else { return }
                if !storedResults.isEmpty {
                    results = storedResults
                }
            }

            // Auto-detect status transitions
            await checkStatusTransition()

            // If status is still "open" but the draw is live, poll ESPN — a non-empty
            // response proves the slam has started even if lockTime/results were stale,
            // and the subsequent transition flips us into the live view.
            if tournament?.status == "open", drawAvailable,
               let t = tournament {
                let espnResults = await espnProvider.fetchMatchResults(
                    drawType: t.drawType, drawPlayers: drawPlayers, grandSlam: t.grandSlam,
                    notBefore: t.lockTime
                )
                if !espnResults.isEmpty {
                    for (slot, winner) in espnResults { results[slot] = winner }
                    if let token = accessToken {
                        try? await SupabaseService.shared.updateTennisBracketResults(
                            tournamentID: t.id, results: results, accessToken: token
                        )
                    }
                    await checkStatusTransition()
                }
            }

            // Check SETTLED first — `isLocked` includes settled, so an
            // `if isLocked` branch would capture settled tournaments
            // first, send them into refreshLive, and refreshLive would
            // bail immediately on `tournament.isSettled`. That's how
            // settled WTA brackets ended up showing 999 bots all at 0
            // pts — neither path populated `results` or rebuilt the
            // leaderboard against fresh WTA data.
            if tournament?.isSettled == true {
                // Settled tournaments used to render an empty leaderboard
                // ("Field Size 0") because refreshLive bails on settled
                // and nothing else loaded the field. Pull the persisted
                // bot field once so a final standings card has data.
                if fieldEntries.isEmpty {
                    await loadFieldEntries()
                }
                // Fetch ESPN results for the settled tournament's own
                // draw type. Without this, `results` was empty (Supabase
                // stored row may have been cleared) and bot leaderboard
                // grading produced 0 points across the board.
                if drawAvailable, let t = tournament {
                    let freshResults = await espnProvider.fetchMatchResults(
                        drawType: t.drawType,
                        drawPlayers: drawPlayers,
                        grandSlam: t.grandSlam,
                        notBefore: t.lockTime
                    )
                    var merged = results
                    for (slot, winner) in freshResults {
                        merged[slot] = winner
                    }
                    if merged != results {
                        results = merged
                        if let token = accessToken {
                            try? await SupabaseService.shared.updateTennisBracketResults(
                                tournamentID: t.id, results: results, accessToken: token
                            )
                        }
                    }
                }
                leaderboardEntries = TennisBracketEngine.computeLeaderboard(
                    entries: fieldEntries,
                    results: results,
                    currentUserID: userID
                )
                // Mark live-data ready so `userRank` / `userTotalPoints`
                // surface in the header. Without this, settled brackets
                // never set `lastRefreshDate` (refreshLive bails early
                // on `isSettled`), so the accessors return nil and the
                // header shows only Field Size — no rank, no points,
                // even though the leaderboard is right there.
                lastRefreshDate = Date()
                // Stale-cache guard for SETTLED tournaments. The same
                // guard exists in refreshLive but doesn't run for
                // settled brackets because refreshLive bails early on
                // `tournament.isSettled`. Without it, a WTA/ATP draw
                // that updated (qualifier swap, withdrawal, etc.) after
                // bots were initially saved leaves the leaderboard
                // showing 999 cached bots all at 0.0 vs 127 resolved
                // ESPN results — exactly the WTA case the user
                // reported. Detect "many bots, real results, all-zero"
                // and regenerate against the current draw.
                if results.count >= 5,
                   let tournament,
                   tournament.isSettled {
                    let botEntries = fieldEntries.filter { $0.isBot }
                    let totalBotPoints = leaderboardEntries
                        .filter { !$0.isCurrentUser }
                        .reduce(0.0) { $0 + $1.totalPoints }
                    if botEntries.count >= 500, totalBotPoints == 0, drawAvailable {
                        print("[TennisBracket] Settled — all \(botEntries.count) cached bots score 0 vs \(results.count) resolved results — regenerating against current draw")
                        UserDefaults.standard.removeObject(forKey: "\(Self.botCacheKey)_\(tournament.id)")
                        if let url = Self.botCacheFileURL(tournamentID: tournament.id) {
                            try? FileManager.default.removeItem(at: url)
                        }
                        fieldEntries = []
                        fieldGenerated = false
                        await generateBotField()
                        leaderboardEntries = TennisBracketEngine.computeLeaderboard(
                            entries: fieldEntries,
                            results: results,
                            currentUserID: userID
                        )
                    }
                }
            } else if isLocked {
                // Locked but not settled (live / pre-final). Standard
                // path — refreshLive fetches results, builds field,
                // computes leaderboard.
                await refreshLive()
            }

        } catch {
            // Ensure we always have a tournament object to prevent nil crashes
            if tournament == nil {
                tournament = fallbackTournament
            }
            print("[TennisBracket] Error loading: \(error)")
        }

        // Only the most-recent load claims completion. If the user has
        // switched draw types mid-flight, leave the loading flags for the
        // newer load to manage.
        guard myToken == currentLoadToken else { return }
        isLoading = false
        hasAttemptedLoad = true
        // Latch the tournament ID so a subsequent reload of the same
        // tournament skips the state wipe.
        lastLoadedTournamentID = tournamentID
    }

    /// Re-fetch the user's submitted entry from Supabase if `userPicks` is
    /// empty but auth is now available. The first `loadTournament` call
    /// often happens before auth has propagated (it fires from
    /// FantasyHubView's `.task` at app launch), so the entry-fetch inside
    /// `loadTournament` gets skipped silently because `accessToken` or
    /// `userID` is nil at that moment. `hasAttemptedLoad` then gets
    /// force-set to true, blocking any retry — so the user's bracket
    /// appears lost ("No bracket submitted") even though it's still in
    /// Supabase. Same pattern as PlayoffTiers/SoccerTiers. Call from
    /// the lobby's and live view's `.task` after auth has had time to
    /// settle.
    func restoreUserPicksIfMissing() async {
        guard userPicks.isEmpty, !hasSubmitted else { return }
        guard let token = accessToken, let uid = userID else { return }
        let tournamentID = tournament?.id ?? Self.currentTournamentID(
            grandSlam: selectedGrandSlam, drawType: selectedDrawType
        )
        // One attempt per tournament per session. The previous version
        // looped forever for users without a server entry: toggling
        // isLoading caused the lobby body to swap loadingView in/out,
        // unmounting the live view and restarting its .task → infinite
        // re-fire of restoreUserPicksIfMissing + spamming -999 errors
        // on loadMyGroups.
        guard !restoreAttemptedTournamentIDs.contains(tournamentID) else { return }
        restoreAttemptedTournamentIDs.insert(tournamentID)

        // Don't toggle isLoading here — it swaps the lobby's view
        // subtree (isLoading-branch wins over isLocked-branch) and
        // unmounts the in-flight live view. Run the fetch quietly.
        guard let existingEntry = try? await SupabaseService.shared.fetchUserTennisBracketEntry(
            tournamentID: tournamentID, userID: uid, accessToken: token
        ) else {
            print("[TennisBracket] restoreUserPicksIfMissing: no server entry for \(tournamentID)")
            return
        }
        hasSubmitted = true
        userPicks = existingEntry.picks
        if selectedDrawType == .atp { hasSubmittedATP = true }
        else { hasSubmittedWTA = true }
        print("[TennisBracket] Restored \(existingEntry.picks.count) picks via late-bind fetch")

        // The field was loaded earlier without the user's entry (since
        // hasSubmitted was false and userPicks was empty). Inject the
        // user now so they show up in the leaderboard / Field Size 1000.
        if let tournament, !fieldEntries.contains(where: { $0.isCurrentUser }) {
            fieldEntries.append(TennisBracketEntry(
                id: UUID(),
                tournamentID: tournament.id,
                userID: uid,
                entryName: profileName.isEmpty ? "Player" : profileName,
                picks: userPicks,
                totalPoints: 0,
                rank: 0,
                isBot: false,
                isCurrentUser: true
            ))
            // Recompute the leaderboard so the user gets a rank.
            leaderboardEntries = TennisBracketEngine.computeLeaderboard(
                entries: fieldEntries,
                results: results,
                currentUserID: userID
            )
        }
    }

    // MARK: - Pick Management

    func pickWinner(slot: String, playerName: String) {
        guard !isLocked else { return }

        // If changing a pick, clear downstream picks of the old player
        if let oldPick = userPicks[slot], oldPick != playerName {
            TennisBracketEngine.clearDownstreamPicks(from: slot, playerName: oldPick, picks: &userPicks)
        }

        userPicks[slot] = playerName
        savePickProgress()
    }

    func clearPick(slot: String) {
        guard !isLocked else { return }
        if let oldPick = userPicks[slot] {
            TennisBracketEngine.clearDownstreamPicks(from: slot, playerName: oldPick, picks: &userPicks)
            userPicks.removeValue(forKey: slot)
            savePickProgress()
        }
    }

    // MARK: - Submit Picks

    func submitPicks() async {
        guard allPicksMade, !isSubmitting else { return }
        guard let token = accessToken, let uid = userID else { return }
        guard let tournament else { return }

        isSubmitting = true
        submitError = nil
        do {
            try await SupabaseService.shared.submitTennisBracketEntry(
                tournamentID: tournament.id,
                userID: uid,
                entryName: profileName.isEmpty ? "Player" : profileName,
                picks: userPicks,
                accessToken: token
            )
            hasSubmitted = true
            clearPickProgress()
            print("[TennisBracket] Picks submitted (\(userPicks.count) picks)")
        } catch {
            submitError = "Failed to save bracket. Please check your connection and try again."
            print("[TennisBracket] Failed to submit: \(error)")
        }
        isSubmitting = false
    }

    // MARK: - Status Transitions

    private func checkStatusTransition() async {
        guard var t = tournament, !t.isSettled else { return }

        // open → locked: past lock time, or results already exist (slam is underway).
        // The results check handles cases where the stored lockTime estimate was off — once
        // ESPN reports any completed match, the tournament has clearly started.
        let lockTimePassed = (t.lockTime.map { Date() >= $0 }) ?? false
        if t.status == "open", lockTimePassed || !results.isEmpty {
            let updated = TennisBracketTournament(
                id: t.id, title: t.title, grandSlam: t.grandSlam, drawType: t.drawType,
                season: t.season, status: "locked", lockTime: t.lockTime,
                entryCount: t.entryCount, isSettled: false, createdAt: t.createdAt
            )
            tournament = updated
            t = updated
            if let token = accessToken {
                try? await SupabaseService.shared.updateTennisBracketTournamentStatus(
                    tournamentID: t.id, status: "locked", accessToken: token
                )
            }
        }

        // locked → live: results exist
        if t.status == "locked" && !results.isEmpty {
            let updated = TennisBracketTournament(
                id: t.id, title: t.title, grandSlam: t.grandSlam, drawType: t.drawType,
                season: t.season, status: "live", lockTime: t.lockTime,
                entryCount: t.entryCount, isSettled: false, createdAt: t.createdAt
            )
            tournament = updated
            t = updated
            if let token = accessToken {
                try? await SupabaseService.shared.updateTennisBracketTournamentStatus(
                    tournamentID: t.id, status: "live", accessToken: token
                )
            }
        }

        // live → settled: Final match completed. Gate on time elapsed since lock so a
        // bogus F-1 entry (e.g., from a misattributed match) can't prematurely settle
        // the bracket during the first week of the slam.
        if t.status == "live" && results["F-1"] != nil {
            let elapsed = t.lockTime.map { Date().timeIntervalSince($0) } ?? .infinity
            if elapsed >= 12 * 24 * 3600 {
                await settle()
            } else {
                print("[TennisBracket] Ignoring suspicious F-1 result (only \(Int(elapsed / 3600))h since lockTime)")
            }
        }
    }

    // MARK: - Refresh Live

    func refreshLive() async {
        guard let tournament, !tournament.isSettled else { return }

        // Fetch fresh ESPN results and MERGE with existing — never shrink. ESPN
        // occasionally returns partial / empty responses on transient failures,
        // and clobbering with that would flash a 0-score leaderboard on view
        // reappearance (e.g., when navigating back from a group detail). New slot
        // values still overwrite old ones, so corrections still propagate.
        if drawAvailable {
            let espnResults = await espnProvider.fetchMatchResults(
                drawType: tournament.drawType,
                drawPlayers: drawPlayers,
                grandSlam: tournament.grandSlam,
                notBefore: tournament.lockTime
            )
            var merged = results
            for (slot, winner) in espnResults {
                merged[slot] = winner
            }
            if merged != results {
                results = merged
                if let token = accessToken {
                    try? await SupabaseService.shared.updateTennisBracketResults(
                        tournamentID: tournament.id, results: results, accessToken: token
                    )
                }
            }
        }

        // Load field entries if not yet done
        if fieldEntries.isEmpty {
            await loadFieldEntries()
        }

        // Compute leaderboard
        leaderboardEntries = TennisBracketEngine.computeLeaderboard(
            entries: fieldEntries,
            results: results,
            currentUserID: userID
        )

        // Stale-cache guard: if ESPN has resolved enough matches that bots should score
        // but every bot is at zero, the cached lineups predate our chalk-favoring bot
        // generator (they're all upset-heavy losers). Wipe the cache and regenerate.
        if results.count >= 5 {
            let botEntries = fieldEntries.filter { $0.isBot }
            let totalBotPoints = leaderboardEntries
                .filter { !$0.isCurrentUser }
                .reduce(0.0) { $0 + $1.totalPoints }
            if botEntries.count >= 500, totalBotPoints == 0 {
                print("[TennisBracket] All \(botEntries.count) cached bots score 0 vs \(results.count) resolved results — regenerating with current chalk-favoring logic")
                UserDefaults.standard.removeObject(forKey: "\(Self.botCacheKey)_\(tournament.id)")
                if let url = Self.botCacheFileURL(tournamentID: tournament.id) {
                    try? FileManager.default.removeItem(at: url)
                }
                fieldEntries = []
                fieldGenerated = false
                await generateBotField()
                leaderboardEntries = TennisBracketEngine.computeLeaderboard(
                    entries: fieldEntries,
                    results: results,
                    currentUserID: userID
                )
            }
        }
        lastRefreshDate = Date()

        // Check for tournament completion
        await checkStatusTransition()
    }

    // MARK: - Field Entries

    private func loadFieldEntries() async {
        guard let tournament, let token = accessToken else { return }

        // 1. Try entries table
        if let records = try? await SupabaseService.shared.fetchTennisBracketEntries(
            tournamentID: tournament.id, accessToken: token
        ), records.count >= 500 {
            fieldEntries = records.map { rec in
                TennisBracketEntry(
                    id: UUID(uuidString: rec.id) ?? UUID(),
                    tournamentID: rec.tournamentID,
                    userID: rec.userID,
                    entryName: rec.entryName,
                    picks: rec.picks,
                    totalPoints: rec.totalPoints ?? 0,
                    rank: rec.rank ?? 0,
                    isBot: rec.isBot ?? false,
                    isCurrentUser: rec.userID == userID
                )
            }
            print("[TennisBracket] Loaded \(fieldEntries.count) entries from table")
            return
        }

        // 2. Try bot_field column
        if let botField = try? await SupabaseService.shared.fetchTennisBracketBotField(
            tournamentID: tournament.id, accessToken: token
        ), !botField.isEmpty {
            restoreFieldFromBotData(botField, tournamentID: tournament.id)
            if fieldEntries.count >= 500 {
                print("[TennisBracket] Restored \(fieldEntries.count) entries from bot_field")
                return
            }
        }

        // 3. Try local cache
        if let cachedBots = loadBotCacheLocally(tournamentID: tournament.id) {
            restoreFieldFromBotData(cachedBots, tournamentID: tournament.id)
            if fieldEntries.count >= 500 {
                print("[TennisBracket] Restored \(fieldEntries.count) entries from local cache")
                return
            }
        }

        // 4. Generate fresh
        guard drawAvailable else { return }
        await generateBotField()
    }

    private func restoreFieldFromBotData(_ botData: [[String: Any]], tournamentID: String) {
        var entries: [TennisBracketEntry] = []
        for bot in botData {
            guard let name = bot["entry_name"] as? String ?? bot["name"] as? String,
                  let picks = bot["picks"] as? [String: String] else { continue }
            entries.append(TennisBracketEntry(
                id: UUID(),
                tournamentID: tournamentID,
                userID: nil,
                entryName: name,
                picks: picks,
                totalPoints: 0,
                rank: 0,
                isBot: true,
                isCurrentUser: false
            ))
        }

        // Stale-cache guard: if the cached bots' picks reference player names that
        // aren't in the current draw (e.g., the WTA draw got updated since these bots
        // were generated), every bot will score 0 against fresh ESPN results. Detect
        // that and bail so the caller will regenerate from the current draw instead.
        if !entries.isEmpty, !drawPlayers.isEmpty {
            let drawNames = Set(drawPlayers.map { TennisBracketEngine.normalizedName($0.name) })
            let samplePicks = entries.prefix(20).flatMap { Array($0.picks.values) }
            let matched = samplePicks.filter { drawNames.contains(TennisBracketEngine.normalizedName($0)) }.count
            let matchRate = samplePicks.isEmpty ? 0.0 : Double(matched) / Double(samplePicks.count)
            if matchRate < 0.5 {
                print("[TennisBracket] Cached bots stale (only \(Int(matchRate * 100))% of picks match current draw); discarding so they regenerate")
                fieldEntries = []
                return
            }
        }

        // Include the user's entry whenever they have picks loaded — `hasSubmitted`
        // only flips for server-confirmed entries, but the leaderboard should still
        // grade local picks.
        if (hasSubmitted || !userPicks.isEmpty), let uid = userID {
            entries.append(TennisBracketEntry(
                id: UUID(),
                tournamentID: tournamentID,
                userID: uid,
                entryName: profileName.isEmpty ? "Player" : profileName,
                picks: userPicks,
                totalPoints: 0,
                rank: 0,
                isBot: false,
                isCurrentUser: true
            ))
        }

        fieldEntries = entries
    }

    func generateBotField() async {
        guard !fieldGenerated, drawAvailable else { return }
        guard let tournament, let token = accessToken else { return }
        fieldGenerated = true

        print("[TennisBracket] Generating 999 bot brackets...")
        let bots = TennisBracketBotDrafter.generateBotEntries(
            draw: drawPlayers,
            grandSlam: tournament.grandSlam,
            count: 999,
            tournamentID: tournament.id
        ).map { entry in
            var e = entry
            e = TennisBracketEntry(
                id: entry.id, tournamentID: tournament.id, userID: nil,
                entryName: entry.entryName, picks: entry.picks,
                totalPoints: 0, rank: 0, isBot: true, isCurrentUser: false
            )
            return e
        }

        // Add user entry
        var allEntries = bots
        // Include the user's entry whenever they have picks loaded. The previous
        // `hasSubmitted` check required a server record, but if the server fetch missed
        // the user falls out of fieldEntries entirely (no rank, no points, no leaderboard
        // presence) even though their picks are locally available and graded.
        if (hasSubmitted || !userPicks.isEmpty), let uid = userID {
            allEntries.append(TennisBracketEntry(
                id: UUID(), tournamentID: tournament.id, userID: uid,
                entryName: profileName.isEmpty ? "Player" : profileName,
                picks: userPicks, totalPoints: 0, rank: 0,
                isBot: false, isCurrentUser: true
            ))
        }
        fieldEntries = allEntries
        print("[TennisBracket] Generated \(bots.count) bots + \(hasSubmitted ? 1 : 0) user entry")

        // Persist bots
        let botPicksData: [[String: Any]] = bots.map { bot in
            ["entry_name": bot.entryName, "picks": bot.picks]
        }

        // Save to local cache
        saveBotCacheLocally(botPicksData, tournamentID: tournament.id)

        // Save to bot_field column
        try? await SupabaseService.shared.saveTennisBracketBotField(
            tournamentID: tournament.id, botField: botPicksData, accessToken: token
        )

        // Batch insert to entries table
        let botTuples = bots.map { (name: $0.entryName, picks: $0.picks) }
        try? await SupabaseService.shared.batchInsertTennisBracketBotEntries(
            tournamentID: tournament.id, bots: botTuples, accessToken: token
        )
    }

    // MARK: - Settlement

    private func settle() async {
        guard let tournament, !tournament.isSettled else { return }
        guard let token = accessToken else { return }

        // Compute final leaderboard
        let finalLeaderboard = TennisBracketEngine.computeLeaderboard(
            entries: fieldEntries,
            results: results,
            currentUserID: userID
        )
        leaderboardEntries = finalLeaderboard

        if let userEntry = finalLeaderboard.first(where: { $0.isCurrentUser }) {
            let rrDelta = TennisBracketEngine.rrDelta(
                forRank: userEntry.rank, totalEntries: finalLeaderboard.count
            )
            rrScore += rrDelta

            // Save to local history
            saveTournamentResult(
                tournamentTitle: tournament.title,
                rank: userEntry.rank,
                totalEntries: finalLeaderboard.count,
                points: userEntry.totalPoints,
                rrDelta: rrDelta,
                tournamentID: tournament.id
            )

            // Also save to Supabase dfs_tournament_results so it appears on the profile
            if let uid = userID {
                let tournamentRecord = DFSTournamentRecord(
                    id: tournament.id,
                    title: tournament.title,
                    league: "tennis-bracket",
                    lockTime: tournament.lockTime ?? Date(),
                    isSettled: true,
                    totalEntries: finalLeaderboard.count,
                    playerSalaries: nil,
                    botField: nil
                )
                try? await SupabaseService.shared.upsertTournament(
                    record: tournamentRecord, accessToken: token
                )

                let playerNames = Array(userEntry.picks.values)
                let playerIDs = Array(userEntry.picks.keys)
                let supabaseResult = DFSTournamentResultRecord(
                    id: UUID().uuidString,
                    tournamentID: tournament.id,
                    userID: uid,
                    entryName: profileName.isEmpty ? "Player" : profileName,
                    lineupPlayerIDs: playerIDs,
                    lineupPlayerNames: playerNames,
                    totalPoints: userEntry.totalPoints,
                    playerPoints: nil,
                    playerSalaries: nil,
                    rank: userEntry.rank,
                    rrDelta: rrDelta,
                    isCurrentUser: true,
                    isBot: false,
                    createdAt: Date()
                )
                try? await SupabaseService.shared.upsertTournamentResults(
                    tournamentID: tournament.id,
                    results: [supabaseResult],
                    accessToken: token
                )
            }
        }

        // Mark settled on server
        try? await SupabaseService.shared.markTennisBracketTournamentSettled(
            tournamentID: tournament.id, accessToken: token
        )

        // Update entry scores
        let updates = finalLeaderboard.map {
            (id: $0.id.uuidString, totalPoints: $0.totalPoints, rank: $0.rank)
        }
        try? await SupabaseService.shared.updateTennisBracketEntryScores(
            entries: updates, accessToken: token
        )

        // Update local tournament
        self.tournament = TennisBracketTournament(
            id: tournament.id, title: tournament.title, grandSlam: tournament.grandSlam,
            drawType: tournament.drawType, season: tournament.season, status: "settled",
            lockTime: tournament.lockTime, entryCount: tournament.entryCount,
            isSettled: true, createdAt: tournament.createdAt
        )
    }

    // MARK: - History Helpers

    private func saveTournamentResult(tournamentTitle: String, rank: Int, totalEntries: Int,
                                       points: Double, rrDelta: Int, tournamentID: String) {
        // Decode existing history
        var history: [[String: Any]] = []
        if !dfsHistoryData.isEmpty,
           let decoded = try? JSONSerialization.jsonObject(with: dfsHistoryData) as? [[String: Any]] {
            history = decoded
        }

        // Add result
        let result: [String: Any] = [
            "id": UUID().uuidString,
            "tournamentTitle": tournamentTitle,
            "rank": rank,
            "totalEntries": totalEntries,
            "lineupPoints": points,
            "rrDelta": rrDelta,
            "loggedAt": ISO8601DateFormatter().string(from: Date()),
            "tournamentId": tournamentID
        ]
        history.insert(result, at: 0)

        if let encoded = try? JSONSerialization.data(withJSONObject: history) {
            dfsHistoryData = encoded
        }

        // Mark tournament as settled locally
        var settled: [String] = []
        if !settledTournamentData.isEmpty,
           let decoded = try? JSONSerialization.jsonObject(with: settledTournamentData) as? [String] {
            settled = decoded
        }
        if !settled.contains(tournamentID) {
            settled.append(tournamentID)
            if let encoded = try? JSONSerialization.data(withJSONObject: settled) {
                settledTournamentData = encoded
            }
        }
    }

    private func isTournamentSettledLocally(_ id: String) -> Bool {
        guard !settledTournamentData.isEmpty,
              let decoded = try? JSONSerialization.jsonObject(with: settledTournamentData) as? [String] else { return false }
        return decoded.contains(id)
    }

    /// Pulls every settled tennis-bracket result row the server holds for
    /// this user and merges any missing rows into local `dfsHistoryData`
    /// so the Fantasy Hub Past Results section reflects history without
    /// requiring the user to visit each settled slam in the picker.
    ///
    /// Required because the DFS cross-VM `applyServerHistory` filters
    /// rows by sport prefix (nba-/nhl-/pga-/etc.) and drops anything
    /// tagged with a tennis tid (`<slam>-(atp|wta)-YYYY`). Idempotent.
    func syncSettledTennisHistoryFromServer() async {
        guard let userID, let token = accessToken else { return }

        // Decode current local history once.
        var localHistory: [[String: Any]] = []
        if !dfsHistoryData.isEmpty,
           let decoded = try? JSONSerialization.jsonObject(with: dfsHistoryData) as? [[String: Any]] {
            localHistory = decoded
        }
        let existingTids = Set(localHistory.compactMap { $0["tournamentId"] as? String })

        // PASS 1 — `dfs_tournament_results` (the canonical Past Results
        // source). When `settle()` ran successfully, the user's row lives
        // here with the authoritative rank/points/rrDelta.
        let canonicalRows = (try? await SupabaseService.shared.fetchUserDFSHistory(
            userID: userID, limit: 200, offset: 0, accessToken: token
        )) ?? []
        let canonicalTennisRows = canonicalRows.filter { r in
            let tid = r.tournamentID.lowercased()
            return (tid.contains("-atp-") || tid.contains("-wta-"))
                && r.userID == userID
                && !r.isBot
        }
        var addedCount = 0
        var coveredTids = Set<String>()
        for myRow in canonicalTennisRows where !existingTids.contains(myRow.tournamentID) {
            let tid = myRow.tournamentID
            coveredTids.insert(tid)
            let fieldRows = (try? await SupabaseService.shared.fetchTournamentResults(
                tournamentID: tid, accessToken: token
            )) ?? []
            // Bracket fields are 999 bots + user = 1000, but bot rows are
            // rarely in dfs_tournament_results — counting the fetched rows
            // gave "rank 99 of 1". Trust the count only when it's a real field.
            let totalEntries = fieldRows.count > 1 ? fieldRows.count : 1000
            let title: String = {
                if let t = tournament, t.id == tid { return t.title }
                return derivedTennisTitleFromTID(tid)
            }()
            saveTournamentResult(
                tournamentTitle: title,
                rank: myRow.rank,
                totalEntries: totalEntries,
                points: myRow.totalPoints,
                rrDelta: myRow.rrDelta,
                tournamentID: tid
            )
            addedCount += 1
            print("[TennisBracket] syncSettledHistory: added (canonical) \(tid) rank=\(myRow.rank)/\(totalEntries) pts=\(myRow.totalPoints) rrΔ=\(myRow.rrDelta)")
        }

        // PASS 2 — `tennis_bracket_entries` fallback. If `settle()` graded
        // the entries table but the `dfs_tournament_results` upsert was
        // skipped (e.g., the user's entry wasn't in fieldEntries when
        // settle() ran), the bracket leaderboard shows the user's rank
        // but Past Results is empty. Probe the recent slam tids directly,
        // derive rrDelta from the entries-table rank + field count.
        let currentYear = Calendar.current.component(.year, from: Date())
        var candidates: [String] = []
        for y in (currentYear - 1)...currentYear {
            for slam in GrandSlam.allCases {
                for draw in DrawType.allCases {
                    let tid = "\(slam.rawValue)-\(draw.rawValue)-\(y)"
                    candidates.append(tid)
                }
            }
        }
        for tid in candidates {
            if existingTids.contains(tid) || coveredTids.contains(tid) { continue }
            // Fetch the user's entry directly. If they didn't submit a
            // bracket for this slam, the response is nil and we move on
            // — cheap empty result, no need to check tournament status
            // first (the old `isSettled` gate was silently filtering out
            // brackets that were graded via `updateTennisBracketEntryScores`
            // but whose tournament row never flipped to status=settled,
            // which is exactly the gap that left Past Results empty).
            guard let userEntry = try? await SupabaseService.shared.fetchUserTennisBracketEntry(
                tournamentID: tid, userID: userID, accessToken: token
            ), let rank = userEntry.rank, let points = userEntry.totalPoints,
            rank > 0, points > 0 else {
                continue
            }
            // Only import COMPLETED brackets — the final (slot "F-1") must be
            // decided. A live slam (e.g. an in-progress Wimbledon) has a partial
            // rank/points, which would otherwise be written to history as a
            // finished "past result".
            let matchResults = (try? await SupabaseService.shared.fetchTennisBracketResults(
                tournamentID: tid, accessToken: token
            )) ?? [:]
            guard matchResults["F-1"] != nil else {
                print("[TennisBracket] syncSettledHistory: \(tid) final (F-1) not decided — in progress, skipping")
                continue
            }
            // Pull tournament metadata for the human-readable title; if
            // it's missing or untitled, fall back to the tid derivation.
            let tRec = try? await SupabaseService.shared.fetchTennisBracketTournament(
                tournamentID: tid, accessToken: token
            )
            let fieldRows = (try? await SupabaseService.shared.fetchTennisBracketEntries(
                tournamentID: tid, accessToken: token
            )) ?? []
            let totalEntries = max(fieldRows.count, 1)
            let rrDelta = TennisBracketEngine.rrDelta(forRank: rank, totalEntries: totalEntries)
            let title = (tRec?.title.isEmpty == false ? tRec!.title : derivedTennisTitleFromTID(tid))
            saveTournamentResult(
                tournamentTitle: title,
                rank: rank,
                totalEntries: totalEntries,
                points: points,
                rrDelta: rrDelta,
                tournamentID: tid
            )
            addedCount += 1
            print("[TennisBracket] syncSettledHistory: added (entries-fallback) \(tid) rank=\(rank)/\(totalEntries) pts=\(points) rrΔ=\(rrDelta)")
        }

        if addedCount > 0 {
            print("[TennisBracket] syncSettledHistory: imported \(addedCount) settled bracket(s) into local history")
        }
        // Do NOT mutate rrScore — server is authoritative.
    }

    /// Human-friendly title for a tennis tid like `french_open-atp-2026`
    /// when the in-memory tournament object isn't for that ID.
    private func derivedTennisTitleFromTID(_ tid: String) -> String {
        let parts = tid.split(separator: "-")
        guard parts.count >= 3 else { return "Tennis Bracket" }
        let slamRaw = String(parts.dropLast(2).joined(separator: "-"))
        let draw = String(parts[parts.count - 2]).uppercased()
        let year = String(parts.last ?? "")
        let slam = GrandSlam(rawValue: slamRaw)?.displayName ?? slamRaw.replacingOccurrences(of: "_", with: " ").capitalized
        return "\(year) \(slam) \(draw)"
    }

    // MARK: - Recheck Status

    func recheckStatusIfNeeded() async {
        guard let tournament, !tournament.isSettled else { return }
        guard tournament.status == "open" else { return }

        let lockTimePassed = (tournament.lockTime.map { Date() >= $0 }) ?? false

        // If our cached lockTime hasn't passed, poll ESPN for results — a non-empty response
        // proves the slam is underway despite a stale estimate.
        if !lockTimePassed, drawAvailable {
            let espnResults = await espnProvider.fetchMatchResults(
                drawType: tournament.drawType, drawPlayers: drawPlayers, grandSlam: tournament.grandSlam,
                notBefore: tournament.lockTime
            )
            if !espnResults.isEmpty {
                for (slot, winner) in espnResults { results[slot] = winner }
                if let token = accessToken {
                    try? await SupabaseService.shared.updateTennisBracketResults(
                        tournamentID: tournament.id, results: results, accessToken: token
                    )
                }
            }
        }

        await checkStatusTransition()
        if isLocked { await refreshLive() }
    }

    // MARK: - Groups

    func loadMyGroups() async {
        guard let token = accessToken, let uid = userID, let tournament else { return }
        do {
            let records = try await SupabaseService.shared.fetchMyTennisBracketGroups(
                userID: uid, tournamentID: tournament.id, accessToken: token
            )
            myGroups = records.map { $0.toModel() }
        } catch {
            print("[TennisBracket] Failed to load groups: \(error)")
        }
    }

    func createGroup(name: String) async -> TennisBracketGroup? {
        guard let token = accessToken, let uid = userID, let tournament else { return nil }
        isCreatingGroup = true
        groupError = nil
        do {
            let code = generateInviteCode()
            let record = try await SupabaseService.shared.createTennisBracketGroup(
                tournamentID: tournament.id, name: name, createdBy: uid,
                inviteCode: code, maxMembers: 20, accessToken: token
            )
            // Auto-join creator
            try await SupabaseService.shared.joinTennisBracketGroup(
                groupID: record.id, userID: uid,
                displayName: profileName.isEmpty ? "Player" : profileName,
                accessToken: token
            )
            let group = record.toModel()
            myGroups.append(group)
            isCreatingGroup = false
            return group
        } catch {
            groupError = "Failed to create group"
            isCreatingGroup = false
            return nil
        }
    }

    func joinGroupByCode(_ code: String) async -> Bool {
        guard let token = accessToken, let uid = userID else { return false }
        isJoiningGroup = true
        groupError = nil
        do {
            let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let record = try await SupabaseService.shared.fetchTennisBracketGroupByInviteCode(
                code: cleanCode, accessToken: token
            ) else {
                groupError = "No group found with that code"
                isJoiningGroup = false
                return false
            }
            let members = try await SupabaseService.shared.fetchTennisBracketGroupMembers(
                groupID: record.id, accessToken: token
            )
            if members.contains(where: { $0.userID == uid }) {
                groupError = "Already in this group"
                isJoiningGroup = false
                return false
            }
            if members.count >= record.maxMembers {
                groupError = "Group is full"
                isJoiningGroup = false
                return false
            }
            try await SupabaseService.shared.joinTennisBracketGroup(
                groupID: record.id, userID: uid,
                displayName: profileName.isEmpty ? "Player" : profileName,
                accessToken: token
            )
            let group = record.toModel()
            if !myGroups.contains(where: { $0.id == group.id }) {
                myGroups.append(group)
            }
            isJoiningGroup = false
            return true
        } catch {
            groupError = "Failed to join group"
            isJoiningGroup = false
            return false
        }
    }

    func loadGroupDetail(group: TennisBracketGroup) async {
        guard let token = accessToken else { return }
        // Reset standings when switching groups so stale data doesn't bleed in.
        if currentGroup?.id != group.id {
            currentGroupStandings = []
            currentGroupResults = [:]
        }
        currentGroup = group
        do {
            let members = try await SupabaseService.shared.fetchTennisBracketGroupMembers(
                groupID: group.id.uuidString, accessToken: token
            )
            currentGroupMembers = members.map { $0.toModel() }
        } catch {
            print("[TennisBracket] Failed to load group members: \(error)")
        }
        // Members are now loaded — fetch the group tournament's entries+results and
        // compute standings directly (independent of the currently-selected tournament).
        await loadGroupStandings(group: group)
    }

    func leaveGroup(_ group: TennisBracketGroup) async {
        guard let token = accessToken, let uid = userID else { return }
        do {
            try await SupabaseService.shared.leaveTennisBracketGroup(
                groupID: group.id.uuidString, userID: uid, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id { currentGroup = nil }
        } catch {
            print("[TennisBracket] Failed to leave group: \(error)")
        }
    }

    func deleteGroup(_ group: TennisBracketGroup) async {
        guard let token = accessToken else { return }
        do {
            try await SupabaseService.shared.deleteTennisBracketGroup(
                groupID: group.id.uuidString, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id { currentGroup = nil }
        } catch {
            print("[TennisBracket] Failed to delete group: \(error)")
        }
    }

    private func generateInviteCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}
