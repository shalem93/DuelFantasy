import Foundation

@MainActor @Observable
final class GolfTiersViewModel {
    // MARK: - Tournament State
    var tournament: GolfTiersTournament?
    var tiers: [[GolfTiersGolfer]] = []  // 6 tiers of golfers
    var userPicks: [Int: GolfTiersGolfer] = [:]  // tier (1-6) → selected golfer
    var leaderboardEntries: [GolfTiersLeaderboardEntry] = []
    var liveGolferScores: [String: Int] = [:]   // golferID → score-to-par
    var liveGolferRounds: [String: [Int]] = [:]  // golferID → round scores
    var liveGolferStatuses: [String: GolfTiersGolfer.GolferStatus] = [:]
    var fieldEntries: [GolfTiersEntry] = []
    var currentRound: Int = 0
    var espnEvent: ESPNPGAEvent?

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
    var myGroups: [GolfTiersGroup] = []
    var currentGroup: GolfTiersGroup?
    var currentGroupMembers: [GolfTiersGroupMember] = []
    var groupError: String?
    var isCreatingGroup: Bool = false
    var isJoiningGroup: Bool = false

    // MARK: - Settled History State
    var settledTournaments: [GolfTiersTournamentRecord] = []
    var settledResults: [String: DFSTournamentResultRecord] = [:]  // tournamentID → user result
    var isLoadingHistory: Bool = false

    // MARK: - Providers
    private let espnProvider = ESPNGolfTiersDataProvider()
    private var fieldGenerated = false
    private var lastRefreshDate: Date?

    // MARK: - Local Bot Cache
    private static let botCacheKey = "golf_tiers_bot_cache"

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

    var hasLiveData: Bool { lastRefreshDate != nil }

    var userRank: Int? {
        guard hasLiveData else { return nil }
        if let rank = leaderboardEntries.first(where: { $0.isCurrentUser })?.rank,
           leaderboardEntries.count >= 10 {
            return rank
        }
        // If no leaderboard yet (no bots), show rank as 1 (only entry)
        if !userPicks.isEmpty && !liveGolferScores.isEmpty {
            return nil  // Don't show rank without a real field to compare against
        }
        return nil
    }

    var userTotalScore: Int? {
        // Try leaderboard first, fall back to computing directly from picks
        if let lbScore = leaderboardEntries.first(where: { $0.isCurrentUser })?.totalScore {
            return lbScore
        }
        // Compute directly from user picks + live scores (works even without bots)
        guard !userPicks.isEmpty, !liveGolferScores.isEmpty else { return nil }
        var pickScores: [(id: String, score: Int)] = []
        for (_, golfer) in userPicks {
            let rawScore = liveGolferScores[golfer.id] ?? 0
            let rounds = liveGolferRounds[golfer.id] ?? []
            let status = liveGolferStatuses[golfer.id] ?? .active
            let effective = GolfTiersEngine.effectiveScoreToPar(
                golferScoreToPar: rawScore, roundScores: rounds, status: status
            )
            pickScores.append((golfer.id, effective))
        }
        let best4 = pickScores.sorted { $0.score < $1.score }.prefix(4)
        return best4.reduce(0) { $0 + $1.score }
    }

    var userTotalScoreDisplay: String {
        guard let score = userTotalScore else { return "--" }
        return GolfTiersEngine.scoreToParDisplay(score)
    }

    // MARK: - Load Tournament

    func loadTournament() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        do {
            let tournamentID = GolfTiersTournament.currentMajorID()

            // ──────────────────────────────────────────────────────────────
            // 1. Check Supabase FIRST for an existing tournament record.
            //    If the tournament is already settled, skip ESPN entirely —
            //    ESPN's scoreboard now shows the NEXT event (e.g. Byron
            //    Nelson after PGA Championship ends), which has a completely
            //    different field.
            // ──────────────────────────────────────────────────────────────
            var loadedTournament: GolfTiersTournament?
            if let token = accessToken {
                if let record = try? await SupabaseService.shared.fetchGolfTiersTournament(
                    tournamentID: tournamentID, accessToken: token
                ) {
                    loadedTournament = GolfTiersTournament(
                        id: record.id,
                        title: record.title,
                        majorName: record.majorName,
                        season: record.season,
                        status: record.status,
                        lockTime: record.lockTime,
                        espnEventID: record.espnEventID,
                        entryCount: record.entryCount ?? 1000,
                        isSettled: record.isSettled ?? false,
                        createdAt: record.createdAt ?? Date()
                    )
                }
            }

            // If the tournament is settled, show final results without hitting ESPN
            if let existing = loadedTournament, existing.isSettled || existing.status == "settled" {
                tournament = existing
                print("[GolfTiers] Tournament \(existing.id) is settled — loading final results only")

                // Load user entry if available
                if let token = accessToken, let uid = userID {
                    if let existingEntry = try? await SupabaseService.shared.fetchUserGolfTiersEntry(
                        tournamentID: tournamentID, userID: uid, accessToken: token
                    ) {
                        hasSubmitted = true
                        for pickData in existingEntry.picks {
                            let pick = pickData.toModel()
                            // Reconstruct minimal golfer objects from pick data
                            userPicks[pick.tier] = GolfTiersGolfer(
                                id: pick.playerID, name: pick.playerName, country: pick.playerCountry,
                                tier: pick.tier, owgrRank: 999, scoreToPar: 0, roundScores: [],
                                status: .active, imageURL: nil
                            )
                        }
                    }
                }

                // Load field entries for the settled leaderboard
                await loadFieldEntries()

                // For settled tournaments, first build leaderboard from stored
                // totalScore & rank as a baseline, then try ESPN for full data.
                if !fieldEntries.isEmpty {
                    let sorted = fieldEntries.sorted { a, b in
                        if a.rank != b.rank { return a.rank < b.rank }
                        return a.totalScore < b.totalScore
                    }
                    leaderboardEntries = sorted.map { entry in
                        var pickScores: [String: Int] = [:]
                        for pick in entry.picks {
                            pickScores[pick.playerID] = 0
                        }
                        let countingIDs = Set(entry.picks.prefix(4).map { $0.playerID })
                        return GolfTiersLeaderboardEntry(
                            id: entry.id,
                            entryName: entry.entryName,
                            picks: entry.picks,
                            totalScore: entry.totalScore,
                            rank: entry.rank > 0 ? entry.rank : 1,
                            isCurrentUser: entry.isCurrentUser,
                            pickScores: pickScores,
                            countingPicks: countingIDs
                        )
                    }
                }
                lastRefreshDate = Date()

                isLoading = false
                hasAttemptedLoad = true
                return
            }

            // ──────────────────────────────────────────────────────────────
            // 2. Tournament is NOT settled — fetch ESPN field.
            //    For majors that already ended but weren't settled (e.g. no
            //    user opened the app during the tournament), the ESPN
            //    scoreboard will show a different event. In that case, try
            //    to fetch the specific event by stored ESPN ID first.
            // ──────────────────────────────────────────────────────────────
            var golfers: [GolfTiersGolfer] = []
            var event: ESPNPGAEvent? = nil

            // If we have a stored ESPN event ID, try fetching that specific event
            if let existing = loadedTournament, let storedEventID = existing.espnEventID {
                do {
                    let (fetchedGolfers, fetchedEvent) = try await espnProvider.fetchMajorField()
                    // Check if the ESPN scoreboard event matches our stored event
                    if fetchedEvent?.id == storedEventID {
                        golfers = fetchedGolfers
                        event = fetchedEvent
                    } else {
                        // ESPN is showing a different event — use stored data
                        print("[GolfTiers] ESPN showing \(fetchedEvent?.name ?? "unknown") instead of \(existing.title) — using stored tournament data")
                        tournament = existing
                        // Auto-settle if enough time has passed
                        await checkStatusTransition()
                        if isLocked {
                            await loadFieldEntries()
                            // Try fetching scores from our stored event ID
                            do {
                                let snapshot = try await espnProvider.fetchLiveScores(espnEventID: storedEventID)
                                if !snapshot.golferScoresToPar.isEmpty {
                                    liveGolferScores = snapshot.golferScoresToPar
                                    liveGolferRounds = snapshot.golferRoundScores
                                    liveGolferStatuses = snapshot.golferStatuses
                                    currentRound = snapshot.currentRound
                                }
                            } catch {
                                print("[GolfTiers] ESPN score fetch failed for stored event: \(error)")
                            }
                            if !fieldEntries.isEmpty {
                                leaderboardEntries = GolfTiersEngine.computeLeaderboard(
                                    entries: fieldEntries,
                                    golferScores: liveGolferScores,
                                    golferStatuses: liveGolferStatuses,
                                    golferRoundScores: liveGolferRounds,
                                    currentUserID: userID
                                )
                            }
                            lastRefreshDate = Date()
                        }
                        isLoading = false
                        hasAttemptedLoad = true
                        return
                    }
                } catch {
                    print("[GolfTiers] ESPN fetch failed, using stored tournament: \(error)")
                    tournament = existing
                    isLoading = false
                    hasAttemptedLoad = true
                    return
                }
            } else {
                // No stored event ID — fresh fetch
                let (fetchedGolfers, fetchedEvent) = try await espnProvider.fetchMajorField()
                golfers = fetchedGolfers
                event = fetchedEvent
            }

            self.espnEvent = event
            guard !golfers.isEmpty else {
                error = "No major tournament field found. The PGA major may not have started yet."
                isLoading = false
                hasAttemptedLoad = true
                return
            }

            // Generate tiers
            tiers = GolfTiersEngine.generateTiers(from: golfers)
            print("[GolfTiers] Generated tiers: \(tiers.map { $0.count })")

            let lockTime = espnProvider.fetchLockTime(event: event)

            if var existing = loadedTournament {
                // Reset "locked" to "open" if lock time is still in the future
                if existing.status == "locked" && !existing.isSettled {
                    if let lt = lockTime, Date() < lt {
                        print("[GolfTiers] Resetting 'locked' to 'open' — lock time \(lt) is still in the future")
                        existing = GolfTiersTournament(
                            id: existing.id, title: existing.title, majorName: existing.majorName,
                            season: existing.season, status: "open", lockTime: lockTime,
                            espnEventID: existing.espnEventID, entryCount: existing.entryCount,
                            isSettled: false, createdAt: existing.createdAt
                        )
                        if let token = accessToken {
                            try? await SupabaseService.shared.updateGolfTiersTournamentStatus(
                                tournamentID: existing.id, status: "open", accessToken: token
                            )
                        }
                    }
                }
                // Update lockTime if we got a fresh one from ESPN
                if let lt = lockTime, lt != existing.lockTime {
                    existing = GolfTiersTournament(
                        id: existing.id, title: existing.title, majorName: existing.majorName,
                        season: existing.season, status: existing.status, lockTime: lt,
                        espnEventID: existing.espnEventID, entryCount: existing.entryCount,
                        isSettled: existing.isSettled, createdAt: existing.createdAt
                    )
                }
                tournament = existing
            } else {
                // Create new tournament
                let majorName = GolfTiersTournament.majorName(for: tournamentID)
                let title = GolfTiersTournament.majorTitle(for: tournamentID)
                let season = String(Calendar.current.component(.year, from: Date()))
                let newTournament = GolfTiersTournament(
                    id: tournamentID,
                    title: title,
                    majorName: majorName,
                    season: season,
                    status: "open",
                    lockTime: lockTime,
                    espnEventID: event?.id,
                    entryCount: 1000,
                    isSettled: false,
                    createdAt: Date()
                )
                tournament = newTournament

                // Save to Supabase
                if let token = accessToken {
                    let record = GolfTiersTournamentRecord(
                        id: newTournament.id,
                        title: newTournament.title,
                        majorName: newTournament.majorName,
                        season: newTournament.season,
                        status: newTournament.status,
                        lockTime: newTournament.lockTime,
                        espnEventID: newTournament.espnEventID,
                        entryCount: newTournament.entryCount
                    )
                    try? await SupabaseService.shared.upsertGolfTiersTournament(
                        record: record, accessToken: token
                    )
                }
            }

            // Check if user already has an entry
            if let token = accessToken, let uid = userID {
                if let existingEntry = try? await SupabaseService.shared.fetchUserGolfTiersEntry(
                    tournamentID: tournamentID, userID: uid, accessToken: token
                ) {
                    hasSubmitted = true
                    for pickData in existingEntry.picks {
                        let pick = pickData.toModel()
                        for tier in tiers {
                            if let golfer = tier.first(where: { $0.id == pick.playerID }) {
                                userPicks[pick.tier] = golfer
                                break
                            }
                        }
                    }
                }
            }

            // Auto-detect status transitions
            print("[GolfTiers] Before status check — status: \(tournament?.status ?? "nil"), lockTime: \(tournament?.lockTime?.description ?? "nil"), now: \(Date())")
            await checkStatusTransition()
            print("[GolfTiers] After status check — status: \(tournament?.status ?? "nil"), isLocked: \(isLocked)")

            // If locked/live, load field and scores
            if isLocked {
                await refreshLive()
                print("[GolfTiers] After refreshLive — fieldEntries: \(fieldEntries.count), bots: \(fieldEntries.filter({ $0.isBot }).count), leaderboard: \(leaderboardEntries.count)")
            } else {
                print("[GolfTiers] Tournament not locked — skipping refreshLive")
            }

        } catch {
            self.error = "Failed to load tournament: \(error.localizedDescription)"
            print("[GolfTiers] Error loading: \(error)")
        }

        isLoading = false
        hasAttemptedLoad = true
    }

    // MARK: - Pick Management

    func selectPlayer(tier: Int, golfer: GolfTiersGolfer) {
        guard !isLocked else { return }
        userPicks[tier] = golfer
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

        let picks = (1...6).compactMap { tier -> GolfTiersPickData? in
            guard let golfer = userPicks[tier] else { return nil }
            return GolfTiersPickData(
                tier: tier,
                playerID: golfer.id,
                playerName: golfer.name,
                playerCountry: golfer.country
            )
        }

        guard picks.count == 6 else {
            error = "Please select a golfer from each tier."
            isSubmitting = false
            return
        }

        do {
            let entryName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.submitGolfTiersEntry(
                tournamentID: tournament?.id ?? GolfTiersTournament.currentMajorID(),
                userID: uid,
                entryName: entryName,
                picks: picks,
                accessToken: token
            )
            hasSubmitted = true
            print("[GolfTiers] Picks submitted successfully")
        } catch {
            self.error = "Failed to submit picks: \(error.localizedDescription)"
            print("[GolfTiers] Submit error: \(error)")
        }

        isSubmitting = false
    }

    // MARK: - Live Refresh

    func refreshLive() async {
        guard let tournament else { return }

        // Load field entries if not yet loaded
        if !fieldGenerated {
            await loadFieldEntries()
        }

        // If user picks weren't restored yet, try multiple sources
        if userPicks.isEmpty {
            if let userFieldEntry = fieldEntries.first(where: { $0.isCurrentUser }) {
                for pick in userFieldEntry.picks {
                    for tier in tiers {
                        if let golfer = tier.first(where: { $0.id == pick.playerID }) {
                            userPicks[pick.tier] = golfer
                            break
                        }
                    }
                    if userPicks[pick.tier] == nil {
                        userPicks[pick.tier] = GolfTiersGolfer(
                            id: pick.playerID, name: pick.playerName, country: pick.playerCountry,
                            tier: pick.tier, owgrRank: 999, scoreToPar: 0, roundScores: [],
                            status: .active, imageURL: nil
                        )
                    }
                }
                hasSubmitted = true
            }
            // If still empty, fetch directly from entries table
            if userPicks.isEmpty, let uid = userID, let token = accessToken {
                if let record = try? await SupabaseService.shared.fetchUserGolfTiersEntry(
                    tournamentID: tournament.id, userID: uid, accessToken: token
                ) {
                    hasSubmitted = true
                    for pickData in record.picks {
                        let pick = pickData.toModel()
                        for tier in tiers {
                            if let golfer = tier.first(where: { $0.id == pick.playerID }) {
                                userPicks[pick.tier] = golfer
                                break
                            }
                        }
                        if userPicks[pick.tier] == nil {
                            userPicks[pick.tier] = GolfTiersGolfer(
                                id: pick.playerID, name: pick.playerName, country: pick.playerCountry,
                                tier: pick.tier, owgrRank: 999, scoreToPar: 0, roundScores: [],
                                status: .active, imageURL: nil
                            )
                        }
                    }
                    // Ensure user is in fieldEntries
                    if !fieldEntries.contains(where: { $0.isCurrentUser }) {
                        let userEntry = GolfTiersEntry(
                            id: UUID(uuidString: record.id) ?? UUID(),
                            tournamentID: record.tournamentID,
                            userID: record.userID,
                            entryName: record.entryName,
                            picks: record.picks.map { $0.toModel() },
                            totalScore: Int(record.totalPoints),
                            rank: record.rank,
                            isBot: false,
                            isCurrentUser: true
                        )
                        fieldEntries.insert(userEntry, at: 0)
                    }
                }
            }
        }

        // Safety net: if field is still empty after loadFieldEntries, force generate
        if fieldEntries.filter({ $0.isBot }).isEmpty && !tiers.isEmpty {
            print("[GolfTiers] refreshLive: no bots in field after load — forcing generation")
            await generateBotField()
        }

        // Fetch live scores from ESPN
        print("[GolfTiers] refreshLive: fieldEntries=\(fieldEntries.count), bots=\(fieldEntries.filter({ $0.isBot }).count), espnEventID=\(tournament.espnEventID ?? "nil"), espnEvent.id=\(espnEvent?.id ?? "nil")")
        if let eventID = tournament.espnEventID ?? espnEvent?.id {
            do {
                let snapshot = try await espnProvider.fetchLiveScores(espnEventID: eventID)
                liveGolferScores = snapshot.golferScoresToPar
                liveGolferRounds = snapshot.golferRoundScores
                liveGolferStatuses = snapshot.golferStatuses
                currentRound = snapshot.currentRound

                // Update tier golfer data with live scores
                for tierIndex in 0..<tiers.count {
                    for golferIndex in 0..<tiers[tierIndex].count {
                        let golfer = tiers[tierIndex][golferIndex]
                        if let score = snapshot.golferScoresToPar[golfer.id] {
                            tiers[tierIndex][golferIndex].scoreToPar = score
                        }
                        if let rounds = snapshot.golferRoundScores[golfer.id] {
                            tiers[tierIndex][golferIndex].roundScores = rounds
                        }
                        if let status = snapshot.golferStatuses[golfer.id] {
                            tiers[tierIndex][golferIndex].status = status
                        }
                    }
                }

                // Compute leaderboard
                leaderboardEntries = GolfTiersEngine.computeLeaderboard(
                    entries: fieldEntries,
                    golferScores: liveGolferScores,
                    golferStatuses: liveGolferStatuses,
                    golferRoundScores: liveGolferRounds,
                    currentUserID: userID
                )

                // Check if tournament is complete → settle
                if tournament.status == "live" && snapshot.isTournamentComplete {
                    await settle()
                }
            } catch {
                print("[GolfTiers] Error fetching live scores: \(error)")
            }
        } else {
            print("[GolfTiers] No ESPN event ID available — skipping live scores fetch")
            // Still compute leaderboard from field entries with current scores (may be zeros)
            if !fieldEntries.isEmpty {
                leaderboardEntries = GolfTiersEngine.computeLeaderboard(
                    entries: fieldEntries,
                    golferScores: liveGolferScores,
                    golferStatuses: liveGolferStatuses,
                    golferRoundScores: liveGolferRounds,
                    currentUserID: userID
                )
            }
        }

        lastRefreshDate = Date()
    }

    // MARK: - Load Field Entries

    private func loadFieldEntries() async {
        guard let tournament else { return }
        let token = accessToken

        // Try loading from entries table first (500+ = complete field) — requires auth
        if let token {
            if let records = try? await SupabaseService.shared.fetchGolfTiersEntries(
                tournamentID: tournament.id, accessToken: token
            ), records.count >= 500 {
                fieldEntries = records.map { record in
                    GolfTiersEntry(
                        id: UUID(uuidString: record.id) ?? UUID(),
                        tournamentID: record.tournamentID,
                        userID: record.userID,
                        entryName: record.entryName,
                        picks: record.picks.map { $0.toModel() },
                        totalScore: Int(record.totalPoints),
                        rank: record.rank,
                        isBot: record.isBot,
                        isCurrentUser: record.userID == userID
                    )
                }
                fieldGenerated = true
                print("[GolfTiers] Loaded \(fieldEntries.count) entries from entries table")
                return
            }

            // Try restoring from bot_field JSON column
            do {
                let botField = try await SupabaseService.shared.fetchGolfTiersBotField(
                    tournamentID: tournament.id, accessToken: token
                )
                print("[GolfTiers] bot_field fetch returned \(botField.count) entries")
                if !botField.isEmpty {
                    let restoredEntries = parseBotFieldData(botField, tournamentID: tournament.id)
                    if !restoredEntries.isEmpty {
                        let userEntry = await buildUserEntry(tournamentID: tournament.id, token: token)
                        if let userEntry {
                            fieldEntries = [userEntry] + restoredEntries
                        } else {
                            fieldEntries = restoredEntries
                        }
                        fieldGenerated = true
                        print("[GolfTiers] Restored \(restoredEntries.count) bots from tournament bot_field")
                        Task { await backfillEntriesToServer(bots: restoredEntries, tournamentID: tournament.id, token: token) }
                        return
                    }
                }
            } catch {
                print("[GolfTiers] bot_field fetch failed: \(error)")
            }
        }

        // Try local cache (works without auth)
        if !fieldGenerated {
            if let cachedBots = loadBotCacheLocally(tournamentID: tournament.id), !cachedBots.isEmpty {
                print("[GolfTiers] Restoring \(cachedBots.count) bots from local cache")
                let restoredEntries = parseBotFieldData(cachedBots, tournamentID: tournament.id)
                if !restoredEntries.isEmpty {
                    if let token {
                        let userEntry = await buildUserEntry(tournamentID: tournament.id, token: token)
                        if let userEntry {
                            fieldEntries = [userEntry] + restoredEntries
                        } else {
                            fieldEntries = restoredEntries
                        }
                        Task { await backfillEntriesToServer(bots: restoredEntries, tournamentID: tournament.id, token: token) }
                    } else {
                        fieldEntries = restoredEntries
                    }
                    fieldGenerated = true
                    return
                }
            }
        }

        // Always generate fresh bots if we still have none after all restore attempts
        if fieldEntries.filter({ $0.isBot }).isEmpty {
            print("[GolfTiers] No bots after all restore paths — generating fresh field")
            await generateBotField()
        }
    }

    /// Parse bot field data from JSON array (used by both server bot_field and local cache)
    private func parseBotFieldData(_ botField: [[String: Any]], tournamentID: String) -> [GolfTiersEntry] {
        var restoredEntries: [GolfTiersEntry] = []
        for botData in botField {
            guard let name = botData["name"] as? String,
                  let picksRaw = botData["picks"] as? [[String: Any]] else { continue }
            let picks = picksRaw.compactMap { p -> GolfTiersPick? in
                let tier: Int
                if let t = p["tier"] as? Int {
                    tier = t
                } else if let t = p["tier"] as? Double {
                    tier = Int(t)
                } else { return nil }
                guard let playerID = p["player_id"] as? String,
                      let playerName = p["player_name"] as? String,
                      let playerCountry = p["player_country"] as? String else { return nil }
                return GolfTiersPick(tier: tier, playerID: playerID, playerName: playerName, playerCountry: playerCountry)
            }
            guard picks.count == 6 else { continue }
            restoredEntries.append(GolfTiersEntry(
                id: UUID(), tournamentID: tournamentID, userID: nil,
                entryName: name, picks: picks, totalScore: 0, rank: 0,
                isBot: true, isCurrentUser: false
            ))
        }
        return restoredEntries
    }

    /// Build the user's entry from userPicks or from a direct Supabase fetch.
    private func buildUserEntry(tournamentID: String, token: String) async -> GolfTiersEntry? {
        guard let uid = userID else { return nil }

        // First try: build from userPicks
        if hasSubmitted && userPicks.count == 6 {
            return GolfTiersEntry(
                id: UUID(), tournamentID: tournamentID, userID: uid,
                entryName: profileName.isEmpty ? "Player" : profileName,
                picks: (1...6).compactMap { tier -> GolfTiersPick? in
                    guard let golfer = userPicks[tier] else { return nil }
                    return GolfTiersPick(tier: tier, playerID: golfer.id, playerName: golfer.name, playerCountry: golfer.country)
                },
                totalScore: 0, rank: 0, isBot: false, isCurrentUser: true
            )
        }

        // Second try: fetch from entries table
        if let record = try? await SupabaseService.shared.fetchUserGolfTiersEntry(
            tournamentID: tournamentID, userID: uid, accessToken: token
        ) {
            hasSubmitted = true
            // Restore userPicks from this entry
            for pickData in record.picks {
                let pick = pickData.toModel()
                for tier in tiers {
                    if let golfer = tier.first(where: { $0.id == pick.playerID }) {
                        userPicks[pick.tier] = golfer
                        break
                    }
                }
                if userPicks[pick.tier] == nil {
                    userPicks[pick.tier] = GolfTiersGolfer(
                        id: pick.playerID, name: pick.playerName, country: pick.playerCountry,
                        tier: pick.tier, owgrRank: 999, scoreToPar: 0, roundScores: [],
                        status: .active, imageURL: nil
                    )
                }
            }
            return GolfTiersEntry(
                id: UUID(uuidString: record.id) ?? UUID(),
                tournamentID: record.tournamentID, userID: record.userID,
                entryName: record.entryName,
                picks: record.picks.map { $0.toModel() },
                totalScore: Int(record.totalPoints), rank: record.rank,
                isBot: false, isCurrentUser: true
            )
        }

        return nil
    }

    /// Backfill entries table from fallback bot list.
    private func backfillEntriesToServer(bots: [GolfTiersEntry], tournamentID: String, token: String) async {
        let botPayloads: [(name: String, picks: [GolfTiersPickData])] = bots.map { entry in
            (name: entry.entryName, picks: entry.picks.map { GolfTiersPickData(from: $0) })
        }
        do {
            let existing = try? await SupabaseService.shared.fetchGolfTiersEntries(
                tournamentID: tournamentID, accessToken: token
            )
            if (existing?.count ?? 0) >= 500 {
                print("[GolfTiers] Entries table already has \(existing?.count ?? 0) entries, skipping backfill")
                return
            }
            try await SupabaseService.shared.deleteGolfTiersBotEntries(
                tournamentID: tournamentID, accessToken: token
            )
            try await SupabaseService.shared.batchInsertGolfTiersBotEntries(
                tournamentID: tournamentID, bots: botPayloads, accessToken: token
            )
            print("[GolfTiers] Backfilled \(bots.count) bots to entries table")
        } catch {
            print("[GolfTiers] Backfill failed: \(error)")
        }
    }

    // MARK: - Generate Bot Field

    private func generateBotField() async {
        guard let tournament else {
            print("[GolfTiers] generateBotField: no tournament")
            return
        }
        guard !tiers.isEmpty else {
            print("[GolfTiers] generateBotField: tiers is empty")
            return
        }
        // If some tiers are empty, fill them with golfers from adjacent tiers
        // so bot generation doesn't fail for partially loaded fields.
        var safeTiers = tiers
        for i in 0..<safeTiers.count {
            if safeTiers[i].isEmpty {
                // Borrow from the nearest non-empty tier
                let donor = safeTiers.first(where: { !$0.isEmpty })
                if let donor, let borrowed = donor.last {
                    let filler = GolfTiersGolfer(
                        id: borrowed.id, name: borrowed.name, country: borrowed.country,
                        tier: i + 1, owgrRank: borrowed.owgrRank, scoreToPar: borrowed.scoreToPar,
                        roundScores: borrowed.roundScores, status: borrowed.status, imageURL: borrowed.imageURL
                    )
                    safeTiers[i] = [filler]
                    print("[GolfTiers] generateBotField: filled empty tier \(i + 1) with \(borrowed.name)")
                }
            }
        }
        guard safeTiers.allSatisfy({ !$0.isEmpty }) else {
            print("[GolfTiers] generateBotField: still have empty tiers after filling, aborting")
            return
        }
        guard fieldEntries.filter({ $0.isBot }).isEmpty else {
            print("[GolfTiers] Skipping generateBotField — already have \(fieldEntries.filter({ $0.isBot }).count) bots")
            fieldGenerated = true
            return
        }

        print("[GolfTiers] Generating bot field with \(safeTiers.map(\.count)) golfers per tier...")
        var botEntries = GolfTiersBotDrafter.generateBotEntries(tiers: safeTiers, count: 999, tournamentID: tournament.id)

        botEntries = botEntries.map { entry in
            GolfTiersEntry(
                id: entry.id, tournamentID: tournament.id, userID: nil,
                entryName: entry.entryName, picks: entry.picks,
                totalScore: 0, rank: 0, isBot: true, isCurrentUser: false
            )
        }

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
        print("[GolfTiers] Generated \(botEntries.count) bot entries (fieldEntries total: \(fieldEntries.count))")

        // Save to entries table and bot_field (only if authenticated)
        guard let token = accessToken else {
            // Still save to local cache even without auth
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
            print("[GolfTiers] Saved bots to local cache (no auth token for server save)")
            return
        }

        let botPayloads: [(name: String, picks: [GolfTiersPickData])] = botEntries.map { entry in
            (name: entry.entryName, picks: entry.picks.map { GolfTiersPickData(from: $0) })
        }
        do {
            try await SupabaseService.shared.deleteGolfTiersBotEntries(
                tournamentID: tournament.id, accessToken: token
            )
            try await SupabaseService.shared.batchInsertGolfTiersBotEntries(
                tournamentID: tournament.id, bots: botPayloads, accessToken: token
            )
            print("[GolfTiers] Saved \(botEntries.count) bots to entries table")
        } catch {
            print("[GolfTiers] Failed to save bots to entries table: \(error)")
        }

        // Save to bot_field column and local cache as fallbacks
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
        do {
            try await SupabaseService.shared.saveGolfTiersBotField(
                tournamentID: tournament.id, botField: botPicksData, accessToken: token
            )
        } catch {
            print("[GolfTiers] Failed to save bot_field fallback: \(error)")
        }
    }

    /// Public re-check for when the LobbyView appears after loadTournament already ran.
    func recheckStatusIfNeeded() async {
        guard tournament != nil else { return }
        if tournament?.status == "open" {
            let lockTime = espnProvider.fetchLockTime(event: espnEvent)
            if let lt = lockTime, lt != tournament?.lockTime {
                tournament = GolfTiersTournament(
                    id: tournament!.id, title: tournament!.title, majorName: tournament!.majorName,
                    season: tournament!.season, status: tournament!.status, lockTime: lt,
                    espnEventID: tournament!.espnEventID, entryCount: tournament!.entryCount,
                    isSettled: tournament!.isSettled, createdAt: tournament!.createdAt
                )
            }
        }
        await checkStatusTransition()
        if isLocked && !isSettled {
            await refreshLive()
        }
    }

    // MARK: - Status Transitions

    private func checkStatusTransition() async {
        guard let tournament else { return }

        // open → locked
        if tournament.status == "open", let lockTime = tournament.lockTime, Date() >= lockTime {
            self.tournament = GolfTiersTournament(
                id: tournament.id, title: tournament.title, majorName: tournament.majorName,
                season: tournament.season, status: "locked", lockTime: tournament.lockTime,
                espnEventID: tournament.espnEventID, entryCount: tournament.entryCount,
                isSettled: false, createdAt: tournament.createdAt
            )
            if let token = accessToken {
                try? await SupabaseService.shared.updateGolfTiersTournamentStatus(
                    tournamentID: tournament.id, status: "locked", accessToken: token
                )
            }
        }

        // locked → live (tournament started)
        if self.tournament?.status == "locked" {
            if let eventID = tournament.espnEventID ?? espnEvent?.id {
                let started = await espnProvider.hasTournamentStarted(espnEventID: eventID)
                if started {
                    self.tournament = GolfTiersTournament(
                        id: tournament.id, title: tournament.title, majorName: tournament.majorName,
                        season: tournament.season, status: "live", lockTime: tournament.lockTime,
                        espnEventID: tournament.espnEventID, entryCount: tournament.entryCount,
                        isSettled: false, createdAt: tournament.createdAt
                    )
                    if let token = accessToken {
                        try? await SupabaseService.shared.updateGolfTiersTournamentStatus(
                            tournamentID: tournament.id, status: "live", accessToken: token
                        )
                    }
                }
            }
        }

        // live → settled (time-based fallback: golf major lasts 4 days, settle after 5)
        // This catches tournaments that finished while no user had the app open.
        if self.tournament?.status == "live", let lockTime = self.tournament?.lockTime {
            let daysSinceLock = Date().timeIntervalSince(lockTime) / 86400
            if daysSinceLock >= 5 {
                print("[GolfTiers] Tournament has been live for \(Int(daysSinceLock)) days — auto-settling")
                await settle()
            }
        }
    }

    // MARK: - Settlement

    private func settle() async {
        guard let tournament, !tournament.isSettled else { return }
        guard let token = accessToken else { return }

        print("[GolfTiers] Settling tournament \(tournament.id)")

        // Compute final leaderboard
        let finalLeaderboard = GolfTiersEngine.computeLeaderboard(
            entries: fieldEntries,
            golferScores: liveGolferScores,
            golferStatuses: liveGolferStatuses,
            golferRoundScores: liveGolferRounds,
            currentUserID: userID
        )
        leaderboardEntries = finalLeaderboard

        // Calculate RR delta for user
        if let userEntry = finalLeaderboard.first(where: { $0.isCurrentUser }) {
            let rrDelta = GolfTiersEngine.rrDelta(forRank: userEntry.rank, totalEntries: finalLeaderboard.count)
            rrScore += rrDelta

            // Save to DFS history
            let result = DFSResult(
                id: UUID(),
                tournamentTitle: tournament.title,
                rank: userEntry.rank,
                totalEntries: finalLeaderboard.count,
                lineupPoints: Double(userEntry.totalScore),
                rrDelta: rrDelta,
                loggedAt: Date(),
                tournamentId: tournament.id
            )
            appendToHistory(result)
            markTournamentSettled(tournament.id)

            // Also save to Supabase dfs_tournament_results so it appears on the profile
            if let uid = userID {
                // Upsert a dfs_tournaments record so the profile can find the title
                let tournamentRecord = DFSTournamentRecord(
                    id: tournament.id,
                    title: tournament.title,
                    league: "golf-tiers",
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
                    totalPoints: Double(userEntry.totalScore),
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
        self.tournament = GolfTiersTournament(
            id: tournament.id, title: tournament.title, majorName: tournament.majorName,
            season: tournament.season, status: "settled", lockTime: tournament.lockTime,
            espnEventID: tournament.espnEventID, entryCount: tournament.entryCount,
            isSettled: true, createdAt: tournament.createdAt
        )

        try? await SupabaseService.shared.markGolfTiersTournamentSettled(
            tournamentID: tournament.id, accessToken: token
        )

        // Update entry scores on server
        let updates = finalLeaderboard.map { entry in
            (id: entry.id.uuidString, totalPoints: Double(entry.totalScore), rank: entry.rank)
        }
        try? await SupabaseService.shared.updateGolfTiersEntryScores(
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

    var groupLeaderboard: [GolfTiersLeaderboardEntry] {
        guard !currentGroupMembers.isEmpty else { return [] }
        let memberUserIDs = Set(currentGroupMembers.map { $0.userID })
        let filtered = leaderboardEntries.filter { entry in
            if entry.isCurrentUser, let uid = userID {
                return memberUserIDs.contains(uid)
            }
            if let fieldEntry = fieldEntries.first(where: { $0.id == entry.id }) {
                if let entryUserID = fieldEntry.userID {
                    return memberUserIDs.contains(entryUserID)
                }
            }
            return false
        }
        // Re-rank within the group (ascending — lowest score wins)
        let sorted = filtered.sorted { $0.totalScore < $1.totalScore }
        return sorted.enumerated().map { index, entry in
            GolfTiersLeaderboardEntry(
                id: entry.id,
                entryName: entry.entryName,
                picks: entry.picks,
                totalScore: entry.totalScore,
                rank: index + 1,
                isCurrentUser: entry.isCurrentUser,
                pickScores: entry.pickScores,
                countingPicks: entry.countingPicks
            )
        }
    }

    // MARK: - Settled History

    func loadSettledHistory() async {
        guard let token = accessToken, let uid = userID else { return }
        guard !isLoadingHistory else { return }
        isLoadingHistory = true

        do {
            let tournaments = try await SupabaseService.shared.fetchSettledGolfTiersTournaments(
                accessToken: token
            )
            settledTournaments = tournaments
            print("[GolfTiers] loadSettledHistory: found \(tournaments.count) settled tournament(s)")

            // Fetch user result for each settled tournament concurrently
            // Try dfs_tournament_results first, fall back to golf_tiers_entries
            await withTaskGroup(of: (String, DFSTournamentResultRecord?).self) { group in
                for t in tournaments {
                    group.addTask {
                        // First try dfs_tournament_results
                        if let result = try? await SupabaseService.shared.fetchUserGolfTiersResult(
                            tournamentID: t.id, userID: uid, accessToken: token
                        ) {
                            print("[GolfTiers] Found dfs_tournament_results for \(t.id): rank=\(result.rank), pts=\(result.totalPoints)")
                            return (t.id, result)
                        }

                        // Fall back: build result from golf_tiers_entries
                        if let entry = try? await SupabaseService.shared.fetchUserGolfTiersEntry(
                            tournamentID: t.id, userID: uid, accessToken: token
                        ) {
                            print("[GolfTiers] Fallback to entries for \(t.id): rank=\(entry.rank), pts=\(entry.totalPoints)")
                            let fallbackResult = DFSTournamentResultRecord(
                                id: entry.id,
                                tournamentID: t.id,
                                userID: uid,
                                entryName: entry.entryName,
                                lineupPlayerIDs: entry.picks.map { $0.playerID },
                                lineupPlayerNames: entry.picks.map { $0.playerName },
                                totalPoints: entry.totalPoints,
                                playerPoints: nil,
                                playerSalaries: nil,
                                rank: entry.rank,
                                rrDelta: 0,
                                isCurrentUser: true,
                                isBot: false,
                                createdAt: entry.createdAt
                            )
                            return (t.id, fallbackResult)
                        }
                        print("[GolfTiers] No result found for \(t.id)")
                        return (t.id, nil)
                    }
                }
                for await (tid, result) in group {
                    if let result {
                        settledResults[tid] = result
                    }
                }
            }
        } catch {
            print("[GolfTiers] Failed to load settled history: \(error)")
        }

        // Also populate results from the local DFS history for any tournaments still missing
        print("[GolfTiers] settledResults has \(settledResults.count) entries, leaderboard has \(leaderboardEntries.count) entries")
        let localHistory = (try? JSONDecoder().decode([DFSResult].self, from: dfsHistoryData)) ?? []
        for t in settledTournaments where settledResults[t.id] == nil {
            if let localResult = localHistory.first(where: { $0.tournamentId == t.id }) {
                print("[GolfTiers] Using local history for \(t.id): rank=\(localResult.rank), pts=\(localResult.lineupPoints), rr=\(localResult.rrDelta)")
                settledResults[t.id] = DFSTournamentResultRecord(
                    id: localResult.id.uuidString,
                    tournamentID: t.id,
                    userID: uid,
                    entryName: profileName.isEmpty ? "Player" : profileName,
                    lineupPlayerIDs: [],
                    lineupPlayerNames: [],
                    totalPoints: localResult.lineupPoints,
                    playerPoints: nil,
                    playerSalaries: nil,
                    rank: localResult.rank,
                    rrDelta: localResult.rrDelta,
                    isCurrentUser: true,
                    isBot: false,
                    createdAt: localResult.loggedAt
                )
            }
        }

        // Last resort: populate from the already-loaded leaderboard for the current tournament
        if let currentTournament = tournament, currentTournament.isSettled,
           settledResults[currentTournament.id] == nil,
           let userEntry = leaderboardEntries.first(where: { $0.isCurrentUser }) {
            print("[GolfTiers] Building result from leaderboard: rank=\(userEntry.rank), score=\(userEntry.totalScore)")
            let totalEntries = leaderboardEntries.count
            let rrDelta = GolfTiersEngine.rrDelta(forRank: userEntry.rank, totalEntries: totalEntries)
            settledResults[currentTournament.id] = DFSTournamentResultRecord(
                id: userEntry.id.uuidString,
                tournamentID: currentTournament.id,
                userID: uid,
                entryName: userEntry.entryName,
                lineupPlayerIDs: userEntry.picks.map { $0.playerID },
                lineupPlayerNames: userEntry.picks.map { $0.playerName },
                totalPoints: Double(userEntry.totalScore),
                playerPoints: nil,
                playerSalaries: nil,
                rank: userEntry.rank,
                rrDelta: rrDelta,
                isCurrentUser: true,
                isBot: false,
                createdAt: Date()
            )
        }

        isLoadingHistory = false
    }

    // MARK: - Groups

    func loadMyGroups() async {
        guard let token = accessToken, let uid = userID else { return }
        let tournamentID = tournament?.id ?? GolfTiersTournament.currentMajorID()

        do {
            let records = try await SupabaseService.shared.fetchMyGolfTiersGroups(
                userID: uid, tournamentID: tournamentID, accessToken: token
            )
            myGroups = records.map { $0.toModel() }
        } catch {
            print("[GolfTiers] Failed to load groups: \(error)")
        }
    }

    func createGroup(name: String) async -> GolfTiersGroup? {
        guard let token = accessToken, let uid = userID else {
            groupError = "Please sign in to create a group."
            return nil
        }
        let tournamentID = tournament?.id ?? GolfTiersTournament.currentMajorID()
        isCreatingGroup = true
        groupError = nil

        do {
            let code = generateInviteCode()
            let record = try await SupabaseService.shared.createGolfTiersGroup(
                tournamentID: tournamentID,
                name: name,
                createdBy: uid,
                inviteCode: code,
                maxMembers: 20,
                accessToken: token
            )
            let group = record.toModel()

            let displayName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.joinGolfTiersGroup(
                groupID: record.id, userID: uid, displayName: displayName, accessToken: token
            )

            myGroups.insert(group, at: 0)
            isCreatingGroup = false
            return group
        } catch {
            groupError = "Failed to create group: \(error.localizedDescription)"
            print("[GolfTiers] Create group error: \(error)")
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
            guard let record = try await SupabaseService.shared.fetchGolfTiersGroupByInviteCode(
                code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                accessToken: token
            ) else {
                groupError = "No group found with that code."
                isJoiningGroup = false
                return false
            }

            let members = try await SupabaseService.shared.fetchGolfTiersGroupMembers(
                groupID: record.id, accessToken: token
            )
            if members.contains(where: { $0.userID == uid }) {
                groupError = "You're already in this group."
                isJoiningGroup = false
                return false
            }
            if members.count >= record.maxMembers {
                groupError = "This group is full."
                isJoiningGroup = false
                return false
            }

            let displayName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.joinGolfTiersGroup(
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
            print("[GolfTiers] Join group error: \(error)")
            isJoiningGroup = false
            return false
        }
    }

    func loadGroupDetail(_ group: GolfTiersGroup) async {
        guard let token = accessToken else { return }
        currentGroup = group

        do {
            let memberRecords = try await SupabaseService.shared.fetchGolfTiersGroupMembers(
                groupID: group.id.uuidString, accessToken: token
            )
            currentGroupMembers = memberRecords.map { $0.toModel() }
        } catch {
            print("[GolfTiers] Failed to load group members: \(error)")
            currentGroupMembers = []
        }
    }

    func leaveGroup(_ group: GolfTiersGroup) async {
        guard let token = accessToken, let uid = userID else { return }

        do {
            try await SupabaseService.shared.leaveGolfTiersGroup(
                groupID: group.id.uuidString, userID: uid, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id {
                currentGroup = nil
                currentGroupMembers = []
            }
        } catch {
            print("[GolfTiers] Failed to leave group: \(error)")
        }
    }

    func deleteGroup(_ group: GolfTiersGroup) async {
        guard let token = accessToken else { return }

        do {
            try await SupabaseService.shared.deleteGolfTiersGroup(
                groupID: group.id.uuidString, accessToken: token
            )
            myGroups.removeAll { $0.id == group.id }
            if currentGroup?.id == group.id {
                currentGroup = nil
                currentGroupMembers = []
            }
        } catch {
            print("[GolfTiers] Failed to delete group: \(error)")
        }
    }

    private func generateInviteCode() -> String {
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in characters.randomElement()! })
    }
}
