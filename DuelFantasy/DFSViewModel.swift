import Foundation
import SwiftUI

enum PlayerSortOrder {
    case salary, projected, name, position
}

@MainActor
@Observable
final class DFSViewModel {
    // MARK: - Tournament State
    var tournaments: [DFSTournament] = []
    var activeTournamentID: String?
    /// Which lineup number is currently being viewed in the live contest (1-based). Defaults to 1.
    var activeLineupNumber: Int = 1
    var tournament: DFSTournament? {
        if let id = activeTournamentID {
            return tournaments.first(where: { $0.id == id })
        }
        return tournaments.first
    }
    /// Per-game single-game player pools with adjusted salaries, keyed by ESPN event ID
    var singleGamePlayers: [String: [DFSPlayer]] = [:]
    /// Tracks which tournament IDs the user has entered today (for entry limit enforcement)
    var enteredTournamentIDs: Set<String> = []
    /// Cached entry records for all of the user's entries today (keyed by tournament ID).
    /// Each tournament can have multiple lineups, stored as an array.
    var userEntryRecords: [String: [DFSEntryRecord]] = [:]
    /// Maximum number of lineups per tournament
    let maxLineupsPerTournament: Int = 5
    /// Maximum number of lineups per sport per day
    let maxLineupsPerDay: Int = 20
    /// Total lineups submitted today across all tournaments
    var totalLineupsToday: Int {
        userEntryRecords.values.reduce(0) { $0 + $1.count }
    }
    /// Number of lineups the user has across all instances of a tournament type.
    /// For instanced tournaments (H2H, 3-man, etc.), each lineup goes to a separate
    /// instance (base, base-i2, base-i3, ...). This counts them all.
    func lineupsInTournament(_ id: String) -> Int {
        let baseID = baseTournamentID(id)
        var count = 0
        for (tid, entries) in userEntryRecords {
            if baseTournamentID(tid) == baseID {
                count += entries.count
            }
        }
        return count
    }

    /// Clear the current lineup selection for starting a fresh new entry.
    func clearLineupForNewEntry() {
        selectedPlayerIDs = []
        mvpPlayerID = nil
    }

    /// Strip instance suffix (e.g. "mlb-xxx-h2h-i3" → "mlb-xxx-h2h")
    func baseTournamentID(_ id: String) -> String {
        // Instance IDs end with "-i2", "-i3", etc.
        if let range = id.range(of: #"-i\d+$"#, options: .regularExpression) {
            return String(id[id.startIndex..<range.lowerBound])
        }
        return id
    }

    /// Ensure any entered instance tournaments have corresponding DFSTournament objects
    /// so they show up in the "Your Lineups" section of the lobby.
    private func ensureInstanceTournamentsExist() {
        let existingIDs = Set(tournaments.map(\.id))
        for enteredID in enteredTournamentIDs where !existingIDs.contains(enteredID) {
            // Find the base tournament to clone its properties
            let baseID = baseTournamentID(enteredID)
            guard let baseTournament = tournaments.first(where: { $0.id == baseID }) else { continue }
            let instanceTournament = DFSTournament(
                id: enteredID,
                title: baseTournament.title,
                league: baseTournament.league,
                entryCount: baseTournament.entryCount,
                lineupSize: baseTournament.lineupSize,
                salaryCap: baseTournament.salaryCap,
                rosterSlots: baseTournament.rosterSlots,
                isSingleGame: baseTournament.isSingleGame,
                tournamentType: baseTournament.tournamentType,
                gameID: baseTournament.gameID,
                entryFee: baseTournament.entryFee
            )
            tournaments.append(instanceTournament)
        }
    }
    
    /// Find the user's entry record for a specific tournament + lineup number.
    /// Tries exact lineupNumber match first, then falls back to index-based
    /// matching (for entries with nil lineupNumber), then to the first entry.
    func entryRecord(for tournamentID: String, lineupNumber: Int) -> DFSEntryRecord? {
        guard let entries = userEntryRecords[tournamentID], !entries.isEmpty else { return nil }
        // Exact match on lineupNumber
        if let exact = entries.first(where: { ($0.lineupNumber ?? 1) == lineupNumber }) {
            return exact
        }
        // Index-based fallback (lineupNumber 1 → index 0, etc.)
        let idx = lineupNumber - 1
        if idx >= 0, idx < entries.count { return entries[idx] }
        // Last resort: first entry
        return entries.first
    }
    /// Whether the user can submit more lineups today
    var canSubmitMoreLineups: Bool {
        totalLineupsToday < maxLineupsPerDay
    }
    var slateGames: [DFSSlateGame] = []
    var players: [DFSPlayer] = []
    var selectedPlayerIDs: Set<String> = []
    /// Explicitly chosen MVP player for single-game mode. When set, this player
    /// is always placed at index 0 in selectedPlayers (the MVP slot).
    var mvpPlayerID: String?
    /// Set to true while the user is actively editing their lineup in the builder.
    /// Prevents background refreshes from overwriting in-progress edits.
    var isEditingLineup: Bool = false
    /// When non-nil, the lineup builder is editing an existing entry rather than creating a new one.
    var editingLineupNumber: Int? = nil
    var isLoading: Bool = false
    /// Whether the first load attempt has completed (success or failure).
    /// Used to distinguish "hasn't loaded yet" from "loaded but no games".
    var hasAttemptedLoad: Bool = false
    var error: String?
    var latestResult: DFSResult?
    var leaderboardEntries: [DFSLeaderboardEntry] = []
    var fieldEntries: [DFSFieldEntry] = []
    var remoteEntries: [DFSEntryRecord] = []
    var remoteProfileNames: [String: String] = [:]
    var livePlayerPoints: [String: Double] = [:]
    /// Cached live ranks keyed by "tournamentID-lineupNumber" for display on Active Contests cards.
    var cachedLiveRanks: [String: Int] = [:]
    var livePlayerStats: [String: DFSPlayerLiveStats] = [:]
    var liveGameInfo: [String: DFSGameLiveInfo] = [:]

    // MARK: - UI State
    var showAllResults: Bool = false
    var selectedPositionFilter: String?
    var selectedGameFilter: String?  // gameID to filter player list by matchup
    var searchText: String = ""
    var sortOrder: PlayerSortOrder = .salary
    var showLineupBuilder: Bool = false

    // MARK: - Tournament Invites
    var pendingInvites: [DFSTournamentInviteRecord] = []
    var showInviteFriends: Bool = false
    var inviteTournamentID: String? = nil

    /// Cached player metadata from roster preload: playerID → (name, team abbreviation, gameID, position)
    private var preloadedPlayerInfo: [String: (name: String, team: String, gameID: String, position: String?)] = [:]

    // MARK: - Persisted History (synced from AppStorage in ContentView)
    var dfsHistoryData: Data = Data()
    var settledTournamentData: Data = Data()  // persisted Set<String> of settled tournament IDs

    // MARK: - Auth (synced from ContentView)
    var userID: String?
    var accessToken: String?
    var userEmail: String = ""
    var profileName: String = ""
    var rrScore: Int = 1000

    // MARK: - Providers
    let sport: String  // "NBA", "MLB", etc.
    private let slateProvider: DFSSlateProvider
    private let scoringProvider: DFSLiveScoringProvider

    init(
        sport: String = "NBA",
        slateProvider: DFSSlateProvider? = nil,
        scoringProvider: DFSLiveScoringProvider? = nil
    ) {
        self.sport = sport
        self.slateProvider = slateProvider ?? ConfiguredDFSSlateProvider()
        self.scoringProvider = scoringProvider ?? ESPNDFSLiveScoringProvider()
    }

    // MARK: - PGA-Specific

    /// Polling interval: PGA uses 5min during rounds, 30min otherwise; other sports use 35s
    var pollingInterval: TimeInterval {
        if sport == "PGA" {
            guard let game = slateGames.first else { return 300 }
            return game.state == "in" ? 300 : 1800
        }
        return 35
    }

    /// Minimum days after lock before a tournament can be settled (PGA = 3 days for 4-round Thu–Sun)
    private var settlementMinDays: Double {
        sport == "PGA" ? 3.0 : 0.0
    }

    /// Current round number (1-4) for PGA tournaments
    var currentRound: Int {
        guard sport == "PGA" else { return 0 }
        if let game = slateGames.first, let info = liveGameInfo[game.id] {
            return info.period
        }
        return 1
    }

    /// Venue name for PGA (stored in awayTeam field of the slate game)
    var venueName: String {
        guard sport == "PGA" else { return "" }
        return slateGames.first?.awayTeam ?? ""
    }

    /// Event name for PGA (stored in homeTeam field of the slate game)
    var eventName: String {
        guard sport == "PGA" else { return "" }
        return slateGames.first?.homeTeam ?? tournament?.title ?? ""
    }

    /// Whether there is no active PGA event (between-weeks)
    var noActiveEvent: Bool {
        guard sport == "PGA" else { return false }
        return tournament == nil && !isLoading && error != nil
    }

    /// Status label for PGA tournaments: "Round 2 - Active", "Final", "Pre-Tournament"
    var tournamentStatusLabel: String {
        guard sport == "PGA", let game = slateGames.first else { return "" }
        if let info = liveGameInfo[game.id] {
            return info.clock
        }
        switch game.state {
        case "post":
            let daysSinceStart = Date().timeIntervalSince(game.startTime) / (24 * 3600)
            return daysSinceStart >= 3.0 ? "Final" : "Round \(currentRound) Complete"
        case "in": return "Round Active"
        default: return "Pre-Tournament"
        }
    }

    /// Whether the PGA tournament is settled
    var isPGATournamentSettled: Bool {
        guard sport == "PGA", !tournaments.isEmpty else { return false }
        let enteredIDs = enteredTournamentIDs.isEmpty ? Set(tournaments.map { $0.id }) : enteredTournamentIDs
        guard enteredIDs.allSatisfy({ settledTournaments.contains($0) }) else { return false }
        let startTime = slateGames.first?.startTime ?? .distantFuture
        let daysSinceStart = Date().timeIntervalSince(startTime) / (24 * 3600)
        return daysSinceStart >= 3.0
    }

    /// Time remaining label for PGA field entries
    func pgaTimeRemainingLabel(for fieldEntry: DFSFieldEntry) -> String {
        guard sport == "PGA", let game = slateGames.first else { return "" }
        if let info = liveGameInfo[game.id] {
            if info.clock == "Final" { return "Final" }
            if info.state == "in" || info.clock.contains("Active") { return "R\(info.period) Active" }
            if info.state == "post" && info.period < 4 { return "R\(info.period) Done" }
            if info.state == "post" { return "R\(info.period) Active" }
            return "Pre"
        }
        if game.state == "post" {
            let daysSinceStart = Date().timeIntervalSince(game.startTime) / (24 * 3600)
            return daysSinceStart >= 3.0 ? "Final" : "R\(currentRound) Active"
        }
        return "Pre"
    }

    // MARK: - Multi-Tournament

    /// The player pool for the currently active tournament.
    /// For single-game tournaments, returns the game-specific adjusted-salary pool.
    /// For main-slate tournaments, returns the full player pool.
    var activePlayers: [DFSPlayer] {
        guard let t = tournament else { return players }
        if t.isSingleGame, let gameID = t.gameID {
            if let sgPool = singleGamePlayers[gameID] {
                return sgPool
            }
            // Fallback: filter main player pool by game ID to prevent cross-game contamination.
            // IMPORTANT: Convert salaries to single-game showdown prices so bots and
            // the live display see the correct (higher) showdown salaries, not main-slate prices.
            let filtered = players.filter { $0.gameID == gameID }
            if !filtered.isEmpty {
                let league = t.league
                let converted = filtered.map { p in
                    var sg = DFSPlayer(
                        id: p.id, name: p.name, team: p.team, position: p.position,
                        salary: singleGameSalary(from: p.salary, league: league),
                        projectedPoints: p.projectedPoints,
                        gameID: p.gameID, injuryStatus: p.injuryStatus,
                        battingOrder: p.battingOrder
                    )
                    sg.gamesPlayed = p.gamesPlayed
                    sg.playedRecently = p.playedRecently
                    sg.isConfirmedActive = p.isConfirmedActive
                    sg.isStartingGoalie = p.isStartingGoalie
                    return sg
                }
                // Cache so subsequent calls don't re-convert
                singleGamePlayers[gameID] = converted
                return converted
            }
        }
        if t.tournamentType.isEvening {
            return eveningPlayers
        }
        return players
    }

    /// Players from evening games only (6pm ET+), cached after slate load.
    var eveningPlayers: [DFSPlayer] = []

    /// Switch the active tournament and reset lineup state for the new tournament.
    func selectTournament(_ tournamentID: String, lineupNumber: Int = 1) {
        let changed = activeTournamentID != tournamentID || activeLineupNumber != lineupNumber
        guard changed else { return }

        let previousTID = activeTournamentID

        // Save current state to cache before switching
        if let prevID = previousTID, fieldGenerated, !fieldEntries.isEmpty {
            liveContestCache[prevID] = LiveContestCache(
                fieldEntries: fieldEntries,
                leaderboard: leaderboardEntries,
                remoteEntries: remoteEntries,
                profileNames: remoteProfileNames,
                fieldGenerated: true
            )
        }

        activeTournamentID = tournamentID
        activeLineupNumber = lineupNumber
        selectedPlayerIDs = []
        mvpPlayerID = nil
        selectedPositionFilter = nil
        selectedGameFilter = nil

        // If this tournament doesn't exist in the array (e.g. old PGA event that ESPN
        // has rotated away from), create a synthetic DFSTournament so the computed
        // `tournament` property returns a valid object and refreshLive() can proceed.
        if !tournaments.contains(where: { $0.id == tournamentID }) {
            let entryCount = Self.entryCountFromTournamentID(tournamentID)
            let syntheticTitle: String
            if tournamentID.hasPrefix("pga-") {
                syntheticTitle = "PGA Tournament"
            } else {
                syntheticTitle = "\(sport) Contest"
            }
            let syntheticTournament = DFSTournament(
                id: tournamentID,
                title: syntheticTitle,
                league: sport,
                entryCount: entryCount,
                lineupSize: sport == "PGA" ? 6 : 7,
                salaryCap: 50000
            )
            tournaments.append(syntheticTournament)
        }

        // Try to restore from cache (instant switch)
        if let cached = liveContestCache[tournamentID] {
            // Swap the user's lineup in the field to the newly active one
            let newLineupEntry = entryRecord(for: tournamentID, lineupNumber: lineupNumber)
            fieldEntries = cached.fieldEntries.map { entry in
                guard entry.isCurrentUser || (entry.realUserID == userID) else { return entry }
                // Replace the user's field entry with the new lineup's player IDs
                if let newEntry = newLineupEntry {
                    return DFSFieldEntry(
                        id: UUID(uuidString: newEntry.id) ?? entry.id,
                        name: entry.name, playerIDs: newEntry.lineupPlayerIDs,
                        isCurrentUser: true,
                        isRealUser: entry.isRealUser, realUserID: entry.realUserID
                    )
                }
                return DFSFieldEntry(
                    id: entry.id, name: entry.name, playerIDs: entry.playerIDs,
                    isCurrentUser: true,
                    isRealUser: entry.isRealUser, realUserID: entry.realUserID
                )
            }
            leaderboardEntries = cached.leaderboard
            remoteEntries = cached.remoteEntries
            remoteProfileNames = cached.profileNames
            fieldGenerated = true

            // Defensive: if the cache was saved without the user's entry,
            // inject it from userEntryRecords so it's visible immediately
            if !fieldEntries.contains(where: { $0.isCurrentUser }),
               let uid = userID,
               let entry = entryRecord(for: tournamentID, lineupNumber: lineupNumber) {
                let name = profileName.isEmpty ? "You" : profileName
                let userFieldEntry = DFSFieldEntry(
                    id: UUID(uuidString: entry.id) ?? UUID(),
                    name: name,
                    playerIDs: entry.lineupPlayerIDs,
                    isCurrentUser: true,
                    isRealUser: true,
                    realUserID: uid
                )
                if let botIdx = fieldEntries.firstIndex(where: { !$0.isCurrentUser && !$0.isRealUser }) {
                    fieldEntries[botIdx] = userFieldEntry
                } else if let t = tournaments.first(where: { $0.id == tournamentID }),
                          fieldEntries.count < t.entryCount {
                    fieldEntries.append(userFieldEntry)
                }
            }
        } else {
            // No cache — full reset
            leaderboardEntries = []
            fieldEntries = []
            remoteEntries = []
            remoteProfileNames = [:]
            fieldGenerated = false
        }

        latestResult = nil
        // Restore latestResult from history if available (prefer matching lineup number)
        let historyMatches = dfsHistory.filter { $0.tournamentId == tournamentID }
        if let exact = historyMatches.first(where: { ($0.lineupNumber ?? 1) == lineupNumber }) {
            latestResult = exact
        } else if let any = historyMatches.first {
            latestResult = any
        }

        // If no history result but we have cached rank + score, build a latestResult
        // so the header shows rank/score immediately instead of "Your lineup is locked in"
        if latestResult == nil, let cachedRank = cachedLiveRanks["\(tournamentID)-\(lineupNumber)"],
           let entry = entryRecord(for: tournamentID, lineupNumber: lineupNumber) {
            let t = tournaments.first(where: { $0.id == tournamentID })
            let isSG = t?.isSingleGame ?? false
            var score = 0.0
            for (i, pid) in entry.lineupPlayerIDs.enumerated() {
                let pts = livePlayerPoints[pid] ?? 0
                score += (isSG && i == 0) ? pts * 1.5 : pts
            }
            if score > 0 {
                latestResult = DFSResult(
                    id: UUID(),
                    tournamentTitle: t?.title ?? "",
                    rank: cachedRank,
                    totalEntries: t?.entryCount ?? cachedRank,
                    lineupPoints: score,
                    rrDelta: 0,
                    loggedAt: Date(),
                    tournamentId: tournamentID,
                    lineupNumber: lineupNumber
                )
            }
        }

        // Pre-fill the lineup from cached entry records so the live contest
        // view can show the user's players immediately (before refreshLive runs)
        if let entry = entryRecord(for: tournamentID, lineupNumber: lineupNumber) {
            loadLineupFromEntry(entry)
        }
    }

    /// Pre-fill the lineup builder with players from an existing entry.
    func loadLineupFromEntry(_ entry: DFSEntryRecord) {
        selectedPlayerIDs = Set(entry.lineupPlayerIDs)
        // For single-game, first player is the MVP
        if tournament?.isSingleGame == true, let firstID = entry.lineupPlayerIDs.first {
            mvpPlayerID = firstID
        } else {
            mvpPlayerID = nil
        }
    }

    /// Whether the user has already entered the currently active tournament
    var hasEnteredActiveTournament: Bool {
        guard let id = activeTournamentID else { return false }
        return enteredTournamentIDs.contains(id)
    }

    // MARK: - Computed Properties

    /// Ordered list of selected players, arranged by roster slot when applicable.
    /// Always includes all selected IDs — creates stub entries for players not in the current pool
    /// (e.g. DNP players not on today's FanDuel slate).
    var selectedPlayers: [DFSPlayer] {
        let playerPool = activePlayers
        let existingIDs = Set(playerPool.map(\.id))
        var pool = playerPool.filter { selectedPlayerIDs.contains($0.id) }
        // Fix two-way batter positions: if both "mlb-X" and "mlb-X-sp" are selected,
        // the batter entry ("mlb-X") should be UTIL, not SP (even though ESPN lists them as SP).
        if sport == "MLB" {
            let spEntryBaseIDs = Set(selectedPlayerIDs.filter { $0.hasSuffix("-sp") }.map { String($0.dropLast(3)) })
            if !spEntryBaseIDs.isEmpty {
                pool = pool.map { p in
                    guard spEntryBaseIDs.contains(p.id), p.position == "SP" else { return p }
                    return DFSPlayer(id: p.id, name: p.name, team: p.team, position: "UTIL",
                                     salary: p.salary, projectedPoints: p.projectedPoints,
                                     gameID: p.gameID, injuryStatus: p.injuryStatus,
                                     battingOrder: p.battingOrder)
                }
            }
        }
        // Override salaries with draft-time values from the entry record.
        // ESPN can update salaries after the user submits their lineup, but the
        // live view should always show what the user originally drafted at.
        if let tid = activeTournamentID,
           let entry = self.entryRecord(for: tid, lineupNumber: activeLineupNumber),
           let savedSalaries = entry.lineupPlayerSalaries, !savedSalaries.isEmpty {
            pool = pool.map { p in
                guard let draftSalary = savedSalaries[p.id] else { return p }
                guard draftSalary != p.salary else { return p }
                var fixed = DFSPlayer(
                    id: p.id, name: p.name, team: p.team, position: p.position,
                    salary: draftSalary, projectedPoints: p.projectedPoints,
                    gameID: p.gameID, injuryStatus: p.injuryStatus,
                    battingOrder: p.battingOrder
                )
                fixed.gamesPlayed = p.gamesPlayed
                fixed.playedRecently = p.playedRecently
                fixed.isConfirmedActive = p.isConfirmedActive
                fixed.isStartingGoalie = p.isStartingGoalie
                return fixed
            }
        }

        // Add stub entries for any selected IDs missing from the player pool
        let missingIDs = selectedPlayerIDs.filter { !existingIDs.contains($0) }
        // Build name and salary lookups from the user's entry record
        let entryRecord: DFSEntryRecord? = {
            guard let tid = activeTournamentID else { return nil }
            return self.entryRecord(for: tid, lineupNumber: activeLineupNumber)
        }()
        let entryNamesByID: [String: String] = {
            guard let entry = entryRecord,
                  let names = entry.lineupPlayerNames, !names.isEmpty else { return [:] }
            var map: [String: String] = [:]
            for (i, pid) in entry.lineupPlayerIDs.enumerated() where i < names.count {
                if !names[i].isEmpty { map[pid] = names[i] }
            }
            return map
        }()
        let entrySalariesByID = entryRecord?.lineupPlayerSalaries ?? [:]
        if !missingIDs.isEmpty, let slots = tournament?.rosterSlots {
            // Figure out which slots real players already fill, then assign stubs
            // to the remaining unfilled positional slots so they aren't all "UTIL".
            var slotFilled = [Bool](repeating: false, count: slots.count)
            // Mark slots that existing real players will occupy
            for p in pool {
                for (i, slot) in slots.enumerated() where !slotFilled[i] {
                    if playerFitsSlot(p, slot: slot) {
                        slotFilled[i] = true
                        break
                    }
                }
            }
            // Assign each stub using preloaded position when available, otherwise first available slot
            for pid in missingIDs {
                let preloadedPos = preloadedPlayerInfo[pid]?.position?.uppercased()
                // For two-way SP entries, force position to SP
                let knownPosition: String? = pid.hasSuffix("-sp") ? "SP" : preloadedPos
                
                var assignedPosition = "UTIL"
                if let knownPos = knownPosition {
                    // Try to fit into the correct positional slot based on known position
                    let stubPlayer = DFSPlayer(id: pid, name: "", team: "", position: knownPos, salary: 0, projectedPoints: 0)
                    for (i, slot) in slots.enumerated() where !slotFilled[i] {
                        if playerFitsSlot(stubPlayer, slot: slot) {
                            assignedPosition = knownPos
                            slotFilled[i] = true
                            break
                        }
                    }
                    // If the known position didn't match any open slot, fall back to any open slot
                    if assignedPosition == "UTIL" && knownPos != "UTIL" {
                        for (i, slot) in slots.enumerated() where !slotFilled[i] && slot != "UTIL" {
                            assignedPosition = slot
                            slotFilled[i] = true
                            break
                        }
                    }
                } else {
                    // No preloaded position — assign to first open non-UTIL slot
                    for (i, slot) in slots.enumerated() where !slotFilled[i] && slot != "UTIL" {
                        assignedPosition = slot
                        slotFilled[i] = true
                        break
                    }
                }
                // If only UTIL slots remain, try those
                if assignedPosition == "UTIL" {
                    for (i, slot) in slots.enumerated() where !slotFilled[i] {
                        assignedPosition = slot
                        slotFilled[i] = true
                        break
                    }
                }
                // Use preloaded info name, then entry record name, then raw ID as fallback
                let name = preloadedPlayerInfo[pid]?.name ?? entryNamesByID[pid] ?? pid
                let team = preloadedPlayerInfo[pid]?.team ?? "—"
                let sal = entrySalariesByID[pid] ?? 0
                pool.append(DFSPlayer(id: pid, name: name, team: team, position: assignedPosition, salary: sal, projectedPoints: 0))
            }
        } else {
            for pid in missingIDs {
                let name = preloadedPlayerInfo[pid]?.name ?? entryNamesByID[pid] ?? pid
                let team = preloadedPlayerInfo[pid]?.team ?? "—"
                let pos = pid.hasSuffix("-sp") ? "SP" : (preloadedPlayerInfo[pid]?.position?.uppercased() ?? "UTIL")
                let sal = entrySalariesByID[pid] ?? 0
                pool.append(DFSPlayer(id: pid, name: name, team: team, position: pos, salary: sal, projectedPoints: 0))
            }
        }
        guard let slots = tournament?.rosterSlots else { return pool }
        // Arrange selected players into their assigned slots
        var arranged = arrangeIntoSlots(pool, slots: slots)
        // In single-game mode, ensure the chosen MVP is at index 0
        if tournament?.isSingleGame == true, let mvpID = mvpPlayerID,
           let mvpIndex = arranged.firstIndex(where: { $0.id == mvpID }), mvpIndex != 0 {
            let mvp = arranged.remove(at: mvpIndex)
            arranged.insert(mvp, at: 0)
        }
        return arranged
    }

    /// Named roster slots for the current tournament (nil = generic slots).
    var rosterSlots: [String]? {
        tournament?.rosterSlots
    }

    /// Returns a label and fill status for each roster slot.
    var slotStatus: [(label: String, player: DFSPlayer?)] {
        guard let slots = rosterSlots else {
            return (0..<lineupSize).map { i in
                let p = i < selectedPlayers.count ? selectedPlayers[i] : nil
                return (label: "SLOT \(i + 1)", player: p)
            }
        }
        // Match each selected player to the best fitting slot (uses selectedPlayers for stub support)
        let pool = selectedPlayers
        var assigned = [DFSPlayer?](repeating: nil, count: slots.count)
        var remaining = pool

        // First pass: assign players to their exact position slot (not UTIL)
        for (i, slot) in slots.enumerated() where slot != "UTIL" {
            if let idx = remaining.firstIndex(where: { playerFitsSlot($0, slot: slot) }) {
                assigned[i] = remaining[idx]
                remaining.remove(at: idx)
            }
        }
        // Second pass: assign leftover players to UTIL slots
        for (i, slot) in slots.enumerated() where slot == "UTIL" && assigned[i] == nil {
            if let idx = remaining.firstIndex(where: { playerFitsSlot($0, slot: "UTIL") }) {
                assigned[i] = remaining[idx]
                remaining.remove(at: idx)
            }
        }

        return slots.enumerated().map { i, slot in
            (label: slot, player: assigned[i])
        }
    }

    /// Whether a player can fill an open roster slot.
    func canFillSlot(_ player: DFSPlayer) -> Bool {
        guard let slots = rosterSlots else { return true }
        let filled = selectedPlayers
        let filledCount = filled.count
        guard filledCount < slots.count else { return false }
        // Check if there's any unfilled slot this player's position can fill
        var slotTaken = [Bool](repeating: false, count: slots.count)
        // First pass: assign already-selected players to slots
        for p in filled {
            for (i, slot) in slots.enumerated() where !slotTaken[i] {
                if playerFitsSlot(p, slot: slot) {
                    slotTaken[i] = true
                    break
                }
            }
        }
        // Second pass: can the new player fit any remaining slot?
        for (i, slot) in slots.enumerated() where !slotTaken[i] {
            if playerFitsSlot(player, slot: slot) {
                return true
            }
        }
        return false
    }

    /// Check if a player's position is compatible with a slot label.
    private func playerFitsSlot(_ player: DFSPlayer, slot: String) -> Bool {
        let effectiveSport = sport
        switch slot {
        case "MVP":
            return true
        case "FLEX":
            if effectiveSport == "EPL" || effectiveSport == "UCL" {
                return player.position != "GK"
            }
            return true
        case "P":
            return player.position == "SP" || player.position == "RP" || player.position == "P"
        case "C/1B":
            return player.position == "C" || player.position == "1B"
        case "C":
            if effectiveSport == "NHL" { return player.position != "G" }
            if effectiveSport == "MLB" { return player.position == "C" }
            return player.position == "C" || player.position == "PF/C" || player.position == "C/PF"
        case "W", "D":
            if effectiveSport == "NHL" { return player.position != "G" }
            return player.position == slot
        case "G":
            if effectiveSport == "NHL" { return player.position == "G" }
            let pos = player.position
            return pos == "PG" || pos == "SG" || pos == "PG/SG" || pos == "SG/PG"
        case "F":
            let pos = player.position
            return pos == "SF" || pos == "PF" || pos == "SF/PF" || pos == "PF/SF"
        case "UTIL":
            if effectiveSport == "MLB" { return !["SP", "RP", "P"].contains(player.position) }
            if effectiveSport == "NHL" { return player.position != "G" }
            return true
        case "1B", "2B", "3B", "SS", "OF":
            return player.position == slot
        case "PG", "SG", "SF", "PF":
            return player.position == slot || player.position.contains(slot)
        case "GK", "DEF", "MID", "FWD":
            return player.position == slot
        default:
            return player.position == slot
        }
    }

    /// Arrange a set of players into roster slots using greedy assignment.
    private func arrangeIntoSlots(_ pool: [DFSPlayer], slots: [String]) -> [DFSPlayer] {
        var result = [DFSPlayer?](repeating: nil, count: slots.count)
        var remaining = pool
        // First pass: assign players to their most specific slot
        for (i, slot) in slots.enumerated() {
            if let idx = remaining.firstIndex(where: { playerFitsSlot($0, slot: slot) }) {
                result[i] = remaining[idx]
                remaining.remove(at: idx)
            }
        }
        return result.compactMap { $0 }
    }

    /// Total salary including MVP 1.5x premium for single-game slates.
    /// In single-game mode, the first selected player is the MVP and costs 1.5x.
    var selectedSalary: Int {
        guard tournament?.isSingleGame == true, !selectedPlayers.isEmpty else {
            return selectedPlayers.reduce(0) { $0 + $1.salary }
        }
        // First player is MVP (1.5x salary), rest are FLEX (1x)
        let mvpSalary = Int(Double(selectedPlayers[0].salary) * 1.5)
        let flexSalary = selectedPlayers.dropFirst().reduce(0) { $0 + $1.salary }
        return mvpSalary + flexSalary
    }

    /// The MVP premium amount (the extra 0.5x cost) for display purposes.
    var mvpSalaryPremium: Int {
        guard tournament?.isSingleGame == true, !selectedPlayers.isEmpty else { return 0 }
        return selectedPlayers[0].salary / 2  // 0.5x of base salary
    }

    var salaryCap: Int {
        tournament?.salaryCap ?? 50000
    }

    var salaryRemaining: Int {
        salaryCap - selectedSalary
    }

    var salaryProgress: Double {
        guard salaryCap > 0 else { return 0 }
        return Double(selectedSalary) / Double(salaryCap)
    }

    /// Whether the overall slate (first game) has started — used for main-slate tournaments.
    var isSlateLocked: Bool {
        Date() >= lockTime
    }

    /// Whether the currently active tournament is locked.
    /// - Main-slate tournaments (main1000, main10, main5wta, main3h2h) lock when the first game starts.
    /// - Single-game tournaments lock when their specific game starts.
    var isTournamentLocked: Bool {
        guard let tournament else { return false }
        return Date() >= lockTimeForTournament(tournament)
    }

    /// Returns the lock time for a specific tournament.
    func lockTimeForTournament(_ t: DFSTournament) -> Date {
        if t.tournamentType == .singleGame, let gid = t.gameID,
           let game = slateGames.first(where: { $0.id == gid }) {
            return game.startTime
        }
        if t.tournamentType.isEvening {
            // Evening tournaments lock at the first evening game
            let eveningCutoff: Date = {
                let cal = Calendar(identifier: .gregorian)
                let tz = TimeZone(identifier: "America/New_York")!
                var comps = cal.dateComponents(in: tz, from: Date())
                comps.hour = 18
                comps.minute = 0
                comps.second = 0
                return cal.date(from: comps) ?? .distantFuture
            }()
            let eveningStart = slateGames
                .filter { $0.startTime >= eveningCutoff }
                .map { $0.startTime }
                .min()
            return eveningStart ?? lockTime
        }
        // Main-slate tournaments lock at the earliest game
        return lockTime
    }

    /// Whether a specific tournament is locked (for UI display in lobby/contest list).
    func isTournamentLocked(_ t: DFSTournament) -> Bool {
        Date() >= lockTimeForTournament(t)
    }

    /// Returns tournaments that are still open for entry (not yet locked).
    var availableTournaments: [DFSTournament] {
        let now = Date()
        return tournaments.filter { now < lockTimeForTournament($0) }
    }

    /// Returns tournaments that are locked (games have started).
    var lockedTournaments: [DFSTournament] {
        let now = Date()
        return tournaments.filter { now >= lockTimeForTournament($0) }
    }

    /// Whether the slate is partially locked (some games started, some haven't).
    var isPartiallyLocked: Bool {
        !availableTournaments.isEmpty && !lockedTournaments.isEmpty
    }

    /// Whether all tournaments are locked (all games have started).
    var isFullyLocked: Bool {
        availableTournaments.isEmpty && !tournaments.isEmpty
    }

    /// Returns the opponent matchup string for a player, e.g. "vs. LAL" or "@CHI"
    func opponentLabel(for player: DFSPlayer) -> String? {
        guard let game = slateGames.first(where: { $0.id == player.gameID ?? "" }) else { return nil }
        // UFC: find the other fighter in the same bout
        if sport == "UFC" {
            if let opponent = players.first(where: { $0.gameID == player.gameID && $0.id != player.id }) {
                let lastName = opponent.name.split(separator: " ").last.map(String.init) ?? opponent.name
                return "vs. \(lastName)"
            }
            return nil
        }
        if player.team == game.homeTeam {
            return "vs. \(game.awayTeam)"
        } else {
            return "@\(game.homeTeam)"
        }
    }

    var currentUserEntry: DFSEntryRecord? {
        guard let userID else { return nil }
        // First check remoteEntries (loaded for the active tournament)
        if let entry = remoteEntries.first(where: { $0.userID == userID }) {
            return entry
        }
        // Fall back to cached userEntryRecords (pre-loaded at slate load time)
        // so we don't show "You haven't entered" while remoteEntries is loading
        if let tid = activeTournamentID {
            return entryRecord(for: tid, lineupNumber: activeLineupNumber)
        }
        return nil
    }

    var lockTime: Date {
        computeLockTime()
    }

    /// Lock at the earliest game start time so users can never submit after a game begins.
    private func computeLockTime() -> Date {
        return slateGames.map { $0.startTime }.min() ?? .distantFuture
    }

    var dfsHistory: [DFSResult] {
        guard let decoded = try? JSONDecoder().decode([DFSResult].self, from: dfsHistoryData) else {
            return []
        }
        return deduplicatedHistory(decoded)
    }

    var settledTournaments: Set<String> {
        guard let decoded = try? JSONDecoder().decode(Set<String>.self, from: settledTournamentData) else {
            return []
        }
        return decoded
    }

    private func markTournamentSettled(_ tournamentID: String) {
        var current = settledTournaments
        current.insert(tournamentID)
        settledTournamentData = (try? JSONEncoder().encode(current)) ?? Data()
    }

    /// Returns a display string for remaining game time for a field entry's players.
    /// Shows count of live/remaining games, e.g. "2 live", "Final", "3 pre"
    func timeRemainingLabel(for fieldEntry: DFSFieldEntry) -> String {
        let playersByID = Dictionary(uniqueKeysWithValues: activePlayers.map { ($0.id, $0) })
        var liveCount = 0
        var preCount = 0
        var finalCount = 0

        for pid in fieldEntry.playerIDs {
            guard let player = playersByID[pid], let gameID = player.gameID else { continue }
            if let info = liveGameInfo[gameID] {
                switch info.state {
                case "post": finalCount += 1
                case "in": liveCount += 1
                default: preCount += 1
                }
            } else {
                // No live info yet — check slate games
                if let slateGame = slateGames.first(where: { $0.id == gameID }) {
                    switch slateGame.state {
                    case "post": finalCount += 1
                    case "in": liveCount += 1
                    default: preCount += 1
                    }
                }
            }
        }

        let total = liveCount + preCount + finalCount
        if total == 0 { return "" }
        if finalCount == total { return "Final" }
        if liveCount > 0 && preCount > 0 { return "\(liveCount) live, \(preCount) pre" }
        if liveCount > 0 { return "\(liveCount) live" }
        return "\(preCount) pre"
    }

    var uniquePositions: [String] {
        let positions = Set(players.map { $0.position })
        let ordered: [String]
        switch sport {
        case "PGA":
            return ["G"]
        case "MLB":
            // Always include UTIL as a filter since it's a roster slot (shows all batters)
            ordered = ["P", "C", "1B", "2B", "3B", "SS", "OF", "UTIL"]
            return ordered.filter { $0 == "UTIL" || positions.contains($0) }
        case "NHL":
            ordered = ["C", "W", "D", "G", "UTIL"]
            return ordered.filter { $0 == "UTIL" || positions.contains($0) }
        case "NFL", "CFB":
            ordered = ["QB", "RB", "WR", "TE", "K", "DEF", "FLEX"]
            return ordered.filter { $0 == "FLEX" || positions.contains($0) }
        case "NBA", "NCAAM":
            ordered = ["PG", "SG", "SF", "PF", "C"]
        default:
            ordered = ["PG", "SG", "SF", "PF", "C"]
        }
        return ordered.filter { positions.contains($0) }
    }

    /// Game matchup labels for the lineup builder filter pills, e.g. "WSH @ DET"
    /// Game IDs for games that are already final ("post") — used to exclude
    /// finished games from the lineup builder so users only draft from live/upcoming games.
    private var postGameIDs: Set<String> {
        Set(slateGames.filter { $0.state == "post" }.map { $0.id })
    }

    /// Only includes games that actually have players fetched and are not already final.
    var gameMatchupLabels: [(id: String, label: String)] {
        let playerGameIDs = Set(players.compactMap { $0.gameID })
        let excludedIDs = postGameIDs
        return slateGames.compactMap { game in
            guard playerGameIDs.contains(game.id), !excludedIDs.contains(game.id) else { return nil }
            return (id: game.id, label: "\(game.awayTeam) @ \(game.homeTeam)")
        }
    }

    var filteredPlayers: [DFSPlayer] {
        // Use the tournament-appropriate player pool (single-game adjusted or main slate)
        let pool = activePlayers
        // Exclude players from games that are already final
        // PGA has a single "game" representing the whole tournament — once it starts,
        // postGameIDs would exclude all golfers, so skip filtering for PGA
        var result: [DFSPlayer]
        if sport == "PGA" {
            result = pool
        } else {
            let excludedIDs = postGameIDs
            result = pool.filter { player in
                guard let gid = player.gameID else { return true }
                return !excludedIDs.contains(gid)
            }
        }

        // Hide backup goalies when confirmed starters are known for their team
        if sport == "NHL" {
            let teamsWithStarters = Set(result.filter { $0.position == "G" && $0.isStartingGoalie }.map { $0.team })
            if !teamsWithStarters.isEmpty {
                result = result.filter { player in
                    guard player.position == "G" else { return true }
                    // If this team has a confirmed starter, only show the starter
                    guard teamsWithStarters.contains(player.team) else { return true }
                    return player.isStartingGoalie
                }
            }
        }

        if let filter = selectedPositionFilter {
            if filter == "UTIL" && sport == "MLB" {
                // UTIL shows all non-pitcher batters
                let pitcherPositions: Set<String> = ["SP", "RP", "P"]
                result = result.filter { !pitcherPositions.contains($0.position) }
            } else if filter == "UTIL" && sport == "NHL" {
                // UTIL shows all skaters (not goalies)
                result = result.filter { $0.position != "G" }
            } else if filter == "FLEX" && (sport == "NFL" || sport == "CFB") {
                // FLEX shows RB, WR, TE (not QB, K, DEF)
                let flexPositions: Set<String> = ["RB", "WR", "TE"]
                result = result.filter { flexPositions.contains($0.position) }
            } else if filter == "P" && sport == "MLB" {
                // P slot accepts SP and RP
                result = result.filter { $0.position == "SP" || $0.position == "RP" }
            } else if filter == "C/1B" {
                result = result.filter { $0.position == "C" || $0.position == "1B" }
            } else {
                result = result.filter { $0.position == filter }
            }
        }

        if let gameFilter = selectedGameFilter {
            result = result.filter { $0.gameID == gameFilter }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                $0.team.lowercased().contains(query)
            }
        }

        switch sortOrder {
        case .salary:
            result.sort { $0.salary > $1.salary }
        case .projected:
            result.sort { $0.projectedPoints > $1.projectedPoints }
        case .name:
            result.sort { $0.name < $1.name }
        case .position:
            let posOrder: [String: Int] = [
                "PG": 0, "SG": 1, "SF": 2, "PF": 3, "C": 4,  // NBA
                "SP": 10, "RP": 11, "1B": 12, "2B": 13, "3B": 14, "SS": 15, "OF": 16, "UTIL": 17,  // MLB
                "W": 20, "D": 21, "G": 22,  // NHL
                "GK": 30, "DEF": 31, "MID": 32, "FWD": 33,  // Soccer
                "QB": 40, "RB": 41, "WR": 42, "TE": 43, "K": 44, "FLEX": 45,  // Football
            ]
            result.sort {
                let a = posOrder[$0.position] ?? 9
                let b = posOrder[$1.position] ?? 9
                if a != b { return a < b }
                return $0.salary > $1.salary // within same position, sort by salary
            }
        }

        return result
    }

    var lineupSize: Int {
        tournament?.lineupSize ?? 7
    }

    var lineupValidationMessage: String? {
        guard let tournament else { return nil }
        let count = selectedPlayers.count
        if count < tournament.lineupSize {
            let remaining = tournament.lineupSize - count
            // Show which positions still need filling
            if let slots = rosterSlots {
                let filled = selectedPlayers
                var slotTaken = [Bool](repeating: false, count: slots.count)
                for p in filled {
                    for (i, slot) in slots.enumerated() where !slotTaken[i] {
                        if playerFitsSlot(p, slot: slot) { slotTaken[i] = true; break }
                    }
                }
                let openSlots = slots.enumerated().filter { !slotTaken[$0.offset] }.map { $0.element }
                let uniqueOpen = Array(Set(openSlots)).sorted()
                return "Need: \(uniqueOpen.joined(separator: ", "))"
            }
            return "Select \(remaining) more player\(remaining == 1 ? "" : "s")"
        }
        if selectedSalary > tournament.salaryCap {
            let over = selectedSalary - tournament.salaryCap
            return "Over salary cap by $\(formatSalary(over))"
        }
        return nil
    }

    var canSubmitLineup: Bool {
        guard let tournament else { return false }
        return !isTournamentLocked
            && selectedPlayers.count == tournament.lineupSize
            && selectedSalary <= tournament.salaryCap
    }

    // MARK: - Actions

    func togglePlayer(_ player: DFSPlayer) {
        if selectedPlayerIDs.contains(player.id) {
            selectedPlayerIDs.remove(player.id)
            // If the removed player was the MVP, clear the MVP selection
            if mvpPlayerID == player.id {
                mvpPlayerID = nil
            }
            return
        }
        guard selectedPlayerIDs.count < lineupSize else { return }
        // If roster slots are defined, check position compatibility
        if rosterSlots != nil {
            guard canFillSlot(player) else { return }
        }
        selectedPlayerIDs.insert(player.id)
        // In single-game mode, auto-set the first added player as MVP
        if tournament?.isSingleGame == true && mvpPlayerID == nil {
            mvpPlayerID = player.id
        }
    }

    func removePlayer(_ player: DFSPlayer) {
        selectedPlayerIDs.remove(player.id)
        if mvpPlayerID == player.id {
            mvpPlayerID = nil
        }
    }

    /// Designate a player as the MVP in single-game mode.
    func setMVP(_ player: DFSPlayer) {
        guard tournament?.isSingleGame == true,
              selectedPlayerIDs.contains(player.id) else { return }
        mvpPlayerID = player.id
    }

    func loadSlateIfNeeded() async {
        if tournament == nil {
            await loadSlate(force: false)
        }
    }

    /// Fetch the user's entries from Supabase independently of slate loading.
    /// Extracts the sport-date prefix (e.g. "mlb-20260507") from a tournament ID.
    /// This is used to filter entries for the current sport + date.
    private func sportDatePrefix(from tournamentID: String) -> String {
        let prefixLen = tournamentID.hasPrefix("ncaam-") ? 6 : (sport.count + 1) // "nba-" = 4, "mlb-" = 4, "nhl-" = 4, "ncaam-" = 6
        let afterPrefix = tournamentID.dropFirst(prefixLen)
        let dateStr = String(afterPrefix.prefix(8)) // "YYYYMMDD"
        return "\(sport.lowercased())-\(dateStr)"
    }

    /// Call this when the DFS tab appears to ensure entries are always fresh,
    /// even if the initial fetch during loadSlate() failed silently.
    func fetchEntriesIfNeeded() async {
        guard let userID, let token = accessToken else { return }
        guard let mainID = tournaments.first?.id else { return }
        // Skip if we already have entries populated
        guard enteredTournamentIDs.isEmpty else { return }

        let prefix = sportDatePrefix(from: mainID)
        do {
            let allUserEntries = try await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)
            let todayEntries = allUserEntries.filter { $0.tournamentID.hasPrefix(prefix) }
            if !todayEntries.isEmpty {
                enteredTournamentIDs = Set(todayEntries.map(\.tournamentID))
                userEntryRecords = Dictionary(grouping: todayEntries, by: \.tournamentID)
                ensureInstanceTournamentsExist()
            }
        } catch {
            print("[DFS] fetchEntriesIfNeeded failed: \(error.localizedDescription)")
        }
    }

    func loadSlate(force: Bool) async {
        if isLoading { return }
        if !force && tournament != nil { return }

        isLoading = true
        error = nil
        do {
            let slate = try await slateProvider.fetchSlate()
            let previousID = tournament?.id
            tournaments = slate.tournaments
            singleGamePlayers = slate.singleGamePlayers
            // If no active tournament selected, default to the first (main) tournament
            if activeTournamentID == nil {
                activeTournamentID = slate.tournaments.first?.id
            }
            slateGames = slate.includedGames
            // Enforce minimum salary — prevents $0 display from missing/stale salary data
            players = slate.players.map { p in
                let minSal: Int
                if sport == "PGA" {
                    minSal = 6000
                } else if sport == "MLB" {
                    minSal = (p.position == "SP" || p.position == "RP") ? 6000 : 2000
                } else if sport == "NHL" {
                    minSal = 3000
                } else if sport == "NFL" || sport == "CFB" {
                    minSal = 3000
                } else {
                    minSal = 3500
                }
                guard p.salary < minSal else { return p }
                return DFSPlayer(id: p.id, name: p.name, team: p.team, position: p.position,
                                 salary: minSal, projectedPoints: p.projectedPoints,
                                 gameID: p.gameID, injuryStatus: p.injuryStatus,
                                 battingOrder: p.battingOrder)
            }
            // Build evening player pool (games at 6pm ET or later)
            let eveningCutoff: Date = {
                let cal = Calendar(identifier: .gregorian)
                let tz = TimeZone(identifier: "America/New_York")!
                var comps = cal.dateComponents(in: tz, from: Date())
                comps.hour = 18
                comps.minute = 0
                comps.second = 0
                return cal.date(from: comps) ?? .distantFuture
            }()
            let eveningGameIDs = Set(slateGames.filter { $0.startTime >= eveningCutoff }.map { $0.id })
            eveningPlayers = players.filter { eveningGameIDs.contains($0.gameID ?? "") }

            // Populate entry tracking from the user's recent entries across all tournaments
            if let mainID = slate.tournaments.first?.id,
               let userID, let token = accessToken {
                let prefix = sportDatePrefix(from: mainID)
                // First try from already-loaded remoteEntries (fast path)
                let fromRemote = remoteEntries.filter { $0.tournamentID.hasPrefix(prefix) }
                if !fromRemote.isEmpty {
                    enteredTournamentIDs = Set(fromRemote.map(\.tournamentID))
                    userEntryRecords = Dictionary(grouping: fromRemote, by: \.tournamentID)
                } else {
                    // Fetch from Supabase to discover all entered tournaments
                    let allUserEntries: [DFSEntryRecord]
                    do {
                        allUserEntries = try await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)
                    } catch {
                        print("[DFS] Failed to fetch user entries on slate load: \(error.localizedDescription)")
                        allUserEntries = []
                    }
                    let todayEntries = allUserEntries.filter { $0.tournamentID.hasPrefix(prefix) }
                    enteredTournamentIDs = Set(todayEntries.map(\.tournamentID))
                    userEntryRecords = Dictionary(grouping: todayEntries, by: \.tournamentID)
                }
                // Re-create instance tournaments so they appear in "Your Lineups"
                ensureInstanceTournamentsExist()

                // PGA: Also include recent entries from previous events (last 7 days)
                // so they show as active contests in the locked view until settled.
                if sport == "PGA" {
                    let recentCutoff = Date().addingTimeInterval(-7 * 24 * 3600)
                    let fetchedPGA = (try? await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)) ?? []
                    let allRecentPGA = fetchedPGA.filter {
                        $0.tournamentID.hasPrefix("pga-")
                        && ($0.submittedAt ?? .distantPast) > recentCutoff
                    }
                    let existingTIDs = Set(tournaments.map(\.id))
                    let settledIDs = settledTournaments
                    // Collect tournament IDs that need synthetic objects
                    var needsSynthetic: [String] = []
                    for entry in allRecentPGA {
                        let tid = entry.tournamentID
                        guard !settledIDs.contains(tid) else { continue }
                        enteredTournamentIDs.insert(tid)
                        if userEntryRecords[tid] == nil {
                            userEntryRecords[tid] = [entry]
                        } else if !userEntryRecords[tid]!.contains(where: { $0.id == entry.id }) {
                            userEntryRecords[tid]!.append(entry)
                        }
                        if !existingTIDs.contains(tid) {
                            needsSynthetic.append(tid)
                        }
                    }
                    // Fetch titles from Supabase for synthetic tournaments
                    var titleCache: [String: String] = [:]
                    for tid in Set(needsSynthetic) {
                        if let record = try? await SupabaseService.shared.fetchTournament(
                            tournamentID: tid, accessToken: token
                        ) {
                            titleCache[tid] = record.title
                        }
                    }
                    for tid in needsSynthetic where !tournaments.contains(where: { $0.id == tid }) {
                        let entryCount = Self.entryCountFromTournamentID(tid)
                        let title = titleCache[tid] ?? "PGA Tournament"
                        tournaments.append(DFSTournament(
                            id: tid, title: title, league: "PGA",
                            entryCount: entryCount, lineupSize: 6,
                            salaryCap: 50000
                        ))
                    }
                }
            } else if let mainID = slate.tournaments.first?.id {
                let prefix = sportDatePrefix(from: mainID)
                enteredTournamentIDs = Set(
                    remoteEntries
                        .map(\.tournamentID)
                        .filter { $0.hasPrefix(prefix) }
                )
            }
            if previousID != tournament?.id {
                // Save outgoing tournament to cache
                if let prevID = previousID, fieldGenerated, !fieldEntries.isEmpty {
                    liveContestCache[prevID] = LiveContestCache(
                        fieldEntries: fieldEntries,
                        leaderboard: leaderboardEntries,
                        remoteEntries: remoteEntries,
                        profileNames: remoteProfileNames,
                        fieldGenerated: true
                    )
                }
                selectedPlayerIDs = []
                latestResult = nil
                livePlayerStats = [:]
                liveGameInfo = [:]
                // Restore from cache if available
                if let tid = tournament?.id, let cached = liveContestCache[tid] {
                    fieldEntries = cached.fieldEntries
                    leaderboardEntries = cached.leaderboard
                    remoteEntries = cached.remoteEntries
                    remoteProfileNames = cached.profileNames
                    fieldGenerated = true
                } else {
                    leaderboardEntries = []
                    fieldEntries = []
                    remoteEntries = []
                    remoteProfileNames = [:]
                }
            }
            // Reset field generation flag on force reload or new tournament (unless restored from cache)
            if force {
                fieldGenerated = false
            } else if previousID != tournament?.id, liveContestCache[tournament?.id ?? ""] == nil {
                fieldGenerated = false
            }
            // Restore latestResult from history for this tournament so the
            // active-contest card shows rank/score immediately (before refreshLive)
            if latestResult == nil, let tid = tournament?.id {
                let historyMatches = dfsHistory.filter { $0.tournamentId == tid }
                if let exact = historyMatches.first(where: { ($0.lineupNumber ?? 1) == activeLineupNumber }) {
                    latestResult = exact
                } else if let any = historyMatches.first {
                    latestResult = any
                }
            }
            await syncTournamentBackend()
        } catch {
            // Only show error if we don't already have a tournament loaded
            if tournament == nil {
                self.error = "Unable to load DFS slate."
            }
        }
        isLoading = false
        hasAttemptedLoad = true
        await loadPendingInvites()
    }

    /// Whether we've already built the simulated field for this tournament
    private var fieldGenerated = false

    /// Whether a player matches a roster slot requirement.
    /// Handles DK roster slots: NBA (PG/SG/SF/PF/C/G/F/UTIL), MLB (P/C/1B/2B/3B/SS/OF),
    /// NHL (C/W/D/UTIL/G), Soccer (GK/DEF/MID/FWD/FLEX).
    private func playerMatchesSlot(_ player: DFSPlayer, slot: String) -> Bool {
        let effectiveSport = sport
        switch slot {
        case "MVP":
            return true
        case "FLEX":
            // Soccer FLEX excludes goalkeepers
            if effectiveSport == "EPL" || effectiveSport == "UCL" {
                return player.position != "GK"
            }
            return true
        case "P":
            return player.position == "SP" || player.position == "RP" || player.position == "P"
        case "C/1B":
            return player.position == "C" || player.position == "1B"
        case "C":
            if effectiveSport == "NHL" {
                // NHL center slot accepts any skater (position data is imprecise)
                return player.position != "G"
            }
            if effectiveSport == "MLB" {
                return player.position == "C"
            }
            // NBA center
            return player.position == "C" || player.position == "PF/C" || player.position == "C/PF"
        case "W", "D":
            if effectiveSport == "NHL" {
                // NHL skater slots accept any skater — during settlement
                // we often can't distinguish exact positions from box score data.
                return player.position != "G"
            }
            return player.position == slot
        case "G":
            if effectiveSport == "NHL" {
                return player.position == "G"
            }
            // NBA guard slot (G = PG or SG)
            let pos = player.position
            return pos == "PG" || pos == "SG" || pos == "PG/SG" || pos == "SG/PG"
        case "F":
            // NBA forward slot (F = SF or PF)
            let pos = player.position
            return pos == "SF" || pos == "PF" || pos == "SF/PF" || pos == "PF/SF"
        case "UTIL":
            if effectiveSport == "MLB" {
                let pitcherPositions: Set<String> = ["SP", "RP", "P"]
                return !pitcherPositions.contains(player.position)
            }
            if effectiveSport == "NHL" {
                // UTIL = any skater (not goalie)
                return player.position != "G"
            }
            // NBA/other: UTIL = any player
            return true
        case "1B", "2B", "3B", "SS", "OF":
            // MLB individual position slots
            return player.position == slot
        case "PG", "SG", "SF", "PF":
            // NBA individual position slots — also accept dual positions
            let pos = player.position
            return pos == slot || pos.contains(slot)
        default:
            return player.position == slot
        }
    }

    /// Build a competitive bot lineup with varied strategies, injury-adjusted projections,
    /// position diversity, salary cap enforcement, and budget optimization.
    private func generateBotLineup(from players: [DFSPlayer], salaryCap: Int, lineupSize: Int, rosterSlots: [String]? = nil, isSingleGame: Bool = false, sportOverride: String? = nil) -> [String] {
        // Use sportOverride when provided (e.g., during settlement of a different sport's tournament)
        let effectiveSport = sportOverride ?? sport
        // PGA bots have no position constraints — use salary-weighted random generation
        if effectiveSport == "PGA" {
            return generateGolfBotLineup(from: players, salaryCap: salaryCap, lineupSize: lineupSize)
        }
        // DraftKings Showdown uses MVP + 5 FLEX with no position requirements,
        // so no goalie override needed for NHL single-game.
        let effectiveRosterSlots: [String]? = rosterSlots
        // Filter out injured/out/IL players and zero-projection bench warmers.
        // NHL uses a higher projection floor (6.0) to exclude healthy scratches and
        // AHL call-ups who technically have roster spots but won't dress.
        // For single-game NHL, use a lower floor (3.0) so goalies aren't excluded.
        let projFloor: Double
        if effectiveSport == "NHL" {
            projFloor = isSingleGame ? 3.0 : 6.0
        } else {
            projFloor = 1.0
        }
        let eligible = players.filter { p in
            let status = p.injuryStatus ?? ""
            var isOut = status == "O" || status == "D" || status.hasPrefix("IL")
            // NHL: GTD players frequently don't dress — exclude from bot pool
            if effectiveSport == "NHL" && status == "GTD" { isOut = true }
            // NHL: require minimum games played to filter AHL call-ups and reserves.
            // Single-game uses a lower threshold (5) so young starters aren't excluded.
            let minGP = isSingleGame ? 5 : 20
            if effectiveSport == "NHL", let gp = p.gamesPlayed, gp < minGP { isOut = true }
            // NHL single-game: confirmed starting goalies are NEVER excluded regardless of GP
            if effectiveSport == "NHL" && p.position == "G" && p.isStartingGoalie { isOut = false }
            // NHL goalies use a lower projection floor — they naturally score fewer
            // fantasy points than skaters but are required roster positions
            let floor = (effectiveSport == "NHL" && p.position == "G") ? 1.0 : projFloor
            return !isOut && p.projectedPoints > floor
        }

        // Strongly prefer confirmed active players (matched by real salary data).
        // NHL uses a lower threshold because RotoGrinders NHL pools are smaller.
        let confirmed = eligible.filter { $0.isConfirmedActive }
        let confirmedThreshold = (effectiveSport == "NHL") ? lineupSize + 5 : lineupSize * 2
        let useConfirmedPool = confirmed.count >= confirmedThreshold

        // For MLB: strongly prefer confirmed starters to avoid drafting bench players.
        // Strategy: use battingOrder when available; fall back to projection threshold.
        let hasRosterSlots = effectiveRosterSlots != nil
        let botPool: [DFSPlayer]
        // Track whether we have MLB batting order data to boost confirmed starters in weighting
        var mlbHasBattingOrders = false
        if hasRosterSlots, let slots = effectiveRosterSlots {
            // Check that a candidate pool can fill every required position slot
            func coversAllSlots(_ pool: [DFSPlayer]) -> Bool {
                for slot in Set(slots) {
                    let hasMatch = pool.contains { self.playerMatchesSlot($0, slot: slot) }
                    if !hasMatch { return false }
                }
                return true
            }

            // Start with confirmed active players if available (matched by real salary data)
            let basePool = useConfirmedPool ? confirmed : eligible

            let confirmedStarters = basePool.filter { $0.battingOrder != nil || $0.position == "SP" }
            if effectiveSport == "MLB" && !confirmedStarters.isEmpty {
                mlbHasBattingOrders = true
            }
            if confirmedStarters.count >= lineupSize + 5 && coversAllSlots(confirmedStarters) {
                // Batting orders available and cover all positions — use confirmed starters only
                botPool = confirmedStarters
            } else if effectiveSport == "MLB" && mlbHasBattingOrders && coversAllSlots(confirmedStarters) {
                // Some batting orders available but not enough to fill pool exclusively —
                // use full pool but weighting will heavily prefer confirmed starters
                botPool = basePool
            } else {
                // Batting orders not yet posted or don't cover all positions —
                // use projection/salary as a proxy.
                let likelyStarters = basePool.filter { $0.projectedPoints >= 6.0 || $0.position == "SP" || $0.position == "G" }
                if likelyStarters.count >= lineupSize * 2 && coversAllSlots(likelyStarters) {
                    botPool = likelyStarters
                } else {
                    // Fall back to full eligible pool (confirmed first, then all)
                    botPool = useConfirmedPool && coversAllSlots(confirmed) ? confirmed : eligible
                }
            }
        } else {
            // NHL, NBA, NCAAM — use confirmed active pool when available
            if useConfirmedPool {
                botPool = confirmed
            } else {
                botPool = eligible
            }
        }

        // For NHL, restrict the upgrade pass to confirmed-active players only
        // to prevent swapping in healthy scratches during salary optimization.
        // For MLB, restrict to confirmed starters when batting orders are available
        // to prevent upgrading into bench players who will score 0.
        let upgradePool: [DFSPlayer]
        if effectiveSport == "NHL" && !confirmed.isEmpty {
            upgradePool = confirmed
        } else if effectiveSport == "MLB" && mlbHasBattingOrders {
            let starterUpgrades = botPool.filter { $0.battingOrder != nil || $0.position == "SP" }
            upgradePool = starterUpgrades.isEmpty ? botPool : starterUpgrades
        } else {
            upgradePool = botPool
        }

        guard botPool.count >= lineupSize else {
            return players.shuffled().prefix(lineupSize).map(\.id)
        }

        // Scramble projections so each bot sees a different player landscape.
        // This is the primary source of lineup diversity.
        // Single-game contests have small pools (~12 players for 6 slots), so
        // use much heavier noise + random exclusions to prevent identical lineups.
        // Soccer/EPL/UCL needs very heavy noise because the confirmed starter pool
        // is tiny (~22 players for 8 slots) and projections cluster tightly.
        let avgProj = botPool.reduce(0.0) { $0 + $1.projectedPoints } / Double(botPool.count)
        let isSoccer = effectiveSport == "EPL" || effectiveSport == "UCL"
        let noiseMagnitude: Double
        if isSingleGame {
            noiseMagnitude = max(avgProj * 0.7, 4.0) // 70% noise for single-game
        } else if isSoccer {
            noiseMagnitude = max(avgProj * 1.0, 6.0) // 100% noise for soccer — pool is tiny
        } else {
            noiseMagnitude = max(avgProj * 0.35, 2.0)
        }
        // Single-game & soccer: randomly exclude players to force different combinations.
        // Soccer pools are tiny (~22 starters for 8 slots) so excluding 3-6 players
        // is the strongest lever for lineup diversity.
        var sgExcludedIDs = Set<String>()
        if isSingleGame && botPool.count > lineupSize + 2 {
            // MLB single-game: exclude 2-4 starters for maximum diversity with ~18 batters.
            // NHL/NBA: exclude 1-2 since pools are slightly larger.
            let maxExclude: Int
            if effectiveSport == "MLB" {
                maxExclude = min(4, botPool.count - lineupSize - 1)
            } else {
                maxExclude = min(2, botPool.count - lineupSize - 1)
            }
            let excludeCount = maxExclude > 1 ? Int.random(in: 1...maxExclude) : 1
            // Never exclude confirmed starting goalies from NHL pools
            // Never exclude starting pitchers from MLB pools
            let excludable = botPool.filter { p in
                if effectiveSport == "NHL" && p.position == "G" && (p.isStartingGoalie || (p.isConfirmedActive && (p.gamesPlayed ?? 0) >= 30)) { return false }
                if effectiveSport == "MLB" && (p.position == "SP" || p.position == "RP") { return false }
                return true
            }
            let shuffledPool = excludable.shuffled()
            for p in shuffledPool.prefix(excludeCount) {
                sgExcludedIDs.insert(p.id)
            }
        } else if isSoccer && botPool.count > lineupSize + 3 {
            // Exclude 3-6 players per bot to force very different combinations.
            // With ~22 starters and 8 slots, excluding 3-6 is aggressive but necessary.
            let maxExclude = min(6, botPool.count - lineupSize - 1)
            let excludeCount = maxExclude > 3 ? Int.random(in: 3...maxExclude) : max(1, maxExclude)
            let shuffledPool = botPool.shuffled()
            for p in shuffledPool.prefix(excludeCount) {
                sgExcludedIDs.insert(p.id)
            }
        }
        let scrambled: [DFSPlayer] = botPool.compactMap { p in
            if sgExcludedIDs.contains(p.id) { return nil }
            let noise = Double.random(in: -noiseMagnitude...noiseMagnitude)
            let newProj = max(p.projectedPoints + noise, 0.5)
            var scrambledPlayer = DFSPlayer(
                id: p.id, name: p.name, team: p.team, position: p.position,
                salary: p.salary, projectedPoints: newProj, gameID: p.gameID,
                injuryStatus: p.injuryStatus, battingOrder: p.battingOrder
            )
            scrambledPlayer.gamesPlayed = p.gamesPlayed
            scrambledPlayer.playedRecently = p.playedRecently
            scrambledPlayer.isConfirmedActive = p.isConfirmedActive
            scrambledPlayer.isStartingGoalie = p.isStartingGoalie
            return scrambledPlayer
        }

        let originalSlots: [String?] = effectiveRosterSlots?.map { Optional($0) } ?? [String?](repeating: nil, count: lineupSize)

        // For NHL classic, draft the goalie early (pick 3) so budget isn't exhausted
        // on skaters first. This ensures all starting goalies are affordable and the
        // flatter goalie weighting produces real ownership diversity.
        // We build a pick-order that moves "G" earlier, then reorder results back.
        let pickOrder: [Int]
        if effectiveSport == "NHL" && !isSingleGame,
           let gIdx = originalSlots.firstIndex(where: { $0 == "G" }), gIdx > 2 {
            // Move goalie slot to pick index 2 (3rd overall)
            var order = Array(0..<lineupSize)
            order.remove(at: gIdx)
            order.insert(gIdx, at: 2)
            pickOrder = order
        } else {
            pickOrder = Array(0..<lineupSize)
        }
        let slots = originalSlots

        // NHL and NBA bots must spend closer to the cap — with 8 players and $50K cap,
        // underspending makes contests trivially easy.
        // Soccer uses a lower floor because the tiny pool (~22 players) means forcing
        // 92%+ spend causes all bots to converge on the same high-salary players.
        // Single-game modes use variable floors for lineup diversity — small pools
        // with tight spending requirements cause all bots to converge on the same players.
        let minSpendPct: Double
        if isSingleGame {
            // Single-game: variable spend floor creates realistic salary diversity.
            // MLB single-game has only ~18 eligible batters for 6 slots — too tight
            // to force 95% spend without convergence. Other sports also benefit.
            switch effectiveSport {
            case "MLB":
                minSpendPct = Double.random(in: 0.85...0.96) // $42.5K-$48K of $50K
            case "NHL", "NBA", "NCAAM":
                minSpendPct = Double.random(in: 0.88...0.96) // $44K-$48K of $50K
            default:
                minSpendPct = Double.random(in: 0.86...0.95) // Soccer/other
            }
        } else if effectiveSport == "NHL" || effectiveSport == "NBA" || effectiveSport == "NCAAM" {
            minSpendPct = 0.95
        } else if isSoccer {
            minSpendPct = 0.82  // Allow more salary variance for diversity
        } else {
            minSpendPct = 0.92
        }
        let minSpend = Int(Double(salaryCap) * minSpendPct)
        let cheapestSalary = scrambled.map(\.salary).min() ?? 3000

        // Bot personality — 5 styles for more variety
        let botStyle = Int.random(in: 0..<5)

        // Try up to 50 times to build a valid lineup (more retries needed for tight 95% floors)
        for _ in 0..<50 {
            var selectedBySlot: [Int: DFSPlayer] = [:]
            var budgetLeft = salaryCap
            var usedIDs = Set<String>()
            var pool = scrambled

            for (draftStep, slotIndex) in pickOrder.enumerated() {
                let slotsLeft = lineupSize - draftStep
                let slotsAfter = slotsLeft - 1

                // Reserve budget for remaining slots at minimum salary
                let reserveForRest = slotsAfter * cheapestSalary
                let maxForThisPick = budgetLeft - reserveForRest

                // Filter to affordable players within the max for this pick
                // Single-game MVP costs 1.5x, so limit to players whose 1.5x salary fits
                let mvpPick = isSingleGame && slotIndex == 0
                var affordable = pool.filter { mvpPick ? Int(Double($0.salary) * 1.5) <= maxForThisPick : $0.salary <= maxForThisPick }

                // If this slot requires a specific position, filter by position
                if let requiredPos = slots[slotIndex] {
                    affordable = affordable.filter { playerMatchesSlot($0, slot: requiredPos) }
                }

                // NHL goalie handling: Remove backup goalies from the pool.
                // For main slate (G slot): filter affordable to only starting goalies.
                // For single-game (FLEX slots): remove backup goalies from the pool
                // entirely so bots only roster confirmed starters.
                if effectiveSport == "NHL" && slots[slotIndex] == "G" {
                    // Main slate G slot — filter to starting goalies only
                    let confirmedStarters = affordable.filter { $0.isStartingGoalie }
                    if !confirmedStarters.isEmpty {
                        affordable = confirmedStarters
                    } else {
                        // Group goalies by team, pick the one with the most games played per team
                        var bestGoaliePerTeam: [String: DFSPlayer] = [:]
                        for goalie in affordable {
                            let team = goalie.team
                            if let existing = bestGoaliePerTeam[team] {
                                if (goalie.gamesPlayed ?? 0) > (existing.gamesPlayed ?? 0) {
                                    bestGoaliePerTeam[team] = goalie
                                }
                            } else {
                                bestGoaliePerTeam[team] = goalie
                            }
                        }
                        let starters = Array(bestGoaliePerTeam.values)
                        if !starters.isEmpty {
                            affordable = starters
                        }
                    }
                }
                // Single-game NHL FLEX slots: also remove backup goalies so bots
                // never draft non-starting goalies in showdown format.
                if effectiveSport == "NHL" && isSingleGame && slots[slotIndex] != "G" {
                    let goaliesInPool = affordable.filter { $0.position == "G" }
                    let confirmedGoalies = goaliesInPool.filter { $0.isStartingGoalie }
                    if !confirmedGoalies.isEmpty {
                        // Remove all non-starting goalies; keep all non-goalies + confirmed starters
                        let confirmedGoalieIDs = Set(confirmedGoalies.map { $0.id })
                        affordable = affordable.filter { p in
                            if p.position == "G" { return confirmedGoalieIDs.contains(p.id) }
                            return true
                        }
                    } else if goaliesInPool.count > 1 {
                        // No confirmed starters — keep only the best goalie per team by GP
                        var bestGoaliePerTeam: [String: DFSPlayer] = [:]
                        for goalie in goaliesInPool {
                            if let existing = bestGoaliePerTeam[goalie.team] {
                                if (goalie.gamesPlayed ?? 0) > (existing.gamesPlayed ?? 0) {
                                    bestGoaliePerTeam[goalie.team] = goalie
                                }
                            } else {
                                bestGoaliePerTeam[goalie.team] = goalie
                            }
                        }
                        let keepGoalieIDs = Set(bestGoaliePerTeam.values.map { $0.id })
                        affordable = affordable.filter { p in
                            if p.position == "G" { return keepGoalieIDs.contains(p.id) }
                            return true
                        }
                    }
                }

                // Soccer GK slot: pick one keeper per team so ownership spreads
                // across all starting GKs (~6 per slate with 6 matches).
                if isSoccer && slots[slotIndex] == "GK" {
                    var bestGKPerTeam: [String: DFSPlayer] = [:]
                    for gk in affordable {
                        if let existing = bestGKPerTeam[gk.team] {
                            if gk.projectedPoints > existing.projectedPoints {
                                bestGKPerTeam[gk.team] = gk
                            }
                        } else {
                            bestGKPerTeam[gk.team] = gk
                        }
                    }
                    let startingGKs = Array(bestGKPerTeam.values)
                    if !startingGKs.isEmpty {
                        affordable = startingGKs
                    }
                }

                guard !affordable.isEmpty else { break }

                // Target salary for this pick to evenly distribute remaining budget
                let targetSalary = slotsLeft > 0 ? budgetLeft / slotsLeft : budgetLeft

                // NHL goalie slot: use flatter weighting so ownership spreads
                // across all starting goalies (typically 2-4 per slate).
                // Real DFS goalie ownership is much more even than skaters.
                let isGoalieSlot = slots[slotIndex] == "G"

                // Score each player — lower exponents = more randomness
                let isGKSlot = isSoccer && slots[slotIndex] == "GK"
                let weights: [Double] = affordable.map { p in
                    let proj = max(p.projectedPoints, 0.5)
                    let value = proj / max(Double(p.salary) / 1000.0, 0.1)
                    var w: Double

                    if isGoalieSlot || isGKSlot {
                        // Goalie/GK picks: very flat weighting so ownership spreads
                        // across all starting keepers (~6 per slate).
                        w = pow(proj, 0.4)
                    } else if isSingleGame {
                        // Single-game: flatter exponents for more variance in small pools
                        switch botStyle {
                        case 0: w = pow(proj, 0.5)                                   // Near-random
                        case 1: w = pow(value, 0.8)                                  // Value hunter (mild)
                        case 2: w = pow(proj, 1.2)                                   // Stars lean
                        case 3: w = pow(max(value, 0.1), 0.6)                        // Balanced flat
                        default: w = 1.0                                             // Uniform random
                        }
                    } else if isSoccer {
                        // Soccer: very flat exponents — tiny pool (~22 for 8 slots)
                        // needs maximum randomness to avoid convergence.
                        switch botStyle {
                        case 0: w = pow(proj, 0.4)                                   // Near-random
                        case 1: w = pow(max(value, 0.1), 0.5)                        // Mild value
                        case 2: w = pow(proj, 0.9)                                   // Slight stars lean
                        case 3: w = 1.0                                              // Uniform random
                        default: w = pow(max(value, 0.1), 0.3)                       // Contrarian flat
                        }
                    } else {
                        switch botStyle {
                        case 0: w = pow(proj, 1.2)                                   // Near-random, slight projection lean
                        case 1: w = pow(value, 1.5)                                  // Value hunter
                        case 2: w = pow(proj, 1.8)                                   // Stars-and-scrubs
                        case 3: w = pow(proj, 1.0) * pow(max(value, 0.1), 1.0)       // Balanced
                        default: w = pow(max(Double(p.salary) / 1000.0, 0.1), 1.3)   // Contrarian — prefers expensive
                        }
                    }
                    // Salary steering — stronger for NHL/NBA to ensure bots approach cap
                    // (skip for goalie slot and soccer — small pools need
                    // more randomness, and salary steering causes convergence)
                    if !isGoalieSlot && !isGKSlot && !isSoccer {
                        let salaryRatio = Double(p.salary) / max(Double(targetSalary), 1.0)
                        if isSingleGame {
                            // Single-game: moderate steering to push bots toward 50K cap
                            // Lighter than main slate to preserve diversity in small pools
                            if salaryRatio >= 0.8 && salaryRatio <= 1.3 {
                                w *= 2.0
                            } else if salaryRatio < 0.5 {
                                w *= 0.3
                            }
                        } else if effectiveSport == "NHL" || effectiveSport == "NBA" || effectiveSport == "NCAAM" {
                            // NHL/NBA: aggressively steer toward target salary
                            if salaryRatio >= 0.8 && salaryRatio <= 1.2 {
                                w *= 3.0
                            } else if salaryRatio >= 0.6 && salaryRatio < 0.8 {
                                w *= 1.0
                            } else if salaryRatio < 0.6 {
                                w *= 0.1
                            }
                        } else {
                            if salaryRatio >= 0.7 && salaryRatio <= 1.3 {
                                w *= 1.5
                            } else if salaryRatio < 0.4 {
                                w *= 0.3
                            }
                        }
                    }
                    // MLB: heavily prefer confirmed starters (in batting order) over bench players.
                    // Players not in the lineup will likely score 0 FPTS.
                    if effectiveSport == "MLB" && mlbHasBattingOrders {
                        if p.battingOrder != nil || p.position == "SP" {
                            w *= 10.0
                        } else {
                            w *= 0.02
                        }
                    }
                    // NHL: boost confirmed starting goalies so bots roster them
                    // at high ownership. Non-starter goalies get heavily penalized
                    // to prevent DNP goalies from being rostered.
                    if effectiveSport == "NHL" && p.position == "G" {
                        if p.isStartingGoalie {
                            // Single-game: massive boost — there are only 2 goalies and
                            // the confirmed starter should be in ~60-80% of lineups.
                            w *= isSingleGame ? 50.0 : 10.0
                        } else if p.isConfirmedActive && (p.gamesPlayed ?? 0) >= 10 && p.playedRecently {
                            // Fallback: confirmed active + reasonable GP + recently played.
                            // Lowered GP threshold from 30→10 so young starters (e.g. Dobes)
                            // aren't excluded when ESPN probables data is missing.
                            w *= isSingleGame ? 15.0 : 3.0
                        } else {
                            w *= 0.05  // Heavy penalty for backup/unconfirmed/inactive goalies
                        }
                    }
                    // NHL skaters: prefer players who actually played recently.
                    // Uses boxscore data from the team's last completed game to
                    // identify who is currently in the lineup vs. scratches/IR/inactive.
                    // Also uses season GP as a secondary signal for role importance.
                    if effectiveSport == "NHL" && p.position != "G" {
                        if !p.playedRecently {
                            w *= 0.05  // Didn't play in team's last game - likely scratch/injured/inactive
                        } else if !p.isConfirmedActive && isSingleGame {
                            // Single-game: if player is NOT on the DK/RotoGrinders salary
                            // list, they're likely a scratch or healthy DNP tonight.
                            // Penalize heavily to avoid 40%+ ownership on DNP players.
                            w *= 0.03
                        } else {
                            let gp = p.gamesPlayed ?? 0
                            if gp >= 65 {
                                w *= 2.0  // Top-line regular who played recently
                            } else if gp >= 45 {
                                w *= 1.3  // Rotation player who played recently
                            } else {
                                w *= 0.7  // Low-GP but recently active (call-up getting a chance)
                            }
                        }
                    }
                    // Soccer: prefer players who appeared in recent matches.
                    // Soccer squads are large (~25-30 per team) but only ~18 dress
                    // per match. Players who haven't featured in recent weeks are
                    // likely reserves, injured, or out of favor.
                    if isSoccer && !p.playedRecently {
                        w *= 0.08  // Didn't appear in any recent match — likely reserve/unavailable
                    }
                    // Captain (MVP) diversity for single-game: flatten weighting further
                    // so no single player dominates captaincy. Real DFS showdowns have
                    // captain ownership spread across 4-6 players, not concentrated on one.
                    if mvpPick {
                        w = pow(w, 0.5) // Square root flattens any dominant weight
                    }
                    // Ownership variance: apply a random dampening factor to every
                    // player so no single player reaches 100% ownership. This creates
                    // more realistic ownership distributions (max ~85-90%).
                    let varianceFactor = Double.random(in: 0.3...1.0)
                    w *= varianceFactor
                    return max(w, 0.001)
                }

                let totalW = weights.reduce(0, +)
                guard totalW > 0 else { break }
                var roll = Double.random(in: 0..<totalW)
                var pick = affordable[0]
                for (i, w) in weights.enumerated() {
                    roll -= w
                    if roll <= 0 { pick = affordable[i]; break }
                }

                selectedBySlot[slotIndex] = pick
                // Single-game MVP (slot 0) costs 1.5x salary
                let pickCost = (isSingleGame && slotIndex == 0) ? Int(Double(pick.salary) * 1.5) : pick.salary
                budgetLeft -= pickCost
                usedIDs.insert(pick.id)
                pool.removeAll { $0.id == pick.id }
            }

            // Reconstruct selected array in original slot order
            guard selectedBySlot.count == lineupSize else { continue }
            var selected: [DFSPlayer] = (0..<lineupSize).compactMap { selectedBySlot[$0] }
            guard selected.count == lineupSize else { continue }
            let totalSpent = salaryCap - budgetLeft

            // If over cap, reject this lineup
            guard totalSpent <= salaryCap else { continue }

            // Helper: compute effective salary total (MVP costs 1.5x in single-game)
            func effectiveSalary(_ lineup: [DFSPlayer]) -> Int {
                if isSingleGame && !lineup.isEmpty {
                    return Int(Double(lineup[0].salary) * 1.5) + lineup.dropFirst().reduce(0) { $0 + $1.salary }
                }
                return lineup.reduce(0) { $0 + $1.salary }
            }

            // Upgrade pass: push spending toward cap — repeat until stable.
            // Soccer uses fewer passes (1) so bots don't all converge to same players.
            // NBA/NHL use 5 passes to ensure convergence with aggressive 95% floor.
            // Single-game uses 1-2 passes to preserve salary diversity in small pools.
            let upgradePassCount: Int
            if isSingleGame {
                upgradePassCount = Int.random(in: 1...2) // Lighter upgrades for variance
            } else if isSoccer {
                upgradePassCount = 1
            } else if effectiveSport == "NHL" || effectiveSport == "NBA" || effectiveSport == "NCAAM" {
                upgradePassCount = 5
            } else {
                upgradePassCount = 3
            }
            for _ in 0..<upgradePassCount {
                let cs = effectiveSalary(selected)
                let upgradeThreshold = isSoccer ? (salaryCap - 2000) : (salaryCap - 500)
                if cs >= upgradeThreshold { break }
                // Sort by effective cost (MVP costs 1.5x in single-game) so we upgrade
                // the truly cheapest slots first, not the raw-salary cheapest.
                let sortedByPrice = selected.enumerated().sorted {
                    let cost0 = (isSingleGame && $0.offset == 0) ? Int(Double($0.element.salary) * 1.5) : $0.element.salary
                    let cost1 = (isSingleGame && $1.offset == 0) ? Int(Double($1.element.salary) * 1.5) : $1.element.salary
                    return cost0 < cost1
                }
                for (idx, cheapPlayer) in sortedByPrice {
                    let currentSpent = effectiveSalary(selected)
                    if currentSpent >= salaryCap - 500 { break }
                    let slack = salaryCap - currentSpent
                    // For single-game MVP (slot 0), the cost change is 1.5x the salary difference,
                    // so the max raw-salary increase is slack / 1.5. For FLEX slots it's 1:1.
                    let isMVPSlot = isSingleGame && idx == 0
                    let maxRawSalaryIncrease = isMVPSlot ? Int(Double(slack) / 1.5) : slack

                    let requiredPos = slots[idx]
                    let upgradeCandidates = upgradePool.filter { candidate in
                        !usedIDs.contains(candidate.id)
                        && candidate.salary > cheapPlayer.salary
                        && candidate.salary <= cheapPlayer.salary + maxRawSalaryIncrease
                        && (requiredPos == nil || self.playerMatchesSlot(candidate, slot: requiredPos!))
                    }
                    if !upgradeCandidates.isEmpty {
                        // Sort by best cap fit — use effective cost (1.5x for MVP) so MVP upgrades
                        // pick candidates that actually bring the team closest to the cap.
                        let oldCost = isMVPSlot ? Int(Double(cheapPlayer.salary) * 1.5) : cheapPlayer.salary
                        let sorted = upgradeCandidates.sorted {
                            let newCost0 = isMVPSlot ? Int(Double($0.salary) * 1.5) : $0.salary
                            let newCost1 = isMVPSlot ? Int(Double($1.salary) * 1.5) : $1.salary
                            let fit1 = abs(salaryCap - (currentSpent - oldCost + newCost0))
                            let fit2 = abs(salaryCap - (currentSpent - oldCost + newCost1))
                            return fit1 < fit2
                        }
                        let topN = Array(sorted.prefix(5))
                        let upgrade = topN.randomElement()!
                        usedIDs.remove(cheapPlayer.id)
                        usedIDs.insert(upgrade.id)
                        selected[idx] = upgrade
                    }
                }
            }

            let finalSpent = effectiveSalary(selected)

            // Accept if within min spend (92-95% depending on sport) to 100% of cap
            if finalSpent >= minSpend && finalSpent <= salaryCap {
                return selected.map(\.id)
            }
        }

        // Fallback: greedy approach that targets salary spending.
        // For NHL, sort by salary descending to pick expensive players first.
        var fallback: [DFSPlayer] = []
        var fb_budget = salaryCap
        var fb_usedIDs = Set<String>()
        var fb_pool = scrambled.shuffled()
        for pickIndex in 0..<lineupSize {
            let slotsLeft = lineupSize - fallback.count
            let slotsAfter = slotsLeft - 1
            let reserveRest = slotsAfter * cheapestSalary
            var affordable = fb_pool.filter { $0.salary <= fb_budget - reserveRest }
            if let requiredPos = slots[pickIndex] {
                affordable = affordable.filter { playerMatchesSlot($0, slot: requiredPos) }
            }
            guard !affordable.isEmpty else { break }
            // MLB: prefer confirmed starters in fallback to avoid bench players scoring 0
            if effectiveSport == "MLB" && mlbHasBattingOrders {
                let starters = affordable.filter { $0.battingOrder != nil || $0.position == "SP" }
                if !starters.isEmpty { affordable = starters }
            }
            // Target the salary we should spend on this pick
            let fbTargetSalary = slotsLeft > 0 ? fb_budget / slotsLeft : fb_budget
            // Sort by closeness to target salary, pick from top candidates
            let sorted = affordable.sorted { abs($0.salary - fbTargetSalary) < abs($1.salary - fbTargetSalary) }
            let topCandidates = Array(sorted.prefix(5))
            let best = topCandidates.randomElement()!
            fallback.append(best)
            let fbPickCost = (isSingleGame && pickIndex == 0) ? Int(Double(best.salary) * 1.5) : best.salary
            fb_budget -= fbPickCost
            fb_usedIDs.insert(best.id)
            fb_pool.removeAll { $0.id == best.id }
        }

        // Helper: compute effective salary total for fallback (MVP costs 1.5x in single-game)
        func fbEffectiveSalary(_ lineup: [DFSPlayer]) -> Int {
            if isSingleGame && !lineup.isEmpty {
                return Int(Double(lineup[0].salary) * 1.5) + lineup.dropFirst().reduce(0) { $0 + $1.salary }
            }
            return lineup.reduce(0) { $0 + $1.salary }
        }

        // Run upgrade pass on fallback to push spending toward cap — repeat until stable
        if fallback.count == lineupSize {
            for _ in 0..<3 {  // Up to 3 passes to maximize spending
                let currentTotal = fbEffectiveSalary(fallback)
                if currentTotal >= salaryCap - 500 { break }
                let sortedByPrice = fallback.enumerated().sorted { $0.element.salary < $1.element.salary }
                for (idx, cheapPlayer) in sortedByPrice {
                    let currentSpent = fbEffectiveSalary(fallback)
                    if currentSpent >= salaryCap - 500 { break }
                    let slack = salaryCap - currentSpent
                    let requiredPos = slots[idx]
                    let upgradeCandidates = upgradePool.filter { candidate in
                        !fb_usedIDs.contains(candidate.id)
                        && candidate.salary > cheapPlayer.salary
                        && candidate.salary <= cheapPlayer.salary + slack
                        && (requiredPos == nil || self.playerMatchesSlot(candidate, slot: requiredPos!))
                    }
                    if !upgradeCandidates.isEmpty {
                        let sorted = upgradeCandidates.sorted {
                            let fit1 = abs(salaryCap - (currentSpent - cheapPlayer.salary + $0.salary))
                            let fit2 = abs(salaryCap - (currentSpent - cheapPlayer.salary + $1.salary))
                            return fit1 < fit2
                        }
                        let topN = Array(sorted.prefix(5))
                        let upgrade = topN.randomElement()!
                        fb_usedIDs.remove(cheapPlayer.id)
                        fb_usedIDs.insert(upgrade.id)
                        fallback[idx] = upgrade
                    }
                }
            }
        }

        let result = fallback.map(\.id)
        if result.isEmpty || result.count < lineupSize {
            print("[DFS-\(effectiveSport)] generateBotLineup returned \(result.count)/\(lineupSize) players. eligible=\(eligible.count), botPool=\(botPool.count), rosterSlots=\(rosterSlots?.description ?? "nil")")
        }
        return result
    }

    func refreshLive() async {
        guard let tournament else { return }

        // Always refresh remote entries to pick up the user's lineup.
        // The function handles both first-load (builds field) and subsequent loads
        // (updates user's entry in existing field).
        await refreshRemoteEntries()

        // Ensure userEntryRecords is populated for this tournament so that
        // selectedPlayers can access lineupPlayerNames for stub name resolution.
        // This is needed when viewing old tournaments not part of the current slate.
        if userEntryRecords[tournament.id] == nil, let uid = userID {
            let myRemote = remoteEntries.filter { $0.userID == uid }
            if !myRemote.isEmpty {
                userEntryRecords[tournament.id] = myRemote
                enteredTournamentIDs.insert(tournament.id)
            }
        }

        // If no remote entries but user has a local lineup, create a local-only field entry
        if fieldEntries.isEmpty && !selectedPlayerIDs.isEmpty {
            let name = profileName.isEmpty ? "You" : profileName
            fieldEntries = [
                DFSFieldEntry(
                    id: UUID(),
                    name: name,
                    playerIDs: Array(selectedPlayerIDs),
                    isCurrentUser: true
                )
            ]
        }

        // Only generate simulated field once — don't regenerate on every refresh
        if !fieldGenerated {
            // Try to load saved bot lineups from the server first.
            // This ensures the same bots appear on every device for the same tournament.
            // CRITICAL: Once the tournament is locked, ALWAYS use saved bots — never regenerate.
            // Regenerating after lock would swap out injured players, giving bots unfair advantage.
            var savedBots: [BotFieldEntry]?
            var needsResave = false
            let tournamentIsLocked = isTournamentLocked
            if let token = accessToken {
                let serverTournament = try? await SupabaseService.shared.fetchTournament(
                    tournamentID: tournament.id, accessToken: token
                )
                if let bots = serverTournament?.botField, !bots.isEmpty {
                    if tournamentIsLocked {
                        // Tournament is locked — ALWAYS use saved bots, no validation.
                        // Bot lineups are frozen at lock time. Even if game coverage
                        // doesn't match (games added/removed from slate), we must use
                        // the original lineups to prevent mid-game lineup changes.
                        savedBots = bots
                        print("[DFS] Tournament locked — using \(bots.count) saved bots as-is for \(tournament.id) (lineups frozen at lock time)")
                    } else {
                        // Tournament not yet locked — validate bots match current slate
                        // Verify bot diversity — if >50% share the same lineup, data is corrupted
                        let uniqueLineups = Set(bots.map { $0.playerIDs.sorted().joined(separator: ",") })
                        if uniqueLineups.count <= bots.count / 2 {
                            print("[DFS] Server bots for \(tournament.id) are corrupted (\(uniqueLineups.count)/\(bots.count) unique) — regenerating")
                        } else {
                            // Verify bots were generated from the SAME set of games
                            // as the current slate. Build a lookup of which game each
                            // player belongs to, then check if the bots cover the same
                            // games the slate has.
                            let playerGameMap = Dictionary(uniqueKeysWithValues: players.compactMap { p -> (String, String)? in
                                guard let gid = p.gameID else { return nil }
                                return (p.id, gid)
                            })
                            let currentGameIDs = Set(slateGames.map { $0.id })

                            // Check which games the saved bots cover
                            var botGameIDs = Set<String>()
                            for bot in bots.prefix(50) { // sample first 50 bots for speed
                                for pid in bot.playerIDs {
                                    if let gid = playerGameMap[pid] {
                                        botGameIDs.insert(gid)
                                    }
                                }
                            }

                            let missingGames = currentGameIDs.subtracting(botGameIDs)
                            if missingGames.isEmpty {
                                savedBots = bots
                                print("[DFS] Loaded \(bots.count) saved bot lineups from server for \(tournament.id) (\(uniqueLineups.count) unique, covers \(botGameIDs.count)/\(currentGameIDs.count) games)")
                            } else {
                                print("[DFS] Server bots for \(tournament.id) only cover \(botGameIDs.count)/\(currentGameIDs.count) games (missing: \(missingGames)) — regenerating")
                            }
                        }
                    }
                }
            }

            let sampleNames = [
                "AceLock", "CourtVision", "ClutchFan", "HalfCourtHero", "StatSavage",
                "UnderdogKing", "BoxScoreBoss", "PrimePicks", "FastBreak", "ZoneDefense",
                "SplashZone", "LineupLab", "FourthQuarter", "RimRunner", "PaintPoints"
            ]

            if let savedBots, !savedBots.isEmpty {
                // Use saved bots from server — consistent across devices
                let realEntries = fieldEntries.filter { $0.isCurrentUser || $0.isRealUser }
                // Only use enough saved bots to fill remaining slots (don't exceed entryCount)
                let botsToUse = max(0, tournament.entryCount - realEntries.count)
                let trimmedBots = Array(savedBots.prefix(botsToUse))
                // Build salary lookup for over-cap detection
                let salaryLookup = Dictionary(uniqueKeysWithValues: activePlayers.map { ($0.id, $0.salary) })
                let isSG = tournament.isSingleGame
                let cap = tournament.salaryCap
                // For single-game: build set of valid player IDs for this game
                let sgValidIDs: Set<String>? = {
                    guard isSG, let gameID = tournament.gameID else { return nil }
                    if let sgPool = singleGamePlayers[gameID] {
                        return Set(sgPool.map(\.id))
                    }
                    // Fallback: use main player pool filtered by gameID
                    return Set(players.filter { $0.gameID == gameID }.map(\.id))
                }()
                // Check for incomplete lineups, over-cap lineups, and wrong-game players
                let validBots = trimmedBots.filter { bot in
                    guard bot.playerIDs.count == tournament.lineupSize else { return false }
                    // For single-game, verify all players belong to the correct game
                    if let validIDs = sgValidIDs {
                        guard bot.playerIDs.allSatisfy({ validIDs.contains($0) }) else { return false }
                    }
                    // For single-game, verify salary total (MVP at 1.5x) doesn't exceed cap
                    if isSG && !salaryLookup.isEmpty {
                        var total = 0
                        for (i, pid) in bot.playerIDs.enumerated() {
                            let sal = salaryLookup[pid] ?? 0
                            total += (i == 0) ? Int(Double(sal) * 1.5) : sal
                        }
                        if total > cap { return false }
                    }
                    return true
                }
                let invalidBots = trimmedBots.filter { bot in !validBots.contains(where: { $0.name == bot.name && $0.playerIDs == bot.playerIDs }) }
                if !invalidBots.isEmpty {
                    let wrongSizeCount = invalidBots.filter { $0.playerIDs.count != tournament.lineupSize }.count
                    let wrongGameCount = invalidBots.filter { bot in
                        bot.playerIDs.count == tournament.lineupSize && sgValidIDs != nil && !bot.playerIDs.allSatisfy({ sgValidIDs!.contains($0) })
                    }.count
                    let overCapCount = invalidBots.count - wrongSizeCount - wrongGameCount
                    print("[DFS-\(sport)] WARNING: \(invalidBots.count) saved bots invalid (\(wrongSizeCount) wrong size, \(wrongGameCount) wrong game, \(overCapCount) over $\(cap) cap) out of \(trimmedBots.count) total")
                }
                if !invalidBots.isEmpty && !activePlayers.isEmpty && !tournamentIsLocked {
                    // Some saved bots are invalid (incomplete or over cap) — regenerate them
                    // ONLY regenerate before tournament locks. After lock, keep originals.
                    print("[DFS-\(sport)] Regenerating \(invalidBots.count) invalid bots (pre-lock)")
                    var botFieldEntries = validBots.map { bot in
                        DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: bot.playerIDs, isCurrentUser: false)
                    }
                    for bot in invalidBots {
                        let newIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                        botFieldEntries.append(DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: newIDs, isCurrentUser: false))
                    }
                    fieldEntries = realEntries + botFieldEntries
                    // Re-save the fixed bot field
                    needsResave = true
                } else if !invalidBots.isEmpty && tournamentIsLocked {
                    // Tournament is locked — keep ALL saved bots (even "invalid" ones)
                    // to preserve original lineups. Bot lineups are frozen at lock time.
                    print("[DFS-\(sport)] Tournament locked — keeping \(invalidBots.count) 'invalid' bots as-is (lineups frozen)")
                    let allBotEntries = trimmedBots.map { bot in
                        DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: bot.playerIDs, isCurrentUser: false)
                    }
                    fieldEntries = realEntries + allBotEntries
                } else {
                    let botFieldEntries = trimmedBots.map { bot in
                        DFSFieldEntry(
                            id: UUID(),
                            name: bot.name,
                            playerIDs: bot.playerIDs,
                            isCurrentUser: false
                        )
                    }
                    fieldEntries = realEntries + botFieldEntries
                }
                // If saved bots are fewer than expected (e.g. saved with old count),
                // pad with additional generated bots to reach the target entry count.
                // Only pad before lock — after lock, use whatever we have.
                let totalNonUser = fieldEntries.filter({ !$0.isCurrentUser }).count
                let targetBots = max(0, tournament.entryCount - realEntries.count)
                if totalNonUser < targetBots && !activePlayers.isEmpty && !tournamentIsLocked {
                    let botsNeeded = targetBots - totalNonUser
                    print("[DFS-\(sport)] Padding saved bot field with \(botsNeeded) additional bots (had \(totalNonUser), need \(targetBots))")
                    let startIndex = totalNonUser
                    for i in 0..<botsNeeded {
                        let botPlayerIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                        let baseName = sampleNames[(startIndex + i) % sampleNames.count]
                        let uniqueName = "\(baseName) #\(startIndex + i + 1)"
                        fieldEntries.append(DFSFieldEntry(id: UUID(), name: uniqueName, playerIDs: botPlayerIDs, isCurrentUser: false))
                    }
                    needsResave = true
                } else if totalNonUser < targetBots && tournamentIsLocked {
                    print("[DFS-\(sport)] Tournament locked — not padding bot field (have \(totalNonUser), target \(targetBots))")
                }
                print("[DFS-\(sport)] Loaded \(fieldEntries.count) entries from server (\(realEntries.count) real + \(fieldEntries.count - realEntries.count) bots), first bot playerIDs count: \(fieldEntries.first(where: { !$0.isCurrentUser })?.playerIDs.count ?? -1)")
            } else if fieldEntries.isEmpty && !activePlayers.isEmpty {
                // No saved bots and no entries — generate a simulated field
                let count = max(0, tournament.entryCount)
                var emptyCount = 0
                fieldEntries = (0..<count).map { index in
                    let botPlayerIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                    if botPlayerIDs.isEmpty { emptyCount += 1 }
                    let baseName = sampleNames[index % sampleNames.count]
                    let uniqueName = "\(baseName) #\(index + 1)"
                    return DFSFieldEntry(
                        id: UUID(),
                        name: uniqueName,
                        playerIDs: botPlayerIDs,
                        isCurrentUser: false
                    )
                }
                print("[DFS-\(sport)] Generated \(count) bots from scratch, \(emptyCount) have empty lineups, players=\(activePlayers.count), rosterSlots=\(tournament.rosterSlots?.description ?? "nil")")
            } else if fieldEntries.count < tournament.entryCount && !activePlayers.isEmpty {
                // Pad the field with simulated bots to reach expected entry count.
                let existingRealEntries = fieldEntries.filter { $0.isCurrentUser || $0.isRealUser }
                let botsNeeded = max(0, tournament.entryCount - existingRealEntries.count)
                var botEntries: [DFSFieldEntry] = []
                var emptyCount = 0
                for index in 0..<botsNeeded {
                    let botPlayerIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                    if botPlayerIDs.isEmpty { emptyCount += 1 }
                    let baseName = sampleNames[index % sampleNames.count]
                    let uniqueName = "\(baseName) #\(index + 1)"
                    botEntries.append(
                        DFSFieldEntry(
                            id: UUID(),
                            name: uniqueName,
                            playerIDs: botPlayerIDs,
                            isCurrentUser: false
                        )
                    )
                }
                fieldEntries = existingRealEntries + botEntries
                print("[DFS-\(sport)] Padded field with \(botsNeeded) bots, \(emptyCount) have empty lineups, players=\(activePlayers.count), rosterSlots=\(tournament.rosterSlots?.description ?? "nil")")
            } else {
                print("[DFS-\(sport)] No bots generated: fieldEntries=\(fieldEntries.count), tournament.entryCount=\(tournament.entryCount), players=\(activePlayers.count)")
            }

            // Defensive: ensure the current user's entry is in the field.
            // If refreshRemoteEntries failed or returned empty, the field may be
            // all bots. Fall back to userEntryRecords to inject the user's entry.
            if !fieldEntries.contains(where: { $0.isCurrentUser }),
               let uid = userID,
               let entry = entryRecord(for: tournament.id, lineupNumber: activeLineupNumber) {
                let name = profileName.isEmpty ? "You" : profileName
                let userFieldEntry = DFSFieldEntry(
                    id: UUID(uuidString: entry.id) ?? UUID(),
                    name: name,
                    playerIDs: entry.lineupPlayerIDs,
                    isCurrentUser: true,
                    isRealUser: true,
                    realUserID: uid
                )
                // Replace a bot with the user's entry to maintain correct field size
                if let botIdx = fieldEntries.firstIndex(where: { !$0.isCurrentUser && !$0.isRealUser }) {
                    fieldEntries[botIdx] = userFieldEntry
                } else if fieldEntries.count < tournament.entryCount {
                    fieldEntries.append(userFieldEntry)
                } else {
                    // Field is full of real users — replace the last entry
                    fieldEntries[fieldEntries.count - 1] = userFieldEntry
                }
                print("[DFS-\(sport)] Injected user entry from cached records (field was missing user)")
            }

            fieldGenerated = true

            // Persist bot lineups to server so post-match settlement can reuse them
            // (only if we generated new ones, not if we loaded from server)
            // NEVER overwrite saved bots after tournament locks — lineups are frozen.
            if (savedBots == nil || needsResave) && !tournamentIsLocked, let token = accessToken {
                let tid = tournament.id
                let botEntriesToSave = fieldEntries.filter { !$0.isCurrentUser && !$0.isRealUser }.map {
                    BotFieldEntry(name: $0.name, playerIDs: $0.playerIDs)
                }
                if !botEntriesToSave.isEmpty {
                    Task {
                        try? await SupabaseService.shared.saveBotField(
                            tournamentID: tid, botField: botEntriesToSave, accessToken: token
                        )
                        print("[DFS] Saved \(botEntriesToSave.count) bot lineups to server for \(tid)")
                    }
                }
            }
        }

        guard !fieldEntries.isEmpty else { return }

        let playersByID = Dictionary(uniqueKeysWithValues: activePlayers.map { ($0.id, $0) })
        guard !playersByID.isEmpty else { return }

        // PGA event mismatch detection: check if the active tournament's ESPN event ID
        // matches the current slate's event ID. PGA tournament IDs are "pga-{eventID}-{fieldSize}".
        // If the IDs don't match, ESPN has moved to a different event and live scoring
        // would return wrong data. Load stored results from Supabase instead.
        if sport == "PGA", let token = accessToken, let tid = activeTournamentID {
            let slateEventID = slateGames.first?.id ?? ""
            // Extract event ID from tournament ID: "pga-401811947-10" → "401811947"
            let tidParts = tid.dropFirst(4).components(separatedBy: "-") // drop "pga-"
            let tournamentEventID = tidParts.first ?? ""
            if !slateEventID.isEmpty && !tournamentEventID.isEmpty && tournamentEventID != slateEventID {
                print("[DFS-PGA] Event mismatch: tournament event \(tournamentEventID) ≠ slate event \(slateEventID) — loading stored results")
                await loadStoredPGAResults(token: token)
                return
            }
        }

        // PGA tournaments take 4 days (Thu-Sun); daily slates are done within 1 day.
        let definitelyOverDays = sport == "PGA" ? 3.5 : 2.0
        let tournamentDefinitelyOver = Date().timeIntervalSince(lockTime) > definitelyOverDays * 24 * 3600
        
        let snapshot: DFSScoreSnapshot
        do {
            let fetched = try await scoringProvider.fetchScoreSnapshot(for: slateGames)
            snapshot = fetched
        } catch {
            print("[DFS-\(sport)] fetchScoreSnapshot FAILED: \(error)")
            snapshot = DFSScoreSnapshot(playerFantasyPoints: [:], playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: tournamentDefinitelyOver)
        }

        print("[DFS-\(sport)] refreshLive: slateGames=\(slateGames.count) ids=\(slateGames.prefix(3).map(\.id)), snapshot.playerFantasyPoints=\(snapshot.playerFantasyPoints.count), fieldEntries=\(fieldEntries.count), players=\(players.count)")
        if !snapshot.playerFantasyPoints.isEmpty {
            let topScorers = snapshot.playerFantasyPoints.sorted { $0.value > $1.value }.prefix(3)
            print("[DFS-\(sport)] Top scorers: \(topScorers.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
        }
        if let firstEntry = fieldEntries.first {
            let sampleIDs = firstEntry.playerIDs.prefix(3)
            let matched = sampleIDs.filter { snapshot.playerFantasyPoints[$0] != nil }
            print("[DFS-\(sport)] First entry '\(firstEntry.name)' sample IDs: \(Array(sampleIDs)), matched in snapshot: \(matched.count)/\(sampleIDs.count)")
        }

        // Preserve existing live data when API returns empty (event dropped from scoreboard)
        if !snapshot.playerFantasyPoints.isEmpty {
            livePlayerPoints = snapshot.playerFantasyPoints
        }
        if !snapshot.playerLiveStats.isEmpty {
            livePlayerStats = snapshot.playerLiveStats
        }
        liveGameInfo = snapshot.gameLiveInfo

        // Use cached live data for leaderboard when snapshot is empty
        let effectiveSnapshot: DFSScoreSnapshot
        if snapshot.playerFantasyPoints.isEmpty && !livePlayerPoints.isEmpty {
            effectiveSnapshot = DFSScoreSnapshot(
                playerFantasyPoints: livePlayerPoints,
                playerLiveStats: livePlayerStats,
                gameLiveInfo: snapshot.gameLiveInfo,
                allGamesFinal: snapshot.allGamesFinal
            )
        } else {
            effectiveSnapshot = snapshot
        }

        let leaderboard = DFSEngine.computeLeaderboard(
            fieldEntries: fieldEntries,
            playersByID: playersByID,
            scoreSnapshot: effectiveSnapshot,
            isSingleGame: tournament.isSingleGame
        )
        leaderboardEntries = leaderboard

        // Cache live ranks for user lineups in THIS tournament.
        if let allEntries = userEntryRecords[tournament.id] {
            for entry in allEntries {
                let ln = entry.lineupNumber ?? 1
                let isSG = tournament.isSingleGame
                var total = 0.0
                for (i, pid) in entry.lineupPlayerIDs.enumerated() {
                    let pts = livePlayerPoints[pid] ?? 0
                    total += (isSG && i == 0) ? pts * 1.5 : pts
                }
                let rank = min(tournament.entryCount, leaderboard.filter({ $0.points > total }).count + 1)
                cachedLiveRanks["\(tournament.id)-\(ln)"] = rank
            }
        }

        // Also update cached ranks for OTHER entered tournaments using fresh livePlayerPoints.
        // This ensures all contest cards on the locked list stay current with each polling cycle.
        for tid in enteredTournamentIDs {
            guard tid != tournament.id else { continue }
            guard let cache = liveContestCache[tid] else { continue }
            guard let tObj = tournaments.first(where: { $0.id == tid }) else { continue }
            if let userRecords = userEntryRecords[tid] {
                // Recompute leaderboard with updated livePlayerPoints
                let poolForT: [DFSPlayer] = {
                    if tObj.isSingleGame, let gid = tObj.gameID, let sgPool = singleGamePlayers[gid] {
                        return sgPool
                    }
                    return players
                }()
                let pByID = Dictionary(uniqueKeysWithValues: poolForT.map { ($0.id, $0) })
                let snap = DFSScoreSnapshot(
                    playerFantasyPoints: livePlayerPoints,
                    playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: false
                )
                let lb = DFSEngine.computeLeaderboard(
                    fieldEntries: cache.fieldEntries, playersByID: pByID,
                    scoreSnapshot: snap, isSingleGame: tObj.isSingleGame
                )
                // Update cache with fresh leaderboard
                liveContestCache[tid] = LiveContestCache(
                    fieldEntries: cache.fieldEntries, leaderboard: lb,
                    remoteEntries: cache.remoteEntries, profileNames: cache.profileNames,
                    fieldGenerated: true
                )
                for rec in userRecords {
                    let ln = rec.lineupNumber ?? 1
                    var total = 0.0
                    for (i, pid) in rec.lineupPlayerIDs.enumerated() {
                        let pts = livePlayerPoints[pid] ?? 0
                        total += (tObj.isSingleGame && i == 0) ? pts * 1.5 : pts
                    }
                    let rank = min(tObj.entryCount, lb.filter({ $0.points > total }).count + 1)
                    cachedLiveRanks["\(tid)-\(ln)"] = rank
                }
            }
        }

        // Update live contest cache so re-entering or switching lineups is instant
        liveContestCache[tournament.id] = LiveContestCache(
            fieldEntries: fieldEntries,
            leaderboard: leaderboard,
            remoteEntries: remoteEntries,
            profileNames: remoteProfileNames,
            fieldGenerated: true
        )

        guard let userEntry = leaderboard.first(where: { $0.isCurrentUser }) else { return }
        let currentRR = latestResult?.rrDelta ?? 0
        latestResult = DFSResult(
            id: latestResult?.id ?? UUID(),
            tournamentTitle: tournament.title,
            rank: userEntry.rank,
            totalEntries: max(tournament.entryCount, fieldEntries.count),
            lineupPoints: userEntry.points,
            rrDelta: currentRR,
            loggedAt: Date(),
            tournamentId: tournament.id,
            lineupNumber: activeLineupNumber
        )

        // PGA un-settlement: if tournament was previously settled but live data says NOT final,
        // un-settle it (the settlement was premature, e.g. between rounds)
        if sport == "PGA" && settledTournaments.contains(tournament.id) && !snapshot.allGamesFinal && !snapshot.playerFantasyPoints.isEmpty {
            let badTID = tournament.id
            let historyMatch = dfsHistory.first(where: { $0.tournamentId == badTID })
            print("[DFS-PGA] Live data says tournament NOT final but was settled — un-settling \(badTID)")
            var currentSettled = settledTournaments
            currentSettled.remove(badTID)
            settledTournamentData = (try? JSONEncoder().encode(currentSettled)) ?? Data()
            if let historyMatch {
                rrScore -= historyMatch.rrDelta
            }
            var updated = dfsHistory
            updated.removeAll { $0.tournamentId == badTID }
            dfsHistoryData = encodedDFSHistory(Array(updated.prefix(500)))
            if var result = latestResult {
                result = DFSResult(
                    id: result.id, tournamentTitle: result.tournamentTitle,
                    rank: result.rank, totalEntries: result.totalEntries,
                    lineupPoints: result.lineupPoints, rrDelta: 0,
                    loggedAt: result.loggedAt, tournamentId: result.tournamentId,
                    lineupNumber: result.lineupNumber
                )
                latestResult = result
            }
            if let token = accessToken {
                try? await SupabaseService.shared.deleteTournamentResults(tournamentID: badTID, accessToken: token)
            }
        }

        guard snapshot.allGamesFinal else { return }
        guard !settledTournaments.contains(tournament.id) else { return }

        // PGA settlement safeguards: never settle before 3 days or before round 4
        if sport == "PGA" {
            let daysSinceLock = Date().timeIntervalSince(lockTime) / (24 * 3600)
            let reportedRound = snapshot.gameLiveInfo.values.first?.period ?? 1
            print("[DFS-PGA] Settlement check: daysSinceLock=\(String(format: "%.1f", daysSinceLock)), reportedRound=\(reportedRound)")
            guard daysSinceLock >= 3.0 || tournamentDefinitelyOver else {
                print("[DFS-PGA] Skipping settlement — only \(String(format: "%.1f", daysSinceLock)) days since start")
                return
            }
            guard reportedRound >= 4 || tournamentDefinitelyOver else {
                print("[DFS-PGA] Skipping settlement — only round \(reportedRound) of 4 complete")
                return
            }
        }

        // Sanity check: don't settle if scoring data looks bad (all zeros)
        let totalFantasyPoints = max(
            snapshot.playerFantasyPoints.values.reduce(0, +),
            livePlayerPoints.values.reduce(0, +)
        )
        let hasUserScore = userEntry.points > 0
        guard totalFantasyPoints > 0 || (tournamentDefinitelyOver && hasUserScore) else {
            print("[DFS] Skipping settlement — all fantasy points are zero (bad data)")
            return
        }

        // Sanity check: don't settle if user has points but ALL bots scored zero.
        // This indicates a player-ID mismatch between bot lineups and the score snapshot.
        // Settling now would persist incorrect leaderboard data — defer to re-settlement.
        let botEntries = leaderboard.filter { !$0.isCurrentUser }
        let allBotsZero = !botEntries.isEmpty && botEntries.allSatisfy { $0.points == 0 }
        if allBotsZero && hasUserScore {
            print("[DFS-\(sport)] Skipping settlement — all \(botEntries.count) bots scored 0 but user scored \(userEntry.points). Likely player-ID mismatch.")
            return
        }

        let totalEntries = max(tournament.entryCount, fieldEntries.count)
        // Compute tie count for pooled RR: how many entries share the same rank as user
        let userTieCount = leaderboard.filter { $0.rank == userEntry.rank }.count
        let rrDelta = DFSEngine.pooledRRDelta(tiedRank: userEntry.rank, tieCount: userTieCount, entryCount: tournament.entryCount)
        rrScore += rrDelta
        markTournamentSettled(tournament.id)

        let finalized = DFSResult(
            id: UUID(),
            tournamentTitle: tournament.title,
            rank: userEntry.rank,
            totalEntries: totalEntries,
            lineupPoints: userEntry.points,
            rrDelta: rrDelta,
            loggedAt: Date(),
            tournamentId: tournament.id,
            lineupNumber: activeLineupNumber
        )
        latestResult = finalized

        var updatedHistory = dfsHistory
        updatedHistory.insert(finalized, at: 0)

        // Also create dfsHistory entries for OTHER user lineups (multi-lineup support).
        // The live field only contains the active lineup, but we need history entries
        // for all lineups so they appear in My Contests and Past Results.
        if let allEntries = userEntryRecords[tournament.id], allEntries.count > 1 {
            let isSG = tournament.isSingleGame
            let activeLineupSet = Set(fieldEntries.first(where: { $0.isCurrentUser })?.playerIDs ?? [])
            for entry in allEntries {
                let entryLineupSet = Set(entry.lineupPlayerIDs)
                guard entryLineupSet != activeLineupSet else { continue }  // Skip active lineup
                let lineupNum = entry.lineupNumber ?? 1
                var total = 0.0
                for (i, pid) in entry.lineupPlayerIDs.enumerated() {
                    let pts = livePlayerPoints[pid] ?? 0
                    total += (isSG && i == 0) ? pts * 1.5 : pts
                }
                let otherRank = min(tournament.entryCount, leaderboard.filter({ $0.points > total }).count + 1)
                let otherTieCount = leaderboard.filter { $0.rank == otherRank }.count
                let otherRRDelta = DFSEngine.pooledRRDelta(tiedRank: otherRank, tieCount: max(1, otherTieCount), entryCount: tournament.entryCount)
                rrScore += otherRRDelta
                updatedHistory.insert(DFSResult(
                    id: UUID(),
                    tournamentTitle: tournament.title,
                    rank: otherRank,
                    totalEntries: totalEntries,
                    lineupPoints: total,
                    rrDelta: otherRRDelta,
                    loggedAt: Date(),
                    tournamentId: tournament.id,
                    lineupNumber: lineupNum
                ), at: 0)
            }
        }

        dfsHistoryData = encodedDFSHistory(Array(updatedHistory.prefix(500)))

        // Persist full leaderboard to Supabase
        await persistLeaderboardToServer(
            tournamentID: tournament.id,
            leaderboard: leaderboard,
            totalEntries: totalEntries
        )
    }

    /// Load stored tournament results from Supabase when the PGA event has rotated
    /// and ESPN no longer has the old event's scoring data. Builds leaderboard from
    /// server-side results so the user sees their final lineup and standings.
    private func loadStoredPGAResults(token: String) async {
        // Use activeTournamentID directly — the `tournament` computed property may
        // return the wrong tournament when ESPN has rotated to a new event and the
        // user's old tournament ID no longer exists in the `tournaments` array.
        guard let tid = activeTournamentID else { return }
        let tournamentObj = tournament  // may be nil or wrong event — used only for metadata fallback

        // Try to load stored results from server
        let storedResults: [DFSTournamentResultRecord]
        do {
            storedResults = try await SupabaseService.shared.fetchTournamentResults(
                tournamentID: tid, accessToken: token
            )
        } catch {
            print("[DFS-PGA] Failed to load stored results for \(tid): \(error.localizedDescription)")
            storedResults = []
        }

        if !storedResults.isEmpty {
            print("[DFS-PGA] Loaded \(storedResults.count) stored results for \(tid)")

            // Build player points from stored results to populate livePlayerPoints
            var aggregatedPoints: [String: Double] = [:]
            for result in storedResults {
                if let pts = result.playerPoints {
                    for (pid, points) in pts {
                        aggregatedPoints[pid] = points
                    }
                }
            }
            if !aggregatedPoints.isEmpty {
                livePlayerPoints = aggregatedPoints
            }

            // Build leaderboard from stored results
            leaderboardEntries = storedResults.enumerated().map { _, result in
                DFSLeaderboardEntry(
                    id: UUID(uuidString: result.id) ?? UUID(),
                    name: result.entryName,
                    rank: result.rank,
                    points: result.totalPoints,
                    isCurrentUser: result.isCurrentUser || result.userID == userID
                )
            }

            // Set game info to show as Final
            if let game = slateGames.first {
                liveGameInfo[game.id] = DFSGameLiveInfo(
                    id: game.id,
                    awayTeam: game.awayTeam,
                    homeTeam: game.homeTeam,
                    awayScore: 0, homeScore: 0,
                    clock: "Final", period: 4, state: "post"
                )
            }

            // Update latestResult from stored results
            if let userResult = storedResults.first(where: { $0.isCurrentUser || $0.userID == userID }) {
                latestResult = DFSResult(
                    id: latestResult?.id ?? UUID(),
                    tournamentTitle: tournamentObj?.title ?? "PGA Tournament",
                    rank: userResult.rank,
                    totalEntries: max(tournamentObj?.entryCount ?? storedResults.count, storedResults.count),
                    lineupPoints: userResult.totalPoints,
                    rrDelta: userResult.rrDelta,
                    loggedAt: Date(),
                    tournamentId: tid,
                    lineupNumber: activeLineupNumber
                )
            }

            // Mark as settled if not already
            if !settledTournaments.contains(tid) {
                markTournamentSettled(tid)
            }

            // Update field entries from stored results to show proper names
            let userFieldEntries = fieldEntries.filter { $0.isCurrentUser || $0.isRealUser }
            var rebuiltField = userFieldEntries
            let botsFromResults = storedResults.filter { $0.isBot }
            for bot in botsFromResults {
                rebuiltField.append(DFSFieldEntry(
                    id: UUID(uuidString: bot.id) ?? UUID(),
                    name: bot.entryName,
                    playerIDs: bot.lineupPlayerIDs,
                    isCurrentUser: false
                ))
            }
            if rebuiltField.count > fieldEntries.count / 2 {
                fieldEntries = rebuiltField
            }

            fieldGenerated = true

            // Fetch ESPN round-by-round stats so R1/R2/R3/R4 show on scorecards.
            // loadStoredPGAResults only has fantasy points from the server — the
            // per-round scores live in ESPN's scoreboard data.
            let pgaAfterPrefix = tid.replacingOccurrences(of: "pga-", with: "")
            let eventID = pgaAfterPrefix.components(separatedBy: "-").first ?? pgaAfterPrefix
            // Use server tournament's lock time for the ESPN date-based fallback query.
            // Old events aren't on the current scoreboard, so we need the actual tournament date.
            let serverTournamentForDate = try? await SupabaseService.shared.fetchTournament(
                tournamentID: tid, accessToken: token
            )
            let eventDate = serverTournamentForDate?.lockTime ?? storedResults.compactMap(\.createdAt).min() ?? Date()
            let slateGame = DFSSlateGame(
                id: eventID,
                awayTeam: "",
                homeTeam: "PGA",
                startTime: eventDate,
                state: "post"
            )
            let pgaScoringProvider = ESPNPGADFSLiveScoringProvider()
            if let snapshot = try? await pgaScoringProvider.fetchScoreSnapshot(for: [slateGame]),
               !snapshot.playerLiveStats.isEmpty {
                livePlayerStats = snapshot.playerLiveStats
                print("[DFS-PGA] Loaded \(snapshot.playerLiveStats.count) player round stats from ESPN for stored results")
            }

            // Cache it
            liveContestCache[tid] = LiveContestCache(
                fieldEntries: fieldEntries,
                leaderboard: leaderboardEntries,
                remoteEntries: remoteEntries,
                profileNames: remoteProfileNames,
                fieldGenerated: true
            )
        } else {
            print("[DFS-PGA] No stored results found for \(tid) — showing empty state")
            // Even without stored results, set game info to Final so it doesn't spin
            if let game = slateGames.first {
                liveGameInfo[game.id] = DFSGameLiveInfo(
                    id: game.id,
                    awayTeam: game.awayTeam,
                    homeTeam: game.homeTeam,
                    awayScore: 0, homeScore: 0,
                    clock: "Final", period: 4, state: "post"
                )
            }
        }
    }

    /// Pre-builds fields and leaderboards for all entered tournaments that aren't cached yet,
    /// so the user sees results instantly when tapping any Active Contests card.
    func preCacheAllEnteredTournaments() async {
        guard let token = accessToken, let userID else { return }
        // Only pre-cache if the current tournament's field is already built
        guard fieldGenerated, !fieldEntries.isEmpty else { return }
        let currentTID = activeTournamentID

        for tid in enteredTournamentIDs {
            guard tid != currentTID else { continue }
            guard liveContestCache[tid] == nil else { continue }
            guard let tObj = tournaments.first(where: { $0.id == tid }) else { continue }

            // Fetch remote entries for this tournament
            let entries: [DFSEntryRecord]
            do {
                entries = try await SupabaseService.shared.fetchEntries(tournamentID: tid, accessToken: token)
            } catch { continue }

            let uniqueUserIDs = Array(Set(entries.map { $0.userID }))
            let profiles = (try? await SupabaseService.shared.fetchProfiles(userIDs: uniqueUserIDs, accessToken: token)) ?? []
            let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.username) })

            // Build field entries from remote entries
            let myEntries = entries.filter { $0.userID == userID }
            let activeEntry = myEntries.first(where: { ($0.lineupNumber ?? 1) == 1 }) ?? myEntries.first
            let otherEntries = entries.filter { $0.userID != userID }
            var initialEntries = otherEntries
            if let ae = activeEntry { initialEntries.insert(ae, at: 0) }
            var field = initialEntries.map { entry in
                let name = profileMap[entry.userID] ?? "User \(entry.userID.prefix(6))"
                let isMe = entry.userID == userID && (entry.lineupNumber ?? 1) == 1
                return DFSFieldEntry(
                    id: UUID(uuidString: entry.id) ?? UUID(),
                    name: name, playerIDs: entry.lineupPlayerIDs,
                    isCurrentUser: isMe, isRealUser: true, realUserID: entry.userID
                )
            }

            // Load saved bots from server
            let serverTournament = try? await SupabaseService.shared.fetchTournament(tournamentID: tid, accessToken: token)
            let savedBots = serverTournament?.botField ?? []
            let realCount = field.filter({ $0.isCurrentUser || $0.isRealUser }).count
            let botsNeeded = max(0, tObj.entryCount - realCount)
            let sampleNames = ["AceLock","CourtVision","ClutchFan","HalfCourtHero","StatSavage",
                               "UnderdogKing","BoxScoreBoss","PrimePicks","FastBreak","ZoneDefense",
                               "SplashZone","LineupLab","FourthQuarter","RimRunner","PaintPoints"]

            if !savedBots.isEmpty {
                let trimmed = Array(savedBots.prefix(botsNeeded))
                field += trimmed.map { DFSFieldEntry(id: UUID(), name: $0.name, playerIDs: $0.playerIDs, isCurrentUser: false) }
            } else {
                // Use the correct player pool for this tournament (may differ from activePlayers
                // which is bound to the currently-selected tournament).
                let poolForBots: [DFSPlayer]
                if tObj.isSingleGame, let gid = tObj.gameID {
                    if let sgPool = singleGamePlayers[gid] {
                        poolForBots = sgPool
                    } else {
                        // Build single-game pool with converted showdown salaries
                        let filtered = players.filter { $0.gameID == gid }
                        let league = tObj.league
                        poolForBots = filtered.map { p in
                            var sg = DFSPlayer(
                                id: p.id, name: p.name, team: p.team, position: p.position,
                                salary: singleGameSalary(from: p.salary, league: league),
                                projectedPoints: p.projectedPoints,
                                gameID: p.gameID, injuryStatus: p.injuryStatus,
                                battingOrder: p.battingOrder
                            )
                            sg.gamesPlayed = p.gamesPlayed
                            sg.playedRecently = p.playedRecently
                            sg.isConfirmedActive = p.isConfirmedActive
                            sg.isStartingGoalie = p.isStartingGoalie
                            return sg
                        }
                        if !poolForBots.isEmpty {
                            singleGamePlayers[gid] = poolForBots
                        }
                    }
                } else if tObj.tournamentType.isEvening {
                    poolForBots = eveningPlayers
                } else {
                    poolForBots = players
                }
                guard !poolForBots.isEmpty else { continue }
                for i in 0..<botsNeeded {
                    let botIDs = generateBotLineup(from: poolForBots, salaryCap: tObj.salaryCap, lineupSize: tObj.lineupSize, rosterSlots: tObj.rosterSlots, isSingleGame: tObj.isSingleGame)
                    let name = "\(sampleNames[i % sampleNames.count]) #\(i + 1)"
                    field.append(DFSFieldEntry(id: UUID(), name: name, playerIDs: botIDs, isCurrentUser: false))
                }
            }

            guard !field.isEmpty, !players.isEmpty else { continue }

            // Build leaderboard using current live player points
            // Use single-game player pool (with adjusted salaries) when applicable
            let poolForTournament: [DFSPlayer]
            if tObj.isSingleGame, let gid = tObj.gameID, let sgPool = singleGamePlayers[gid] {
                poolForTournament = sgPool
            } else {
                poolForTournament = players
            }
            let playersByID = Dictionary(uniqueKeysWithValues: poolForTournament.map { ($0.id, $0) })
            let snapshot = DFSScoreSnapshot(
                playerFantasyPoints: livePlayerPoints,
                playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: false
            )
            let lb = DFSEngine.computeLeaderboard(
                fieldEntries: field, playersByID: playersByID,
                scoreSnapshot: snapshot, isSingleGame: tObj.isSingleGame
            )

            liveContestCache[tid] = LiveContestCache(
                fieldEntries: field, leaderboard: lb,
                remoteEntries: entries, profileNames: profileMap,
                fieldGenerated: true
            )

            // Cache ranks for all user lineups in this tournament
            if let userRecords = userEntryRecords[tid] {
                for rec in userRecords {
                    let ln = rec.lineupNumber ?? 1
                    var total = 0.0
                    for (i, pid) in rec.lineupPlayerIDs.enumerated() {
                        let pts = livePlayerPoints[pid] ?? 0
                        total += (tObj.isSingleGame && i == 0) ? pts * 1.5 : pts
                    }
                    let rank = min(tObj.entryCount, lb.filter({ $0.points > total }).count + 1)
                    cachedLiveRanks["\(tid)-\(ln)"] = rank
                }
            }
            print("[DFS-\(sport)] Pre-cached field for \(tid): \(field.count) entries, \(lb.count) leaderboard rows")
        }
    }

    /// Persists the full leaderboard (including bots) to dfs_tournament_results
    private func persistLeaderboardToServer(
        tournamentID: String,
        leaderboard: [DFSLeaderboardEntry],
        totalEntries: Int
    ) async {
        guard let token = accessToken, let userID else { return }

        let entryNameMap = Dictionary(uniqueKeysWithValues: fieldEntries.map { ($0.id, $0.name) })
        let fieldByID = Dictionary(uniqueKeysWithValues: fieldEntries.map { ($0.id, $0) })
        let playersByID = Dictionary(uniqueKeysWithValues: activePlayers.map { ($0.id, $0) })
        let isSG = tournament?.isSingleGame ?? false
        let entryCount = tournament?.entryCount ?? 1000

        // Deduplicate entry names to avoid upsert conflict errors
        var nameCounter: [String: Int] = [:]
        var resultRecords: [DFSTournamentResultRecord] = leaderboard.map { entry in
            let field = fieldByID[entry.id]
            let playerIDs = field?.playerIDs ?? []
            let playerNames = playerIDs.map { playersByID[$0]?.name ?? $0 }
            let perPlayerPoints: [String: Double] = Dictionary(uniqueKeysWithValues:
                playerIDs.map { pid in
                    (pid, livePlayerPoints[pid] ?? 0)
                }
            )
            let perPlayerSalaries: [String: Int] = Dictionary(uniqueKeysWithValues:
                playerIDs.compactMap { pid in
                    guard let sal = playersByID[pid]?.salary, sal > 0 else { return nil }
                    return (pid, sal)
                }
            )
            let rrDelta: Int
            if entry.isCurrentUser {
                let tieCount = leaderboard.filter { $0.rank == entry.rank }.count
                rrDelta = DFSEngine.pooledRRDelta(tiedRank: entry.rank, tieCount: max(1, tieCount), entryCount: entryCount)
            } else {
                rrDelta = 0
            }

            let baseName = entryNameMap[entry.id] ?? entry.name
            let count = nameCounter[baseName, default: 0]
            nameCounter[baseName] = count + 1
            let uniqueName = count == 0 ? baseName : "\(baseName) \(count + 1)"

            return DFSTournamentResultRecord(
                id: UUID().uuidString,
                tournamentID: tournamentID,
                userID: entry.isCurrentUser ? userID : nil,
                entryName: uniqueName,
                lineupPlayerIDs: playerIDs,
                lineupPlayerNames: playerNames,
                totalPoints: entry.points,
                playerPoints: perPlayerPoints,
                playerSalaries: perPlayerSalaries,
                rank: entry.rank,
                rrDelta: rrDelta,
                isCurrentUser: entry.isCurrentUser,
                isBot: !(entry.isCurrentUser)
            )
        }

        // Also persist the user's OTHER lineups that aren't in the live field.
        // The live field only contains the active lineup, but multi-lineup tournaments
        // may have additional user entries that need to be in the results for
        // syncHistoryFromServer and standings to work correctly.
        if let allEntries = userEntryRecords[tournamentID], allEntries.count > 1 {
            let activeLineupSets = fieldEntries.filter { $0.isCurrentUser }.map { Set($0.playerIDs) }
            let otherEntries = allEntries.filter { entry in
                !activeLineupSets.contains(Set(entry.lineupPlayerIDs))
            }
            let userName = profileName.isEmpty ? "You" : profileName
            for entry in otherEntries {
                let lineupNum = entry.lineupNumber ?? 1
                let displayName = "\(userName) #\(lineupNum)"
                let pids = entry.lineupPlayerIDs
                let pnames = pids.map { playersByID[$0]?.name ?? $0 }
                var total = 0.0
                var perPts: [String: Double] = [:]
                for (i, pid) in pids.enumerated() {
                    let pts = livePlayerPoints[pid] ?? 0
                    let multiplied = (isSG && i == 0) ? pts * 1.5 : pts
                    perPts[pid] = multiplied
                    total += multiplied
                }
                let perSals: [String: Int] = Dictionary(uniqueKeysWithValues:
                    pids.compactMap { pid in
                        guard let sal = playersByID[pid]?.salary, sal > 0 else { return nil }
                        return (pid, sal)
                    }
                )
                // Estimate rank based on position in the full leaderboard
                let higherCount = leaderboard.filter { $0.points > total }.count
                let estimatedRank = min(totalEntries, higherCount + 1)
                let estimatedTieCount = leaderboard.filter { $0.rank == estimatedRank }.count
                let rrDelta = DFSEngine.pooledRRDelta(tiedRank: estimatedRank, tieCount: max(1, estimatedTieCount), entryCount: entryCount)

                let count = nameCounter[displayName, default: 0]
                nameCounter[displayName] = count + 1
                let uniqueName = count == 0 ? displayName : "\(displayName) (\(count + 1))"

                resultRecords.append(DFSTournamentResultRecord(
                    id: UUID().uuidString,
                    tournamentID: tournamentID,
                    userID: userID,
                    entryName: uniqueName,
                    lineupPlayerIDs: pids,
                    lineupPlayerNames: pnames,
                    totalPoints: total,
                    playerPoints: perPts,
                    playerSalaries: perSals,
                    rank: estimatedRank,
                    rrDelta: rrDelta,
                    isCurrentUser: true,
                    isBot: false
                ))
            }
        }

        do {
            // Delete old/bad results before inserting fresh ones
            try await SupabaseService.shared.deleteTournamentResults(tournamentID: tournamentID, accessToken: token)

            // Upload in batches of 100 to avoid request size limits
            for batch in stride(from: 0, to: resultRecords.count, by: 100) {
                let end = min(batch + 100, resultRecords.count)
                let chunk = Array(resultRecords[batch..<end])
                try await SupabaseService.shared.upsertTournamentResults(
                    tournamentID: tournamentID,
                    results: chunk,
                    accessToken: token
                )
            }
            try await SupabaseService.shared.markTournamentSettled(
                tournamentID: tournamentID,
                totalEntries: totalEntries,
                accessToken: token
            )
            print("[DFS] Persisted \(resultRecords.count) results for tournament \(tournamentID)")
        } catch {
            print("[DFS] Failed to persist tournament results: \(error.localizedDescription)")
        }

        // Also update individual entry scores (for backwards compat)
        for entry in leaderboard {
            if let remoteEntry = remoteEntries.first(where: { UUID(uuidString: $0.id) == entry.id }) {
                let name = entryNameMap[entry.id] ?? entry.name
                try? await SupabaseService.shared.updateEntryScore(
                    entryID: remoteEntry.id,
                    totalPoints: entry.points,
                    displayName: name,
                    accessToken: token
                )
            }
        }
    }

    func submitLineup() {
        guard canSubmitLineup else { return }
        guard let userID, let token = accessToken else {
            error = "Sign in required to join tournaments."
            return
        }
        guard let tournament else { return }
        let isEditing = editingLineupNumber != nil
        let lineupNumber: Int
        if let editNum = editingLineupNumber {
            lineupNumber = editNum
        } else {
            let currentLineups = lineupsInTournament(tournament.id)
            // Check per-tournament type limit (across all instances)
            if currentLineups >= maxLineupsPerTournament {
                error = "Maximum \(maxLineupsPerTournament) lineups per game type reached."
                return
            }
            // Check daily limit
            if !canSubmitMoreLineups {
                error = "Maximum \(maxLineupsPerDay) lineups per day reached."
                return
            }
            lineupNumber = currentLineups + 1
        }
        let userLineup = selectedPlayers.map { $0.id }
        let salaryMap = Dictionary(uniqueKeysWithValues: selectedPlayers.map { ($0.id, $0.salary) })
        let namesList = selectedPlayers.map { $0.name }

        // Build full slate salary map so re-settlement can use original prices
        let allPlayerSalaries = Dictionary(uniqueKeysWithValues: activePlayers.map { ($0.id, $0.salary) })

        Task {
            do {
                // For small tournaments, resolve to an instance with room for this user.
                // Each user gets at most 1 entry per instance — additional entries go to new instances.
                // Priority: (1) instance with a real human opponent, (2) empty instance for bot fill.
                // Never place user against themselves.
                var resolvedTournamentID = tournament.id
                if !isEditing && tournament.entryCount <= 10 {
                    // Scan instances sequentially: base, -i2, -i3, ...
                    // Stop when we hit an empty instance (all subsequent will also be empty).
                    var bestHumanInstance: String? = nil
                    var firstEmptyInstance: String? = nil

                    var instanceNum = 1
                    while instanceNum <= 100 {
                        let candidateID = instanceNum == 1
                            ? tournament.id
                            : "\(tournament.id)-i\(instanceNum)"

                        let entries = try await SupabaseService.shared.fetchEntries(
                            tournamentID: candidateID, accessToken: token
                        )

                        if entries.isEmpty {
                            // Empty instance — all subsequent will be empty too
                            firstEmptyInstance = candidateID
                            break
                        }

                        let entryUserIDs = Set(entries.map(\.userID))

                        // Skip if user is already in this instance
                        if entryUserIDs.contains(userID) {
                            instanceNum += 1
                            continue
                        }

                        // Check if there's room
                        if entryUserIDs.count < tournament.entryCount {
                            // Has room and user isn't in it — check for real human opponent
                            let hasRealHuman = entryUserIDs.contains(where: { $0 != userID })
                            if hasRealHuman && bestHumanInstance == nil {
                                bestHumanInstance = candidateID
                                break // found a human opponent — use it immediately
                            }
                        }

                        instanceNum += 1
                    }

                    // Prefer human opponent, fall back to empty instance
                    if let humanInstance = bestHumanInstance {
                        resolvedTournamentID = humanInstance
                    } else if let emptyInstance = firstEmptyInstance {
                        resolvedTournamentID = emptyInstance
                    }
                }

                let record = DFSTournamentRecord(id: resolvedTournamentID, title: tournament.title, league: tournament.league, lockTime: computeLockTime(), playerSalaries: allPlayerSalaries)
                try await SupabaseService.shared.upsertTournament(record: record, accessToken: token)
                try await SupabaseService.shared.submitEntry(
                    tournamentID: resolvedTournamentID,
                    userID: userID,
                    lineupPlayerIDs: userLineup,
                    lineupPlayerSalaries: salaryMap,
                    lineupPlayerNames: namesList,
                    lineupNumber: lineupNumber,
                    accessToken: token
                )
                // Only deduct entry fee for new lineups, not edits
                if !isEditing {
                    rrScore -= tournament.entryFee
                }
                enteredTournamentIDs.insert(resolvedTournamentID)
                // Cache this entry locally for the lobby lineup preview
                let newEntry = DFSEntryRecord(
                    id: UUID().uuidString,
                    tournamentID: resolvedTournamentID,
                    userID: userID,
                    lineupPlayerIDs: userLineup,
                    submittedAt: Date(),
                    lineupTotalPoints: nil,
                    displayName: nil,
                    lineupPlayerSalaries: salaryMap,
                    lineupPlayerNames: namesList,
                    lineupNumber: lineupNumber
                )
                if isEditing {
                    // Replace the existing entry in the local cache
                    if var entries = userEntryRecords[resolvedTournamentID] {
                        if let idx = entries.firstIndex(where: { $0.lineupNumber == lineupNumber }) {
                            entries[idx] = newEntry
                        } else {
                            entries.append(newEntry)
                        }
                        userEntryRecords[resolvedTournamentID] = entries
                    }
                } else if userEntryRecords[resolvedTournamentID] != nil {
                    userEntryRecords[resolvedTournamentID]!.append(newEntry)
                } else {
                    userEntryRecords[resolvedTournamentID] = [newEntry]
                }
                // Update the local tournament reference if we got routed to an instance
                if resolvedTournamentID != tournament.id {
                    let instanceTournament = DFSTournament(
                        id: resolvedTournamentID,
                        title: tournament.title,
                        league: tournament.league,
                        entryCount: tournament.entryCount,
                        lineupSize: tournament.lineupSize,
                        salaryCap: tournament.salaryCap,
                        rosterSlots: tournament.rosterSlots,
                        isSingleGame: tournament.isSingleGame,
                        tournamentType: tournament.tournamentType,
                        gameID: tournament.gameID,
                        entryFee: tournament.entryFee
                    )
                    tournaments.append(instanceTournament)
                    activeTournamentID = resolvedTournamentID
                    // Reset field so it rebuilds with the correct instance's entries
                    fieldGenerated = false
                    fieldEntries = []
                }
                editingLineupNumber = nil
                await refreshRemoteEntries()
                await refreshLive()
            } catch {
                print("[DFS] Submit error raw: \(error)")
                self.error = "Unable to submit entry: \(normalizedError(error))"
            }
        }
    }

    func unregisterEntry(lineupNumber: Int = 1) async {
        guard let tournament else { return }
        guard !isTournamentLocked else { return }
        guard let token = accessToken, let userID else { return }
        do {
            try await SupabaseService.shared.unregisterEntry(tournamentID: tournament.id, userID: userID, lineupNumber: lineupNumber, accessToken: token)
            selectedPlayerIDs = []
            // Refund entry fee
            rrScore += tournament.entryFee
            // Remove specific lineup from cache
            if var entries = userEntryRecords[tournament.id] {
                entries.removeAll { ($0.lineupNumber ?? 1) == lineupNumber }
                if entries.isEmpty {
                    userEntryRecords.removeValue(forKey: tournament.id)
                    enteredTournamentIDs.remove(tournament.id)
                } else {
                    userEntryRecords[tournament.id] = entries
                }
            }
            await refreshRemoteEntries()
            await refreshLive()
        } catch {
            self.error = "Unable to unregister: \(normalizedError(error))"
        }
    }

    // MARK: - Tournament Invites

    func loadPendingInvites() async {
        guard let userID, let token = accessToken else { return }
        do {
            let invites = try await SupabaseService.shared.fetchPendingInvites(userID: userID, accessToken: token)
            // Filter out invites for tournaments that have already locked
            let now = Date()
            pendingInvites = invites.filter { invite in
                if let t = tournaments.first(where: { $0.id == invite.tournamentID }) {
                    return now < lockTimeForTournament(t)
                }
                // If we don't have the tournament locally, keep the invite (they may need to load that sport's slate)
                return true
            }
            // Cache inviter display names
            let inviterIDs = Set(pendingInvites.map(\.inviterID))
            let unknownIDs = inviterIDs.filter { remoteProfileNames[$0] == nil }
            if !unknownIDs.isEmpty {
                let profiles = try await SupabaseService.shared.fetchProfiles(userIDs: Array(unknownIDs), accessToken: token)
                for p in profiles {
                    remoteProfileNames[p.id] = p.username
                }
            }
        } catch {
            print("[DFS] Failed to load pending invites: \(error.localizedDescription)")
        }
    }

    func sendInvites(tournamentID: String, friendIDs: [String]) async {
        guard let userID, let token = accessToken else { return }
        for friendID in friendIDs {
            do {
                try await SupabaseService.shared.sendTournamentInvite(
                    tournamentID: tournamentID,
                    inviterID: userID,
                    inviteeID: friendID,
                    accessToken: token
                )
            } catch {
                print("[DFS] Failed to invite \(friendID): \(error.localizedDescription)")
            }
        }
    }

    func acceptInvite(_ invite: DFSTournamentInviteRecord) async {
        guard let token = accessToken else { return }
        do {
            try await SupabaseService.shared.respondToTournamentInvite(inviteID: invite.id, status: "accepted", accessToken: token)
            pendingInvites.removeAll { $0.id == invite.id }
        } catch {
            print("[DFS] Failed to accept invite: \(error.localizedDescription)")
        }
    }

    func declineInvite(_ invite: DFSTournamentInviteRecord) async {
        guard let token = accessToken else { return }
        do {
            try await SupabaseService.shared.respondToTournamentInvite(inviteID: invite.id, status: "declined", accessToken: token)
            pendingInvites.removeAll { $0.id == invite.id }
        } catch {
            print("[DFS] Failed to decline invite: \(error.localizedDescription)")
        }
    }

    func dismissError() {
        error = nil
    }

    // MARK: - Past Tournament Standings

    var pastTournamentLeaderboard: [DFSLeaderboardEntry] = []
    var pastTournamentFieldEntries: [DFSFieldEntry] = []
    var pastTournamentResultRecords: [DFSTournamentResultRecord] = []
    var isLoadingPastTournament: Bool = false
    /// Box score stats fetched from ESPN for the past tournament date (keyed by player ID)
    var pastTournamentPlayerStats: [String: DFSPlayerLiveStats] = [:]
    var pastTournamentSlateSalaries: [String: Int] = [:]  // tournament-level salary map for fallback
    private var pastTournamentStatsLoaded: String? = nil  // tournament ID for which stats were loaded
    private var settlingInProgress: Set<String> = []  // tournament IDs currently being settled (prevents races)

    /// Cache for live contest field + leaderboard so switching lineups or re-entering is instant.
    private struct LiveContestCache {
        var fieldEntries: [DFSFieldEntry]
        var leaderboard: [DFSLeaderboardEntry]
        var remoteEntries: [DFSEntryRecord]
        var profileNames: [String: String]
        var fieldGenerated: Bool
    }
    private var liveContestCache: [String: LiveContestCache] = [:]

    /// Cache for past tournament standings to avoid re-fetching when switching between multi-lineup entries
    private struct StandingsCache {
        let results: [DFSTournamentResultRecord]
        let leaderboard: [DFSLeaderboardEntry]
        let fieldEntries: [DFSFieldEntry]
        let slateSalaries: [String: Int]
        let userResultIDs: Set<String>
        let timestamp: Date
    }
    private var standingsCache: [String: StandingsCache] = [:]

    /// Fetches ESPN box score data for a past tournament date, caching the result.
    /// Also resolves any remaining "nba-" player IDs via the ESPN athlete endpoint.
    func loadPastTournamentBoxScores(tournamentId: String) async {
        guard pastTournamentStatsLoaded != tournamentId else { return }

        // Determine the sport and date from the tournament ID prefix
        let sportPrefix: String
        let dateString: String
        if tournamentId.hasPrefix("nba-") {
            sportPrefix = "nba"
            dateString = String(tournamentId.dropFirst(4).prefix(8))
        } else if tournamentId.hasPrefix("ncaam-") {
            sportPrefix = "ncaam"
            dateString = String(tournamentId.dropFirst(6).prefix(8))
        } else if tournamentId.hasPrefix("mlb-") {
            sportPrefix = "mlb"
            dateString = String(tournamentId.dropFirst(4).prefix(8))
        } else if tournamentId.hasPrefix("nhl-") {
            sportPrefix = "nhl"
            dateString = String(tournamentId.dropFirst(4).prefix(8))
        } else if tournamentId.hasPrefix("epl-") {
            sportPrefix = "epl"
            dateString = String(tournamentId.dropFirst(4).prefix(8))
        } else if tournamentId.hasPrefix("ucl-") {
            sportPrefix = "ucl"
            dateString = String(tournamentId.dropFirst(4).prefix(8))
        } else if tournamentId.hasPrefix("pga-") {
            // For golf, fetch the ESPN PGA scoreboard to get round-by-round scores
            // Tournament ID is "pga-{eventID}-{fieldSize}" — extract just the ESPN event ID
            let pgaAfterPrefix = tournamentId.replacingOccurrences(of: "pga-", with: "")
            let eventID = pgaAfterPrefix.components(separatedBy: "-").first ?? pgaAfterPrefix
            // Use the server tournament's lock time for the ESPN date-based fallback query.
            // Old events aren't on the current scoreboard, so we need the actual tournament
            // date (not Date() or createdAt which may differ).
            let serverTournament = try? await SupabaseService.shared.fetchTournament(
                tournamentID: tournamentId, accessToken: accessToken ?? ""
            )
            let eventDate = serverTournament?.lockTime ?? pastTournamentResultRecords.compactMap(\.createdAt).min() ?? Date()
            let slateGame = DFSSlateGame(
                id: eventID,
                awayTeam: "",
                homeTeam: "PGA",
                startTime: eventDate,
                state: "post"
            )
            let scoringProvider = ESPNPGADFSLiveScoringProvider()
            if let snapshot = try? await scoringProvider.fetchScoreSnapshot(for: [slateGame]),
               !snapshot.playerLiveStats.isEmpty {
                // Merge snapshot stats (contains round scores in fgm/fga/threePM/threePA fields)
                for (pid, stats) in snapshot.playerLiveStats {
                    pastTournamentPlayerStats[pid] = stats
                }
                pastTournamentStatsLoaded = tournamentId
            } else {
                print("[DFS-PGA] Box scores: ESPN returned empty stats for event \(eventID) (date: \(eventDate))")
            }
            // Resolve any remaining unresolved player names from ESPN
            await resolveUnresolvedPlayerNames(tournamentId: tournamentId, sportPrefix: "pga", espnSport: "golf/pga")
            return
        } else {
            return
        }

        guard dateString.count == 8 else { return }

        // Fetch the scoreboard and scoring snapshot for the sport
        let espnSport: String
        switch sportPrefix {
        case "ncaam": espnSport = "basketball/mens-college-basketball"
        case "mlb": espnSport = "baseball/mlb"
        case "nhl": espnSport = "hockey/nhl"
        case "epl": espnSport = "soccer/eng.1"
        case "ucl": espnSport = "soccer/uefa.champions"
        case "ufc": espnSport = "mma/ufc"
        case "nfl": espnSport = "football/nfl"
        case "cfb": espnSport = "football/college-football"
        default: espnSport = "basketball/nba"
        }

        let games = await fetchSlateGamesForDate(dateString, espnSport: espnSport)
        guard !games.isEmpty else { return }

        if let snapshot = try? await scoringProvider.fetchScoreSnapshot(for: games) {
            pastTournamentPlayerStats = snapshot.playerLiveStats
            pastTournamentStatsLoaded = tournamentId

            // Resolve any player IDs that are still unresolved (not in box scores)
            await resolveUnresolvedPlayerNames(tournamentId: tournamentId, sportPrefix: sportPrefix, espnSport: espnSport)
        }
    }

    /// Fetch individual athlete names from ESPN for unresolved player IDs.
    /// First tries individual athlete endpoints, then falls back to team rosters for any still-unresolved.
    private func resolveUnresolvedPlayerNames(tournamentId: String, sportPrefix: String, espnSport: String) async {
        let rawPrefixes = ["nba-", "pga-", "ncaam-", "mlb-", "nhl-", "epl-", "ucl-", "ufc-", "nfl-", "cfb-"]
        let allRecordPlayerIDs = pastTournamentResultRecords.flatMap { $0.lineupPlayerIDs }
        let unresolvedIDs = Array(Set(allRecordPlayerIDs)).filter { pid in
            guard pid.hasPrefix("\(sportPrefix)-") else { return false }
            guard let existing = pastTournamentPlayerStats[pid] else { return true }
            // Also re-resolve if the stored name is itself a raw ID
            return rawPrefixes.contains(where: { existing.name.hasPrefix($0) }) || existing.name.isEmpty
        }
        guard !unresolvedIDs.isEmpty else { return }

        // Step 1: Try individual athlete endpoints (batched to avoid network storms)
        let capturedSportPrefix = sportPrefix
        let capturedESPNSportResolve = espnSport
        let isSoccerResolve = sportPrefix == "epl" || sportPrefix == "ucl"
        let batchedIDs = Array(unresolvedIDs.prefix(200))
        let batchSize = 10
        for batchStart in stride(from: 0, to: batchedIDs.count, by: batchSize) {
            let batch = Array(batchedIDs[batchStart..<min(batchStart + batchSize, batchedIDs.count)])
            await withTaskGroup(of: (String, String?, String?).self) { group in
            for pid in batch {
                group.addTask {
                    let athleteID = pid.replacingOccurrences(of: "\(capturedSportPrefix)-", with: "")
                    // Soccer uses v3 endpoint (v2 athlete endpoint returns 404 for soccer)
                    let urlString: String
                    if isSoccerResolve {
                        urlString = "https://site.web.api.espn.com/apis/common/v3/sports/soccer/\(capturedESPNSportResolve.replacingOccurrences(of: "soccer/", with: ""))/athletes/\(athleteID)"
                    } else {
                        urlString = "https://site.api.espn.com/apis/site/v2/sports/\(capturedESPNSportResolve)/athletes/\(athleteID)"
                    }
                    guard let url = URL(string: urlString) else {
                        return (pid, nil, nil)
                    }
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return (pid, nil, nil)
                    }
                    // v3 nests under "athlete", v2 is top-level
                    let name: String?
                    let posAbbr: String?
                    if isSoccerResolve {
                        let athlete = json["athlete"] as? [String: Any]
                        name = athlete?["displayName"] as? String
                        posAbbr = (athlete?["position"] as? [String: Any])?["abbreviation"] as? String
                    } else {
                        name = json["displayName"] as? String
                        posAbbr = (json["position"] as? [String: Any])?["abbreviation"] as? String
                    }
                    return (pid, name, posAbbr)
                }
            }
            for await (pid, name, posAbbr) in group {
                if let name {
                    // Mark goalies with minutes="G" so the view can detect them
                    let minutesMarker = (posAbbr?.uppercased() == "G") ? "G" : ""
                    pastTournamentPlayerStats[pid] = DFSPlayerLiveStats(
                        name: name, points: 0, rebounds: 0, assists: 0,
                        steals: 0, blocks: 0, turnovers: 0, minutes: minutesMarker,
                        fgm: 0, fga: 0, threePM: 0, threePA: 0, ftm: 0, fta: 0,
                        fantasyPoints: 0, gameStatus: "Final", gameFinal: true
                    )
                }
            }
            }  // end withTaskGroup
        }  // end batch loop

        // Step 2: For any still-unresolved IDs, try team rosters (ESPN roster API returns all players)
        let stillUnresolved = unresolvedIDs.filter { pastTournamentPlayerStats[$0] == nil }
        guard !stillUnresolved.isEmpty else { return }

        let neededAthleteIDs = Set(stillUnresolved.map { $0.replacingOccurrences(of: "\(sportPrefix)-", with: "") })

        // Extract date from tournament ID (e.g., "mlb-20260329")
        let dateKey = tournamentId.components(separatedBy: "-").last ?? ""
        let scoreboardURL: URL?
        if !dateKey.isEmpty {
            scoreboardURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(espnSport)/scoreboard?dates=\(dateKey)")
        } else {
            scoreboardURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(espnSport)/scoreboard")
        }

        guard let sbURL = scoreboardURL,
              let (sbData, sbResp) = try? await URLSession.shared.data(from: sbURL),
              let sbHttp = sbResp as? HTTPURLResponse, (200..<300).contains(sbHttp.statusCode),
              let sbJSON = try? JSONSerialization.jsonObject(with: sbData) as? [String: Any],
              let events = sbJSON["events"] as? [[String: Any]] else { return }

        // Collect team IDs from events
        var teamIDs: Set<String> = []
        for event in events {
            if let competitions = event["competitions"] as? [[String: Any]] {
                for comp in competitions {
                    if let competitors = comp["competitors"] as? [[String: Any]] {
                        for competitor in competitors {
                            if let teamID = competitor["id"] as? String {
                                teamIDs.insert(teamID)
                            }
                        }
                    }
                }
            }
        }

        // Fetch team rosters in batches to find missing player names (with position)
        let teamIDArray = Array(teamIDs)
        for teamBatchStart in stride(from: 0, to: teamIDArray.count, by: 6) {
            let teamBatch = Array(teamIDArray[teamBatchStart..<min(teamBatchStart + 6, teamIDArray.count)])
        await withTaskGroup(of: [(String, String, String)].self) { group in
            for teamID in teamBatch {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(espnSport)/teams/\(teamID)/roster") else { return [] }
                    guard let (data, resp) = try? await URLSession.shared.data(from: url),
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

                    var found: [(String, String, String)] = []  // (pid, name, posAbbr)
                    // Handle both flat (athletes: []) and grouped (athletes: [{position, items}]) formats
                    if let athletes = json["athletes"] as? [[String: Any]] {
                        for group in athletes {
                            // Grouped format: group-level position applies to all items
                            let groupPos = (group["position"] as? String) ?? ""
                            let items: [[String: Any]]
                            if let nested = group["items"] as? [[String: Any]] {
                                items = nested
                            } else if group["id"] != nil {
                                items = [group]
                            } else {
                                continue
                            }
                            for athlete in items {
                                if let aid = athlete["id"] as? String, neededAthleteIDs.contains(aid),
                                   let name = athlete["displayName"] as? String ?? athlete["fullName"] as? String {
                                    // Athlete-level position overrides group-level
                                    let athletePos = (athlete["position"] as? [String: Any])?["abbreviation"] as? String
                                        ?? (athlete["position"] as? String)
                                        ?? groupPos
                                    found.append(("\(capturedSportPrefix)-\(aid)", name, athletePos))
                                }
                            }
                        }
                    }
                    return found
                }
            }
            for await matches in group {
                for (pid, name, posAbbr) in matches {
                    let minutesMarker = (posAbbr.uppercased() == "G") ? "G" : ""
                    pastTournamentPlayerStats[pid] = DFSPlayerLiveStats(
                        name: name, points: 0, rebounds: 0, assists: 0,
                        steals: 0, blocks: 0, turnovers: 0, minutes: minutesMarker,
                        fgm: 0, fga: 0, threePM: 0, threePA: 0, ftm: 0, fta: 0,
                        fantasyPoints: 0, gameStatus: "Final", gameFinal: true
                    )
                }
            }
        }  // end withTaskGroup
        }  // end team batch loop
    }

    func loadPastTournamentStandings(tournamentId: String) async {
        guard let token = accessToken, let userID else { return }

        // Check cache first — settled tournaments don't change, use long TTL
        if let cached = standingsCache[tournamentId],
           Date().timeIntervalSince(cached.timestamp) < 86400 {  // 24-hour TTL (settled data is static)
            // Validate cache: if all non-user entries have 0 points, cache is stale/bad
            let botLeaderboard = cached.leaderboard.filter { !$0.isCurrentUser }
            let allBotsZero = !botLeaderboard.isEmpty && botLeaderboard.allSatisfy { $0.points == 0 }
            let userHasPts = cached.leaderboard.contains { $0.isCurrentUser && $0.points > 0 }
            let allResultsZero = cached.leaderboard.allSatisfy { $0.points == 0 }
            // Also detect partial-zero: some user entries scored, others at 0.0 (bad multi-lineup settlement)
            let userLeaderboard = cached.leaderboard.filter { $0.isCurrentUser }
            let someUserZeroCache = userLeaderboard.count > 1
                && userLeaderboard.contains(where: { $0.points > 0 })
                && userLeaderboard.contains(where: { $0.points == 0 })
            if allResultsZero || (allBotsZero && userHasPts) || someUserZeroCache {
                let reason = allResultsZero ? "all entries" : someUserZeroCache ? "partial user entries" : "all bots"
                print("[DFS] Cache for \(tournamentId) has \(reason) at 0 pts — invalidating")
                standingsCache.removeValue(forKey: tournamentId)
            } else {
                pastTournamentResultRecords = cached.results
                pastTournamentLeaderboard = cached.leaderboard
                pastTournamentFieldEntries = cached.fieldEntries
                pastTournamentSlateSalaries = cached.slateSalaries
                return
            }
        }

        isLoadingPastTournament = true
        defer { isLoadingPastTournament = false }

        // Helper: determine if a result record belongs to the current user.
        // Primary: userID match. Fallback: entryName matches profileName (for legacy data
        // where userID may be nil). We do NOT trust isCurrentUser alone because in multi-user
        // tournaments, another user's settlement run sets isCurrentUser=true for THEIR entries,
        // which would falsely claim them as ours.
        let pName = profileName
        func isUserEntry(_ r: DFSTournamentResultRecord) -> Bool {
            if r.userID == userID { return true }
            // Only trust isCurrentUser if userID is nil (legacy data from before userID was set)
            if r.isCurrentUser && r.userID == nil {
                // Additional check: entry name must match profile name to avoid false positives
                if !pName.isEmpty {
                    if r.entryName == pName { return true }
                    if r.entryName.hasPrefix(pName + " #") { return true }
                }
            }
            // Name-based fallback for non-bot entries with no userID
            if !pName.isEmpty && !r.isBot && r.userID == nil {
                if r.entryName == pName { return true }
                if r.entryName.hasPrefix(pName + " #") { return true }
            }
            return false
        }

        do {
            // Try the new dfs_tournament_results table first (has full leaderboard including bots)
            var results = try await SupabaseService.shared.fetchTournamentResults(tournamentID: tournamentId, accessToken: token)

            // Deduplicate: if multiple settlement runs accumulated (RLS blocked delete),
            // keep all user entries + latest bot entry per entry_name.
            if results.count > 550 {
                let userEntries = results.filter { isUserEntry($0) }

                var seen = Set<String>()
                var deduped: [DFSTournamentResultRecord] = []

                // Add all user entries first
                for userEntry in userEntries {
                    if seen.insert(userEntry.entryName).inserted {
                        deduped.append(userEntry)
                    }
                }

                // Then add bot entries, keeping latest per name (reverse = newest first)
                for r in results.reversed() {
                    guard !isUserEntry(r) else { continue }
                    if seen.insert(r.entryName).inserted {
                        deduped.append(r)
                    }
                }

                // Cap at expected entry count to handle duplicate settlement runs
                let expectedSize = Self.entryCountFromTournamentID(tournamentId)
                let maxEntries = max(expectedSize, 2000)
                if deduped.count > maxEntries {
                    // Keep user entries + top non-user entries by points
                    let user = deduped.filter { isUserEntry($0) }
                    var others = deduped.filter { !isUserEntry($0) }
                    others.sort { $0.totalPoints > $1.totalPoints }
                    deduped = user + Array(others.prefix(maxEntries - user.count))
                }

                // Re-sort by points descending and re-assign tie-aware ranks
                deduped.sort { $0.totalPoints > $1.totalPoints }
                var dedupRanks = [Int](repeating: 1, count: deduped.count)
                for i in 1..<deduped.count {
                    if abs(deduped[i].totalPoints - deduped[i - 1].totalPoints) < 0.001 {
                        dedupRanks[i] = dedupRanks[i - 1]
                    } else {
                        dedupRanks[i] = i + 1
                    }
                }
                results = deduped.enumerated().map { offset, r in
                    DFSTournamentResultRecord(
                        id: r.id, tournamentID: r.tournamentID, userID: r.userID,
                        entryName: r.entryName, lineupPlayerIDs: r.lineupPlayerIDs,
                        lineupPlayerNames: r.lineupPlayerNames, totalPoints: r.totalPoints,
                        playerPoints: r.playerPoints ?? [:], playerSalaries: r.playerSalaries,
                        rank: dedupRanks[offset],
                        rrDelta: r.rrDelta, isCurrentUser: r.isCurrentUser, isBot: r.isBot
                    )
                }
            }

            // Check if server data is "good": has many entries with non-zero scores
            let userResult = results.first(where: { isUserEntry($0) })
            let hasNonZeroScores = results.contains(where: { $0.totalPoints > 0 })
            let userHasPoints = userResult?.totalPoints ?? 0 > 0
            // Check if bot entries have salary data (missing = bad re-settlement)
            let botEntries = results.filter { $0.isBot }
            let botsHaveSalaries = botEntries.prefix(10).contains(where: { entry in
                guard let salaries = entry.playerSalaries else { return false }
                return !salaries.isEmpty
            })
            // Detect oversized field: more results than the tournament's entry count
            let expectedEntryCount = Self.entryCountFromTournamentID(tournamentId)
            let fieldOversized = results.count > expectedEntryCount && expectedEntryCount <= 10
            // Detect invalid bot lineups (stale data from before bot/pricing fixes).
            // Check for: incomplete lineups, over salary cap lineups.
            let isSG = tournamentId.contains("-sg-")
            let expectedLineupSize = userResult?.lineupPlayerIDs.count ?? (isSG ? 6 : 0)
            // For single-game, cap is $50K (DK Showdown). Stored salaries already include 1.5x for MVP.
            let sgCapForValidation = isSG ? 50000 : 0
            let botsHaveValidLineups: Bool = {
                guard !botEntries.isEmpty else { return true }
                let sampleBots = Array(botEntries.prefix(20))
                var invalidCount = 0
                for bot in sampleBots {
                    // Check lineup completeness
                    if expectedLineupSize > 0 && bot.lineupPlayerIDs.count < expectedLineupSize {
                        invalidCount += 1
                        continue
                    }
                    // Check salary cap for single-game (stored salaries include 1.5x MVP)
                    if isSG, sgCapForValidation > 0, let salaries = bot.playerSalaries {
                        let total = salaries.values.reduce(0, +)
                        if total > sgCapForValidation {
                            invalidCount += 1
                            continue
                        }
                    }
                }
                // Also flag as invalid if ALL sampled bots have 0 points (empty lineups)
                let allBotsZero = sampleBots.allSatisfy { $0.totalPoints == 0 }
                if allBotsZero && userHasPoints {
                    print("[DFS] All \(sampleBots.count) sampled bots have 0 points for \(tournamentId) — likely empty lineups")
                    return false
                }
                if invalidCount > 0 {
                    print("[DFS] \(invalidCount)/\(sampleBots.count) sampled bots are invalid (incomplete or over cap) for \(tournamentId)")
                }
                return invalidCount == 0
            }()

            // For small tournaments (≤10 entries), accept data if count matches and has scores
            let isSmallTournament = expectedEntryCount <= 10
            let isGoodData: Bool
            if isSmallTournament {
                isGoodData = results.count == expectedEntryCount && hasNonZeroScores
                    && (userResult == nil || userHasPoints)
                    && !fieldOversized
                    && botsHaveValidLineups
            } else {
                // Also check that result count matches expected entry count for 2K tournaments
                let fieldUndersized = expectedEntryCount >= 2000 && results.count < expectedEntryCount
                isGoodData = results.count >= 50 && hasNonZeroScores
                    && (userResult == nil || userHasPoints)
                    && (botEntries.isEmpty || botsHaveSalaries)
                    && !fieldUndersized
                    && botsHaveValidLineups
            }

            if !isGoodData {
                print("[DFS-Standings] Bad data for \(tournamentId): results=\(results.count) expected=\(expectedEntryCount) hasScores=\(hasNonZeroScores) userPts=\(userHasPoints) botsSalaries=\(botsHaveSalaries) botsValid=\(botsHaveValidLineups) small=\(isSmallTournament)")
            }

            // If data is missing or bad, attempt on-the-fly settlement
            if !isGoodData {
                // Clear local settled marker so re-settlement can run
                var settled = settledTournaments
                if settled.remove(tournamentId) != nil {
                    settledTournamentData = (try? JSONEncoder().encode(settled)) ?? Data()
                    print("[DFS] Cleared settled marker for \(tournamentId) due to bad data")
                }

                // If another path is already settling this tournament, wait for it
                if settlingInProgress.contains(tournamentId) {
                    // Poll until settlement finishes (up to ~30s)
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .seconds(1))
                        if !settlingInProgress.contains(tournamentId) { break }
                    }
                    // Re-fetch after the other settlement finished
                    results = (try? await SupabaseService.shared.fetchTournamentResults(tournamentID: tournamentId, accessToken: token)) ?? []
                } else {
                    // Find the user's entry for this tournament
                    let userEntry = try? await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)
                        .first(where: { $0.tournamentID == tournamentId })

                    if let userEntry {
                        if tournamentId.hasPrefix("pga-") {
                            await settleUnsettledPastGolfTournament(
                                tournamentID: tournamentId,
                                userEntry: userEntry,
                                token: token,
                                userID: userID
                            )
                            // Re-fetch for PGA (different settlement function)
                            results = (try? await SupabaseService.shared.fetchTournamentResults(tournamentID: tournamentId, accessToken: token)) ?? []
                        } else {
                            // Use the locally-generated results directly — server may still
                            // have stale data if the DELETE was blocked by RLS.
                            // Force-regenerate bots if the existing data has all-zero bot scores
                            // (saved bots have player IDs that don't match the scoring snapshot).
                            let allBotsZero = !botEntries.isEmpty && botEntries.allSatisfy { $0.totalPoints == 0 } && userHasPoints
                            let needsBotRegen = allBotsZero
                            let localResults = await settleUnsettledPastTournament(
                                tournamentID: tournamentId,
                                userEntry: userEntry,
                                token: token,
                                userID: userID,
                                forceRegenerateBots: needsBotRegen
                            )
                            if let localResults, !localResults.isEmpty {
                                results = localResults
                                print("[DFS-Standings] Using \(localResults.count) locally-generated results for \(tournamentId)")
                            } else {
                                // Fallback: re-fetch from server
                                results = (try? await SupabaseService.shared.fetchTournamentResults(tournamentID: tournamentId, accessToken: token)) ?? []
                            }
                        }
                    }
                }
            }

            // Load tournament-level salary data for fallback display
            if let tournament = try? await SupabaseService.shared.fetchTournament(tournamentID: tournamentId, accessToken: token),
               let salaries = tournament.playerSalaries {
                pastTournamentSlateSalaries = salaries
            } else {
                pastTournamentSlateSalaries = [:]
            }

            if !results.isEmpty {
                pastTournamentResultRecords = results

                // Fetch the user's dfs_entries to identify them by lineup player IDs
                let userDFSEntries = (try? await SupabaseService.shared.fetchEntries(
                    tournamentID: tournamentId, accessToken: token
                ))?.filter { $0.userID == userID } ?? []
                let userLineupSets = Set(userDFSEntries.map { Set($0.lineupPlayerIDs) })

                // Build a set of result IDs that belong to the current user.
                // We match by: (1) explicit user markers, (2) lineup player IDs for non-bot
                // non-real-user entries, and (3) bot-flagged entries whose name matches the
                // user's profile (handles old persistLeaderboardToServer bug where multi-lineup
                // entries were incorrectly saved as bots).
                var userResultIDs = Set<String>()
                for r in results {
                    if isUserEntry(r) { userResultIDs.insert(r.id); continue }
                    if !userLineupSets.isEmpty {
                        let resultLineup = Set(r.lineupPlayerIDs)
                        if userLineupSets.contains(resultLineup) {
                            // Only claim entries that don't belong to another known user.
                            // In single-game tournaments, multiple real users can have identical lineups.
                            if r.userID != nil && r.userID != userID {
                                // This entry belongs to another real user — do NOT claim it
                                continue
                            }
                            if !r.isBot {
                                // Non-bot entry with matching lineup and no conflicting userID
                                userResultIDs.insert(r.id); continue
                            }
                            // Bot-flagged entry with matching lineup: only claim it if the
                            // entry name matches the user's profile name (old persist bug).
                            if !pName.isEmpty && (r.entryName == pName || r.entryName.hasPrefix(pName + " #")) {
                                userResultIDs.insert(r.id); continue
                            }
                        }
                    }
                }

                print("[DFS-Standings] results=\(results.count) userID=\(userID) profile=\(pName) dfsEntries=\(userDFSEntries.count) lineupSets=\(userLineupSets.count) matched=\(userResultIDs.count)")

                // For each user dfs_entry that wasn't found in the fetched results,
                // inject a synthetic result record so the leaderboard shows all lineups.
                // This handles both the case where ALL entries are missing (user ranked
                // outside top 1000) and where SOME entries are missing (multi-lineup with
                // one lineup in top 1000 and another outside).
                let matchedLineupSets: Set<Set<String>> = {
                    var matched = Set<Set<String>>()
                    for rid in userResultIDs {
                        if let r = results.first(where: { $0.id == rid }) {
                            matched.insert(Set(r.lineupPlayerIDs))
                        }
                    }
                    return matched
                }()
                let missingEntries = userDFSEntries.filter { entry in
                    !matchedLineupSets.contains(Set(entry.lineupPlayerIDs))
                }
                if !missingEntries.isEmpty {
                    let isMulti = userDFSEntries.count > 1
                    // Build lookup from local history for fallback points/rank
                    let localHistoryForTournament = dfsHistory.filter { $0.tournamentId == tournamentId }
                    for (idx, entry) in missingEntries.enumerated() {
                        let syntheticID = "synthetic-user-\(idx)"
                        let lineupNum = entry.lineupNumber ?? (idx + 1)
                        let displayName = isMulti
                            ? "\(pName.isEmpty ? "You" : pName) #\(lineupNum)"
                            : (pName.isEmpty ? "You" : pName)
                        // Try dfs_entries points first, then fall back to local history
                        var userPts = entry.lineupTotalPoints ?? 0
                        var localRank: Int? = nil
                        if userPts == 0 {
                            // Match local history by lineupNumber or by closest points
                            let localMatch = localHistoryForTournament.first(where: { $0.lineupNumber == lineupNum })
                                ?? (isMulti ? nil : localHistoryForTournament.first)
                            if let lm = localMatch {
                                userPts = lm.lineupPoints
                                localRank = lm.rank
                            }
                        }
                        let higherCount = results.filter { $0.totalPoints > userPts }.count
                        let estimatedRank = localRank ?? (higherCount + 1)

                        let syntheticResult = DFSTournamentResultRecord(
                            id: syntheticID,
                            tournamentID: tournamentId,
                            userID: userID,
                            entryName: displayName,
                            lineupPlayerIDs: entry.lineupPlayerIDs,
                            lineupPlayerNames: entry.lineupPlayerNames ?? [],
                            totalPoints: userPts,
                            playerPoints: nil,
                            playerSalaries: entry.lineupPlayerSalaries,
                            rank: estimatedRank,
                            rrDelta: 0,
                            isCurrentUser: true,
                            isBot: false
                        )
                        results.append(syntheticResult)
                        userResultIDs.insert(syntheticID)
                        print("[DFS-Standings] Injected synthetic entry: \(displayName) rank=\(estimatedRank) pts=\(userPts)")
                    }
                    // Re-sort and re-assign ranks (tie-aware)
                    results.sort { $0.totalPoints > $1.totalPoints }
                    var resortTieRanks = [Int](repeating: 1, count: results.count)
                    for i in 1..<results.count {
                        if abs(results[i].totalPoints - results[i - 1].totalPoints) < 0.001 {
                            resortTieRanks[i] = resortTieRanks[i - 1]
                        } else {
                            resortTieRanks[i] = i + 1
                        }
                    }
                    results = results.enumerated().map { offset, r in
                        DFSTournamentResultRecord(
                            id: r.id, tournamentID: r.tournamentID, userID: r.userID,
                            entryName: r.entryName, lineupPlayerIDs: r.lineupPlayerIDs,
                            lineupPlayerNames: r.lineupPlayerNames, totalPoints: r.totalPoints,
                            playerPoints: r.playerPoints, playerSalaries: r.playerSalaries,
                            rank: resortTieRanks[offset],
                            rrDelta: r.rrDelta,
                            isCurrentUser: userResultIDs.contains(r.id),
                            isBot: r.isBot
                        )
                    }
                    pastTournamentResultRecords = results
                }

                // Always correct the isCurrentUser flag on result records using our
                // authoritative userResultIDs set, not the raw server flag (which may
                // have been set by another user's settlement run).
                // Sort by points descending for consistent leaderboard display
                // (stored ranks may be stale from earlier settlement bugs).
                let correctedResults = results.map { r in
                    DFSTournamentResultRecord(
                        id: r.id, tournamentID: r.tournamentID, userID: r.userID,
                        entryName: r.entryName, lineupPlayerIDs: r.lineupPlayerIDs,
                        lineupPlayerNames: r.lineupPlayerNames, totalPoints: r.totalPoints,
                        playerPoints: r.playerPoints, playerSalaries: r.playerSalaries,
                        rank: r.rank, rrDelta: r.rrDelta,
                        isCurrentUser: userResultIDs.contains(r.id),
                        isBot: r.isBot
                    )
                }
                let sortedResults = correctedResults.sorted { $0.totalPoints > $1.totalPoints }
                pastTournamentResultRecords = sortedResults

                pastTournamentFieldEntries = sortedResults.map { r in
                    DFSFieldEntry(
                        id: UUID(uuidString: r.id) ?? UUID(),
                        name: r.entryName,
                        playerIDs: r.lineupPlayerIDs,
                        isCurrentUser: userResultIDs.contains(r.id)
                    )
                }
                // Build leaderboard with tie-aware ranks:
                // entries with the same points share the same rank, next rank skips ahead.
                var tieAwareRanks = [Int](repeating: 1, count: sortedResults.count)
                for i in 1..<sortedResults.count {
                    if abs(sortedResults[i].totalPoints - sortedResults[i - 1].totalPoints) < 0.001 {
                        tieAwareRanks[i] = tieAwareRanks[i - 1]
                    } else {
                        tieAwareRanks[i] = i + 1
                    }
                }
                pastTournamentLeaderboard = sortedResults.enumerated().map { offset, r in
                    DFSLeaderboardEntry(
                        id: UUID(uuidString: r.id) ?? UUID(),
                        name: r.entryName,
                        rank: tieAwareRanks[offset],
                        points: r.totalPoints,
                        isCurrentUser: userResultIDs.contains(r.id)
                    )
                }

                // Recompute correct pooled RR deltas locally using tie-aware
                // leaderboard data. The server may have stale non-pooled values
                // from earlier settlement code, so we can't trust serverUser.rrDelta.
                let standingsEntryCount = Self.entryCountFromTournamentID(tournamentId)
                var correctRRByEntryID: [String: Int] = [:]
                for (offset, r) in sortedResults.enumerated() where userResultIDs.contains(r.id) {
                    let rank = tieAwareRanks[offset]
                    let tieCount = tieAwareRanks.filter { $0 == rank }.count
                    let pooledRR = DFSEngine.pooledRRDelta(tiedRank: rank, tieCount: tieCount, entryCount: standingsEntryCount)
                    correctRRByEntryID[r.id] = pooledRR
                }

                // If any user entry's server rrDelta differs from the locally
                // recomputed pooled value, update the server records too.
                var serverRecordsNeedUpdate = false
                var correctedServerResults = results
                for (i, r) in correctedServerResults.enumerated() {
                    if let correctRR = correctRRByEntryID[r.id], r.rrDelta != correctRR {
                        correctedServerResults[i] = DFSTournamentResultRecord(
                            id: r.id, tournamentID: r.tournamentID, userID: r.userID,
                            entryName: r.entryName, lineupPlayerIDs: r.lineupPlayerIDs,
                            lineupPlayerNames: r.lineupPlayerNames, totalPoints: r.totalPoints,
                            playerPoints: r.playerPoints, playerSalaries: r.playerSalaries,
                            rank: r.rank, rrDelta: correctRR,
                            isCurrentUser: r.isCurrentUser, isBot: r.isBot
                        )
                        serverRecordsNeedUpdate = true
                        print("[DFS-Standings] Correcting rrDelta for \(r.entryName): \(r.rrDelta) → \(correctRR)")
                    }
                }
                if serverRecordsNeedUpdate {
                    // Update the local display records
                    pastTournamentResultRecords = correctedServerResults
                    // Push corrected records to server so future syncs get the right value
                    let userRecordsToFix = correctedServerResults.filter { correctRRByEntryID[$0.id] != nil && userResultIDs.contains($0.id) }
                    if let token = accessToken, !userRecordsToFix.isEmpty {
                        try? await SupabaseService.shared.upsertTournamentResults(
                            tournamentID: tournamentId,
                            results: userRecordsToFix,
                            accessToken: token
                        )
                    }
                }

                // Sync local dfsHistory entries with server rank/points so the
                // DFS history list stays consistent with the standings view.
                // Handle all user entries (multi-lineup support).
                // Use corrected server results (with recomputed pooled rrDelta).
                let serverUserResults = correctedServerResults.filter { userResultIDs.contains($0.id) }
                let isMultiLineup = serverUserResults.count > 1
                if !serverUserResults.isEmpty {
                    var updated = dfsHistory
                    var didChange = false
                    var matchedLocalIndices = Set<Int>()
                    var newEntries: [DFSResult] = []

                    // Derive tournament title from existing local entry or server data
                    let existingTitle = updated.first(where: { $0.tournamentId == tournamentId })?.tournamentTitle ?? "Tournament"
                    let existingLoggedAt = updated.first(where: { $0.tournamentId == tournamentId })?.loggedAt ?? Date()

                    for serverUser in serverUserResults {
                        // Derive lineup number from entry name (e.g., "Username #2").
                        // Only accept small numbers (1-20) — larger values are bot indices, not lineup numbers.
                        let serverLineupNum: Int? = {
                            if let hashRange = serverUser.entryName.range(of: "#"),
                               let num = Int(serverUser.entryName[hashRange.upperBound...].trimmingCharacters(in: .whitespaces)),
                               num >= 1 && num <= 20 {
                                return num
                            }
                            return nil
                        }()

                        // Use the locally recomputed pooled rrDelta (not raw server value)
                        let correctRR = correctRRByEntryID[serverUser.id] ?? serverUser.rrDelta
                        let correctRank: Int = {
                            if let idx = sortedResults.firstIndex(where: { $0.id == serverUser.id }) {
                                return tieAwareRanks[idx]
                            }
                            return serverUser.rank
                        }()

                        // Find matching local history entry
                        var matchIdx: Int? = nil
                        if isMultiLineup {
                            // Try exact lineupNumber match first
                            for (i, r) in updated.enumerated() {
                                guard r.tournamentId == tournamentId, !matchedLocalIndices.contains(i) else { continue }
                                if r.lineupNumber == serverLineupNum {
                                    matchIdx = i
                                    break
                                }
                            }
                            // Fallback: match an unmatched entry with nil lineupNumber (corrupted data)
                            if matchIdx == nil {
                                for (i, r) in updated.enumerated() {
                                    guard r.tournamentId == tournamentId, !matchedLocalIndices.contains(i) else { continue }
                                    if r.lineupNumber == nil {
                                        matchIdx = i
                                        break
                                    }
                                }
                            }
                        } else {
                            matchIdx = updated.firstIndex(where: { $0.tournamentId == tournamentId })
                        }

                        if let idx = matchIdx {
                            matchedLocalIndices.insert(idx)
                            let old = updated[idx]
                            // Always update: restore lineupNumber if it was lost, sync rank/points/rrDelta
                            let needsUpdate = old.rank != correctRank
                                || old.lineupPoints != serverUser.totalPoints
                                || old.rrDelta != correctRR
                                || (isMultiLineup && old.lineupNumber != serverLineupNum)
                            if needsUpdate {
                                let oldRR = old.rrDelta
                                updated[idx] = DFSResult(
                                    id: old.id,
                                    tournamentTitle: old.tournamentTitle,
                                    rank: correctRank,
                                    totalEntries: max(results.count, old.totalEntries),
                                    lineupPoints: serverUser.totalPoints,
                                    rrDelta: correctRR,
                                    loggedAt: old.loggedAt,
                                    tournamentId: old.tournamentId,
                                    lineupNumber: isMultiLineup ? serverLineupNum : old.lineupNumber
                                )
                                didChange = true
                                // Also adjust the running rrScore total
                                if oldRR != correctRR {
                                    rrScore += (correctRR - oldRR)
                                    print("[DFS-Standings] Adjusted rrScore by \(correctRR - oldRR) for \(old.tournamentId ?? "?")")
                                }
                            }
                        } else if isMultiLineup {
                            // No local entry found for this lineup — create a new one.
                            // This handles multi-lineup tournaments where live settlement
                            // only recorded one lineup (the active one).
                            newEntries.append(DFSResult(
                                id: UUID(),
                                tournamentTitle: existingTitle,
                                rank: correctRank,
                                totalEntries: max(results.count, Self.entryCountFromTournamentID(tournamentId)),
                                lineupPoints: serverUser.totalPoints,
                                rrDelta: correctRR,
                                loggedAt: existingLoggedAt,
                                tournamentId: tournamentId,
                                lineupNumber: serverLineupNum
                            ))
                            didChange = true
                        }
                    }
                    if didChange {
                        updated.append(contentsOf: newEntries)
                        updated.sort { $0.loggedAt > $1.loggedAt }
                        dfsHistoryData = encodedDFSHistory(Array(updated.prefix(500)))
                    }
                }

                // Cache the loaded standings for fast switching between multi-lineup entries
                standingsCache[tournamentId] = StandingsCache(
                    results: pastTournamentResultRecords,
                    leaderboard: pastTournamentLeaderboard,
                    fieldEntries: pastTournamentFieldEntries,
                    slateSalaries: pastTournamentSlateSalaries,
                    userResultIDs: userResultIDs,
                    timestamp: Date()
                )
                return
            }

            // Fallback: try dfs_entries table (old path — no lineup details available)
            pastTournamentResultRecords = []
            let entries = try await SupabaseService.shared.fetchEntries(tournamentID: tournamentId, accessToken: token)
            guard !entries.isEmpty else {
                pastTournamentLeaderboard = []
                pastTournamentFieldEntries = []
                return
            }

            let uniqueUserIDs = Array(Set(entries.map { $0.userID }))
            let profiles = try await SupabaseService.shared.fetchProfiles(userIDs: uniqueUserIDs, accessToken: token)
            let profileNames = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.username) })

            let scored: [(DFSEntryRecord, String, Double)] = entries.map { entry in
                let name = entry.displayName ?? profileNames[entry.userID] ?? "User \(entry.userID.prefix(6))"
                let points = entry.lineupTotalPoints ?? 0
                return (entry, name, points)
            }
            let sorted = scored.sorted { $0.2 > $1.2 }

            pastTournamentFieldEntries = sorted.map { entry, name, _ in
                DFSFieldEntry(
                    id: UUID(uuidString: entry.id) ?? UUID(),
                    name: name,
                    playerIDs: entry.lineupPlayerIDs,
                    isCurrentUser: entry.userID == userID
                )
            }

            pastTournamentLeaderboard = sorted.enumerated().map { offset, tuple in
                let (entry, name, points) = tuple
                return DFSLeaderboardEntry(
                    id: UUID(uuidString: entry.id) ?? UUID(),
                    name: name,
                    rank: offset + 1,
                    points: points,
                    isCurrentUser: entry.userID == userID
                )
            }
        } catch {
            pastTournamentLeaderboard = []
            pastTournamentFieldEntries = []
            pastTournamentResultRecords = []
        }
    }

    /// Called on app launch: checks if any tournaments the user entered have finished
    /// but weren't settled (e.g. user closed the app during games, or the day rolled over).
    /// Also settles the current tournament if all its games are final (e.g. user opens app
    /// after the day's games finished). Settlement via this path produces better data
    /// (real ESPN player names) than the refreshLive() fallback.
    func checkAndSettleUnsettledTournaments() async {
        guard let token = accessToken, let userID else { return }

        do {
            let recentEntries = try await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)
            let existingTournamentIDs = Set(dfsHistory.compactMap { $0.tournamentId })
            let locallySettled = settledTournaments

            // Group recent entries by tournament to detect multi-lineup tournaments
            // that were settled with the old single-entry code
            let entriesByTournament = Dictionary(grouping: recentEntries, by: \.tournamentID)

            for entry in recentEntries {
                let tid = entry.tournamentID
                var shouldForceRegenerateBots = false

                // For already-settled tournaments, check if multi-lineup entries are missing
                // or if server data has bad bot scores (all zeros)
                if existingTournamentIDs.contains(tid) || locallySettled.contains(tid) {
                    let userEntriesForTournament = entriesByTournament[tid] ?? []
                    let localResultCount = dfsHistory.filter { $0.tournamentId == tid }.count
                    let needsMultiLineupFix = userEntriesForTournament.count > localResultCount

                    // Also check if server data has all-zero bots (bad settlement).
                    // Only check tournaments that are actually settled on the server —
                    // in-progress tournaments may have bots at 0 during live play, which is normal.
                    var needsBotFix = false
                    var needsFullResettle = false
                    if !needsMultiLineupFix {
                        let serverTournamentCheck = try? await SupabaseService.shared.fetchTournament(
                            tournamentID: tid, accessToken: token
                        )
                        let isServerSettled = serverTournamentCheck?.isSettled == true
                        if isServerSettled {
                            let serverResults = (try? await SupabaseService.shared.fetchTournamentResults(
                                tournamentID: tid, accessToken: token
                            )) ?? []
                            if !serverResults.isEmpty {
                                let botResults = serverResults.filter { $0.isBot }
                                let userServerResults = serverResults.filter { $0.userID == userID }
                                let userHasPts = userServerResults.contains { $0.totalPoints > 0 }
                                let allBotsZero = !botResults.isEmpty && botResults.allSatisfy { $0.totalPoints == 0 }
                                let allResultsZero = serverResults.allSatisfy { $0.totalPoints == 0 }
                                // Detect partial-zero: some user entries scored, others at 0.0
                                // (old single-entry settlement only scored one lineup)
                                let someUserZero = userServerResults.count > 1
                                    && userServerResults.contains { $0.totalPoints > 0 }
                                    && userServerResults.contains { $0.totalPoints == 0 }
                                if allResultsZero || someUserZero {
                                    // Bad or partial settlement — clear and re-settle from scratch.
                                    let reason = allResultsZero ? "ALL entries at 0.0 pts" : "\(userServerResults.filter { $0.totalPoints == 0 }.count) of \(userServerResults.count) user entries at 0.0 pts"
                                    print("[DFS] Settled tournament \(tid) has \(reason) — clearing and re-settling")
                                    var updated = dfsHistory
                                    let oldRR = updated.filter { $0.tournamentId == tid }.reduce(0) { $0 + $1.rrDelta }
                                    updated.removeAll { $0.tournamentId == tid }
                                    dfsHistoryData = encodedDFSHistory(updated)
                                    rrScore -= oldRR
                                    var settled = settledTournaments
                                    settled.remove(tid)
                                    settledTournamentData = (try? JSONEncoder().encode(settled)) ?? Data()
                                    // Delete bad server results so re-settlement starts fresh
                                    try? await SupabaseService.shared.deleteTournamentResults(tournamentID: tid, accessToken: token)
                                    needsFullResettle = true
                                } else if allBotsZero && userHasPts {
                                    needsBotFix = true
                                    print("[DFS] Settled tournament \(tid) has all-zero bots — forcing re-settlement")
                                }
                            }
                        }
                    }

                    if needsFullResettle {
                        // Fall through to the re-settlement section below
                    } else if needsMultiLineupFix {
                        // Multi-lineup fix: remove old single result so re-settlement can create per-lineup results
                        var updated = dfsHistory
                        updated.removeAll { $0.tournamentId == tid }
                        dfsHistoryData = encodedDFSHistory(updated)
                        // Remove from settled set so settlement runs again
                        var settled = settledTournaments
                        settled.remove(tid)
                        settledTournamentData = (try? JSONEncoder().encode(settled)) ?? Data()
                    } else if needsBotFix {
                        // Bot fix: DON'T remove history entries — user's rank/points are correct.
                        // Just remove from settled set so re-settlement can fix server-side bot data.
                        var settled = settledTournaments
                        settled.remove(tid)
                        settledTournamentData = (try? JSONEncoder().encode(settled)) ?? Data()
                        shouldForceRegenerateBots = true
                    } else {
                        // Recompute correct pooled rrDelta from full tournament results.
                        // The server may also have stale non-pooled values, so we can't
                        // just compare local vs server — we must recompute from scratch.
                        if let serverResults = try? await SupabaseService.shared.fetchTournamentResults(
                            tournamentID: tid, accessToken: token
                        ), !serverResults.isEmpty {
                            let sorted = serverResults.sorted { $0.totalPoints > $1.totalPoints }
                            // Build tie-aware ranks
                            var ranks = [Int](repeating: 1, count: sorted.count)
                            for i in 1..<sorted.count {
                                if abs(sorted[i].totalPoints - sorted[i - 1].totalPoints) < 0.001 {
                                    ranks[i] = ranks[i - 1]
                                } else {
                                    ranks[i] = i + 1
                                }
                            }
                            // Compute correct pooled RR for each user entry
                            let entryCount = Self.entryCountFromTournamentID(tid)
                            var correctRRByPoints: [Double: Int] = [:]
                            for (offset, r) in sorted.enumerated() where r.userID == userID {
                                let rank = ranks[offset]
                                let tieCount = ranks.filter { $0 == rank }.count
                                let pooledRR = DFSEngine.pooledRRDelta(tiedRank: rank, tieCount: tieCount, entryCount: entryCount)
                                correctRRByPoints[r.totalPoints] = pooledRR
                            }

                            var updated = dfsHistory
                            var didFixRR = false
                            for (idx, local) in updated.enumerated() {
                                guard local.tournamentId == tid else { continue }
                                let correctRR = correctRRByPoints[local.lineupPoints]
                                    ?? correctRRByPoints.values.first  // single-entry fallback
                                    ?? local.rrDelta
                                if local.rrDelta != correctRR {
                                    updated[idx] = DFSResult(
                                        id: local.id, tournamentTitle: local.tournamentTitle,
                                        rank: local.rank,
                                        totalEntries: local.totalEntries,
                                        lineupPoints: local.lineupPoints,
                                        rrDelta: correctRR,
                                        loggedAt: local.loggedAt,
                                        tournamentId: local.tournamentId,
                                        lineupNumber: local.lineupNumber
                                    )
                                    didFixRR = true
                                    print("[DFS] Startup: correcting rrDelta for \(tid) entry \(idx): \(local.rrDelta) → \(correctRR)")
                                }
                            }
                            if didFixRR {
                                let oldTotal = dfsHistory.filter { $0.tournamentId == tid }.reduce(0) { $0 + $1.rrDelta }
                                let newTotal = updated.filter { $0.tournamentId == tid }.reduce(0) { $0 + $1.rrDelta }
                                dfsHistoryData = encodedDFSHistory(updated)
                                rrScore += (newTotal - oldTotal)
                                print("[DFS] Startup: fixed rrDelta for \(tid): \(oldTotal) → \(newTotal)")

                                // Also fix server records so they have correct pooled values
                                let serverUserResults = serverResults.filter { $0.userID == userID }
                                var serverFixedResults: [DFSTournamentResultRecord] = []
                                for r in serverUserResults {
                                    let correctRR = correctRRByPoints[r.totalPoints] ?? r.rrDelta
                                    if r.rrDelta != correctRR {
                                        serverFixedResults.append(DFSTournamentResultRecord(
                                            id: r.id, tournamentID: r.tournamentID, userID: r.userID,
                                            entryName: r.entryName, lineupPlayerIDs: r.lineupPlayerIDs,
                                            lineupPlayerNames: r.lineupPlayerNames, totalPoints: r.totalPoints,
                                            playerPoints: r.playerPoints, playerSalaries: r.playerSalaries,
                                            rank: r.rank, rrDelta: correctRR,
                                            isCurrentUser: r.isCurrentUser, isBot: r.isBot
                                        ))
                                    }
                                }
                                if !serverFixedResults.isEmpty {
                                    try? await SupabaseService.shared.upsertTournamentResults(
                                        tournamentID: tid,
                                        results: serverFixedResults,
                                        accessToken: token
                                    )
                                    print("[DFS] Startup: pushed corrected rrDelta to server for \(tid)")
                                }
                            }
                        }
                        continue
                    }
                }

                // Check if this tournament is settled on the server with good data
                let serverTournament = try? await SupabaseService.shared.fetchTournament(
                    tournamentID: tid, accessToken: token
                )
                // Skip tournaments that haven't started yet or not found on server
                guard let lockTime = serverTournament?.lockTime, lockTime < Date() else { continue }
                // PGA tournaments take 4 days (Thu–Sun) — never settle early
                let daysSinceLock = Date().timeIntervalSince(lockTime) / (24 * 3600)
                if tid.hasPrefix("pga-") && daysSinceLock < 3.5 { continue }
                if serverTournament?.isSettled == true {
                    // Verify the server has good result data:
                    // - Reasonable count (~500 entries, not duplicated)
                    // - User's entry has real player names (not raw sport-prefixed IDs like "nba-", "ncaam-", etc.)
                    let serverResults = (try? await SupabaseService.shared.fetchTournamentResults(
                        tournamentID: tid, accessToken: token
                    )) ?? []
                    let userResultOnServer = serverResults.first(where: { $0.userID == userID })
                    let rawIDPrefixes = ["nba-", "ncaam-", "mlb-", "nhl-", "pga-"]
                    let userNamesGood = userResultOnServer.map { r in
                        !r.lineupPlayerNames.isEmpty && !r.lineupPlayerNames.contains(where: { name in
                            rawIDPrefixes.contains(where: { name.hasPrefix($0) })
                        })
                    } ?? false
                    let expectedCount = Self.entryCountFromTournamentID(tid)
                    let countOK = serverResults.count >= min(50, expectedCount) && serverResults.count <= max(600, expectedCount + 100)
                    let hasRealScores = serverResults.contains(where: { $0.totalPoints > 0 })
                    // Check that bots actually have non-zero scores (catches old bad settlements)
                    let botResults = serverResults.filter { $0.isBot }
                    let botsHaveScores = botResults.isEmpty || botResults.contains(where: { $0.totalPoints > 0 })
                    // Check all user entries are scored (catches partial multi-lineup settlement)
                    let userResults2 = serverResults.filter { $0.userID == userID }
                    let allUserScored = userResults2.count <= 1
                        || !userResults2.contains(where: { $0.totalPoints == 0 })
                        || userResults2.allSatisfy { $0.totalPoints == 0 }  // all-zero handled separately

                    if countOK && userNamesGood && hasRealScores && botsHaveScores && allUserScored {
                        // Server has good data from a proper settlement — use it
                        markTournamentSettled(tid)
                        await addServerResultToHistoryIfMissing(tournamentID: tid, token: token, userID: userID)
                    } else {
                        // Server was settled with bad/incomplete/duplicated data — re-settle properly
                        if tid.hasPrefix("pga-") {
                            await settleUnsettledPastGolfTournament(
                                tournamentID: tid, userEntry: entry, token: token, userID: userID
                            )
                        } else {
                            await settleUnsettledPastTournament(
                                tournamentID: tid, userEntry: entry, token: token, userID: userID,
                                forceRegenerateBots: shouldForceRegenerateBots
                            )
                        }
                    }
                } else {
                    // Tournament isn't settled on the server at all — settle now
                    if tid.hasPrefix("pga-") {
                        await settleUnsettledPastGolfTournament(
                            tournamentID: tid, userEntry: entry, token: token, userID: userID
                        )
                    } else {
                        await settleUnsettledPastTournament(
                            tournamentID: tid, userEntry: entry, token: token, userID: userID,
                            forceRegenerateBots: shouldForceRegenerateBots
                        )
                    }
                }
            }
        } catch {
            print("[DFS] Failed to check past tournaments: \(error.localizedDescription)")
        }
    }

    /// Settles a past tournament that was never settled on the server.
    /// Reconstructs the field from the user's entry, fetches final scores from ESPN,
    /// builds a full simulated field with real player lineups, and persists everything to server.
    /// Returns the generated result records on success so callers can use them directly
    /// without needing to re-fetch from the server (which may still have stale data if DELETE failed).
    @discardableResult
    private func settleUnsettledPastTournament(
        tournamentID: String,
        userEntry: DFSEntryRecord,
        token: String,
        userID: String,
        forceRegenerateBots: Bool = false
    ) async -> [DFSTournamentResultRecord]? {
        // Prevent concurrent settlements of the same tournament
        guard !settlingInProgress.contains(tournamentID) else { return nil }
        settlingInProgress.insert(tournamentID)
        defer { settlingInProgress.remove(tournamentID) }

        // Tournament ID is "{sport}-YYYYMMDD-..." — extract the sport prefix and 8-char date.
        let sportPrefix = tournamentID.components(separatedBy: "-").first ?? "nba"
        let afterPrefix = tournamentID.dropFirst(sportPrefix.count + 1)
        let dateString = String(afterPrefix.prefix(8))
        guard dateString.count == 8 else { return nil }

        // Map sport prefix to ESPN API sport path
        let espnSport: String
        switch sportPrefix {
        case "ncaam": espnSport = "basketball/mens-college-basketball"
        case "mlb": espnSport = "baseball/mlb"
        case "nhl": espnSport = "hockey/nhl"
        case "epl": espnSport = "soccer/eng.1"
        case "ucl": espnSport = "soccer/uefa.champions"
        case "ufc": espnSport = "mma/ufc"
        case "nfl": espnSport = "football/nfl"
        case "cfb": espnSport = "football/college-football"
        default: espnSport = "basketball/nba"
        }

        // Fetch that day's slate games
        let allPastSlateGames = await fetchSlateGamesForDate(dateString, espnSport: espnSport)
        guard !allPastSlateGames.isEmpty else { return nil }

        // For single-game tournaments, only check the specific game — not all games on the slate.
        // Tournament ID format: "{sport}-{date}-sg-{gameID}-{size}"
        let isSingleGameTournament = tournamentID.contains("-sg-")
        let singleGameID: String? = {
            guard isSingleGameTournament else { return nil }
            // Extract game ID: everything between "-sg-" and the last "-{size}"
            guard let sgRange = tournamentID.range(of: "-sg-") else { return nil }
            let afterSG = String(tournamentID[sgRange.upperBound...])
            // Strip instance suffix first (e.g., "-i2")
            var cleaned = afterSG
            if let iRange = cleaned.range(of: #"-i\d+$"#, options: .regularExpression) {
                cleaned.removeSubrange(iRange)
            }
            // Remove trailing "-{size}" (e.g., "-2000", "-3")
            if let lastDash = cleaned.lastIndex(of: "-") {
                return String(cleaned[cleaned.startIndex..<lastDash])
            }
            return cleaned
        }()

        let pastSlateGames: [DFSSlateGame]
        if let sgID = singleGameID, let game = allPastSlateGames.first(where: { $0.id == sgID }) {
            pastSlateGames = [game]
        } else {
            pastSlateGames = allPastSlateGames
        }

        // Check relevant games are final
        let allFinal = pastSlateGames.allSatisfy { $0.state == "post" }
        guard allFinal else { return nil }

        // Use the correct sport-specific scoring provider for this tournament.
        // This function may be called from ANY sport's ViewModel (since
        // checkAndSettleUnsettledTournaments processes all recent entries),
        // so we must NOT use self.scoringProvider which belongs to the calling ViewModel.
        let settlementScoringProvider: DFSLiveScoringProvider
        switch sportPrefix {
        case "nba": settlementScoringProvider = ESPNDFSLiveScoringProvider()
        case "mlb": settlementScoringProvider = ESPNMLBDFSLiveScoringProvider()
        case "nhl": settlementScoringProvider = ESPNNHLDFSLiveScoringProvider()
        case "ncaam": settlementScoringProvider = ESPNNCAAMDFSLiveScoringProvider()
        case "epl": settlementScoringProvider = ESPNSoccerDFSLiveScoringProvider(league: .epl)
        case "ucl": settlementScoringProvider = ESPNSoccerDFSLiveScoringProvider(league: .ucl)
        case "nfl": settlementScoringProvider = ESPNNFLDFSLiveScoringProvider()
        case "cfb": settlementScoringProvider = ESPNNCAAFBDFSLiveScoringProvider()
        default: settlementScoringProvider = scoringProvider
        }

        // Fetch final scores (use all games to get comprehensive player stats)
        guard let snapshot = try? await settlementScoringProvider.fetchScoreSnapshot(for: pastSlateGames) else { return nil }

        // Build a map of all players with their names, scores, and positions
        struct PlayerInfo {
            let id: String
            let name: String
            let points: Double
            let position: String
        }
        let allPlayers: [PlayerInfo] = snapshot.playerFantasyPoints.compactMap { (pid, pts) in
            let name = snapshot.playerLiveStats[pid]?.name ?? pid
            // Derive position from live stats
            let pos: String
            if sportPrefix == "nhl" {
                pos = snapshot.playerLiveStats[pid]?.minutes == "G" ? "G" : "C"
            } else if sportPrefix == "mlb" {
                let mins = snapshot.playerLiveStats[pid]?.minutes ?? ""
                // Pitchers have numeric IP value (e.g. "6.0", "7.1"), batters have "X AB" format
                if mins.isEmpty {
                    pos = "UTIL"
                } else if mins.contains("AB") {
                    pos = "UTIL"  // Batter
                } else {
                    pos = "SP"    // Pitcher (minutes field is IP like "6.0")
                }
            } else if sportPrefix == "epl" || sportPrefix == "ucl" {
                // Soccer: position encoded as "GK:90'" or "DEF:85'" in minutes field
                let mins = snapshot.playerLiveStats[pid]?.minutes ?? ""
                if let colonIdx = mins.firstIndex(of: ":") {
                    pos = String(mins[mins.startIndex..<colonIdx])
                } else {
                    pos = "MID"
                }
            } else {
                pos = "UTIL"
            }
            return PlayerInfo(id: pid, name: name, points: pts, position: pos)
        }
        guard !allPlayers.isEmpty else { return nil }

        // Build a lookup of player ID → name from all available sources
        var playerNameLookup: [String: String] = [:]
        for player in allPlayers {
            playerNameLookup[player.id] = player.name
        }

        // Fetch ALL of the current user's entries for this tournament (for multi-lineup support)
        let allUserEntries: [DFSEntryRecord]
        if let fetched = try? await SupabaseService.shared.fetchEntries(
            tournamentID: tournamentID, accessToken: token
        ) {
            let mine = fetched.filter { $0.userID == userID }
            allUserEntries = mine.isEmpty ? [userEntry] : mine
        } else {
            allUserEntries = [userEntry]
        }

        // For any user lineup players not in the box scores (DNP, injured, etc.),
        // try to resolve their names from the ESPN athlete endpoint
        let allUserPlayerIDs = Set(allUserEntries.flatMap(\.lineupPlayerIDs))
        let unresolvedIDs = allUserPlayerIDs.filter { playerNameLookup[$0] == nil }
        if !unresolvedIDs.isEmpty {
            let capturedPrefix = sportPrefix
            let capturedESPNSport = espnSport
            let isSoccerSport = sportPrefix == "epl" || sportPrefix == "ucl"
            await withTaskGroup(of: (String, String?).self) { group in
                for pid in unresolvedIDs {
                    group.addTask {
                        let athleteID = pid.replacingOccurrences(of: "\(capturedPrefix)-", with: "")
                        // Soccer uses v3 endpoint (v2 athlete endpoint returns 404 for soccer)
                        let urlString: String
                        if isSoccerSport {
                            urlString = "https://site.web.api.espn.com/apis/common/v3/sports/soccer/\(capturedESPNSport.replacingOccurrences(of: "soccer/", with: ""))/athletes/\(athleteID)"
                        } else {
                            urlString = "https://site.api.espn.com/apis/site/v2/sports/\(capturedESPNSport)/athletes/\(athleteID)"
                        }
                        guard let url = URL(string: urlString) else {
                            return (pid, nil)
                        }
                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            return (pid, nil)
                        }
                        // v3 nests under "athlete", v2 is top-level
                        let name: String?
                        if isSoccerSport {
                            name = (json["athlete"] as? [String: Any])?["displayName"] as? String
                        } else {
                            name = json["displayName"] as? String
                        }
                        return (pid, name)
                    }
                }
                for await (pid, name) in group {
                    if let name { playerNameLookup[pid] = name }
                }
            }
        }

        // Detect single-game mode from the first user entry's lineup size
        let userPlayerIDs = userEntry.lineupPlayerIDs
        let lineupSize = userPlayerIDs.count
        // Detect single-game mode: classic NBA=7, classic NHL=9, classic MLB=9, single-game=6
        let isSingleGame = lineupSize == 6 && (sportPrefix == "nba" || sportPrefix == "nhl" || sportPrefix == "mlb")

        // Compute per-entry user stats for the primary entry (used for backward compat)
        var userPerPlayerPoints: [String: Double] = [:]
        var userPoints = 0.0
        for (index, pid) in userPlayerIDs.enumerated() {
            let pts = snapshot.playerFantasyPoints[pid] ?? 0
            let multiplied = (isSingleGame && index == 0) ? pts * 1.5 : pts
            userPerPlayerPoints[pid] = multiplied
            userPoints += multiplied
        }
        let userPlayerNames: [String] = userPlayerIDs.map { pid in
            playerNameLookup[pid] ?? pid
        }

        // Generate simulated field with salary-constrained bot lineups
        let entryCount = Self.entryCountFromTournamentID(tournamentID)
        let userName = profileName.isEmpty ? "You" : profileName
        let botNames = [
            "AceLock", "CourtVision", "ClutchFan", "HalfCourtHero", "StatSavage",
            "UnderdogKing", "BoxScoreBoss", "PrimePicks", "FastBreak", "ZoneDefense",
            "SplashZone", "LineupLab", "FourthQuarter", "RimRunner", "PaintPoints",
            "BenchMob", "DunkCity", "TripleDouble", "FloorGeneral", "SixthMan",
            "Swish99", "LockerRoom", "PlayoffMode", "BuzzerBeater", "PickNRoll"
        ]

        struct SimEntry {
            let name: String
            let playerIDs: [String]
            let playerNames: [String]
            let playerPoints: [String: Double]
            let playerSalaries: [String: Int]
            let totalPoints: Double
            let isCurrentUser: Bool
            var realUserID: String? = nil
            var lineupNumber: Int? = nil
            var isBot: Bool { !isCurrentUser && realUserID == nil }
        }

        // Build DFSPlayer objects from scoring snapshot for salary-constrained bot lineup generation
        // All sports use $50K salary cap (DraftKings standard)
        let salaryCap: Int = tournament?.salaryCap ?? 50000
        let botLineupSize: Int
        if isSingleGame {
            botLineupSize = 6
        } else {
            switch sportPrefix {
            case "mlb": botLineupSize = 10
            case "ncaam": botLineupSize = 6
            case "nhl": botLineupSize = 9
            case "epl", "ucl": botLineupSize = 8
            case "nfl": botLineupSize = 9
            case "cfb": botLineupSize = 8
            default: botLineupSize = 8  // NBA
            }
        }

        // Fetch tournament record early — it may contain the original slate salaries
        let serverTournament = try? await SupabaseService.shared.fetchTournament(tournamentID: tournamentID, accessToken: token)
        let tournamentSalaries = serverTournament?.playerSalaries ?? [:]
        let userStoredSalaries = userEntry.lineupPlayerSalaries ?? [:]

        // Resolve names for saved bot lineups — their player IDs may not be
        // in the scoring snapshot (e.g., backup goalies who didn't play).
        if let savedBots = serverTournament?.botField {
            let unresolvedBotIDs = Set(savedBots.flatMap(\.playerIDs)).filter { playerNameLookup[$0] == nil }
            if !unresolvedBotIDs.isEmpty {
                let capturedPrefix2 = sportPrefix
                let capturedESPNSport2 = espnSport
                let isSoccerSport2 = sportPrefix == "epl" || sportPrefix == "ucl"
                await withTaskGroup(of: (String, String?).self) { group in
                    for pid in unresolvedBotIDs {
                        group.addTask {
                            let athleteID = pid.replacingOccurrences(of: "\(capturedPrefix2)-", with: "")
                            // Soccer uses v3 endpoint (v2 returns 404 for soccer)
                            let urlString: String
                            if isSoccerSport2 {
                                urlString = "https://site.web.api.espn.com/apis/common/v3/sports/soccer/\(capturedESPNSport2.replacingOccurrences(of: "soccer/", with: ""))/athletes/\(athleteID)"
                            } else {
                                urlString = "https://site.api.espn.com/apis/site/v2/sports/\(capturedESPNSport2)/athletes/\(athleteID)"
                            }
                            guard let url = URL(string: urlString) else {
                                return (pid, nil)
                            }
                            guard let (data, response) = try? await URLSession.shared.data(from: url),
                                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                return (pid, nil)
                            }
                            // v3 nests under "athlete", v2 is top-level
                            let name: String?
                            if isSoccerSport2 {
                                name = (json["athlete"] as? [String: Any])?["displayName"] as? String
                            } else {
                                name = json["displayName"] as? String
                            }
                            return (pid, name)
                        }
                    }
                    for await (pid, name) in group {
                        if let name { playerNameLookup[pid] = name }
                    }
                }
            }
        }

        // Build salary lookup: tournament salaries (original slate) > user stored > estimate
        // Seed with ALL tournament slate salaries first so DNP players also have prices.
        var salaryByID: [String: Int] = tournamentSalaries
        let sortedByFPTS = allPlayers.sorted { $0.points > $1.points }
        for (index, player) in sortedByFPTS.enumerated() {
            if let tSal = tournamentSalaries[player.id], tSal > 0 {
                salaryByID[player.id] = tSal
                continue
            }
            if let uSal = userStoredSalaries[player.id], uSal > 0 {
                salaryByID[player.id] = uSal
                continue
            }
            let order = index + 1
            let estimated: Int
            if sportPrefix == "nhl" {
                // NHL: $55K cap, 9 players → avg ~$6,100 per slot
                // FanDuel NHL salaries typically range $3,500-$9,500 with avg ~$6,100.
                switch order {
                case 1...5: estimated = Int.random(in: 8500...9500)
                case 6...15: estimated = Int.random(in: 7000...8500)
                case 16...30: estimated = Int.random(in: 5500...7000)
                case 31...50: estimated = Int.random(in: 4500...6000)
                case 51...80: estimated = Int.random(in: 4000...5000)
                default: estimated = Int.random(in: 3500...4500)
                }
            } else if sportPrefix == "mlb" {
                // MLB: $35K cap, 9 players → avg ~$3,900 per slot
                // FanDuel MLB: ace pitchers $9K-$11K, good SP $7K-$9K,
                // top batters $4K-$4.5K, avg batters $2.5K-$3.5K, min $2K
                let isPitcher = player.position == "SP" || player.position == "RP" || player.position == "P"
                if isPitcher {
                    switch order {
                    case 1...3: estimated = Int.random(in: 9500...11000)
                    case 4...8: estimated = Int.random(in: 7500...9500)
                    case 9...15: estimated = Int.random(in: 6000...7500)
                    default: estimated = Int.random(in: 5500...6500)
                    }
                } else {
                    switch order {
                    case 1...5: estimated = Int.random(in: 4000...4500)
                    case 6...15: estimated = Int.random(in: 3500...4000)
                    case 16...30: estimated = Int.random(in: 3000...3500)
                    case 31...50: estimated = Int.random(in: 2500...3000)
                    case 51...80: estimated = Int.random(in: 2200...2600)
                    default: estimated = Int.random(in: 2000...2400)
                    }
                }
            } else if sportPrefix == "epl" || sportPrefix == "ucl" {
                // Soccer: $50K cap, 11 players → avg ~$4,500 per slot
                switch order {
                case 1...5: estimated = Int.random(in: 8500...10500)
                case 6...15: estimated = Int.random(in: 6500...8500)
                case 16...30: estimated = Int.random(in: 5000...7000)
                case 31...50: estimated = Int.random(in: 4000...5500)
                case 51...80: estimated = Int.random(in: 3500...4500)
                default: estimated = Int.random(in: 3500...4000)
                }
            } else {
                // NBA / NCAAM
                switch order {
                case 1...5: estimated = Int.random(in: 9500...11500)
                case 6...15: estimated = Int.random(in: 8000...9500)
                case 16...30: estimated = Int.random(in: 6500...8000)
                case 31...50: estimated = Int.random(in: 5000...6500)
                case 51...80: estimated = Int.random(in: 4000...5500)
                default: estimated = Int.random(in: 3000...4500)
                }
            }
            salaryByID[player.id] = (estimated / 100) * 100  // Round to nearest $100 like FanDuel
        }

        var field: [SimEntry] = []

        // Add ALL of the current user's entries to the field (multi-lineup support)
        for (entryIdx, entry) in allUserEntries.enumerated() {
            let pids = entry.lineupPlayerIDs
            let entryStoredSalaries = entry.lineupPlayerSalaries ?? [:]
            let entrySalaries: [String: Int] = Dictionary(uniqueKeysWithValues: pids.enumerated().compactMap { (index, pid) -> (String, Int)? in
                let baseSal: Int?
                if let tSal = tournamentSalaries[pid], tSal > 0 { baseSal = tSal }
                else if let uSal = entryStoredSalaries[pid], uSal > 0 { baseSal = uSal }
                else if let sal = salaryByID[pid], sal > 0 { baseSal = sal }
                else { return nil }
                let sal = baseSal!
                return (pid, (isSingleGame && index == 0) ? Int(Double(sal) * 1.5) : sal)
            })
            var entryPoints = 0.0
            var entryPerPlayerPoints: [String: Double] = [:]
            for (index, pid) in pids.enumerated() {
                let pts = snapshot.playerFantasyPoints[pid] ?? 0
                let multiplied = (isSingleGame && index == 0) ? pts * 1.5 : pts
                entryPerPlayerPoints[pid] = multiplied
                entryPoints += multiplied
            }
            let entryPlayerNames = pids.map { playerNameLookup[$0] ?? $0 }
            let lineupNum = entry.lineupNumber ?? (entryIdx + 1)
            let displayName = allUserEntries.count > 1 ? "\(userName) #\(lineupNum)" : userName
            field.append(SimEntry(
                name: displayName,
                playerIDs: pids,
                playerNames: entryPlayerNames,
                playerPoints: entryPerPlayerPoints,
                playerSalaries: entrySalaries,
                totalPoints: entryPoints,
                isCurrentUser: true,
                realUserID: userID,
                lineupNumber: lineupNum
            ))
        }

        // Minimum salary floor per sport — used when salary lookup fails entirely
        let salaryFloor: Int = (sportPrefix == "nhl") ? 3500 : (sportPrefix == "mlb") ? 2000 : (sportPrefix == "epl" || sportPrefix == "ucl") ? 3500 : 3000

        // Add other real users' entries to the field
        let allEntries = (try? await SupabaseService.shared.fetchEntries(
            tournamentID: tournamentID, accessToken: token
        )) ?? []
        let realUserEntries = allEntries.filter { $0.userID != userID }
        // Fetch profile names for other real users
        let realUserIDs = Array(Set(realUserEntries.map { $0.userID }))
        let realProfiles = (try? await SupabaseService.shared.fetchProfiles(
            userIDs: realUserIDs, accessToken: token
        )) ?? []
        let realProfileNames = Dictionary(uniqueKeysWithValues: realProfiles.map { ($0.id, $0.username) })
        for realEntry in realUserEntries {
            let entryName = realProfileNames[realEntry.userID]
                ?? realEntry.displayName
                ?? "User \(realEntry.userID.prefix(6))"
            let pids = realEntry.lineupPlayerIDs
            // Resolve names for real user lineup players
            let unresolvedRealIDs = pids.filter { playerNameLookup[$0] == nil }
            if !unresolvedRealIDs.isEmpty {
                let capturedPrefix3 = sportPrefix
                let capturedESPNSport3 = espnSport
                let isSoccerSport3 = sportPrefix == "epl" || sportPrefix == "ucl"
                await withTaskGroup(of: (String, String?).self) { group in
                    for pid in unresolvedRealIDs {
                        group.addTask {
                            let athleteID = pid.replacingOccurrences(of: "\(capturedPrefix3)-", with: "")
                            // Soccer uses v3 endpoint (v2 returns 404 for soccer)
                            let urlString: String
                            if isSoccerSport3 {
                                urlString = "https://site.web.api.espn.com/apis/common/v3/sports/soccer/\(capturedESPNSport3.replacingOccurrences(of: "soccer/", with: ""))/athletes/\(athleteID)"
                            } else {
                                urlString = "https://site.api.espn.com/apis/site/v2/sports/\(capturedESPNSport3)/athletes/\(athleteID)"
                            }
                            guard let url = URL(string: urlString) else {
                                return (pid, nil)
                            }
                            guard let (data, response) = try? await URLSession.shared.data(from: url),
                                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                return (pid, nil)
                            }
                            // v3 nests under "athlete", v2 is top-level
                            let name: String?
                            if isSoccerSport3 {
                                name = (json["athlete"] as? [String: Any])?["displayName"] as? String
                            } else {
                                name = json["displayName"] as? String
                            }
                            return (pid, name)
                        }
                    }
                    for await (pid, name) in group {
                        if let name { playerNameLookup[pid] = name }
                    }
                }
            }
            let pnames = pids.map { playerNameLookup[$0] ?? $0 }
            let ppts = Dictionary(uniqueKeysWithValues: pids.enumerated().map { (i, pid) in
                let raw = snapshot.playerFantasyPoints[pid] ?? 0
                return (pid, (isSingleGame && i == 0) ? raw * 1.5 : raw)
            })
            let psals = Dictionary(uniqueKeysWithValues: pids.enumerated().map { (i, pid) in
                let baseSal = salaryByID[pid] ?? salaryFloor
                return (pid, (isSingleGame && i == 0) ? Int(Double(baseSal) * 1.5) : baseSal)
            })
            let total = pids.enumerated().reduce(0.0) { acc, pair in
                let raw = snapshot.playerFantasyPoints[pair.element] ?? 0
                return acc + ((isSingleGame && pair.offset == 0) ? raw * 1.5 : raw)
            }
            field.append(SimEntry(
                name: entryName,
                playerIDs: pids,
                playerNames: pnames,
                playerPoints: ppts,
                playerSalaries: psals,
                totalPoints: total,
                isCurrentUser: false,
                realUserID: realEntry.userID
            ))
        }
        let totalRealEntries = allUserEntries.count + realUserEntries.count

        // Try to use saved bot lineups from the server (drafted at tournament start).
        // This preserves the original pre-game lineups instead of regenerating with hindsight.
        // When forceRegenerateBots is true, skip saved bots — they produced all-zero scores
        // (likely due to player-ID mismatch) and need to be regenerated from the scoring snapshot.
        let savedBotField: [BotFieldEntry]? = forceRegenerateBots ? nil : serverTournament?.botField
        if forceRegenerateBots {
            print("[DFS] Force-regenerating bots for \(tournamentID) — ignoring \(serverTournament?.botField?.count ?? 0) saved bots")
        }
        let baseBotPlayers: [(id: String, name: String, salary: Int, actualPoints: Double, position: String, hasRealSalary: Bool)] = allPlayers.map { p in
            let hasReal = (tournamentSalaries[p.id] ?? 0) > 0 || (userStoredSalaries[p.id] ?? 0) > 0
            let sal = salaryByID[p.id] ?? salaryFloor
            return (id: p.id, name: p.name, salary: sal, actualPoints: p.points, position: p.position, hasRealSalary: hasReal)
        }
        let avgPoints = allPlayers.isEmpty ? 20.0 : allPlayers.reduce(0.0) { $0 + $1.points } / Double(allPlayers.count)

        // Define roster slots for position-constrained sports so bots draft valid lineups
        let botRosterSlots: [String]?
        if isSingleGame {
            // Single-game (DK Showdown): no position requirements, just MVP + FLEX
            botRosterSlots = nil
        } else {
            switch sportPrefix {
            case "nhl": botRosterSlots = ["C", "C", "W", "W", "D", "D", "UTIL", "UTIL", "G"]
            case "mlb": botRosterSlots = ["P", "P", "UTIL", "UTIL", "UTIL", "UTIL", "UTIL", "UTIL", "UTIL", "UTIL"]
            case "epl", "ucl": botRosterSlots = ["GK", "DEF", "DEF", "MID", "MID", "FWD", "FWD", "FLEX"]
            case "nfl": botRosterSlots = ["QB", "RB", "RB", "WR", "WR", "WR", "TE", "FLEX", "DEF"]
            case "cfb": botRosterSlots = ["QB", "RB", "RB", "WR", "WR", "WR", "TE", "FLEX"]
            case "nba": botRosterSlots = nil
            default: botRosterSlots = nil
            }
        }

        // Helper: compute total points for a lineup, applying 1.5x MVP multiplier for single-game
        func lineupTotal(_ playerIDs: [String]) -> Double {
            var total = 0.0
            for (i, pid) in playerIDs.enumerated() {
                let pts = snapshot.playerFantasyPoints[pid] ?? 0
                total += (isSingleGame && i == 0) ? pts * 1.5 : pts
            }
            return total
        }

        if let savedBots = savedBotField, !savedBots.isEmpty {
            // Only use enough saved bots to fill remaining slots (don't exceed entryCount)
            let botsToUse = max(0, entryCount - totalRealEntries)
            let trimmedSavedBots = Array(savedBots.prefix(botsToUse))
            // Use ALL saved bots as-is — these are the lineups that were frozen at lock time.
            // Previously, salary validation here could reject bots whose salaries didn't match
            // the settlement salary lookup (e.g., bots generated with main-slate prices vs
            // showdown prices), causing the settlement to regenerate different lineups than
            // what users saw during live play. Bot lineups must be consistent from start to finish.
            // Only filter out bots with wrong lineup size (actually corrupt data).
            let validSavedBots = trimmedSavedBots.filter { bot in
                bot.playerIDs.count == botLineupSize
            }
            let invalidCount = trimmedSavedBots.count - validSavedBots.count
            if invalidCount > 0 {
                print("[DFS] Settlement: \(invalidCount) saved bots have wrong lineup size (\(botLineupSize) expected) — will regenerate")
            }
            print("[DFS] Using \(validSavedBots.count) of \(savedBots.count) saved bot lineups for \(tournamentID) (entryCount=\(entryCount), realEntries=\(totalRealEntries), wrongSize=\(invalidCount))")
            for bot in validSavedBots {
                let botTotal = lineupTotal(bot.playerIDs)
                let pnames = bot.playerIDs.map { playerNameLookup[$0] ?? $0 }
                let ppts = Dictionary(uniqueKeysWithValues: bot.playerIDs.enumerated().map { (i, pid) in
                    let raw = snapshot.playerFantasyPoints[pid] ?? 0
                    return (pid, (isSingleGame && i == 0) ? raw * 1.5 : raw)
                })
                let psals = Dictionary(uniqueKeysWithValues: bot.playerIDs.enumerated().map { (i, pid) in
                    let sal = salaryByID[pid] ?? 0
                    let baseSal = sal > 0 ? sal : salaryFloor
                    return (pid, (isSingleGame && i == 0) ? Int(Double(baseSal) * 1.5) : baseSal)
                })
                field.append(SimEntry(
                    name: bot.name,
                    playerIDs: bot.playerIDs,
                    playerNames: pnames,
                    playerPoints: ppts,
                    playerSalaries: psals,
                    totalPoints: botTotal,
                    isCurrentUser: false
                ))
            }
            // If saved bots are fewer than expected (incomplete ones excluded), pad with additional generated bots
            let currentBotCount = field.count - totalRealEntries
            let targetBots = entryCount - totalRealEntries
            if currentBotCount < targetBots {
                let botsNeeded = targetBots - currentBotCount
                print("[DFS] Padding saved bot field with \(botsNeeded) additional bots (had \(currentBotCount), need \(targetBots))")
                for i in 0..<botsNeeded {
                    let dfsPlayersForBot: [DFSPlayer] = baseBotPlayers.map { p in
                        // Use salary-based projections to avoid hindsight bias.
                        // Higher-salary players get higher projections, matching pre-game expectations.
                        let salaryRatio = Double(p.salary) / Double(salaryCap) * Double(botLineupSize)
                        let baseProj = salaryRatio * avgPoints * Double.random(in: 0.5...1.5)
                        let noise = Double.random(in: -0.3...0.3) * avgPoints
                        let simulatedProjection = max(baseProj + noise, 1.0)
                        var player = DFSPlayer(
                            id: p.id, name: p.name, team: "", position: p.position,
                            salary: p.salary, projectedPoints: simulatedProjection
                        )
                        player.isConfirmedActive = p.hasRealSalary
                        return player
                    }
                    let botPlayerIDs = generateBotLineup(from: dfsPlayersForBot, salaryCap: salaryCap, lineupSize: botLineupSize, rosterSlots: botRosterSlots, isSingleGame: isSingleGame, sportOverride: sportPrefix.uppercased())
                    let botTotal = lineupTotal(botPlayerIDs)
                    let pnames = botPlayerIDs.map { playerNameLookup[$0] ?? $0 }
                    let ppts = Dictionary(uniqueKeysWithValues: botPlayerIDs.enumerated().map { (i, pid) in
                        let raw = snapshot.playerFantasyPoints[pid] ?? 0
                        return (pid, (isSingleGame && i == 0) ? raw * 1.5 : raw)
                    })
                    // Use the DFSPlayer salary from the bot pool (what generateBotLineup actually used)
                    let botPlayerLookup = Dictionary(uniqueKeysWithValues: dfsPlayersForBot.map { ($0.id, $0.salary) })
                    let psals = Dictionary(uniqueKeysWithValues: botPlayerIDs.enumerated().map { (i, pid) in
                        let baseSal = botPlayerLookup[pid] ?? salaryByID[pid] ?? salaryFloor
                        return (pid, (isSingleGame && i == 0) ? Int(Double(baseSal) * 1.5) : baseSal)
                    })
                    let baseName = botNames[(currentBotCount + i) % botNames.count]
                    let uniqueName = "\(baseName) #\(currentBotCount + i + 1)"
                    field.append(SimEntry(
                        name: uniqueName,
                        playerIDs: botPlayerIDs,
                        playerNames: pnames,
                        playerPoints: ppts,
                        playerSalaries: psals,
                        totalPoints: botTotal,
                        isCurrentUser: false
                    ))
                }
            }
        } else {
            // No saved bots — generate with salary-based projections to avoid hindsight bias.
            // We intentionally do NOT use actualPoints here because those are final game results;
            // using them would let bots "know" who performed well and draft accordingly.
            print("[DFS] No saved bot field for \(tournamentID), generating with salary-based projections (no hindsight)")
            let botsToGenerate = max(0, entryCount - totalRealEntries)
            for i in 0..<botsToGenerate {
                let dfsPlayersForBot: [DFSPlayer] = baseBotPlayers.map { p in
                    let salaryRatio = Double(p.salary) / Double(salaryCap) * Double(botLineupSize)
                    let baseProj = salaryRatio * avgPoints * Double.random(in: 0.5...1.5)
                    let noise = Double.random(in: -0.3...0.3) * avgPoints
                    let simulatedProjection = max(baseProj + noise, 1.0)
                    var player = DFSPlayer(
                        id: p.id, name: p.name, team: "", position: p.position,
                        salary: p.salary, projectedPoints: simulatedProjection
                    )
                    player.isConfirmedActive = p.hasRealSalary
                    return player
                }
                let botPlayerIDs = generateBotLineup(from: dfsPlayersForBot, salaryCap: salaryCap, lineupSize: botLineupSize, rosterSlots: botRosterSlots, isSingleGame: isSingleGame, sportOverride: sportPrefix.uppercased())
                let botTotal = lineupTotal(botPlayerIDs)
                let pnames = botPlayerIDs.map { playerNameLookup[$0] ?? $0 }
                let ppts = Dictionary(uniqueKeysWithValues: botPlayerIDs.enumerated().map { (idx, pid) in
                    let raw = snapshot.playerFantasyPoints[pid] ?? 0
                    return (pid, (isSingleGame && idx == 0) ? raw * 1.5 : raw)
                })
                // Use the DFSPlayer salary from the bot pool (what generateBotLineup actually used)
                let botPlayerLookup = Dictionary(uniqueKeysWithValues: dfsPlayersForBot.map { ($0.id, $0.salary) })
                let psals = Dictionary(uniqueKeysWithValues: botPlayerIDs.enumerated().map { (idx, pid) in
                    let baseSal = botPlayerLookup[pid] ?? salaryByID[pid] ?? salaryFloor
                    return (pid, (isSingleGame && idx == 0) ? Int(Double(baseSal) * 1.5) : baseSal)
                })
                let baseName = botNames[i % botNames.count]
                let uniqueName = "\(baseName) #\(i + 1)"

                field.append(SimEntry(
                    name: uniqueName,
                    playerIDs: botPlayerIDs,
                    playerNames: pnames,
                    playerPoints: ppts,
                    playerSalaries: psals,
                    totalPoints: botTotal,
                    isCurrentUser: false
                ))
            }
        }

        // Validate generated field — detect broken settlement early
        let botField = field.filter { !$0.isCurrentUser && $0.realUserID == nil }
        let emptyBotCount = botField.filter { $0.playerIDs.isEmpty }.count
        let zeroBotCount = botField.filter { $0.totalPoints == 0 && !$0.playerIDs.isEmpty }.count
        if !botField.isEmpty {
            print("[DFS] Settlement field: \(field.count) entries, \(botField.count) bots, \(emptyBotCount) empty, \(zeroBotCount) zero-points")
            if emptyBotCount > botField.count / 2 {
                print("[DFS] WARNING: More than half of bots have empty lineups for \(tournamentID) — settlement may produce bad data")
            }
        }

        // Abort settlement if ALL bots scored zero but user has real points.
        // This means bot player IDs don't match the scoring snapshot — persisting
        // would write bad leaderboard data. The next settlement attempt should fix it.
        let allBotsZeroInSettlement = !botField.isEmpty && botField.allSatisfy { $0.totalPoints == 0 }
        if allBotsZeroInSettlement && userPoints > 0 {
            print("[DFS] Aborting settlement for \(tournamentID) — all \(botField.count) bots scored 0 but user scored \(userPoints). Player IDs may not match scoring snapshot.")
            // Log sample bot vs snapshot for debugging
            if let sampleBot = botField.first, !sampleBot.playerIDs.isEmpty {
                let sampleIDs = sampleBot.playerIDs.prefix(3)
                let snapshotSample = snapshot.playerFantasyPoints.keys.prefix(3)
                print("[DFS] Sample bot IDs: \(Array(sampleIDs)), sample snapshot keys: \(Array(snapshotSample))")
            }
            return nil
        }

        // Sort by points descending and assign tie-aware ranks
        field.sort { $0.totalPoints > $1.totalPoints }

        // Precompute tie-aware ranks: entries with the same points share the same rank.
        // Next rank after a tie group skips ahead (e.g., 1,1,1,4,5).
        var fieldRanks = [Int](repeating: 1, count: field.count)
        // Also precompute tie group sizes for pooled RR
        var fieldTieCounts = [Int](repeating: 1, count: field.count)
        if !field.isEmpty {
            // First pass: assign ranks
            for i in 1..<field.count {
                if abs(field[i].totalPoints - field[i - 1].totalPoints) < 0.001 {
                    fieldRanks[i] = fieldRanks[i - 1]
                } else {
                    fieldRanks[i] = i + 1
                }
            }
            // Second pass: compute tie group sizes
            var i = 0
            while i < field.count {
                let rank = fieldRanks[i]
                var j = i
                while j < field.count && fieldRanks[j] == rank { j += 1 }
                let groupSize = j - i
                for k in i..<j { fieldTieCounts[k] = groupSize }
                i = j
            }
        }

        let title = serverTournament?.title ?? "Free Tournament of the Day"

        // Create dfsHistory entries for user lineups that aren't recorded yet.
        // For multi-lineup tournaments, live settlement may have only recorded ONE lineup
        // (the active one), so we need to create entries for the remaining lineups.
        let existingHistoryForTournament = dfsHistory.filter { $0.tournamentId == tournamentID }
        let existingLineupNumbers = Set(existingHistoryForTournament.compactMap { $0.lineupNumber })
        let fullyRecorded = settledTournaments.contains(tournamentID)
            && existingHistoryForTournament.count >= allUserEntries.count

        let userFieldEntries = field.enumerated().filter { $0.element.isCurrentUser }
        if !fullyRecorded {
            var totalRRDelta = 0
            var newResults: [DFSResult] = []
            for (offset, userFieldEntry) in userFieldEntries {
                let entryRank = fieldRanks[offset]
                let tieCount = fieldTieCounts[offset]
                let lineupNum = userFieldEntry.lineupNumber
                // Skip if this lineup is already in history
                if let ln = lineupNum, existingLineupNumbers.contains(ln) { continue }
                // Also skip if there's a single existing entry with nil lineupNumber (non-multi case)
                if lineupNum == nil && !existingHistoryForTournament.isEmpty { continue }
                let entryRRDelta = DFSEngine.pooledRRDelta(tiedRank: entryRank, tieCount: tieCount, entryCount: entryCount)
                totalRRDelta += entryRRDelta
                newResults.append(DFSResult(
                    id: UUID(),
                    tournamentTitle: title,
                    rank: entryRank,
                    totalEntries: entryCount,
                    lineupPoints: userFieldEntry.totalPoints,
                    rrDelta: entryRRDelta,
                    loggedAt: serverTournament?.lockTime ?? Date(),
                    tournamentId: tournamentID,
                    lineupNumber: lineupNum
                ))
            }
            if !newResults.isEmpty {
                rrScore += totalRRDelta
                var updatedHistory = dfsHistory
                updatedHistory.append(contentsOf: newResults)
                updatedHistory.sort { $0.loggedAt > $1.loggedAt }
                dfsHistoryData = encodedDFSHistory(Array(updatedHistory.prefix(500)))
            }
        }
        // Build result records for ALL entries and persist to server
        // Deduplicate entry names to avoid upsert conflict on (tournament_id, entry_name)
        var settlementNameCounter: [String: Int] = [:]
        let resultRecords: [DFSTournamentResultRecord] = field.enumerated().map { offset, entry in
            let count = settlementNameCounter[entry.name, default: 0]
            settlementNameCounter[entry.name] = count + 1
            let uniqueName = count == 0 ? entry.name : "\(entry.name) (\(count + 1))"
            let entryRank = fieldRanks[offset]
            let tieCount = fieldTieCounts[offset]
            let entryRRDelta = entry.isCurrentUser ? DFSEngine.pooledRRDelta(tiedRank: entryRank, tieCount: tieCount, entryCount: entryCount) : 0
            return DFSTournamentResultRecord(
                id: UUID().uuidString,
                tournamentID: tournamentID,
                userID: entry.realUserID,
                entryName: uniqueName,
                lineupPlayerIDs: entry.playerIDs,
                lineupPlayerNames: entry.playerNames,
                totalPoints: entry.totalPoints,
                playerPoints: entry.playerPoints,
                playerSalaries: entry.playerSalaries.isEmpty ? nil : entry.playerSalaries,
                rank: entryRank,
                rrDelta: entryRRDelta,
                isCurrentUser: entry.isCurrentUser,
                isBot: entry.isBot
            )
        }

        do {
            // Delete old bad results first
            try await SupabaseService.shared.deleteTournamentResults(tournamentID: tournamentID, accessToken: token)

            // Upload in batches of 100 to avoid request size limits
            for batch in stride(from: 0, to: resultRecords.count, by: 100) {
                let end = min(batch + 100, resultRecords.count)
                let chunk = Array(resultRecords[batch..<end])
                try await SupabaseService.shared.upsertTournamentResults(
                    tournamentID: tournamentID,
                    results: chunk,
                    accessToken: token
                )
            }
            try await SupabaseService.shared.markTournamentSettled(
                tournamentID: tournamentID,
                totalEntries: entryCount,
                accessToken: token
            )
            // Only mark settled locally AFTER successful server persist
            markTournamentSettled(tournamentID)
            let userEntryCount = field.filter(\.isCurrentUser).count
            print("[DFS] Settled past tournament \(tournamentID) — \(userEntryCount) user lineup(s), \(resultRecords.count) entries persisted")
        } catch {
            print("[DFS] Failed to persist past tournament results: \(error.localizedDescription)")
            // Don't mark as settled locally — allow retry on next attempt
        }

        // Return the generated records so callers can use them directly
        // (avoids re-fetching from server which may still have stale data if DELETE failed)
        return resultRecords
    }

    /// On-the-fly settlement for PGA golf tournaments.
    /// Uses the ESPN PGA scoreboard + scoring provider to compute final results.
    private func settleUnsettledPastGolfTournament(
        tournamentID: String,
        userEntry: DFSEntryRecord,
        token: String,
        userID: String
    ) async {
        guard !settlingInProgress.contains(tournamentID) else { return }
        settlingInProgress.insert(tournamentID)
        defer { settlingInProgress.remove(tournamentID) }

        // tournamentID is "pga-{espnEventID}-{fieldSize}" — extract the ESPN event ID
        // Strip "pga-" prefix, then take only the first component (the event ID)
        let afterPrefix = tournamentID.replacingOccurrences(of: "pga-", with: "")
        let eventID = afterPrefix.components(separatedBy: "-").first ?? afterPrefix
        guard !eventID.isEmpty else { return }

        // Fetch golf slate to get player data and tournament info
        let slateProvider = ESPNPGADFSSlateProvider()
        guard let slate = try? await slateProvider.fetchSlate() else {
            print("[DFS] Golf on-the-fly settlement: couldn't fetch slate")
            return
        }

        // Create a slate game for the scoring provider using the CORRECT event ID
        // (not the current slate's game, which may be a different tournament)
        let slateGame: DFSSlateGame
        if let existingGame = slate.includedGames.first, existingGame.id == eventID {
            slateGame = existingGame
        } else {
            let serverTournament = try? await SupabaseService.shared.fetchTournament(tournamentID: tournamentID, accessToken: token)
            let serverTitle = serverTournament?.title ?? "PGA Tournament"
            // Use the actual lock time from the server for the date-based ESPN query
            let tournamentDate = serverTournament?.lockTime ?? Date().addingTimeInterval(-7 * 24 * 3600)
            slateGame = DFSSlateGame(
                id: eventID,
                awayTeam: "",
                homeTeam: serverTitle,
                startTime: tournamentDate,
                state: "post"
            )
        }

        // Fetch final scores
        let scoringProvider = ESPNPGADFSLiveScoringProvider()
        guard let snapshot = try? await scoringProvider.fetchScoreSnapshot(for: [slateGame]) else {
            print("[DFS] Golf on-the-fly settlement: couldn't fetch scores")
            return
        }

        // Build player info from snapshot
        struct PlayerInfo {
            let id: String
            let name: String
            let points: Double
        }
        let allPlayers: [PlayerInfo] = snapshot.playerFantasyPoints.compactMap { (pid, pts) in
            let name = snapshot.playerLiveStats[pid]?.name ?? slate.players.first(where: { $0.id == pid })?.name ?? pid
            return PlayerInfo(id: pid, name: name, points: pts)
        }
        guard !allPlayers.isEmpty else {
            print("[DFS] Golf on-the-fly settlement: no player scores available")
            return
        }
        // Don't settle if all scores are zero (ESPN dropped the event data)
        let totalScoreSum = allPlayers.reduce(0.0) { $0 + abs($1.points) }
        guard totalScoreSum > 0 else {
            print("[DFS] Golf on-the-fly settlement: all player scores are zero — skipping")
            return
        }

        // Build name lookup
        var playerNameLookup: [String: String] = [:]
        for player in allPlayers {
            playerNameLookup[player.id] = player.name
        }
        for player in slate.players {
            if playerNameLookup[player.id] == nil {
                playerNameLookup[player.id] = player.name
            }
        }

        // Resolve any missing user lineup player names
        let userPlayerIDs = userEntry.lineupPlayerIDs
        let unresolvedIDs = userPlayerIDs.filter { playerNameLookup[$0] == nil }
        if !unresolvedIDs.isEmpty {
            await withTaskGroup(of: (String, String?).self) { group in
                for pid in unresolvedIDs {
                    group.addTask {
                        let athleteID = pid.replacingOccurrences(of: "pga-", with: "")
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/athletes/\(athleteID)") else {
                            return (pid, nil)
                        }
                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let name = json["displayName"] as? String else {
                            return (pid, nil)
                        }
                        return (pid, name)
                    }
                }
                for await (pid, name) in group {
                    if let name { playerNameLookup[pid] = name }
                }
            }
        }

        // Fetch ALL of the current user's entries for this tournament (multi-lineup support)
        let allUserGolfEntries: [DFSEntryRecord]
        if let fetched = try? await SupabaseService.shared.fetchEntries(
            tournamentID: tournamentID, accessToken: token
        ) {
            let mine = fetched.filter { $0.userID == userID }
            allUserGolfEntries = mine.isEmpty ? [userEntry] : mine
        } else {
            allUserGolfEntries = [userEntry]
        }

        // Resolve names for ALL user lineup players (not just the first entry)
        let allUserPlayerIDSet = Set(allUserGolfEntries.flatMap(\.lineupPlayerIDs))
        let additionalUnresolved = allUserPlayerIDSet.filter { playerNameLookup[$0] == nil }
        if !additionalUnresolved.isEmpty {
            await withTaskGroup(of: (String, String?).self) { group in
                for pid in additionalUnresolved {
                    group.addTask {
                        let athleteID = pid.replacingOccurrences(of: "pga-", with: "")
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/athletes/\(athleteID)") else {
                            return (pid, nil)
                        }
                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let name = json["displayName"] as? String else {
                            return (pid, nil)
                        }
                        return (pid, name)
                    }
                }
                for await (pid, name) in group {
                    if let name { playerNameLookup[pid] = name }
                }
            }
        }

        let lineupSize = allUserGolfEntries.first?.lineupPlayerIDs.count ?? userEntry.lineupPlayerIDs.count

        // Generate simulated field
        let entryCount = Self.entryCountFromTournamentID(tournamentID)
        let userName = profileName.isEmpty ? "You" : profileName
        let golfBotNames = [
            "EagleEye", "BirdieKing", "FairwayPro", "GreenSide", "IronShot",
            "PuttMaster", "DriveHero", "ChipShot", "SandTrap", "AcePutt",
            "LinksLegend", "CourseKing", "BogeyFree", "TeeTime", "HoleInOne",
            "WedgeWizard", "ClubPro", "RangeRat", "DogLeg", "PinSeeker",
            "ShotShaper", "GreenReader", "BackNine", "FrontRunner", "ProShop"
        ]

        struct SimEntry {
            let name: String
            let playerIDs: [String]
            let playerNames: [String]
            let playerPoints: [String: Double]
            let playerSalaries: [String: Int]
            let totalPoints: Double
            let isCurrentUser: Bool
            var realUserID: String? = nil
            var lineupNumber: Int? = nil
            var isBot: Bool { !isCurrentUser && realUserID == nil }
        }

        // Fetch tournament record — it may contain the original slate salaries
        let serverTournament = try? await SupabaseService.shared.fetchTournament(tournamentID: tournamentID, accessToken: token)
        let tournamentSalaries = serverTournament?.playerSalaries ?? [:]

        // Build salary lookup: tournament salaries (original slate) > current slate > estimate
        var salaryByID: [String: Int] = [:]
        // Start with current slate prices as baseline
        for player in slate.players {
            salaryByID[player.id] = player.salary
        }
        // Override with stored tournament salaries (original prices from draft day)
        for (pid, sal) in tournamentSalaries where sal > 0 {
            salaryByID[pid] = sal
        }

        // For players in the scoring data but not in any salary source, estimate
        let sortedByPoints = allPlayers.sorted { $0.points > $1.points }
        for (index, player) in sortedByPoints.enumerated() {
            if salaryByID[player.id] == nil {
                let order = index + 1
                let estimated: Int
                switch order {
                case 1...5: estimated = 11000
                case 6...15: estimated = 9500
                case 16...30: estimated = 8500
                case 31...50: estimated = 7500
                case 51...80: estimated = 6800
                default: estimated = 6200
                }
                salaryByID[player.id] = estimated
            }
        }

        var field: [SimEntry] = []

        // Add ALL of the current user's entries to the field (multi-lineup support)
        for (entryIdx, entry) in allUserGolfEntries.enumerated() {
            let pids = entry.lineupPlayerIDs
            let entryStoredSalaries = entry.lineupPlayerSalaries ?? [:]
            let entrySalaries: [String: Int] = Dictionary(uniqueKeysWithValues: pids.compactMap { pid -> (String, Int)? in
                if let tSal = tournamentSalaries[pid], tSal > 0 { return (pid, tSal) }
                else if let uSal = entryStoredSalaries[pid], uSal > 0 { return (pid, uSal) }
                else if let sal = salaryByID[pid], sal > 0 { return (pid, sal) }
                else { return nil }
            })
            var entryPoints = 0.0
            var entryPerPlayerPoints: [String: Double] = [:]
            for pid in pids {
                let pts = snapshot.playerFantasyPoints[pid] ?? 0
                entryPerPlayerPoints[pid] = pts
                entryPoints += pts
            }
            let entryPlayerNames = pids.map { playerNameLookup[$0] ?? $0 }
            let lineupNum = entry.lineupNumber ?? (entryIdx + 1)
            let displayName = allUserGolfEntries.count > 1 ? "\(userName) #\(lineupNum)" : userName
            field.append(SimEntry(
                name: displayName,
                playerIDs: pids,
                playerNames: entryPlayerNames,
                playerPoints: entryPerPlayerPoints,
                playerSalaries: entrySalaries,
                totalPoints: entryPoints,
                isCurrentUser: true,
                realUserID: userID,
                lineupNumber: lineupNum
            ))
        }

        // Add other real users' entries to the golf field
        let allGolfEntries = (try? await SupabaseService.shared.fetchEntries(
            tournamentID: tournamentID, accessToken: token
        )) ?? []
        let realGolfUserEntries = allGolfEntries.filter { $0.userID != userID }
        let golfRealUserIDs = Array(Set(realGolfUserEntries.map { $0.userID }))
        let golfRealProfiles = (try? await SupabaseService.shared.fetchProfiles(
            userIDs: golfRealUserIDs, accessToken: token
        )) ?? []
        let golfRealProfileNames = Dictionary(uniqueKeysWithValues: golfRealProfiles.map { ($0.id, $0.username) })
        for realEntry in realGolfUserEntries {
            let entryName = golfRealProfileNames[realEntry.userID]
                ?? realEntry.displayName
                ?? "User \(realEntry.userID.prefix(6))"
            let pids = realEntry.lineupPlayerIDs
            let pnames = pids.map { playerNameLookup[$0] ?? $0 }
            let ppts = Dictionary(uniqueKeysWithValues: pids.map { ($0, snapshot.playerFantasyPoints[$0] ?? 0) })
            let psals = Dictionary(uniqueKeysWithValues: pids.compactMap { pid -> (String, Int)? in
                guard let sal = salaryByID[pid], sal > 0 else { return nil }
                return (pid, sal)
            })
            let total = pids.reduce(0.0) { $0 + (snapshot.playerFantasyPoints[$1] ?? 0) }
            field.append(SimEntry(
                name: entryName,
                playerIDs: pids,
                playerNames: pnames,
                playerPoints: ppts,
                playerSalaries: psals,
                totalPoints: total,
                isCurrentUser: false,
                realUserID: realEntry.userID
            ))
        }
        let totalGolfRealEntries = allUserGolfEntries.count + realGolfUserEntries.count

        // Base player data for per-bot scrambled projections
        let baseGolfPlayers: [(id: String, name: String, salary: Int, actualPoints: Double)] = allPlayers.map { p in
            (id: p.id, name: p.name, salary: salaryByID[p.id] ?? 7000, actualPoints: p.points)
        }
        let golfAvgPoints = allPlayers.isEmpty ? 20.0 : allPlayers.reduce(0.0) { $0 + $1.points } / Double(allPlayers.count)
        let golfSalaryCap = 50000
        // Build a salary lookup for bot lineup salary tracking
        let golfSalaryByID = Dictionary(uniqueKeysWithValues: baseGolfPlayers.map { ($0.id, $0.salary) })

        // Use saved bot lineups if available (persisted at tournament start)
        let savedGolfBotField = serverTournament?.botField
        if let savedGolfBots = savedGolfBotField, !savedGolfBots.isEmpty {
            print("[DFS] Using \(savedGolfBots.count) saved bot lineups for golf \(tournamentID)")
            for (i, bot) in savedGolfBots.enumerated() {
                let botTotal = bot.playerIDs.reduce(0.0) { $0 + (snapshot.playerFantasyPoints[$1] ?? 0) }
                let pnames = bot.playerIDs.map { playerNameLookup[$0] ?? $0 }
                let ppts = Dictionary(uniqueKeysWithValues: bot.playerIDs.map { ($0, snapshot.playerFantasyPoints[$0] ?? 0) })
                let psals = Dictionary(uniqueKeysWithValues: bot.playerIDs.map { pid in
                    (pid, golfSalaryByID[pid] ?? 0)
                })
                field.append(SimEntry(
                    name: bot.name,
                    playerIDs: bot.playerIDs,
                    playerNames: pnames,
                    playerPoints: ppts,
                    playerSalaries: psals,
                    totalPoints: botTotal,
                    isCurrentUser: false
                ))
            }
            // If saved bots < needed, fill the rest with generated ones
            let remaining = max(0, entryCount - totalGolfRealEntries - savedGolfBots.count)
            if remaining > 0 {
                for i in 0..<remaining {
                    let golfDFSPlayersForBot: [DFSPlayer] = baseGolfPlayers.map { p in
                        let noise = Double.random(in: -0.5...0.8) * max(golfAvgPoints, 10.0)
                        let simulatedProjection = max(p.actualPoints * Double.random(in: 0.3...1.4) + noise, 1.0)
                        return DFSPlayer(
                            id: p.id, name: p.name, team: "", position: "G",
                            salary: p.salary, projectedPoints: simulatedProjection, gameID: nil
                        )
                    }
                    let botLineupIDs = generateBotLineup(from: golfDFSPlayersForBot, salaryCap: golfSalaryCap, lineupSize: lineupSize)
                    let botTotal = botLineupIDs.reduce(0.0) { $0 + (snapshot.playerFantasyPoints[$1] ?? 0) }
                    let pnames = botLineupIDs.map { playerNameLookup[$0] ?? $0 }
                    let ppts = Dictionary(uniqueKeysWithValues: botLineupIDs.map { ($0, snapshot.playerFantasyPoints[$0] ?? 0) })
                    let psals = Dictionary(uniqueKeysWithValues: botLineupIDs.map { pid in
                        (pid, golfSalaryByID[pid] ?? 0)
                    })
                    let baseName = golfBotNames[(savedGolfBots.count + i) % golfBotNames.count]
                    let uniqueName = "\(baseName) #\(savedGolfBots.count + i + 1)"
                    field.append(SimEntry(
                        name: uniqueName,
                        playerIDs: botLineupIDs,
                        playerNames: pnames,
                        playerPoints: ppts,
                        playerSalaries: psals,
                        totalPoints: botTotal,
                        isCurrentUser: false
                    ))
                }
            }
        } else {
            // Fallback: generate with scrambled projections (no saved bot field available)
            let golfBotsToGenerate = max(0, entryCount - totalGolfRealEntries)
            for i in 0..<golfBotsToGenerate {
                let golfDFSPlayersForBot: [DFSPlayer] = baseGolfPlayers.map { p in
                    let noise = Double.random(in: -0.5...0.8) * max(golfAvgPoints, 10.0)
                    let simulatedProjection = max(p.actualPoints * Double.random(in: 0.3...1.4) + noise, 1.0)
                    return DFSPlayer(
                        id: p.id, name: p.name, team: "", position: "G",
                        salary: p.salary, projectedPoints: simulatedProjection, gameID: nil
                    )
                }
                let botLineupIDs = generateBotLineup(from: golfDFSPlayersForBot, salaryCap: golfSalaryCap, lineupSize: lineupSize)
                let botTotal = botLineupIDs.reduce(0.0) { $0 + (snapshot.playerFantasyPoints[$1] ?? 0) }
                let pnames = botLineupIDs.map { playerNameLookup[$0] ?? $0 }
                let ppts = Dictionary(uniqueKeysWithValues: botLineupIDs.map { ($0, snapshot.playerFantasyPoints[$0] ?? 0) })
                let psals = Dictionary(uniqueKeysWithValues: botLineupIDs.map { pid in
                    (pid, golfSalaryByID[pid] ?? 0)
                })
                let baseName = golfBotNames[i % golfBotNames.count]
                let uniqueName = "\(baseName) #\(i + 1)"

                field.append(SimEntry(
                    name: uniqueName,
                    playerIDs: botLineupIDs,
                    playerNames: pnames,
                    playerPoints: ppts,
                    playerSalaries: psals,
                    totalPoints: botTotal,
                    isCurrentUser: false
                ))
            }
        }

        // Sort by points descending and compute tie-aware ranks for ALL entries
        field.sort { $0.totalPoints > $1.totalPoints }

        var fieldRanks = Array(repeating: 1, count: field.count)
        var fieldTieCounts = Array(repeating: 1, count: field.count)
        if !field.isEmpty {
            // First pass: assign ranks (tied entries share the same rank)
            for i in 0..<field.count {
                if i > 0 && abs(field[i].totalPoints - field[i - 1].totalPoints) < 0.001 {
                    fieldRanks[i] = fieldRanks[i - 1]
                } else {
                    fieldRanks[i] = i + 1
                }
            }
            // Second pass: compute tie group sizes
            var i = 0
            while i < field.count {
                let rank = fieldRanks[i]
                var j = i
                while j < field.count && fieldRanks[j] == rank { j += 1 }
                let groupSize = j - i
                for k in i..<j { fieldTieCounts[k] = groupSize }
                i = j
            }
        }

        let title = serverTournament?.title ?? slate.tournament.title

        // Create dfsHistory entries for user lineups that aren't recorded yet.
        // For multi-lineup tournaments, previous settlement may have only recorded ONE lineup,
        // so we need to create entries for the remaining lineups.
        let existingHistoryForTournament = dfsHistory.filter { $0.tournamentId == tournamentID }
        let existingLineupNumbers = Set(existingHistoryForTournament.compactMap { $0.lineupNumber })
        let fullyRecorded = settledTournaments.contains(tournamentID)
            && existingHistoryForTournament.count >= allUserGolfEntries.count

        let userFieldEntries = field.enumerated().filter { $0.element.isCurrentUser }
        if !fullyRecorded {
            var totalRRDelta = 0
            var newResults: [DFSResult] = []
            for (offset, userFieldEntry) in userFieldEntries {
                let entryRank = fieldRanks[offset]
                let tieCount = fieldTieCounts[offset]
                let lineupNum = userFieldEntry.lineupNumber
                // Skip if this lineup is already in history
                if let ln = lineupNum, existingLineupNumbers.contains(ln) { continue }
                // Also skip if there's a single existing entry with nil lineupNumber (non-multi case)
                if lineupNum == nil && !existingHistoryForTournament.isEmpty { continue }
                let entryRRDelta = DFSEngine.pooledRRDelta(tiedRank: entryRank, tieCount: tieCount, entryCount: entryCount)
                totalRRDelta += entryRRDelta
                newResults.append(DFSResult(
                    id: UUID(),
                    tournamentTitle: title,
                    rank: entryRank,
                    totalEntries: entryCount,
                    lineupPoints: userFieldEntry.totalPoints,
                    rrDelta: entryRRDelta,
                    loggedAt: serverTournament?.lockTime ?? Date(),
                    tournamentId: tournamentID,
                    lineupNumber: lineupNum
                ))
            }
            if !newResults.isEmpty {
                rrScore += totalRRDelta
                var updatedHistory = dfsHistory
                updatedHistory.append(contentsOf: newResults)
                updatedHistory.sort { $0.loggedAt > $1.loggedAt }
                dfsHistoryData = encodedDFSHistory(Array(updatedHistory.prefix(500)))
            }
        }
        // Build result records for ALL entries and persist to server
        // Deduplicate entry names to avoid upsert conflict on (tournament_id, entry_name)
        var golfNameCounter: [String: Int] = [:]
        let resultRecords: [DFSTournamentResultRecord] = field.enumerated().map { offset, entry in
            let count = golfNameCounter[entry.name, default: 0]
            golfNameCounter[entry.name] = count + 1
            let uniqueName = count == 0 ? entry.name : "\(entry.name) (\(count + 1))"
            let entryRank = fieldRanks[offset]
            let tieCount = fieldTieCounts[offset]
            let entryRRDelta = entry.isCurrentUser ? DFSEngine.pooledRRDelta(tiedRank: entryRank, tieCount: tieCount, entryCount: entryCount) : 0
            return DFSTournamentResultRecord(
                id: UUID().uuidString,
                tournamentID: tournamentID,
                userID: entry.realUserID,
                entryName: uniqueName,
                lineupPlayerIDs: entry.playerIDs,
                lineupPlayerNames: entry.playerNames,
                totalPoints: entry.totalPoints,
                playerPoints: entry.playerPoints,
                playerSalaries: entry.playerSalaries.isEmpty ? nil : entry.playerSalaries,
                rank: entryRank,
                rrDelta: entryRRDelta,
                isCurrentUser: entry.isCurrentUser,
                isBot: entry.isBot
            )
        }

        do {
            try await SupabaseService.shared.deleteTournamentResults(tournamentID: tournamentID, accessToken: token)
            for batch in stride(from: 0, to: resultRecords.count, by: 100) {
                let end = min(batch + 100, resultRecords.count)
                let chunk = Array(resultRecords[batch..<end])
                try await SupabaseService.shared.upsertTournamentResults(
                    tournamentID: tournamentID,
                    results: chunk,
                    accessToken: token
                )
            }
            try await SupabaseService.shared.markTournamentSettled(
                tournamentID: tournamentID,
                totalEntries: entryCount,
                accessToken: token
            )
            // Only mark settled locally AFTER successful server persist
            markTournamentSettled(tournamentID)
            let userEntryCount = field.filter(\.isCurrentUser).count
            print("[DFS] Settled past golf tournament \(tournamentID) — \(userEntryCount) user lineup(s), \(resultRecords.count) entries persisted")
        } catch {
            print("[DFS] Failed to persist golf tournament results: \(error.localizedDescription)")
        }
    }

    /// Helper: fetches the user's result for a specific tournament from the server and adds to local history if missing.
    private func addServerResultToHistoryIfMissing(tournamentID: String, token: String, userID: String) async {
        do {
            let allResults = try await SupabaseService.shared.fetchTournamentResults(tournamentID: tournamentID, accessToken: token)
            let userResults = allResults.filter { $0.userID == userID && $0.isCurrentUser }
            guard !userResults.isEmpty else { return }

            let serverTournament = try? await SupabaseService.shared.fetchTournament(tournamentID: tournamentID, accessToken: token)
            let title = serverTournament?.title ?? "Tournament"
            let totalEntries = serverTournament?.totalEntries ?? allResults.count
            let loggedAt = serverTournament?.lockTime ?? Date()

            var updatedHistory = dfsHistory
            for (idx, userResult) in userResults.enumerated() {
                let lineupNum = userResults.count > 1 ? idx + 1 : nil as Int?
                // Check if already in history using composite key
                let existsAlready = updatedHistory.contains { r in
                    r.tournamentId == tournamentID && r.lineupNumber == lineupNum
                }
                guard !existsAlready else { continue }

                updatedHistory.append(DFSResult(
                    id: UUID(),
                    tournamentTitle: title,
                    rank: userResult.rank,
                    totalEntries: totalEntries,
                    lineupPoints: userResult.totalPoints,
                    rrDelta: userResult.rrDelta,
                    loggedAt: loggedAt,
                    tournamentId: tournamentID,
                    lineupNumber: lineupNum
                ))
            }
            if updatedHistory.count != dfsHistory.count {
                updatedHistory.sort { $0.loggedAt > $1.loggedAt }
                dfsHistoryData = encodedDFSHistory(Array(updatedHistory.prefix(500)))
            }
        } catch {
            print("[DFS] Failed to fetch result for tournament \(tournamentID): \(error.localizedDescription)")
        }
    }

    /// Loads DFS history from server and merges with local history.
    /// Always checks for new server-side results so that tournaments settled
    /// while the app was closed (or on another device) appear in past results.
    func syncHistoryFromServer() async {
        guard let token = accessToken, let userID else { return }

        do {
            let serverResults = try await SupabaseService.shared.fetchUserDFSHistory(userID: userID, limit: 500, accessToken: token)

            // Only import results matching this view model's sport.
            // NBA also handles NCAAM since they share the same DFSViewModel.
            let sportPrefixes: [String] = sport == "NBA" ? ["nba-", "ncaam-"] : [sport.lowercased() + "-"]
            let matchesSport: (String) -> Bool = { tid in sportPrefixes.contains(where: { tid.hasPrefix($0) }) }

            // If server has no results at all, clear local history entries for this sport
            // so that stale data from a previous account on the same device is removed.
            if serverResults.isEmpty {
                let localHistory = dfsHistory
                let cleaned = localHistory.filter { r in
                    guard let tid = r.tournamentId else { return true }
                    return !matchesSport(tid)
                }
                if cleaned.count != localHistory.count {
                    dfsHistoryData = encodedDFSHistory(cleaned)
                }
                return
            }

            // Also fetch tournament info for titles and total entries
            let tournaments = try await SupabaseService.shared.fetchRecentTournaments(accessToken: token)
            let tournamentMap = Dictionary(uniqueKeysWithValues: tournaments.map { ($0.id, $0) })

            // Group server results by tournament ID to assign lineup numbers
            var serverResultsByTournament: [String: [DFSTournamentResultRecord]] = [:]
            for result in serverResults {
                guard matchesSport(result.tournamentID) else { continue }
                guard result.totalPoints > 0 else { continue }
                serverResultsByTournament[result.tournamentID, default: []].append(result)
            }

            // Build lookup of existing local history by composite key (tournamentID + lineupNumber)
            var localHistory = dfsHistory
            let existingByKey = Dictionary(
                localHistory.enumerated().compactMap { (idx, r) -> (String, Int)? in
                    guard let tid = r.tournamentId else { return nil }
                    let key = "\(tid)-L\(r.lineupNumber ?? 1)"
                    return (key, idx)
                },
                uniquingKeysWith: { first, _ in first }
            )

            var newEntries: [DFSResult] = []
            var didUpdate = false
            for (tournamentID, results) in serverResultsByTournament {
                let tournament = tournamentMap[tournamentID]
                
                // If tournament IS in the map, verify it has started
                if let lockTime = tournament?.lockTime, lockTime > Date() { continue }
                
                // Use tournament metadata when available, fall back to result data
                let title = tournament?.title ?? "Tournament"
                let totalEntries = tournament?.totalEntries ?? 0
                let loggedAt = tournament?.lockTime ?? results.first?.createdAt ?? Date()

                for (resultIdx, result) in results.enumerated() {
                    // Derive lineup number: extract from entry name (e.g., "Username #2") or use index.
                    // Only accept small numbers (1-20) as lineup numbers — larger values are
                    // bot indices or rank values that leaked into entry names.
                    let lineupNum: Int = {
                        if let hashRange = result.entryName.range(of: "#"),
                           let num = Int(result.entryName[hashRange.upperBound...].trimmingCharacters(in: .whitespaces)),
                           num >= 1 && num <= 20 {
                            return num
                        }
                        return resultIdx + 1
                    }()
                    let compositeKey = "\(tournamentID)-L\(lineupNum)"

                    if let existingIndex = existingByKey[compositeKey] {
                        // Already in local history — update if server has better data OR stale title
                        let existing = localHistory[existingIndex]
                        let needsPointsUpdate = result.totalPoints > existing.lineupPoints || existing.lineupPoints == 0
                        let needsTitleRefresh = existing.tournamentTitle != title && title != "Tournament"
                        if needsPointsUpdate || needsTitleRefresh {
                            localHistory[existingIndex] = DFSResult(
                                id: existing.id,
                                tournamentTitle: title,
                                rank: needsPointsUpdate ? result.rank : existing.rank,
                                totalEntries: totalEntries > 0 ? totalEntries : existing.totalEntries,
                                lineupPoints: needsPointsUpdate ? result.totalPoints : existing.lineupPoints,
                                rrDelta: needsPointsUpdate ? result.rrDelta : existing.rrDelta,
                                loggedAt: existing.loggedAt,
                                tournamentId: tournamentID,
                                lineupNumber: results.count > 1 ? lineupNum : existing.lineupNumber
                            )
                            didUpdate = true
                        }
                    } else {
                        // New result not in local history
                        newEntries.append(DFSResult(
                            id: UUID(),
                            tournamentTitle: title,
                            rank: result.rank,
                            totalEntries: totalEntries,
                            lineupPoints: result.totalPoints,
                            rrDelta: result.rrDelta,
                            loggedAt: loggedAt,
                            tournamentId: tournamentID,
                            lineupNumber: results.count > 1 ? lineupNum : nil
                        ))
                    }
                }
                // Mark as settled locally
                markTournamentSettled(tournamentID)
            }

            if !newEntries.isEmpty || didUpdate {
                var merged = localHistory
                merged.append(contentsOf: newEntries)
                merged.sort { $0.loggedAt > $1.loggedAt }
                dfsHistoryData = encodedDFSHistory(Array(merged.prefix(500)))
            }

            // Restore latestResult for the current tournament from history so the
            // active-contest card shows the correct rank/score immediately
            if latestResult == nil, let tid = tournament?.id,
               let historyMatch = dfsHistory.first(where: { $0.tournamentId == tid }) {
                latestResult = historyMatch
            }
        } catch {
            print("[DFS] Failed to sync history from server: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func syncTournamentBackend() async {
        guard let tournament else { return }
        guard let token = accessToken else { return }
        do {
            let lockTime = computeLockTime()
            let isLocked = Date() >= lockTime

            // Check if the tournament already has stored salaries on the server
            let existing = try? await SupabaseService.shared.fetchTournament(
                tournamentID: tournament.id, accessToken: token
            )
            let storedSalaries = existing?.playerSalaries ?? [:]

            if isLocked && !storedSalaries.isEmpty {
                // Tournament is locked — freeze main-slate salaries to the stored snapshot
                players = players.map { p in
                    if let saved = storedSalaries[p.id] {
                        var frozen = p
                        frozen = DFSPlayer(
                            id: p.id, name: p.name, team: p.team, position: p.position,
                            salary: saved, projectedPoints: p.projectedPoints,
                            gameID: p.gameID, injuryStatus: p.injuryStatus,
                            battingOrder: p.battingOrder
                        )
                        frozen.gamesPlayed = p.gamesPlayed
                        frozen.playedRecently = p.playedRecently
                        frozen.isConfirmedActive = p.isConfirmedActive
                        frozen.isStartingGoalie = p.isStartingGoalie
                        return frozen
                    }
                    return p
                }
                // Re-derive single-game pools from stored main-slate salaries.
                // Stored salaries are MAIN-SLATE prices; single-game pools need
                // showdown-converted prices (via singleGameSalary). Previously this
                // applied main-slate prices directly, producing too-low showdown salaries.
                let league = tournament.league
                for (gameID, sgPool) in singleGamePlayers {
                    singleGamePlayers[gameID] = sgPool.map { p in
                        if let mainSalary = storedSalaries[p.id] {
                            let showdownSalary = singleGameSalary(from: mainSalary, league: league)
                            var fixed = DFSPlayer(
                                id: p.id, name: p.name, team: p.team, position: p.position,
                                salary: showdownSalary, projectedPoints: p.projectedPoints,
                                gameID: p.gameID, injuryStatus: p.injuryStatus,
                                battingOrder: p.battingOrder
                            )
                            fixed.gamesPlayed = p.gamesPlayed
                            fixed.playedRecently = p.playedRecently
                            fixed.isConfirmedActive = p.isConfirmedActive
                            fixed.isStartingGoalie = p.isStartingGoalie
                            return fixed
                        }
                        return p
                    }
                }
                let record = DFSTournamentRecord(
                    id: tournament.id, title: tournament.title, league: tournament.league,
                    lockTime: lockTime, playerSalaries: storedSalaries
                )
                try await SupabaseService.shared.upsertTournament(record: record, accessToken: token)
            } else {
                // Tournament is still open — save the latest main-slate salaries.
                // Always save main-slate prices (not showdown-converted) so the stored
                // snapshot is consistent. Showdown prices are derived at load time.
                let pool = players
                let allPlayerSalaries = pool.isEmpty ? nil : Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0.salary) })
                let record = DFSTournamentRecord(
                    id: tournament.id, title: tournament.title, league: tournament.league,
                    lockTime: lockTime, playerSalaries: allPlayerSalaries
                )
                try await SupabaseService.shared.upsertTournament(record: record, accessToken: token)
            }
        } catch {
            // Don't block the UI if backend sync fails — tournament still loads locally
            print("[DFS] Tournament sync failed: \(error.localizedDescription)")
        }
        // Always try to load entries even if upsert failed
        await refreshRemoteEntries()
    }

    private func refreshRemoteEntries() async {
        guard let tournament else { return }
        guard let token = accessToken, let userID else { return }
        do {
            let entries = try await SupabaseService.shared.fetchEntries(tournamentID: tournament.id, accessToken: token)
            remoteEntries = entries

            let uniqueUserIDs = Array(Set(entries.map { $0.userID }))
            let profiles = try await SupabaseService.shared.fetchProfiles(userIDs: uniqueUserIDs, accessToken: token)
            remoteProfileNames = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.username) })

            // Only overwrite fieldEntries if we haven't generated simulated opponents yet.
            // Once the field is built (real + simulated), we preserve it to avoid resetting
            // the leaderboard on every refresh or tab switch.
            if !fieldGenerated {
                // Include ALL of the current user's entries so every lineup appears
                // in the leaderboard (multi-entry support).
                let otherEntries = entries.filter { $0.userID != userID }
                let myEntriesAll = entries.filter { $0.userID == userID }
                let myName = remoteProfileNames[userID] ?? (profileName.isEmpty ? "You" : profileName)
                let showLineupNumber = myEntriesAll.count > 1
                let initialEntries: [DFSEntryRecord] = myEntriesAll + otherEntries
                fieldEntries = initialEntries.map { entry in
                    let isMe = entry.userID == userID
                    let name: String
                    if isMe && showLineupNumber {
                        let ln = entry.lineupNumber ?? (myEntriesAll.firstIndex(where: { $0.id == entry.id }).map { $0 + 1 } ?? 1)
                        name = "\(myName) #\(ln)"
                    } else {
                        name = isMe ? myName : (remoteProfileNames[entry.userID] ?? "User \(entry.userID.prefix(6))")
                    }
                    return DFSFieldEntry(
                        id: UUID(uuidString: entry.id) ?? UUID(),
                        name: name,
                        playerIDs: entry.lineupPlayerIDs,
                        isCurrentUser: isMe,
                        isRealUser: true,
                        realUserID: entry.userID
                    )
                }
                // Fallback: if remote entries were empty but we have a cached entry, include the user
                if fieldEntries.isEmpty || !fieldEntries.contains(where: { $0.isCurrentUser }),
                   let cachedEntry = entryRecord(for: tournament.id, lineupNumber: activeLineupNumber) {
                    let fallbackName = profileName.isEmpty ? "You" : profileName
                    let userFieldEntry = DFSFieldEntry(
                        id: UUID(uuidString: cachedEntry.id) ?? UUID(),
                        name: fallbackName,
                        playerIDs: cachedEntry.lineupPlayerIDs,
                        isCurrentUser: true,
                        isRealUser: true,
                        realUserID: userID
                    )
                    if !fieldEntries.contains(where: { $0.isCurrentUser }) {
                        fieldEntries.insert(userFieldEntry, at: 0)
                        print("[DFS-\(sport)] Injected user from cached records (remote entries missing user, fieldGenerated=false)")
                    }
                }
            } else {
                // Field already generated — ensure ALL of the current user's entries are present.
                // This handles the case where the user submits a lineup after the field was built
                // (e.g. after viewing the lobby, bots were generated, then user locks lineup).
                let myEntries2 = entries.filter { $0.userID == userID }
                let myName = remoteProfileNames[userID] ?? (profileName.isEmpty ? "You" : profileName)
                let showLN = myEntries2.count > 1

                // Remove all existing user entries from field (we'll re-add them all)
                fieldEntries.removeAll(where: { $0.isCurrentUser })

                if !myEntries2.isEmpty {
                    for entry in myEntries2 {
                        let ln = entry.lineupNumber ?? (myEntries2.firstIndex(where: { $0.id == entry.id }).map { $0 + 1 } ?? 1)
                        let displayName = showLN ? "\(myName) #\(ln)" : myName
                        let fe = DFSFieldEntry(
                            id: UUID(uuidString: entry.id) ?? UUID(),
                            name: displayName,
                            playerIDs: entry.lineupPlayerIDs,
                            isCurrentUser: true,
                            isRealUser: true,
                            realUserID: userID
                        )
                        // Replace bot entries to keep total count stable
                        if let botIdx = fieldEntries.firstIndex(where: { !$0.isCurrentUser && !$0.isRealUser }) {
                            fieldEntries[botIdx] = fe
                        } else {
                            fieldEntries.append(fe)
                        }
                    }
                } else if let cachedEntry = entryRecord(for: tournament.id, lineupNumber: activeLineupNumber) {
                    // Fallback: inject from cached records
                    let fallbackName = profileName.isEmpty ? "You" : profileName
                    let fallbackFieldEntry = DFSFieldEntry(
                        id: UUID(uuidString: cachedEntry.id) ?? UUID(),
                        name: fallbackName,
                        playerIDs: cachedEntry.lineupPlayerIDs,
                        isCurrentUser: true,
                        isRealUser: true,
                        realUserID: userID
                    )
                    if let botIdx = fieldEntries.firstIndex(where: { !$0.isCurrentUser && !$0.isRealUser }) {
                        fieldEntries[botIdx] = fallbackFieldEntry
                    } else {
                        fieldEntries.append(fallbackFieldEntry)
                    }
                    print("[DFS-\(sport)] Injected user entry from cached records in refreshRemoteEntries (remote was empty)")
                }

                // Also integrate other real users — replace bot entries with real user entries
                let otherRealEntries = entries.filter { $0.userID != userID }
                for otherEntry in otherRealEntries {
                    let otherName = remoteProfileNames[otherEntry.userID] ?? "User \(otherEntry.userID.prefix(6))"
                    let otherFieldEntry = DFSFieldEntry(
                        id: UUID(uuidString: otherEntry.id) ?? UUID(),
                        name: otherName,
                        playerIDs: otherEntry.lineupPlayerIDs,
                        isCurrentUser: false,
                        isRealUser: true,
                        realUserID: otherEntry.userID
                    )
                    // If this user is already in the field, update their entry
                    if let existingIdx = fieldEntries.firstIndex(where: { $0.realUserID == otherEntry.userID }) {
                        fieldEntries[existingIdx] = otherFieldEntry
                    } else {
                        // Replace a bot entry with this real user
                        if let botIdx = fieldEntries.firstIndex(where: { !$0.isCurrentUser && !$0.isRealUser }) {
                            fieldEntries[botIdx] = otherFieldEntry
                        }
                        // If no bot slots available, the field is full of real users — don't add
                    }
                }
            }

            // Pick the user's entry matching the active lineup number
            let myEntries = entries.filter { $0.userID == userID }
            let exactMatch: DFSEntryRecord? = myEntries.first(where: { ($0.lineupNumber ?? 1) == activeLineupNumber })
                ?? {
                    // Index-based fallback for entries with nil lineupNumber
                    let idx = activeLineupNumber - 1
                    return (idx >= 0 && idx < myEntries.count) ? myEntries[idx] : nil
                }()
            let mine = exactMatch ?? myEntries.first
            if let mine {
                // Don't overwrite the user's in-progress edits during background refresh
                // Only set selectedPlayerIDs from the EXACT match for the active lineup number.
                // If we fell back to .first, we'd show a different lineup's players (wrong lineup bug).
                if !isEditingLineup {
                    if exactMatch != nil {
                        selectedPlayerIDs = Set(mine.lineupPlayerIDs)
                        // Restore MVP selection for single-game: first player in saved array is the MVP
                        if tournament.isSingleGame, let firstID = mine.lineupPlayerIDs.first {
                            mvpPlayerID = firstID
                        }
                    } else if selectedPlayerIDs.isEmpty {
                        // Only use fallback if we have nothing at all
                        selectedPlayerIDs = Set(mine.lineupPlayerIDs)
                        if tournament.isSingleGame, let firstID = mine.lineupPlayerIDs.first {
                            mvpPlayerID = firstID
                        }
                    }
                }
                
                // Keep userEntryRecords fresh for this tournament
                if !myEntries.isEmpty {
                    userEntryRecords[tournament.id] = myEntries
                }
                
                // Build a name lookup from saved entry data (playerID → name)
                let savedNames: [String: String]
                if let names = mine.lineupPlayerNames, names.count == mine.lineupPlayerIDs.count {
                    savedNames = Dictionary(uniqueKeysWithValues: zip(mine.lineupPlayerIDs, names))
                } else {
                    savedNames = [:]
                }
                let savedSalaries = mine.lineupPlayerSalaries ?? [:]
                
                // Ensure all selected player IDs exist in the players array.
                // If a player was dropped from the top-N roster on refresh,
                // fetch their info from ESPN and add them back.
                let existingIDs = Set(players.map(\.id))
                let missingIDs = selectedPlayerIDs.subtracting(existingIDs)
                if !missingIDs.isEmpty {
                    // Pre-fetch names from team rosters for missing players.
                    // The roster endpoint always has names (unlike boxscores which are empty pre-game).
                    // PGA players use golf-specific ESPN endpoints; others use team rosters
                    if sport == "PGA" {
                        await withTaskGroup(of: DFSPlayer.self) { group in
                            for pid in missingIDs {
                                let salary = savedSalaries[pid] ?? 6000
                                let fallbackName = savedNames[pid]
                                group.addTask { [self] in
                                    return await self.fetchMissingGolfPlayer(pid: pid, salary: salary, fallbackName: fallbackName)
                                }
                            }
                            for await player in group {
                                players.append(player)
                            }
                        }
                    } else {
                        let rosterMissing = missingIDs.filter { $0.hasPrefix("ncaam-") || $0.hasPrefix("nba-") || $0.hasPrefix("mlb-") || $0.hasPrefix("nhl-") }
                        if !rosterMissing.isEmpty {
                            await preloadNamesFromTeamRosters(missingIDs: rosterMissing, savedNames: savedNames)
                        }
                        await withTaskGroup(of: DFSPlayer.self) { group in
                            for pid in missingIDs {
                                let fallbackName = savedNames[pid]
                                let salary = savedSalaries[pid] ?? 0
                                group.addTask { [self] in
                                    return await self.fetchMissingPlayer(pid: pid, fallbackName: fallbackName, salary: salary)
                                }
                            }
                            for await player in group {
                                players.append(player)
                            }
                        }
                    }
                    print("[DFS] Restored \(missingIDs.count) missing lineup player(s)")
                }
            }

            // Also resolve names for players in OTHER field entries (bot/opponent lineups)
            // that aren't in the players array. Without this, leaderboard box scores show raw IDs.
            let allFieldPlayerIDs = Set(fieldEntries.flatMap { $0.playerIDs })
            let currentPlayerIDs = Set(players.map(\.id))
            let fieldMissing = allFieldPlayerIDs.subtracting(currentPlayerIDs)
            if !fieldMissing.isEmpty {
                // Build a salary lookup from stored tournament salaries so missing
                // bot players get their real FanDuel price instead of the $2K floor.
                let serverTournament = try? await SupabaseService.shared.fetchTournament(
                    tournamentID: tournament.id, accessToken: token
                )
                let storedSalaries = serverTournament?.playerSalaries ?? [:]

                let rosterFieldMissing = fieldMissing.filter { $0.hasPrefix("ncaam-") || $0.hasPrefix("nba-") || $0.hasPrefix("mlb-") || $0.hasPrefix("nhl-") }
                if !rosterFieldMissing.isEmpty {
                    await preloadNamesFromTeamRosters(missingIDs: rosterFieldMissing, savedNames: [:])
                }
                await withTaskGroup(of: DFSPlayer.self) { group in
                    for pid in fieldMissing {
                        let salary = storedSalaries[pid] ?? 0
                        group.addTask { [self] in
                            return await self.fetchMissingPlayer(pid: pid, salary: salary)
                        }
                    }
                    for await player in group {
                        players.append(player)
                    }
                }
                print("[DFS] Resolved \(fieldMissing.count) missing field entry player name(s)")
            }
        } catch {
            // Don't block UI for entry loading failures
            print("[DFS] Unable to load entries: \(error.localizedDescription)")
        }
    }

    /// Pre-fetch player names from team rosters for missing players.
    /// Works both pre-game and in-game by using the roster endpoint (always available).
    /// Populates `preloadedPlayerInfo` so subsequent `fetchMissingPlayer` calls find names instantly.
    private func preloadNamesFromTeamRosters(missingIDs: Set<String>, savedNames: [String: String]) async {
        // Build a lookup of athlete IDs we need (without prefix)
        // Two-way player IDs like "mlb-39832-sp" need the "-sp" stripped to get the real ESPN athlete ID
        var neededAthleteIDs: Set<String> = []
        // Map real ESPN athlete ID back to the original pid(s) that need it
        var athleteIDToPIDs: [String: [String]] = [:]
        for pid in missingIDs {
            var rawID: String
            if pid.hasPrefix("ncaam-") {
                rawID = String(pid.dropFirst(6))
            } else if pid.hasPrefix("nba-") {
                rawID = String(pid.dropFirst(4))
            } else if pid.hasPrefix("mlb-") {
                rawID = String(pid.dropFirst(4))
            } else if pid.hasPrefix("nhl-") {
                rawID = String(pid.dropFirst(4))
            } else {
                continue
            }
            // Strip "-sp" suffix for two-way pitcher entries
            if rawID.hasSuffix("-sp") {
                rawID = String(rawID.dropLast(3))
            }
            neededAthleteIDs.insert(rawID)
            athleteIDToPIDs[rawID, default: []].append(pid)
        }
        guard !neededAthleteIDs.isEmpty else { return }

        let espnSport: String
        let idPrefix: String
        if missingIDs.first?.hasPrefix("ncaam-") == true {
            espnSport = "basketball/mens-college-basketball"
            idPrefix = "ncaam-"
        } else if missingIDs.first?.hasPrefix("mlb-") == true {
            espnSport = "baseball/mlb"
            idPrefix = "mlb-"
        } else if missingIDs.first?.hasPrefix("nhl-") == true {
            espnSport = "hockey/nhl"
            idPrefix = "nhl-"
        } else if missingIDs.first?.hasPrefix("ufc-") == true {
            espnSport = "mma/ufc"
            idPrefix = "ufc-"
        } else if missingIDs.first?.hasPrefix("nfl-") == true {
            espnSport = "football/nfl"
            idPrefix = "nfl-"
        } else if missingIDs.first?.hasPrefix("cfb-") == true {
            espnSport = "football/college-football"
            idPrefix = "cfb-"
        } else {
            espnSport = "basketball/nba"
            idPrefix = "nba-"
        }

        // Step 1: Fetch the scoreboard to get team IDs from event competitors
        // Use the date from the tournament ID (e.g. "ncaam-20260319") if available
        let dateKey: String
        if let tid = tournament?.id {
            // Extract date portion: "ncaam-20260319" → "20260319", "nba-20260319" → "20260319"
            let parts = tid.split(separator: "-")
            if parts.count >= 2, parts.last?.count == 8 {
                dateKey = String(parts.last!)
            } else {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd"
                df.timeZone = TimeZone(identifier: "America/New_York")
                dateKey = df.string(from: Date())
            }
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd"
            df.timeZone = TimeZone(identifier: "America/New_York")
            dateKey = df.string(from: Date())
        }
        // Only NCAAM needs groups=100 for March Madness filtering; NBA/MLB don't use it
        let groupsParam = espnSport.contains("college") ? "&groups=100" : ""
        guard let scoreboardURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(espnSport)/scoreboard?dates=\(dateKey)&limit=100\(groupsParam)"),
              let (sbData, _) = try? await URLSession.shared.data(from: scoreboardURL),
              let sbJSON = try? JSONSerialization.jsonObject(with: sbData) as? [String: Any],
              let events = sbJSON["events"] as? [[String: Any]] else {
            return
        }

        // Collect team IDs and build teamID → (abbreviation, eventID) mapping from scoreboard
        struct TeamInfo {
            let teamID: String
            let abbreviation: String
            let eventID: String
        }
        var teamInfos: [TeamInfo] = []
        for event in events {
            guard let eventID = event["id"] as? String,
                  let competitions = event["competitions"] as? [[String: Any]],
                  let comp = competitions.first,
                  let competitors = comp["competitors"] as? [[String: Any]] else { continue }
            for competitor in competitors {
                if let team = competitor["team"] as? [String: Any],
                   let teamID = team["id"] as? String,
                   let abbr = team["abbreviation"] as? String {
                    teamInfos.append(TeamInfo(teamID: teamID, abbreviation: abbr, eventID: eventID))
                }
            }
        }

        // Step 2: Fetch team rosters in parallel and look for missing athlete IDs
        // Basketball rosters have flat athletes array; MLB rosters have grouped { items: [athlete] } arrays.
        await withTaskGroup(of: [(String, String, String, String, String?)].self) { group in  // (pid, name, teamAbbr, eventID, position)
            for info in teamInfos {
                let teamAbbr = info.abbreviation
                let eventID = info.eventID
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(espnSport)/teams/\(info.teamID)/roster"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let athleteGroups = json["athletes"] as? [[String: Any]] else {
                        return []
                    }
                    var found: [(String, String, String, String, String?)] = []
                    for groupObj in athleteGroups {
                        // MLB: grouped format — athletes are in "items" sub-array
                        if let items = groupObj["items"] as? [[String: Any]] {
                            for item in items {
                                let athleteID = (item["id"] as? String) ?? (item["id"] as? Int).map(String.init) ?? ""
                                guard neededAthleteIDs.contains(athleteID) else { continue }
                                let name = (item["fullName"] as? String) ?? (item["displayName"] as? String) ?? athleteID
                                let rawPos = (item["position"] as? [String: Any])?["abbreviation"] as? String
                                let pid = "\(idPrefix)\(athleteID)"
                                found.append((pid, name, teamAbbr, eventID, rawPos))
                            }
                        } else {
                            // Basketball: flat format — each group object IS an athlete
                            let athleteID = (groupObj["id"] as? String) ?? (groupObj["id"] as? Int).map(String.init) ?? ""
                            guard neededAthleteIDs.contains(athleteID) else { continue }
                            let name = (groupObj["fullName"] as? String) ?? (groupObj["displayName"] as? String) ?? athleteID
                            let rawPos = (groupObj["position"] as? [String: Any])?["abbreviation"] as? String
                            let pid = "\(idPrefix)\(athleteID)"
                            found.append((pid, name, teamAbbr, eventID, rawPos))
                        }
                    }
                    return found
                }
            }
            for await results in group {
                for (pid, name, teamAbbr, eventID, rawPos) in results {
                    preloadedPlayerInfo[pid] = (name: name, team: teamAbbr, gameID: eventID, position: rawPos)
                    // For two-way players: if we found athlete "mlb-39832" and "mlb-39832-sp" is a missing ID,
                    // also store the info under the -sp key with position forced to "SP"
                    let athleteIDOnly: String
                    if pid.hasPrefix("mlb-") { athleteIDOnly = String(pid.dropFirst(4)) }
                    else if pid.hasPrefix("nba-") { athleteIDOnly = String(pid.dropFirst(4)) }
                    else if pid.hasPrefix("nhl-") { athleteIDOnly = String(pid.dropFirst(4)) }
                    else if pid.hasPrefix("ncaam-") { athleteIDOnly = String(pid.dropFirst(6)) }
                    else { athleteIDOnly = "" }
                    if !athleteIDOnly.isEmpty, let allPIDs = athleteIDToPIDs[athleteIDOnly] {
                        for originalPID in allPIDs where originalPID != pid {
                            // This is a -sp variant — force position to SP
                            let overridePos = originalPID.hasSuffix("-sp") ? "SP" : rawPos
                            preloadedPlayerInfo[originalPID] = (name: name, team: teamAbbr, gameID: eventID, position: overridePos)
                        }
                    }
                }
            }
        }

        let foundCount = missingIDs.filter { preloadedPlayerInfo[$0] != nil }.count
        if foundCount > 0 {
            print("[DFS] Pre-loaded \(foundCount)/\(missingIDs.count) missing player info from team rosters")
        }
    }

    /// Fetch a single missing player's info from ESPN to restore them into the players array.
    /// Always returns a DFSPlayer — uses fallbackName from the saved entry if ESPN fails.
    private func fetchMissingPlayer(pid: String, fallbackName: String? = nil, salary: Int = 0) async -> DFSPlayer {
        // Two-way player SP entries have IDs like "mlb-39832-sp" — detect and strip suffix
        let isTwoWaySP = pid.hasSuffix("-sp")
        // Two-way batter detection: if "mlb-39832-sp" is also selected, this is the batter half
        let isTwoWayBatter = !isTwoWaySP && selectedPlayerIDs.contains(pid + "-sp")
        // Ensure a reasonable minimum salary so players never show $0
        // (pitcher vs batter distinction is refined after position is known below)
        let minSalary: Int
        if pid.hasPrefix("mlb-") { minSalary = isTwoWaySP ? 6000 : 2000 }
        else if pid.hasPrefix("nhl-") { minSalary = 3000 }
        else if pid.hasPrefix("ncaam-") { minSalary = 3500 }
        else if pid.hasPrefix("epl-") || pid.hasPrefix("ucl-") { minSalary = 3500 }
        else if pid.hasPrefix("pga-") { minSalary = 6000 }
        else { minSalary = 3500 } // NBA
        let salary = max(salary, minSalary)
        /// Maps a raw ESPN position abbreviation to a DFS-friendly position based on sport prefix.
        func mapPosition(_ raw: String?) -> String {
            guard let raw, raw != "—" else { return "UTIL" }
            let upper = raw.uppercased()
            if pid.hasPrefix("mlb-") {
                // Two-way batter: ESPN says "SP" but this is the batter entry → use UTIL
                if isTwoWayBatter && upper == "SP" { return "UTIL" }
                switch upper {
                case "SP": return "SP"
                case "RP", "CP": return "RP"
                case "C": return "C"
                case "1B": return "1B"
                case "2B": return "2B"
                case "3B": return "3B"
                case "SS": return "SS"
                case "LF", "CF", "RF", "OF": return "OF"
                case "DH": return "UTIL"
                default: return "UTIL"
                }
            } else if pid.hasPrefix("nhl-") {
                switch upper {
                case "C": return "C"
                case "LW", "RW", "F": return "W"
                case "D": return "D"
                case "G": return "G"
                default: return "C"
                }
            } else {
                // NBA / NCAAM — positions are already DFS-ready (PG, SG, SF, PF, C)
                return upper.isEmpty ? "UTIL" : upper
            }
        }

        // Bump MLB pitcher salary to $6K floor (SP/RP are worth more than position players)
        func pitcherAdjusted(_ sal: Int, position: String) -> Int {
            if pid.hasPrefix("mlb-"), (position == "SP" || position == "RP") { return max(sal, 6000) }
            return sal
        }

        // Try preloaded roster info first (has name, team, gameID, and position)
        if let info = preloadedPlayerInfo[pid] {
            let pos = mapPosition(info.position)
            return DFSPlayer(id: pid, name: info.name, team: info.team, position: pos, salary: pitcherAdjusted(salary, position: pos), projectedPoints: 0, gameID: info.gameID)
        }
        
        // Try live stats — for -sp entries, also check the base ID since live stats may be keyed either way
        if let stats = livePlayerStats[pid] {
            let pos = isTwoWaySP ? "SP" : mapPosition(nil)
            return DFSPlayer(id: pid, name: stats.name, team: "—", position: pos, salary: salary, projectedPoints: 0)
        }
        if isTwoWaySP {
            let baseID = String(pid.dropLast(3))
            if let stats = livePlayerStats[baseID] {
                return DFSPlayer(id: pid, name: stats.name, team: "—", position: "SP", salary: salary, projectedPoints: 0)
            }
        }
        
        // For -sp entries, derive the real PID to use for ESPN lookups
        let lookupPID = isTwoWaySP ? String(pid.dropLast(3)) : pid
        
        // Determine ESPN sport path from player ID prefix
        let espnSport: String
        let athleteID: String
        if lookupPID.hasPrefix("nba-") {
            espnSport = "basketball/nba"
            athleteID = String(lookupPID.dropFirst(4))
        } else if lookupPID.hasPrefix("ncaam-") {
            espnSport = "basketball/mens-college-basketball"
            athleteID = String(lookupPID.dropFirst(6))
        } else if lookupPID.hasPrefix("mlb-") {
            espnSport = "baseball/mlb"
            athleteID = String(lookupPID.dropFirst(4))
        } else if lookupPID.hasPrefix("nhl-") {
            espnSport = "hockey/nhl"
            athleteID = String(lookupPID.dropFirst(4))
        } else if lookupPID.hasPrefix("ufc-") {
            espnSport = "mma/ufc"
            athleteID = String(lookupPID.dropFirst(4))
        } else if lookupPID.hasPrefix("nfl-") {
            espnSport = "football/nfl"
            athleteID = String(lookupPID.dropFirst(4))
        } else if lookupPID.hasPrefix("cfb-") {
            espnSport = "football/college-football"
            athleteID = String(lookupPID.dropFirst(4))
        } else if lookupPID.hasPrefix("pga-") {
            // PGA uses a separate fetch chain with golf-specific endpoints
            return await fetchMissingGolfPlayer(pid: pid, salary: salary, fallbackName: fallbackName)
        } else {
            let name = fallbackName ?? "Player #\(pid)"
            return DFSPlayer(id: pid, name: name, team: "—", position: "UTIL", salary: salary, projectedPoints: 0)
        }
        
        // Helper: look up gameID from team abbreviation using slateGames
        func gameIDForTeam(_ abbr: String) -> String? {
            slateGames.first(where: { $0.homeTeam == abbr || $0.awayTeam == abbr })?.id
        }
        
        // Try standard ESPN athlete endpoint
        if let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(espnSport)/athletes/\(athleteID)"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = json["displayName"] as? String ?? fallbackName ?? pid
            let team = (json["team"] as? [String: Any])?["abbreviation"] as? String ?? "—"
            let rawPos = (json["position"] as? [String: Any])?["abbreviation"] as? String
            let pos = isTwoWaySP ? "SP" : mapPosition(rawPos)
            return DFSPlayer(id: pid, name: name, team: team, position: pos, salary: pitcherAdjusted(salary, position: pos), projectedPoints: 0, gameID: gameIDForTeam(team))
        }
        
        // Fallback: try the v3 athlete endpoint (works for some sports where the v2 endpoint returns 404)
        if let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/\(espnSport)/athletes/\(athleteID)"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // v3 endpoint nests athlete info under "athlete" key
            let athlete = json["athlete"] as? [String: Any] ?? json
            if let name = athlete["displayName"] as? String {
                let team = (athlete["team"] as? [String: Any])?["abbreviation"] as? String ?? "—"
                let rawPos = (athlete["position"] as? [String: Any])?["abbreviation"] as? String
                let pos = isTwoWaySP ? "SP" : mapPosition(rawPos)
                return DFSPlayer(id: pid, name: name, team: team, position: pos, salary: pitcherAdjusted(salary, position: pos), projectedPoints: 0, gameID: gameIDForTeam(team))
            }
        }
        
        // All ESPN calls failed — use saved name from entry, or a readable fallback
        let name = fallbackName ?? "Player #\(athleteID)"
        print("[DFS] ESPN fetch failed for \(pid) — using fallback name: \(name)")
        let fallbackPos = isTwoWaySP ? "SP" : mapPosition(nil)
        return DFSPlayer(id: pid, name: name, team: "—", position: fallbackPos, salary: salary, projectedPoints: 0)
    }

    private func normalizedError(_ error: Error) -> String {
        error.localizedDescription
    }

    // MARK: - PGA Bot Lineup Generation

    /// Generate a salary-aware golf bot lineup with no position constraints.
    private func generateGolfBotLineup(from players: [DFSPlayer], salaryCap: Int, lineupSize: Int) -> [String] {
        let eligible = players.filter { ($0.injuryStatus ?? "") != "WD" }
        guard eligible.count >= lineupSize else {
            return players.shuffled().prefix(lineupSize).map(\.id)
        }

        let minSpend = Int(Double(salaryCap) * 0.97)
        let upgradeTarget = Int(Double(salaryCap) * 0.99)
        let cheapestSalary = eligible.map(\.salary).min() ?? 3000
        let botStyle = Int.random(in: 0..<3)

        for _ in 0..<30 {
            var selected: [DFSPlayer] = []
            var budgetLeft = salaryCap
            var usedIDs = Set<String>()
            var pool = eligible

            for pickIndex in 0..<lineupSize {
                let slotsLeft = lineupSize - pickIndex
                let slotsAfter = slotsLeft - 1
                let reserveForRest = slotsAfter * cheapestSalary
                let maxForThisPick = budgetLeft - reserveForRest
                let affordable = pool.filter { $0.salary <= maxForThisPick }
                guard !affordable.isEmpty else { break }
                let targetSalary = slotsLeft > 0 ? budgetLeft / slotsLeft : budgetLeft
                let isEarlyPick = pickIndex < 2

                let weights: [Double] = affordable.map { p in
                    let proj = max(p.projectedPoints, 1.0)
                    let value = proj / max(Double(p.salary) / 1000.0, 0.1)
                    var w: Double
                    switch botStyle {
                    case 1: w = pow(value, 2.5)
                    case 2: w = pow(proj, 3.0)
                    default: w = pow(proj, 2.0) * pow(max(value, 0.1), 0.5)
                    }
                    if isEarlyPick {
                        let salaryFrac = Double(p.salary - cheapestSalary) / max(Double(salaryCap / lineupSize - cheapestSalary), 1.0)
                        if salaryFrac < 0.3 { w *= 0.3 }
                    } else {
                        let salaryRatio = Double(p.salary) / max(Double(targetSalary), 1.0)
                        if salaryRatio >= 0.85 && salaryRatio <= 1.15 { w *= 5.0 }
                        else if salaryRatio >= 0.7 && salaryRatio < 0.85 { w *= 1.5 }
                        else if salaryRatio < 0.5 { w *= 0.05 }
                        else if salaryRatio > 1.3 { w *= 0.3 }
                    }
                    return max(w, 0.001)
                }

                let totalW = weights.reduce(0, +)
                guard totalW > 0 else { break }
                var roll = Double.random(in: 0..<totalW)
                var pick = affordable[0]
                for (i, w) in weights.enumerated() {
                    roll -= w
                    if roll <= 0 { pick = affordable[i]; break }
                }
                selected.append(pick)
                budgetLeft -= pick.salary
                usedIDs.insert(pick.id)
                pool.removeAll { $0.id == pick.id }
            }

            guard selected.count == lineupSize else { continue }
            let totalSpent = salaryCap - budgetLeft
            guard totalSpent <= salaryCap else { continue }

            if totalSpent < upgradeTarget {
                let sortedByPrice = selected.enumerated().sorted { $0.element.salary < $1.element.salary }
                for (idx, cheapPlayer) in sortedByPrice {
                    let currentSpent = selected.reduce(0) { $0 + $1.salary }
                    if currentSpent >= upgradeTarget { break }
                    let slack = salaryCap - currentSpent
                    let upgradeCandidates = eligible.filter { candidate in
                        !usedIDs.contains(candidate.id)
                        && candidate.salary > cheapPlayer.salary
                        && candidate.salary <= cheapPlayer.salary + slack
                    }
                    if let upgrade = upgradeCandidates.min(by: {
                        let newSpent1 = currentSpent - cheapPlayer.salary + $0.salary
                        let newSpent2 = currentSpent - cheapPlayer.salary + $1.salary
                        return abs(salaryCap - newSpent1) < abs(salaryCap - newSpent2)
                    }) {
                        usedIDs.remove(cheapPlayer.id)
                        usedIDs.insert(upgrade.id)
                        selected[idx] = upgrade
                    }
                }
            }

            let finalSpent = selected.reduce(0) { $0 + $1.salary }
            if finalSpent >= minSpend && finalSpent <= salaryCap {
                return selected.map(\.id)
            }
        }

        // Fallback: deterministic greedy approach
        var fallback: [DFSPlayer] = []
        var fb_budget = salaryCap
        var fb_pool = eligible.sorted { $0.projectedPoints > $1.projectedPoints }
        for _ in 0..<lineupSize {
            let slotsLeft = lineupSize - fallback.count
            let slotsAfter = slotsLeft - 1
            let reserveRest = slotsAfter * cheapestSalary
            let targetPerSlot = slotsLeft > 0 ? fb_budget / slotsLeft : fb_budget
            let affordable = fb_pool.filter { $0.salary <= fb_budget - reserveRest }
            guard !affordable.isEmpty else { break }
            let best = affordable.min(by: { abs($0.salary - targetPerSlot) < abs($1.salary - targetPerSlot) })!
            fallback.append(best)
            fb_budget -= best.salary
            fb_pool.removeAll { $0.id == best.id }
        }
        return fallback.map(\.id)
    }

    // MARK: - PGA Missing Player Fetch

    /// Fetch a single missing golfer's info from ESPN to restore them into the players array.
    private func fetchMissingGolfPlayer(pid: String, salary: Int = 6000, fallbackName: String? = nil) async -> DFSPlayer {
        let rawID = pid.hasPrefix("pga-") ? String(pid.dropFirst(4)) : pid
        // Tournament ID is "pga-{eventID}-{fieldSize}" — extract just the ESPN event ID
        let pgaGameAfterPrefix = tournament?.id.replacingOccurrences(of: "pga-", with: "") ?? ""
        let gameID = pgaGameAfterPrefix.components(separatedBy: "-").first ?? pgaGameAfterPrefix

        // Try the ESPN athlete endpoint
        if let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/golf/pga/athletes/\(rawID)"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let athlete = json["athlete"] as? [String: Any] {
            let name = athlete["displayName"] as? String ?? athlete["fullName"] as? String ?? fallbackName ?? "Golfer \(rawID)"
            let country = (athlete["flag"] as? [String: Any])?["alt"] as? String ?? ""
            return DFSPlayer(id: pid, name: name, team: country, position: "G",
                             salary: salary, projectedPoints: Double(salary) / 1000.0, gameID: gameID)
        }

        // Fallback: try the overview endpoint
        if let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/golf/pga/athletes/\(rawID)/overview"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let athlete = json["athlete"] as? [String: Any] {
            let name = athlete["displayName"] as? String ?? athlete["fullName"] as? String ?? fallbackName ?? "Golfer \(rawID)"
            let country = (athlete["flag"] as? [String: Any])?["alt"] as? String ?? ""
            return DFSPlayer(id: pid, name: name, team: country, position: "G",
                             salary: salary, projectedPoints: Double(salary) / 1000.0, gameID: gameID)
        }

        // Try the PGA scoreboard
        if let sbURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard"),
           let (sbData, sbResp) = try? await URLSession.shared.data(from: sbURL),
           let sbHTTP = sbResp as? HTTPURLResponse, (200..<300).contains(sbHTTP.statusCode),
           let sbJSON = try? JSONSerialization.jsonObject(with: sbData) as? [String: Any],
           let events = sbJSON["events"] as? [[String: Any]] {
            for event in events {
                guard let competitions = event["competitions"] as? [[String: Any]] else { continue }
                for comp in competitions {
                    guard let competitors = comp["competitors"] as? [[String: Any]] else { continue }
                    for competitor in competitors {
                        guard let cid = competitor["id"] as? String, cid == rawID,
                              let athleteObj = competitor["athlete"] as? [String: Any] else { continue }
                        let name = athleteObj["displayName"] as? String ?? fallbackName ?? "Golfer #\(rawID)"
                        let country = (athleteObj["flag"] as? [String: Any])?["alt"] as? String ?? ""
                        return DFSPlayer(id: pid, name: name, team: country, position: "G",
                                         salary: salary, projectedPoints: Double(salary) / 1000.0, gameID: gameID)
                    }
                }
            }
        }

        let name = fallbackName ?? "Golfer #\(rawID)"
        return DFSPlayer(id: pid, name: name, team: "", position: "G",
                         salary: salary, projectedPoints: Double(salary) / 1000.0, gameID: gameID)
    }

    /// Deduplicates history entries: for each tournament, keeps at most one entry per logical lineup.
    /// Handles mismatched lineupNumber states (nil vs numbered) by matching on points.
    private func deduplicatedHistory(_ value: [DFSResult]) -> [DFSResult] {
        var tournamentGroups: [String: [DFSResult]] = [:]
        var noTournament: [DFSResult] = []
        for entry in value {
            guard let tid = entry.tournamentId else {
                noTournament.append(entry)
                continue
            }
            tournamentGroups[tid, default: []].append(entry)
        }

        var deduped: [DFSResult] = noTournament
        for (_, entries) in tournamentGroups {
            // Treat entries with unreasonable lineupNumbers (>20) as unnumbered — these are
            // corrupted values from bot indices or rank numbers that leaked into entry names.
            let numbered = entries.filter { if let ln = $0.lineupNumber { return ln >= 1 && ln <= 20 } else { return false } }
            let unnumbered = entries.filter { if let ln = $0.lineupNumber { return ln < 1 || ln > 20 } else { return true } }

            if numbered.isEmpty {
                // No numbered entries — keep best unnumbered, sanitize corrupted lineupNumber
                if let best = unnumbered.max(by: { entryQuality($0) < entryQuality($1) }) {
                    if let ln = best.lineupNumber, (ln < 1 || ln > 20) {
                        deduped.append(DFSResult(
                            id: best.id, tournamentTitle: best.tournamentTitle,
                            rank: best.rank, totalEntries: best.totalEntries,
                            lineupPoints: best.lineupPoints, rrDelta: best.rrDelta,
                            loggedAt: best.loggedAt, tournamentId: best.tournamentId,
                            lineupNumber: nil
                        ))
                    } else {
                        deduped.append(best)
                    }
                }
            } else {
                // Deduplicate numbered entries by lineupNumber, keeping the best quality
                var byLineup: [Int: DFSResult] = [:]
                for entry in numbered {
                    let ln = entry.lineupNumber!
                    if let existing = byLineup[ln] {
                        byLineup[ln] = entryQuality(entry) > entryQuality(existing) ? entry : existing
                    } else {
                        byLineup[ln] = entry
                    }
                }
                deduped.append(contentsOf: byLineup.values)

                // Only keep unnumbered entries that don't match any numbered entry by points
                let numberedPoints = Set(byLineup.values.map { Int($0.lineupPoints * 10) })
                for entry in unnumbered {
                    let rounded = Int(entry.lineupPoints * 10)
                    if !numberedPoints.contains(rounded) && !numberedPoints.contains(rounded + 1) && !numberedPoints.contains(rounded - 1) {
                        deduped.append(entry)
                    }
                }
            }
        }

        deduped.sort { $0.loggedAt > $1.loggedAt }
        return deduped
    }

    private func encodedDFSHistory(_ value: [DFSResult]) -> Data {
        let cleaned = deduplicatedHistory(value)
        return (try? JSONEncoder().encode(Array(cleaned.prefix(500)))) ?? Data()
    }

    /// Public entry point for one-time cleanup of raw history data (used by ContentView on init).
    func encodedDFSHistoryFromRaw(_ rawData: Data) -> Data {
        guard let decoded = try? JSONDecoder().decode([DFSResult].self, from: rawData) else { return rawData }
        return encodedDFSHistory(decoded)
    }

    /// Quality score for deduplication — higher means better data.
    private func entryQuality(_ entry: DFSResult) -> Int {
        var score = 0
        if entry.lineupNumber != nil && entry.lineupNumber! >= 1 && entry.lineupNumber! <= 20 { score += 10 }
        if entry.totalEntries >= 2000 { score += 5 }
        if entry.rank > 0 && entry.rank < entry.totalEntries { score += 3 }
        if entry.lineupPoints > 0 { score += 2 }
        // Penalize stale-looking ranks (rank near totalEntries boundary from Supabase 1000—row limit)
        if entry.totalEntries > 100 && (entry.rank == 1001 || entry.rank == 1002) { score -= 8 }
        return score
    }

    func formatSalary(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Extract entry count from tournament ID suffix.
    /// IDs like "nba-20260506-1000", "nba-20260506-sg-401234567-100", "nba-20260506-eve-500"
    /// have the entry count as the last numeric component. Legacy IDs without a size suffix default to 1000.
    static func entryCountFromTournamentID(_ tournamentID: String) -> Int {
        // Strip instance suffix (e.g., "-i2", "-i3") before parsing
        var id = tournamentID
        if let range = id.range(of: #"-i\d+$"#, options: .regularExpression) {
            id.removeSubrange(range)
        }
        let parts = id.components(separatedBy: "-")
        if let last = parts.last, let size = Int(last) {
            let validSizes = [2, 3, 5, 10, 100, 500, 1000, 2000]
            if validSizes.contains(size) { return size }
        }
        return 1000 // default for legacy IDs
    }
}
