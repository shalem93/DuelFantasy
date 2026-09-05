import Foundation
import SwiftUI

/// NFL Best Ball Tournament — season-long salary-cap best ball against a
/// 2,000-bot field. Client-driven like every other mode: this VM mints the
/// season's tournament row on first sight, prices the pool, generates and
/// persists the bot field, scores every week from ESPN box scores (cached
/// server-side once a week is final), and settles RR through the fantasy
/// ledger at season end.
@MainActor
@Observable
final class BestBallTournamentViewModel {
    // Auth (synced from ContentView)
    var userID: String?
    var accessToken: String?
    var profileName: String = ""

    var tournament: BBTTournamentRecord?
    var pool: [BBTPlayer] = []
    /// Every real user's entries (including mine).
    var userEntries: [BBTEntry] = []
    var bots: [BBTEntry] = []
    /// week → playerID → points (weeks with any data).
    var weekPoints: [Int: [String: Double]] = [:]
    var standings: [BBTStanding] = []
    var isLoading = false
    var isScoring = false
    var isSubmitting = false
    var hasAttemptedLoad = false
    var error: String?
    var lastScoredAt: Date?

    private let playerProvider = ESPNBestBallPlayerProvider()
    private let scoringProvider = ESPNBestBallWeeklyScoringProvider()
    private var scoringTask: Task<Void, Never>?

    // MARK: - Derived

    var lockTime: Date { tournament?.lockTime ?? BBTConfig.lockTime }
    var isLocked: Bool { Date() >= lockTime }
    var isSettled: Bool { tournament?.status == "settled" }
    var isLive: Bool { isLocked && !isSettled }
    var myEntries: [BBTEntry] { userEntries.filter { $0.isCurrentUser }.sorted { $0.entryNumber < $1.entryNumber } }
    var hasEntered: Bool { !myEntries.isEmpty }
    var canAddEntry: Bool { !isLocked && !isSettled && myEntries.count < BBTConfig.maxEntriesPerUser && accessToken != nil }
    var fieldSize: Int { userEntries.count + bots.count }
    var myStandings: [BBTStanding] { standings.filter { $0.entry.isCurrentUser } }
    var bestRank: Int? { myStandings.map(\.rank).min() }
    var currentWeek: Int { min(BBTConfig.totalWeeks, BestBallSeasonHelper.currentWeekNumber(for: "NFL")) }
    var statusLabel: String {
        if isSettled { return "FINAL" }
        if isLocked { return "LIVE" }
        return "OPEN"
    }

    // MARK: - Load

    func loadAll(force: Bool = false) async {
        guard let token = accessToken else { return }
        if isLoading { return }
        if hasAttemptedLoad, !force, !pool.isEmpty { await refreshScores(); return }
        isLoading = true
        defer { isLoading = false; hasAttemptedLoad = true }
        error = nil
        do {
            // 1. Tournament row (mint once per season).
            if let rec = try await SupabaseService.shared.fetchBBTTournament(id: BBTConfig.tournamentID, accessToken: token) {
                tournament = rec
            } else {
                let rec = BBTTournamentRecord(id: BBTConfig.tournamentID, title: BBTConfig.title, season: BBTConfig.season, status: "open", lockTime: BBTConfig.lockTime)
                try await SupabaseService.shared.ensureBBTTournament(record: rec, accessToken: token)
                tournament = (try? await SupabaseService.shared.fetchBBTTournament(id: BBTConfig.tournamentID, accessToken: token)) ?? rec
            }
            // Status roll-forward: open → live at lock (any client may flip it).
            if let t = tournament, t.status == "open", Date() >= (t.lockTime ?? BBTConfig.lockTime) {
                try? await SupabaseService.shared.updateBBTTournamentStatus(id: t.id, status: "live", accessToken: token)
                tournament = BBTTournamentRecord(id: t.id, title: t.title, season: t.season, status: "live", lockTime: t.lockTime)
            }

            // 2. Priced pool.
            if pool.isEmpty || force {
                let players = try await playerProvider.fetchPlayers(sport: "NFL", cfbPool: nil)
                pool = BBTPricing.pricedPool(from: players)
            }

            // 3. Entries + bots.
            await loadEntries()
            await loadOrGenerateBots()

            // 4. Scores.
            await refreshScores()
        } catch {
            self.error = error.localizedDescription
            print("[BBT] load failed: \(error)")
        }
    }

    func loadEntries() async {
        guard let token = accessToken else { return }
        do {
            let records = try await SupabaseService.shared.fetchBBTEntries(tournamentID: BBTConfig.tournamentID, accessToken: token)
            userEntries = records.map { r in
                BBTEntry(id: r.id, userID: r.userID, entryName: r.entryName, entryNumber: r.entryNumber,
                         picks: r.picks, isBot: false, isCurrentUser: r.userID == userID)
            }
        } catch {
            print("[BBT] entries fetch failed: \(error)")
        }
    }

    // MARK: - Bots

    private static func botCacheURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("bbt_bots_\(BBTConfig.tournamentID)_v1.json")
    }

    private func loadOrGenerateBots() async {
        guard bots.isEmpty, let token = accessToken, !pool.isEmpty else { return }
        // Server first (shared field), then local cache, then generate.
        if let field = try? await SupabaseService.shared.fetchBBTBotField(id: BBTConfig.tournamentID, accessToken: token),
           field.count >= 500 {
            bots = restoreBots(from: field)
            try? JSONSerialization.data(withJSONObject: field).write(to: Self.botCacheURL() ?? URL(fileURLWithPath: "/dev/null"))
            return
        }
        if let url = Self.botCacheURL(), let data = try? Data(contentsOf: url),
           let field = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], field.count >= 500 {
            bots = restoreBots(from: field)
            return
        }
        let poolSnapshot = pool
        let generated = await Task.detached(priority: .userInitiated) {
            BBTBotDrafter.generate(pool: poolSnapshot, seedSalt: BBTConfig.tournamentID)
        }.value
        bots = generated
        // Compact persisted shape: name + player ids (prices resolve from the pool).
        let field: [[String: Any]] = generated.map { ["n": $0.entryName, "p": $0.picks.map(\.playerID)] }
        if let data = try? JSONSerialization.data(withJSONObject: field), let url = Self.botCacheURL() {
            try? data.write(to: url)
        }
        try? await SupabaseService.shared.saveBBTBotField(id: BBTConfig.tournamentID, botField: field, accessToken: token)
        print("[BBT] generated + saved \(generated.count) bots")
    }

    private func restoreBots(from field: [[String: Any]]) -> [BBTEntry] {
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [BBTEntry] = []
        out.reserveCapacity(field.count)
        for (i, bot) in field.enumerated() {
            guard let name = bot["n"] as? String, let ids = bot["p"] as? [String] else { continue }
            let picks: [BBTPick] = ids.compactMap { id in
                guard let p = byID[id] else { return nil }
                return BBTPick(playerID: p.id, name: p.name, team: p.team, position: p.position, price: p.price)
            }
            guard picks.count >= 10 else { continue }
            out.append(BBTEntry(id: "bot-\(i)", userID: nil, entryName: name, entryNumber: 1, picks: picks, isBot: true, isCurrentUser: false))
        }
        return out
    }

    // MARK: - Scoring

    /// Weeks 1…current: finalized weeks come from the shared server cache
    /// (any client writes it once), the in-progress week refetches live.
    func refreshScores() async {
        guard let token = accessToken, isLocked else {
            // Pre-lock: nothing to score; standings are just the field.
            standings = await BBTScoringEngine.standingsAsync(entries: userEntries + bots, weekPointsByWeek: [:])
            return
        }
        if isScoring { return }
        isScoring = true
        defer { isScoring = false }

        let cached = (try? await SupabaseService.shared.fetchBBTWeekPoints(tournamentID: BBTConfig.tournamentID, accessToken: token)) ?? []
        for rec in cached where rec.isFinal { weekPoints[rec.week] = rec.playerPoints }

        let lastWeek = currentWeek
        for week in 1...max(1, lastWeek) {
            if let cachedFinal = cached.first(where: { $0.week == week && $0.isFinal }), !cachedFinal.playerPoints.isEmpty { continue }
            let (start, end) = BestBallSeasonHelper.weekDateRange(sport: "NFL", week: week)
            guard Date() >= start else { continue }
            let weekEnded = Date() > (Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end)
            guard let result = try? await scoringProvider.fetchWeeklyAllPlayerStats(
                sport: "NFL", weekStartDate: start, weekEndDate: end, restrictToPlayerIDs: nil
            ) else { continue }
            // Zero-clobber: never replace real points with an empty fetch.
            if result.playerPoints.isEmpty, !(weekPoints[week] ?? [:]).isEmpty { continue }
            weekPoints[week] = result.playerPoints
            if weekEnded, !result.playerPoints.isEmpty {
                try? await SupabaseService.shared.upsertBBTWeekPoints(
                    record: BBTWeekPointsRecord(tournamentID: BBTConfig.tournamentID, week: week, playerPoints: result.playerPoints, isFinal: true),
                    accessToken: token
                )
            }
        }

        standings = await BBTScoringEngine.standingsAsync(entries: userEntries + bots, weekPointsByWeek: weekPoints)
        lastScoredAt = Date()
        await persistMyScores()
        await settleIfSeasonOver()
    }

    private func persistMyScores() async {
        guard let token = accessToken else { return }
        for s in myStandings {
            try? await SupabaseService.shared.updateBBTEntryScore(entryID: s.entry.id, totalPoints: s.totalPoints, rank: s.rank, accessToken: token)
        }
    }

    func startLivePolling() {
        stopLivePolling()
        scoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, self.isLive else { continue }
                await self.refreshScores()
            }
        }
    }

    func stopLivePolling() {
        scoringTask?.cancel()
        scoringTask = nil
    }

    // MARK: - Entry

    /// Validates and submits a roster as the user's next entry, charging
    /// the entry fee through the idempotent fantasy ledger.
    func submitEntry(picks: [BBTPlayer]) async -> Bool {
        guard let uid = userID, let token = accessToken else { error = "Sign in to enter"; return false }
        guard canAddEntry else { error = isLocked ? "Entries are locked" : "Entry limit reached (\(BBTConfig.maxEntriesPerUser))"; return false }
        if let v = BBTRosterRules.violation(for: picks) { error = v; return false }
        let ids = Set(picks.map(\.id))
        if myEntries.contains(where: { Set($0.picks.map(\.playerID)) == ids }) {
            error = "You already have this exact roster — change at least one player"
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let number = (myEntries.map(\.entryNumber).max() ?? 0) + 1
        let base = profileName.isEmpty ? "Player" : profileName
        let name = number == 1 ? base : "\(base) #\(number)"
        let bbtPicks = picks.map { BBTPick(playerID: $0.id, name: $0.name, team: $0.team, position: $0.position, price: $0.price) }
        do {
            let rec = try await SupabaseService.shared.insertBBTEntry(
                tournamentID: BBTConfig.tournamentID, userID: uid, entryName: name,
                entryNumber: number, picks: bbtPicks, accessToken: token
            )
            try? await SupabaseService.shared.insertFantasyLedgerRow(
                userID: uid, refID: rec.id, kind: "bbt_entry", rrDelta: -BBTConfig.entryFeeRR, accessToken: token
            )
            await refreshFantasyDelta()
            await loadEntries()
            standings = await BBTScoringEngine.standingsAsync(entries: userEntries + bots, weekPointsByWeek: weekPoints)
            return true
        } catch {
            self.error = "Couldn't submit: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Settlement

    /// After Week 18 has fully ended: flip the tournament to settled (any
    /// client), pay my entries through the ledger (idempotent per entry),
    /// and write Past Results rows. Settled data is never rescored.
    private func settleIfSeasonOver() async {
        guard let token = accessToken, let uid = userID, !isSettled else { return }
        let (_, end18) = BestBallSeasonHelper.weekDateRange(sport: "NFL", week: BBTConfig.totalWeeks)
        guard Date() > (Calendar.current.date(byAdding: .day, value: 2, to: end18) ?? end18) else { return }
        guard !standings.isEmpty, weekPoints.count >= BBTConfig.totalWeeks - 1 else { return }
        try? await SupabaseService.shared.updateBBTTournamentStatus(id: BBTConfig.tournamentID, status: "settled", accessToken: token)
        if let t = tournament {
            tournament = BBTTournamentRecord(id: t.id, title: t.title, season: t.season, status: "settled", lockTime: t.lockTime)
        }
        let field = standings.count
        for s in myStandings {
            let delta = DFSEngine.rrDelta(forRank: s.rank, entryCount: field)
            if delta != 0 {
                try? await SupabaseService.shared.insertFantasyLedgerRow(
                    userID: uid, refID: s.entry.id, kind: "bbt_payout", rrDelta: delta, accessToken: token
                )
            }
            saveHistoryRow(standing: s, fieldSize: field, rrDelta: delta)
        }
        await refreshFantasyDelta()
    }

    private func saveHistoryRow(standing: BBTStanding, fieldSize: Int, rrDelta: Int) {
        let key = "dfs_history_data"
        var history: [[String: Any]] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            history = decoded
        }
        let tid = "\(BBTConfig.tournamentID)-e\(standing.entry.entryNumber)"
        guard !history.contains(where: { ($0["tournamentId"] as? String) == tid }) else { return }
        history.insert([
            "id": UUID().uuidString,
            "tournamentTitle": BBTConfig.title,
            "rank": standing.rank,
            "totalEntries": fieldSize,
            "lineupPoints": standing.totalPoints,
            "rrDelta": rrDelta,
            "loggedAt": ISO8601DateFormatter().string(from: Date()),
            "tournamentId": tid,
            "lineupNumber": standing.entry.entryNumber
        ], at: 0)
        if let encoded = try? JSONSerialization.data(withJSONObject: history) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    /// Recompose the home RR pill's fantasy bucket the same way Survivor
    /// does, including this mode's ledger rows.
    private func refreshFantasyDelta() async {
        guard let uid = userID, let token = accessToken else { return }
        guard let ledger = try? await SupabaseService.shared.fetchFantasyLedger(userID: uid, accessToken: token) else { return }
        let net = ledger.filter { $0.kind.hasPrefix("survivor") || $0.kind.hasPrefix("bbt") }.reduce(0) { $0 + $1.rrDelta }
        let total = net
            + UserDefaults.standard.integer(forKey: "fantasy_bestball_delta")
            + UserDefaults.standard.integer(forKey: "fantasy_tiers_delta")
        if UserDefaults.standard.integer(forKey: "fantasy_rr_delta") != total {
            UserDefaults.standard.set(total, forKey: "fantasy_rr_delta")
        }
    }
}
