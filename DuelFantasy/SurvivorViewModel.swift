import Foundation
import SwiftUI

/// Standing row for a survivor pool: the server entry plus the
/// elimination week computed client-side from final scores.
struct SurvivorStanding: Identifiable {
    let entry: SurvivorEntryRecord
    let eliminatedWeek: Int?
    var id: String { entry.id }
    var isAlive: Bool { eliminatedWeek == nil }
}

@MainActor
@Observable
final class SurvivorViewModel {
    // Auth (synced from ContentView)
    var userID: String?
    var accessToken: String?
    var profileName: String = ""

    var entriesByPool: [String: [SurvivorEntryRecord]] = [:]
    var picksByPool: [String: [SurvivorPickRecord]] = [:]
    var gamesByWeek: [Int: [SurvivorGame]] = [:]
    var currentWeek: Int = 1
    var hasLoadedLobby = false
    var isLoading = false
    var isJoining = false
    var error: String?

    private let provider = NFLSurvivorScheduleProvider()

    // MARK: - Derived

    var seasonStarted: Bool {
        guard let lock = weekLockDate(1) else { return false }
        return Date() >= lock
    }

    /// All picks lock at the week's first kickoff (Thursday night).
    func weekLockDate(_ week: Int) -> Date? {
        gamesByWeek[week]?.map(\.date).min()
    }

    func isWeekLocked(_ week: Int) -> Bool {
        guard let lock = weekLockDate(week) else { return false }
        return Date() >= lock
    }

    func isWeekComplete(_ week: Int) -> Bool {
        guard let games = gamesByWeek[week], !games.isEmpty else { return false }
        return games.allSatisfy { $0.state == "post" }
    }

    func myEntry(poolID: String) -> SurvivorEntryRecord? {
        guard let uid = userID else { return nil }
        return entriesByPool[poolID]?.first { $0.userID == uid }
    }

    func pick(poolID: String, userID uid: String, week: Int) -> SurvivorPickRecord? {
        picksByPool[poolID]?.first { $0.userID == uid && $0.week == week }
    }

    func myPick(poolID: String, week: Int) -> SurvivorPickRecord? {
        guard let uid = userID else { return nil }
        return pick(poolID: poolID, userID: uid, week: week)
    }

    /// Teams this user has burned in locked weeks (current-week picks
    /// stay switchable until the week's first kickoff).
    func usedTeams(poolID: String) -> Set<String> {
        guard let uid = userID else { return [] }
        let picks = (picksByPool[poolID] ?? []).filter { $0.userID == uid }
        return Set(picks.filter { isWeekLocked($0.week) }.map(\.teamAbbr))
    }

    func joinDenialReason(fee: Int) -> String? {
        let poolID = SurvivorSeason.poolID(fee: fee)
        if myEntry(poolID: poolID) != nil { return nil }   // joined = no denial, just no re-join
        if seasonStarted { return "Entries closed — the season has started" }
        let balance = UserDefaults.standard.integer(forKey: "rr_score")
        if balance < fee { return "Not enough RR (balance: \(balance))" }
        return nil
    }

    // MARK: - Grading (client-side, from final scores)

    /// First week the user busted: a completed week with a losing/tied
    /// pick, or a locked-and-completed week with no pick at all. Only
    /// fully-final weeks grade — a week in progress never eliminates.
    func computedEliminationWeek(poolID: String, userID uid: String) -> Int? {
        let picks = (picksByPool[poolID] ?? []).filter { $0.userID == uid }
        let picksByWeek = Dictionary(picks.map { ($0.week, $0) }, uniquingKeysWith: { a, _ in a })
        guard seasonStarted else { return nil }
        for week in 1...SurvivorSeason.totalWeeks {
            guard isWeekComplete(week) else { break }
            guard let pick = picksByWeek[week] else { return week }
            guard let game = gamesByWeek[week]?.first(where: { $0.involves(pick.teamAbbr) }) else { continue }
            if game.winnerAbbr != pick.teamAbbr { return week }
        }
        return nil
    }

    func standings(poolID: String) -> [SurvivorStanding] {
        let rows = (entriesByPool[poolID] ?? []).map { entry in
            SurvivorStanding(entry: entry, eliminatedWeek: computedEliminationWeek(poolID: poolID, userID: entry.userID))
        }
        return rows.sorted { a, b in
            switch (a.eliminatedWeek, b.eliminatedWeek) {
            case (nil, nil): return a.entry.entryName < b.entry.entryName
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x != y ? x > y : a.entry.entryName < b.entry.entryName
            }
        }
    }

    func aliveCount(poolID: String) -> Int {
        // Before this pool's picks are loaded (lobby), computed grading
        // would read every entry as a missed-pick elimination — fall back
        // to the server-persisted status.
        guard picksByPool[poolID] != nil else {
            return (entriesByPool[poolID] ?? []).filter { $0.status == "alive" }.count
        }
        return standings(poolID: poolID).filter(\.isAlive).count
    }

    /// Elimination week for display: computed from final scores once this
    /// pool's picks are in memory, otherwise the server-persisted status.
    func displayedElimination(poolID: String, entry: SurvivorEntryRecord) -> Int? {
        guard picksByPool[poolID] != nil else {
            return entry.status == "eliminated" ? (entry.eliminatedWeek ?? 1) : nil
        }
        return computedEliminationWeek(poolID: poolID, userID: entry.userID)
    }

    func poolPot(poolID: String) -> Int {
        SurvivorSeason.fee(fromPoolID: poolID) * (entriesByPool[poolID]?.count ?? 0)
    }

    /// Winners once the pool is decided; nil while it's still running.
    /// One survivor left → they win. Everyone busted the same week → the
    /// last-out group splits. Multiple alive after week 18 → they split.
    func poolWinners(poolID: String) -> [SurvivorStanding]? {
        let entries = entriesByPool[poolID] ?? []
        // Never judge a pool before its picks are loaded — with an empty
        // pick set every entry grades as a week-1 missed-pick elimination.
        guard picksByPool[poolID] != nil, seasonStarted, entries.count >= 2 else { return nil }
        let rows = standings(poolID: poolID)
        let lastCompleteWeek = (1...SurvivorSeason.totalWeeks).last(where: { isWeekComplete($0) }) ?? 0
        guard lastCompleteWeek >= 1 else { return nil }
        let alive = rows.filter(\.isAlive)
        if alive.count == 1 { return alive }
        if alive.isEmpty {
            guard let maxWeek = rows.compactMap(\.eliminatedWeek).max() else { return nil }
            return rows.filter { $0.eliminatedWeek == maxWeek }
        }
        if lastCompleteWeek >= SurvivorSeason.totalWeeks { return alive }
        return nil
    }

    func poolShare(poolID: String) -> Int {
        guard let winners = poolWinners(poolID: poolID), !winners.isEmpty else { return 0 }
        return max(1, poolPot(poolID: poolID) / winners.count)
    }

    // MARK: - Loading

    func loadLobby() async {
        guard accessToken != nil else { return }
        if entriesByPool.isEmpty { isLoading = true }
        defer { isLoading = false }
        currentWeek = await provider.fetchCurrentWeek()
        await ensureGames(forWeek: 1)
        if currentWeek != 1 { await ensureGames(forWeek: currentWeek) }
        await reloadEntries()
        hasLoadedLobby = true
    }

    private func reloadEntries() async {
        guard let token = accessToken else { return }
        let poolIDs = SurvivorSeason.entryFees.map { SurvivorSeason.poolID(fee: $0) }
        if let recs = try? await SupabaseService.shared.fetchSurvivorEntries(poolIDs: poolIDs, accessToken: token) {
            entriesByPool = Dictionary(grouping: recs, by: \.poolID)
        }
    }

    func loadPool(_ poolID: String) async {
        guard let token = accessToken else { return }
        currentWeek = await provider.fetchCurrentWeek()
        for week in 1..<max(currentWeek, 1) { await ensureGames(forWeek: week) }
        await ensureGames(forWeek: currentWeek, forceRefresh: true)
        await reloadEntries()
        if let picks = try? await SupabaseService.shared.fetchSurvivorPicks(poolID: poolID, accessToken: token) {
            picksByPool[poolID] = picks
        }
        await persistMyGrading(poolID: poolID)
        await reconcilePoolLedger(poolID: poolID)
    }

    /// Fetch a week's games, memoized in memory and — once every game is
    /// final — persisted to UserDefaults so past weeks never refetch.
    private func ensureGames(forWeek week: Int, forceRefresh: Bool = false) async {
        guard week >= 1, week <= SurvivorSeason.totalWeeks else { return }
        if !forceRefresh, let games = gamesByWeek[week], !games.isEmpty {
            if games.allSatisfy({ $0.state == "post" }) || !isWeekLocked(week) { return }
        }
        let cacheKey = "survivor_games_\(SurvivorSeason.year)_w\(week)"
        if !forceRefresh, gamesByWeek[week] == nil,
           let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([SurvivorGame].self, from: data),
           !cached.isEmpty, cached.allSatisfy({ $0.state == "post" }) {
            gamesByWeek[week] = cached
            return
        }
        let fetched = await provider.fetchGames(week: week)
        guard !fetched.isEmpty else { return }
        gamesByWeek[week] = fetched
        if fetched.allSatisfy({ $0.state == "post" }) {
            UserDefaults.standard.set(try? JSONEncoder().encode(fetched), forKey: cacheKey)
        }
    }

    // MARK: - Actions

    func join(fee: Int) async -> Bool {
        let poolID = SurvivorSeason.poolID(fee: fee)
        guard myEntry(poolID: poolID) == nil, joinDenialReason(fee: fee) == nil,
              let uid = userID, let token = accessToken else { return false }
        isJoining = true
        defer { isJoining = false }
        do {
            let name = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.insertSurvivorEntry(
                poolID: poolID, userID: uid, entryName: name, accessToken: token
            )
            // Idempotent charge — unique (user_id, ref_id, kind) means a
            // retry can never double-charge.
            try await SupabaseService.shared.insertFantasyLedgerRow(
                userID: uid, refID: poolID, kind: "survivor_entry", rrDelta: -fee, accessToken: token
            )
            await refreshFantasyDelta()
            await reloadEntries()
            return true
        } catch {
            self.error = "Couldn't join: \(error.localizedDescription)"
            return false
        }
    }

    func makePick(poolID: String, week: Int, teamAbbr: String, teamName: String) async {
        guard let uid = userID, let token = accessToken else { return }
        guard !isWeekLocked(week), !usedTeams(poolID: poolID).contains(teamAbbr) else { return }
        do {
            try await SupabaseService.shared.upsertSurvivorPick(
                poolID: poolID, userID: uid, week: week,
                teamAbbr: teamAbbr, teamName: teamName, accessToken: token
            )
            if let picks = try? await SupabaseService.shared.fetchSurvivorPicks(poolID: poolID, accessToken: token) {
                picksByPool[poolID] = picks
            }
        } catch {
            self.error = "Couldn't save pick: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence of my own grading

    /// Writes my pick results and entry status back to the server (RLS
    /// only lets a user update their own rows; everyone else's standings
    /// are computed client-side from final scores regardless).
    private func persistMyGrading(poolID: String) async {
        guard let uid = userID, let token = accessToken else { return }
        let myPicks = (picksByPool[poolID] ?? []).filter { $0.userID == uid }
        for pick in myPicks where pick.result == "pending" && isWeekComplete(pick.week) {
            guard let game = gamesByWeek[pick.week]?.first(where: { $0.involves(pick.teamAbbr) }) else { continue }
            let result = game.winnerAbbr == pick.teamAbbr ? "win" : "loss"
            try? await SupabaseService.shared.updateSurvivorPickResult(
                poolID: poolID, userID: uid, week: pick.week, result: result, accessToken: token
            )
        }
        guard let mine = myEntry(poolID: poolID) else { return }
        let elimWeek = computedEliminationWeek(poolID: poolID, userID: uid)
        if let elimWeek, mine.status == "alive" {
            try? await SupabaseService.shared.updateSurvivorEntry(
                entryID: mine.id, status: "eliminated", eliminatedWeek: elimWeek, accessToken: token
            )
        } else if elimWeek == nil, mine.status == "eliminated" {
            try? await SupabaseService.shared.updateSurvivorEntry(
                entryID: mine.id, status: "alive", eliminatedWeek: nil, accessToken: token
            )
        }
    }

    // MARK: - RR ledger

    /// Lazy self-payout, mirroring Best Ball: when the pool is decided and
    /// I'm a winner, insert my payout row (idempotent). A single-entrant
    /// pool refunds the fee once the season locks.
    private func reconcilePoolLedger(poolID: String) async {
        guard let uid = userID, let token = accessToken, myEntry(poolID: poolID) != nil else { return }
        let fee = SurvivorSeason.fee(fromPoolID: poolID)
        let entries = entriesByPool[poolID] ?? []
        if seasonStarted, entries.count == 1 {
            try? await SupabaseService.shared.insertFantasyLedgerRow(
                userID: uid, refID: poolID, kind: "survivor_payout", rrDelta: fee, accessToken: token
            )
            await refreshFantasyDelta()
            return
        }
        if let winners = poolWinners(poolID: poolID), winners.contains(where: { $0.entry.userID == uid }) {
            let share = poolShare(poolID: poolID)
            try? await SupabaseService.shared.insertFantasyLedgerRow(
                userID: uid, refID: poolID, kind: "survivor_payout", rrDelta: share, accessToken: token
            )
            await refreshFantasyDelta()
        }
    }

    /// Recompute the shared "fantasy_rr_delta" bucket from the ledger plus
    /// the Tiers/Bracket component that BestBallViewModel.reconcileFantasyLedger
    /// snapshots into "fantasy_tiers_delta" — so survivor charges show up on
    /// the home RR pill without waiting for the next Best Ball reconcile.
    private func refreshFantasyDelta() async {
        guard let uid = userID, let token = accessToken else { return }
        guard let ledger = try? await SupabaseService.shared.fetchFantasyLedger(userID: uid, accessToken: token) else { return }
        // Only the survivor component is computed here — Best Ball entry
        // fees don't count until their league completes, and this VM
        // can't see league statuses. Recompose from the persisted
        // components BestBallViewModel.reconcileFantasyLedger maintains.
        let survivorNet = ledger.filter { $0.kind.hasPrefix("survivor") }.reduce(0) { $0 + $1.rrDelta }
        let total = survivorNet
            + UserDefaults.standard.integer(forKey: "fantasy_bestball_delta")
            + UserDefaults.standard.integer(forKey: "fantasy_tiers_delta")
        if UserDefaults.standard.integer(forKey: "fantasy_rr_delta") != total {
            UserDefaults.standard.set(total, forKey: "fantasy_rr_delta")
        }
    }
}
