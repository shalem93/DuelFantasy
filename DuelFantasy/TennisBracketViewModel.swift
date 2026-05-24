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
    var isSubmitting: Bool = false
    var submitError: String?
    var drawAvailable: Bool = false

    // MARK: - Selection
    var selectedGrandSlam: GrandSlam = .frenchOpen
    var selectedDrawType: DrawType = .atp

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
    var groupError: String?
    var isCreatingGroup: Bool = false
    var isJoiningGroup: Bool = false

    // MARK: - Providers
    private let espnProvider = ESPNTennisResultsProvider()
    private var fieldGenerated = false
    private var lastRefreshDate: Date?

    // MARK: - Local Bot Cache
    private static let botCacheKey = "tennis_bracket_bot_cache"

    private func saveBotCacheLocally(_ botPicksData: [[String: Any]], tournamentID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: botPicksData) else { return }
        UserDefaults.standard.set(data, forKey: "\(Self.botCacheKey)_\(tournamentID)")
    }

    private func loadBotCacheLocally(tournamentID: String) -> [[String: Any]]? {
        guard let data = UserDefaults.standard.data(forKey: "\(Self.botCacheKey)_\(tournamentID)"),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return parsed
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
        guard hasLiveData, leaderboardEntries.count >= 10 else { return nil }
        return leaderboardEntries.first(where: { $0.isCurrentUser })?.rank
    }

    var userTotalPoints: Double? {
        guard hasLiveData else { return nil }
        return leaderboardEntries.first(where: { $0.isCurrentUser })?.totalPoints
    }

    var completedMatches: Int { results.count }

    var currentRound: String {
        var total = 0
        for (roundIndex, round) in TennisBracketEngine.rounds.enumerated() {
            let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
            var roundComplete = 0
            for matchNum in 1...matchCount {
                let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
                if results[slot] != nil { roundComplete += 1 }
            }
            total += roundComplete
            if roundComplete < matchCount {
                return round
            }
        }
        return "F"
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

    /// Group leaderboard: filter to group members, re-rank
    var groupLeaderboard: [TennisBracketLeaderboardEntry] {
        guard let group = currentGroup else { return [] }
        let memberIDs = Set(currentGroupMembers.map { $0.userID })
        let filtered = leaderboardEntries.filter { entry in
            if entry.isCurrentUser { return true }
            // Match by finding the field entry
            if let field = fieldEntries.first(where: { $0.id == entry.id }),
               let uid = field.userID, memberIDs.contains(uid) {
                return true
            }
            return false
        }
        return filtered.enumerated().map { index, entry in
            TennisBracketLeaderboardEntry(
                id: entry.id, entryName: entry.entryName, picks: entry.picks,
                totalPoints: entry.totalPoints, rank: index + 1,
                isCurrentUser: entry.isCurrentUser, roundBreakdown: entry.roundBreakdown
            )
        }
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
        case .frenchOpen:     (month, day) = (5, 25)   // Late May
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
        guard !isLoading else { return }
        isLoading = true
        error = nil
        drawAvailable = false

        // Reset per-tournament state so ATP picks don't bleed into WTA and vice versa
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

        let tournamentID = Self.currentTournamentID(grandSlam: selectedGrandSlam, drawType: selectedDrawType)

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
                if draw.count == 128 {
                    drawPlayers = draw
                    drawAvailable = true
                    print("[TennisBracket] Draw loaded from Supabase: \(draw.count) players")
                } else {
                    // Try hardcoded draw data first (reliable, no network dependency)
                    let year = Calendar.current.component(.year, from: Date())
                    if let hardcoded = TennisBracketDrawData.hardcodedDraw(
                        grandSlam: selectedGrandSlam, drawType: selectedDrawType, year: year
                    ), hardcoded.count == 128 {
                        drawPlayers = hardcoded
                        drawAvailable = true
                        print("[TennisBracket] Draw loaded from hardcoded data: \(hardcoded.count) players — saving to Supabase")
                        // Store to Supabase for future loads
                        try? await SupabaseService.shared.updateTennisBracketDrawData(
                            tournamentID: tournamentID, draw: hardcoded, accessToken: token
                        )
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
            }

            // If no server entry, try to restore from local progress
            if !hasSubmitted {
                loadPickProgress()
            }

            // Fetch stored results
            if let token = accessToken {
                let storedResults = (try? await SupabaseService.shared.fetchTennisBracketResults(
                    tournamentID: tournamentID, accessToken: token
                )) ?? [:]
                if !storedResults.isEmpty {
                    results = storedResults
                }
            }

            // Auto-detect status transitions
            await checkStatusTransition()

            // If locked/live, load field and scores
            if isLocked {
                await refreshLive()
            }

        } catch {
            // Ensure we always have a tournament object to prevent nil crashes
            if tournament == nil {
                tournament = fallbackTournament
            }
            print("[TennisBracket] Error loading: \(error)")
        }

        isLoading = false
        hasAttemptedLoad = true
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

        // open → locked: past lock time
        if t.status == "open", let lockTime = t.lockTime, Date() >= lockTime {
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

        // live → settled: Final match completed
        if t.status == "live" && results["F-1"] != nil {
            await settle()
        }
    }

    // MARK: - Refresh Live

    func refreshLive() async {
        guard let tournament, !tournament.isSettled else { return }

        // Fetch fresh ESPN results
        if drawAvailable {
            let espnResults = await espnProvider.fetchMatchResults(
                drawType: tournament.drawType,
                drawPlayers: drawPlayers
            )
            if !espnResults.isEmpty {
                // Merge with existing results
                for (slot, winner) in espnResults {
                    results[slot] = winner
                }
                // Save updated results to Supabase
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

        // Add user entry if submitted
        if hasSubmitted, let uid = userID {
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
            count: 999
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
        if hasSubmitted, let uid = userID {
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

    // MARK: - Recheck Status

    func recheckStatusIfNeeded() async {
        guard let tournament, !tournament.isSettled else { return }
        if tournament.status == "open", let lockTime = tournament.lockTime, Date() >= lockTime {
            await checkStatusTransition()
            if isLocked { await refreshLive() }
        }
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
        currentGroup = group
        do {
            let members = try await SupabaseService.shared.fetchTennisBracketGroupMembers(
                groupID: group.id.uuidString, accessToken: token
            )
            currentGroupMembers = members.map { $0.toModel() }
        } catch {
            print("[TennisBracket] Failed to load group members: \(error)")
        }
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
