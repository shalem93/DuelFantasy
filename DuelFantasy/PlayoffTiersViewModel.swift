import Foundation

@MainActor @Observable
final class PlayoffTiersViewModel {
    // MARK: - Tournament State
    var tournament: PlayoffTiersTournament?
    var tiers: [[PlayoffTiersPlayer]] = []  // 6 tiers of players
    var userPicks: [Int: PlayoffTiersPlayer] = [:]  // tier (1-6) → selected player
    var leaderboardEntries: [PlayoffTiersLeaderboardEntry] = []
    var livePlayerPoints: [String: Double] = [:]  // accumulated playoff FPTS per player

    // MARK: - Score cache (kills the 0.0 flash between sessions/visits)

    private var pointsCacheKey: String? {
        guard let tid = tournament?.id else { return nil }
        return "tiersPointsCache-\(tid)"
    }

    /// Load the last successfully fetched scores from disk when the in-memory
    /// dict is empty (cold launch / VM reset) so standings render with real
    /// numbers immediately instead of 0.0 until the next ESPN fetch lands.
    func hydratePointsCacheIfNeeded() {
        guard livePlayerPoints.isEmpty, let key = pointsCacheKey,
              let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode([String: Double].self, from: data),
              !cached.isEmpty else { return }
        livePlayerPoints = cached
        print("[PlayoffTiers] Hydrated \(cached.count) cached player scores")
    }

    func persistPointsCache() {
        guard let key = pointsCacheKey, !livePlayerPoints.isEmpty,
              let data = try? JSONEncoder().encode(livePlayerPoints) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    var fieldEntries: [PlayoffTiersEntry] = []
    var eliminatedTeams: Set<String> = []

    var isLoading: Bool = false
    var hasAttemptedLoad: Bool = false
    var error: String?
    var hasSubmitted: Bool = false
    var isSubmitting: Bool = false

    // MARK: - Persisted History (synced from ContentView)
    var dfsHistoryData: Data = Data()
    var settledTournamentData: Data = Data()

    // MARK: - Auth (synced from ContentView)
    var userID: String?
    var accessToken: String?
    var profileName: String = ""
    var rrScore: Int = 1000

    // MARK: - Groups State
    var myGroups: [PlayoffTiersGroup] = []
    var currentGroup: PlayoffTiersGroup?
    var currentGroupMembers: [PlayoffTiersGroupMember] = []
    var groupError: String?
    var isCreatingGroup: Bool = false
    var isJoiningGroup: Bool = false

    // MARK: - Providers
    private let espnProvider = ESPNPlayoffTiersDataProvider()
    private var fieldGenerated = false
    private var lastRefreshDate: Date?

    // MARK: - Local Bot Cache
    private static let botCacheKey = "playoff_tiers_bot_cache"

    private func saveBotCacheLocally(_ botPicksData: [[String: Any]], tournamentID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: botPicksData) else { return }
        UserDefaults.standard.set(data, forKey: "\(Self.botCacheKey)_\(tournamentID)")
    }

    private func loadBotCacheLocally(tournamentID: String) -> [[String: Any]]? {
        guard let data = UserDefaults.standard.data(forKey: "\(Self.botCacheKey)_\(tournamentID)"),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return parsed
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
        userPicks.count == 6
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

    /// Whether live scores have been fetched at least once this session.
    var hasLiveData: Bool { lastRefreshDate != nil }

    var userRank: Int? {
        // Don't report a rank when every entry is tied at 0 points — otherwise the user
        // sees a misleading "Rank #1" flash before live scoring populates.
        guard hasLiveData, leaderboardEntries.count >= 10,
              let entry = leaderboardEntries.first(where: { $0.isCurrentUser }),
              entry.totalPoints > 0 || leaderboardEntries.contains(where: { $0.totalPoints > 0 })
        else { return nil }
        return entry.rank
    }

    var userTotalPoints: Double? {
        guard hasLiveData,
              leaderboardEntries.contains(where: { $0.totalPoints > 0 })
        else { return nil }
        return leaderboardEntries.first(where: { $0.isCurrentUser })?.totalPoints
    }

    // MARK: - Load Tournament

    func loadTournament() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        do {
            // Fetch playoff players from ESPN
            let allPlayers = try await espnProvider.fetchPlayoffPlayers()
            guard !allPlayers.isEmpty else {
                error = "No playoff teams found. NBA playoffs may not have started yet."
                isLoading = false
                hasAttemptedLoad = true
                return
            }

            // Generate tiers
            tiers = PlayoffTiersEngine.generateTiers(from: allPlayers)
            print("[PlayoffTiers] Generated tiers: \(tiers.map { $0.count })")

            // Build tournament
            let tournamentID = PlayoffTiersTournament.currentSeasonID()
            let lockTime = await espnProvider.fetchPlayoffLockTime()

            // Try to load existing tournament from Supabase
            var loadedTournament: PlayoffTiersTournament?
            if let token = accessToken {
                if let record = try? await SupabaseService.shared.fetchPlayoffTiersTournament(
                    tournamentID: tournamentID, accessToken: token
                ) {
                    loadedTournament = PlayoffTiersTournament(
                        id: record.id,
                        title: record.title,
                        season: record.season,
                        status: record.status,
                        lockTime: record.lockTime,
                        entryCount: record.entryCount ?? 1000,
                        playoffRound: record.playoffRound ?? "full",
                        isSettled: record.isSettled ?? false,
                        createdAt: record.createdAt ?? Date()
                    )
                }
            }

            if var existing = loadedTournament {
                // Only reset "locked" to "open" if we have a concrete lock time that's
                // still in the future. If lockTime is nil (API couldn't find playoff games),
                // trust the server status — resetting to "open" would break an already-locked tournament.
                if existing.status == "locked" && !existing.isSettled {
                    if let lt = lockTime, Date() < lt {
                        print("[PlayoffTiers] Resetting 'locked' to 'open' — lock time \(lt) is still in the future")
                        existing = PlayoffTiersTournament(
                            id: existing.id, title: existing.title, season: existing.season,
                            status: "open", lockTime: lockTime, entryCount: existing.entryCount,
                            playoffRound: existing.playoffRound, isSettled: false, createdAt: existing.createdAt
                        )
                        if let token = accessToken {
                            try? await SupabaseService.shared.updatePlayoffTiersTournamentStatus(
                                tournamentID: existing.id, status: "open", accessToken: token
                            )
                        }
                    }
                }
                // Update lockTime if we got a fresh one from ESPN
                if let lt = lockTime, lt != existing.lockTime {
                    existing = PlayoffTiersTournament(
                        id: existing.id, title: existing.title, season: existing.season,
                        status: existing.status, lockTime: lt, entryCount: existing.entryCount,
                        playoffRound: existing.playoffRound, isSettled: existing.isSettled, createdAt: existing.createdAt
                    )
                }
                tournament = existing
            } else {
                // Create new tournament
                let newTournament = PlayoffTiersTournament(
                    id: tournamentID,
                    title: PlayoffTiersTournament.currentSeasonTitle(),
                    season: PlayoffTiersTournament.currentSeason(),
                    status: "open",
                    lockTime: lockTime,
                    entryCount: 1000,
                    playoffRound: "full",
                    isSettled: false,
                    createdAt: Date()
                )
                tournament = newTournament

                // Save to Supabase
                if let token = accessToken {
                    let record = PlayoffTiersTournamentRecord(
                        id: newTournament.id,
                        title: newTournament.title,
                        season: newTournament.season,
                        status: newTournament.status,
                        lockTime: newTournament.lockTime,
                        entryCount: newTournament.entryCount,
                        playoffRound: newTournament.playoffRound
                    )
                    try? await SupabaseService.shared.upsertPlayoffTiersTournament(
                        record: record, accessToken: token
                    )
                }
            }

            // Check if user already has an entry
            if let token = accessToken, let uid = userID {
                if let existingEntry = try? await SupabaseService.shared.fetchUserPlayoffTiersEntry(
                    tournamentID: tournamentID, userID: uid, accessToken: token
                ) {
                    hasSubmitted = true
                    // Restore picks
                    for pickData in existingEntry.picks {
                        let pick = pickData.toModel()
                        // Find matching player in tiers
                        for tier in tiers {
                            if let player = tier.first(where: { $0.id == pick.playerID }) {
                                userPicks[pick.tier] = player
                                break
                            }
                        }
                    }
                }
            }

            // Auto-detect status transitions
            await checkStatusTransition()

            // If locked/live, load field and scores
            if isLocked {
                await refreshLive()
            }

        } catch {
            self.error = "Failed to load tournament: \(error.localizedDescription)"
            print("[PlayoffTiers] Error loading: \(error)")
        }

        isLoading = false
        hasAttemptedLoad = true
    }

    /// Re-fetch the user's submitted entry from Supabase if `userPicks` is
    /// empty but auth is now available. Mirrors the SoccerTiers fix — the
    /// FantasyHubView launch task often fires `loadTournament` before auth
    /// has propagated to this VM, the entry-fetch inside `loadTournament`
    /// gets silently skipped, and `hasAttemptedLoad` is then force-set so
    /// no retry ever runs. Call from the lobby's `.task` after auth has
    /// had time to settle. Wrapped in `isLoading` so the lobby shows a
    /// spinner instead of empty content while the fetch is in flight.
    func restoreUserPicksIfMissing() async {
        guard userPicks.isEmpty, !hasSubmitted else { return }
        guard let token = accessToken, let uid = userID else { return }
        let tournamentID = tournament?.id ?? PlayoffTiersTournament.currentSeasonID()
        isLoading = true
        defer { isLoading = false }
        guard let record = try? await SupabaseService.shared.fetchUserPlayoffTiersEntry(
            tournamentID: tournamentID, userID: uid, accessToken: token
        ) else { return }
        hasSubmitted = true
        for pickData in record.picks {
            let pick = pickData.toModel()
            var foundPlayer: PlayoffTiersPlayer?
            for tier in tiers {
                if let player = tier.first(where: { $0.id == pick.playerID }) {
                    foundPlayer = player
                    break
                }
            }
            if let player = foundPlayer {
                userPicks[pick.tier] = player
            }
        }
        print("[PlayoffTiers] Restored \(userPicks.count) picks via late-bind fetch")
    }

    // MARK: - Pick Management

    func selectPlayer(tier: Int, player: PlayoffTiersPlayer) {
        guard !isLocked else { return }
        userPicks[tier] = player
    }

    func removePlayer(tier: Int) {
        guard !isLocked else { return }
        userPicks.removeValue(forKey: tier)
    }

    // MARK: - Submit Picks

    func submitPicks() async {
        guard allPicksMade else { return }
        guard let token = accessToken, let uid = userID else {
            error = "Please sign in to submit picks."
            return
        }
        guard !isLocked else {
            error = "Tournament is locked. Picks can no longer be changed."
            return
        }

        isSubmitting = true

        let picks = (1...6).compactMap { tier -> PlayoffTiersPickData? in
            guard let player = userPicks[tier] else { return nil }
            return PlayoffTiersPickData(
                tier: tier,
                playerID: player.id,
                playerName: player.name,
                playerTeam: player.team
            )
        }

        guard picks.count == 6 else {
            error = "Please select a player from each tier."
            isSubmitting = false
            return
        }

        do {
            let entryName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.submitPlayoffTiersEntry(
                tournamentID: tournament?.id ?? PlayoffTiersTournament.currentSeasonID(),
                userID: uid,
                entryName: entryName,
                picks: picks,
                accessToken: token
            )
            hasSubmitted = true
            print("[PlayoffTiers] Picks submitted successfully")
        } catch {
            self.error = "Failed to submit picks: \(error.localizedDescription)"
            print("[PlayoffTiers] Submit error: \(error)")
        }

        isSubmitting = false
    }

    // MARK: - Live Refresh

    func refreshLive() async {
        guard let tournament else { return }

        // Load field entries if not yet loaded.
        // Check !fieldGenerated (not fieldEntries.isEmpty) because fieldEntries
        // may already contain just the user's own entry from the picks restoration
        // path below, but the bot field hasn't been loaded yet.
        if !fieldGenerated {
            await loadFieldEntries()
        }

        // If user picks weren't restored yet, try multiple sources:
        // 1. From fieldEntries (already loaded)
        // 2. Direct fetch from entries table
        if userPicks.isEmpty {
            // Try from fieldEntries first
            if let userFieldEntry = fieldEntries.first(where: { $0.isCurrentUser }) {
                for pick in userFieldEntry.picks {
                    for tier in tiers {
                        if let player = tier.first(where: { $0.id == pick.playerID }) {
                            userPicks[pick.tier] = player
                            break
                        }
                    }
                    if userPicks[pick.tier] == nil {
                        userPicks[pick.tier] = PlayoffTiersPlayer(
                            id: pick.playerID, name: pick.playerName, team: pick.playerTeam,
                            position: "", tier: pick.tier, projectedPoints: 0,
                            gamesPlayed: 0, totalFantasyPoints: 0, perGameAvg: 0,
                            imageURL: nil, isEliminated: false
                        )
                    }
                }
                hasSubmitted = true
            }
            // If still empty, fetch directly from entries table
            if userPicks.isEmpty, let uid = userID, let token = accessToken {
                if let record = try? await SupabaseService.shared.fetchUserPlayoffTiersEntry(
                    tournamentID: tournament.id, userID: uid, accessToken: token
                ) {
                    hasSubmitted = true
                    for pickData in record.picks {
                        let pick = pickData.toModel()
                        for tier in tiers {
                            if let player = tier.first(where: { $0.id == pick.playerID }) {
                                userPicks[pick.tier] = player
                                break
                            }
                        }
                        if userPicks[pick.tier] == nil {
                            userPicks[pick.tier] = PlayoffTiersPlayer(
                                id: pick.playerID, name: pick.playerName, team: pick.playerTeam,
                                position: "", tier: pick.tier, projectedPoints: 0,
                                gamesPlayed: 0, totalFantasyPoints: 0, perGameAvg: 0,
                                imageURL: nil, isEliminated: false
                            )
                        }
                    }
                    // Also ensure user is in fieldEntries
                    if !fieldEntries.contains(where: { $0.isCurrentUser }) {
                        let userEntry = PlayoffTiersEntry(
                            id: UUID(uuidString: record.id) ?? UUID(),
                            tournamentID: record.tournamentID,
                            userID: record.userID,
                            entryName: record.entryName,
                            picks: record.picks.map { $0.toModel() },
                            totalPoints: record.totalPoints,
                            rank: record.rank,
                            isBot: false,
                            isCurrentUser: true
                        )
                        fieldEntries.insert(userEntry, at: 0)
                    }
                }
            }
        }

        // Collect all player IDs from field entries + user picks
        var allPlayerIDs = Set<String>()
        for entry in fieldEntries {
            for pick in entry.picks {
                allPlayerIDs.insert(pick.playerID)
            }
        }
        for (_, player) in userPicks {
            allPlayerIDs.insert(player.id)
        }

        guard !allPlayerIDs.isEmpty else { return }

        // Show last-known scores instantly while the (slow, multi-boxscore)
        // ESPN fetch runs — otherwise every cold open flashes 0.0 for every
        // player until the fetch completes.
        hydratePointsCacheIfNeeded()
        if leaderboardEntries.isEmpty && !livePlayerPoints.isEmpty && !fieldEntries.isEmpty {
            leaderboardEntries = PlayoffTiersEngine.computeLeaderboard(
                entries: fieldEntries,
                playerPoints: livePlayerPoints,
                currentUserID: userID
            )
        }

        // Fetch accumulated playoff scores. NEVER overwrite good scores with
        // an empty result — a failed/204 ESPN fetch was zeroing the whole
        // standings while the screen sat open.
        let scores = await espnProvider.fetchPlayoffScores(playerIDs: allPlayerIDs)
        if !scores.isEmpty {
            livePlayerPoints = scores
            persistPointsCache()
        } else if !livePlayerPoints.isEmpty {
            print("[PlayoffTiers] Score fetch returned empty — keeping \(livePlayerPoints.count) existing scores")
        }

        // Fetch eliminated teams
        eliminatedTeams = await espnProvider.fetchEliminatedTeams()

        // Update tier player data with elimination status
        for tierIndex in 0..<tiers.count {
            for playerIndex in 0..<tiers[tierIndex].count {
                let player = tiers[tierIndex][playerIndex]
                tiers[tierIndex][playerIndex].isEliminated = eliminatedTeams.contains(player.team)
                tiers[tierIndex][playerIndex].totalFantasyPoints = livePlayerPoints[player.id] ?? 0
            }
        }

        // Compute leaderboard
        leaderboardEntries = PlayoffTiersEngine.computeLeaderboard(
            entries: fieldEntries,
            playerPoints: livePlayerPoints,
            currentUserID: userID
        )

        // Check if playoffs are complete → settle
        if tournament.status == "live" {
            let complete = await espnProvider.checkPlayoffsComplete()
            if complete {
                await settle()
            }
        }

        lastRefreshDate = Date()
    }

    // MARK: - Load Field Entries

    private func loadFieldEntries() async {
        guard let tournament else { return }
        let token = accessToken  // May be nil — Supabase paths are conditional

        // Try loading from entries table first — but only trust it if it has a
        // substantial field (500+). A small count means the old per-bot submission
        // was interrupted and left partial data.
        if let token,
           let records = try? await SupabaseService.shared.fetchPlayoffTiersEntries(
            tournamentID: tournament.id, accessToken: token
        ), records.count >= 500 {
            fieldEntries = records.map { record in
                PlayoffTiersEntry(
                    id: UUID(uuidString: record.id) ?? UUID(),
                    tournamentID: record.tournamentID,
                    userID: record.userID,
                    entryName: record.entryName,
                    picks: record.picks.map { $0.toModel() },
                    totalPoints: record.totalPoints,
                    rank: record.rank,
                    isBot: record.isBot,
                    isCurrentUser: record.userID == userID
                )
            }
            fieldGenerated = true
            print("[PlayoffTiers] Loaded \(fieldEntries.count) entries from entries table")
            return
        }

        // Try restoring bots from the tournament's bot_field JSON (fast, no 999 individual fetches)
        if let token {
            do {
                let botField = try await SupabaseService.shared.fetchPlayoffTiersBotField(
                    tournamentID: tournament.id, accessToken: token
                )
                print("[PlayoffTiers] bot_field fetch returned \(botField.count) entries")
                if !botField.isEmpty {
                    let restoredEntries = parseBotFieldData(botField, tournamentID: tournament.id)
                    if !restoredEntries.isEmpty {
                        await attachUserEntryAndFinalize(restoredEntries: restoredEntries, tournamentID: tournament.id, token: token)
                        if fieldGenerated {
                            // Backfill entries table in background so next launch loads from primary tier
                            Task { await backfillEntriesToServer(bots: restoredEntries, tournamentID: tournament.id, token: token) }
                            return
                        }
                    }
                }
            } catch {
                print("[PlayoffTiers] bot_field fetch failed: \(error)")
            }
        }

        // Try local cache before generating fresh bots
        if !fieldGenerated {
            if let cachedBots = loadBotCacheLocally(tournamentID: tournament.id), !cachedBots.isEmpty {
                print("[PlayoffTiers] Restoring \(cachedBots.count) bots from local cache")
                let restoredEntries = parseBotFieldData(cachedBots, tournamentID: tournament.id)
                if !restoredEntries.isEmpty {
                    await attachUserEntryAndFinalize(restoredEntries: restoredEntries, tournamentID: tournament.id, token: token)
                    if fieldGenerated {
                        // Backfill to server if authenticated
                        if let token {
                            Task { await backfillEntriesToServer(bots: restoredEntries, tournamentID: tournament.id, token: token) }
                        }
                        return
                    }
                }
            }
        }

        // Last resort: generate fresh bots (works without auth)
        if !fieldGenerated {
            await generateBotField()
        }
    }

    /// Parse bot field JSON data (from Supabase bot_field column or local cache) into entries.
    private func parseBotFieldData(_ botField: [[String: Any]], tournamentID: String) -> [PlayoffTiersEntry] {
        var restoredEntries: [PlayoffTiersEntry] = []
        var parseFailures = 0
        for botData in botField {
            guard let name = botData["name"] as? String,
                  let picksRaw = botData["picks"] as? [[String: Any]] else {
                parseFailures += 1
                continue
            }
            let picks = picksRaw.compactMap { p -> PlayoffTiersPick? in
                let tier: Int
                if let t = p["tier"] as? Int {
                    tier = t
                } else if let t = p["tier"] as? Double {
                    tier = Int(t)
                } else { return nil }
                guard let playerID = p["player_id"] as? String,
                      let playerName = p["player_name"] as? String,
                      let playerTeam = p["player_team"] as? String else { return nil }
                return PlayoffTiersPick(tier: tier, playerID: playerID, playerName: playerName, playerTeam: playerTeam)
            }
            guard picks.count == 6 else {
                parseFailures += 1
                continue
            }
            restoredEntries.append(PlayoffTiersEntry(
                id: UUID(), tournamentID: tournamentID, userID: nil,
                entryName: name, picks: picks, totalPoints: 0, rank: 0,
                isBot: true, isCurrentUser: false
            ))
        }
        if parseFailures > 0 {
            print("[PlayoffTiers] ⚠️ \(parseFailures) bots failed to parse from bot field data")
        }
        return restoredEntries
    }

    /// Attach the user's entry to restored bot entries and finalize the field.
    private func attachUserEntryAndFinalize(restoredEntries: [PlayoffTiersEntry], tournamentID: String, token: String?) async {
        var userEntry: PlayoffTiersEntry?
        if let uid = userID {
            // First try: build from userPicks (already restored from Supabase)
            if hasSubmitted && userPicks.count == 6 {
                userEntry = PlayoffTiersEntry(
                    id: UUID(), tournamentID: tournamentID, userID: uid,
                    entryName: profileName.isEmpty ? "Player" : profileName,
                    picks: (1...6).compactMap { tier -> PlayoffTiersPick? in
                        guard let player = userPicks[tier] else { return nil }
                        return PlayoffTiersPick(tier: tier, playerID: player.id, playerName: player.name, playerTeam: player.team)
                    },
                    totalPoints: 0, rank: 0, isBot: false, isCurrentUser: true
                )
            }
            // Second try: fetch directly from entries table (requires auth)
            if userEntry == nil, let token {
                if let record = try? await SupabaseService.shared.fetchUserPlayoffTiersEntry(
                    tournamentID: tournamentID, userID: uid, accessToken: token
                ) {
                    hasSubmitted = true
                    userEntry = PlayoffTiersEntry(
                        id: UUID(uuidString: record.id) ?? UUID(),
                        tournamentID: record.tournamentID,
                        userID: record.userID,
                        entryName: record.entryName,
                        picks: record.picks.map { $0.toModel() },
                        totalPoints: record.totalPoints,
                        rank: record.rank,
                        isBot: false,
                        isCurrentUser: true
                    )
                    // Also restore userPicks from this entry
                    for pickData in record.picks {
                        let pick = pickData.toModel()
                        for tier in tiers {
                            if let player = tier.first(where: { $0.id == pick.playerID }) {
                                userPicks[pick.tier] = player
                                break
                            }
                        }
                        if userPicks[pick.tier] == nil {
                            userPicks[pick.tier] = PlayoffTiersPlayer(
                                id: pick.playerID, name: pick.playerName, team: pick.playerTeam,
                                position: "", tier: pick.tier, projectedPoints: 0,
                                gamesPlayed: 0, totalFantasyPoints: 0, perGameAvg: 0,
                                imageURL: nil, isEliminated: false
                            )
                        }
                    }
                }
            }
        }
        if let userEntry {
            fieldEntries = [userEntry] + restoredEntries
        } else {
            fieldEntries = restoredEntries
        }
        fieldGenerated = true
        print("[PlayoffTiers] Restored \(restoredEntries.count) bots from field data")
    }

    /// Backfill the entries table (primary persistence) from a fallback-restored bot list.
    /// Runs in the background so the UI isn't blocked.
    private func backfillEntriesToServer(bots: [PlayoffTiersEntry], tournamentID: String, token: String) async {
        let botPayloads: [(name: String, picks: [PlayoffTiersPickData])] = bots.map { entry in
            (name: entry.entryName, picks: entry.picks.map { PlayoffTiersPickData(from: $0) })
        }
        do {
            // Check if entries table already has enough bots (another client may have saved first)
            let existing = try? await SupabaseService.shared.fetchPlayoffTiersEntries(
                tournamentID: tournamentID, accessToken: token
            )
            if (existing?.count ?? 0) >= 500 {
                print("[PlayoffTiers] Entries table already has \(existing?.count ?? 0) entries, skipping backfill")
                return
            }
            try await SupabaseService.shared.deletePlayoffTiersBotEntries(
                tournamentID: tournamentID, accessToken: token
            )
            try await SupabaseService.shared.batchInsertPlayoffTiersBotEntries(
                tournamentID: tournamentID, bots: botPayloads, accessToken: token
            )
            print("[PlayoffTiers] Backfilled \(bots.count) bots to entries table")
        } catch {
            print("[PlayoffTiers] ⚠️ Backfill to entries table failed: \(error)")
        }
    }

    // MARK: - Generate Bot Field

    private func generateBotField() async {
        guard let tournament else {
            print("[PlayoffTiers] generateBotField: no tournament")
            return
        }
        guard !tiers.isEmpty && tiers.allSatisfy({ !$0.isEmpty }) else {
            print("[PlayoffTiers] generateBotField: invalid tier data")
            return
        }
        // Don't regenerate if we already have bot entries
        guard fieldEntries.filter({ $0.isBot }).isEmpty else {
            print("[PlayoffTiers] Skipping generateBotField — already have \(fieldEntries.filter({ $0.isBot }).count) bots")
            fieldGenerated = true
            return
        }

        print("[PlayoffTiers] Generating bot field...")
        var botEntries = PlayoffTiersBotDrafter.generateBotEntries(tiers: tiers, count: 999, tournamentID: tournament.id)

        // Set tournament ID
        botEntries = botEntries.map { entry in
            PlayoffTiersEntry(
                id: entry.id,
                tournamentID: tournament.id,
                userID: nil,
                entryName: entry.entryName,
                picks: entry.picks,
                totalPoints: 0,
                rank: 0,
                isBot: true,
                isCurrentUser: false
            )
        }

        // Add user entry if authenticated
        if let token = accessToken {
            let userEntry = await buildUserEntry(tournamentID: tournament.id, token: token)
            if let userEntry {
                fieldEntries = [userEntry] + botEntries
            } else {
                fieldEntries = botEntries
            }
        } else {
            fieldEntries = botEntries
        }

        fieldGenerated = true

        // Save bot data to local cache (always works, no auth needed)
        let botPicksData: [[String: Any]] = botEntries.map { entry in
            [
                "name": entry.entryName,
                "picks": entry.picks.map { pick in
                    ["tier": pick.tier, "player_id": pick.playerID,
                     "player_name": pick.playerName, "player_team": pick.playerTeam]
                }
            ] as [String: Any]
        }
        saveBotCacheLocally(botPicksData, tournamentID: tournament.id)

        // Save to Supabase only if authenticated
        guard let token = accessToken else {
            print("[PlayoffTiers] No auth — saved bots to local cache only")
            return
        }

        // Save bot entries to the entries table (primary persistence).
        let botPayloads: [(name: String, picks: [PlayoffTiersPickData])] = botEntries.map { entry in
            (name: entry.entryName, picks: entry.picks.map { PlayoffTiersPickData(from: $0) })
        }
        do {
            try await SupabaseService.shared.deletePlayoffTiersBotEntries(
                tournamentID: tournament.id, accessToken: token
            )
            try await SupabaseService.shared.batchInsertPlayoffTiersBotEntries(
                tournamentID: tournament.id, bots: botPayloads, accessToken: token
            )
            print("[PlayoffTiers] Saved \(botEntries.count) bots to entries table")
        } catch {
            print("[PlayoffTiers] ⚠️ Failed to save bots to entries table: \(error)")
        }

        // Also save to bot_field column as fallback
        do {
            try await SupabaseService.shared.savePlayoffTiersBotField(
                tournamentID: tournament.id, botField: botPicksData, accessToken: token
            )
        } catch {
            print("[PlayoffTiers] ⚠️ Failed to save bot_field fallback: \(error)")
        }
    }

    /// Build a user entry for the field — tries local userPicks first, then Supabase.
    private func buildUserEntry(tournamentID: String, token: String) async -> PlayoffTiersEntry? {
        guard let uid = userID else { return nil }

        if hasSubmitted && userPicks.count == 6 {
            return PlayoffTiersEntry(
                id: UUID(), tournamentID: tournamentID, userID: uid,
                entryName: profileName.isEmpty ? "Player" : profileName,
                picks: (1...6).compactMap { tier -> PlayoffTiersPick? in
                    guard let player = userPicks[tier] else { return nil }
                    return PlayoffTiersPick(tier: tier, playerID: player.id, playerName: player.name, playerTeam: player.team)
                },
                totalPoints: 0, rank: 0, isBot: false, isCurrentUser: true
            )
        }

        if let record = try? await SupabaseService.shared.fetchUserPlayoffTiersEntry(
            tournamentID: tournamentID, userID: uid, accessToken: token
        ) {
            hasSubmitted = true
            // Restore userPicks
            for pickData in record.picks {
                let pick = pickData.toModel()
                for tier in tiers {
                    if let player = tier.first(where: { $0.id == pick.playerID }) {
                        userPicks[pick.tier] = player
                        break
                    }
                }
                if userPicks[pick.tier] == nil {
                    userPicks[pick.tier] = PlayoffTiersPlayer(
                        id: pick.playerID, name: pick.playerName, team: pick.playerTeam,
                        position: "", tier: pick.tier, projectedPoints: 0,
                        gamesPlayed: 0, totalFantasyPoints: 0, perGameAvg: 0,
                        imageURL: nil, isEliminated: false
                    )
                }
            }
            return PlayoffTiersEntry(
                id: UUID(uuidString: record.id) ?? UUID(),
                tournamentID: record.tournamentID, userID: record.userID,
                entryName: record.entryName,
                picks: record.picks.map { $0.toModel() },
                totalPoints: record.totalPoints, rank: record.rank,
                isBot: false, isCurrentUser: true
            )
        }

        return nil
    }

    /// Public re-check for when the LobbyView appears after `loadTournament` already ran.
    /// Ensures lock → live transitions fire even if the original load happened before lock time.
    func recheckStatusIfNeeded() async {
        guard tournament != nil else { return }
        // If the tournament still looks "open" but lock time has passed, update lockTime from ESPN
        if tournament?.status == "open" {
            let lockTime = await espnProvider.fetchPlayoffLockTime()
            if let lt = lockTime, lt != tournament?.lockTime {
                tournament = PlayoffTiersTournament(
                    id: tournament!.id, title: tournament!.title, season: tournament!.season,
                    status: tournament!.status, lockTime: lt, entryCount: tournament!.entryCount,
                    playoffRound: tournament!.playoffRound, isSettled: tournament!.isSettled, createdAt: tournament!.createdAt
                )
            }
        }
        await checkStatusTransition()
        // If now locked/live, load the field
        if isLocked && !fieldGenerated {
            await refreshLive()
        }
    }

    // MARK: - Status Transitions

    private func checkStatusTransition() async {
        guard let tournament else { return }

        // Check if we should transition from open → locked
        if tournament.status == "open", let lockTime = tournament.lockTime, Date() >= lockTime {
            self.tournament = PlayoffTiersTournament(
                id: tournament.id, title: tournament.title, season: tournament.season,
                status: "locked", lockTime: tournament.lockTime, entryCount: tournament.entryCount,
                playoffRound: tournament.playoffRound, isSettled: false, createdAt: tournament.createdAt
            )
            if let token = accessToken {
                try? await SupabaseService.shared.updatePlayoffTiersTournamentStatus(
                    tournamentID: tournament.id, status: "locked", accessToken: token
                )
            }
        }

        // Check if we should transition from locked → live (games started/in progress)
        if self.tournament?.status == "locked" {
            let hasGamesStarted = await espnProvider.hasPlayoffGamesStarted()
            if hasGamesStarted {
                self.tournament = PlayoffTiersTournament(
                    id: tournament.id, title: tournament.title, season: tournament.season,
                    status: "live", lockTime: tournament.lockTime, entryCount: tournament.entryCount,
                    playoffRound: tournament.playoffRound, isSettled: false, createdAt: tournament.createdAt
                )
                if let token = accessToken {
                    try? await SupabaseService.shared.updatePlayoffTiersTournamentStatus(
                        tournamentID: tournament.id, status: "live", accessToken: token
                    )
                }
            }
        }
    }

    // MARK: - Settlement

    private func settle() async {
        guard let tournament, !tournament.isSettled else { return }
        guard let token = accessToken else { return }

        print("[PlayoffTiers] Settling tournament \(tournament.id)")

        // Compute final leaderboard
        let finalLeaderboard = PlayoffTiersEngine.computeLeaderboard(
            entries: fieldEntries,
            playerPoints: livePlayerPoints,
            currentUserID: userID
        )
        leaderboardEntries = finalLeaderboard

        // Calculate RR delta for user
        if let userEntry = finalLeaderboard.first(where: { $0.isCurrentUser }) {
            let rrDelta = PlayoffTiersEngine.rrDelta(forRank: userEntry.rank, totalEntries: finalLeaderboard.count)
            rrScore += rrDelta

            // Save to DFS history
            let result = DFSResult(
                id: UUID(),
                tournamentTitle: tournament.title,
                rank: userEntry.rank,
                totalEntries: finalLeaderboard.count,
                lineupPoints: userEntry.totalPoints,
                rrDelta: rrDelta,
                loggedAt: Date(),
                tournamentId: tournament.id
            )
            appendToHistory(result)
            markTournamentSettled(tournament.id)

            // Also save to Supabase dfs_tournament_results so it appears on the profile
            if let uid = userID {
                let tournamentRecord = DFSTournamentRecord(
                    id: tournament.id,
                    title: tournament.title,
                    league: "playoff-tiers",
                    lockTime: tournament.lockTime ?? Date(),
                    isSettled: true,
                    totalEntries: finalLeaderboard.count,
                    playerSalaries: nil,
                    botField: nil
                )
                try? await SupabaseService.shared.upsertTournament(
                    record: tournamentRecord, accessToken: token
                )

                let playerNames = userEntry.picks.map { $0.playerName }
                let playerIDs = userEntry.picks.map { $0.playerID }
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

        // Update tournament status
        self.tournament = PlayoffTiersTournament(
            id: tournament.id, title: tournament.title, season: tournament.season,
            status: "settled", lockTime: tournament.lockTime, entryCount: tournament.entryCount,
            playoffRound: tournament.playoffRound, isSettled: true, createdAt: tournament.createdAt
        )

        try? await SupabaseService.shared.markPlayoffTiersTournamentSettled(
            tournamentID: tournament.id, accessToken: token
        )

        // Update entry scores on server
        let updates = finalLeaderboard.map { entry in
            (id: entry.id.uuidString, totalPoints: entry.totalPoints, rank: entry.rank)
        }
        try? await SupabaseService.shared.updatePlayoffTiersEntryScores(
            entries: updates, accessToken: token
        )
    }

    // MARK: - History Helpers

    private func appendToHistory(_ result: DFSResult) {
        var history = (try? JSONDecoder().decode([DFSResult].self, from: dfsHistoryData)) ?? []
        history.insert(result, at: 0)
        if let data = try? JSONEncoder().encode(history) {
            dfsHistoryData = data
        }
    }

    private func markTournamentSettled(_ tournamentID: String) {
        var settled = (try? JSONDecoder().decode(Set<String>.self, from: settledTournamentData)) ?? []
        settled.insert(tournamentID)
        if let data = try? JSONEncoder().encode(settled) {
            settledTournamentData = data
        }
    }

    private func isTournamentSettled(_ tournamentID: String) -> Bool {
        let settled = (try? JSONDecoder().decode(Set<String>.self, from: settledTournamentData)) ?? []
        return settled.contains(tournamentID)
    }

    // MARK: - Groups

    /// Leaderboard filtered to only members of the current group
    var groupLeaderboard: [PlayoffTiersLeaderboardEntry] {
        guard !currentGroupMembers.isEmpty else { return [] }
        let memberUserIDs = Set(currentGroupMembers.map { $0.userID })
        let filtered = leaderboardEntries.filter { entry in
            // Match by checking if the entry's underlying userID is in the group
            if entry.isCurrentUser, let uid = userID {
                return memberUserIDs.contains(uid)
            }
            // For field entries, find the matching entry by ID
            if let fieldEntry = fieldEntries.first(where: { $0.id == entry.id }) {
                if let entryUserID = fieldEntry.userID {
                    return memberUserIDs.contains(entryUserID)
                }
            }
            return false
        }
        // Re-rank within the group
        return filtered.enumerated().map { index, entry in
            PlayoffTiersLeaderboardEntry(
                id: entry.id,
                entryName: entry.entryName,
                picks: entry.picks,
                totalPoints: entry.totalPoints,
                rank: index + 1,
                isCurrentUser: entry.isCurrentUser,
                playerPoints: entry.playerPoints
            )
        }
    }

    func loadMyGroups() async {
        guard let token = accessToken, let uid = userID else { return }
        let tournamentID = tournament?.id ?? PlayoffTiersTournament.currentSeasonID()

        do {
            let records = try await SupabaseService.shared.fetchMyPlayoffTiersGroups(
                userID: uid, tournamentID: tournamentID, accessToken: token
            )
            myGroups = records.map { $0.toModel() }
        } catch {
            print("[PlayoffTiers] Failed to load groups: \(error)")
        }
    }

    func createGroup(name: String) async -> PlayoffTiersGroup? {
        guard let token = accessToken, let uid = userID else {
            groupError = "Please sign in to create a group."
            return nil
        }
        let tournamentID = tournament?.id ?? PlayoffTiersTournament.currentSeasonID()
        isCreatingGroup = true
        groupError = nil

        do {
            // Generate a short invite code
            let code = generateInviteCode()
            let record = try await SupabaseService.shared.createPlayoffTiersGroup(
                tournamentID: tournamentID,
                name: name,
                createdBy: uid,
                inviteCode: code,
                maxMembers: 20,
                accessToken: token
            )
            let group = record.toModel()

            // Auto-join the creator
            let displayName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.joinPlayoffTiersGroup(
                groupID: record.id, userID: uid, displayName: displayName, accessToken: token
            )

            myGroups.insert(group, at: 0)
            isCreatingGroup = false
            return group
        } catch {
            groupError = "Failed to create group: \(error.localizedDescription)"
            print("[PlayoffTiers] Create group error: \(error)")
            isCreatingGroup = false
            return nil
        }
    }

    func joinGroupByCode(_ code: String) async -> Bool {
        guard let token = accessToken, let uid = userID else {
            groupError = "Please sign in to join a group."
            return false
        }
        isJoiningGroup = true
        groupError = nil

        do {
            guard let record = try await SupabaseService.shared.fetchPlayoffTiersGroupByInviteCode(
                code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                accessToken: token
            ) else {
                groupError = "No group found with that code."
                isJoiningGroup = false
                return false
            }

            // Check if already a member
            let members = try await SupabaseService.shared.fetchPlayoffTiersGroupMembers(
                groupID: record.id, accessToken: token
            )
            if members.contains(where: { $0.userID == uid }) {
                groupError = "You're already in this group."
                isJoiningGroup = false
                return false
            }

            // Check max members
            if members.count >= record.maxMembers {
                groupError = "This group is full."
                isJoiningGroup = false
                return false
            }

            let displayName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.joinPlayoffTiersGroup(
                groupID: record.id, userID: uid, displayName: displayName, accessToken: token
            )

            let group = record.toModel()
            if !myGroups.contains(where: { $0.id == group.id }) {
                myGroups.insert(group, at: 0)
            }

            isJoiningGroup = false
            return true
        } catch {
            groupError = "Failed to join group: \(error.localizedDescription)"
            print("[PlayoffTiers] Join group error: \(error)")
            isJoiningGroup = false
            return false
        }
    }

    func loadGroupDetail(_ group: PlayoffTiersGroup) async {
        guard let token = accessToken else { return }
        currentGroup = group

        do {
            let memberRecords = try await SupabaseService.shared.fetchPlayoffTiersGroupMembers(
                groupID: group.id.uuidString, accessToken: token
            )
            currentGroupMembers = memberRecords.map { $0.toModel() }
        } catch {
            print("[PlayoffTiers] Failed to load group members: \(error)")
            currentGroupMembers = []
        }
    }

    func leaveGroup(_ group: PlayoffTiersGroup) async {
        guard let token = accessToken, let uid = userID else { return }

        do {
            try await SupabaseService.shared.leavePlayoffTiersGroup(
                groupID: group.id.uuidString, userID: uid, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id {
                currentGroup = nil
                currentGroupMembers = []
            }
        } catch {
            print("[PlayoffTiers] Failed to leave group: \(error)")
        }
    }

    func deleteGroup(_ group: PlayoffTiersGroup) async {
        guard let token = accessToken else { return }

        do {
            try await SupabaseService.shared.deletePlayoffTiersGroup(
                groupID: group.id.uuidString, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id {
                currentGroup = nil
                currentGroupMembers = []
            }
        } catch {
            print("[PlayoffTiers] Failed to delete group: \(error)")
        }
    }

    private func generateInviteCode() -> String {
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  // no I/O/0/1 to avoid confusion
        return String((0..<6).map { _ in characters.randomElement()! })
    }
}
