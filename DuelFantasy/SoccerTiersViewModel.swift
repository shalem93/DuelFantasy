import Foundation

@MainActor @Observable
final class SoccerTiersViewModel {
    // MARK: - Tournament State
    var tournament: SoccerTiersTournament?
    var tiers: [[SoccerTiersPlayer]] = []  // 6 tiers of players
    var userPicks: [Int: SoccerTiersPlayer] = [:]  // tier (1-6) → selected player
    var leaderboardEntries: [SoccerTiersLeaderboardEntry] = []
    var livePlayerPoints: [String: Double] = [:]  // accumulated WC FPTS per player

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
        print("[SoccerTiers] Hydrated \(cached.count) cached player scores")
    }

    func persistPointsCache() {
        guard let key = pointsCacheKey, !livePlayerPoints.isEmpty,
              let data = try? JSONEncoder().encode(livePlayerPoints) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    var fieldEntries: [SoccerTiersEntry] = []
    var eliminatedNations: Set<String> = []

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
    var myGroups: [SoccerTiersGroup] = []
    var currentGroup: SoccerTiersGroup?
    var currentGroupMembers: [SoccerTiersGroupMember] = []
    var groupError: String?
    var isCreatingGroup: Bool = false
    var isJoiningGroup: Bool = false

    // MARK: - Providers
    private let espnProvider = ESPNSoccerTiersDataProvider()
    private var fieldGenerated = false
    private var lastRefreshDate: Date?

    // MARK: - Local Bot Cache
    private static let botCacheKey = "soccer_tiers_bot_cache"

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
        guard hasLiveData else { return nil }
        // Don't report a rank if the leaderboard is incomplete (e.g. bots haven't loaded yet).
        // A real contest has hundreds of entries; a small count means only the user entry loaded.
        guard leaderboardEntries.count >= 10 else { return nil }
        return leaderboardEntries.first(where: { $0.isCurrentUser })?.rank
    }

    var userTotalPoints: Double? {
        guard hasLiveData else { return nil }
        return leaderboardEntries.first(where: { $0.isCurrentUser })?.totalPoints
    }

    // MARK: - Load Tournament

    func loadTournament() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        // Use hardcoded squad data for World Cup 2026
        let allPlayers = SoccerTiersSquadData.worldCup2026()
        guard !allPlayers.isEmpty else {
            error = "No World Cup players found."
            isLoading = false
            hasAttemptedLoad = true
            return
        }

        // Generate tiers
        tiers = SoccerTiersEngine.generateTiers(from: allPlayers)
        print("[SoccerTiers] Generated tiers: \(tiers.map { $0.count })")

        // Build tournament
        let tournamentID = SoccerTiersTournament.currentTournamentID()
        let lockTime = SoccerTiersTournament.lockTime()

        // Try to load existing tournament from Supabase
        var loadedTournament: SoccerTiersTournament?
        if let token = accessToken {
            if let record = try? await SupabaseService.shared.fetchSoccerTiersTournament(
                tournamentID: tournamentID, accessToken: token
            ) {
                loadedTournament = SoccerTiersTournament(
                    id: record.id,
                    title: record.title,
                    season: record.season,
                    status: record.status,
                    lockTime: record.lockTime,
                    entryCount: record.entryCount ?? 1000,
                    isSettled: record.isSettled ?? false,
                    createdAt: record.createdAt ?? Date()
                )
            }
        }

        if var existing = loadedTournament {
            // Only reset "locked" to "open" if lock time is still in the future.
            if existing.status == "locked" && !existing.isSettled {
                if Date() < lockTime {
                    print("[SoccerTiers] Resetting 'locked' to 'open' — lock time \(lockTime) is still in the future")
                    existing = SoccerTiersTournament(
                        id: existing.id, title: existing.title, season: existing.season,
                        status: "open", lockTime: lockTime, entryCount: existing.entryCount,
                        isSettled: false, createdAt: existing.createdAt
                    )
                    if let token = accessToken {
                        try? await SupabaseService.shared.updateSoccerTiersTournamentStatus(
                            tournamentID: existing.id, status: "open", accessToken: token
                        )
                    }
                }
            }
            // Update lockTime if different
            if lockTime != existing.lockTime {
                existing = SoccerTiersTournament(
                    id: existing.id, title: existing.title, season: existing.season,
                    status: existing.status, lockTime: lockTime, entryCount: existing.entryCount,
                    isSettled: existing.isSettled, createdAt: existing.createdAt
                )
            }
            tournament = existing
        } else {
            // Create new tournament
            let newTournament = SoccerTiersTournament(
                id: tournamentID,
                title: SoccerTiersTournament.currentTitle(),
                season: SoccerTiersTournament.currentSeason(),
                status: "open",
                lockTime: lockTime,
                entryCount: 1000,
                isSettled: false,
                createdAt: Date()
            )
            tournament = newTournament

            // Save to Supabase
            if let token = accessToken {
                let record = SoccerTiersTournamentRecord(
                    id: newTournament.id,
                    title: newTournament.title,
                    season: newTournament.season,
                    status: newTournament.status,
                    lockTime: newTournament.lockTime,
                    entryCount: newTournament.entryCount
                )
                try? await SupabaseService.shared.upsertSoccerTiersTournament(
                    record: record, accessToken: token
                )
            }
        }

        // Check if user already has an entry
        if let token = accessToken, let uid = userID {
            if let existingEntry = try? await SupabaseService.shared.fetchUserSoccerTiersEntry(
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

        isLoading = false
        hasAttemptedLoad = true
    }

    /// Re-fetch the user's submitted entry from Supabase if `userPicks` is
    /// empty but auth is now available. The first `loadTournament` call
    /// often happens before auth has propagated (it fires from
    /// FantasyHubView's `.task` at app launch), so the entry-fetch inside
    /// `loadTournament` gets skipped silently because `accessToken` is
    /// nil at that moment. `hasAttemptedLoad` then gets force-set to true,
    /// blocking any retry — so the user's submitted picks appear lost
    /// even though they're still in Supabase. Call this from the lobby's
    /// `.task` after auth has had time to settle.
    func restoreUserPicksIfMissing() async {
        guard userPicks.isEmpty, !hasSubmitted else { return }
        guard let token = accessToken, let uid = userID else { return }
        guard let tournamentID = tournament?.id ?? Optional(SoccerTiersTournament.currentTournamentID()) else { return }
        // Surface a spinner while we late-bind fetch. Without this the
        // lobby flashed empty content for ~1-2s before the picks popped in.
        isLoading = true
        defer { isLoading = false }
        guard let record = try? await SupabaseService.shared.fetchUserSoccerTiersEntry(
            tournamentID: tournamentID, userID: uid, accessToken: token
        ) else { return }
        hasSubmitted = true
        for pickData in record.picks {
            let pick = pickData.toModel()
            var foundPlayer: SoccerTiersPlayer?
            for tier in tiers {
                if let player = tier.first(where: { $0.id == pick.playerID }) {
                    foundPlayer = player
                    break
                }
            }
            if let player = foundPlayer {
                userPicks[pick.tier] = player
            } else {
                // Player not in current tier pool (e.g. removed from squad
                // after submission). Use the data we stored on the entry.
                userPicks[pick.tier] = SoccerTiersPlayer(
                    id: pick.playerID, name: pick.playerName,
                    country: "", countryCode: pick.playerCountry,
                    position: "", tier: pick.tier, projectedPoints: 0,
                    matchesPlayed: 0, totalFantasyPoints: 0, perMatchAvg: 0,
                    imageURL: nil, isEliminated: false
                )
            }
        }
        print("[SoccerTiers] Restored \(userPicks.count) picks via late-bind fetch")
    }

    // MARK: - Pick Management

    func selectPlayer(tier: Int, player: SoccerTiersPlayer) {
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

        let picks = (1...6).compactMap { tier -> SoccerTiersPickData? in
            guard let player = userPicks[tier] else { return nil }
            return SoccerTiersPickData(
                tier: tier,
                playerID: player.id,
                playerName: player.name,
                playerCountry: player.countryCode
            )
        }

        guard picks.count == 6 else {
            error = "Please select a player from each tier."
            isSubmitting = false
            return
        }

        do {
            let entryName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.submitSoccerTiersEntry(
                tournamentID: tournament?.id ?? SoccerTiersTournament.currentTournamentID(),
                userID: uid,
                entryName: entryName,
                picks: picks,
                accessToken: token
            )
            hasSubmitted = true
            print("[SoccerTiers] Picks submitted successfully")
        } catch {
            self.error = "Failed to submit picks: \(error.localizedDescription)"
            print("[SoccerTiers] Submit error: \(error)")
        }

        isSubmitting = false
    }

    // MARK: - Live Refresh

    func refreshLive() async {
        guard let tournament else { return }

        // Load field entries if not yet loaded.
        if !fieldGenerated {
            await loadFieldEntries()
        }

        // If user picks weren't restored yet, try multiple sources:
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
                        userPicks[pick.tier] = SoccerTiersPlayer(
                            id: pick.playerID, name: pick.playerName,
                            country: "", countryCode: pick.playerCountry,
                            position: "", tier: pick.tier, projectedPoints: 0,
                            matchesPlayed: 0, totalFantasyPoints: 0, perMatchAvg: 0,
                            imageURL: nil, isEliminated: false
                        )
                    }
                }
                hasSubmitted = true
            }
            // If still empty, fetch directly from entries table
            if userPicks.isEmpty, let uid = userID, let token = accessToken {
                if let record = try? await SupabaseService.shared.fetchUserSoccerTiersEntry(
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
                            userPicks[pick.tier] = SoccerTiersPlayer(
                                id: pick.playerID, name: pick.playerName,
                                country: "", countryCode: pick.playerCountry,
                                position: "", tier: pick.tier, projectedPoints: 0,
                                matchesPlayed: 0, totalFantasyPoints: 0, perMatchAvg: 0,
                                imageURL: nil, isEliminated: false
                            )
                        }
                    }
                    // Also ensure user is in fieldEntries
                    if !fieldEntries.contains(where: { $0.isCurrentUser }) {
                        let userEntry = SoccerTiersEntry(
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

        // Show last-known scores instantly while the multi-match ESPN fetch
        // runs — otherwise every cold open flashes 0.0 for every player.
        hydratePointsCacheIfNeeded()
        if leaderboardEntries.isEmpty && !livePlayerPoints.isEmpty && !fieldEntries.isEmpty {
            leaderboardEntries = SoccerTiersEngine.computeLeaderboard(
                entries: fieldEntries,
                playerPoints: livePlayerPoints,
                currentUserID: userID
            )
        }

        // Fetch accumulated World Cup scores. We pass the full pool (flattened
        // from `tiers`) so the provider can match ESPN athletes back to our
        // pool IDs by name + country, and look up each player's position
        // for the scoring formula.
        // NEVER overwrite good scores with an empty result — a failed ESPN
        // fetch was zeroing the standings while the screen sat open.
        let poolPlayers = tiers.flatMap { $0 }
        let snapshot = await espnProvider.fetchWorldCupScores(players: poolPlayers)
        if !snapshot.playerFantasyPoints.isEmpty {
            livePlayerPoints = snapshot.playerFantasyPoints
            persistPointsCache()
        } else if !livePlayerPoints.isEmpty {
            print("[SoccerTiers] Score fetch returned empty — keeping \(livePlayerPoints.count) existing scores")
        }

        // Fetch eliminated nations
        eliminatedNations = await espnProvider.fetchEliminatedNations()

        // Update tier player data with elimination status
        for tierIndex in 0..<tiers.count {
            for playerIndex in 0..<tiers[tierIndex].count {
                let player = tiers[tierIndex][playerIndex]
                tiers[tierIndex][playerIndex].isEliminated = eliminatedNations.contains(player.countryCode)
                tiers[tierIndex][playerIndex].totalFantasyPoints = livePlayerPoints[player.id] ?? 0
            }
        }

        // Compute leaderboard
        leaderboardEntries = SoccerTiersEngine.computeLeaderboard(
            entries: fieldEntries,
            playerPoints: livePlayerPoints,
            currentUserID: userID
        )

        // Check if tournament is complete → settle
        if tournament.status == "live" {
            let complete = await espnProvider.checkTournamentComplete()
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
        // substantial field (500+).
        if let token,
           let records = try? await SupabaseService.shared.fetchSoccerTiersEntries(
            tournamentID: tournament.id, accessToken: token
        ), records.count >= 500 {
            fieldEntries = records.map { record in
                SoccerTiersEntry(
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
            print("[SoccerTiers] Loaded \(fieldEntries.count) entries from entries table")
            return
        }

        // Try restoring bots from the tournament's bot_field JSON
        if let token {
            do {
                let botField = try await SupabaseService.shared.fetchSoccerTiersBotField(
                    tournamentID: tournament.id, accessToken: token
                )
                print("[SoccerTiers] bot_field fetch returned \(botField.count) entries")
                if !botField.isEmpty {
                    let restoredEntries = parseBotFieldData(botField, tournamentID: tournament.id)
                    if !restoredEntries.isEmpty {
                        await attachUserEntryAndFinalize(restoredEntries: restoredEntries, tournamentID: tournament.id, token: token)
                        if fieldGenerated {
                            // Backfill entries table in background
                            Task { await backfillEntriesToServer(bots: restoredEntries, tournamentID: tournament.id, token: token) }
                            return
                        }
                    }
                }
            } catch {
                print("[SoccerTiers] bot_field fetch failed: \(error)")
            }
        }

        // Try local cache before generating fresh bots
        if !fieldGenerated {
            if let cachedBots = loadBotCacheLocally(tournamentID: tournament.id), !cachedBots.isEmpty {
                print("[SoccerTiers] Restoring \(cachedBots.count) bots from local cache")
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
    private func parseBotFieldData(_ botField: [[String: Any]], tournamentID: String) -> [SoccerTiersEntry] {
        var restoredEntries: [SoccerTiersEntry] = []
        var parseFailures = 0
        for botData in botField {
            guard let name = botData["name"] as? String,
                  let picksRaw = botData["picks"] as? [[String: Any]] else {
                parseFailures += 1
                continue
            }
            let picks = picksRaw.compactMap { p -> SoccerTiersPick? in
                let tier: Int
                if let t = p["tier"] as? Int {
                    tier = t
                } else if let t = p["tier"] as? Double {
                    tier = Int(t)
                } else { return nil }
                guard let playerID = p["player_id"] as? String,
                      let playerName = p["player_name"] as? String,
                      let playerCountry = p["player_country"] as? String else { return nil }
                return SoccerTiersPick(tier: tier, playerID: playerID, playerName: playerName, playerCountry: playerCountry)
            }
            guard picks.count == 6 else {
                parseFailures += 1
                continue
            }
            restoredEntries.append(SoccerTiersEntry(
                id: UUID(), tournamentID: tournamentID, userID: nil,
                entryName: name, picks: picks, totalPoints: 0, rank: 0,
                isBot: true, isCurrentUser: false
            ))
        }
        if parseFailures > 0 {
            print("[SoccerTiers] \(parseFailures) bots failed to parse from bot field data")
        }
        return restoredEntries
    }

    /// Attach the user's entry to restored bot entries and finalize the field.
    private func attachUserEntryAndFinalize(restoredEntries: [SoccerTiersEntry], tournamentID: String, token: String?) async {
        var userEntry: SoccerTiersEntry?
        if let uid = userID {
            // First try: build from userPicks (already restored from Supabase)
            if hasSubmitted && userPicks.count == 6 {
                userEntry = SoccerTiersEntry(
                    id: UUID(), tournamentID: tournamentID, userID: uid,
                    entryName: profileName.isEmpty ? "Player" : profileName,
                    picks: (1...6).compactMap { tier -> SoccerTiersPick? in
                        guard let player = userPicks[tier] else { return nil }
                        return SoccerTiersPick(tier: tier, playerID: player.id, playerName: player.name, playerCountry: player.countryCode)
                    },
                    totalPoints: 0, rank: 0, isBot: false, isCurrentUser: true
                )
            }
            // Second try: fetch directly from entries table (requires auth)
            if userEntry == nil, let token {
                if let record = try? await SupabaseService.shared.fetchUserSoccerTiersEntry(
                    tournamentID: tournamentID, userID: uid, accessToken: token
                ) {
                    hasSubmitted = true
                    userEntry = SoccerTiersEntry(
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
                            userPicks[pick.tier] = SoccerTiersPlayer(
                                id: pick.playerID, name: pick.playerName,
                                country: "", countryCode: pick.playerCountry,
                                position: "", tier: pick.tier, projectedPoints: 0,
                                matchesPlayed: 0, totalFantasyPoints: 0, perMatchAvg: 0,
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
        print("[SoccerTiers] Restored \(restoredEntries.count) bots from field data")
    }

    /// Backfill the entries table (primary persistence) from a fallback-restored bot list.
    /// Runs in the background so the UI isn't blocked.
    private func backfillEntriesToServer(bots: [SoccerTiersEntry], tournamentID: String, token: String) async {
        let botPayloads: [(name: String, picks: [SoccerTiersPickData])] = bots.map { entry in
            (name: entry.entryName, picks: entry.picks.map { SoccerTiersPickData(from: $0) })
        }
        do {
            // Check if entries table already has enough bots
            let existing = try? await SupabaseService.shared.fetchSoccerTiersEntries(
                tournamentID: tournamentID, accessToken: token
            )
            if (existing?.count ?? 0) >= 500 {
                print("[SoccerTiers] Entries table already has \(existing?.count ?? 0) entries, skipping backfill")
                return
            }
            try await SupabaseService.shared.deleteSoccerTiersBotEntries(
                tournamentID: tournamentID, accessToken: token
            )
            try await SupabaseService.shared.batchInsertSoccerTiersBotEntries(
                tournamentID: tournamentID, bots: botPayloads, accessToken: token
            )
            print("[SoccerTiers] Backfilled \(bots.count) bots to entries table")
        } catch {
            print("[SoccerTiers] Backfill to entries table failed: \(error)")
        }
    }

    // MARK: - Generate Bot Field

    private func generateBotField() async {
        guard let tournament else {
            print("[SoccerTiers] generateBotField: no tournament")
            return
        }
        guard !tiers.isEmpty && tiers.allSatisfy({ !$0.isEmpty }) else {
            print("[SoccerTiers] generateBotField: invalid tier data")
            return
        }
        // Don't regenerate if we already have bot entries
        guard fieldEntries.filter({ $0.isBot }).isEmpty else {
            print("[SoccerTiers] Skipping generateBotField — already have \(fieldEntries.filter({ $0.isBot }).count) bots")
            fieldGenerated = true
            return
        }

        print("[SoccerTiers] Generating bot field...")
        var botEntries = SoccerTiersBotDrafter.generateBotEntries(tiers: tiers, count: 999, tournamentID: tournament.id)

        // Set tournament ID
        botEntries = botEntries.map { entry in
            SoccerTiersEntry(
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
                     "player_name": pick.playerName, "player_country": pick.playerCountry]
                }
            ] as [String: Any]
        }
        saveBotCacheLocally(botPicksData, tournamentID: tournament.id)

        // Save to Supabase only if authenticated
        guard let token = accessToken else {
            print("[SoccerTiers] No auth — saved bots to local cache only")
            return
        }

        // Save bot entries to the entries table (primary persistence).
        let botPayloads: [(name: String, picks: [SoccerTiersPickData])] = botEntries.map { entry in
            (name: entry.entryName, picks: entry.picks.map { SoccerTiersPickData(from: $0) })
        }
        do {
            try await SupabaseService.shared.deleteSoccerTiersBotEntries(
                tournamentID: tournament.id, accessToken: token
            )
            try await SupabaseService.shared.batchInsertSoccerTiersBotEntries(
                tournamentID: tournament.id, bots: botPayloads, accessToken: token
            )
            print("[SoccerTiers] Saved \(botEntries.count) bots to entries table")
        } catch {
            print("[SoccerTiers] Failed to save bots to entries table: \(error)")
        }

        // Also save to bot_field column as fallback
        do {
            try await SupabaseService.shared.saveSoccerTiersBotField(
                tournamentID: tournament.id, botField: botPicksData, accessToken: token
            )
        } catch {
            print("[SoccerTiers] Failed to save bot_field fallback: \(error)")
        }
    }

    /// Build a user entry for the field — tries local userPicks first, then Supabase.
    private func buildUserEntry(tournamentID: String, token: String) async -> SoccerTiersEntry? {
        guard let uid = userID else { return nil }

        if hasSubmitted && userPicks.count == 6 {
            return SoccerTiersEntry(
                id: UUID(), tournamentID: tournamentID, userID: uid,
                entryName: profileName.isEmpty ? "Player" : profileName,
                picks: (1...6).compactMap { tier -> SoccerTiersPick? in
                    guard let player = userPicks[tier] else { return nil }
                    return SoccerTiersPick(tier: tier, playerID: player.id, playerName: player.name, playerCountry: player.countryCode)
                },
                totalPoints: 0, rank: 0, isBot: false, isCurrentUser: true
            )
        }

        if let record = try? await SupabaseService.shared.fetchUserSoccerTiersEntry(
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
                    userPicks[pick.tier] = SoccerTiersPlayer(
                        id: pick.playerID, name: pick.playerName,
                        country: "", countryCode: pick.playerCountry,
                        position: "", tier: pick.tier, projectedPoints: 0,
                        matchesPlayed: 0, totalFantasyPoints: 0, perMatchAvg: 0,
                        imageURL: nil, isEliminated: false
                    )
                }
            }
            return SoccerTiersEntry(
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
    func recheckStatusIfNeeded() async {
        guard tournament != nil else { return }
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
            self.tournament = SoccerTiersTournament(
                id: tournament.id, title: tournament.title, season: tournament.season,
                status: "locked", lockTime: tournament.lockTime, entryCount: tournament.entryCount,
                isSettled: false, createdAt: tournament.createdAt
            )
            if let token = accessToken {
                try? await SupabaseService.shared.updateSoccerTiersTournamentStatus(
                    tournamentID: tournament.id, status: "locked", accessToken: token
                )
            }
        }

        // Check if we should transition from locked → live (matches started)
        if self.tournament?.status == "locked" {
            let hasMatchesStarted = await espnProvider.hasMatchesStarted()
            if hasMatchesStarted {
                self.tournament = SoccerTiersTournament(
                    id: tournament.id, title: tournament.title, season: tournament.season,
                    status: "live", lockTime: tournament.lockTime, entryCount: tournament.entryCount,
                    isSettled: false, createdAt: tournament.createdAt
                )
                if let token = accessToken {
                    try? await SupabaseService.shared.updateSoccerTiersTournamentStatus(
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

        print("[SoccerTiers] Settling tournament \(tournament.id)")

        // Compute final leaderboard
        let finalLeaderboard = SoccerTiersEngine.computeLeaderboard(
            entries: fieldEntries,
            playerPoints: livePlayerPoints,
            currentUserID: userID
        )
        leaderboardEntries = finalLeaderboard

        // Calculate RR delta for user
        if let userEntry = finalLeaderboard.first(where: { $0.isCurrentUser }) {
            let rrDelta = SoccerTiersEngine.rrDelta(forRank: userEntry.rank, totalEntries: finalLeaderboard.count)
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
                    league: "soccer-tiers",
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
        self.tournament = SoccerTiersTournament(
            id: tournament.id, title: tournament.title, season: tournament.season,
            status: "settled", lockTime: tournament.lockTime, entryCount: tournament.entryCount,
            isSettled: true, createdAt: tournament.createdAt
        )

        try? await SupabaseService.shared.markSoccerTiersTournamentSettled(
            tournamentID: tournament.id, accessToken: token
        )

        // Update entry scores on server
        let updates = finalLeaderboard.map { entry in
            (id: entry.id.uuidString, totalPoints: entry.totalPoints, rank: entry.rank)
        }
        try? await SupabaseService.shared.updateSoccerTiersEntryScores(
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

    /// Members' actual entries, fetched directly from the entries table when
    /// the group detail opens. The global `leaderboardEntries` only contains
    /// entries that happen to be in the loaded 1,000-row field — another
    /// member's real entry isn't guaranteed to be there, which silently
    /// dropped them from group standings.
    var currentGroupEntries: [SoccerTiersEntry] = []

    /// Leaderboard filtered to only members of the current group
    var groupLeaderboard: [SoccerTiersLeaderboardEntry] {
        // Preferred path: score the directly-fetched member entries.
        if !currentGroupEntries.isEmpty {
            return SoccerTiersEngine.computeLeaderboard(
                entries: currentGroupEntries,
                playerPoints: livePlayerPoints,
                currentUserID: userID
            )
        }
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
            SoccerTiersLeaderboardEntry(
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
        let tournamentID = tournament?.id ?? SoccerTiersTournament.currentTournamentID()

        do {
            let records = try await SupabaseService.shared.fetchMySoccerTiersGroups(
                userID: uid, tournamentID: tournamentID, accessToken: token
            )
            myGroups = records.map { $0.toModel() }
        } catch {
            print("[SoccerTiers] Failed to load groups: \(error)")
        }
    }

    func createGroup(name: String) async -> SoccerTiersGroup? {
        guard let token = accessToken, let uid = userID else {
            groupError = "Please sign in to create a group."
            return nil
        }
        let tournamentID = tournament?.id ?? SoccerTiersTournament.currentTournamentID()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Idempotency: if the user already has a group with this exact name,
        // return it instead of double-creating. The DB also enforces a unique
        // (created_by, name) constraint as a hard guarantee.
        if let existing = myGroups.first(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            groupError = "You already have a group named \"\(existing.name)\"."
            return existing
        }

        isCreatingGroup = true
        groupError = nil

        do {
            // Generate a short invite code
            let code = generateInviteCode()
            let record = try await SupabaseService.shared.createSoccerTiersGroup(
                tournamentID: tournamentID,
                name: trimmedName,
                createdBy: uid,
                inviteCode: code,
                maxMembers: 20,
                accessToken: token
            )
            let group = record.toModel()

            // Auto-join the creator
            let displayName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.joinSoccerTiersGroup(
                groupID: record.id, userID: uid, displayName: displayName, accessToken: token
            )

            myGroups.insert(group, at: 0)
            isCreatingGroup = false
            return group
        } catch {
            groupError = "Failed to create group: \(error.localizedDescription)"
            print("[SoccerTiers] Create group error: \(error)")
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
            guard let record = try await SupabaseService.shared.fetchSoccerTiersGroupByInviteCode(
                code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                accessToken: token
            ) else {
                groupError = "No group found with that code."
                isJoiningGroup = false
                return false
            }

            // Check if already a member
            let members = try await SupabaseService.shared.fetchSoccerTiersGroupMembers(
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
            try await SupabaseService.shared.joinSoccerTiersGroup(
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
            print("[SoccerTiers] Join group error: \(error)")
            isJoiningGroup = false
            return false
        }
    }

    func loadGroupDetail(_ group: SoccerTiersGroup) async {
        guard let token = accessToken else { return }
        currentGroup = group

        do {
            let memberRecords = try await SupabaseService.shared.fetchSoccerTiersGroupMembers(
                groupID: group.id.uuidString, accessToken: token
            )
            currentGroupMembers = memberRecords.map { $0.toModel() }
        } catch {
            print("[SoccerTiers] Failed to load group members: \(error)")
            currentGroupMembers = []
        }

        // Fetch each member's actual entry directly so group standings show
        // everyone who submitted — independent of what the global field holds.
        var entries: [SoccerTiersEntry] = []
        for member in currentGroupMembers {
            guard let rec = try? await SupabaseService.shared.fetchUserSoccerTiersEntry(
                tournamentID: group.tournamentID, userID: member.userID, accessToken: token
            ) else { continue }
            entries.append(SoccerTiersEntry(
                id: UUID(uuidString: rec.id) ?? UUID(),
                tournamentID: rec.tournamentID,
                userID: rec.userID,
                entryName: member.displayName,
                picks: rec.picks.map { $0.toModel() },
                totalPoints: rec.totalPoints,
                rank: rec.rank,
                isBot: false,
                isCurrentUser: member.userID == userID
            ))
        }
        currentGroupEntries = entries
        // Make sure scores exist for the standings even if the live view
        // hasn't been opened this session.
        hydratePointsCacheIfNeeded()
        print("[SoccerTiers] Group detail: \(currentGroupMembers.count) members, \(entries.count) entries fetched")
    }

    func leaveGroup(_ group: SoccerTiersGroup) async {
        guard let token = accessToken, let uid = userID else { return }

        do {
            try await SupabaseService.shared.leaveSoccerTiersGroup(
                groupID: group.id.uuidString, userID: uid, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id {
                currentGroup = nil
                currentGroupMembers = []
            }
        } catch {
            print("[SoccerTiers] Failed to leave group: \(error)")
        }
    }

    func deleteGroup(_ group: SoccerTiersGroup) async {
        guard let token = accessToken else { return }

        do {
            try await SupabaseService.shared.deleteSoccerTiersGroup(
                groupID: group.id.uuidString, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id {
                currentGroup = nil
                currentGroupMembers = []
            }
        } catch {
            print("[SoccerTiers] Failed to delete group: \(error)")
        }
    }

    private func generateInviteCode() -> String {
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  // no I/O/0/1 to avoid confusion
        return String((0..<6).map { _ in characters.randomElement()! })
    }
}
