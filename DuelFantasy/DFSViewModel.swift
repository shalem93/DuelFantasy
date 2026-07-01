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
        // Skip past-settled tournaments when picking the default. PGA
        // synthesizes past-week events into `tournaments` so they render
        // as Active Contests cards until settled — once settled they
        // should stop counting as the "current" event, otherwise the
        // PGA tab shows a stale locked-view for Memorial on Monday when
        // the upcoming RBC slate hasn't loaded yet.
        return tournaments.first(where: { !isTournamentSettledOrSibling($0.id) })
    }

    /// Treat a PGA tournament as settled if the user has settled ANY size
    /// variant of the same event. The PGA slate provider emits 5 variants
    /// per event (`pga-<eventID>-2`, `-3`, `-5`, `-10`, `-2000`); the user
    /// typically only enters one, so only that variant gets explicitly
    /// settled. Without this rollup, the unentered variants stayed in
    /// `tournaments` as unsettled-but-locked phantoms and forced the PGA
    /// tab into the "No Active Entries — this week's tournament has
    /// locked" view on Monday after Memorial finished. Exposed `internal`
    /// so DFSContestView's active-contest filters can use it too.
    func isTournamentSettledOrSibling(_ tid: String) -> Bool {
        if settledTournaments.contains(tid) { return true }
        // Only roll up PGA tids — other sports use unique IDs per slate.
        guard tid.hasPrefix("pga-") else { return false }
        let baseID = pgaBaseEventID(from: tid)
        guard !baseID.isEmpty else { return false }
        return settledTournaments.contains(where: { pgaBaseEventID(from: $0) == baseID && $0.hasPrefix("pga-") })
    }

    /// Slate identity for de-duping a contest across date buckets. A single-game
    /// (`-sg-`) contest can exist under TWO date prefixes for the SAME game — a
    /// midnight kickoff gets bucketed under both the prior day and the next day
    /// (ET vs UTC boundary). Settlement grades it under one date while the live
    /// card's entry sits under the other, so an EXACT tid match misses it and
    /// the graded contest keeps showing as a LIVE card. Identity drops the date
    /// prefix (for SG) and the trailing entry-count so all variants collapse:
    ///   `wc-20260616-sg-401-2000` and `wc-20260617-sg-401-100` → `wc-sg-401`.
    static func slateIdentity(_ tid: String) -> String {
        var id = tid
        if let r = id.range(of: #"-i\d+$"#, options: .regularExpression) { id.removeSubrange(r) }
        if let sgRange = id.range(of: "-sg-") {
            let sport = id.components(separatedBy: "-").first ?? ""
            let afterSG = String(id[sgRange.upperBound...])
            let gameID = afterSG.components(separatedBy: "-").first ?? afterSG
            return "\(sport)-sg-\(gameID)"
        }
        let parts = id.components(separatedBy: "-")
        if let last = parts.last, let n = Int(last),
           [2, 3, 5, 10, 100, 500, 1000, 2000].contains(n) {
            return parts.dropLast().joined(separator: "-")
        }
        return id
    }

    /// SINGLE SOURCE OF TRUTH for "this contest is finished — it belongs in Past
    /// Results, never as an active/live card." A contest is finished if it's in
    /// the settled set (or a PGA sibling) OR it already has a stored result in
    /// history (matched by SLATE IDENTITY, so a midnight game graded under one
    /// date excludes the same game's live card sitting under the adjacent date).
    /// Using history as a co-authority also keeps a contest from flip-flopping
    /// between a LIVE card and a Past Results row when `settledTournaments` and
    /// `dfsHistory` briefly disagree. Every active/live-card path must use this.
    func isTournamentFinished(_ tid: String) -> Bool {
        if isTournamentSettledOrSibling(tid) { return true }
        // Single-game ONLY: match history by slate identity (drops the date) so a
        // midnight game graded under one date excludes its twin under the
        // adjacent date. For NON-single-game contests, match the EXACT tid —
        // slateIdentity strips the entry count there, which would collapse
        // different-size same-day contests (mlb-…-2 vs mlb-…-2000) and let a
        // settled sibling wrongly hide a LIVE main-slate contest.
        if tid.contains("-sg-") {
            let identity = Self.slateIdentity(tid)
            return dfsHistory.contains { $0.tournamentId.map(Self.slateIdentity) == identity }
        }
        return dfsHistory.contains { $0.tournamentId == tid }
    }

    /// Extracts the ESPN event ID from a PGA tournament tid by stripping
    /// the `pga-` prefix and the trailing `-<size>` suffix.
    /// `pga-401811949-2000` → `401811949`
    private func pgaBaseEventID(from tid: String) -> String {
        guard tid.hasPrefix("pga-") else { return tid }
        let afterPrefix = tid.dropFirst("pga-".count)
        let parts = afterPrefix.split(separator: "-")
        return parts.first.map(String.init) ?? String(afterPrefix)
    }
    /// True for a PGA entry that belongs to a PAST/other event — not the one on
    /// the active slate. PGA ids are event-based with no date, so past events
    /// (US Open, Travelers, a Monday-playoff week, …) linger in
    /// `userEntryRecords`/`enteredTournamentIDs` while their results cycle through
    /// settlement. That inflated "Lineups Today" (2/20 → 8/20) and kept old
    /// contests showing as Active for a fresh week the user never entered. The
    /// lobby counter + active list treat these as not-current. Non-PGA sports
    /// (date-based ids, scoped on load) and an unloaded slate return false.
    func isStalePGAEntryEvent(_ tid: String) -> Bool {
        guard sport == "PGA", let activeEvent = slateGames.first?.id else { return false }
        return pgaBaseEventID(from: tid) != activeEvent
    }
    /// Per-game single-game player pools with adjusted salaries, keyed by ESPN event ID
    var singleGamePlayers: [String: [DFSPlayer]] = [:]
    /// Tracks which tournament IDs the user has entered today (for entry limit enforcement)
    var enteredTournamentIDs: Set<String> = []
    /// Cached entry records for all of the user's entries today (keyed by tournament ID).
    /// Each tournament can have multiple lineups, stored as an array.
    var userEntryRecords: [String: [DFSEntryRecord]] = [:]
    /// Canonical slate-wide player salaries captured at contest creation time, keyed by
    /// tournament ID. Used to render every lineup (yours + every bot's) with the exact
    /// prices that were offered during lineup building, regardless of later slate refreshes.
    var tournamentPlayerSalaries: [String: [String: Int]] = [:]
    /// Maximum number of lineups per tournament
    let maxLineupsPerTournament: Int = 5
    /// Maximum number of lineups per sport per day
    let maxLineupsPerDay: Int = 20
    /// Total lineups submitted today across all tournaments. Settled
    /// tournaments (and PGA-sibling-settled variants) are excluded so the
    /// "Lineups Today 2/20" badge doesn't keep flashing old Memorial
    /// entries the morning after the tournament finished.
    var totalLineupsToday: Int {
        userEntryRecords.reduce(0) { running, kv in
            let tid = kv.key
            guard !isTournamentSettledOrSibling(tid) else { return running }
            // Skip past-event PGA lineups (see isStalePGAEntryEvent) so the count
            // sits at 0 for a fresh week and doesn't jump as old events cycle.
            guard !isStalePGAEntryEvent(tid) else { return running }
            return running + kv.value.count
        }
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
        // Reset the player-list filters too. Starting a new lineup in the SAME
        // tournament skips selectTournament's reset (it early-returns on an
        // unchanged ID), so a position/game pill left selected from the last
        // lineup (e.g. MID) would carry over and hide the rest of the pool.
        selectedPositionFilter = nil
        selectedGameFilter = nil
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
    /// When the in-flight loadSlate started — lets retries take over a wedged load.
    private var slateLoadStartedAt: Date? = nil
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
    /// Sport-date prefix (e.g. "mlb-20260610") of the slate whose scores are
    /// currently in `livePlayerPoints`. Player IDs are stable across days, so
    /// without this tag a consumer can't tell today's points from yesterday's
    /// leftovers — which made private contests show prior-day scores before
    /// their own games even started.
    var livePlayerPointsSlatePrefix: String? = nil
    /// Server-persisted lock times keyed by tournament ID. Used as the lock-time
    /// fallback when the live slate failed to build (no `slateGames`) — without
    /// it, slate-less contests (e.g. a single-game night DK already pulled)
    /// compute a `.distantFuture` lock and get stuck showing "Upcoming" forever
    /// even after their game ended.
    var serverLockTimes: [String: Date] = [:]
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

    // MARK: - Private Contests
    var myPrivateContests: [DFSPrivateContest] = []
    var privateContestMembers: [UUID: [DFSPrivateContestMember]] = [:]
    var privateContestEntries: [UUID: [DFSPrivateContestEntry]] = [:]
    var privateContestLeaderboards: [UUID: [DFSPrivateContestLeaderboardRow]] = [:]
    var privateContestError: String?
    var isCreatingPrivateContest: Bool = false
    var isJoiningPrivateContest: Bool = false
    /// When set, the lineup builder is submitting to this private contest
    /// instead of the public dfs_entries flow. Cleared on submit/exit.
    var activePrivateContest: DFSPrivateContest?

    /// Cached player metadata from roster preload: playerID → (name, team abbreviation, gameID, position)
    private var preloadedPlayerInfo: [String: (name: String, team: String, gameID: String, position: String?)] = [:]

    /// Public accessor for the cached player name by ID. Used by views to
    /// resolve names for IDs that aren't in the current active pool (e.g.,
    /// DNP'd players whose past-contest lineups still reference them).
    func cachedPlayerName(for playerID: String) -> String? {
        if let info = preloadedPlayerInfo[playerID], !info.name.isEmpty { return info.name }
        // Live scoring data carries the athlete's display name — when a
        // player isn't in today's lobby pool (e.g. yesterday's MLB pitcher
        // showing up in a past private-contest standings view), this is
        // often the only source that has their name.
        if let liveName = livePlayerStats[playerID]?.name, !liveName.isEmpty, liveName != playerID {
            return liveName
        }
        if let pastName = pastTournamentPlayerStats[playerID]?.name, !pastName.isEmpty, pastName != playerID {
            return pastName
        }
        // MLB two-way SP entries store their name under the base batter ID;
        // strip the "-sp" suffix and retry the lookups.
        if playerID.hasSuffix("-sp") {
            let baseID = String(playerID.dropLast(3))
            if let info = preloadedPlayerInfo[baseID], !info.name.isEmpty { return info.name }
            if let liveName = livePlayerStats[baseID]?.name, !liveName.isEmpty, liveName != baseID {
                return liveName
            }
            if let pastName = pastTournamentPlayerStats[baseID]?.name, !pastName.isEmpty, pastName != baseID {
                return pastName
            }
        }
        return nil
    }

    /// Last-resort name resolver for a player id. Use after every other
    /// source (slate pool, ESPN athlete fetch, cached info, box-score stats)
    /// has been tried. Handles two stub-id shapes that ESPN can't resolve:
    ///   `nhl-dk-adin-hill` → "Adin Hill"
    ///   `nhl-adin-hill`    → "Adin Hill"
    /// These show up when a Phase 2.5 LineupHQ injection (a goalie / call-up
    /// ESPN's roster didn't return) gets drafted by a bot and then falls out
    /// of the slate by settlement time — without this fallback the name
    /// renders as "Unknown" / the raw id. Returns nil if the id is purely
    /// numeric (real ESPN id we genuinely can't resolve any other way).
    func decodedStubName(for playerID: String) -> String? {
        let knownPrefixes = ["nhl-", "nba-", "mlb-", "ncaam-", "wnba-", "epl-", "ucl-", "wc-", "ufc-", "nfl-", "cfb-", "pga-"]
        var tail = playerID
        for p in knownPrefixes where tail.hasPrefix(p) {
            tail = String(tail.dropFirst(p.count))
            break
        }
        if tail.hasPrefix("dk-") { tail = String(tail.dropFirst(3)) }
        // Strip MLB two-way "-sp" trailing marker
        if tail.hasSuffix("-sp") { tail = String(tail.dropLast(3)) }
        // Pure numeric → ESPN id we just don't have a name for.
        if Int(tail) != nil { return nil }
        // Must contain a hyphen to look like a slugified name.
        guard tail.contains("-") else { return nil }
        let parts = tail.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        let titled = parts.map { word -> String in
            guard let first = word.first else { return word }
            return first.uppercased() + word.dropFirst().lowercased()
        }
        let name = titled.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// Public read-only accessor for a tournament's cached leaderboard. Used
    /// by the lobby's active-contest card to show ranks for non-selected
    /// tournaments without needing the full cachedLiveRanks key.
    func cachedLeaderboard(for tournamentID: String) -> [DFSLeaderboardEntry]? {
        liveContestCache[tournamentID]?.leaderboard
    }

    /// Single source of truth for "is this tournament ready to render."
    /// Returns true only when:
    ///   1. The tournament exists in the slate.
    ///   2. The player pool for the slate is loaded (so names resolve).
    ///   3. The field is populated to the expected threshold.
    ///   4. The user's lineup is represented in the field (or no entry exists).
    /// The live view should render its real content ONLY when this is true —
    /// otherwise show a shimmer placeholder. Prevents the "raw IDs / 1 entry /
    /// locked in placeholder" intermediate states.
    func isTournamentReady(_ tid: String) -> Bool {
        guard let t = tournaments.first(where: { $0.id == tid }) else { return false }

        // 1. Player pool loaded
        let hasPool: Bool = {
            if t.isSingleGame, let gid = t.gameID {
                if let sgPool = singleGamePlayers[gid] { return !sgPool.isEmpty }
                // Fallback: check main pool for game players (activePlayers builds SG on demand)
                return players.contains(where: { $0.gameID == gid })
            }
            return !players.isEmpty
        }()
        guard hasPool else { return false }

        // 2. Field populated to a SHOWABLE threshold. We only need enough to
        // render a meaningful leaderboard — the rest can stream in via the
        // background polling cycle. Previously we required entryCount/2 which
        // for 2000-person contests means waiting for 1000 bot generations
        // (10+ seconds on device). Now we accept anything that lets us render
        // a real leaderboard, even if it's partial.
        let expected = t.entryCount
        let threshold: Int
        if expected <= 10 {
            threshold = expected             // small contests: must be full
        } else if expected <= 100 {
            threshold = 10                   // medium: 10 entries
        } else {
            threshold = 25                   // large: ~25 entries (one screenful)
        }
        let fieldCount: Int = {
            if activeTournamentID == tid {
                return fieldEntries.count
            }
            return liveContestCache[tid]?.fieldEntries.count ?? 0
        }()
        guard fieldCount >= threshold else { return false }

        // 3. If user has an entry for this tournament, ensure it's in the field
        if let entry = entryRecord(for: tid, lineupNumber: activeLineupNumber) {
            let fieldList: [DFSFieldEntry]
            if activeTournamentID == tid {
                fieldList = fieldEntries
            } else {
                fieldList = liveContestCache[tid]?.fieldEntries ?? []
            }
            let hasUserEntry = fieldList.contains(where: { $0.isCurrentUser || $0.realUserID == userID })
            guard hasUserEntry else { return false }
            _ = entry
        }

        return true
    }

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
        // Dropping the `error != nil` requirement: after Memorial
        // settles on Monday, ESPN's slate may legitimately be empty
        // (no event yet for this week) without throwing an error.
        // The view needs the "No PGA Event This Week" empty state in
        // that case, not the loading view forever.
        guard !isLoading, hasAttemptedLoad else { return false }
        return tournament == nil
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
        let basePool = computeActivePool()
        return applyCanonicalSalaries(to: normalizeMLBTwoWayBatters(basePool))
    }

    /// Re-route a two-way player's PITCHING stats from the base batter id to the
    /// "-sp" pitcher id. The live scorer puts pitching on the base id `mlb-X`
    /// whenever the athlete appears only in the boxscore's pitching category
    /// (e.g. Ohtani early in his start, before he's batted) — it can't know
    /// `mlb-X` is the batter slot. Result without this: the 1B slot renders
    /// pitching stats as a garbled batter line ("5/6.0 (4 HR)" = K/IP, ER-as-HR)
    /// and the SP slot shows 0.0. We know which ids are two-way (any `-sp` id in
    /// the pool or any lineup), so we move pitching → `mlb-X-sp` and clear the
    /// batter id (he shows 0 until he actually bats). Pitching stats carry an IP
    /// string in `minutes` (no " AB"); batting stats always have "<n> AB".
    private func correctMLBTwoWaySnapshot(_ snapshot: DFSScoreSnapshot) -> DFSScoreSnapshot {
        guard sport == "MLB" else { return snapshot }
        // Every base id that has a known "-sp" pitcher sibling somewhere.
        var twoWayBaseIDs = Set<String>()
        func collect(_ ids: [String]) {
            for id in ids where id.hasSuffix("-sp") { twoWayBaseIDs.insert(String(id.dropLast(3))) }
        }
        collect(players.map(\.id))
        collect(Array(selectedPlayerIDs))
        for e in fieldEntries { collect(e.playerIDs) }
        guard !twoWayBaseIDs.isEmpty else { return snapshot }

        var pts = snapshot.playerFantasyPoints
        var sts = snapshot.playerLiveStats
        var moved = false
        for base in twoWayBaseIDs {
            // Pitching landed on the batter id (minutes is IP, not "<n> AB").
            guard let s = sts[base], !s.minutes.contains("AB") else { continue }
            let spID = base + "-sp"
            if sts[spID] == nil { sts[spID] = s }
            if pts[spID] == nil { pts[spID] = pts[base] }
            // Batter id reflects batting only — zero it until he actually bats.
            sts[base] = nil
            pts[base] = 0
            moved = true
        }
        guard moved else { return snapshot }
        return DFSScoreSnapshot(playerFantasyPoints: pts, playerLiveStats: sts,
                                gameLiveInfo: snapshot.gameLiveInfo, allGamesFinal: snapshot.allGamesFinal)
    }

    /// MLB two-way players (Ohtani) carry a batter entry ("mlb-X") and a pitcher
    /// entry ("mlb-X-sp"). The batter must occupy a real batter slot — MLB main
    /// slates have NO UTIL slot, so a batter still typed SP/RP/P fits nothing:
    /// it shows as "SP" in the picker, can't fill the 1B the lineup needs, and
    /// gets silently dropped by `arrangeIntoSlots` (the two real pitchers take
    /// the 2 P slots and the third pitcher-typed entry falls out — which is why
    /// the batter Ohtani goes missing from the live lineup entirely).
    ///
    /// A "-sp" sibling can live in the rendered pool OR only in the saved lineup
    /// (`selectedPlayerIDs`) when the live slate rebuild typed Ohtani as a pure
    /// pitcher — so we check both. DK classifies Ohtani as 1B/OF → default 1B.
    private func normalizeMLBTwoWayBatters(_ pool: [DFSPlayer]) -> [DFSPlayer] {
        guard sport == "MLB" else { return pool }
        // Slots a two-way BATTER half must never keep: pitcher slots (a stale live
        // rebuild types Ohtani-the-batter as SP) and UTIL (MLB classic has no UTIL
        // slot, so a UTIL batter is unslottable). Both re-type to 1B.
        let wrongBatterSlots: Set<String> = ["SP", "RP", "P", "UTIL"]
        var spBaseIDs = Set(pool.filter { $0.id.hasSuffix("-sp") }.map { String($0.id.dropLast(3)) })
        spBaseIDs.formUnion(selectedPlayerIDs.filter { $0.hasSuffix("-sp") }.map { String($0.dropLast(3)) })
        guard !spBaseIDs.isEmpty else { return pool }
        return pool.map { p in
            guard spBaseIDs.contains(p.id), wrongBatterSlots.contains(p.position) else { return p }
            var fixed = DFSPlayer(id: p.id, name: p.name, team: p.team, position: "1B",
                                  salary: p.salary, projectedPoints: p.projectedPoints,
                                  gameID: p.gameID, injuryStatus: p.injuryStatus,
                                  battingOrder: p.battingOrder)
            fixed.gamesPlayed = p.gamesPlayed
            fixed.playedRecently = p.playedRecently
            fixed.isConfirmedActive = p.isConfirmedActive
            fixed.isStartingGoalie = p.isStartingGoalie
            return fixed
        }
    }

    private func computeActivePool() -> [DFSPlayer] {
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

    /// Apply the contest's frozen salary snapshot to a player pool. This keeps
    /// the picker, the chip, the cap math, and the stored entry all on the
    /// same price source — without this, raw activePlayers can drift, making
    /// a "$50K/$50K" build save as ~$53K because the canonical snapshot
    /// (used at submit time and in the lobby) differs from the live pool.
    private func applyCanonicalSalaries(to pool: [DFSPlayer]) -> [DFSPlayer] {
        guard let tid = activeTournamentID else { return pool }
        // Only apply the frozen-at-submit canonical for tournaments the user
        // has actually entered. Otherwise, lobby builds of sibling SG
        // tournaments (H2H / 5-Man / 2000-person all backed by the same
        // gameID + RG slate) get pinned to whatever stale `tournament.playerSalaries`
        // snapshot was written by an earlier session — making the same
        // Eichel/Hart/etc. price different depending on which contest you
        // navigated into. Skip the override here so the lobby always shows
        // today's raw RG prices for unentered tournaments.
        guard enteredTournamentIDs.contains(tid) else { return pool }
        let canonical: [String: Int]
        if let slate = tournamentPlayerSalaries[tid], !slate.isEmpty {
            canonical = slate
        } else if let entry = self.entryRecord(for: tid, lineupNumber: activeLineupNumber),
                  let saved = entry.lineupPlayerSalaries, !saved.isEmpty {
            canonical = saved
        } else {
            return pool
        }
        // DK's MLB batter ceiling — a real hitter never prices above this.
        let mlbBatterSlots: Set<String> = ["C", "1B", "2B", "3B", "SS", "OF", "UTIL"]
        return pool.map { p in
            guard let drafted = canonical[p.id], drafted > 0, drafted != p.salary else { return p }
            // Two-way stale-price guard: when a two-way starter's outing is
            // scratched/moved (Ohtani's Wednesday start pushed to Friday), the
            // slate re-types him SP → 1B and reprices him to his ~$6.5K hitter
            // salary — but the contest's frozen snapshot still holds his ~$10.5K
            // PITCHER price, and pinning it stamps a pitcher price on a 1B. A real
            // batter never exceeds DK's ceiling, so treat a canonical price above
            // it on a batter-slot MLB player as stale and keep the live price.
            if sport == "MLB", mlbBatterSlots.contains(p.position), drafted > 8000 {
                return p
            }
            var fixed = DFSPlayer(
                id: p.id, name: p.name, team: p.team, position: p.position,
                salary: drafted, projectedPoints: p.projectedPoints,
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

    /// Players from evening games only (6pm ET+), cached after slate load.
    var eveningPlayers: [DFSPlayer] = []

    /// Switch the active tournament and reset lineup state for the new tournament.
    func selectTournament(_ tournamentID: String, lineupNumber: Int = 1) {
        // Clear any private-contest mode by default; callers entering the
        // private flow set this back after calling selectTournament.
        activePrivateContest = nil

        let changed = activeTournamentID != tournamentID || activeLineupNumber != lineupNumber
        guard changed else { return }

        let previousTID = activeTournamentID

        // Immediately blank the leaderboard so the next view that renders
        // doesn't briefly show the PREVIOUS tournament's standings while
        // the cache restore (further down) is still in flight. The cached
        // leaderboard for the NEW tournament will populate this within the
        // same function call, but SwiftUI may evaluate body() in between.
        leaderboardEntries = []

        // Save current state to cache before switching, but ONLY if the
        // current bots actually match the previous tournament's slate
        // (right lineup size AND right player IDs).
        if let prevID = previousTID, fieldGenerated, !fieldEntries.isEmpty {
            if botsMatchTournament(fieldEntries, tournamentID: prevID) {
                liveContestCache[prevID] = LiveContestCache(
                    fieldEntries: fieldEntries,
                    leaderboard: leaderboardEntries,
                    remoteEntries: remoteEntries,
                    profileNames: remoteProfileNames,
                    fieldGenerated: true
                )
            } else {
                print("[DFS-\(sport)] Refusing to cache \(prevID) — current fieldEntries don't match its tournament")
            }
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
            // Detect single-game from the tournament ID so MVP 1.5x scoring
            // still applies when the slate rotated this tournament out and we
            // had to synthesize a stub. Without this, the leaderboard for a
            // resumed SG contest would compute every bot's MVP at 1.0x and
            // the total ends up 1.5× too low compared to per-row points.
            let isSGFromID = tournamentID.contains("-sg-")
            // UFC main slates are captain mode (MVP + 5 FLEX) — DK only runs
            // UFC as showdown. Their tid is `ufc-<date>-<size>` with no "-sg-",
            // so without this they'd synthesize as a classic slate and the
            // leaderboard would score the MVP at 1x instead of 1.5x (the
            // captain salaries were already charged at 1.5x, so the field looks
            // like it under-spent). Treat any synthesized UFC tournament as
            // captain mode so scoring matches how it was drafted.
            let isUFCCaptain = sport == "UFC"
            let isCaptainScoring = isSGFromID || isUFCCaptain
            let synthGameID: String? = {
                guard isSGFromID else { return nil }
                // Format: "<sport>-<YYYYMMDD>-sg-<gameID>-<entryCount>"
                let parts = tournamentID.split(separator: "-")
                guard let sgIdx = parts.firstIndex(of: "sg"), sgIdx + 1 < parts.count else { return nil }
                return String(parts[sgIdx + 1])
            }()
            let synthLineupSize: Int = {
                // Prefer the user's own saved entry — guessing wrong here makes
                // every saved bot look "wrong shape" (e.g. a 10-player MLB main
                // contest synthesized at 7) and the whole bot field gets
                // rejected on load.
                if let entry = userEntryRecords[tournamentID]?.first,
                   !entry.lineupPlayerIDs.isEmpty {
                    return entry.lineupPlayerIDs.count
                }
                if sport == "PGA" { return 6 }
                if isCaptainScoring { return 6 } // MVP + 5 FLEX
                return 7
            }()
            let syntheticTournament = DFSTournament(
                id: tournamentID,
                title: syntheticTitle,
                league: sport,
                entryCount: entryCount,
                lineupSize: synthLineupSize,
                salaryCap: 50000,
                rosterSlots: isCaptainScoring ? ["MVP", "FLEX", "FLEX", "FLEX", "FLEX", "FLEX"] : nil,
                isSingleGame: isCaptainScoring,
                // UFC captain mode is still a "main" slate (one card), not a
                // per-game single game — only `-sg-` tids are .singleGame.
                tournamentType: isSGFromID ? .singleGame : .main,
                gameID: synthGameID
            )
            tournaments.append(syntheticTournament)
        }

        // Validate cache before restoring — same matching check applied on write.
        if let cached = liveContestCache[tournamentID],
           !botsMatchTournament(cached.fieldEntries, tournamentID: tournamentID) {
            print("[DFS-\(sport)] Discarding contaminated cache for \(tournamentID) — bots don't match this tournament's shape")
            discardContaminatedCache(tournamentID)
            _ = cached
        }

        // Try to restore from cache (instant switch)
        if let cached = liveContestCache[tournamentID] {
            // Rebuild the user's rows from their saved lineups — one row per
            // lineup, each with its OWN players. The old code mapped EVERY
            // user row to the ACTIVE lineup's player IDs, so a multi-entry
            // user saw the same lineup pinned twice (identical scores)
            // instead of their two distinct entries.
            let myRecords = userEntryRecords[tournamentID] ?? []
            if myRecords.isEmpty {
                fieldEntries = cached.fieldEntries
            } else {
                var rebuilt = cached.fieldEntries.filter { !($0.isCurrentUser || $0.realUserID == userID) }
                let myName = profileName.isEmpty ? "You" : profileName
                let showLN = myRecords.count > 1
                for (idx, rec) in myRecords.enumerated().reversed() {
                    let ln = rec.lineupNumber ?? (idx + 1)
                    rebuilt.insert(DFSFieldEntry(
                        id: UUID(uuidString: rec.id) ?? UUID(),
                        name: showLN ? "\(myName) #\(ln)" : myName,
                        playerIDs: rec.lineupPlayerIDs,
                        isCurrentUser: true,
                        isRealUser: true,
                        realUserID: userID
                    ), at: 0)
                }
                fieldEntries = rebuilt
            }
            leaderboardEntries = cached.leaderboard
            remoteEntries = cached.remoteEntries
            remoteProfileNames = cached.profileNames
            // Honor the cache's own `fieldGenerated` flag. Pre-cache writes
            // partial caches (just enough to clear isTournamentReady's
            // shimmer threshold) so the lobby can paint quickly; the rest
            // of the bots are still pending. Setting this unconditionally
            // to `true` would tell refreshLive "you don't need to pad" and
            // the detail page would show a 25-row leaderboard for a
            // 2000-entry contest. By honoring the flag, refreshLive's
            // existing chunked padding flow fills the field on tap-in.
            fieldGenerated = cached.fieldGenerated

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
        // Only import players that exist in the current pool — stale entries
        // (or pool changes since submit) would otherwise fill slots with
        // undeletable $0 stubs like "pga-5467".
        let poolIDs = Set(activePlayers.map(\.id))
        let savedIDs = entry.lineupPlayerIDs
        // EXCEPTION — MLB two-way pairs (Ohtani: "mlb-X" batter + "mlb-X-sp"
        // pitcher). The live slate rebuild sometimes regenerates only ONE half
        // of the pair, so the other half isn't in the current pool. Pruning it
        // would silently delete a player the user drafted and paid for (the
        // lineup drops to 9, salary falls by the missing player's price, and the
        // survivor flip-flops between SP and 1B). Keep the missing half whenever
        // its sibling is also in this lineup — the selectedPlayers stub path
        // materializes it with the saved salary and correct slot.
        func hasTwoWaySibling(_ id: String) -> Bool {
            guard sport == "MLB" else { return false }
            if id.hasSuffix("-sp") { return savedIDs.contains(String(id.dropLast(3))) }
            return savedIDs.contains(id + "-sp")
        }
        // GENERAL keep-path (covers soccer/WC and every other sport). When the
        // live pool is still loading or was partially rebuilt, a player the user
        // drafted (e.g. Mbappé) may be momentarily absent from `activePlayers`.
        // Pruning him here permanently deletes him from the selection — and the
        // `selectedPlayers` stub fallback never gets the chance to re-materialize
        // him because his ID never enters `selectedPlayerIDs`. Keep any saved ID
        // we can still render PROPERLY — i.e. we have both its name (from the
        // entry or preloaded info) AND its draft salary — so it shows as a named,
        // priced, removable player rather than a "$0 pga-5467"-style dead stub.
        // Genuinely stale raw IDs with no metadata are still pruned.
        let savedNamesByID: [String: String] = {
            guard let names = entry.lineupPlayerNames, !names.isEmpty else { return [:] }
            var map: [String: String] = [:]
            for (i, pid) in savedIDs.enumerated() where i < names.count && !names[i].isEmpty {
                map[pid] = names[i]
            }
            return map
        }()
        let savedSalaries = entry.lineupPlayerSalaries ?? [:]
        func isResolvable(_ id: String) -> Bool {
            let hasName = savedNamesByID[id] != nil || (preloadedPlayerInfo[id]?.name.isEmpty == false)
            return hasName && savedSalaries[id] != nil
        }
        let importable = savedIDs.filter { poolIDs.contains($0) || hasTwoWaySibling($0) || isResolvable($0) }
        if importable.count < savedIDs.count {
            print("[DFS-\(sport)] Import: dropped \(savedIDs.count - importable.count) players no longer in the slate")
        }
        selectedPlayerIDs = Set(importable)
        // For single-game, first player is the MVP
        if tournament?.isSingleGame == true, let firstID = importable.first {
            mvpPlayerID = firstID
        } else {
            mvpPlayerID = nil
        }
    }

    /// Begin a LATE SWAP of an already-submitted lineup. Enters edit mode so the
    /// re-submit UPDATES the existing entry (not a new one), preloads the current
    /// lineup, and relies on `isPlayerLocked` to freeze spots whose games have
    /// already started — only the not-yet-started spots are editable.
    func startLateSwap(lineupNumber: Int) {
        guard supportsLateSwap, allowsLineupEditing else { return }
        activePrivateContest = nil
        editingLineupNumber = lineupNumber
        if let tid = activeTournamentID,
           let entry = entryRecord(for: tid, lineupNumber: lineupNumber) {
            loadLineupFromEntry(entry)
        }
        // Make the late-swap pool show the same confirmed (CS) starters the
        // single-game pools already have, then pull the freshest XIs from ESPN.
        // Without this, a game whose XI dropped after the main slate loaded
        // shows stale "predicted" badges in the swap builder.
        reconcileConfirmedFromSingleGamePools()
        Task {
            await reprobeSoccerConfirmedXIIfNeeded()
            reconcileConfirmedFromSingleGamePools()
        }
    }

    /// Has the game a player belongs to started yet? (Helper for late-swap bot
    /// optimization; mirrors `isPlayerLocked` but works off a raw gameID.)
    private func gameHasStarted(_ gameID: String?) -> Bool {
        guard let gid = gameID else { return false }
        if let info = liveGameInfo[gid], info.state != "pre" { return true }
        if let g = slateGames.first(where: { $0.id == gid }) { return Date() >= g.startTime }
        return false
    }

    /// BOT late swap (#5): for staggered slates, replace each bot's
    /// not-yet-started, NON-confirmed picks with confirmed-active players from
    /// games that also haven't started — cutting DNP risk as later lineups are
    /// announced. Players whose games have already started are PINNED (their
    /// live scores are locked), so the live leaderboard never churns for games
    /// in progress. Same-position swaps keep each lineup roster-valid and under
    /// cap. Returns true if any bot changed. Caller gates on
    /// `supportsLateSwap && !allGamesStarted`.
    @discardableResult
    private func applyLateSwapBotOptimization() -> Bool {
        guard let tournament else { return false }
        let cap = tournament.salaryCap
        let byID = Dictionary(activePlayers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Confirmed-active, not-injured-out players whose game hasn't started,
        // grouped by position and sorted best-projection-first.
        let pool = activePlayers.filter { p in
            guard p.isConfirmedActive, !gameHasStarted(p.gameID) else { return false }
            let st = p.injuryStatus ?? ""
            return !(st == "O" || st == "D" || st.hasPrefix("IL"))
        }
        var candidatesByPos: [String: [DFSPlayer]] = [:]
        for p in pool { candidatesByPos[p.position, default: []].append(p) }
        // Game start times keyed by gameID — used to push bots toward LATER
        // games. As each later game publishes its confirmed lineup, its players
        // become eligible here and we want bots to migrate their open
        // (not-yet-started, non-confirmed) slots into them rather than piling
        // onto the earliest game. This is what makes the field realistically
        // spread across the slate's full window.
        let startByGame: [String: TimeInterval] = Dictionary(
            slateGames.map { ($0.id, $0.startTime.timeIntervalSince1970) },
            uniquingKeysWith: { a, _ in a }
        )
        // Deterministic order so the same replacement is chosen every cycle —
        // otherwise tie-breaking churns the bot field on each refresh and the
        // leaderboard jumps. Primary key biases toward later-starting games
        // (more late-game players), then projection desc, then id.
        for k in candidatesByPos.keys {
            candidatesByPos[k]?.sort { a, b in
                let sa = a.gameID.flatMap { startByGame[$0] } ?? 0
                let sb = b.gameID.flatMap { startByGame[$0] } ?? 0
                if sa != sb { return sa > sb }
                if a.projectedPoints != b.projectedPoints { return a.projectedPoints > b.projectedPoints }
                return a.id < b.id
            }
        }

        var changedAny = false
        let isSoccerSlate = sport == "EPL" || sport == "UCL" || sport == "WC"
        let minPoolSalary = pool.map(\.salary).min() ?? 3500
        for i in fieldEntries.indices {
            let entry = fieldEntries[i]
            guard !entry.isCurrentUser, !entry.isRealUser else { continue }
            var ids = entry.playerIDs

            if isSoccerSlate {
                // SOCCER: re-draft every OPEN slot (game not started AND not yet
                // a confirmed starter) from the confirmed pool within the bot's
                // FREED budget (cap minus locked confirmed/started salary). The
                // generation pass reserves budget by parking unconfirmed slots
                // on cheap placeholders, so here we can afford the best available
                // confirmed starters — biased to LATER games so late-game studs
                // (Díaz/Suárez) get real exposure. A per-bot deterministic RNG
                // spreads the field (not every bot grabs the same stud) and keeps
                // picks stable across refreshes (no leaderboard churn). Slots
                // whose game's XI isn't out yet have no confirmed candidates and
                // simply keep their placeholder until a later refresh.
                var openSlots: [Int] = []
                var lockedSalary = 0
                var selected = Set<String>()
                for slot in ids.indices {
                    let cur = byID[ids[slot]]
                    if let cur, !gameHasStarted(cur.gameID), !cur.isConfirmedActive {
                        openSlots.append(slot)
                    } else {
                        if let cur { lockedSalary += cur.salary }
                        selected.insert(ids[slot])
                    }
                }
                guard !openSlots.isEmpty else { continue }
                var budgetLeft = cap - lockedSalary
                // Fill scarcer positions first (GK) so a tight slot isn't starved.
                let ordered = openSlots.sorted {
                    (candidatesByPos[byID[ids[$0]]?.position ?? ""]?.count ?? 0) <
                    (candidatesByPos[byID[ids[$1]]?.position ?? ""]?.count ?? 0)
                }
                // Per-(bot,slot) deterministic pick from a STABLE key (the bot's
                // NAME + slot index) — NOT entry.id, which is a fresh per-device
                // UUID. The field is persisted and SHARED across every real user,
                // so every device must compute the identical result; seeding off
                // the stable, server-persisted name guarantees that. Per-slot
                // (rather than a sequential RNG) makes each pick independent of
                // how many other slots a given refresh happens to optimize, so
                // progressive optimization across staggered games still converges.
                func pickUnit(_ slot: Int) -> Double {
                    var h: UInt64 = 14695981039346656037
                    for b in entry.name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
                    h = (h ^ UInt64(slot &+ 1)) &* 1099511628211
                    return Double(h >> 11) / Double(UInt64(1) << 53)
                }
                var remaining = ordered.count
                var rowChanged = false
                for slot in ordered {
                    remaining -= 1
                    guard let cur = byID[ids[slot]] else { continue }
                    let pos = cur.position
                    let reserve = remaining * minPoolSalary
                    // SAME-GAME upgrade: only replace the placeholder with a
                    // confirmed starter from ITS OWN game. This keeps the bot's
                    // late-game allocation intact — a slot the bot reserved for
                    // the last game (Colombia) stays a cheap placeholder until
                    // that XI posts, THEN upgrades to a confirmed Colombia
                    // starter (Díaz/Suárez). Without this, the slot would get
                    // filled by an earlier-confirmed game and the late-game
                    // studs would never get exposure (the 0% bug).
                    let affordable = (candidatesByPos[pos] ?? []).filter {
                        $0.gameID == cur.gameID && !selected.contains($0.id) && $0.salary <= budgetLeft - reserve
                    }
                    guard !affordable.isEmpty else { continue }
                    // Weighted pick within the game's confirmed starters, biased
                    // toward higher projection but spread across the field so the
                    // late swap doesn't pile every bot onto the single top option
                    // (which left the other real starters at 0% and made the field
                    // trivial to differentiate from). `pow(r, 1.4)` is flatter than
                    // the old `r*r` — meaningfully more ownership variance while
                    // still leaning chalk. The stable per-bot hash keeps each bot's
                    // pick deterministic across refreshes (no leaderboard churn).
                    let r = pickUnit(slot)
                    let idx = min(affordable.count - 1, Int(Double(affordable.count) * pow(r, 1.4)))
                    let pick = affordable[idx]
                    if pick.id != ids[slot] { rowChanged = true }
                    ids[slot] = pick.id
                    selected.insert(pick.id)
                    budgetLeft -= pick.salary
                }
                if rowChanged {
                    fieldEntries[i] = DFSFieldEntry(
                        id: entry.id, name: entry.name, playerIDs: ids,
                        isCurrentUser: false, isRealUser: false, realUserID: nil
                    )
                    changedAny = true
                }
                continue
            }

            // NON-soccer (MLB, …): original 1-for-1 swap — replace each
            // not-started, unconfirmed slot with the best affordable confirmed
            // starter of the same position. Unchanged behavior.
            var selected = Set(ids)
            var usedSalary = ids.reduce(0) { $0 + (byID[$1]?.salary ?? 0) }
            var rowChanged = false

            for slot in ids.indices {
                guard let cur = byID[ids[slot]] else { continue }
                if gameHasStarted(cur.gameID) { continue }      // pinned — live or finished
                if cur.isConfirmedActive { continue }            // already a confirmed starter
                // Find the best affordable confirmed replacement of the same position.
                guard let repl = candidatesByPos[cur.position]?.first(where: { c in
                    !selected.contains(c.id) && (usedSalary - cur.salary + c.salary) <= cap
                }) else { continue }
                selected.remove(cur.id); selected.insert(repl.id)
                usedSalary += repl.salary - cur.salary
                ids[slot] = repl.id
                rowChanged = true
            }

            if rowChanged {
                fieldEntries[i] = DFSFieldEntry(
                    id: entry.id, name: entry.name, playerIDs: ids,
                    isCurrentUser: false, isRealUser: false, realUserID: nil
                )
                changedAny = true
            }
        }
        return changedAny
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
        // Fix two-way batter positions: the batter entry ("mlb-X") must fill a
        // real batter slot, not stay typed SP (see normalizeMLBTwoWayBatters).
        pool = normalizeMLBTwoWayBatters(pool)
        // Override salaries with draft-time values. Prefer the slate-wide tournament
        // snapshot (captured at contest creation, covers every player) so the user's
        // lineup matches every bot lineup. Falls back to the per-entry saved salaries.
        let canonicalSalaries: [String: Int] = {
            guard let tid = activeTournamentID else { return [:] }
            if let slate = tournamentPlayerSalaries[tid], !slate.isEmpty {
                return slate
            }
            if let entry = self.entryRecord(for: tid, lineupNumber: activeLineupNumber),
               let saved = entry.lineupPlayerSalaries {
                return saved
            }
            return [:]
        }()
        if !canonicalSalaries.isEmpty {
            pool = pool.map { p in
                guard let draftSalary = canonicalSalaries[p.id] else { return p }
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
                // For two-way SP entries, force position to SP. For the BATTER
                // half of a two-way pair (its "-sp" pitcher sibling is also in
                // the lineup), force a batter slot — otherwise the stub inherits
                // ESPN's raw "SP" position and gets dropped fighting for a P slot.
                let isTwoWayBatterStub = !pid.hasSuffix("-sp") && sport == "MLB" && selectedPlayerIDs.contains(pid + "-sp")
                let knownPosition: String? = pid.hasSuffix("-sp") ? "SP" : (isTwoWayBatterStub ? "1B" : preloadedPos)
                
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
                // Use preloaded info name, then entry record name, then live stats name, then raw ID.
                let name = preloadedPlayerInfo[pid]?.name
                    ?? entryNamesByID[pid]
                    ?? livePlayerStats[pid]?.name
                    ?? pid
                let team = preloadedPlayerInfo[pid]?.team ?? "—"
                let sal = entrySalariesByID[pid] ?? 0
                pool.append(DFSPlayer(id: pid, name: name, team: team, position: assignedPosition, salary: sal, projectedPoints: 0))
            }
        } else {
            for pid in missingIDs {
                let name = preloadedPlayerInfo[pid]?.name ?? entryNamesByID[pid] ?? pid
                let team = preloadedPlayerInfo[pid]?.team ?? "—"
                let isTwoWayBatterStub = !pid.hasSuffix("-sp") && sport == "MLB" && selectedPlayerIDs.contains(pid + "-sp")
                let pos = pid.hasSuffix("-sp") ? "SP" : (isTwoWayBatterStub ? "1B" : (preloadedPlayerInfo[pid]?.position?.uppercased() ?? "UTIL"))
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
        // Second pass: a player who matched no slot (e.g. a two-way batter still
        // momentarily typed SP while the slate finishes loading) would otherwise
        // be dropped by compactMap — making a player the user drafted vanish from
        // their lineup. Park leftovers in any still-empty slot, then append any
        // remainder as overflow, so the full lineup is always shown.
        if !remaining.isEmpty {
            for i in result.indices where result[i] == nil {
                if remaining.isEmpty { break }
                result[i] = remaining.removeFirst()
            }
        }
        return result.compactMap { $0 } + remaining
    }

    /// Total salary including MVP 1.5x premium for single-game slates.
    /// In single-game mode, the first selected player is the MVP and costs 1.5x.
    var selectedSalary: Int {
        // Use selectedPlayers salaries (which applies the canonical/snapshot
        // override) so the builder's cap math matches what gets stored on
        // submit and displayed in the lobby. Raw activePlayers can drift after
        // contest creation, causing a "$50K/$50K" build to actually save as
        // ~$53K — over the cap.
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
        return selectedPlayers[0].salary / 2  // 0.5x of canonical base salary
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

    // MARK: - Late Swap (per-game lock)

    /// Late swap applies to MULTI-GAME main slates whose games start at
    /// staggered times (World Cup 3/6/9/12, MLB all-day) — a user/bot can keep
    /// editing roster spots tied to games that haven't started yet, even after
    /// the earliest game (the slate "lock") has begun. Single-game/showdown
    /// slates and slates where every game starts together keep the old
    /// all-or-nothing lock.
    var supportsLateSwap: Bool {
        guard let t = tournament, t.tournamentType != .singleGame, !(t.isSingleGame) else { return false }
        // Applies to every staggered multi-game team-sport main slate
        // (NBA/NHL/MLB/NFL/CFB/NCAAM/WNBA/EPL/UCL/WC). Excluded: UFC (one fight
        // card, all in the same window) and PGA (golf — one event, everyone
        // tees off together, different model). The start-time check below means
        // a slate whose games all start at once also keeps the simple lock.
        guard sport != "UFC", sport != "PGA" else { return false }
        let starts = Set(slateGames.map { $0.startTime.timeIntervalSince1970.rounded() })
        return starts.count > 1
    }

    /// A player is locked once HIS game has started. For non-late-swap slates
    /// this collapses to the whole-slate lock so existing behavior is unchanged.
    func isPlayerLocked(_ player: DFSPlayer) -> Bool {
        guard supportsLateSwap else { return isTournamentLocked }
        guard let gid = player.gameID else { return isTournamentLocked }
        // Locked if the game is live/final per ESPN, OR its scheduled start has
        // passed. The start-time check is essential: ESPN's `state` lags (a game
        // that kicked off can still report "pre" for a bit), and we must NEVER
        // let a started player be removed — so don't short-circuit on a stale
        // "pre", fall through to the clock.
        if let info = liveGameInfo[gid], info.state != "pre" { return true }
        if let game = slateGames.first(where: { $0.id == gid }) { return Date() >= game.startTime }
        return false
    }

    /// True once EVERY game on the active slate has started — the point at which
    /// a late-swap lineup can no longer be edited at all. (Distinct from the
    /// tournament-based `isFullyLocked` further down, which is about all
    /// TOURNAMENTS being locked.)
    var allGamesStarted: Bool {
        guard tournament != nil else { return false }
        guard supportsLateSwap else { return isTournamentLocked }
        let now = Date()
        return slateGames.allSatisfy { g in
            if let info = liveGameInfo[g.id], info.state != "pre" { return true }
            return now >= g.startTime
        }
    }

    /// Whether the lineup can still be edited (drives builder-vs-live routing).
    /// Late-swap slates stay editable until every game has started.
    var allowsLineupEditing: Bool {
        guard tournament != nil else { return false }
        return supportsLateSwap ? !allGamesStarted : !isTournamentLocked
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
        // Main-slate tournaments lock at the earliest game. When the live slate
        // failed to load (no slateGames → computeLockTime returns
        // .distantFuture), fall back to the lock time persisted on the server
        // tournament so the contest still resolves its real lock instead of
        // being stuck "Upcoming" after its game ended.
        if let serverLock = serverLockTimes[t.id] {
            let computed = lockTime
            return computed == .distantFuture ? serverLock : min(computed, serverLock)
        }
        // PGA rotates weekly. After last week's event finishes (and its Monday
        // playoff completes), the slate moves to the upcoming tournament — but
        // the user's entries for the FINISHED event linger in `tournaments`.
        // The global `lockTime` is the ACTIVE slate's lock (a FUTURE time, e.g.
        // the upcoming event 3 days out), so falling through to it marks the
        // finished event "Upcoming" and makes its stale lineup look editable.
        // A PGA tournament whose event ID isn't the loaded slate's has already
        // passed (you can't have entered a slate that isn't posted yet) — treat
        // it as locked so it drops out of "Upcoming Lineups" and into results.
        if sport == "PGA", let activeEvent = slateGames.first?.id,
           pgaBaseEventID(from: t.id) != activeEvent {
            return .distantPast
        }
        return lockTime
    }

    /// Whether a specific tournament is locked (for UI display in lobby/contest list).
    func isTournamentLocked(_ t: DFSTournament) -> Bool {
        Date() >= lockTimeForTournament(t)
    }

    /// Returns tournaments that are still open for entry (not yet locked).
    var availableTournaments: [DFSTournament] {
        let now = Date()
        return tournaments.filter { now < lockTimeForTournament($0) && !isTournamentSettledOrSibling($0.id) }
    }

    /// Returns tournaments that are locked (games have started).
    /// Settled past tournaments are excluded — they should not count
    /// toward `isFullyLocked`, otherwise PGA gets stuck showing a
    /// "this week's tournament has locked" view after Memorial settles
    /// on a Monday while the upcoming RBC slate hasn't loaded yet.
    var lockedTournaments: [DFSTournament] {
        let now = Date()
        return tournaments.filter { now >= lockTimeForTournament($0) && !isTournamentSettledOrSibling($0.id) }
    }

    /// Whether the slate is partially locked (some games started, some haven't).
    var isPartiallyLocked: Bool {
        !availableTournaments.isEmpty && !lockedTournaments.isEmpty
    }

    /// Whether all tournaments are locked (all games have started).
    var isFullyLocked: Bool {
        let unsettled = tournaments.filter { !isTournamentSettledOrSibling($0.id) }
        return availableTournaments.isEmpty && !unsettled.isEmpty
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
        // Drop admin-excluded contests at read time. A plain local/server
        // delete can't stick because `applyServerHistory` re-imports rows from
        // the server (and a still-settling contest re-writes them). Filtering
        // here means an excluded tournament stays gone no matter what comes
        // back, so its RR (which is history-derived) never reappears.
        let excluded = Self.excludedTournamentIDs
        let visible = decoded.filter {
            let tid = $0.tournamentId ?? ""
            return !excluded.contains(tid) && !Self.isFantasyModeTid(tid)
        }
        return deduplicatedHistory(visible)
    }

    /// True for a tournament id that belongs to a Fantasy game mode (Playoff
    /// Tiers, Soccer Tiers, Tennis Bracket), not DFS. Those modes share the
    /// `dfs_tournament_results` table, and Playoff Tiers' id (`nba-playoffs-YYYY`)
    /// even shares the `nba-` prefix — so without this filter a Fantasy contest
    /// (e.g. a "U.S. Open Tiers" Playoff-Tiers private group) leaks into DFS Past
    /// Results, mis-badged as NBA, and skews DFS RR. Fantasy has its own results
    /// surface (FantasyHub), so DFS excludes these everywhere.
    static func isFantasyModeTid(_ tid: String) -> Bool {
        if tid.hasPrefix("nba-playoffs-") { return true }   // Playoff Tiers
        if tid.hasPrefix("world-cup-") { return true }      // Soccer Tiers
        // Golf Tiers majors. Note `us-open-` is HYPHENated — distinct from the
        // tennis `us_open-` (underscore) below. `pga-championship-` shares the
        // `pga-` prefix but a real DFS PGA tid is `pga-<numericEventID>-<size>`,
        // so "championship" never collides.
        if tid.hasPrefix("masters-") || tid.hasPrefix("pga-championship-")
            || tid.hasPrefix("us-open-") || tid.hasPrefix("the-open-") { return true }
        // Tennis Bracket: "<slam>-(atp|wta)-YYYY"
        if tid.contains("-atp-") || tid.contains("-wta-") {
            if tid.hasPrefix("us_open-") || tid.hasPrefix("wimbledon-")
                || tid.hasPrefix("french_open-") || tid.hasPrefix("australian_open-") {
                return true
            }
        }
        return false
    }

    /// Tournament IDs the admin has permanently removed from history/RR.
    /// Stored globally in UserDefaults so the read-time filter in `dfsHistory`
    /// applies across every per-sport view model without extra plumbing.
    static let excludedTournamentsKey = "dfs_excluded_tournaments"
    static var excludedTournamentIDs: Set<String> {
        guard let data = UserDefaults.standard.data(forKey: excludedTournamentsKey),
              let set = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return set
    }
    static func excludeTournament(_ tournamentID: String) {
        var set = excludedTournamentIDs
        set.insert(tournamentID)
        UserDefaults.standard.set((try? JSONEncoder().encode(set)) ?? Data(), forKey: excludedTournamentsKey)
    }
    /// Reverse a `excludeTournament` — used when a contest that was wrongly
    /// ghosted (e.g. the settled flag got clobbered mid-self-heal) turns out to
    /// have good server results after all.
    static func unexcludeTournament(_ tournamentID: String) {
        var set = excludedTournamentIDs
        guard set.contains(tournamentID) else { return }
        set.remove(tournamentID)
        UserDefaults.standard.set((try? JSONEncoder().encode(set)) ?? Data(), forKey: excludedTournamentsKey)
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

    /// ADMIN: permanently remove a stuck/ungradeable ACTIVE contest from
    /// "My Contests". Used for contests that can never settle because the data
    /// source has no scores for the event (e.g. a UFC card ESPN never posted
    /// fighter stats for, a postponed game). Excludes + marks settled + drops
    /// the local entry so it can't reappear after a server re-fetch.
    func adminRemoveStuckContest(tournamentID tid: String) {
        // Reverse any RR a stale/partial result contributed.
        let staleRR = dfsHistory.filter { $0.tournamentId == tid }.reduce(0) { $0 + $1.rrDelta }
        if staleRR != 0 { rrScore -= staleRR }
        var updated = dfsHistory
        updated.removeAll { $0.tournamentId == tid }
        dfsHistoryData = encodedDFSHistory(updated)
        enteredTournamentIDs.remove(tid)
        userEntryRecords[tid] = nil
        markTournamentSettled(tid)
        Self.excludeTournament(tid)
        print("[DFS-\(sport)] Admin removed stuck contest \(tid) (excluded + settled + dropped)")
    }

    /// ADMIN: wipe a settled contest's stored results and un-settle it so the
    /// normal settlement machinery re-grades it from scratch — regenerating the
    /// bot field and re-scoring with the CURRENT (fixed) logic (UFC MVP, golf
    /// bot scoring, etc.). Reverses the old RR so the re-settle's RR is clean.
    func adminRegradeContest(tournamentID tid: String) async {
        guard let token = accessToken else { return }
        // Reverse the RR the stale result contributed + drop local history.
        let staleRR = dfsHistory.filter { $0.tournamentId == tid }.reduce(0) { $0 + $1.rrDelta }
        rrScore -= staleRR
        var updated = dfsHistory
        updated.removeAll { $0.tournamentId == tid }
        dfsHistoryData = encodedDFSHistory(updated)
        var settled = settledTournaments
        settled.remove(tid)
        settledTournamentData = (try? JSONEncoder().encode(settled)) ?? settledTournamentData
        botFieldRegeneratedThisSession.remove(tid)

        // Golf has its own past-event self-heal driven by refreshLive
        // (settleUnsettledPastGolfTournament re-fetches the event and does its
        // own delete+upsert). Every OTHER sport must re-settle through
        // settleUnsettledPastTournament, which scores against the contest's OWN
        // event date (not today's slate, which is what refreshLive would use)
        // and honors the persisted is_single_game flag (UFC captain MVP 1.5x).
        if sport == "PGA" {
            selectTournament(tid, lineupNumber: activeLineupNumber)
            fieldGenerated = false
            await loadSlateIfNeeded()
            await refreshLive()
            print("[DFS-PGA] Admin re-grade for \(tid) — reversed \(staleRR) RR, re-settling")
            return
        }

        guard let uid = userID,
              let entries = try? await SupabaseService.shared.fetchEntries(tournamentID: tid, accessToken: token),
              let myEntry = entries.first(where: { $0.userID == uid }) ?? entries.first else {
            print("[DFS-\(sport)] Admin re-grade for \(tid) — no entries found")
            return
        }
        // forceRegenerateBots=false: saved bots belong to this event; we only
        // need to re-score (e.g. apply captain MVP). The function aborts safely
        // if it can't get real scores, so a failed re-grade never blanks results.
        _ = await settleUnsettledPastTournament(
            tournamentID: tid, userEntry: myEntry, token: token,
            userID: uid, forceRegenerateBots: false
        )
        print("[DFS-\(sport)] Admin re-grade for \(tid) — reversed \(staleRR) RR, re-settled via past-event path")
    }

    /// Returns a display string for remaining game time for a field entry's players.
    /// Shows count of live/remaining games, e.g. "2 live", "Final", "3 pre"
    func timeRemainingLabel(for fieldEntry: DFSFieldEntry) -> String {
        let playersByID = Dictionary(activePlayers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
        // Use the tournament-appropriate pool, NOT the full `players` list. For
        // an EVENING slate `activePlayers` resolves to `eveningPlayers` (games at
        // 6pm ET+), so the filter pills only show evening matchups — the full
        // `players` pool was leaking the day's earlier games (COD@POR, CRO@ENG)
        // into the evening slate's filter.
        let playerGameIDs = Set(activePlayers.compactMap { $0.gameID })
        return slateGames.compactMap { game in
            guard playerGameIDs.contains(game.id) else { return nil }
            // Hide any game that has already STARTED (in progress OR final), not
            // just finished ones — you can't draft or late-swap into a game
            // that's underway, so listing it just dead-ends the filter with
            // locked/empty players. (Was only excluding "post" games, so the
            // 3pm/6pm games stayed in the filter when building the 9pm slate.)
            if gameHasStarted(game.id) { return nil }
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
        return allowsLineupEditing
            && selectedPlayers.count == tournament.lineupSize
            && selectedSalary <= tournament.salaryCap
    }

    /// Teams whose starting XI has been announced (≥1 confirmed starter in
    /// the active pool). Once a team's XI is out, "projected starter" is
    /// meaningless for that team — anyone not confirmed is benched.
    var confirmedXITeams: Set<String> {
        Set(activePlayers.filter { $0.isConfirmedActive && !$0.team.isEmpty }.map(\.team))
    }

    // MARK: - Actions

    func togglePlayer(_ player: DFSPlayer) {
        // Late swap: a player whose game has already started is frozen — it can
        // neither be added nor removed. (For non-late-swap slates this is the
        // whole-slate lock, matching the builder's disabled state.)
        if isPlayerLocked(player) { return }
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
        // Late swap: never remove a player whose game has already started.
        if isPlayerLocked(player) { return }
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
        // Load when there's no tournament yet OR the player pool is empty. A
        // stub/instance tournament can exist without the real slate ever
        // having loaded, which strands contest detail views in shimmer — the
        // empty-pool check forces the fetch in that case. (loadSlate's own
        // guard mirrors this.)
        if tournament == nil || (players.isEmpty && singleGamePlayers.isEmpty) {
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
        // Skip if we already have entries populated
        guard enteredTournamentIDs.isEmpty else { return }

        do {
            let allUserEntries = try await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)
            let matched: [DFSEntryRecord]
            if let mainID = tournaments.first?.id {
                // Normal path: filter to the active slate's day.
                let prefix = sportDatePrefix(from: mainID)
                matched = allUserEntries.filter { $0.tournamentID.hasPrefix(prefix) }
            } else {
                // The live slate failed to build (e.g. a single-game night DK
                // only posted as showdown, or the game already started and DK
                // pulled the slate). The user's entered contests still live in
                // Supabase — surface their recent UNSETTLED contests for this
                // sport so "My Contests" isn't empty. Works just like other
                // sports whose slate happens to be available.
                let sportPrefix = "\(sport.lowercased())-"
                let recentCutoff = Date().addingTimeInterval(-2 * 24 * 3600)
                matched = allUserEntries.filter {
                    $0.tournamentID.hasPrefix(sportPrefix)
                    && ($0.submittedAt ?? .distantPast) > recentCutoff
                    && !settledTournaments.contains($0.tournamentID)
                }
            }
            if !matched.isEmpty {
                enteredTournamentIDs = Set(matched.map(\.tournamentID))
                userEntryRecords = Dictionary(grouping: matched, by: \.tournamentID)
                // When the slate failed to build there are no base tournaments to
                // clone, so synthesize a tournament object per entered contest
                // from the server record. Without this the card has no title /
                // metadata and won't render. (Mirrors the PGA recent-entries path.)
                if tournaments.first?.id == nil {
                    for tid in Set(matched.map(\.tournamentID)) where !tournaments.contains(where: { $0.id == tid }) {
                        let record = try? await SupabaseService.shared.fetchTournament(tournamentID: tid, accessToken: token)
                        // Cache the server lock time so isEntryUpcoming/lockTimeForTournament
                        // resolve correctly without a live slate (otherwise these show
                        // "Upcoming" forever, even after the game ended).
                        if let lt = record?.lockTime { serverLockTimes[tid] = lt }
                        let single = record?.isSingleGame ?? tid.contains("-sg-")
                        tournaments.append(DFSTournament(
                            id: tid,
                            title: record?.title ?? "\(sport) Contest",
                            league: sport,
                            entryCount: record?.totalEntries ?? Self.entryCountFromTournamentID(tid),
                            lineupSize: single ? 6 : 8,
                            salaryCap: 50000,
                            isSingleGame: single,
                            tournamentType: single ? .singleGame : .main
                        ))
                    }
                }
                ensureInstanceTournamentsExist()
            }
        } catch {
            print("[DFS] fetchEntriesIfNeeded failed: \(error.localizedDescription)")
        }
    }

    func loadSlate(force: Bool) async {
        if isLoading {
            // Takeover for wedged loads: if a previous attempt has been
            // "loading" for over a minute, it's stuck (hung request, killed
            // task) — without this, every retry (watchdog, manual refresh)
            // bails here forever and the shimmer never resolves.
            guard let started = slateLoadStartedAt,
                  Date().timeIntervalSince(started) > 60 else { return }
            print("[DFS-\(sport)] loadSlate: previous attempt stuck for \(Int(Date().timeIntervalSince(started)))s — taking over")
        }
        // Skip a non-forced reload only when the slate is genuinely loaded —
        // i.e. there's a tournament AND a player pool. A non-nil `tournament`
        // alone isn't enough: it can be a synthetic stub (selectTournament) or
        // an instance clone (ensureInstanceTournamentsExist) created from a
        // saved entry while the real fetch never completed (timed out, was
        // cancelled). In that state `players` is empty and every contest
        // detail sits in shimmer forever, so we must still attempt the load.
        if !force && tournament != nil && !(players.isEmpty && singleGamePlayers.isEmpty) { return }

        isLoading = true
        slateLoadStartedAt = Date()
        error = nil
        do {
            // Hard timeout — a single hung request inside fetchSlate (ESPN
            // roster fetches have no aggressive timeout) otherwise pins
            // isLoading=true and the tab in shimmer indefinitely.
            let provider = slateProvider
            let slate = try await withDFSTimeout(seconds: 45) { try await provider.fetchSlate() }
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
            // MLB two-way players (Ohtani): normalize the batter half of the
            // pair to a real batter slot in the base pool too, so bots and
            // scoring that read `players` directly see a draftable 1B rather
            // than a second SP. See normalizeMLBTwoWayBatters.
            players = normalizeMLBTwoWayBatters(players)
            // PGA: collapse duplicate golfers by name at the display layer too.
            // Golfers are unique by name, so this is safe — and it catches dupes
            // regardless of how the slate was built/cached (the provider also
            // dedupes, but this guarantees the pool the builder renders is clean).
            // NOT done for team sports: two different players CAN share a name
            // (e.g. multiple "Josh Allen"), so name-collapsing there is unsafe.
            if sport == "PGA" {
                players = ESPNPGADFSSlateProvider.dedupeGolfers(players)
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
                // CRITICAL: ALWAYS fetch the user's full entry list across
                // every tournament. The previous "fast path" tried to skip
                // the network call by reusing `remoteEntries`, but that
                // variable only holds entries for the ONE active tournament
                // (the result of `fetchEntries(tournamentID:)`). Using it
                // collapsed `enteredTournamentIDs` to just whatever tid the
                // lobby had open — wiping the other tournaments the user
                // had entered (e.g. SG H2H + 5-Man for the same game). They
                // then vanished from Active Contests even though they were
                // still in `dfsHistory` / My Contests.
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
                // Save outgoing tournament to cache — only if its bots actually
                // match the outgoing tournament's shape, to prevent cross-
                // tournament contamination.
                if let prevID = previousID, fieldGenerated, !fieldEntries.isEmpty,
                   botsMatchTournament(fieldEntries, tournamentID: prevID) {
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
                // Discard contaminated cache up front so the restore path
                // can't pull bots from a different tournament.
                if let tid = tournament?.id,
                   let cached = liveContestCache[tid],
                   !botsMatchTournament(cached.fieldEntries, tournamentID: tid) {
                    discardContaminatedCache(tid)
                    _ = cached
                }
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

    /// DISPLAY-ONLY arrangement: orders a lineup's player IDs into the
    /// tournament's roster slots and labels each by the SLOT it occupies, so the
    /// box score shows e.g. both SP at top then C/1B/2B…, and a two-way batter
    /// (relabeled UTIL with no UTIL slot in MLB classic) shows "1B" instead of
    /// "—". Does NOT change eligibility — only orders/labels what was drafted.
    /// Single-game (MVP/FLEX) and slot-less sports (golf) keep their original
    /// order, badged by the player's own position.
    func arrangedLineupForDisplay(_ playerIDs: [String]) -> [(playerID: String, slot: String)] {
        let byID = Dictionary(activePlayers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return arrangeForDisplay(
            playerIDs: playerIDs,
            rosterSlots: tournament?.rosterSlots,
            isSingleGame: tournament?.isSingleGame ?? false,
            position: { id in id.hasSuffix("-sp") ? "SP" : (byID[id]?.position ?? "") }
        )
    }

    /// General roster-slot arranger (used by both the live box score and the
    /// settled Past Results view). Orders `playerIDs` into `rosterSlots`, labels
    /// each by the slot it occupies. `position` resolves a player's position by
    /// id — callers pass whatever source they have (live pool, past box-score
    /// stats, etc.). Single-game / slot-less inputs keep original order + the
    /// resolved position as the badge. DISPLAY-ONLY; no eligibility change.
    func arrangeForDisplay(playerIDs: [String], rosterSlots: [String]?, isSingleGame: Bool,
                           position: (String) -> String) -> [(playerID: String, slot: String)] {
        guard let slots = rosterSlots, !slots.isEmpty, !isSingleGame else {
            return playerIDs.map { ($0, position($0)) }
        }
        var unplaced = playerIDs
        var slotPlayer = [String?](repeating: nil, count: slots.count)
        // Pass 1: place each player in a slot its position is eligible for.
        for (i, slot) in slots.enumerated() {
            if let idx = unplaced.firstIndex(where: { id in
                let stub = DFSPlayer(id: id, name: "", team: "", position: position(id), salary: 0, projectedPoints: 0)
                return playerMatchesSlot(stub, slot: slot)
            }) {
                slotPlayer[i] = unplaced.remove(at: idx)
            }
        }
        // Pass 2: fill any still-empty slots with leftovers (flex / a UTIL-tagged
        // two-way batter that didn't match a concrete slot, missing-from-pool ids).
        for i in slotPlayer.indices where slotPlayer[i] == nil {
            if !unplaced.isEmpty { slotPlayer[i] = unplaced.removeFirst() }
        }
        var result: [(String, String)] = []
        for (i, slot) in slots.enumerated() where slotPlayer[i] != nil {
            result.append((slotPlayer[i]!, slot))
        }
        for id in unplaced { result.append((id, position(id))) }  // overflow safety
        return result
    }

    private var lastGoalieProbeAt: Date? = nil

    /// Throttled re-check of ESPN's scoreboard probables. The slate often
    /// loads hours before teams announce their starting goalie — without
    /// this, `isStartingGoalie` only ever updates on a full slate reload,
    /// so the GS badge stayed missing and bot generation stayed deferred
    /// until the user manually refreshed.
    func reprobeNHLStartingGoaliesIfNeeded() async {
        guard sport == "NHL" else { return }
        guard let t = tournament, Date() < lockTimeForTournament(t) else { return }
        let goalieTeams = Set(players.filter { $0.position == "G" && !$0.team.isEmpty }.map(\.team))
        let starterTeams = Set(players.filter { $0.position == "G" && $0.isStartingGoalie }.map(\.team))
        guard goalieTeams.isEmpty || starterTeams.count < goalieTeams.count else { return }
        if let last = lastGoalieProbeAt, Date().timeIntervalSince(last) < 300 { return }
        lastGoalieProbeAt = Date()

        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/scoreboard"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return }
        var probableIDs = Set<String>()
        for event in events {
            guard let comps = event["competitions"] as? [[String: Any]], let comp = comps.first,
                  let competitors = comp["competitors"] as? [[String: Any]] else { continue }
            for competitor in competitors {
                // ESPN lists the confirmed starter first — take only the first
                // probable per team so backups aren't marked.
                if let probables = competitor["probables"] as? [[String: Any]],
                   let first = probables.first,
                   let athlete = first["athlete"] as? [String: Any],
                   let id = athlete["id"] as? String {
                    probableIDs.insert(id)
                }
            }
        }
        guard !probableIDs.isEmpty else { return }

        func mark(_ list: [DFSPlayer]) -> ([DFSPlayer], Int) {
            var marked = 0
            let out = list.map { p -> DFSPlayer in
                guard p.position == "G", !p.isStartingGoalie else { return p }
                let espnID = String(p.id.dropFirst(4)) // "nhl-"
                guard probableIDs.contains(espnID) else { return p }
                var s = p
                s.isStartingGoalie = true
                marked += 1
                return s
            }
            return (out, marked)
        }
        let (newPlayers, mainMarked) = mark(players)
        players = newPlayers
        var totalMarked = mainMarked
        for (gid, pool) in singleGamePlayers {
            let (newPool, m) = mark(pool)
            singleGamePlayers[gid] = newPool
            totalMarked += m
        }
        if totalMarked > 0 {
            print("[DFS-NHL] Goalie re-probe marked \(totalMarked) starting-goalie entries from scoreboard probables")
        }
    }

    private var lastSoccerXIProbeAt: Date? = nil

    /// Throttled re-check of ESPN's soccer lineups. Confirmed XIs drop ~75
    /// minutes before each kickoff — long after the slate loaded — and
    /// without this the `isConfirmedActive` flags only updated on a full
    /// slate reload, so bot generation deferral never released and CS badges
    /// lagged. Only trusts lineups inside the 75-minute official window.
    func reprobeSoccerConfirmedXIIfNeeded() async {
        let slugBySport = ["WC": "fifa.world", "EPL": "eng.1", "UCL": "uefa.champions"]
        guard let slug = slugBySport[sport] else { return }
        let now = Date()
        // Games inside the official-XI window that still lack confirmed teams
        let probeGames = slateGames.filter { game in
            let untilKickoff = game.startTime.timeIntervalSince(now)
            guard untilKickoff > -30 * 60, untilKickoff < 75 * 60 else { return false }
            let confirmedTeams = Set(players.filter { $0.gameID == game.id && $0.isConfirmedActive }.map(\.team)).subtracting([""])
            return confirmedTeams.count < 2
        }
        guard !probeGames.isEmpty else { return }
        if let last = lastSoccerXIProbeAt, now.timeIntervalSince(last) < 240 { return }
        lastSoccerXIProbeAt = now

        let prefix = sport.lowercased() + "-"
        var confirmedIDs = Set<String>()
        for game in probeGames {
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(slug)/summary?event=\(game.id)"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rosters = json["rosters"] as? [[String: Any]] else { continue }
            for block in rosters {
                guard let entries = block["roster"] as? [[String: Any]] else { continue }
                for entry in entries where (entry["starter"] as? Bool ?? false) {
                    if let ath = entry["athlete"] as? [String: Any], let id = ath["id"] as? String {
                        confirmedIDs.insert(prefix + id)
                    }
                }
            }
        }
        guard !confirmedIDs.isEmpty else { return }

        func mark(_ list: [DFSPlayer]) -> ([DFSPlayer], Int) {
            var marked = 0
            let out = list.map { p -> DFSPlayer in
                guard !p.isConfirmedActive, confirmedIDs.contains(p.id) else { return p }
                var c = p
                c.isConfirmedActive = true
                marked += 1
                return c
            }
            return (out, marked)
        }
        let (newPlayers, mainMarked) = mark(players)
        players = newPlayers
        var totalMarked = mainMarked
        // Evening pool is a separate array (built off `players` at load time) —
        // mark it too, otherwise an evening-slate builder shows stale PS badges
        // for an XI that the main/single-game pools already confirmed.
        if !eveningPlayers.isEmpty {
            let (newEvening, eveMarked) = mark(eveningPlayers)
            eveningPlayers = newEvening
            totalMarked += eveMarked
        }
        for (gid, pool) in singleGamePlayers {
            let (newPool, m) = mark(pool)
            singleGamePlayers[gid] = newPool
            totalMarked += m
        }
        if totalMarked > 0 {
            print("[DFS-\(sport)] XI re-probe confirmed \(totalMarked) starter entries from ESPN lineups")
        }
        // Catch any starter a single-game pool already had confirmed (e.g. from
        // RotoGrinders' XI at build time) that this ESPN pass didn't surface.
        reconcileConfirmedFromSingleGamePools()
    }

    /// Make the main (and evening) player pools at least as up-to-date on
    /// confirmed starters as the single-game pools. The same player exists in
    /// both `players` and `singleGamePlayers[gameID]` (same id), built from one
    /// marked pool — but the two can drift apart: a re-probe, a slate rebuild,
    /// or a per-game lineup fetch may confirm a starter in one pool while the
    /// other still shows the pre-XI "predicted" badge. Symptom the user hit:
    /// the Belgium single-game contest shows CS badges, but late-swapping the
    /// same game on the main slate still shows PS. Confirmation is monotonic
    /// within a slate (an announced starter stays announced), so ORing the flag
    /// from the SG pools into `players`/`eveningPlayers` only ever upgrades —
    /// it never wrongly un-confirms anyone.
    func reconcileConfirmedFromSingleGamePools() {
        guard sport == "EPL" || sport == "UCL" || sport == "WC" else { return }
        guard !singleGamePlayers.isEmpty else { return }
        // Union of every player the single-game pools consider a confirmed XI starter.
        var confirmedIDs = Set<String>()
        for (_, pool) in singleGamePlayers {
            for p in pool where p.isConfirmedActive { confirmedIDs.insert(p.id) }
        }
        guard !confirmedIDs.isEmpty else { return }
        func upgrade(_ list: [DFSPlayer]) -> ([DFSPlayer], Int) {
            var marked = 0
            let out = list.map { p -> DFSPlayer in
                guard !p.isConfirmedActive, confirmedIDs.contains(p.id) else { return p }
                var c = p
                c.isConfirmedActive = true
                marked += 1
                return c
            }
            return (out, marked)
        }
        let (newPlayers, mainMarked) = upgrade(players)
        players = newPlayers
        var total = mainMarked
        if !eveningPlayers.isEmpty {
            let (newEvening, eveMarked) = upgrade(eveningPlayers)
            eveningPlayers = newEvening
            total += eveMarked
        }
        if total > 0 {
            print("[DFS-\(sport)] Reconciled \(total) confirmed starters from single-game pools into main/evening pools")
        }
    }

    /// True when >25% of the given bot lineups hold players that confirmed
    /// lineup data says will NOT play tonight:
    /// - Soccer: players on a team whose XI is announced but who aren't in it.
    /// - NHL single-game: non-starting goalies (once both starters are known)
    ///   or skaters with no DK-slate confirmation / no recent game (healthy
    ///   scratches like a $2,000 depth wing who isn't dressed).
    /// Used to flag stale bot fields — frozen before lineups dropped — for a
    /// one-shot regeneration.
    private func botsContradictConfirmedLineups(_ botLineups: [[String]]) -> Bool {
        let lineups = Array(botLineups.prefix(50))
        guard !lineups.isEmpty, let tournament else { return false }
        var badIDs = Set<String>()
        if sport == "EPL" || sport == "UCL" || sport == "WC" {
            let confirmedTeams = Set(players.filter { $0.isConfirmedActive && !$0.team.isEmpty }.map(\.team))
            guard !confirmedTeams.isEmpty else { return false }
            badIDs = Set(players.filter { confirmedTeams.contains($0.team) && !$0.isConfirmedActive }.map(\.id))
        } else if sport == "NHL", tournament.isSingleGame {
            let sgPool: [DFSPlayer] = {
                if let gid = tournament.gameID, let sg = singleGamePlayers[gid], !sg.isEmpty { return sg }
                return players.filter { $0.gameID == tournament.gameID }
            }()
            let starterGoalieIDs = Set(sgPool.filter { $0.position == "G" && $0.isStartingGoalie }.map(\.id))
            guard starterGoalieIDs.count >= 2 else { return false } // starters unknown — can't judge
            let nonStartingGoalies = Set(sgPool.filter { $0.position == "G" && !$0.isStartingGoalie }.map(\.id))
            let dnpSkaters = Set(sgPool.filter { $0.position != "G" && (!$0.isConfirmedActive || !$0.playedRecently) }.map(\.id))
            badIDs = nonStartingGoalies.union(dnpSkaters)
        } else {
            return false
        }
        guard !badIDs.isEmpty else { return false }
        var bad = 0
        for lineup in lineups where lineup.contains(where: { badIDs.contains($0) }) { bad += 1 }
        let rate = Double(bad) / Double(lineups.count)
        if rate > 0.25 {
            print("[DFS-\(sport)] \(Int(rate * 100))% of bots hold players confirmed NOT playing — field needs regeneration")
            return true
        }
        return false
    }

    /// Don't generate (and later freeze) a bot field while the lineup
    /// information that decides it is still unknown:
    /// - NHL single-game: both teams' starting goalies must be confirmed.
    /// - Soccer (EPL/UCL/WC): the tournament's first game must have both
    ///   confirmed XIs — they drop ~75 min before kickoff, i.e. before lock.
    ///   (Later games on a main slate stay projected; that's the best
    ///   information that exists at lock.)
    /// Once the tournament locks we generate regardless, with the best info
    /// available. Bots frozen with bench players (18%-owned Ochoa) are wrong
    /// for the whole contest.
    func shouldDeferBotGeneration(for t: DFSTournament) -> Bool {
        guard Date() < lockTimeForTournament(t) else { return false }

        if sport == "NHL", t.isSingleGame {
            let pool: [DFSPlayer]
            if let gid = t.gameID, let sg = singleGamePlayers[gid], !sg.isEmpty {
                pool = sg
            } else if let gid = t.gameID {
                pool = players.filter { $0.gameID == gid }
            } else {
                pool = players
            }
            let goalieTeams = Set(pool.filter { $0.position == "G" && !$0.team.isEmpty }.map(\.team))
            let starterTeams = Set(pool.filter { $0.position == "G" && $0.isStartingGoalie && !$0.team.isEmpty }.map(\.team))
            guard !goalieTeams.isEmpty else { return true } // pool not ready yet
            let needed = min(2, goalieTeams.count)
            if starterTeams.count < needed {
                print("[DFS-NHL] Bot generation deferred for \(t.id): confirmed starting goalies \(starterTeams.sorted())/\(goalieTeams.sorted())")
                return true
            }
            return false
        }

        if sport == "EPL" || sport == "UCL" || sport == "WC" {
            // The gating game: a single-game tournament's own game, or the
            // earliest game for main/evening slates (its kickoff IS the lock).
            let gatingGameID: String? = t.isSingleGame
                ? t.gameID
                : slateGames.min(by: { $0.startTime < $1.startTime })?.id
            guard let gid = gatingGameID else { return true } // slate not ready
            let gamePlayers = players.filter { $0.gameID == gid }
            guard !gamePlayers.isEmpty else { return true }
            let gameTeams = Set(gamePlayers.map(\.team)).subtracting([""])
            let confirmedTeams = Set(gamePlayers.filter { $0.isConfirmedActive }.map(\.team)).subtracting([""])
            if confirmedTeams.count < min(2, gameTeams.count) {
                print("[DFS-\(sport)] Bot generation deferred for \(t.id): confirmed XIs \(confirmedTeams.sorted())/\(gameTeams.sorted())")
                return true
            }
            return false
        }

        return false
    }

    /// Staggered soccer slate reservation. The field is generated when game 1
    /// LOCKS, so every bot is 100% game-1 players — and all of those games have
    /// STARTED, which means late-swap (it only edits not-started slots) can never
    /// pull the bots into the later games. The whole field then stays clustered
    /// on the first match (the "all bots took from the first game" complaint).
    ///
    /// This parks a few cheap, POSITION-CORRECT placeholders from games that
    /// haven't started yet into each bot, so (a) the field spreads across the
    /// slate and (b) late-swap can later upgrade those reserved slots to each
    /// later game's confirmed starters as its XI drops. Placeholders are cheaper
    /// than what they replace, so the lineup only frees budget (which late-swap
    /// spends) — it never breaks the cap. Generation runs once and the field is
    /// frozen, so the per-bot randomness here causes no leaderboard churn.
    private func reserveNotStartedGameSlots(_ lineup: [DFSPlayer], slots: [String?], poolForReservation: [DFSPlayer]) -> [DFSPlayer] {
        guard sport == "EPL" || sport == "UCL" || sport == "WC" else { return lineup }
        guard lineup.count == slots.count, slots.count >= 6 else { return lineup }
        let notStarted = slateGames.filter { !gameHasStarted($0.id) }.map(\.id)
        let startedSet = Set(slateGames.filter { gameHasStarted($0.id) }.map(\.id))
        guard !notStarted.isEmpty, !startedSet.isEmpty else { return lineup }

        var result = lineup
        var used = Set(result.map(\.id))
        // Reserve ~1 slot per not-started game (+/- a little per-bot variance),
        // but always keep a majority of real confirmed starters (>= slots-4).
        let target = min(notStarted.count + Int.random(in: 0...1), max(1, slots.count - 4))
        var rr = Int.random(in: 0..<notStarted.count)   // round-robin start for spread
        func reservedCount() -> Int { result.filter { notStarted.contains($0.gameID ?? "") }.count }

        for slotIdx in result.indices.shuffled() {
            if reservedCount() >= target { break }
            // Only convert a slot currently held by a STARTED-game player.
            guard startedSet.contains(result[slotIdx].gameID ?? "") else { continue }
            let pos = slots[slotIdx]
            var placeholder: DFSPlayer? = nil
            for offset in 0..<notStarted.count {
                let gid = notStarted[(rr + offset) % notStarted.count]
                placeholder = poolForReservation.filter {
                    $0.gameID == gid && !used.contains($0.id)
                        && (pos == nil || playerMatchesSlot($0, slot: pos!))
                }.min(by: { $0.salary < $1.salary })
                if placeholder != nil { rr = (rr + offset + 1) % notStarted.count; break }
            }
            guard let pick = placeholder else { continue }
            used.remove(result[slotIdx].id)
            used.insert(pick.id)
            result[slotIdx] = pick
        }
        return result
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
            // NHL DNP-tightening pass — mirrors the NBA pattern. Old floors
            // (SG 5.0, classic 6.0) still admitted 4th-liners projected
            // 5-7 FPPG who DNP routinely in playoff slates. NBA went to
            // 12.0 SG / 8.0 classic and the field got noticeably more
            // competitive. NHL skater projections sit lower than NBA so
            // we don't go that high, but bumping both tiers cuts the
            // deep-bench DNP risk that still leaked through.
            //   SG 7.0 → excludes most bottom-six guys (typically 4-7 FPPG),
            //   keeps the value-tier $3.5K-$5K rotation regulars (8+ FPPG).
            //   Classic 8.0 → same effect on the wider 9-player roster.
            projFloor = isSingleGame ? 7.0 : 8.0
        } else if effectiveSport == "NBA" || effectiveSport == "NCAAM" {
            // NBA rotation players score 15+ FPPG (and stars 30+). Deep-bench
            // players like Lindy Waters (~$4,700 UTIL) sit around 6-10 FPPG and
            // routinely DNP — they get injected into the pool via Phase 2.5
            // because DK lists them on the SG slate, but bots shouldn't draft
            // them. SG floors run higher because rotations tighten in playoff
            // single-game slates.
            //
            // SG dropped 12.0 → 10.0 — the 12.0 floor was excluding legit
            // mid-tier rotation guys (Landry Shamet tier, 10-12 FPPG) entirely,
            // which left them at 0% ownership when they should have been
            // marginal-tier picks. 10.0 still cuts the 6-9 FPPG deep-bench
            // DNP risk but admits the rotation regulars who occasionally crack
            // a starting role.
            projFloor = isSingleGame ? 10.0 : 8.0
        } else {
            projFloor = 1.0
        }
        // For NHL we have a `playedRecently` flag derived from recent boxscores. If any
        // skaters on a team are flagged active, we use that signal to exclude DNPs that
        // are technically still rostered (retired, healthy scratches, AHL assignments).
        let nhlHasRecencyData = effectiveSport == "NHL" && players.contains { $0.playedRecently }

        let eligible = players.filter { p in
            let status = p.injuryStatus ?? ""
            var isOut = status == "O" || status == "D" || status.hasPrefix("IL")
            // NHL: GTD players frequently don't dress — exclude from bot pool
            if effectiveSport == "NHL" && status == "GTD" { isOut = true }
            // NHL: require minimum games played to filter AHL call-ups, healthy
            // scratches, and part-time players. Both tiers bumped to match
            // the projection-floor tightening pass:
            //   SG 40 GP → playoff rotation regulars only (~half a season)
            //   Classic 30 GP → established roster guys, not call-ups
            let minGP = effectiveSport == "NHL" ? (isSingleGame ? 40 : 30) : 20
            if effectiveSport == "NHL", let gp = p.gamesPlayed, gp < minGP { isOut = true }
            // NHL: when recency data is available, require skaters to have played recently.
            // This catches DNPs that pass the GP threshold (retired mid-season, prolonged
            // healthy scratch, etc.) — goalies are exempt since they cycle starts.
            if nhlHasRecencyData, p.position != "G", !p.playedRecently { isOut = true }
            // NHL SG: hard-require recent play for skaters regardless of the
            // global `nhlHasRecencyData` flag. Previously this gate only fired
            // when SOME other player had recency data — but a team whose last
            // game fell outside the 7-day lookback (rest days between playoff
            // rounds, etc.) had no recency for ANY of its skaters, leaving
            // `playedRecently=false` defaults to slip through. Strict required
            // recency at the per-player level eliminates that escape hatch.
            // Combined with isConfirmedActive (DK salary list) this gives the
            // two-signal confirmation: dressed last game AND on tonight's DK
            // slate.
            if effectiveSport == "NHL" && isSingleGame && p.position != "G" {
                if !p.isConfirmedActive || !p.playedRecently { isOut = true }
            }
            // NHL SG goalies: ONLY confirmed starters allowed. The previous
            // logic un-excluded starters but didn't exclude backups — so a
            // team's backup goalie (high salary, sitting on the bench) could
            // still end up in 20%+ of bot lineups. Exclude any goalie that
            // isn't the confirmed starter for tonight's game.
            if effectiveSport == "NHL" && isSingleGame && p.position == "G" && !p.isStartingGoalie {
                isOut = true
            }
            // NHL single-game: confirmed starting goalies are NEVER excluded regardless of GP
            if effectiveSport == "NHL" && p.position == "G" && p.isStartingGoalie { isOut = false }
            // Confirmed starting goalies bypass the projection floor entirely —
            // a call-up making his first starts (Bussi) projects ~0.0 from
            // career stats but is still THE goalie bots must draft.
            if effectiveSport == "NHL" && p.position == "G" && p.isStartingGoalie {
                return !isOut
            }
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
        let strictBotPool: [DFSPlayer]
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

            // Soccer: `isConfirmedActive` is set when ESPN publishes the
            // starting XI (~1h before kickoff). Use confirmed players
            // exclusively when they cover all positions — bench/squad
            // players have meaningful projections (squad rotation, late
            // subs) and would otherwise slip into bot lineups through the
            // "likelyStarters" projection path below. Mirrors the MLB
            // `battingOrder` lock.
            let isSoccerLeague = effectiveSport == "EPL" || effectiveSport == "UCL" || effectiveSport == "WC"
            // Projected-starter tier, per-team aware: for any team whose XI is
            // already announced use ONLY its confirmed starters (unconfirmed
            // players on that team are benched, not "projected"); for teams
            // without an XI yet, fall back to recent-match participants
            // (warm-up friendlies for the World Cup).
            let soccerHybridPool: [DFSPlayer] = {
                guard isSoccerLeague else { return [] }
                let xiTeams = Set(eligible.filter { $0.isConfirmedActive && !$0.team.isEmpty }.map(\.team))
                // Teams without an announced XI that DID get a likely-starter
                // signal (ESPN predicted XI or a recent-match starter — see
                // SoccerDFSData's `playedRecently` marking). For these we trust
                // that signal and DON'T pull in extra players by salary: a
                // high price alone doesn't mean a player starts (stars get
                // rested/rotated), and rostering DNPs is exactly what we want
                // to avoid.
                let likelyStarterTeams = Set(eligible.filter { $0.playedRecently && !$0.team.isEmpty }.map(\.team))
                // Last resort: a team with NEITHER an announced XI NOR any
                // likely-starter signal (no predicted XI published, no recent
                // matches in the lookback) would contribute zero players and
                // land at 0% bot ownership — the original late-game bug. Only
                // for those signal-less teams do we fall back to top salaries
                // as a rough XI proxy, so every game still gets representation.
                var salaryProxyIDs = Set<String>()
                let signalLessTeams = Set(eligible.map(\.team))
                    .subtracting(xiTeams)
                    .subtracting(likelyStarterTeams)
                    .subtracting([""])
                for team in signalLessTeams {
                    let topBySalary = eligible.filter { $0.team == team }
                        .sorted { $0.salary > $1.salary }
                        .prefix(11)
                    salaryProxyIDs.formUnion(topBySalary.map(\.id))
                }
                if !signalLessTeams.isEmpty {
                    print("[DFS-\(effectiveSport)] Bot pool: no XI/recency signal for \(signalLessTeams.sorted()) — using top salaries as XI proxy")
                }
                return eligible.filter { p in
                    if xiTeams.contains(p.team) { return p.isConfirmedActive }
                    if likelyStarterTeams.contains(p.team) { return p.playedRecently }
                    return salaryProxyIDs.contains(p.id)
                }
            }()
            // Prefer the hybrid pool: it already restricts announced teams to
            // their confirmed XI, so it equals the confirmed-only pool when
            // every game's XI is out — but on a MIXED slate (early game
            // announced, late game still projected) confirmed-only would
            // exclude the unannounced game entirely. Hybrid keeps that game's
            // likely starters in the field. The 1.3x confirmed boost in the
            // weighting below still leans bots toward the announced certainties.
            if isSoccerLeague && soccerHybridPool.count >= lineupSize * 2 && coversAllSlots(soccerHybridPool) {
                print("[DFS-\(effectiveSport)] Bot pool: using \(soccerHybridPool.count) starters (confirmed XI where announced, recent/likely starters elsewhere)")
                strictBotPool = soccerHybridPool
            } else if isSoccerLeague && useConfirmedPool && coversAllSlots(confirmed) {
                strictBotPool = confirmed
            } else {

            let confirmedStarters = basePool.filter { $0.battingOrder != nil || $0.position == "SP" }
            if effectiveSport == "MLB" && !confirmedStarters.isEmpty {
                mlbHasBattingOrders = true
            }
            if confirmedStarters.count >= lineupSize + 5 && coversAllSlots(confirmedStarters) {
                // Batting orders available and cover all positions — use confirmed starters only
                strictBotPool = confirmedStarters
            } else if effectiveSport == "MLB" && mlbHasBattingOrders && coversAllSlots(confirmedStarters) {
                // Some batting orders available but not enough to fill pool exclusively —
                // use full pool but weighting will heavily prefer confirmed starters
                strictBotPool = basePool
            } else {
                // Batting orders not yet posted or don't cover all positions —
                // use projection/salary as a proxy.
                let likelyStarters = basePool.filter { $0.projectedPoints >= 6.0 || $0.position == "SP" || $0.position == "G" }
                if likelyStarters.count >= lineupSize * 2 && coversAllSlots(likelyStarters) {
                    strictBotPool = likelyStarters
                } else {
                    // Fall back to full eligible pool (confirmed first, then all)
                    strictBotPool = useConfirmedPool && coversAllSlots(confirmed) ? confirmed : eligible
                }
            }

            }  // close soccer-confirmed-XI else wrapper
        } else {
            // NHL, NBA, NCAAM — use confirmed active pool when available
            if useConfirmedPool {
                strictBotPool = confirmed
            } else {
                strictBotPool = eligible
            }
        }

        // For NHL, restrict the upgrade pass to confirmed-active players only
        // to prevent swapping in healthy scratches during salary optimization.
        // For MLB, restrict to confirmed starters when batting orders are available
        // to prevent upgrading into bench players who will score 0.
        let upgradePool: [DFSPlayer]
        if effectiveSport == "NHL" && !confirmed.isEmpty {
            // NHL classic: confirmed pool is fine. NHL single-game pool is
            // tight enough (~10 confirmed players for 6 slots) that the
            // upgrade pass runs out of candidates after 1-2 swaps and
            // leaves bots underspending the cap. Use the broader `eligible`
            // pool for SG upgrades — it still enforces GP/projection/recency
            // filters, just doesn't require the (sometimes-sparse) RG
            // salary match.
            upgradePool = isSingleGame ? eligible : confirmed
        } else if effectiveSport == "MLB" && mlbHasBattingOrders {
            let starterUpgrades = strictBotPool.filter { $0.battingOrder != nil || $0.position == "SP" }
            upgradePool = starterUpgrades.isEmpty ? strictBotPool : starterUpgrades
        } else {
            upgradePool = strictBotPool
        }

        // Pool collapse handling. The old fallback was
        // `players.shuffled().prefix(lineupSize)` — PURE RANDOM lineups,
        // scratches and backup goalies included, no cap discipline. That's
        // where the $35K / 4-DNP bot fields came from whenever the strict
        // gates rejected everyone (e.g. SG pools missing recency flags).
        // Instead, relax the ACTIVITY gates step by step while never
        // relaxing the safety rules: no injured players, no non-starting
        // NHL SG goalies.
        let botPool: [DFSPlayer] = {
            if strictBotPool.count >= lineupSize { return strictBotPool }
            if eligible.count >= lineupSize {
                print("[DFS-\(effectiveSport)] Bot pool collapsed to \(strictBotPool.count) — using \(eligible.count) eligible players")
                return eligible
            }
            let relaxed = players.filter { p in
                let status = p.injuryStatus ?? ""
                let injured = status == "O" || status == "D" || status == "GTD" || status.hasPrefix("IL")
                if injured { return false }
                if effectiveSport == "NHL" && isSingleGame && p.position == "G" && !p.isStartingGoalie { return false }
                return true
            }
            print("[DFS-\(effectiveSport)] Bot pool collapsed to \(strictBotPool.count)/\(eligible.count) — relaxed activity gates to \(relaxed.count) healthy players")
            return relaxed.count >= lineupSize ? relaxed : players
        }()
        guard botPool.count >= lineupSize else {
            // Truly nothing to draft from (pool smaller than a lineup) —
            // return best-effort by projection rather than random.
            return players.sorted { $0.projectedPoints > $1.projectedPoints }.prefix(lineupSize).map(\.id)
        }

        // Scramble projections so each bot sees a different player landscape.
        // This is the primary source of lineup diversity.
        // Single-game contests have small pools (~12 players for 6 slots), so
        // use much heavier noise + random exclusions to prevent identical lineups.
        // Soccer/EPL/UCL needs very heavy noise because the confirmed starter pool
        // is tiny (~22 players for 8 slots) and projections cluster tightly.
        let avgProj = botPool.reduce(0.0) { $0 + $1.projectedPoints } / Double(botPool.count)
        let isSoccer = effectiveSport == "EPL" || effectiveSport == "UCL" || effectiveSport == "WC"
        let noiseMagnitude: Double
        if isSingleGame {
            // 35% noise (was 70%). The old setting made every bot's
            // projection landscape nearly random, so 2000-entry NHL/MLB SG
            // contests had ~0 sharp lineups — top bot routinely sat at
            // ~87 FPTS when an optimized lineup should hit 110+. Tighter
            // noise lets sharp bot styles actually lean on projection.
            noiseMagnitude = max(avgProj * 0.35, 2.0)
        } else if isSoccer {
            noiseMagnitude = max(avgProj * 1.0, 6.0) // 100% noise for soccer — pool is tiny
        } else {
            noiseMagnitude = max(avgProj * 0.35, 2.0)
        }
        // Bot personality — defined here so SG exclusion logic can gate
        // on style (sharp styles skip exclusions to keep top players in
        // their view).
        let botStyle = Int.random(in: 0..<5)

        // Single-game & soccer: randomly exclude players to force different combinations.
        // Soccer pools are tiny (~22 starters for 8 slots) so excluding 3-6 players
        // is the strongest lever for lineup diversity.
        var sgExcludedIDs = Set<String>()
        if isSingleGame && botPool.count > lineupSize + 2 {
            // MLB single-game: exclude 2-4 starters for maximum diversity with ~18 batters.
            // NHL: stricter — only 60% of bots get an exclusion at all, and
            // those exclude only 1 player. Most NHL SG pools are 10-12
            // confirmed players for 6 slots; aggressive exclusions removed
            // top stars from sharp bots' view, capping leaderboard scores.
            // Casual bots (style 4 default) still get random exclusions to
            // preserve some lineup diversity.
            let maxExclude: Int
            if effectiveSport == "MLB" {
                maxExclude = min(4, botPool.count - lineupSize - 1)
            } else if effectiveSport == "NHL" {
                // Skip exclusion for sharp styles (0-2); only casual styles
                // 3-4 see exclusions, and only 40% of them.
                if botStyle >= 3 && Double.random(in: 0...1) < 0.4 {
                    maxExclude = min(1, botPool.count - lineupSize - 1)
                } else {
                    maxExclude = 0
                }
            } else {
                maxExclude = min(2, botPool.count - lineupSize - 1)
            }
            if maxExclude > 0 {
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
            }
        } else if isSoccer && botPool.count > lineupSize + 3 {
            // Exclude 3-6 players per bot to force very different combinations.
            // With ~22 starters and 8 slots, excluding 3-6 is aggressive but necessary.
            let maxExclude = min(6, botPool.count - lineupSize - 1)
            let excludeCount = maxExclude > 3 ? Int.random(in: 3...maxExclude) : max(1, maxExclude)
            // Bias exclusions toward PROJECTED (late-game, unconfirmed)
            // players: consume them first, only reaching confirmed starters
            // if a bot needs more exclusions than there are projected players.
            // This keeps confirmed starters in most lineups (heavy confirmed
            // lean) while late-game stars cycle in and out across the field —
            // the variance the user wants on the later games without letting
            // those riskier picks dominate ownership.
            let projectedFirst = botPool.filter { !$0.isConfirmedActive }.shuffled()
                + botPool.filter { $0.isConfirmedActive }.shuffled()
            for p in projectedFirst.prefix(excludeCount) {
                sgExcludedIDs.insert(p.id)
            }
        }
        let scrambled: [DFSPlayer] = botPool.compactMap { p in
            if sgExcludedIDs.contains(p.id) { return nil }
            let noise = Double.random(in: -noiseMagnitude...noiseMagnitude)
            // Mixed soccer slates (early game XI announced, late game still
            // projected): lean HEAVILY on CONFIRMED starters — they're a
            // certainty; projected late-game players carry rotation risk.
            // The 1.5x boost (with the projected-biased exclusion below)
            // keeps confirmed starters as the backbone of most bot lineups
            // while still letting high-projection late-game stars surface.
            var baseProj = p.projectedPoints
            if isSoccer && p.isConfirmedActive { baseProj *= 1.5 }
            // Soccer staggered slates: an UNCONFIRMED player is a later-game
            // slot whose XI isn't out yet — a placeholder the late-swap pass
            // will upgrade to a confirmed starter once that game's lineup
            // posts. Bias bots toward CHEAP unconfirmed fills, scaled by price:
            //   (a) stops bots over-rostering expensive non-starters (the $8K
            //       Ollie Watkins problem — he isn't confirmed but his price
            //       pulled him into 16% of lineups), and
            //   (b) reserves salary so the late swap can actually afford the
            //       confirmed late-game studs (Luis Díaz $9.5K, Suárez $8K)
            //       that were landing at 0% because the budget was already
            //       spent on early-game certainties.
            if isSoccer && !p.isConfirmedActive {
                // priceFactor ~1.0 when the player costs an average slot's
                // worth of cap, higher when pricier. Pricier => bigger cut.
                let priceFactor = Double(p.salary) / (Double(salaryCap) / Double(max(1, lineupSize)))
                baseProj *= max(0.35, 1.0 - 0.45 * priceFactor)
            }
            let newProj = max(baseProj + noise, 0.5)
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
            // Single-game: bump spend floor toward cap so bots actually use ~$50K,
            // not the ~$38K we were seeing. Small pools still get variance from
            // bot styles and weighted picking; the floor just ensures the lineup
            // ISN'T under-spent.
            switch effectiveSport {
            case "MLB":
                minSpendPct = Double.random(in: 0.92...0.99) // $46K-$49.5K of $50K
            case "NHL", "NBA", "NCAAM":
                minSpendPct = Double.random(in: 0.94...0.99) // $47K-$49.5K of $50K
            default:
                minSpendPct = Double.random(in: 0.90...0.98)
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

        // (botStyle hoisted up to where SG exclusions need it)

        // NHL single-game (Showdown): 20% of bots skip goalies entirely so ownership
        // settles around ~80% instead of 100% (real DK ownership is rarely that lopsided).
        let nhlSkipGoalie = effectiveSport == "NHL" && isSingleGame && Double.random(in: 0...1) < 0.20

        // Try up to 50 times to build a valid lineup (more retries needed for tight 95% floors)
        for _ in 0..<50 {
            var selectedBySlot: [Int: DFSPlayer] = [:]
            var budgetLeft = salaryCap
            var usedIDs = Set<String>()
            var pool = nhlSkipGoalie ? scrambled.filter { $0.position != "G" } : scrambled

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
                        // Sharper SG mix. The previous exponents (0.5, 0.8,
                        // 1.2, 0.6, 1.0) were so flat that every bot drafted
                        // near-randomly — for a 2000-entry SG that's wrong:
                        // real DFS has a "sharp" upper tier that drafts close
                        // to optimal. New distribution gives ~40% of bots a
                        // genuinely projection/value-driven build while still
                        // keeping ~20% casual for diversity.
                        switch botStyle {
                        case 0: w = pow(max(value, 0.1), 2.2)                        // Sharp value
                        case 1: w = pow(proj, 2.0)                                   // Sharp projection
                        case 2: w = pow(proj, 1.5) * pow(max(value, 0.1), 0.8)       // Balanced sharp
                        case 3: w = pow(proj, 1.2)                                   // Mild stars lean
                        default: w = pow(proj, 0.7)                                  // Casual
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
                            // the confirmed starter should appear in 30-50%+ of lineups.
                            // 150x overcomes the random variance (0.3-1.0) and MVP sqrt
                            // flattening to consistently land goalies in bot rosters.
                            w *= isSingleGame ? 150.0 : 10.0
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
                    // Captain (MVP) diversity for single-game: mild flatten
                    // so the chalk MVP doesn't reach 100%, but sharp bots
                    // still concentrate on the top projection. Was sqrt
                    // (0.5) — that was so aggressive it spread MVP ownership
                    // evenly across all 6 players, which is why top bots
                    // missed obvious MVP picks. 0.75 = mild flatten.
                    if mvpPick {
                        w = pow(w, 0.75)
                    }
                    // Ownership variance: random dampening so no single
                    // player hits 100% ownership. SG uses a tighter range
                    // (0.6-1.0) so sharp bots still draft the top players;
                    // the wider 0.3-1.0 range was strong enough to
                    // randomly downweight a 25-FPTS stud into a 4-FPTS
                    // slot, which is exactly how 87-FPTS top lineups
                    // were happening.
                    let varianceRange: ClosedRange<Double> = isSingleGame ? 0.6...1.0 : 0.3...1.0
                    let varianceFactor = Double.random(in: varianceRange)
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
                // Bumped 1-2 → 3-5: the prior lighter setting left bots
                // routinely under the minSpend floor on NHL/NBA SG slates,
                // so they kept falling through to the (less constrained)
                // greedy fallback and underspending the cap.
                upgradePassCount = Int.random(in: 3...5)
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
                return reserveNotStartedGameSlots(selected, slots: slots, poolForReservation: players).map(\.id)
            }
        }

        // Fallback: greedy approach that targets salary spending.
        // For NHL, sort by salary descending to pick expensive players first.
        var fallback: [DFSPlayer] = []
        var fb_budget = salaryCap
        var fb_usedIDs = Set<String>()
        var fb_pool = (nhlSkipGoalie ? scrambled.filter { $0.position != "G" } : scrambled).shuffled()
        for pickIndex in 0..<lineupSize {
            let slotsLeft = lineupSize - fallback.count
            let slotsAfter = slotsLeft - 1
            let reserveRest = slotsAfter * cheapestSalary
            var affordable = fb_pool.filter { $0.salary <= fb_budget - reserveRest }
            if let requiredPos = slots[pickIndex] {
                affordable = affordable.filter { playerMatchesSlot($0, slot: requiredPos) }
            }
            // If the reserve math leaves no affordable option, relax it: any unused player
            // that fits the remaining budget for this single pick is acceptable. Better to
            // produce a complete lineup that underspends than a short lineup.
            if affordable.isEmpty {
                let mvpFactor = (isSingleGame && pickIndex == 0) ? 1.5 : 1.0
                var relaxed = fb_pool.filter { Int(Double($0.salary) * mvpFactor) <= fb_budget }
                if let requiredPos = slots[pickIndex] {
                    let positional = relaxed.filter { playerMatchesSlot($0, slot: requiredPos) }
                    if !positional.isEmpty {
                        relaxed = positional
                    } else if isSoccer || requiredPos == "GK" || requiredPos == "G" {
                        // NEVER mis-slot a position-strict spot (a defender in the
                        // GK slot, etc.). Leave it empty — the position-aware pad
                        // below fills it from the full pool, pulling a cheap keeper
                        // from another game if the early games' keepers are used up.
                        relaxed = []
                    }
                }
                affordable = relaxed
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

        // Run upgrade pass on fallback to push spending toward cap. Use up to 10
        // iterations and prefer the MOST expensive affordable upgrade so a starting
        // total of ~75% of cap can climb to 95% even when individual swaps are small.
        if fallback.count == lineupSize {
            for _ in 0..<10 {
                let currentTotal = fbEffectiveSalary(fallback)
                if currentTotal >= salaryCap - 500 { break }
                let sortedByPrice = fallback.enumerated().sorted { $0.element.salary < $1.element.salary }
                var didUpgrade = false
                for (idx, cheapPlayer) in sortedByPrice {
                    let currentSpent = fbEffectiveSalary(fallback)
                    if currentSpent >= salaryCap - 500 { break }
                    let slack = salaryCap - currentSpent
                    let requiredPos = slots[idx]
                    // For MVP slot (idx 0 in single-game), the effective cost increase is
                    // 1.5x the salary delta, so the max usable salary uplift is slack/1.5.
                    let isMVPSlot = isSingleGame && idx == 0
                    let maxRawSalaryIncrease = isMVPSlot ? Int(Double(slack) / 1.5) : slack
                    let upgradeCandidates = upgradePool.filter { candidate in
                        !fb_usedIDs.contains(candidate.id)
                        && candidate.salary > cheapPlayer.salary
                        && candidate.salary <= cheapPlayer.salary + maxRawSalaryIncrease
                        && (requiredPos == nil || self.playerMatchesSlot(candidate, slot: requiredPos!))
                    }
                    if let upgrade = upgradeCandidates.max(by: { $0.salary < $1.salary }) {
                        fb_usedIDs.remove(cheapPlayer.id)
                        fb_usedIDs.insert(upgrade.id)
                        fallback[idx] = upgrade
                        didUpgrade = true
                    }
                }
                if !didUpgrade { break }
            }
        }

        // Pad each still-empty slot with the cheapest unused player that ACTUALLY
        // fits that slot's position — from `eligible`, then the full `players`
        // pool. Slot-aware so a defender never lands in the GK slot (the bug the
        // old position-blind pad caused), and so a scarce position (a 2nd/3rd
        // keeper) gets pulled from another game when the early games' starters at
        // that position are used up. A complete lineup that underspends beats the
        // saved-bot validation rejecting the entry and looping on regeneration.
        if fallback.count < lineupSize {
            var usedIDs = Set(fallback.map(\.id))
            func cheapestFit(_ source: [DFSPlayer], pos: String?) -> DFSPlayer? {
                source.filter {
                    !usedIDs.contains($0.id) && (pos == nil || playerMatchesSlot($0, slot: pos!))
                }.min(by: { $0.salary < $1.salary })
            }
            while fallback.count < lineupSize {
                let requiredPos = slots[fallback.count]
                var pick = cheapestFit(eligible, pos: requiredPos) ?? cheapestFit(players, pos: requiredPos)
                // Non-soccer last resort: any unused player (their slot rules are
                // already permissive via playerMatchesSlot). Soccer keeps the
                // position exact — if no keeper/etc. exists anywhere, the lineup
                // stays short and is retried rather than mis-slotted.
                if pick == nil && !isSoccer {
                    pick = (eligible + players).first { !usedIDs.contains($0.id) }
                }
                guard let chosen = pick else { break }
                fallback.append(chosen)
                usedIDs.insert(chosen.id)
            }
        }

        // Force-spend safety net. The greedy fallback + upgrade loop above
        // can still leave a bot well under-spent — observed live: an NHL SG
        // bot spent $23,100 of $50K. That happens when the fallback's
        // upgrade pool runs out of meaningful candidates after a few swaps
        // and the `didUpgrade = false` break exits prematurely. Run an
        // aggressive last-resort pass: until we're at ~92% of cap (or we've
        // tried every cheap-slot/expensive-swap combo), swap the lineup's
        // cheapest player for the most expensive unused player whose
        // salary fits in remaining slack. Pulls from the full `eligible`
        // pool so the upgrade pool isn't constrained to the tiny SG
        // confirmed list.
        if fallback.count == lineupSize {
            func fbSafetyEffective(_ lineup: [DFSPlayer]) -> Int {
                if isSingleGame && !lineup.isEmpty {
                    return Int(Double(lineup[0].salary) * 1.5) + lineup.dropFirst().reduce(0) { $0 + $1.salary }
                }
                return lineup.reduce(0) { $0 + $1.salary }
            }
            let safetyTarget = Int(Double(salaryCap) * 0.92)
            var safetyUsedIDs = Set(fallback.map(\.id))
            for _ in 0..<30 {
                let totalSpent = fbSafetyEffective(fallback)
                if totalSpent >= safetyTarget { break }
                let slack = salaryCap - totalSpent
                let sortedByCost = fallback.enumerated().sorted {
                    let cost0 = (isSingleGame && $0.offset == 0) ? Int(Double($0.element.salary) * 1.5) : $0.element.salary
                    let cost1 = (isSingleGame && $1.offset == 0) ? Int(Double($1.element.salary) * 1.5) : $1.element.salary
                    return cost0 < cost1
                }
                var didSwap = false
                for (idx, cheapPlayer) in sortedByCost {
                    let isMVPSlot = isSingleGame && idx == 0
                    let maxSalaryIncrease = isMVPSlot ? Int(Double(slack) / 1.5) : slack
                    let maxNewSalary = cheapPlayer.salary + maxSalaryIncrease
                    let requiredPos = slots[idx]
                    let candidates = eligible.filter { c in
                        !safetyUsedIDs.contains(c.id)
                        && c.salary > cheapPlayer.salary
                        && c.salary <= maxNewSalary
                        && (requiredPos == nil || self.playerMatchesSlot(c, slot: requiredPos!))
                    }
                    if let upgrade = candidates.max(by: { $0.salary < $1.salary }) {
                        safetyUsedIDs.remove(cheapPlayer.id)
                        safetyUsedIDs.insert(upgrade.id)
                        fallback[idx] = upgrade
                        didSwap = true
                        break // restart the inner sort so the new "cheapest" is targeted next iteration
                    }
                }
                if !didSwap { break }
            }
        }

        let result = (fallback.count == lineupSize
            ? reserveNotStartedGameSlots(fallback, slots: slots, poolForReservation: players)
            : fallback).map(\.id)
        if result.isEmpty || result.count < lineupSize {
            print("[DFS-\(effectiveSport)] generateBotLineup returned \(result.count)/\(lineupSize) players. eligible=\(eligible.count), botPool=\(botPool.count), rosterSlots=\(rosterSlots?.description ?? "nil")")
        }
        return result
    }

    /// ADMIN / TESTING: force a fresh regeneration of the ACTIVE contest's bot
    /// field with the current bot logic. Clears the shared server `bot_field`
    /// and local caches, regenerates via refreshLive, then re-persists so every
    /// device picks up the new field. NOTE: the bot field is shared by every
    /// entrant, so this reshuffles the live leaderboard for the whole contest —
    /// gated to admin accounts in the UI. Returns the number of bots regenerated.
    @discardableResult
    func adminRegenerateBotField() async -> Int {
        guard let tournament, let token = accessToken else { return 0 }
        let tid = tournament.id
        // 1. Clear the shared server field so other devices regenerate too.
        try? await SupabaseService.shared.saveBotField(tournamentID: tid, botField: [], accessToken: token)
        // 2. Drop local bots + the cached field so refreshLive can't restore the
        //    old lineups (keep the real user/opponent rows).
        fieldEntries = fieldEntries.filter { $0.isCurrentUser || $0.isRealUser }
        fieldGenerated = false
        liveContestCache.removeValue(forKey: tid)
        // 3. Regenerate in memory against the current slate + bot logic.
        await refreshLive()
        // 4. Persist the freshly generated bots so the shared field updates
        //    (refreshLive's own save gate won't fire for a locked contest).
        let salaryLookup = Dictionary(activePlayers.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
        let botEntries = fieldEntries.filter { !$0.isCurrentUser && !$0.isRealUser }.map { entry -> BotFieldEntry in
            let psals: [String: Int] = Dictionary(uniqueKeysWithValues: entry.playerIDs.compactMap { pid -> (String, Int)? in
                guard let sal = salaryLookup[pid], sal > 0 else { return nil }
                return (pid, sal)
            })
            return BotFieldEntry(name: entry.name, playerIDs: entry.playerIDs, playerSalaries: psals.isEmpty ? nil : psals)
        }
        if !botEntries.isEmpty {
            try? await SupabaseService.shared.saveBotField(tournamentID: tid, botField: botEntries, accessToken: token)
            print("[DFS-\(sport)] ADMIN regenerated + saved \(botEntries.count) bots for \(tid)")
        }
        return botEntries.count
    }

    func refreshLive() async {
        // PGA self-heal for orphaned past tournaments runs BEFORE the
        // `guard let tournament` below, because the bug we're fixing is
        // exactly when this VM has no active tournament (mid-week, or
        // before slate load completes). Without running it here,
        // Memorial-style stale cards stay pinned in Active Contests
        // forever waiting for a "this week" tournament that may never
        // exist for this poll cycle. Each call no-ops unless the scoring
        // provider reports `allGamesFinal=true`, so it's safe to run
        // unconditionally.
        if sport == "PGA", let token = accessToken, let userID = userID {
            let activeTID = tournament?.id
            let activeBaseEventID = activeTID.map { pgaBaseEventID(from: $0) } ?? ""
            // Use the entry's `submittedAt` (when available) as the age proxy.
            // Synthetic past tournaments don't store a real lockTime — they
            // fall back to the active tournament's lockTime, which is THIS
            // week's, so a `>2 days` check against `lockTimeForTournament`
            // always returned false and Memorial / older events never
            // self-healed. Submissions happen before lock, so submittedAt
            // is a safe proxy.
            //
            // Also skip any PGA tid whose underlying ESPN event matches the
            // active tournament's event. `pga-401811950-2` and
            // `pga-401811950-2000` are the SAME real-world tournament with
            // different entry-size variants — force-settling the 2000-entry
            // variant on Thursday while the actual Memorial is still being
            // played (the 2-entry active contest covers it) was grading
            // R1-only scores as final. The base-event check defers
            // settlement of every variant until the underlying ESPN event
            // is actually over.
            let stalePGA = enteredTournamentIDs.filter { tid in
                guard tid.hasPrefix("pga-"), tid != activeTID else { return false }
                // Already settled (and persisted) → leave it alone. Re-wiping
                // history + un-settling + deleting server results on every
                // launch (the block below) is exactly what made finished RBC
                // contests flash as LIVE 0.0 each time My Contests opened: the
                // contest got un-settled, rendered as an active card, then
                // re-settled a moment later. Bad/zero settlements are repaired
                // by checkAndSettleUnsettledTournaments and admin re-grade — this
                // path only needs to settle contests that aren't settled yet.
                if settledTournaments.contains(tid) { return false }
                if !activeBaseEventID.isEmpty,
                   pgaBaseEventID(from: tid) == activeBaseEventID {
                    return false
                }
                if let submittedAt = userEntryRecords[tid]?.first?.submittedAt {
                    return Date().timeIntervalSince(submittedAt) > 2 * 24 * 3600
                }
                return true
            }
            print("[PGA-SelfHeal] activeTID=\(activeTID ?? "nil") entered=\(enteredTournamentIDs.count) stale=\(stalePGA.count) healed=\(pgaSelfHealedThisSession.count) settled=\(settledTournaments.count)")
            for tid in stalePGA {
                // Once-per-session: avoid wiping+re-settling on every poll.
                if pgaSelfHealedThisSession.contains(tid) {
                    print("[PGA-SelfHeal] \(tid): already healed this session, skipping")
                    continue
                }
                guard let records = userEntryRecords[tid], let firstRecord = records.first else {
                    print("[PGA-SelfHeal] \(tid): no userEntryRecords, skipping")
                    continue
                }
                // FINALIZE, don't re-grade. The old path WIPED an already-graded
                // event's result (subtracting its RR), deleted the server rows,
                // and re-graded from scratch on EVERY session. A PGA event a few
                // days+ out grades inconsistently (ESPN serves partial/no data
                // for a finished event), so its RR flip-flopped on each launch —
                // the churn the user hit. Instead: if this event already has a
                // result in history, KEEP it, persist the settled flag so it
                // drops out of the stale set permanently, and never touch it
                // again. A genuinely-wrong old grade can still be corrected with
                // the admin Re-grade action.
                if dfsHistory.contains(where: { $0.tournamentId == tid }) {
                    print("[PGA-SelfHeal] \(tid): already graded — finalizing (no re-grade)")
                    markTournamentSettled(tid)
                    pgaSelfHealedThisSession.insert(tid)
                    continue
                }
                // No result yet — grade ONCE (nothing to wipe). `settle…`
                // handles multi-lineup users internally; one call is enough.
                print("[PGA-SelfHeal] \(tid): no result yet — grading once (records=\(records.count))")
                await settleUnsettledPastGolfTournament(
                    tournamentID: tid, userEntry: firstRecord,
                    forceFinal: true,
                    token: token, userID: userID
                )
                if settledTournaments.contains(tid) {
                    print("[PGA-SelfHeal] \(tid): SETTLED successfully — latching")
                    pgaSelfHealedThisSession.insert(tid)
                } else {
                    // Never gradeable (ESPN no longer serves this event's scores).
                    // Once it's clearly finished (>3d since submit — PGA finals
                    // post within hours, so a still-ungradeable entry never will),
                    // GHOST it permanently: drop it from entries + mark settled so
                    // it stops retrying and can never churn RR again. It scored
                    // nothing (no history), so nothing is lost.
                    let submittedAt = firstRecord.submittedAt ?? .distantPast
                    let daysStale = Date().timeIntervalSince(submittedAt) / (24 * 3600)
                    if daysStale > 3 {
                        print("[PGA-SelfHeal] \(tid): \(Int(daysStale))d ungradeable — ghosting permanently")
                        enteredTournamentIDs.remove(tid)
                        userEntryRecords[tid] = nil
                        markTournamentSettled(tid)
                        pgaSelfHealedThisSession.insert(tid)
                    } else {
                        print("[PGA-SelfHeal] \(tid): not gradeable yet — retry next cycle")
                    }
                }
            }
        }

        // The rest of refreshLive operates on the active tournament.
        // If there isn't one (mid-week PGA, pre-slate-load, etc.), the
        // self-heal above is the only work to do this cycle — bail here.
        guard var tournament else { return }

        // NHL: pick up starting-goalie announcements that landed after the
        // slate loaded (throttled; no-op for other sports / once marked).
        await reprobeNHLStartingGoaliesIfNeeded()
        // Soccer: same for confirmed XIs (~75 min before each kickoff).
        await reprobeSoccerConfirmedXIIfNeeded()


        // Defensive: detect when fieldEntries don't actually belong to the
        // current tournament before any other logic runs. Symptom: user
        // toggles between an MLB main-slate contest (10-player bots) and an
        // MLB single-game contest (6-player bots) several times and the SG
        // view ends up displaying 10-player bots. Multiple validation gates
        // upstream already exist, but state can still drift across rapid
        // navigations (cache write races, partial restores). Catching it
        // here resets fieldGenerated → the bot-rebuild path below regenerates
        // from the correct slate pool for `tournament.id`, then re-saves
        // both the cache and the server. Drops only the BOT entries — real
        // user/remote entries are preserved.
        if fieldGenerated && !fieldEntries.isEmpty
            && !botsMatchTournament(fieldEntries, tournamentID: tournament.id) {
            print("[DFS-\(sport)] refreshLive: fieldEntries don't match \(tournament.id) (lineup size or pool) — discarding bots and forcing regen")
            fieldEntries = fieldEntries.filter { $0.isCurrentUser || $0.isRealUser }
            fieldGenerated = false
            discardContaminatedCache(tournament.id)
        }

        // Zero-bots guard: a large contest can end up with fieldGenerated=true but
        // a user-ONLY field (server botField was empty and the user-only field
        // slipped past BOTH generation branches: the saved-bots branch needs
        // serverBots, the from-scratch branch needs an EMPTY field). With 0 bots,
        // botsMatchTournament returns true vacuously, so the guard above never
        // fires → permanent shimmer (fieldEntries=1 < the 25 ready threshold).
        // Force a regen so the pad/generate path fills the field. (One-shot:
        // once bots exist the condition is false.)
        if fieldGenerated && tournament.entryCount > 10 && !activePlayers.isEmpty
            && !shouldDeferBotGeneration(for: tournament) {
            let botCount = fieldEntries.filter { !$0.isCurrentUser && !$0.isRealUser }.count
            if botCount == 0 {
                print("[DFS-\(sport)] refreshLive: fieldGenerated but 0 bots for \(tournament.entryCount)-entry \(tournament.id) — forcing regen to pad field")
                fieldGenerated = false
            }
        }

        // Always refresh remote entries to pick up the user's lineup.
        // The function handles both first-load (builds field) and subsequent loads
        // (updates user's entry in existing field).
        await refreshRemoteEntries()

        // Ensure userEntryRecords is populated for this tournament so that
        // selectedPlayers can access lineupPlayerNames for stub name resolution.
        // This is needed when viewing old tournaments not part of the current slate.
        //
        // CRITICAL: filter by BOTH userID AND tournamentID. Previously this
        // only filtered by userID, which created a phantom-contest bug:
        // when the user navigated quickly between tournaments,
        // `refreshRemoteEntries` would discard a late-arriving fetch as
        // stale and leave `remoteEntries` holding the PREVIOUS tournament's
        // entries. This block would then copy those entries into the new
        // tournament's `userEntryRecords` (e.g. eve-2000 entries leaking
        // into mlb-20260605-2), spawning "H2H Heads Up" cards with the
        // user's actual eve-2000 lineup — identical scores included.
        if userEntryRecords[tournament.id] == nil, let uid = userID {
            let myRemote = remoteEntries.filter {
                $0.userID == uid && $0.tournamentID == tournament.id
            }
            if !myRemote.isEmpty {
                userEntryRecords[tournament.id] = myRemote
                enteredTournamentIDs.insert(tournament.id)
            }
        }

        // If no remote entries but user has a local lineup, create a
        // local-only field entry — BUT ONLY if the user has actually
        // submitted to this tournament. Without the `enteredTournamentIDs`
        // gate, opening a small-tournament builder (H2H, 5-Man, etc.) with
        // `selectedPlayerIDs` still populated from a sibling tournament's
        // lineup pre-fill caused settlement to treat the stub as a real
        // submission — writing a phantom `dfs_tournament_results` row, +RR
        // delta, and duplicate past-results card for a contest the user
        // never actually entered.
        if fieldEntries.isEmpty
            && !selectedPlayerIDs.isEmpty
            && enteredTournamentIDs.contains(tournament.id) {
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

        // Re-arm the regen heals for CACHED fields, which otherwise skip the
        // saved-bots validation entirely (fieldGenerated comes back true from
        // the cache/pre-cache). Two triggers:
        //  1. PRE-LOCK ONLY: bots contradict the now-confirmed lineups
        //     (quality refresh while entries are still open).
        //  2. ANY TIME (structural): the random-fallback signature — most
        //     bots spending way under the cap. Such a field was never
        //     validly generated, so repairing it is corruption-repair, not a
        //     mid-contest quality re-roll; without this hook the launch
        //     pre-cache re-accepts the malformed field every session and the
        //     repair in the reload path never gets to run.
        if fieldGenerated,
           !botFieldRegeneratedThisSession.contains(tournament.id),
           !players.isEmpty {
            let cachedBots = fieldEntries.filter { !$0.isCurrentUser && !$0.isRealUser }
            if !cachedBots.isEmpty {
                var rearm = false
                if Date() < lockTimeForTournament(tournament),
                   botsContradictConfirmedLineups(cachedBots.map(\.playerIDs)) {
                    print("[DFS-\(sport)] Pre-lock cached bot field contradicts confirmed lineups — forcing reload so the regen heal can run")
                    rearm = true
                }
                if !rearm {
                    let salaryLookup = Dictionary(activePlayers.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
                    if !salaryLookup.isEmpty {
                        let isSG = tournament.isSingleGame
                        let sample = cachedBots.prefix(50)
                        var under = 0
                        for bot in sample {
                            var total = 0
                            for (i, pid) in bot.playerIDs.enumerated() {
                                let sal = salaryLookup[pid] ?? 0
                                total += (isSG && i == 0) ? Int(Double(sal) * 1.5) : sal
                            }
                            if total < Int(Double(tournament.salaryCap) * 0.75) { under += 1 }
                        }
                        if !sample.isEmpty, Double(under) / Double(sample.count) > 0.5 {
                            print("[DFS-\(sport)] Cached bot field has \(under)/\(sample.count) bots under 75% of cap — random-fallback field, forcing reload for structural repair")
                            rearm = true
                        }
                    }
                }
                if rearm { fieldGenerated = false }
            }
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
                if let sals = serverTournament?.playerSalaries, !sals.isEmpty {
                    tournamentPlayerSalaries[tournament.id] = sals
                }
                // Grade with the captain/showdown format this slate was DRAFTED
                // as, not a re-derived guess. If the persisted flag disagrees
                // with the (possibly synthesized) active tournament, rebuild it
                // so the leaderboard's MVP 1.5x scoring matches how it was played.
                if let persistedSG = serverTournament?.isSingleGame,
                   persistedSG != tournament.isSingleGame {
                    let corrected = DFSTournament(
                        id: tournament.id, title: tournament.title, league: tournament.league,
                        entryCount: tournament.entryCount, lineupSize: tournament.lineupSize,
                        salaryCap: tournament.salaryCap,
                        rosterSlots: persistedSG ? ["MVP", "FLEX", "FLEX", "FLEX", "FLEX", "FLEX"] : tournament.rosterSlots,
                        isSingleGame: persistedSG,
                        tournamentType: tournament.tournamentType,
                        gameID: tournament.gameID, entryFee: tournament.entryFee
                    )
                    if let idx = tournaments.firstIndex(where: { $0.id == tournament.id }) {
                        tournaments[idx] = corrected
                    }
                    tournament = corrected  // fix this pass's downstream scoring too
                    print("[DFS-\(sport)] Applied persisted captain flag (isSingleGame=\(persistedSG)) to \(tournament.id)")
                }
                botValidation: if let serverBots = serverTournament?.botField, !serverBots.isEmpty {
                    // Defense against cross-contamination: when a user
                    // submits a main-slate lineup to a tournament whose
                    // ID was mis-routed (e.g. submitted to the eve-2000
                    // path but logged under an SG tid), bots can end up
                    // saved with the WRONG lineup size for the
                    // tournament. Result: a Red Sox SG showdown contest
                    // ends up with bots that have 10 main-slate players
                    // spread across 9 different games. Filter those out
                    // BEFORE the over-cap check sees them.
                    let expectedSize = tournament.lineupSize
                    let bots: [BotFieldEntry] = expectedSize > 0
                        ? serverBots.filter { $0.playerIDs.count == expectedSize }
                        : serverBots
                    if bots.count != serverBots.count {
                        print("[DFS-\(sport)] Filtered \(serverBots.count - bots.count) cross-contaminated bots (wrong lineup size for \(tournament.id), expected \(expectedSize))")
                    }
                    guard !bots.isEmpty else {
                        print("[DFS-\(sport)] All saved bots had wrong shape for \(tournament.id) — falling through to regen")
                        savedBots = nil
                        needsResave = true
                        // Note: this is OK to regen even when locked because the
                        // saved field is garbage that doesn't belong to this tid.
                        // `break`, NOT `return` — a bare return here aborted ALL
                        // of refreshLive (no regen, no scores), freezing the
                        // contest at whatever partial field was cached.
                        break botValidation
                    }
                    // Validate that saved bots fit within the salary cap
                    // using CURRENT player prices. The slate provider can
                    // change a player's salary between sessions (DK reposts,
                    // showdown-conversion tweaks, etc.) — when that happens,
                    // old saved bot lineups can sum to more than the cap.
                    // Bots over cap break ownership distributions and look
                    // visibly broken in the leaderboard. If >10% of bots
                    // are over cap with current prices, discard the field
                    // and regenerate.
                    let salaryByPID: [String: Int] = Dictionary(players.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
                    let capForCheck = tournament.salaryCap
                    let isSG = tournament.isSingleGame
                    let overCapCount = bots.prefix(100).filter { bot in
                        var total = 0
                        for (idx, pid) in bot.playerIDs.enumerated() {
                            guard let sal = salaryByPID[pid], sal > 0 else {
                                // Player not in current slate (cross-contamination
                                // detected elsewhere) — skip from this check
                                return false
                            }
                            total += (isSG && idx == 0) ? Int(Double(sal) * 1.5) : sal
                        }
                        return total > capForCheck
                    }.count
                    let overCapRate = Double(overCapCount) / Double(min(100, bots.count))
                    let overCapForcedRegen: Bool = {
                        guard overCapRate > 0.1, !players.isEmpty else { return false }
                        // Never regen for a LOCKED tournament. The saved
                        // bot lineups were valid at submit time; if today's
                        // refreshed prices (e.g. after a LineupHQ swap)
                        // make them over cap, that's a display-only quirk —
                        // discarding the field and trying to rebuild 2000
                        // unique lineups from a 26-player SG pool just
                        // fails and shows "Loading contest…" forever.
                        guard !tournamentIsLocked else {
                            print("[DFS] \(Int(overCapRate * 100))% of saved bots exceed cap \(capForCheck), but tournament is LOCKED — keeping saved field as-is")
                            return false
                        }
                        let alreadyRegenerated = botFieldRegeneratedThisSession.contains(tournament.id)
                        guard !alreadyRegenerated else { return false }
                        print("[DFS] \(Int(overCapRate * 100))% of saved bots exceed salary cap \(capForCheck) with current prices — discarding for regen")
                        botFieldRegeneratedThisSession.insert(tournament.id)
                        return true
                    }()
                    // Stale-price detection: even when the bot field fits
                    // under the cap, individual player salaries saved with
                    // the bots can be wildly out-of-date (e.g. a bot saved
                    // Kolek at $4,700 because RG hadn't loaded yet, but the
                    // current slate has him at $1,000). The leaderboard
                    // reads from `bot.playerSalaries` and displays the
                    // stale price — making it look like bots are using
                    // different prices than the user. Compare each bot's
                    // saved salary to the live slate salary; if >20% of
                    // bots have any player with a delta > $1,500, the
                    // field was generated against a stale price source and
                    // should be regenerated.
                    let stalePriceCount = bots.prefix(100).filter { bot in
                        guard let savedSals = bot.playerSalaries, !savedSals.isEmpty else { return false }
                        for (idx, pid) in bot.playerIDs.enumerated() {
                            guard let liveSal = salaryByPID[pid], liveSal > 0 else { continue }
                            let savedRaw = savedSals[pid] ?? 0
                            // Saved MVP slot stores 1.5× — back it out before comparing.
                            let saved = (isSG && idx == 0) ? Int(Double(savedRaw) / 1.5) : savedRaw
                            if saved > 0 && abs(saved - liveSal) > 1500 { return true }
                        }
                        return false
                    }.count
                    let stalePriceRate = Double(stalePriceCount) / Double(min(100, bots.count))
                    let stalePriceForcedRegen: Bool = {
                        guard stalePriceRate > 0.2, !players.isEmpty else { return false }
                        // Locked tournaments freeze prices at lock time — even
                        // if the live slate now disagrees, don't rewrite history.
                        guard !tournamentIsLocked else {
                            print("[DFS] \(Int(stalePriceRate * 100))% of saved bots have stale prices for \(tournament.id), but tournament is LOCKED — keeping saved field")
                            return false
                        }
                        let alreadyRegenerated = botFieldRegeneratedThisSession.contains(tournament.id)
                        guard !alreadyRegenerated else { return false }
                        print("[DFS] \(Int(stalePriceRate * 100))% of saved bots have stale player prices vs current slate — discarding for regen with correct prices")
                        botFieldRegeneratedThisSession.insert(tournament.id)
                        return true
                    }()
                    if overCapForcedRegen {
                        savedBots = nil
                        needsResave = true
                    } else if stalePriceForcedRegen {
                        savedBots = nil
                        needsResave = true
                    } else if tournamentIsLocked {
                        // Tournament is locked — normally we accept saved bots
                        // as-is (lineups freeze at lock time). EXCEPTION: if
                        // this is a multi-game main slate but the saved bots
                        // only cover a tiny fraction of the slate's games
                        // (e.g. all 500 bots' players come from one SG match),
                        // the field is clearly cross-contaminated from another
                        // contest. Reject and force regeneration in that case.
                        // Only check coverage on the FIRST cycle per session.
                        // Once we've regenerated, accept whatever's saved going
                        // forward — the freshly-saved field won't have echoed
                        // back to GET yet, so re-checking would loop endlessly.
                        let alreadyRegenerated = botFieldRegeneratedThisSession.contains(tournament.id)
                        // Cross-sport detection: if a non-trivial chunk of the
                        // saved bots reference player IDs that don't exist in
                        // this slate at all, the bot_field has been clobbered
                        // by another sport's contest. Always reject in that
                        // case, regardless of single-game vs main slate.
                        let slateIDSet = Set(players.map(\.id))
                        let crossSportRate: Double = {
                            guard !slateIDSet.isEmpty else { return 0.0 }
                            var foreign = 0
                            for bot in bots.prefix(50) {
                                if !bot.playerIDs.allSatisfy({ slateIDSet.contains($0) }) {
                                    foreign += 1
                                }
                            }
                            return Double(foreign) / Double(min(50, bots.count))
                        }()
                        if !alreadyRegenerated && crossSportRate > 0.3 {
                            print("[DFS] Tournament locked but \(Int(crossSportRate * 100))% of saved bots reference foreign player IDs — discarding cross-sport-contaminated bot field")
                            savedBots = nil
                            needsResave = true
                            botFieldRegeneratedThisSession.insert(tournament.id)
                        } else {
                        let isMultiGameSlate = !tournament.isSingleGame && slateGames.count > 2
                        if isMultiGameSlate && !alreadyRegenerated {
                            let playerGameMap = Dictionary(players.compactMap { p -> (String, String)? in
                                guard let gid = p.gameID else { return nil }
                                return (p.id, gid)
                            }, uniquingKeysWith: { a, _ in a })
                            let currentGameIDs = Set(slateGames.map { $0.id })
                            var botGameIDs = Set<String>()
                            for bot in bots.prefix(50) {
                                for pid in bot.playerIDs {
                                    if let gid = playerGameMap[pid] {
                                        botGameIDs.insert(gid)
                                    }
                                }
                            }
                            let coverage = currentGameIDs.isEmpty
                                ? 1.0
                                : Double(botGameIDs.intersection(currentGameIDs).count) / Double(currentGameIDs.count)
                            // Guard against false positives when the slate
                            // itself isn't loaded yet (no players → no game
                            // map → no coverage). Don't discard in that case.
                            if !players.isEmpty && coverage < 0.4 {
                                print("[DFS] Tournament locked but saved bots only cover \(botGameIDs.count)/\(currentGameIDs.count) games (\(Int(coverage * 100))%) — discarding cross-contaminated bot field (one-shot)")
                                savedBots = nil
                                needsResave = true
                                botFieldRegeneratedThisSession.insert(tournament.id)
                            } else {
                                savedBots = bots
                                print("[DFS] Tournament locked — using \(bots.count) saved bots as-is for \(tournament.id) (lineups frozen, \(botGameIDs.count)/\(currentGameIDs.count) games covered)")
                            }
                        } else {
                            savedBots = bots
                            print("[DFS] Tournament locked — using \(bots.count) saved bots as-is for \(tournament.id) (lineups frozen at lock time)")
                        }
                        }  // close the cross-sport-detection else wrapper
                    } else {
                        // Tournament not yet locked — validate bots match current slate
                        // NHL SG: if both starting goalies are NOW confirmed but the
                        // saved bots drafted other goalies (field generated before the
                        // announcement), discard and regenerate once with the right
                        // netminders. Wrong-goalie bots are wrong for the whole game.
                        var nhlGoalieMismatch = false
                        if sport == "NHL", tournament.isSingleGame,
                           !botFieldRegeneratedThisSession.contains(tournament.id) {
                            let sgPoolForGoalies: [DFSPlayer] = {
                                if let gid = tournament.gameID, let sg = singleGamePlayers[gid], !sg.isEmpty { return sg }
                                return activePlayers
                            }()
                            let starterIDs = Set(sgPoolForGoalies.filter { $0.position == "G" && $0.isStartingGoalie }.map(\.id))
                            let allGoalieIDs = Set(sgPoolForGoalies.filter { $0.position == "G" }.map(\.id))
                            if starterIDs.count >= 2 {
                                var wrongGoalieBots = 0
                                for bot in bots.prefix(50) {
                                    let botGoalies = bot.playerIDs.filter { allGoalieIDs.contains($0) }
                                    if botGoalies.contains(where: { !starterIDs.contains($0) }) { wrongGoalieBots += 1 }
                                }
                                let rate = Double(wrongGoalieBots) / Double(min(50, bots.count))
                                if rate > 0.15 {
                                    print("[DFS-NHL] \(Int(rate * 100))% of saved bots drafted non-starting goalies — regenerating pre-lock with confirmed starters")
                                    nhlGoalieMismatch = true
                                    botFieldRegeneratedThisSession.insert(tournament.id)
                                }
                            }
                        }
                        // Verify bot diversity — if >50% share the same lineup, data is corrupted
                        let uniqueLineups = Set(bots.map { $0.playerIDs.sorted().joined(separator: ",") })
                        if nhlGoalieMismatch {
                            // savedBots stays nil → falls through to fresh generation
                            needsResave = true
                        } else if uniqueLineups.count <= bots.count / 2 {
                            print("[DFS] Server bots for \(tournament.id) are corrupted (\(uniqueLineups.count)/\(bots.count) unique) — regenerating")
                        } else {
                            // Verify bots were generated from the SAME set of games
                            // as the current slate. Build a lookup of which game each
                            // player belongs to, then check if the bots cover the same
                            // games the slate has.
                            let playerGameMap = Dictionary(players.compactMap { p -> (String, String)? in
                                guard let gid = p.gameID else { return nil }
                                return (p.id, gid)
                            }, uniquingKeysWith: { a, _ in a })
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
                                // Soccer self-heal: if confirmed XIs are now
                                // published (≥18 confirmed players, i.e.
                                // both teams' lineups are out) but saved
                                // bots were generated before lineups dropped
                                // and stuffed bench players into lineups,
                                // discard and regen once. Bench players post
                                // first-XI release would tank the bot field.
                                let isSoccerLeague = sport == "EPL" || sport == "UCL" || sport == "WC"
                                let confirmedIDs = Set(players.filter { $0.isConfirmedActive }.map(\.id))
                                let confirmedAvailable = confirmedIDs.count >= 18
                                let alreadyRegenerated = botFieldRegeneratedThisSession.contains(tournament.id)
                                if isSoccerLeague && confirmedAvailable && !alreadyRegenerated {
                                    var nonConfirmedCount = 0
                                    for bot in bots.prefix(50) {
                                        let nonConf = bot.playerIDs.filter { !confirmedIDs.contains($0) }.count
                                        if nonConf > 0 { nonConfirmedCount += 1 }
                                    }
                                    let staleRate = Double(nonConfirmedCount) / Double(min(50, bots.count))
                                    if staleRate > 0.40 {
                                        print("[DFS-\(sport)] Confirmed XI now available (\(confirmedIDs.count) players) but \(Int(staleRate * 100))% of saved bots have non-confirmed picks — discarding to regen with starting XIs (one-shot)")
                                        botFieldRegeneratedThisSession.insert(tournament.id)
                                        // Drop through without setting savedBots → triggers fresh generation below
                                    } else {
                                        savedBots = bots
                                        print("[DFS] Loaded \(bots.count) saved bot lineups from server for \(tournament.id) (\(uniqueLineups.count) unique, covers \(botGameIDs.count)/\(currentGameIDs.count) games)")
                                    }
                                } else {
                                    savedBots = bots
                                    print("[DFS] Loaded \(bots.count) saved bot lineups from server for \(tournament.id) (\(uniqueLineups.count) unique, covers \(botGameIDs.count)/\(currentGameIDs.count) games)")
                                }
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
                let salaryLookup = Dictionary(activePlayers.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
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
                // Slate-wide player ID set — catches cross-sport contamination
                // (e.g. NHL player IDs sneaking into an MLB main slate's bot
                // field) and stale bots whose player IDs no longer exist in
                // today's slate. Empty when the slate isn't loaded yet, in
                // which case we skip this check to avoid false rejections.
                let slatePlayerIDs: Set<String> = Set(players.map(\.id))
                // Check for incomplete lineups, over-cap lineups, and wrong-game players
                let validBots = trimmedBots.filter { bot in
                    guard bot.playerIDs.count == tournament.lineupSize else { return false }
                    // All player IDs must exist in today's slate. Catches
                    // catastrophic cross-contamination where one sport's
                    // bots end up in another sport's bot_field.
                    if !slatePlayerIDs.isEmpty {
                        guard bot.playerIDs.allSatisfy({ slatePlayerIDs.contains($0) }) else { return false }
                    }
                    // For single-game, verify all players belong to the correct game
                    if let validIDs = sgValidIDs {
                        guard bot.playerIDs.allSatisfy({ validIDs.contains($0) }) else { return false }
                    }
                    // Salary cap check applies to both classic and single-game
                    // (MVP at 1.5x for single-game). Without this, NHL bots
                    // with drifted prices end up spending $60K against a $50K
                    // cap and the leaderboard shows phantom over-budget lineups.
                    if !salaryLookup.isEmpty {
                        var total = 0
                        for (i, pid) in bot.playerIDs.enumerated() {
                            let sal = salaryLookup[pid] ?? 0
                            total += (isSG && i == 0) ? Int(Double(sal) * 1.5) : sal
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
                // Split invalid bots into "wrong-size" (structurally corrupt —
                // 10-player bots in a 6-player SG contest, etc.) and "merely
                // over-cap" (still the right shape, just borderline salary).
                // Wrong-size bots are always regenerated, locked or not — the
                // freeze policy only makes sense for valid lineups; keeping
                // corrupt ones causes user-visible weirdness like "10 live"
                // on a single-game contest.
                let wrongShapeBots = invalidBots.filter { bot in
                    if bot.playerIDs.count != tournament.lineupSize { return true }
                    if !slatePlayerIDs.isEmpty && !bot.playerIDs.allSatisfy({ slatePlayerIDs.contains($0) }) { return true }
                    if let validIDs = sgValidIDs, !bot.playerIDs.allSatisfy({ validIDs.contains($0) }) { return true }
                    return false
                }
                let canRegenerate = !activePlayers.isEmpty

                // Mass-corruption escape hatch: if MORE than half of the saved
                // bots are wrong-shape, treat the entire saved field as
                // tainted (cross-contaminated from another contest type) and
                // ignore it. This recovers contests whose bot_field on the
                // server is stuffed with SG bots in a main-slate contest, or
                // vice versa — partial replacement alone leaves the remaining
                // "valid" bots looking nothing like a real lineup.
                let majorityCorrupt = !trimmedBots.isEmpty
                    && wrongShapeBots.count > trimmedBots.count / 2
                // The latch protects against repeated regeneration cycles
                // (each one is expensive), BUT when literally every saved bot
                // is structurally invalid, the user is staring at a broken
                // leaderboard — bypass the latch in that case. A second regen
                // here is a small price to recover from a totally trashed
                // bot field that the previous attempt didn't fix.
                let totallyCorrupt = !trimmedBots.isEmpty && validBots.isEmpty
                let canFullRegen = canRegenerate
                    && (totallyCorrupt || !botFieldRegeneratedThisSession.contains(tournament.id))
                // PRE-LOCK ONLY: a field generated before lineups dropped can
                // be stuffed with players who won't play — soccer bench
                // players, NHL non-starting goalies / scratched skaters.
                // While entries are still open nothing is frozen, so quietly
                // regenerate with the announced lineups. AFTER lock the field
                // is immutable, period — stable standings beat perfect bots,
                // and the deferral gates ensure post-lock fields are
                // generated from confirmed lineups in the first place.
                let staleVsConfirmedLineups = canRegenerate
                    && !tournamentIsLocked
                    && !players.isEmpty
                    && !botFieldRegeneratedThisSession.contains(tournament.id)
                    && botsContradictConfirmedLineups(trimmedBots.map(\.playerIDs))
                // STRUCTURAL repair (allowed post-lock, like wrong-shape):
                // fields produced by the old collapsed-pool fallback were
                // assembled by `players.shuffled()` — no cap discipline, full
                // of scratches. Signature: most bots massively underspend
                // ($35K totals on a $50K cap). That's a generation
                // malfunction, not a lineup-quality judgment, so repairing
                // it doesn't break field immutability any more than fixing
                // wrong-sport player IDs does.
                let malformedGeneration: Bool = {
                    guard canRegenerate, !players.isEmpty,
                          !botFieldRegeneratedThisSession.contains(tournament.id) else { return false }
                    guard !salaryLookup.isEmpty else { return false }
                    let sample = trimmedBots.prefix(50)
                    guard !sample.isEmpty else { return false }
                    var underspenders = 0
                    for bot in sample {
                        var total = 0
                        for (i, pid) in bot.playerIDs.enumerated() {
                            let sal = bot.playerSalaries?[pid] ?? salaryLookup[pid] ?? 0
                            total += (isSG && i == 0) ? Int(Double(sal) * 1.5) : sal
                        }
                        if total < Int(Double(cap) * 0.75) { underspenders += 1 }
                    }
                    let rate = Double(underspenders) / Double(sample.count)
                    if rate > 0.5 {
                        print("[DFS-\(sport)] \(Int(rate * 100))% of saved bots spent <75% of cap — random-fallback field detected, regenerating (structural repair)")
                        return true
                    }
                    return false
                }()
                if staleVsConfirmedLineups || malformedGeneration {
                    let botsToGenerate = max(0, tournament.entryCount - realEntries.count)
                    var freshBots: [DFSFieldEntry] = []
                    let chunkSize = 50
                    for index in 0..<botsToGenerate {
                        let newIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                        let baseName = sampleNames[index % sampleNames.count]
                        freshBots.append(DFSFieldEntry(id: UUID(), name: "\(baseName) #\(index + 1)", playerIDs: newIDs, isCurrentUser: false))
                        if (index + 1) % chunkSize == 0 && (index + 1) < botsToGenerate {
                            fieldEntries = realEntries + freshBots
                            await Task.yield()
                        }
                    }
                    fieldEntries = realEntries + freshBots
                    needsResave = true
                    botFieldRegeneratedThisSession.insert(tournament.id)
                } else if majorityCorrupt && canFullRegen {
                    print("[DFS-\(sport)] \(wrongShapeBots.count)/\(trimmedBots.count) saved bots are wrong-shape — discarding entire bot field and regenerating fresh (one-shot)")
                    let botsToGenerate = max(0, tournament.entryCount - realEntries.count)
                    var freshBots: [DFSFieldEntry] = []
                    let chunkSize = 50
                    for index in 0..<botsToGenerate {
                        let newIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                        let baseName = sampleNames[index % sampleNames.count]
                        let uniqueName = "\(baseName) #\(index + 1)"
                        freshBots.append(DFSFieldEntry(id: UUID(), name: uniqueName, playerIDs: newIDs, isCurrentUser: false))
                        if (index + 1) % chunkSize == 0 && (index + 1) < botsToGenerate {
                            fieldEntries = realEntries + freshBots
                            await Task.yield()
                        }
                    }
                    fieldEntries = realEntries + freshBots
                    needsResave = true
                    botFieldRegeneratedThisSession.insert(tournament.id)
                } else if !invalidBots.isEmpty && canRegenerate && !tournamentIsLocked {
                    // Pre-lock: regenerate everything that's invalid.
                    print("[DFS-\(sport)] Regenerating \(invalidBots.count) invalid bots (pre-lock)")
                    var botFieldEntries = validBots.map { bot in
                        DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: bot.playerIDs, isCurrentUser: false)
                    }
                    for bot in invalidBots {
                        let newIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                        botFieldEntries.append(DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: newIDs, isCurrentUser: false))
                    }
                    fieldEntries = realEntries + botFieldEntries
                    needsResave = true
                } else if !wrongShapeBots.isEmpty && canRegenerate && tournamentIsLocked {
                    // Post-lock but bots are STRUCTURALLY broken (wrong
                    // lineup size or wrong-game player IDs). Keeping these
                    // shows nonsense like "10 live" on a 6-player contest.
                    // Regenerate just the broken ones; preserve everything
                    // valid as-is to honor the freeze rule.
                    print("[DFS-\(sport)] Tournament locked but \(wrongShapeBots.count) bots are structurally corrupt — regenerating those")
                    let wrongShapeIDs = Set(wrongShapeBots.map { "\($0.name)|\($0.playerIDs.joined(separator: ","))" })
                    var botFieldEntries: [DFSFieldEntry] = []
                    for bot in trimmedBots {
                        let key = "\(bot.name)|\(bot.playerIDs.joined(separator: ","))"
                        if wrongShapeIDs.contains(key) {
                            let newIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                            botFieldEntries.append(DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: newIDs, isCurrentUser: false))
                        } else {
                            botFieldEntries.append(DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: bot.playerIDs, isCurrentUser: false))
                        }
                    }
                    fieldEntries = realEntries + botFieldEntries
                    needsResave = true
                } else if !invalidBots.isEmpty && tournamentIsLocked {
                    if validBots.isEmpty {
                        // Every saved bot is invalid AND we couldn't regen
                        // (slate not loaded yet). Show only real entries; bot
                        // field will be re-validated and regenerated on the
                        // next refresh once the slate finishes loading.
                        print("[DFS-\(sport)] Tournament locked — all \(invalidBots.count) bots invalid and regen unavailable; showing only real entries until slate loads")
                        fieldEntries = realEntries
                    } else {
                        // Post-lock with merely over-cap bots — those still have
                        // the right shape and game coverage, so the freeze rule
                        // wins. Keep them as-is.
                        print("[DFS-\(sport)] Tournament locked — keeping \(invalidBots.count) borderline bots as-is (lineups frozen)")
                        let allBotEntries = trimmedBots.map { bot in
                            DFSFieldEntry(id: UUID(), name: bot.name, playerIDs: bot.playerIDs, isCurrentUser: false)
                        }
                        fieldEntries = realEntries + allBotEntries
                    }
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
                // Pad an INCOMPLETE bot field up to the target entry count. This
                // now runs POST-LOCK too: a contest whose bot field was never
                // fully built (e.g. saved with only 1 bot for a 2000-entry slate)
                // would otherwise stay below the isTournamentReady threshold and
                // shimmer forever. Padding post-lock is safe — we only APPEND the
                // missing bots (existing/frozen bots are never modified) and the
                // new lineups are salary-projected (outcome-blind), exactly like
                // the pre-cache's "first-time-post-lock" generation. The freeze
                // rule only protects existing bots from being swapped, not the
                // filling of a field that was never generated.
                let totalNonUser = fieldEntries.filter({ !$0.isCurrentUser }).count
                let targetBots = max(0, tournament.entryCount - realEntries.count)
                if totalNonUser < targetBots && !activePlayers.isEmpty
                    && !shouldDeferBotGeneration(for: tournament) {
                    let botsNeeded = targetBots - totalNonUser
                    print("[DFS-\(sport)] Padding bot field with \(botsNeeded) bots (had \(totalNonUser), need \(targetBots), locked=\(tournamentIsLocked))")
                    let startIndex = totalNonUser
                    let chunkSize = 50
                    for i in 0..<botsNeeded {
                        let botPlayerIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                        let baseName = sampleNames[(startIndex + i) % sampleNames.count]
                        let uniqueName = "\(baseName) #\(startIndex + i + 1)"
                        fieldEntries.append(DFSFieldEntry(id: UUID(), name: uniqueName, playerIDs: botPlayerIDs, isCurrentUser: false))
                        if (i + 1) % chunkSize == 0 && (i + 1) < botsNeeded {
                            await Task.yield()
                        }
                    }
                    needsResave = true
                }
                print("[DFS-\(sport)] Loaded \(fieldEntries.count) entries from server (\(realEntries.count) real + \(fieldEntries.count - realEntries.count) bots), first bot playerIDs count: \(fieldEntries.first(where: { !$0.isCurrentUser })?.playerIDs.count ?? -1)")
            } else if fieldEntries.isEmpty && !activePlayers.isEmpty
                        && !shouldDeferBotGeneration(for: tournament) {
                // No saved bots and no entries — generate a simulated field. We also
                // allow this after lock when zero bots exist (e.g., user joined right at
                // lock or the initial generation never ran). In that case `needsResave`
                // is set so the freshly generated lineups get persisted as the frozen
                // source of truth from this point forward.
                let count = max(0, tournament.entryCount)
                var emptyCount = 0
                // Generate in chunks so the leaderboard unlocks at the first
                // 25-bot threshold rather than blocking the main actor for
                // every bot before any UI update — matters mostly for
                // 2000-entry contests where the synchronous map() previously
                // froze the view for minutes.
                var accumulated: [DFSFieldEntry] = []
                accumulated.reserveCapacity(count)
                let chunkSize = 50
                for index in 0..<count {
                    let botPlayerIDs = generateBotLineup(from: activePlayers, salaryCap: tournament.salaryCap, lineupSize: tournament.lineupSize, rosterSlots: tournament.rosterSlots, isSingleGame: tournament.isSingleGame)
                    if botPlayerIDs.isEmpty { emptyCount += 1 }
                    let baseName = sampleNames[index % sampleNames.count]
                    let uniqueName = "\(baseName) #\(index + 1)"
                    accumulated.append(DFSFieldEntry(
                        id: UUID(), name: uniqueName,
                        playerIDs: botPlayerIDs, isCurrentUser: false
                    ))
                    if (index + 1) % chunkSize == 0 && (index + 1) < count {
                        fieldEntries = accumulated
                        await Task.yield()
                    }
                }
                fieldEntries = accumulated
                if tournamentIsLocked { needsResave = true }
                print("[DFS-\(sport)] Generated \(count) bots from scratch (locked=\(tournamentIsLocked)), \(emptyCount) have empty lineups, players=\(activePlayers.count), rosterSlots=\(tournament.rosterSlots?.description ?? "nil")")
            } else if fieldEntries.count < tournament.entryCount && !activePlayers.isEmpty {
                // Pad the field with simulated bots to reach expected entry count.
                // We also allow post-lock padding when the field is currently real
                // users only (no saved bots ever existed) — otherwise a contest joined
                // right at lock would show a 1-entry leaderboard forever.
                let existingRealEntries = fieldEntries.filter { $0.isCurrentUser || $0.isRealUser }
                let hasAnyBots = fieldEntries.contains { !$0.isCurrentUser && !$0.isRealUser }
                let allowPostLockPad = tournamentIsLocked && !hasAnyBots && (savedBots?.isEmpty ?? true)
                if tournamentIsLocked && !allowPostLockPad {
                    print("[DFS-\(sport)] Tournament locked — not padding bot field from scratch (have \(fieldEntries.count), target \(tournament.entryCount))")
                } else {
                    let botsNeeded = max(0, tournament.entryCount - existingRealEntries.count)
                    // Generate in chunks so the view's `isTournamentReady`
                    // (which only needs ~25 bots) flips out of shimmer as
                    // soon as the first chunk lands, instead of waiting for
                    // all 2000 bots on a UFC main slate. Each chunk publishes
                    // fieldEntries then yields the main actor so SwiftUI gets
                    // a chance to render.
                    var botEntries: [DFSFieldEntry] = []
                    var emptyCount = 0
                    let chunkSize = 50
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
                        if (index + 1) % chunkSize == 0 && (index + 1) < botsNeeded {
                            fieldEntries = existingRealEntries + botEntries
                            await Task.yield()
                        }
                    }
                    fieldEntries = existingRealEntries + botEntries
                    if allowPostLockPad { needsResave = true }
                    print("[DFS-\(sport)] Padded field with \(botsNeeded) bots (locked=\(tournamentIsLocked), firstTimePostLock=\(allowPostLockPad)), \(emptyCount) have empty lineups, players=\(activePlayers.count), rosterSlots=\(tournament.rosterSlots?.description ?? "nil")")
                }
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

            // Persist bot lineups to server so post-match settlement can reuse them.
            // Pre-lock: save whenever we generated/regenerated to keep server canonical.
            // Post-lock: save whenever an INTENTIONAL locked-field regen ran
            // (needsResave) — wrong-shape replacement, the soccer bench-stuffed
            // heal, or first-time generation. Every post-lock needsResave setter
            // is a deliberate rewrite; ordinary frozen loads never set it. The
            // old gate additionally required the server field to be EMPTY,
            // which blocked persisting every post-lock heal — the regenerated
            // field was thrown away, so each app launch re-downloaded the bad
            // bots, displayed them for ~15s, re-healed in memory, and repeated.
            if (savedBots == nil || needsResave) && (!tournamentIsLocked || needsResave), let token = accessToken {
                let tid = tournament.id
                let salaryLookup = Dictionary(activePlayers.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
                let botEntriesToSave = fieldEntries.filter { !$0.isCurrentUser && !$0.isRealUser }.map { entry -> BotFieldEntry in
                    // Capture each bot's lineup salaries from the live slate so the
                    // settled view displays the same total as live (no salary drift
                    // when players drop off the snapshot post-game).
                    let psals: [String: Int] = Dictionary(uniqueKeysWithValues: entry.playerIDs.compactMap { pid -> (String, Int)? in
                        guard let sal = salaryLookup[pid], sal > 0 else { return nil }
                        return (pid, sal)
                    })
                    return BotFieldEntry(
                        name: entry.name,
                        playerIDs: entry.playerIDs,
                        playerSalaries: psals.isEmpty ? nil : psals
                    )
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

        // uniquingKeysWith (NOT uniqueKeysWithValues) — the pool can briefly
        // contain two players with the same id (e.g. an MLB two-way "-sp" entry
        // re-added by the missing-lineup restore path). uniqueKeysWithValues
        // CRASHES on a duplicate key; keep the first occurrence instead.
        let playersByID = Dictionary(activePlayers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
            snapshot = correctMLBTwoWaySnapshot(fetched)
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
            livePlayerPointsSlatePrefix = sportDatePrefix(from: tournament.id)
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

        // BOT late swap: before scoring, swap each bot's not-yet-started,
        // unconfirmed picks for confirmed starters (DNP avoidance). Started-game
        // players are pinned. The swap is DETERMINISTIC (per-bot-name seeded), so
        // every device computes the identical in-memory field from the same shared
        // saved bots — live standings stay consistent across users with NO server
        // write. The AUTHORITATIVE shared final field is produced at settlement
        // (`upgradeSoccerBotsForSettlement`), which runs whenever the app opens
        // after games — so late-game exposure no longer depends on a client being
        // open during each game's confirm→kickoff window. In-memory only here.
        if supportsLateSwap && !allGamesStarted && fieldEntries.count >= 5 {
            _ = applyLateSwapBotOptimization()
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
        // CRITICAL: livePlayerPoints only contains points for the active
        // tournament's slate (e.g. SG = 2 teams worth of points). Computing
        // another tournament's leaderboard against that data scores most
        // players at 0 → wrong ranks get cached → Active Contests cards
        // display nonsense ranks. So we only update OTHER tournaments whose
        // user lineup players are mostly covered by the current livePlayerPoints.
        for tid in enteredTournamentIDs {
            guard tid != tournament.id else { continue }
            guard let cache = liveContestCache[tid] else { continue }
            guard let tObj = tournaments.first(where: { $0.id == tid }) else { continue }
            guard let userRecords = userEntryRecords[tid] else { continue }
            // CRITICAL: also verify the cached field actually belongs to this
            // tournament. If liveContestCache[SG_tid] somehow holds main-slate
            // bots (10-player, high scores), recomputing its leaderboard with
            // those bots would rank the user's 6-player SG entry against
            // main-slate-sized scores → user shows as last place at 24 FPTS
            // because main-slate bots are at 100+. Discard such caches and
            // skip the update entirely.
            if !botsMatchTournament(cache.fieldEntries, tournamentID: tid) {
                print("[DFS-\(sport)] Cross-tournament rank update: cache for \(tid) is contaminated — discarding")
                discardContaminatedCache(tid)
                continue
            }
            // Coverage check: at least 70% of the user's lineup IDs must
            // appear in livePlayerPoints. Otherwise we'd score a main-slate
            // lineup against SG-only data and produce a phantom rank.
            let allLineupIDs = userRecords.flatMap { $0.lineupPlayerIDs }
            guard !allLineupIDs.isEmpty else { continue }
            let coveredCount = allLineupIDs.filter { livePlayerPoints[$0] != nil }.count
            let coverage = Double(coveredCount) / Double(allLineupIDs.count)
            guard coverage >= 0.7 else {
                // Skip silently — the active tournament's livePlayerPoints
                // doesn't cover this tournament's players. The card on the
                // Active Contests screen will fall back to its own cached
                // rank (which was computed when this tournament was active).
                continue
            }
            let poolForT: [DFSPlayer] = {
                if tObj.isSingleGame, let gid = tObj.gameID, let sgPool = singleGamePlayers[gid] {
                    return sgPool
                }
                return players
            }()
            let pByID = Dictionary(poolForT.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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

        // Update live contest cache so re-entering or switching lineups is
        // instant. Final validation gate: only persist when the bots in
        // memory actually belong to this tournament. Without this, a brief
        // state drift (e.g. during a rapid main↔SG toggle) could write
        // 10-player main-slate bots into the SG cache key, which would then
        // be restored as-is on the next switch.
        if botsMatchTournament(fieldEntries, tournamentID: tournament.id) {
            liveContestCache[tournament.id] = LiveContestCache(
                fieldEntries: fieldEntries,
                leaderboard: leaderboard,
                remoteEntries: remoteEntries,
                profileNames: remoteProfileNames,
                fieldGenerated: true
            )
        } else {
            print("[DFS-\(sport)] Refusing to cache \(tournament.id) — fieldEntries don't match tournament shape")
        }

        guard let userEntry = leaderboard.first(where: { $0.isCurrentUser }) else { return }

        // Avoid "Rank #1 flash": with all-zeros the user is tied for first and
        // would render as Rank #1 before real data lands. BUT we still want to
        // publish a real rank pre-game once the field is built — otherwise the
        // header is stuck on "Your lineup is locked in" for 15+ minutes until
        // first pitch.
        // Publish when EITHER scoring has started OR the field is fully built
        // (so we're confident the leaderboard's rank ordering is final, even
        // if it's based on projections/zeros). The "field fully built" check
        // requires the field to be at least half the expected entry count.
        let hasAnyScoring = leaderboard.contains(where: { $0.points > 0 })
        let expectedEntries = max(2, tournament.entryCount)
        let fieldFullyBuilt = leaderboard.count >= expectedEntries / 2
        guard hasAnyScoring || fieldFullyBuilt else { return }

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

        // PGA un-settlement: trigger when EITHER the tournament was
        // settled prematurely (still in progress) OR the now-final live
        // scores meaningfully disagree with what we wrote to history.
        // The second case catches the playoff scenario: settlement ran
        // during regulation, then a playoff changed the eventual winner +
        // win bonus, leaving stored scores 5–30 pts off the true final.
        let pgaScoreDrift: Bool = {
            guard sport == "PGA", snapshot.allGamesFinal else { return false }
            // Check EVERY lineup's stored history entry, not just the
            // active one. A user can have multiple lineups in the same
            // tournament — if any of them has drifted, the settlement
            // was pre-playoff and ALL entries need a refresh.
            guard let userRecords = userEntryRecords[tournament.id] else { return false }
            for userRecord in userRecords {
                let ln = userRecord.lineupNumber ?? 1
                guard let historyEntry = dfsHistory.first(where: {
                    $0.tournamentId == tournament.id && ($0.lineupNumber ?? 1) == ln
                }) else { continue }
                var currentScore = 0.0
                for pid in userRecord.lineupPlayerIDs {
                    currentScore += (snapshot.playerFantasyPoints[pid] ?? 0)
                }
                // 2-pt threshold: tight enough to catch playoff-driven
                // shifts (a single +5 top-tier bonus change, ~3pt birdie
                // streak, etc.) without thrashing on tiny end-of-day
                // ESPN data revisions.
                if abs(currentScore - historyEntry.lineupPoints) > 2.0 {
                    return true
                }
            }
            return false
        }()
        if sport == "PGA" && settledTournaments.contains(tournament.id) && !snapshot.playerFantasyPoints.isEmpty
            && (!snapshot.allGamesFinal || pgaScoreDrift) {
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
            // After un-settle, re-run the per-lineup-aware golf settler
            // (it handles multi-lineup users internally via
            // `allUserGolfEntries`, so we only call it ONCE — calling
            // per-record makes the second call wipe the bots written
            // by the first → server ends up user-only and the standings
            // detail shows a leaderboard of just two rows at 0.0).
            if let token = accessToken, let userID,
               let firstRecord = userEntryRecords[badTID]?.first {
                await settleUnsettledPastGolfTournament(
                    tournamentID: badTID, userEntry: firstRecord,
                    token: token, userID: userID
                )
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

        // Postponed-game push: if this is a single-game contest whose
        // only game was postponed/suspended/canceled, grade it as a
        // push (rrDelta=0) instead of stranding the contest in "live"
        // shimmer forever waiting on scoring data that won't come.
        // Detected from the snapshot's gameLiveInfo isPostponed flag,
        // which the MLB scoring provider populates from ESPN's status
        // description ("Postponed", "Suspended", "Canceled").
        let postponedGameCount = snapshot.gameLiveInfo.values.filter { $0.isPostponed }.count
        let isSingleGamePush = tournament.isSingleGame
            && postponedGameCount >= 1
            && snapshot.gameLiveInfo.values.allSatisfy { $0.isPostponed || $0.state == "post" }
        if isSingleGamePush {
            print("[DFS-\(sport)] Single-game contest \(tournament.id) postponed — grading as PUSH (RR=0)")
            markTournamentSettled(tournament.id)
            let pushed = DFSResult(
                id: UUID(),
                tournamentTitle: tournament.title,
                rank: userEntry.rank,
                totalEntries: max(tournament.entryCount, fieldEntries.count),
                lineupPoints: 0,
                rrDelta: 0,
                loggedAt: Date(),
                tournamentId: tournament.id,
                lineupNumber: activeLineupNumber
            )
            latestResult = pushed
            var updated = dfsHistory
            updated.insert(pushed, at: 0)
            dfsHistoryData = encodedDFSHistory(Array(updated.prefix(500)))
            return
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

        // Sparse-field guard: don't settle a large contest before its
        // bot field has populated. If the user opens a 2000-entry UFC
        // contest right after lock but bots haven't generated yet, the
        // leaderboard is just the user → rank 1 → max +RR. Once the tid
        // latches into `settledTournaments` it never re-settles, leaving
        // a phantom "#1 / +1000" history row even though the actual
        // leaderboard later resolves to ~#950. Require the leaderboard
        // to be at least 50% populated for large contests before
        // grading; small contests (H2H, 3-Man, etc.) are exempt because
        // a small expected count is fully populated quickly.
        if tournament.entryCount > 10 {
            let populated = leaderboard.count
            let expected = tournament.entryCount
            let fillRatio = Double(populated) / Double(max(1, expected))
            if fillRatio < 0.5 {
                // The live field never populated. If the bot field is essentially
                // EMPTY (slate failed to rebuild — e.g. a single-game slate DK
                // pulled after the game) AND the games are final (we passed the
                // allGamesFinal guard above), the live path can NEVER reach the
                // fill threshold — the contest would be stuck as a LIVE 0.0 card
                // forever while its small-field siblings settle fine. Fall back
                // to the past-settlement path, which rebuilds the full field from
                // the finished game independently and grades it. Guard on a
                // near-empty field so a field that's merely still loading isn't
                // preempted.
                if fieldEntries.count <= 5, let token = accessToken, let uid = userID,
                   let rec = userEntryRecords[tournament.id]?.first {
                    print("[DFS-\(sport)] \(tournament.id): field empty + games final → past-settlement fallback")
                    await settleUnsettledPastTournament(tournamentID: tournament.id, userEntry: rec, token: token, userID: uid)
                } else {
                    print("[DFS-\(sport)] Skipping settlement — leaderboard \(populated)/\(expected) (\(Int(fillRatio*100))%) too sparse, defer until bots load")
                }
                return
            }
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
                livePlayerPointsSlatePrefix = sportDatePrefix(from: tid)
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
    ///
    /// Per-tournament work runs concurrently via TaskGroup so the network awaits
    /// (fetchEntries / fetchProfiles / fetchTournament — 3 round-trips each)
    /// interleave instead of serializing. The CPU-bound bot generation still
    /// runs on the main actor between awaits, but with N tournaments we now
    /// pay ~1× network latency instead of ~N×.
    func preCacheAllEnteredTournaments() async {
        guard let token = accessToken, let userID else { return }
        // Need the slate's player pool to be loaded before we can generate bot
        // lineups. The old guard required `fieldGenerated && !fieldEntries.isEmpty`,
        // which is only true after the user has opened a specific tournament —
        // so if the user has multiple entered contests for the same sport but
        // only opens one, the others never get their bot fields populated and
        // render as "1 entries" on tap.
        guard !players.isEmpty || !singleGamePlayers.isEmpty else { return }
        let currentTID = activeTournamentID

        // Snapshot the set so concurrent mutations to enteredTournamentIDs
        // (from another task or refresh cycle) don't change the loop's view
        // partway through.
        let tidsToCache = enteredTournamentIDs.filter { $0 != currentTID }
        await withTaskGroup(of: Void.self) { group in
            for tid in tidsToCache {
                group.addTask { [weak self] in
                    await self?.preCacheSingleTournament(tid: tid, token: token, userID: userID)
                }
            }
        }
    }

    /// Body of one tournament's pre-cache pass. Extracted from
    /// preCacheAllEnteredTournaments so the loop can run as a TaskGroup.
    /// All `continue` statements in the original loop became `return` here.
    private func preCacheSingleTournament(tid: String, token: String, userID: String) async {
        guard let tObj = tournaments.first(where: { $0.id == tid }) else {
            print("[DFS-\(sport)] Pre-cache SKIP \(tid): tournament not in current `tournaments` array (\(tournaments.count) loaded)")
            return
        }
        // Re-attempt if the previous cache produced suspiciously few entries.
        // Small contests (H2H, 3-man, 5-man) must be fully populated;
        // bigger contests (2000-person) just need ~half built.
        if let cached = liveContestCache[tid] {
            let expected = tObj.entryCount
            let threshold = expected <= 10 ? expected : max(2, expected / 2)
            if cached.fieldEntries.count >= threshold { return }
            print("[DFS-\(sport)] Pre-cache: cache for \(tid) has only \(cached.fieldEntries.count)/\(expected) entries — regenerating")
        }

        // Fetch remote entries for this tournament
        let entries: [DFSEntryRecord]
        do {
            entries = try await SupabaseService.shared.fetchEntries(tournamentID: tid, accessToken: token)
        } catch { return }

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

            let isLocked = isTournamentLocked(tObj)
            // First-time-post-lock: locked with no saved bots ever. We GENERATE and
            // SAVE so the lineups freeze on first encounter (matches the live view's
            // `allowPostLockPad` path). Without this, the leaderboard would show 1
            // entry until the user manually opens the live view.
            let firstTimePostLock = isLocked && savedBots.isEmpty

            // Validate saved bots against the SAME criteria refreshLive uses
            // (size, slate pool). Otherwise pre-cache happily stuffs broken
            // (e.g. cross-sport, wrong-shape) bots into liveContestCache and
            // they survive every navigation back into this contest.
            let preCacheSlateIDs: Set<String> = {
                if tObj.isSingleGame, let gid = tObj.gameID {
                    if let sgPool = singleGamePlayers[gid] { return Set(sgPool.map(\.id)) }
                    return Set(players.filter { $0.gameID == gid }.map(\.id))
                }
                return Set(players.map(\.id))
            }()
            let savedBotsAreValid = !savedBots.isEmpty && savedBots.allSatisfy { bot in
                guard bot.playerIDs.count == tObj.lineupSize else { return false }
                if !preCacheSlateIDs.isEmpty {
                    guard bot.playerIDs.allSatisfy({ preCacheSlateIDs.contains($0) }) else { return false }
                }
                return true
            }
            if !savedBots.isEmpty && !savedBotsAreValid {
                print("[DFS-\(sport)] Pre-cache: \(savedBots.count) saved bots for \(tid) are invalid (wrong size or foreign players) — regenerating from scratch")
            }

            if !savedBots.isEmpty && savedBotsAreValid {
                let trimmed = Array(savedBots.prefix(botsNeeded))
                field += trimmed.map { DFSFieldEntry(id: UUID(), name: $0.name, playerIDs: $0.playerIDs, isCurrentUser: false) }
            } else if shouldDeferBotGeneration(for: tObj) {
                // NHL SG pre-lock without confirmed starting goalies — don't
                // generate a field that would draft the wrong goalie. The
                // pre-cache pass retries on later cycles.
                print("[DFS-\(sport)] Pre-cache: deferring bot generation for \(tid) until starting goalies confirm")
                return
            } else if savedBots.isEmpty && isLocked && !firstTimePostLock {
                // Locked AND we've already generated bots for this tournament before
                // (this branch never runs in practice because firstTimePostLock above
                // is true whenever savedBots is empty — kept for clarity).
                print("[DFS-\(sport)] Pre-cache: tournament \(tid) is locked with no saved bots — skipping bot generation to preserve consistency")
            } else {
                // Use the correct player pool for this tournament (may differ from activePlayers
                // which is bound to the currently-selected tournament).
                let rawPoolForBots: [DFSPlayer]
                if tObj.isSingleGame, let gid = tObj.gameID {
                    if let sgPool = singleGamePlayers[gid] {
                        rawPoolForBots = sgPool
                    } else {
                        // Build single-game pool with converted showdown salaries
                        let filtered = players.filter { $0.gameID == gid }
                        let league = tObj.league
                        let converted = filtered.map { p -> DFSPlayer in
                            let isMLBPitcher = league.uppercased() == "MLB" && p.position.uppercased() == "SP"
                            var sg = DFSPlayer(
                                id: p.id, name: p.name, team: p.team, position: p.position,
                                salary: isMLBPitcher
                                    ? mlbShowdownPitcherSalary(from: p.salary)
                                    : singleGameSalary(from: p.salary, league: league),
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
                        if !converted.isEmpty {
                            singleGamePlayers[gid] = converted
                        }
                        rawPoolForBots = converted
                    }
                } else if tObj.tournamentType.isEvening {
                    rawPoolForBots = eveningPlayers
                } else {
                    rawPoolForBots = players
                }
                // Apply the contest's frozen salary snapshot so bots draft against
                // the same prices the user will see (and that get stored). Without
                // this, bots could use raw prices that drift from canonical,
                // making "$50K spent" mean different things for bots vs the user.
                let poolForBots: [DFSPlayer] = {
                    guard let canonical = tournamentPlayerSalaries[tid], !canonical.isEmpty else {
                        return rawPoolForBots
                    }
                    return rawPoolForBots.map { p in
                        guard let drafted = canonical[p.id], drafted > 0, drafted != p.salary else { return p }
                        var fixed = DFSPlayer(
                            id: p.id, name: p.name, team: p.team, position: p.position,
                            salary: drafted, projectedPoints: p.projectedPoints,
                            gameID: p.gameID, injuryStatus: p.injuryStatus,
                            battingOrder: p.battingOrder
                        )
                        fixed.gamesPlayed = p.gamesPlayed
                        fixed.playedRecently = p.playedRecently
                        fixed.isConfirmedActive = p.isConfirmedActive
                        fixed.isStartingGoalie = p.isStartingGoalie
                        return fixed
                    }
                }()
                guard !poolForBots.isEmpty else {
                    print("[DFS-\(sport)] Pre-cache SKIP \(tid): bot pool empty (isSG=\(tObj.isSingleGame), gameID=\(tObj.gameID ?? "nil"), players=\(players.count), sgPools=\(singleGamePlayers.count))")
                    return
                }
                // Hoisted leaderboard helpers so we can publish partial
                // caches mid-loop. Without these computed here, the first
                // cache write would have to wait for the full 2000-bot
                // generation — which was the source of the 75s shimmer
                // freeze when 8 entered contests all generated in lock-
                // step on the main actor.
                let earlyPool: [DFSPlayer] = {
                    if tObj.isSingleGame, let gid = tObj.gameID, let sgPool = singleGamePlayers[gid] {
                        return sgPool
                    }
                    return players
                }()
                let earlyPlayersByID = Dictionary(earlyPool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let earlySnapshot = DFSScoreSnapshot(
                    playerFantasyPoints: livePlayerPoints,
                    playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: false
                )
                // Threshold mirrors isTournamentReady: small contests need
                // full population, medium need 10, large need 25. The
                // lobby flips out of shimmer the moment the cache holds
                // this many entries — that's the user-visible win.
                let expectedEntries = tObj.entryCount
                let readyThreshold: Int = {
                    if expectedEntries <= 10 { return expectedEntries }
                    if expectedEntries <= 100 { return 10 }
                    return 25
                }()
                let chunkSize = 50
                var publishedReady = false
                for i in 0..<botsNeeded {
                    let botIDs = generateBotLineup(from: poolForBots, salaryCap: tObj.salaryCap, lineupSize: tObj.lineupSize, rosterSlots: tObj.rosterSlots, isSingleGame: tObj.isSingleGame)
                    let name = "\(sampleNames[i % sampleNames.count]) #\(i + 1)"
                    field.append(DFSFieldEntry(id: UUID(), name: name, playerIDs: botIDs, isCurrentUser: false))
                    // First time we cross the ready threshold, publish a
                    // partial cache so the lobby card paints. fieldGenerated
                    // stays false on the cache so a tap-in lets refreshLive
                    // pad the rest (it has its own chunked padding loop).
                    if !publishedReady && field.count >= readyThreshold && !players.isEmpty {
                        let partialLB = DFSEngine.computeLeaderboard(
                            fieldEntries: field, playersByID: earlyPlayersByID,
                            scoreSnapshot: earlySnapshot, isSingleGame: tObj.isSingleGame
                        )
                        liveContestCache[tid] = LiveContestCache(
                            fieldEntries: field, leaderboard: partialLB,
                            remoteEntries: entries, profileNames: profileMap,
                            fieldGenerated: false
                        )
                        publishedReady = true
                        print("[DFS-\(sport)] Pre-cache: published partial cache for \(tid) at \(field.count)/\(expectedEntries) bots — lobby card unlocked")
                    }
                    // Yield between chunks so SwiftUI can paint and the
                    // other 7 entered tournaments' generators get a turn
                    // on the main actor. Without this every TaskGroup task
                    // serialized on @MainActor and the shimmer stuck for
                    // ~75s waiting on the slowest tournament.
                    if (i + 1) % chunkSize == 0 && (i + 1) < botsNeeded {
                        await Task.yield()
                    }
                }
            }

            guard !field.isEmpty else {
                print("[DFS-\(sport)] Pre-cache SKIP \(tid): field ended up empty after bot generation")
                return
            }
            guard !players.isEmpty else {
                print("[DFS-\(sport)] Pre-cache SKIP \(tid): main players pool empty")
                return
            }

            // Build leaderboard using current live player points
            // Use single-game player pool (with adjusted salaries) when applicable
            let poolForTournament: [DFSPlayer]
            if tObj.isSingleGame, let gid = tObj.gameID, let sgPool = singleGamePlayers[gid] {
                poolForTournament = sgPool
            } else {
                poolForTournament = players
            }
            let playersByID = Dictionary(poolForTournament.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let snapshot = DFSScoreSnapshot(
                playerFantasyPoints: livePlayerPoints,
                playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: false
            )
            let lb = DFSEngine.computeLeaderboard(
                fieldEntries: field, playersByID: playersByID,
                scoreSnapshot: snapshot, isSingleGame: tObj.isSingleGame
            )

            // Only mark fieldGenerated=true if the field is actually populated
            // to the expected count. Otherwise refreshLive would see this cache,
            // think generation is done, and skip its own bot generation — leaving
            // the contest stuck at 1 entry until the user navigates away/back.
            let expectedEntries = tObj.entryCount
            let fieldComplete = expectedEntries <= 10
                ? field.count >= expectedEntries
                : field.count >= max(2, expectedEntries / 2)
            liveContestCache[tid] = LiveContestCache(
                fieldEntries: field, leaderboard: lb,
                remoteEntries: entries, profileNames: profileMap,
                fieldGenerated: fieldComplete
            )
            if !fieldComplete {
                print("[DFS-\(sport)] Pre-cache: cache for \(tid) partial (\(field.count)/\(expectedEntries)) — refreshLive will retry generation")
            }

            // Save the freshly generated field back to the server when:
            //   1. firstTimePostLock — never had bots before; freeze these now, OR
            //   2. invalid saved bots were detected and replaced — overwrite the
            //      bad data so subsequent loads don't keep re-fetching it.
            let shouldResaveBotField = firstTimePostLock || (!savedBots.isEmpty && !savedBotsAreValid)
            if shouldResaveBotField {
                // IMPORTANT: prefer the tournament's canonical snapshot
                // (frozen at first user submit) over the raw `playersByID`
                // pool. Without this, bots get written with the current raw
                // RG price (e.g. Towns at $13K) while the user's entry sits
                // at the canonical ($10K), and the leaderboard displays the
                // two prices side-by-side in the same contest.
                let canonicalSnapshot: [String: Int] = tournamentPlayerSalaries[tid] ?? [:]
                let botEntriesToSave = field
                    .filter { !$0.isCurrentUser && !$0.isRealUser }
                    .map { entry -> BotFieldEntry in
                        let psals: [String: Int] = Dictionary(uniqueKeysWithValues: entry.playerIDs.compactMap { pid -> (String, Int)? in
                            if let canonicalSal = canonicalSnapshot[pid], canonicalSal > 0 {
                                return (pid, canonicalSal)
                            }
                            guard let sal = playersByID[pid]?.salary, sal > 0 else { return nil }
                            return (pid, sal)
                        })
                        return BotFieldEntry(
                            name: entry.name,
                            playerIDs: entry.playerIDs,
                            playerSalaries: psals.isEmpty ? nil : psals
                        )
                    }
                if !botEntriesToSave.isEmpty, let saveToken = accessToken {
                    Task {
                        try? await SupabaseService.shared.saveBotField(
                            tournamentID: tid, botField: botEntriesToSave, accessToken: saveToken
                        )
                        print("[DFS-\(self.sport)] Pre-cache: saved \(botEntriesToSave.count) first-time-post-lock bots for \(tid)")
                    }
                }
            }

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

    /// Persists the full leaderboard (including bots) to dfs_tournament_results
    private func persistLeaderboardToServer(
        tournamentID: String,
        leaderboard: [DFSLeaderboardEntry],
        totalEntries: Int
    ) async {
        guard let token = accessToken, let userID else { return }

        let entryNameMap = Dictionary(uniqueKeysWithValues: fieldEntries.map { ($0.id, $0.name) })
        let fieldByID = Dictionary(uniqueKeysWithValues: fieldEntries.map { ($0.id, $0) })
        // Look up the TARGET tournament (not the currently-active one) — settlement
        // can run for a tournament that isn't currently selected (background settle
        // loop, multi-lineup tournaments, etc.) and we MUST use the target's correct
        // player pool. For SG, that's the showdown-salary pool keyed by gameID;
        // otherwise the bots get persisted with main-slate salaries that display as
        // ~$36K total instead of the ~$50K showdown cap.
        let targetTournament = tournaments.first(where: { $0.id == tournamentID })
        let poolForLookup: [DFSPlayer]
        if targetTournament?.isSingleGame == true,
           let gid = targetTournament?.gameID,
           let sgPool = singleGamePlayers[gid] {
            poolForLookup = sgPool
        } else {
            poolForLookup = activePlayers
        }
        let playersByID = Dictionary(poolForLookup.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let isSG = targetTournament?.isSingleGame ?? (tournament?.isSingleGame ?? false)
        let entryCount = targetTournament?.entryCount ?? tournament?.entryCount ?? 1000
        let salaryCapForCheck = targetTournament?.salaryCap ?? tournament?.salaryCap ?? 50000
        // Canonical snapshot: frozen at first user submit, persisted on
        // the dfs_tournaments row. For SG contests this is already in
        // SG dollars (see syncTournamentBackend comment). Using it for
        // bot salary persistence prevents the "displayed total drifts
        // over cap" bug — without it, bots get re-saved on each settle
        // pass using live LineupHQ prices that may have shifted upward
        // since draft time, producing $57.5K totals on a $50K cap.
        let canonicalSnapshot: [String: Int] = tournamentPlayerSalaries[tournamentID] ?? [:]

        // Deduplicate entry names to avoid upsert conflict errors
        var nameCounter: [String: Int] = [:]
        // Build a comprehensive name lookup: bots can roster a player who later
        // DNP'd and was filtered out of `playersByID`, so we need additional
        // fallbacks to avoid persisting raw IDs (which display as "Unknown").
        func resolveName(_ pid: String) -> String {
            if let name = playersByID[pid]?.name, !name.isEmpty { return name }
            if let info = preloadedPlayerInfo[pid], !info.name.isEmpty { return info.name }
            if let stats = livePlayerStats[pid], !stats.name.isEmpty, stats.name != pid {
                return stats.name
            }
            // Look across other field entries' lineup names that may already have it resolved
            for (_, entries) in userEntryRecords {
                for entry in entries {
                    if let names = entry.lineupPlayerNames,
                       let idx = entry.lineupPlayerIDs.firstIndex(of: pid),
                       idx < names.count {
                        let n = names[idx]
                        if !n.isEmpty, n != pid, !["nba-", "pga-", "ncaam-", "mlb-", "nhl-", "epl-", "ucl-", "wc-"]
                            .contains(where: { n.hasPrefix($0) }) {
                            return n
                        }
                    }
                }
            }
            return pid
        }
        // Build per-player salaries with canonical priority + MVP 1.5x
        // for SG slot 0. Falls back to live slate price only when the
        // canonical snapshot doesn't carry this player (e.g. injected
        // bench player not present at submit time).
        func resolveSalary(_ pid: String, slotIndex: Int) -> Int? {
            let base: Int? = {
                if let canonicalSal = canonicalSnapshot[pid], canonicalSal > 0 {
                    return canonicalSal
                }
                if let liveSal = playersByID[pid]?.salary, liveSal > 0 {
                    return liveSal
                }
                return nil
            }()
            guard let baseSal = base, baseSal > 0 else { return nil }
            return (isSG && slotIndex == 0) ? Int(Double(baseSal) * 1.5) : baseSal
        }
        var resultRecords: [DFSTournamentResultRecord] = leaderboard.map { entry in
            let field = fieldByID[entry.id]
            let playerIDs = field?.playerIDs ?? []
            let playerNames = playerIDs.map { resolveName($0) }
            let perPlayerPoints: [String: Double] = Dictionary(uniqueKeysWithValues:
                playerIDs.map { pid in
                    (pid, livePlayerPoints[pid] ?? 0)
                }
            )
            var perPlayerSalaries: [String: Int] = [:]
            for (idx, pid) in playerIDs.enumerated() {
                if let sal = resolveSalary(pid, slotIndex: idx) {
                    perPlayerSalaries[pid] = sal
                }
            }
            // Cap-safety scale: if a saved lineup's salaries sum
            // suspiciously above the cap (>5%), the canonical/live
            // sources disagree with the generator's draft-time math.
            // Scale per-player salaries proportionally so the displayed
            // total stays at the cap — the relative weights between
            // players are preserved, which is what matters for the
            // "different prices" complaint. This is a safety net; the
            // canonical priority above should normally make it a no-op.
            let rawTotal = perPlayerSalaries.values.reduce(0, +)
            let capCeiling = Int(Double(salaryCapForCheck) * 1.05)
            if rawTotal > capCeiling && rawTotal > 0 {
                let scale = Double(salaryCapForCheck) / Double(rawTotal)
                perPlayerSalaries = perPlayerSalaries.mapValues { sal in
                    let scaled = Int((Double(sal) * scale / 100.0).rounded()) * 100  // round to nearest $100
                    return max(100, scaled)
                }
                print("[DFS-\(sport)] persistLeaderboard: scaled over-cap bot salaries \(rawTotal) → cap \(salaryCapForCheck) for \(entry.name)")
            }
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
                // Same canonical+MVP salary resolution as the main loop
                // above, so the user's OTHER lineups also persist with
                // frozen draft-time prices instead of drifted live ones.
                var perSals: [String: Int] = [:]
                for (i, pid) in pids.enumerated() {
                    if let sal = resolveSalary(pid, slotIndex: i) {
                        perSals[pid] = sal
                    }
                }
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

        // Private contest branch: bypass public dfs_entries entirely.
        // The lineup is stored in dfs_private_contest_entries against the contest.
        if let contest = activePrivateContest {
            _ = userID; _ = token  // silence warnings
            Task {
                if await submitActivePrivateContestLineup() {
                    await MainActor.run {
                        self.showLineupBuilder = false
                        self.activePrivateContest = nil
                        self.selectedPlayerIDs = []
                        self.mvpPlayerID = nil
                        self.editingLineupNumber = nil
                    }
                }
            }
            return
        }

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
        let salaryMap = Dictionary(selectedPlayers.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
        let namesList = selectedPlayers.map { $0.name }

        // Build full slate salary map so re-settlement can use original prices
        let allPlayerSalaries = Dictionary(activePlayers.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })

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

                // DK slate prices DON'T move once posted. The previous
                // "latest submission wins" behavior was the actual source
                // of the per-player price drift the user kept reporting
                // (bots displayed at different prices than what they
                // were drafted with). The fix: first VALID canonical
                // wins. Subsequent submissions read the server's locked
                // canonical and don't overwrite it.
                //
                // The lobby auto-write was previously removed because it
                // could lock in pre-RG fallback prices. We guard against
                // that here with a sanity check: only treat a server
                // canonical as "valid and locked" when it has a real RG
                // signal (many distinct prices spread across a reasonable
                // range). A trivial fallback snapshot (all min-floor, or
                // <5 distinct values) is treated as bad and overwritten.
                let existingTournament = try? await SupabaseService.shared.fetchTournament(
                    tournamentID: resolvedTournamentID, accessToken: token
                )
                let serverCanonical = existingTournament?.playerSalaries ?? [:]
                let serverCanonicalIsValid: Bool = {
                    guard serverCanonical.count >= 5 else { return false }
                    let distinctVals = Set(serverCanonical.values).count
                    // RG slates have many distinct salary values; a
                    // fallback "everyone at floor" looks like 1-3 values.
                    return distinctVals >= 5
                }()
                let canonicalToWrite: [String: Int] = serverCanonicalIsValid
                    ? serverCanonical
                    : allPlayerSalaries
                let record = DFSTournamentRecord(
                    id: resolvedTournamentID,
                    title: tournament.title,
                    league: tournament.league,
                    // Per-tournament lock, NOT the slate-wide earliest game —
                    // evening/SG tournaments were being stored with the main
                    // slate's lock time (hours too early).
                    lockTime: lockTimeForTournament(tournament),
                    playerSalaries: canonicalToWrite,
                    isSingleGame: tournament.isSingleGame
                )
                try await SupabaseService.shared.upsertTournament(record: record, accessToken: token)
                // Pull server's canonical into the local cache so the
                // builder, persist path, and any subsequent draft of
                // the SAME slate (H2H / 5-Man / 2000-person etc.) all
                // read identical prices from this point forward.
                if serverCanonicalIsValid {
                    tournamentPlayerSalaries[resolvedTournamentID] = serverCanonical
                    print("[DFS-\(sport)] submit: server canonical locked (\(serverCanonical.count) players, \(Set(serverCanonical.values).count) distinct) — using server prices")
                } else {
                    tournamentPlayerSalaries[resolvedTournamentID] = allPlayerSalaries
                    print("[DFS-\(sport)] submit: server canonical empty/invalid — writing our snapshot (\(allPlayerSalaries.count) players)")
                }
                // Server-authoritative lineup number. The locally computed
                // number comes from `userEntryRecords`, which can be stale
                // (rapid back-to-back submissions, wiped cache, fresh
                // session). A reused number makes the upsert silently
                // REPLACE that lineup instead of adding a new one — the
                // "submitted 4 lineups, only 1 saved" bug. Read the user's
                // existing numbers from the server and bump past the max.
                var finalLineupNumber = lineupNumber
                if !isEditing {
                    let existing = (try? await SupabaseService.shared.fetchEntries(
                        tournamentID: resolvedTournamentID, accessToken: token
                    )) ?? []
                    let myNumbers = existing.filter { $0.userID == userID }.map { $0.lineupNumber ?? 1 }
                    if myNumbers.count >= maxLineupsPerTournament {
                        self.error = "Maximum \(maxLineupsPerTournament) lineups per game type reached."
                        return
                    }
                    if let maxNum = myNumbers.max(), maxNum >= finalLineupNumber {
                        print("[DFS-\(sport)] submit: local lineup number \(lineupNumber) stale (server max \(maxNum)) — using \(maxNum + 1)")
                        finalLineupNumber = maxNum + 1
                    }
                }
                try await SupabaseService.shared.submitEntry(
                    tournamentID: resolvedTournamentID,
                    userID: userID,
                    lineupPlayerIDs: userLineup,
                    lineupPlayerSalaries: salaryMap,
                    lineupPlayerNames: namesList,
                    lineupNumber: finalLineupNumber,
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
                    lineupNumber: finalLineupNumber
                )
                if isEditing {
                    // Replace the existing entry in the local cache
                    if var entries = userEntryRecords[resolvedTournamentID] {
                        if let idx = entries.firstIndex(where: { $0.lineupNumber == finalLineupNumber }) {
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
    /// Tournaments whose saved bot field has already been judged corrupt and
    /// regenerated this session. Without this latch, every refreshLive cycle
    /// re-detects the same low coverage (the freshly regenerated save hasn't
    /// propagated back yet) and rebuilds 2000 bots again — looping forever
    /// and stranding the UI on shimmer.
    private var botFieldRegeneratedThisSession: Set<String> = []
    /// Per-session latch: tids we've already force-re-settled via the PGA
    /// self-heal so we don't wipe + re-settle on every refresh cycle.
    private var pgaSelfHealedThisSession: Set<String> = []

    /// Discards a contaminated cache entry along with every stale entry
    /// derived from it (rank-by-key cache that the Active Contests cards
    /// read from). Otherwise a card could keep showing a bad rank from a
    /// poisoned cache even after the underlying cache itself was nuked.
    private func discardContaminatedCache(_ tid: String) {
        liveContestCache[tid] = nil
        let staleRankKeys = cachedLiveRanks.keys.filter { $0.hasPrefix("\(tid)-") }
        for key in staleRankKeys { cachedLiveRanks[key] = nil }
    }

    /// Shared cache-validity check used everywhere we read or write
    /// `liveContestCache`. Catches contamination where the bots in a cached
    /// LiveContestCache entry don't actually belong to the tournament whose
    /// key they're filed under (wrong lineup size or wrong game/slate IDs).
    /// Returns true when the cache is empty (no bots = nothing to validate)
    /// or when at least 50% of bots match the tournament's expected shape.
    private func botsMatchTournament(_ bots: [DFSFieldEntry], tournamentID: String) -> Bool {
        guard let tObj = tournaments.first(where: { $0.id == tournamentID }) else { return true }
        // Size sanity check for small contests. H2H/3-Man/5-Man/10-Man
        // sibling tournaments for the same SG gameID share the same pool
        // and same lineup size — the pool+size check below CAN'T tell
        // them apart, so a 5-Man's cached 5 fieldEntries would pass
        // validation for an H2H (2 entries) and get loaded into the wrong
        // view. Reject the cache if total entry count doesn't match.
        // Large contests (>10) can have partial fields during pre-cache,
        // so only enforce strict size for small tournaments.
        if tObj.entryCount <= 10 && tObj.entryCount > 0 && !bots.isEmpty {
            if bots.count != tObj.entryCount {
                return false
            }
        }
        let botsOnly = bots.filter { !$0.isCurrentUser && !$0.isRealUser }
        guard !botsOnly.isEmpty else { return true }
        let validIDs: Set<String> = {
            if tObj.isSingleGame, let gid = tObj.gameID {
                if let sgPool = singleGamePlayers[gid] { return Set(sgPool.map(\.id)) }
                return Set(players.filter { $0.gameID == gid }.map(\.id))
            }
            return Set(players.map(\.id))
        }()
        let runPoolCheck = !validIDs.isEmpty
        let validCount = botsOnly.filter { bot in
            guard bot.playerIDs.count == tObj.lineupSize else { return false }
            if runPoolCheck {
                guard bot.playerIDs.allSatisfy({ validIDs.contains($0) }) else { return false }
            }
            return true
        }.count
        return Double(validCount) / Double(botsOnly.count) >= 0.5
    }

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
        if tournamentId.hasPrefix("wnba-") {
            // MUST be checked before "nba-" — though "wnba-" doesn't actually
            // prefix-match "nba-", omitting this branch entirely (the original
            // bug) made every WNBA tid fall through to `else { return }`, so box
            // scores never loaded and all stat columns rendered "-".
            sportPrefix = "wnba"
            dateString = String(tournamentId.dropFirst(5).prefix(8))
        } else if tournamentId.hasPrefix("nba-") {
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
        } else if tournamentId.hasPrefix("wc-") {
            sportPrefix = "wc"
            // "wc-" is 3 chars (not 4 like other leagues), so the YYYYMMDD
            // date sits at offset 3.
            dateString = String(tournamentId.dropFirst(3).prefix(8))
        } else if tournamentId.hasPrefix("ufc-") {
            sportPrefix = "ufc"
            dateString = String(tournamentId.dropFirst(4).prefix(8))
        } else if tournamentId.hasPrefix("nfl-") {
            sportPrefix = "nfl"
            dateString = String(tournamentId.dropFirst(4).prefix(8))
        } else if tournamentId.hasPrefix("cfb-") {
            sportPrefix = "cfb"
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
        case "wnba": espnSport = "basketball/wnba"
        case "mlb": espnSport = "baseball/mlb"
        case "nhl": espnSport = "hockey/nhl"
        case "epl": espnSport = "soccer/eng.1"
        case "ucl": espnSport = "soccer/uefa.champions"
        case "wc": espnSport = "soccer/fifa.world"
        case "ufc": espnSport = "mma/ufc"
        case "nfl": espnSport = "football/nfl"
        case "cfb": espnSport = "football/college-football"
        default: espnSport = "basketball/nba"
        }

        // UFC needs special handling — the generic scoreboard fetcher reads
        // `competitor.team.abbreviation`, which fails for athlete-based
        // competitors. Use the UFC-specific helper that returns one slate
        // game per fight (keyed on competition.id).
        let games: [DFSSlateGame]
        if sportPrefix == "ufc" {
            games = await fetchUFCSlateGamesForDate(dateString)
        } else {
            games = await fetchSlateGamesForDate(dateString, espnSport: espnSport)
        }
        guard !games.isEmpty else { return }

        // Use the correct sport-specific scoring provider. `self.scoringProvider`
        // is whichever sport's VM is calling this — when NBA VM calls
        // loadPastTournamentBoxScores for a UFC tournament (since the
        // unified My Contests view can route any sport here), the NBA
        // scoring provider can't parse UFC box scores. Pick the right one.
        let providerForStats: DFSLiveScoringProvider
        switch sportPrefix {
        case "mlb": providerForStats = ESPNMLBDFSLiveScoringProvider()
        case "nhl": providerForStats = ESPNNHLDFSLiveScoringProvider()
        case "ncaam": providerForStats = ESPNNCAAMDFSLiveScoringProvider()
        case "wnba": providerForStats = ESPNWNBADFSLiveScoringProvider()
        case "epl": providerForStats = ESPNSoccerDFSLiveScoringProvider(league: .epl)
        case "ucl": providerForStats = ESPNSoccerDFSLiveScoringProvider(league: .ucl)
        case "wc": providerForStats = ESPNSoccerDFSLiveScoringProvider(league: .worldCup)
        case "ufc": providerForStats = ESPNUFCDFSLiveScoringProvider()
        case "nfl": providerForStats = ESPNNFLDFSLiveScoringProvider()
        case "cfb": providerForStats = ESPNNCAAFBDFSLiveScoringProvider()
        default: providerForStats = scoringProvider
        }

        if let snapshot = try? await providerForStats.fetchScoreSnapshot(for: games) {
            pastTournamentPlayerStats = snapshot.playerLiveStats
            pastTournamentStatsLoaded = tournamentId
            // Box scores are keyed by ESPN athlete ID, but single-game/showdown
            // lineups reference stub IDs (e.g. wnba-<dkDraftableId>) that don't
            // match — so the stat columns rendered "-" even though FPTS resolved
            // from stored results. Alias the stats onto each lineup player ID by
            // NAME so the PTS/REB/AST line shows regardless of the ID scheme.
            aliasPastStatsByName()

            // Resolve any player IDs that are still unresolved (not in box scores)
            await resolveUnresolvedPlayerNames(tournamentId: tournamentId, sportPrefix: sportPrefix, espnSport: espnSport)
        }
    }

    /// Normalized key for matching a player by name across ID schemes:
    /// lowercased, diacritics removed, non-alphanumerics stripped.
    static func statNameKey(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Aliases `pastTournamentPlayerStats` (keyed by ESPN athlete ID) onto each
    /// lineup player ID by matching names, so per-player stat lines resolve even
    /// when the lineup uses showdown stub IDs that don't match ESPN's IDs.
    private func aliasPastStatsByName() {
        guard !pastTournamentPlayerStats.isEmpty, !pastTournamentResultRecords.isEmpty else { return }
        var byName: [String: DFSPlayerLiveStats] = [:]
        for s in pastTournamentPlayerStats.values where !s.name.isEmpty {
            byName[Self.statNameKey(s.name)] = s
        }
        guard !byName.isEmpty else { return }
        var aliased = 0
        for record in pastTournamentResultRecords {
            let ids = record.lineupPlayerIDs
            let names = record.lineupPlayerNames
            for (i, pid) in ids.enumerated() where pastTournamentPlayerStats[pid] == nil {
                let nm = i < names.count ? names[i] : ""
                guard !nm.isEmpty, let s = byName[Self.statNameKey(nm)] else { continue }
                pastTournamentPlayerStats[pid] = s
                aliased += 1
            }
        }
        if aliased > 0 { print("[DFS] aliased \(aliased) box-score stat line(s) by name (stub→ESPN ID mismatch)") }
    }

    /// Fetch individual athlete names from ESPN for unresolved player IDs.
    /// First tries individual athlete endpoints, then falls back to team rosters for any still-unresolved.
    private func resolveUnresolvedPlayerNames(tournamentId: String, sportPrefix: String, espnSport: String) async {
        let rawPrefixes = ["nba-", "pga-", "ncaam-", "mlb-", "nhl-", "epl-", "ucl-", "wc-", "ufc-", "nfl-", "cfb-"]
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
        let isSoccerResolve = sportPrefix == "epl" || sportPrefix == "ucl" || sportPrefix == "wc"
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

                // Recompute correct pooled RR deltas AND ranks locally using
                // tie-aware leaderboard data. The server may have stale
                // values from earlier (sparse-field) settlement code, so we
                // can't trust serverUser.rrDelta OR serverUser.rank.
                let standingsEntryCount = Self.entryCountFromTournamentID(tournamentId)
                var correctRRByEntryID: [String: Int] = [:]
                var correctRankByEntryID: [String: Int] = [:]
                for (offset, r) in sortedResults.enumerated() where userResultIDs.contains(r.id) {
                    let rank = tieAwareRanks[offset]
                    let tieCount = tieAwareRanks.filter { $0 == rank }.count
                    let pooledRR = DFSEngine.pooledRRDelta(tiedRank: rank, tieCount: tieCount, entryCount: standingsEntryCount)
                    correctRRByEntryID[r.id] = pooledRR
                    correctRankByEntryID[r.id] = rank
                }

                // If any user entry's server rrDelta OR rank differs from
                // the locally recomputed pooled values, update the server
                // records. Critical: ALSO write the correct rank back. The
                // earlier version only pushed rrDelta and kept r.rank,
                // leaving a permanently inconsistent row (rank=1 /
                // rrDelta=-10) that the sync loop then read back into
                // local — the exact "reverts after a few seconds" bug.
                var serverRecordsNeedUpdate = false
                var correctedServerResults = results
                for (i, r) in correctedServerResults.enumerated() {
                    let correctRR = correctRRByEntryID[r.id]
                    let correctRank = correctRankByEntryID[r.id]
                    let needsRRFix = correctRR != nil && r.rrDelta != correctRR
                    let needsRankFix = correctRank != nil && r.rank != correctRank
                    if needsRRFix || needsRankFix {
                        correctedServerResults[i] = DFSTournamentResultRecord(
                            id: r.id, tournamentID: r.tournamentID, userID: r.userID,
                            entryName: r.entryName, lineupPlayerIDs: r.lineupPlayerIDs,
                            lineupPlayerNames: r.lineupPlayerNames, totalPoints: r.totalPoints,
                            playerPoints: r.playerPoints, playerSalaries: r.playerSalaries,
                            rank: correctRank ?? r.rank,
                            rrDelta: correctRR ?? r.rrDelta,
                            isCurrentUser: r.isCurrentUser, isBot: r.isBot
                        )
                        serverRecordsNeedUpdate = true
                        print("[DFS-Standings] Correcting \(r.entryName): rank \(r.rank)→\(correctRank ?? r.rank), rrDelta \(r.rrDelta)→\(correctRR ?? r.rrDelta)")
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
            let allRecentEntries = try await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)
            // Only process entries that belong to THIS view model's sport.
            // Every sport's VM runs this check on app load — without the
            // filter, all 10 VMs concurrently iterated every other sport's
            // tournaments, racing on `dfsHistoryData` writes and producing
            // duplicate history rows under derived lineup numbers (the
            // classic "NYM @ SEA shows 4 rows, scores all identical" case).
            // NBA VM also handles NCAAM since they share a model.
            // Each sport view model owns exactly its own tournament-ID prefix.
        // NCAAM and WNBA now have their own view models, so NBA no longer
        // also claims "ncaam-".
        let sportPrefixes: [String] = [sport.lowercased() + "-"]
            let recentEntries = allRecentEntries.filter { entry in
                sportPrefixes.contains(where: { entry.tournamentID.hasPrefix($0) })
            }
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
                                // Detect wrong-size bot lineups: bots must
                                // have the same number of player IDs as the
                                // user's entry. Older settlement passes for
                                // UFC built 8-player lineups (the default
                                // fallback) instead of 6 — force a full
                                // resettle so the new bot sizing kicks in.
                                let userLineupSize = entry.lineupPlayerIDs.count
                                let botSizes = Set(botResults.prefix(20).map { $0.lineupPlayerIDs.count })
                                let botSizeMismatch = userLineupSize > 0 && !botResults.isEmpty
                                    && !botSizes.contains(userLineupSize)

                                // Detect "too few server entries" — the
                                // exact UFC bug the user kept reporting.
                                // Server has the user's row but no/very few
                                // bots because the early-settle path bailed
                                // before bots were generated. Without
                                // forcing a re-settle here, the loops above
                                // (rrDelta recompute, applyServerHistory)
                                // all key off a near-empty leaderboard and
                                // resolve the user to rank #1 / max +RR
                                // forever, producing the "+1000 won't go
                                // away" loop.
                                let expectedTotalEntries = Self.entryCountFromTournamentID(tid)
                                let tooFewServerEntries = expectedTotalEntries >= 50
                                    && serverResults.count < max(10, expectedTotalEntries / 10)

                                // STABILITY: stale server zeros must NOT nuke a
                                // correct local result. If history already has a
                                // good (non-zero) score for this contest, the
                                // server being all-zero just means it hasn't
                                // received our settle yet — clearing here would
                                // delete the Past Result and bounce the contest
                                // back to a LIVE card, then re-settle, then
                                // repeat (the flip-flop the user reported).
                                let localHasGoodScore = dfsHistory.contains { $0.tournamentId == tid && $0.lineupPoints > 0 }
                                let effectiveAllResultsZero = allResultsZero && !localHasGoodScore

                                if effectiveAllResultsZero || someUserZero || botSizeMismatch || tooFewServerEntries {
                                    // Bad or partial settlement — clear and re-settle from scratch.
                                    let reason: String = {
                                        if effectiveAllResultsZero { return "ALL entries at 0.0 pts" }
                                        if someUserZero { return "\(userServerResults.filter { $0.totalPoints == 0 }.count) of \(userServerResults.count) user entries at 0.0 pts" }
                                        if tooFewServerEntries { return "only \(serverResults.count)/\(expectedTotalEntries) server entries (bots missing from early-settle)" }
                                        return "bot lineup size \(botSizes) doesn't match user's \(userLineupSize)"
                                    }()
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
                            // Build maps keyed by BOTH lineup number (from
                            // entry name "Username #N") AND total points.
                            // Float comparison alone is unreliable across
                            // settlement paths — local NHL row showing
                            // 52.8 vs server 52.7999 misses the points
                            // lookup and falls back to the first user
                            // entry's rank, which is why both multi-lineup
                            // rows ended up showing the same rank #1807.
                            var correctRRByLineupNum: [Int: Int] = [:]
                            var correctRankByLineupNum: [Int: Int] = [:]
                            var correctRRByPoints: [Double: Int] = [:]
                            var correctRankByPoints: [Double: Int] = [:]
                            func extractLineupNum(_ name: String) -> Int? {
                                guard let hashRange = name.range(of: "#"),
                                      let num = Int(name[hashRange.upperBound...].trimmingCharacters(in: .whitespaces)),
                                      num >= 1, num <= 20 else { return nil }
                                return num
                            }
                            for (offset, r) in sorted.enumerated() where r.userID == userID {
                                let rank = ranks[offset]
                                let tieCount = ranks.filter { $0 == rank }.count
                                let pooledRR = DFSEngine.pooledRRDelta(tiedRank: rank, tieCount: tieCount, entryCount: entryCount)
                                correctRRByPoints[r.totalPoints] = pooledRR
                                correctRankByPoints[r.totalPoints] = rank
                                if let ln = extractLineupNum(r.entryName) {
                                    correctRRByLineupNum[ln] = pooledRR
                                    correctRankByLineupNum[ln] = rank
                                }
                            }
                            let serverTotalEntries = sorted.count
                            // Find rank with closest-points tolerance (catches
                            // float-precision misses like 52.8 vs 52.79999).
                            func pointsTolerant(_ pts: Double) -> (rank: Int, rr: Int)? {
                                for (sp, rank) in correctRankByPoints where abs(sp - pts) < 0.05 {
                                    if let rr = correctRRByPoints[sp] { return (rank, rr) }
                                }
                                return nil
                            }

                            var updated = dfsHistory
                            var didFixRR = false
                            for (idx, local) in updated.enumerated() {
                                guard local.tournamentId == tid else { continue }
                                // Prefer lineup-number match (robust for
                                // multi-lineup contests); fall back to
                                // exact-points then close-points lookup.
                                // If NONE match, skip — better to keep
                                // potentially-stale local than guess.
                                let lnKey = local.lineupNumber ?? 1
                                let byLineup = (correctRankByLineupNum[lnKey], correctRRByLineupNum[lnKey])
                                let byExact = (correctRankByPoints[local.lineupPoints], correctRRByPoints[local.lineupPoints])
                                let byClose = pointsTolerant(local.lineupPoints)
                                let resolved: (rank: Int, rr: Int)? = {
                                    if let r = byLineup.0, let rr = byLineup.1 { return (r, rr) }
                                    if let r = byExact.0, let rr = byExact.1 { return (r, rr) }
                                    if let c = byClose { return c }
                                    return nil
                                }()
                                guard let resolved else { continue }
                                let correctRank = resolved.rank
                                let correctRR = resolved.rr
                                let resolvedEntries = max(local.totalEntries, max(entryCount, serverTotalEntries))
                                let needsChange = local.rrDelta != correctRR
                                    || local.rank != correctRank
                                    || local.totalEntries != resolvedEntries
                                if needsChange {
                                    updated[idx] = DFSResult(
                                        id: local.id, tournamentTitle: local.tournamentTitle,
                                        rank: correctRank,
                                        totalEntries: resolvedEntries,
                                        lineupPoints: local.lineupPoints,
                                        rrDelta: correctRR,
                                        loggedAt: local.loggedAt,
                                        tournamentId: local.tournamentId,
                                        lineupNumber: local.lineupNumber
                                    )
                                    didFixRR = true
                                    print("[DFS] Startup: correcting \(tid) entry \(idx): rank \(local.rank)→\(correctRank), rrDelta \(local.rrDelta)→\(correctRR), entries \(local.totalEntries)→\(resolvedEntries)")
                                }
                            }
                            if didFixRR {
                                let oldTotal = dfsHistory.filter { $0.tournamentId == tid }.reduce(0) { $0 + $1.rrDelta }
                                let newTotal = updated.filter { $0.tournamentId == tid }.reduce(0) { $0 + $1.rrDelta }
                                dfsHistoryData = encodedDFSHistory(updated)
                                rrScore += (newTotal - oldTotal)
                                print("[DFS] Startup: fixed rrDelta for \(tid): \(oldTotal) → \(newTotal)")

                                // Also fix server records so they have correct pooled values.
                                // Propagate the correct rank too — otherwise we'd write
                                // back rrDelta=-10 over the server's stale rank=1 and the
                                // next syncHistoryFromServer round would re-read that
                                // inconsistent row and stamp the local history with
                                // rank=1 again (the user's reported "reverts after 30s").
                                let serverUserResults = serverResults.filter { $0.userID == userID }
                                var serverFixedResults: [DFSTournamentResultRecord] = []
                                for r in serverUserResults {
                                    let correctRR = correctRRByPoints[r.totalPoints] ?? r.rrDelta
                                    let correctRank = correctRankByPoints[r.totalPoints] ?? r.rank
                                    if r.rrDelta != correctRR || r.rank != correctRank {
                                        serverFixedResults.append(DFSTournamentResultRecord(
                                            id: r.id, tournamentID: r.tournamentID, userID: r.userID,
                                            entryName: r.entryName, lineupPlayerIDs: r.lineupPlayerIDs,
                                            lineupPlayerNames: r.lineupPlayerNames, totalPoints: r.totalPoints,
                                            playerPoints: r.playerPoints, playerSalaries: r.playerSalaries,
                                            rank: correctRank, rrDelta: correctRR,
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
                                    print("[DFS] Startup: pushed corrected rank/rrDelta to server for \(tid)")
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
                // Decide whether the contest is in the past. The server
                // lock_time is the primary signal, but it can be CORRUPTED into
                // the future — UFC tournament records sometimes get re-stamped
                // with the next card's lock when the slate reloads, which
                // stranded finished UFC contests in "upcoming" forever (they
                // never met `lockTime < now`, so the self-heal kept skipping
                // them). The tournament ID encodes the real event date
                // ("{sport}-YYYYMMDD-…"), which is authoritative — fall back to
                // it when the server lock is missing or implausibly in the future.
                let now = Date()
                let tidEventDate: Date? = {
                    let comps = tid.components(separatedBy: "-")
                    guard comps.count >= 2, comps[1].count == 8 else { return nil }
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyyMMdd"
                    return f.date(from: comps[1])
                }()
                let serverLock = serverTournament?.lockTime
                let startToday = Calendar.current.startOfDay(for: now)
                let isPast: Bool = {
                    if let serverLock, serverLock < now { return true }
                    // Event day already passed → finished regardless of a bad lock.
                    if let d = tidEventDate, d < startToday { return true }
                    return false
                }()
                print("[DFS-\(sport)] self-heal eval tid=\(tid) serverLock=\(serverLock.map { ISO8601DateFormatter().string(from: $0) } ?? "nil") tidDate=\(tidEventDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil") isPast=\(isPast) serverFound=\(serverTournament != nil)")
                guard isPast else { continue }
                // Effective lock for the staleness math below: prefer a valid
                // past server lock, else the ID's event date.
                let lockTime = (serverLock != nil && serverLock! < now) ? serverLock! : (tidEventDate ?? serverLock ?? now)
                // PGA tournaments take 4 days (Thu–Sun) — never settle early
                let daysSinceLock = now.timeIntervalSince(lockTime) / (24 * 3600)
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
                        // Server has good data from a proper settlement — use it.
                        // NOTE: do NOT un-exclude here. `excludedTournamentIDs`
                        // is also how a deliberate admin delete sticks (the
                        // read-time filter in `dfsHistory` drops excluded rows),
                        // and a deleted contest with good server data would be
                        // wrongly resurrected. Wrong auto-ghosting is prevented
                        // at the source now (the ghost hatch gates on
                        // isTournamentFinished), so no good contest gets excluded.
                        print("[DFS-\(sport)] self-heal \(tid): server good (results=\(serverResults.count)) — marking settled + adding to history")
                        markTournamentSettled(tid)
                        await addServerResultToHistoryIfMissing(tournamentID: tid, token: token, userID: userID)
                    } else {
                        print("[DFS-\(sport)] self-heal \(tid): server settled but data check FAILED (countOK=\(countOK) namesGood=\(userNamesGood) realScores=\(hasRealScores) botsHaveScores=\(botsHaveScores) allUserScored=\(allUserScored)) — re-settling")
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

                // Ghost escape hatch (non-golf): if a contest is well past its
                // event and STILL couldn't settle, it's a dead end — ESPN serves
                // no scoreable stats for that event (e.g. ufc-20260614 returns an
                // empty snapshot, or a postponed MLB game). Without this it shows
                // as a perpetual LIVE 0.0 card that can never resolve. Non-golf
                // events finish same-day, so >1 day past + unsettleable = ghost.
                // PGA has its own 7-day ghost in refreshLive (multi-day events).
                //
                // Gate on isTournamentFinished (settled OR already in history),
                // NOT just the settled flag: the good-data branch above adds the
                // result to history but its settled flag can be clobbered by a
                // concurrent sync during its `await`, which used to make this
                // hatch wrongly ghost a perfectly-graded contest (a settled WNBA
                // single game vanished from Past Results and got excluded).
                if !tid.hasPrefix("pga-"), !isTournamentFinished(tid) {
                    let staleDays = now.timeIntervalSince(lockTime) / (24 * 3600)
                    if staleDays > 1 {
                        print("[DFS-\(sport)] \(tid): \(String(format: "%.1f", staleDays))d past and ungradeable (no ESPN scores) — ghosting from active")
                        enteredTournamentIDs.remove(tid)
                        userEntryRecords[tid] = nil
                        markTournamentSettled(tid)
                        Self.excludeTournament(tid)
                    }
                }
            }
        } catch {
            print("[DFS] Failed to check past tournaments: \(error.localizedDescription)")
        }
    }

    /// Settles a past tournament that was never settled on the server.
    /// Reconstructs the field from the user's entry, fetches final scores from ESPN,
    /// Fetches one specific past UFC card by date and returns one slate
    /// game per fight (using the competition ID — that's what the live
    /// scoring provider keys against). The standard `fetchSlateGamesForDate`
    /// helper is unusable for UFC because it assumes one team-vs-team
    /// competition per event and reads `competitor.team.abbreviation`.
    private func fetchUFCSlateGamesForDate(_ dateKey: String) async -> [DFSSlateGame] {
        let urlString = "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=\(dateKey)"
        guard let url = URL(string: urlString) else { return [] }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            return []
        }
        var games: [DFSSlateGame] = []
        for event in events {
            let comps = event["competitions"] as? [[String: Any]] ?? []
            for comp in comps {
                guard let compID = comp["id"] as? String,
                      let competitors = comp["competitors"] as? [[String: Any]],
                      competitors.count == 2 else { continue }
                let c1 = competitors[0]
                let c2 = competitors[1]
                let c1Name = (c1["athlete"] as? [String: Any])?["shortName"] as? String
                    ?? (c1["athlete"] as? [String: Any])?["displayName"] as? String ?? "Fighter 1"
                let c2Name = (c2["athlete"] as? [String: Any])?["shortName"] as? String
                    ?? (c2["athlete"] as? [String: Any])?["displayName"] as? String ?? "Fighter 2"
                let state = ((comp["status"] as? [String: Any])?["type"] as? [String: Any])?["state"] as? String ?? "pre"
                let dateStr = comp["date"] as? String ?? ""
                let startTime: Date = {
                    let fmt = ISO8601DateFormatter()
                    return fmt.date(from: dateStr) ?? Date()
                }()
                games.append(DFSSlateGame(
                    id: compID, awayTeam: c1Name, homeTeam: c2Name,
                    startTime: startTime, state: state
                ))
            }
        }
        return games
    }

    /// builds a full simulated field with real player lineups, and persists everything to server.
    /// Returns the generated result records on success so callers can use them directly
    /// without needing to re-fetch from the server (which may still have stale data if DELETE failed).
    @discardableResult
    /// The calendar days immediately around a "YYYYMMDD" date string (next, then
    /// previous), in the same ET bucket the slate fetch uses. Used to locate a
    /// late/midnight game that ESPN files on the adjacent day from the slate.
    private func adjacentDateStrings(_ dateString: String) -> [String] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        guard let d = fmt.date(from: dateString) else { return [] }
        let cal = Calendar(identifier: .gregorian)
        return [1, -1].compactMap { delta in
            cal.date(byAdding: .day, value: delta, to: d).map { fmt.string(from: $0) }
        }
    }

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
        case "wnba": espnSport = "basketball/wnba"
        case "mlb": espnSport = "baseball/mlb"
        case "nhl": espnSport = "hockey/nhl"
        case "epl": espnSport = "soccer/eng.1"
        case "ucl": espnSport = "soccer/uefa.champions"
        case "wc": espnSport = "soccer/fifa.world"
        case "ufc": espnSport = "mma/ufc"
        case "nfl": espnSport = "football/nfl"
        case "cfb": espnSport = "football/college-football"
        default: espnSport = "basketball/nba"
        }

        // Fetch that day's slate games. UFC needs special handling: the
        // generic `fetchSlateGamesForDate` assumes one team-vs-team
        // competition per event and reads `competitor.team.abbreviation`,
        // which fails for UFC (athletes, not teams, and many fights per
        // event). Hit ESPN's UFC scoreboard for the exact date and build
        // per-fight slate games. The UFC slate provider can't be reused
        // here because it returns the "best" upcoming/live card — for
        // settlement we need the specific past card by date.
        let allPastSlateGames: [DFSSlateGame]
        if sportPrefix == "ufc" {
            allPastSlateGames = await fetchUFCSlateGamesForDate(dateString)
        } else {
            allPastSlateGames = await fetchSlateGamesForDate(dateString, espnSport: espnSport)
        }
        guard !allPastSlateGames.isEmpty else {
            print("[DFS-settle] \(tournamentID): NO past slate games for date \(dateString) (sport \(sportPrefix)) — ESPN returned no card; cannot settle")
            return nil
        }

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
        if let sgID = singleGameID {
            // Single-game contest: settle ONLY against its own game. A late
            // "midnight" kickoff falls on a different ESPN calendar day than the
            // slate's date (date boundary in ET vs UTC), so the game may not be
            // in this date's slate — search the tournament date's neighbors
            // before giving up. CRITICAL: if we still can't find it, DO NOT fall
            // back to the day's other games. Doing so grades the contest against
            // unrelated (already-final) games → a phantom 0.0 FINAL while the
            // real game is still being played.
            var found = allPastSlateGames.first(where: { $0.id == sgID })
            if found == nil {
                for adj in adjacentDateStrings(dateString) {
                    let games = sportPrefix == "ufc"
                        ? await fetchUFCSlateGamesForDate(adj)
                        : await fetchSlateGamesForDate(adj, espnSport: espnSport)
                    if let g = games.first(where: { $0.id == sgID }) { found = g; break }
                }
            }
            guard let game = found else {
                print("[DFS-settle] \(tournamentID): single game \(sgID) not found on \(dateString)±1 — skipping (likely a late/midnight game still pending)")
                return nil
            }
            pastSlateGames = [game]
        } else {
            // Multi-game main slate. A staggered SOCCER slate can include a late
            // "midnight" kickoff that ESPN files on the NEXT calendar day (e.g.
            // JOR @ AUT at 00:00). Pull early next-day games (kickoff before ~6am
            // ET) into the set so the slate WAITS for them instead of finalizing
            // once the same-day games end. Gated to soccer + early kickoff so a
            // normal next-day slate (afternoon/evening games) is never dragged in.
            var games = allPastSlateGames
            if ["epl", "ucl", "wc"].contains(sportPrefix),
               let nextDay = adjacentDateStrings(dateString).first {
                let nextGames = await fetchSlateGamesForDate(nextDay, espnSport: espnSport)
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
                let existing = Set(games.map { $0.id })
                let earlyNext = nextGames.filter {
                    cal.component(.hour, from: $0.startTime) < 6 && !existing.contains($0.id)
                }
                if !earlyNext.isEmpty {
                    print("[DFS-settle] \(tournamentID): including \(earlyNext.count) cross-midnight game(s) from \(nextDay) (states=\(earlyNext.map { $0.state }))")
                    games.append(contentsOf: earlyNext)
                }
            }
            pastSlateGames = games
        }

        // Check relevant games are final
        let allFinal = pastSlateGames.allSatisfy { $0.state == "post" }
        guard allFinal else {
            print("[DFS-settle] \(tournamentID): \(pastSlateGames.count) games for \(dateString) but states=\(pastSlateGames.map { $0.state }) — not all final, skipping")
            return nil
        }

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
        case "wnba": settlementScoringProvider = ESPNWNBADFSLiveScoringProvider()
        case "epl": settlementScoringProvider = ESPNSoccerDFSLiveScoringProvider(league: .epl)
        case "ucl": settlementScoringProvider = ESPNSoccerDFSLiveScoringProvider(league: .ucl)
        case "wc": settlementScoringProvider = ESPNSoccerDFSLiveScoringProvider(league: .worldCup)
        case "ufc": settlementScoringProvider = ESPNUFCDFSLiveScoringProvider()
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
            } else if sportPrefix == "epl" || sportPrefix == "ucl" || sportPrefix == "wc" {
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
        guard !allPlayers.isEmpty else {
            print("[DFS-settle] \(tournamentID): scoring snapshot EMPTY for \(dateString) (\(sportPrefix)) — provider returned no player scores; cannot settle")
            return nil
        }

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
                    if let name {
                        playerNameLookup[pid] = name
                    } else if let decoded = self.decodedStubName(for: pid) {
                        // ESPN couldn't resolve this id — fall back to the stub
                        // decoder so we render "Adin Hill" instead of "Unknown".
                        playerNameLookup[pid] = decoded
                    }
                }
            }
        }

        let userPlayerIDs = userEntry.lineupPlayerIDs
        let lineupSize = userPlayerIDs.count
        // Fetch the tournament record up front: besides salaries/bots it carries
        // the persisted `is_single_game` flag. UFC CAPTAIN main slates (MVP + 5
        // FLEX) have NO "-sg-" in their ID yet ARE single-game-style scoring, so
        // the ID alone misses them. Trust the draft-time flag so captain contests
        // grade with the 1.5x MVP (and a classic UFC card grades flat).
        let serverTournament = try? await SupabaseService.shared.fetchTournament(tournamentID: tournamentID, accessToken: token)
        let isSingleGame = isSingleGameTournament || (serverTournament?.isSingleGame ?? false)

        // Compute per-entry user stats for the primary entry (used for backward compat)
        var userPerPlayerPoints: [String: Double] = [:]
        var userPoints = 0.0
        for (index, pid) in userPlayerIDs.enumerated() {
            let pts = (snapshot.playerFantasyPoints[pid] ?? 0)
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
        // Bots MUST match the user's lineup format. The re-settle guard clears +
        // re-settles whenever saved-bot size ≠ the user's entry size — so a
        // hardcoded per-sport guess that's wrong (e.g. WNBA classic = 7 but the
        // switch had no `wnba` case → defaulted to 8) causes a perpetual
        // clear→re-settle flip-flop (grade appears, then vanishes on the next
        // refresh). The user's own submitted lineup is the source of truth, so
        // size bots to it and a mismatch can never happen, for ANY sport.
        let botLineupSize: Int
        let userEntrySize = userEntry.lineupPlayerIDs.count
        if userEntrySize > 0 {
            botLineupSize = userEntrySize
        } else if isSingleGame {
            botLineupSize = 6
        } else {
            switch sportPrefix {
            case "mlb": botLineupSize = 10
            case "ncaam": botLineupSize = 6
            case "nhl": botLineupSize = 9
            case "epl", "ucl", "wc": botLineupSize = 8
            case "nfl": botLineupSize = 9
            case "cfb": botLineupSize = 8
            case "ufc": botLineupSize = 6   // DK showdown — 6 fighters, no position slots
            case "wnba": botLineupSize = 7  // WNBA classic
            default: botLineupSize = 8  // NBA
            }
        }

        // serverTournament already fetched above (carries salaries + bot field).
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
                        if let name {
                        playerNameLookup[pid] = name
                    } else if let decoded = self.decodedStubName(for: pid) {
                        // ESPN couldn't resolve this id — fall back to the stub
                        // decoder so we render "Adin Hill" instead of "Unknown".
                        playerNameLookup[pid] = decoded
                    }
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
                let pts = (snapshot.playerFantasyPoints[pid] ?? 0)
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
        let salaryFloor: Int = (sportPrefix == "nhl") ? 3500 : (sportPrefix == "mlb") ? 2000 : (sportPrefix == "epl" || sportPrefix == "ucl" || sportPrefix == "wc") ? 2500 : 3000

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
                        if let name {
                        playerNameLookup[pid] = name
                    } else if let decoded = self.decodedStubName(for: pid) {
                        // ESPN couldn't resolve this id — fall back to the stub
                        // decoder so we render "Adin Hill" instead of "Unknown".
                        playerNameLookup[pid] = decoded
                    }
                    }
                }
            }
            // Final fallback for any pid still lacking a name: stub decode.
            // Catches RG-injected ids that ESPN's athlete endpoint can't
            // resolve (e.g. nhl-dk-adin-hill → "Adin Hill").
            for pid in pids where playerNameLookup[pid] == nil {
                if let decoded = decodedStubName(for: pid) {
                    playerNameLookup[pid] = decoded
                }
            }
            let pnames = pids.map { playerNameLookup[$0] ?? $0 }
            let ppts = Dictionary(uniqueKeysWithValues: pids.enumerated().map { (i, pid) in
                let raw = (snapshot.playerFantasyPoints[pid] ?? 0)
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
            case "epl", "ucl", "wc": botRosterSlots = ["GK", "DEF", "DEF", "MID", "MID", "FWD", "FWD", "FLEX"]
            case "nfl": botRosterSlots = ["QB", "RB", "RB", "WR", "WR", "WR", "TE", "FLEX", "DEF"]
            case "cfb": botRosterSlots = ["QB", "RB", "RB", "WR", "WR", "WR", "TE", "FLEX"]
            case "ufc": botRosterSlots = nil  // no position constraints
            case "nba": botRosterSlots = nil
            default: botRosterSlots = nil
            }
        }

        // Helper: compute total points for a lineup, applying 1.5x MVP multiplier for single-game
        func lineupTotal(_ playerIDs: [String]) -> Double {
            var total = 0.0
            for (i, pid) in playerIDs.enumerated() {
                let pts = (snapshot.playerFantasyPoints[pid] ?? 0)
                total += (isSingleGame && i == 0) ? pts * 1.5 : pts
            }
            return total
        }

        // SETTLEMENT-TIME late swap for ALL late-swap sports (client-window-
        // independent). A staggered slate generates bots at the EARLIEST game's
        // lock, so later games are filled with cheap UNCONFIRMED placeholders. If
        // no client was open during a late game's confirm→lock window, those never
        // got upgraded live — so here, at settlement (which runs whenever the app
        // opens after games), any placeholder that turned out to be a DNP (didn't
        // appear in the boxscore) is upgraded to a player who ACTUALLY PLAYED in
        // the same roster slot. Ranked by SALARY (a pre-game value proxy, NEVER by
        // points → no hindsight) with a deterministic per-bot-name hash so every
        // user settles to the IDENTICAL field (same bot in 1st/2nd/3rd for all).
        // High-salary studs who played (late-game forwards, late MLB bats, etc.)
        // thus get realistic exposure. Players who appeared are kept as drafted.
        // Applies to every late-swap sport (NBA/NHL/MLB/NFL/CFB/soccer) — i.e.
        // multi-game, non-single-game, excluding UFC/PGA. Where the settlement
        // position derivation is coarse (NHL skater-vs-goalie; football all-UTIL),
        // matching falls back to "any appeared player" so DNP slots still upgrade.
        let isLateSwapSettle = !isSingleGame && !["ufc", "pga"].contains(sportPrefix)
        let appearedIDs = Set(allPlayers.map(\.id))
        // Deterministic salary for ranking/budget (NEVER Int.random — every device
        // must agree): canonical tournament price, else a stable id-hash estimate.
        func detSal(_ id: String) -> Int {
            if let s = tournamentSalaries[id], s > 0 { return s }
            var h: UInt64 = 14695981039346656037
            for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            return 3000 + Int(h % 5000) // $3000–$8000, deterministic
        }
        // All appeared players, ordered by salary desc then id (stable tiebreak so
        // dict-iteration order can't make two devices diverge).
        let appearedSorted: [String] = allPlayers.map(\.id)
            .sorted { detSal($0) != detSal($1) ? detSal($0) > detSal($1) : $0 < $1 }
        let posByID = Dictionary(allPlayers.map { ($0.id, $0.position) }, uniquingKeysWith: { a, _ in a })
        // Does an appeared player's derived position fill this roster slot?
        func posFillsSlot(_ pos: String, _ slot: String) -> Bool {
            switch sportPrefix {
            case "epl", "ucl", "wc": return slot == "FLEX" ? pos != "GK" : pos == slot
            case "mlb": let p: Set<String> = ["SP", "RP", "P"]; return slot == "P" ? p.contains(pos) : !p.contains(pos)
            case "nhl": return slot == "G" ? pos == "G" : pos != "G"
            default: return false // football/ncaam: positions are all UTIL → fall back to any
            }
        }
        // Precompute the candidate list per distinct slot name (salary-sorted),
        // with a permissive fallback to all appeared players when none match.
        var candsBySlot: [String: [String]] = [:]
        if isLateSwapSettle, let slots = botRosterSlots {
            for slot in Set(slots) {
                let matched = appearedSorted.filter { posFillsSlot(posByID[$0] ?? "", slot) }
                candsBySlot[slot] = matched.isEmpty ? appearedSorted : matched
            }
        }
        func upgradeBotLineup(_ botName: String, _ ids: [String]) -> [String] {
            guard isLateSwapSettle else { return ids }
            let slots = botRosterSlots
            var newIDs = ids
            var used = Set(ids)
            var usedSalary = ids.reduce(0) { $0 + detSal($1) }
            for i in ids.indices {
                let pid = ids[i]
                if appearedIDs.contains(pid) { continue } // played → keep as drafted
                let curSal = detSal(pid)
                let pool: [String] = (slots != nil && i < slots!.count) ? (candsBySlot[slots![i]] ?? appearedSorted) : appearedSorted
                let cands = pool.filter { !used.contains($0) && (usedSalary - curSal + detSal($0)) <= salaryCap }
                guard !cands.isEmpty else { continue }
                // Deterministic per-(bot,slot) pick; r*r biases toward top salary
                // while the bot-name hash spreads exposure across the field.
                var h: UInt64 = 14695981039346656037
                for b in botName.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
                h = (h ^ UInt64(i &+ 1)) &* 1099511628211
                let r = Double(h >> 11) / Double(UInt64(1) << 53)
                let idx = min(cands.count - 1, Int(Double(cands.count) * r * r))
                let pick = cands[idx]
                newIDs[i] = pick
                used.remove(pid); used.insert(pick)
                usedSalary += detSal(pick) - curSal
            }
            return newIDs
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
                // Upgrade DNP placeholders to players who appeared, in the same
                // slot — all late-swap sports; no-op for single-game/UFC/PGA.
                let lineupIDs = upgradeBotLineup(bot.name, bot.playerIDs)
                let botTotal = lineupTotal(lineupIDs)
                let pnames = lineupIDs.map { playerNameLookup[$0] ?? $0 }
                let ppts = Dictionary(uniqueKeysWithValues: lineupIDs.enumerated().map { (i, pid) in
                    let raw = (snapshot.playerFantasyPoints[pid] ?? 0)
                    return (pid, (isSingleGame && i == 0) ? raw * 1.5 : raw)
                })
                // Canonical-first salary lookup: in priority order,
                //   1. the user's frozen lineup snapshot (`userStoredSalaries`) —
                //      ensures Towns/Anunoby/etc shared between user and bot rows
                //      display the SAME price the user paid,
                //   2. the tournament's stored snapshot (frozen at first submit),
                //   3. the bot's own saved salary,
                //   4. current live pool, then a fallback floor.
                // Without (1)+(2), bots saved with prices from a different RG fetch
                // moment than the user submission display higher prices for the same
                // player ($13K Towns next to user's $10K Towns in the same contest).
                let psals = Dictionary(uniqueKeysWithValues: lineupIDs.enumerated().map { (i, pid) -> (String, Int) in
                    let userSal = userStoredSalaries[pid] ?? 0
                    let tourneySal = tournamentSalaries[pid] ?? 0
                    let savedSal = bot.playerSalaries?[pid] ?? 0
                    let liveSal = salaryByID[pid] ?? 0
                    let sal: Int
                    if userSal > 0 { sal = userSal }
                    else if tourneySal > 0 { sal = tourneySal }
                    else if savedSal > 0 { sal = savedSal }
                    else { sal = liveSal }
                    let baseSal = sal > 0 ? sal : salaryFloor
                    return (pid, (isSingleGame && i == 0) ? Int(Double(baseSal) * 1.5) : baseSal)
                })
                field.append(SimEntry(
                    name: bot.name,
                    playerIDs: lineupIDs,
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
                        let raw = (snapshot.playerFantasyPoints[pid] ?? 0)
                        return (pid, (isSingleGame && i == 0) ? raw * 1.5 : raw)
                    })
                    // Use the DFSPlayer salary from the bot pool (what generateBotLineup actually used)
                    let botPlayerLookup = Dictionary(dfsPlayersForBot.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
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
                    let raw = (snapshot.playerFantasyPoints[pid] ?? 0)
                    return (pid, (isSingleGame && idx == 0) ? raw * 1.5 : raw)
                })
                // Use the DFSPlayer salary from the bot pool (what generateBotLineup actually used)
                let botPlayerLookup = Dictionary(dfsPlayersForBot.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })
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
        // Stamp history with a sane date: a corrupted FUTURE lock_time (see the
        // self-heal note) would otherwise log this finished contest with a
        // future date and float it to the top of Past Results. Fall back to the
        // event date encoded in the tournament ID when the lock is implausible.
        let settledLoggedAt: Date = {
            let now = Date()
            if let lock = serverTournament?.lockTime, lock < now { return lock }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd"
            if let d = f.date(from: dateString) { return d }
            return serverTournament?.lockTime ?? now
        }()

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
                    loggedAt: settledLoggedAt,
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
    /// When `forceFinal=true`, skips the snapshot.allGamesFinal gate — the
    /// caller has already established that the tournament is past (via
    /// submittedAt staleness or similar) and just wants to settle with
    /// whatever score data ESPN provides. Used by the PGA self-heal where
    /// ESPN's status fields (completed/STATUS_FINAL) are unreliable for
    /// older events.
    private func settleUnsettledPastGolfTournament(
        tournamentID: String,
        userEntry: DFSEntryRecord,
        forceFinal: Bool = false,
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

        // Fetch golf slate for player names / baseline salaries — but this is
        // NON-ESSENTIAL: names fall back to ESPN/stub lookups and salaries to
        // the stored tournament prices. Don't abort settlement if it's missing
        // (e.g. between events, or now that we gate slates without live DK
        // prices) — otherwise a finished tournament can never (re)settle its
        // bot field and the standings show every bot at 0.
        let slateProvider = ESPNPGADFSSlateProvider()
        let slate = try? await slateProvider.fetchSlate()

        // Create a slate game for the scoring provider using the CORRECT event ID
        // (not the current slate's game, which may be a different tournament)
        let slateGame: DFSSlateGame
        if let existingGame = slate?.includedGames.first, existingGame.id == eventID {
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

        // CRITICAL: don't settle a PGA tournament that isn't actually
        // finished. The scoring provider's `allGamesFinal` requires the
        // ESPN event to be in "post" state, marked completed/STATUS_FINAL,
        // AND every non-cut competitor to have a real R4 linescore. The
        // outer time-based gate (3.5 days since lock) fires too early for
        // a Sunday-finishing tournament whose lock time was Thursday
        // morning — letting settlement go through with round 3 scores
        // and a few R4 leaders still on the course.
        if !snapshot.allGamesFinal && !forceFinal {
            print("[DFS] Golf on-the-fly settlement (\(tournamentID)): snapshot.allGamesFinal=false — tournament still in progress, skipping. eventID=\(eventID) playerCount=\(snapshot.playerFantasyPoints.count)")
            return
        }
        if forceFinal && !snapshot.allGamesFinal {
            // Self-heal-initiated bypass. ESPN's status fields for past
            // events (status.type.completed, STATUS_FINAL, status.period)
            // are frequently nil on the date-fallback response, so we
            // can't rely on allGamesFinal. The caller has already
            // verified staleness; we just need score data to be present.
            guard !snapshot.playerFantasyPoints.isEmpty else {
                print("[DFS] Golf on-the-fly settlement (\(tournamentID)): forceFinal=true but no player score data — skipping. eventID=\(eventID)")
                return
            }
            print("[DFS] Golf on-the-fly settlement (\(tournamentID)): forceFinal=true bypassing allGamesFinal gate (playerCount=\(snapshot.playerFantasyPoints.count))")
        } else {
            print("[DFS] Golf on-the-fly settlement (\(tournamentID)): allGamesFinal=TRUE — proceeding with field build")
        }

        // Build player info from snapshot
        struct PlayerInfo {
            let id: String
            let name: String
            let points: Double
        }
        let allPlayers: [PlayerInfo] = snapshot.playerFantasyPoints.compactMap { (pid, pts) in
            let name = snapshot.playerLiveStats[pid]?.name ?? slate?.players.first(where: { $0.id == pid })?.name ?? pid
            return PlayerInfo(id: pid, name: name, points: pts)
        }
        guard !allPlayers.isEmpty else {
            print("[DFS] Golf on-the-fly settlement: no player scores available")
            return
        }

        // The scoring snapshot is keyed by ESPN athlete IDs ("pga-{espnID}"), but
        // when ESPN returns no competitor refs the slate (and therefore the bot
        // lineups) is built from the DK-only fallback with name-slug IDs
        // ("pga-dk-rory-mcilroy"). Those never match the snapshot, so bots scored
        // 0. Resolve points by NAME for slug IDs so every entry scores regardless
        // of which ID scheme its lineup used.
        let golfPointsByName: [String: Double] = {
            var m: [String: Double] = [:]
            for p in allPlayers { m[RotoGrindersSalaryProvider.normalizeName(p.name)] = p.points }
            return m
        }()
        // Last-name index as a fallback — golf fields are ~150 players so last
        // names are almost always unique, and it catches slug/spelling/accent/
        // suffix mismatches (e.g. "min woo lee" vs "minwoo lee") that the exact
        // match misses. Only keep last names that are unambiguous in this field.
        let golfPointsByLastName: [String: Double] = {
            var counts: [String: Int] = [:]
            var m: [String: Double] = [:]
            for p in allPlayers {
                guard let last = RotoGrindersSalaryProvider.normalizeName(p.name).split(separator: " ").last.map(String.init) else { continue }
                counts[last, default: 0] += 1
                m[last] = p.points
            }
            return m.filter { counts[$0.key] == 1 }  // unambiguous only
        }()
        func golferPoints(_ id: String) -> Double {
            if let direct = snapshot.playerFantasyPoints[id] { return direct }
            let rawName: String
            if id.hasPrefix("pga-dk-") {
                rawName = String(id.dropFirst("pga-dk-".count)).replacingOccurrences(of: "-", with: " ")
            } else if id.hasPrefix("pga-") {
                rawName = String(id.dropFirst("pga-".count)).replacingOccurrences(of: "-", with: " ")
            } else {
                return 0
            }
            let norm = RotoGrindersSalaryProvider.normalizeName(rawName)
            if let exact = golfPointsByName[norm] { return exact }
            if let last = norm.split(separator: " ").last.map(String.init),
               let byLast = golfPointsByLastName[last] { return byLast }
            return 0
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
        for player in (slate?.players ?? []) {
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
                    if let name {
                        playerNameLookup[pid] = name
                    } else if let decoded = self.decodedStubName(for: pid) {
                        // ESPN couldn't resolve this id — fall back to the stub
                        // decoder so we render "Adin Hill" instead of "Unknown".
                        playerNameLookup[pid] = decoded
                    }
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
                    if let name {
                        playerNameLookup[pid] = name
                    } else if let decoded = self.decodedStubName(for: pid) {
                        // ESPN couldn't resolve this id — fall back to the stub
                        // decoder so we render "Adin Hill" instead of "Unknown".
                        playerNameLookup[pid] = decoded
                    }
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
        for player in (slate?.players ?? []) {
            salaryByID[player.id] = player.salary
        }
        // Override with stored tournament salaries (original prices from draft day)
        for (pid, sal) in tournamentSalaries where sal > 0 {
            salaryByID[pid] = sal
        }
        // Bridge by NAME: the stored draft-day prices can be keyed by a
        // different id scheme (slug) than the scoring snapshot (espnID), so map
        // the real prices onto the actual-field golfers by name. This keeps the
        // event's OWN prices instead of leaking the current week's prices in.
        var rbcPriceByName: [String: Int] = [:]
        for (pid, sal) in tournamentSalaries where sal > 0 {
            let nm = playerNameLookup[pid]
                ?? (pid.hasPrefix("pga-dk-") ? String(pid.dropFirst("pga-dk-".count)).replacingOccurrences(of: "-", with: " ") : pid)
            rbcPriceByName[RotoGrindersSalaryProvider.normalizeName(nm)] = sal
        }
        if !rbcPriceByName.isEmpty {
            for player in allPlayers {
                if let realPrice = rbcPriceByName[RotoGrindersSalaryProvider.normalizeName(player.name)] {
                    salaryByID[player.id] = realPrice
                }
            }
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
                let pts = golferPoints(pid)
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
            let ppts = Dictionary(uniqueKeysWithValues: pids.map { ($0, golferPoints($0)) })
            let psals = Dictionary(uniqueKeysWithValues: pids.compactMap { pid -> (String, Int)? in
                guard let sal = salaryByID[pid], sal > 0 else { return nil }
                return (pid, sal)
            })
            let total = pids.reduce(0.0) { $0 + (golferPoints($1)) }
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
        let golfSalaryByID = Dictionary(baseGolfPlayers.map { ($0.id, $0.salary) }, uniquingKeysWith: { a, _ in a })

        // Field membership from the scoring snapshot = exactly who actually
        // played this event. Saved bot fields generated against a DIFFERENT
        // slate (e.g. the next week's pool, after this event rotated off ESPN)
        // contain golfers who never teed off here — they score 0 and the prices
        // are wrong. Detect that and regenerate from the real field instead.
        let golfFieldIDs = Set(allPlayers.map { $0.id })
        let golfFieldNames = Set(allPlayers.map { RotoGrindersSalaryProvider.normalizeName($0.name) })
        let golfFieldLastNames = Set(allPlayers.compactMap { RotoGrindersSalaryProvider.normalizeName($0.name).split(separator: " ").last.map(String.init) })
        func playedInEvent(_ id: String) -> Bool {
            if golfFieldIDs.contains(id) { return true }
            let raw: String
            if id.hasPrefix("pga-dk-") { raw = String(id.dropFirst("pga-dk-".count)) }
            else if id.hasPrefix("pga-") { raw = String(id.dropFirst("pga-".count)) }
            else { raw = id }
            let nm = RotoGrindersSalaryProvider.normalizeName(raw.replacingOccurrences(of: "-", with: " "))
            if golfFieldNames.contains(nm) { return true }
            if let last = nm.split(separator: " ").last.map(String.init) { return golfFieldLastNames.contains(last) }
            return false
        }

        // Use saved bot lineups if available (persisted at tournament start) AND
        // they actually belong to this event's field.
        let savedGolfBotField = serverTournament?.botField
        let savedGolfBotsBelong: Bool = {
            guard let saved = savedGolfBotField, !saved.isEmpty else { return false }
            let sample = saved.prefix(50)
            var slots = 0, played = 0
            for bot in sample {
                for pid in bot.playerIDs { slots += 1; if playedInEvent(pid) { played += 1 } }
            }
            guard slots > 0 else { return false }
            let coverage = Double(played) / Double(slots)
            if coverage < 0.85 {
                print("[DFS] Saved golf bots only \(Int(coverage * 100))% in the actual field — regenerating from the real field for \(tournamentID)")
            }
            return coverage >= 0.85
        }()
        if let savedGolfBots = savedGolfBotField, !savedGolfBots.isEmpty, savedGolfBotsBelong {
            print("[DFS] Using \(savedGolfBots.count) saved bot lineups for golf \(tournamentID)")
            for (i, bot) in savedGolfBots.enumerated() {
                let botTotal = bot.playerIDs.reduce(0.0) { $0 + (golferPoints($1)) }
                let pnames = bot.playerIDs.map { playerNameLookup[$0] ?? $0 }
                let ppts = Dictionary(uniqueKeysWithValues: bot.playerIDs.map { ($0, golferPoints($0)) })
                // Prefer the bot's OWN saved salaries (the prices it was drafted
                // against) over the current pool — otherwise a valid past lineup
                // displays priced at today's event and shows over the $50K cap.
                let psals = Dictionary(uniqueKeysWithValues: bot.playerIDs.map { pid in
                    (pid, bot.playerSalaries?[pid] ?? golfSalaryByID[pid] ?? 0)
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
                        // Outcome-BLIND projection: drive bot picks off the golfer's
                        // DRAFT-DAY salary (the market's pre-event expectation), NEVER
                        // the actual result. Wide per-bot noise spreads the field so
                        // bots vary instead of converging on the post-hoc optimal
                        // lineup. They still spend ~$50K via generateGolfBotLineup.
                        let salaryK = Double(p.salary) / 1000.0
                        let simulatedProjection = max(salaryK * Double.random(in: 4.0...10.0), 1.0)
                        return DFSPlayer(
                            id: p.id, name: p.name, team: "", position: "G",
                            salary: p.salary, projectedPoints: simulatedProjection, gameID: nil
                        )
                    }
                    let botLineupIDs = generateBotLineup(from: golfDFSPlayersForBot, salaryCap: golfSalaryCap, lineupSize: lineupSize)
                    let botTotal = botLineupIDs.reduce(0.0) { $0 + (golferPoints($1)) }
                    let pnames = botLineupIDs.map { playerNameLookup[$0] ?? $0 }
                    let ppts = Dictionary(uniqueKeysWithValues: botLineupIDs.map { ($0, golferPoints($0)) })
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
                    // Outcome-BLIND projection: salary-driven, never actualPoints.
                    // See the saved-bot-fill branch above for rationale.
                    let salaryK = Double(p.salary) / 1000.0
                    let simulatedProjection = max(salaryK * Double.random(in: 4.0...10.0), 1.0)
                    return DFSPlayer(
                        id: p.id, name: p.name, team: "", position: "G",
                        salary: p.salary, projectedPoints: simulatedProjection, gameID: nil
                    )
                }
                let botLineupIDs = generateBotLineup(from: golfDFSPlayersForBot, salaryCap: golfSalaryCap, lineupSize: lineupSize)
                let botTotal = botLineupIDs.reduce(0.0) { $0 + (golferPoints($1)) }
                let pnames = botLineupIDs.map { playerNameLookup[$0] ?? $0 }
                let ppts = Dictionary(uniqueKeysWithValues: botLineupIDs.map { ($0, golferPoints($0)) })
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

        let title = serverTournament?.title ?? slate?.tournament.title ?? "PGA Tournament"
        // Golf lock times aren't corrupted like UFC's, so the stored lock is the
        // right history date; this binding just lets the shared append code below
        // reference `settledLoggedAt` (mirrors the non-golf settlement path).
        let settledLoggedAt: Date = serverTournament?.lockTime ?? Date()

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
                    loggedAt: settledLoggedAt,
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
            // Match on userID ONLY — that already isolates the user's own rows.
            // The previous `&& $0.isCurrentUser` could drop the user's result
            // when the server row had that flag false/null, leaving the contest
            // marked settled (gone from active cards) but with NO Past Results
            // row — it just vanished. The settlement quality-check that gates
            // this path matches on userID only, so this now agrees with it.
            let userResults = allResults.filter { $0.userID == userID }
            guard !userResults.isEmpty else {
                print("[DFS-\(sport)] addServerResultToHistory \(tournamentID): server has \(allResults.count) results but NONE for this user — cannot add to history")
                return
            }

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

    /// One-shot heal that scans local `settledTournaments` for PGA entries
    /// that shouldn't be settled yet (lockTime within last 72h). Refunds RR
    /// and removes the corresponding `dfsHistory` rows so the tournament
    /// returns to in-progress. Guarded by a UserDefaults version flag so it
    /// only runs once per device unless the version is bumped.
    private func healPrematurePGASettlements() async {
        guard sport == "PGA", let token = accessToken else { return }
        let healVersionKey = "pgaPrematureSettleHealVersion"
        // v2 ran once on devices that had `pga-<event>-2000` force-settled
        // by the pre-fix self-heal — but un-settling locally while the
        // server still held the (wrong) Final state created an unrenderable
        // hybrid state in the lobby (active+entered, no live field). With
        // the import guard removed elsewhere in this file, the server's
        // existing Final state re-imports cleanly on the next sync. No
        // further heal work is needed — the base-event-ID fix in
        // `PGA-SelfHeal` prevents new occurrences, and the next real
        // settlement (Sunday for in-progress events) will overwrite the
        // stale R1-only scores with the correct R4 totals.
        let currentHealVersion = 2
        if UserDefaults.standard.integer(forKey: healVersionKey) >= currentHealVersion { return }

        let pgaSettled = settledTournaments.filter { $0.hasPrefix("pga-") }
        var totalRefund = 0
        var updatedHistory = dfsHistory
        var updatedSettled = settledTournaments
        var changed = false

        for tid in pgaSettled {
            guard let tournament = try? await SupabaseService.shared.fetchTournament(
                tournamentID: tid, accessToken: token
            ) else { continue }
            let lockTime = tournament.lockTime
            let hoursElapsed = Date().timeIntervalSince(lockTime) / 3600
            guard hoursElapsed < 72 else { continue }

            let staleRows = updatedHistory.filter { $0.tournamentId == tid }
            let refund = staleRows.reduce(0) { $0 + $1.rrDelta }
            totalRefund += refund
            updatedHistory.removeAll { $0.tournamentId == tid }
            updatedSettled.remove(tid)
            changed = true
            print("[DFS-PGA-Heal] Un-settled premature \(tid) — only \(String(format: "%.1f", hoursElapsed))h since lockTime, refunded \(refund) RR")
        }

        if changed {
            dfsHistoryData = encodedDFSHistory(updatedHistory)
            settledTournamentData = (try? JSONEncoder().encode(updatedSettled)) ?? Data()
            rrScore -= totalRefund
        }
        UserDefaults.standard.set(currentHealVersion, forKey: healVersionKey)
    }

    /// Per-VM wrapper: fetches DFS history (and tournament metadata) from
    /// the server and applies it locally. Prefer the shared
    /// `syncAllSportsHistoryFromServer` entry point when syncing all sport
    /// VMs at once — it does ONE network round-trip and dispatches to each
    /// VM, avoiding the 10x DB hammer that triggered statement timeouts
    /// (Postgres `57014`) and caused UCL/UFC to load several seconds after
    /// the other sports.
    func syncHistoryFromServer() async {
        guard let token = accessToken, let userID else { return }

        await healPrematurePGASettlements()

        do {
            let serverResults = try await SupabaseService.shared.fetchUserDFSHistory(
                userID: userID, limit: 500, accessToken: token
            )
            if serverResults.isEmpty { return }

            // The tournament-metadata fetch is resilient: if it times out or
            // fails, we still ingest with empty metadata (title/totalEntries
            // fall back to defaults). Previously a failure here threw out of
            // the whole `do` block and discarded the rows we already had.
            let tournaments: [DFSTournamentRecord]
            do {
                tournaments = try await SupabaseService.shared.fetchRecentTournaments(accessToken: token)
            } catch {
                print("[DFS] fetchRecentTournaments failed (\(error.localizedDescription)) — proceeding with empty metadata")
                tournaments = []
            }
            applyServerHistory(serverResults: serverResults, tournaments: tournaments)
        } catch {
            print("[DFS] Failed to sync history from server: \(error.localizedDescription)")
        }
    }

    /// Fetches DFS history ONCE for all provided VMs and dispatches the
    /// per-sport slice to each one in parallel. Replaces the previous
    /// pattern of 10 VMs each making their own pair of fetches, which
    /// flooded Postgres with 20 concurrent queries and produced the
    /// `canceling statement due to statement timeout` chain that left UCL
    /// (and sometimes others) missing from the My Contests pills until a
    /// later retry succeeded.
    ///
    /// The optional `onMergedHistory` closure receives the union of all
    /// VMs' resulting `dfsHistory` after dispatch — used by ContentView to
    /// write the merged blob back to the `@AppStorage("dfs_history_data")`
    /// source of truth. Without that write-back, the @AppStorage stays
    /// stale and any subsequent `.onChange(of: dfsHistoryData)` fan-out
    /// overwrites the freshly-ingested per-VM data with the pre-sync blob.
    @MainActor
    static func syncAllSportsHistoryFromServer(
        vms: [DFSViewModel],
        userID: String,
        accessToken: String,
        onMergedHistory: ((Data) -> Void)? = nil
    ) async {
        // Heals are per-VM and gated by their own UserDefaults version
        // flag — they only do real work once per device. Run in parallel
        // before the shared fetch so any premature settlements are cleared
        // before we re-import server rows.
        await withTaskGroup(of: Void.self) { group in
            for vm in vms where vm.sport == "PGA" {
                group.addTask { @MainActor in
                    await vm.healPrematurePGASettlements()
                }
            }
        }

        let serverResults: [DFSTournamentResultRecord]
        do {
            serverResults = try await SupabaseService.shared.fetchUserDFSHistory(
                userID: userID, limit: 500, accessToken: accessToken
            )
        } catch {
            print("[DFS-SharedSync] fetchUserDFSHistory failed: \(error.localizedDescription)")
            return
        }
        if serverResults.isEmpty {
            print("[DFS-SharedSync] serverResults empty — bailing without wiping local history")
            return
        }

        let tournaments: [DFSTournamentRecord]
        do {
            tournaments = try await SupabaseService.shared.fetchRecentTournaments(accessToken: accessToken)
        } catch {
            print("[DFS-SharedSync] fetchRecentTournaments failed (\(error.localizedDescription)) — proceeding with empty metadata")
            tournaments = []
        }

        // Dispatch the slice to each VM in parallel. No network here —
        // each `applyServerHistory` is a local mutation, so the parallel
        // dispatch only costs CPU and main-actor hops. The unified Net RR
        // delta and My Contests page already merge across VMs via the
        // canonical-owner filter, so no cross-VM propagation is needed.
        await withTaskGroup(of: Void.self) { group in
            for vm in vms {
                group.addTask { @MainActor in
                    vm.applyServerHistory(serverResults: serverResults, tournaments: tournaments)
                }
            }
        }

        // Build the union of every VM's resulting history and hand it back
        // to the caller. ContentView writes this into the @AppStorage
        // source-of-truth so subsequent `.onChange` fan-outs propagate the
        // freshly-synced state instead of clobbering it with the pre-sync
        // blob.
        //
        // Canonical-owner filter: each row is ONLY contributed by the VM
        // whose sport matches the row's tid prefix. Without this, every
        // VM holds a copy of every other sport's rows (they share
        // @AppStorage), and a stale copy in an earlier VM in the array
        // (NBA's copy of UFC, etc.) could win the dedupe over the
        // owner VM's freshly-corrected copy — that's the actual
        // mechanism behind the UFC "reverts to +1000 on every Profile
        // tap" loop the user reported.
        if let onMergedHistory {
            func canonicalSport(for tid: String) -> String? {
                // IMPORTANT: do NOT give wnba- a dedicated owner. Several merge
                // callers pass only the original 10 VMs (no WNBA VM). If wnba-
                // had owner "WNBA", such a merge would match NO VM in its list
                // and DROP every wnba- row — wiping that history on each 10-VM
                // sync. With no case (nil owner), a wnba- row is contributed by
                // whatever VM holds it in the shared blob, so no merge deletes it.
                if tid.hasPrefix("nba-") || tid.hasPrefix("ncaam-") { return "NBA" }
                if tid.hasPrefix("nhl-") { return "NHL" }
                if tid.hasPrefix("mlb-") { return "MLB" }
                if tid.hasPrefix("pga-") { return "PGA" }
                if tid.hasPrefix("epl-") { return "EPL" }
                if tid.hasPrefix("ucl-") { return "UCL" }
                if tid.hasPrefix("wc-")  { return "WC"  }
                if tid.hasPrefix("ufc-") { return "UFC" }
                if tid.hasPrefix("nfl-") { return "NFL" }
                if tid.hasPrefix("cfb-") { return "CFB" }
                return nil
            }
            var byKey: [String: DFSResult] = [:]
            for vm in vms {
                for r in vm.dfsHistory {
                    let tid = r.tournamentId ?? r.id.uuidString
                    // Skip rows this VM doesn't canonically own —
                    // another VM in the array will contribute the
                    // authoritative copy.
                    if let owner = canonicalSport(for: tid), owner != vm.sport {
                        continue
                    }
                    let key = "\(tid)#\(r.lineupNumber ?? 1)"
                    if let existing = byKey[key] {
                        if r.lineupPoints > existing.lineupPoints {
                            byKey[key] = r
                        }
                    } else {
                        byKey[key] = r
                    }
                }
            }
            let merged = byKey.values.sorted { $0.loggedAt > $1.loggedAt }
            let blob = (try? JSONEncoder().encode(Array(merged.prefix(500)))) ?? Data()
            print("[DFS-SharedSync] merged history: \(merged.count) rows across \(vms.count) VMs (canonical-owner filter applied)")
            onMergedHistory(blob)
        }
    }

    /// Synchronous ingest: filters `serverResults` to this VM's sport
    /// prefix, merges with local history, and trims duplicates against the
    /// server's authoritative count. No network — safe to call from the
    /// shared fetch dispatch above.
    func applyServerHistory(
        serverResults: [DFSTournamentResultRecord],
        tournaments: [DFSTournamentRecord]
    ) {
        let isUCLDebug = (sport == "UCL")

        if isUCLDebug {
            print("[UCL-DEBUG] applyServerHistory — \(serverResults.count) total rows, \(tournaments.count) tournament records")
            let uclRows = serverResults.filter { $0.tournamentID.hasPrefix("ucl-") }
            print("[UCL-DEBUG] of which \(uclRows.count) have prefix ucl-")
            for row in uclRows {
                print("[UCL-DEBUG]   tid=\(row.tournamentID) entry=\(row.entryName) pts=\(row.totalPoints) rrDelta=\(row.rrDelta) rank=\(row.rank)")
            }
        }

        // Only import results matching this view model's sport.
        // NBA also handles NCAAM since they share the same DFSViewModel.
        // Each sport view model owns exactly its own tournament-ID prefix.
        // NCAAM and WNBA now have their own view models, so NBA no longer
        // also claims "ncaam-".
        let sportPrefixes: [String] = [sport.lowercased() + "-"]
        // Exclude Fantasy-mode rows that share this table (and, for Playoff
        // Tiers, the `nba-` prefix) so they never enter DFS history/RR.
        let matchesSport: (String) -> Bool = { tid in
            sportPrefixes.contains(where: { tid.hasPrefix($0) }) && !Self.isFantasyModeTid(tid)
        }

        let tournamentMap = Dictionary(tournaments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if isUCLDebug {
                let uclTournaments = tournaments.filter { $0.id.hasPrefix("ucl-") }
                print("[UCL-DEBUG] fetchRecentTournaments returned \(tournaments.count) total, \(uclTournaments.count) with ucl- prefix")
                for t in uclTournaments {
                    print("[UCL-DEBUG]   tournament tid=\(t.id) title=\(t.title) lockTime=\(String(describing: t.lockTime))")
                }
            }

            // Dedupe pre-pass: collapse duplicate user rows for the
            // same (tid, lineup_player_ids) keeping only the row with
            // the LATEST createdAt. Without this, an early-settle bad
            // row (e.g. UFC rank=1, +1000) and a re-settled correct
            // row (rank=965, -10) for the same lineup both survive
            // the fetch — and the loop below ends up adding the second
            // one as a new local entry, summing to ~+990 RR. The
            // ENTRY NAME differs across passes so upsert's
            // on-conflict=tournament_id,entry_name doesn't collapse
            // them server-side. Dedupe here.
            let dedupedServerResults: [DFSTournamentResultRecord] = {
                // Extract the lineup number ("Username #2" → 2; 1–20 only).
                func lineupNumToken(_ name: String) -> String {
                    if let hashRange = name.range(of: "#"),
                       let num = Int(name[hashRange.upperBound...].trimmingCharacters(in: .whitespaces)),
                       num >= 1 && num <= 20 {
                        return String(num)
                    }
                    return ""
                }
                var bestByKey: [String: DFSTournamentResultRecord] = [:]
                for r in serverResults {
                    // Key on tid + playerIDs + LINEUP NUMBER. The lineup number
                    // is essential: two SEPARATE entries of an IDENTICAL lineup
                    // (the user submitted the same players as #1 AND #2) share
                    // tid+playerIDs, so without the number they collapsed to one
                    // — the duplicate lineup then took minutes to reappear once
                    // the slower multi-lineup settle path restored it. A bad+good
                    // re-settle of the SAME lineup keeps the same number, so it
                    // still collapses (the original purpose of this dedup).
                    let lineupKey = "\(r.tournamentID)|\(r.lineupPlayerIDs.joined(separator: ","))|\(lineupNumToken(r.entryName))"
                    if let existing = bestByKey[lineupKey] {
                        let existingDate = existing.createdAt ?? .distantPast
                        let newDate = r.createdAt ?? .distantPast
                        if newDate > existingDate {
                            bestByKey[lineupKey] = r
                        }
                    } else {
                        bestByKey[lineupKey] = r
                    }
                }
                return Array(bestByKey.values)
            }()

            // Group server results by tournament ID to assign lineup numbers
            var serverResultsByTournament: [String: [DFSTournamentResultRecord]] = [:]
            var droppedNoSportMatch = 0
            var droppedZeroPoints = 0
            for result in dedupedServerResults {
                if !matchesSport(result.tournamentID) {
                    droppedNoSportMatch += 1
                    continue
                }
                if result.totalPoints <= 0 {
                    // Keep the current user's zero-point rows — UFC (main
                    // fighter loses), single-game showdowns, and other
                    // low-floor sports can legitimately resolve at 0,
                    // and silently dropping them hides real losses from
                    // Past Results. Bot/other rows at 0 are still skipped
                    // because pre-game or partially-settled leaderboards
                    // produce a lot of them and they'd noise up the merge.
                    if !result.isCurrentUser {
                        if isUCLDebug { print("[UCL-DEBUG] dropping zero-points row tid=\(result.tournamentID) entry=\(result.entryName)") }
                        droppedZeroPoints += 1
                        continue
                    }
                }
                serverResultsByTournament[result.tournamentID, default: []].append(result)
            }

            if isUCLDebug {
                print("[UCL-DEBUG] after filter: \(serverResultsByTournament.count) tournaments survived. Dropped (wrong sport): \(droppedNoSportMatch). Dropped (zero pts): \(droppedZeroPoints)")
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
                if let lockTime = tournament?.lockTime, lockTime > Date() {
                    if isUCLDebug { print("[UCL-DEBUG] skipping tid=\(tournamentID) — lockTime \(lockTime) is still in the future") }
                    continue
                }

                // (Was: 72h PGA import guard — removed.) The guard prevented
                // re-importing a still-live PGA tournament's server-side
                // settlement, which made sense in principle but caused a
                // catastrophic side effect: once `healPrematurePGASettlements`
                // un-settled a prematurely-settled tournament locally, the
                // import guard refused to re-pull anything from the server
                // for the next 3 days, leaving the lobby unable to render
                // the 2000-entry contest (bots/field couldn't be loaded
                // for an unsettled-but-not-live-renderable state). The
                // base-event-ID fix in `PGA-SelfHeal` prevents NEW buggy
                // settlements from being produced; for the legacy Memorial
                // case we accept that the server's pre-fix settled state
                // re-imports here. The data will self-correct when the
                // tournament actually completes Sunday and a proper settle
                // overwrites it.
                
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
                        // Already in local history — only update non-RR
                        // metadata (title, points-when-stale, totalEntries).
                        // NEVER overwrite local rank/rrDelta from
                        // server here.
                        //
                        // The Profile tab fires syncAllSportsHistoryFromServer
                        // every time it's selected. The server can be holding
                        // a stale row (e.g. an early "rank=1, +1000" written
                        // before bots loaded) that hasn't yet been corrected
                        // by loadPastTournamentStandings. Letting this sync
                        // overwrite a locally-good rank with a server-stale
                        // one produces the "Profile tab reverts UFC back to
                        // +1000" loop the user kept reporting.
                        //
                        // Correction paths for genuinely stale LOCAL rows:
                        //   • loadPastTournamentStandings (when user views the
                        //     contest standings) writes the correct rank/RR
                        //     back to both local and server.
                        //   • checkAndSettleUnsettledTournaments recompute
                        //     path repairs both sides on the settlement timer.
                        // Both pipelines compute rank from the sorted
                        // leaderboard, which is the source of truth.
                        let existing = localHistory[existingIndex]
                        let needsPointsUpdate = result.totalPoints > existing.lineupPoints || existing.lineupPoints == 0
                        let needsTitleRefresh = existing.tournamentTitle != title && title != "Tournament"
                        let needsEntriesFix = totalEntries > 0
                            && existing.totalEntries < totalEntries
                        if needsPointsUpdate || needsTitleRefresh || needsEntriesFix {
                            localHistory[existingIndex] = DFSResult(
                                id: existing.id,
                                tournamentTitle: needsTitleRefresh ? title : existing.tournamentTitle,
                                rank: existing.rank,
                                totalEntries: needsEntriesFix ? totalEntries : existing.totalEntries,
                                lineupPoints: needsPointsUpdate ? result.totalPoints : existing.lineupPoints,
                                rrDelta: existing.rrDelta,
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

            // Cleanup pass: trim local history rows that exceed the server's
            // authoritative count for each tournament. The pre-fix concurrent-
            // settlement race left some tournaments with extra rows under
            // derived lineupNumbers (e.g. NYM @ SEA showing #1, #2, #3, #4
            // when the user only ever submitted 2 lineups). Keep the lowest
            // lineupNumber rows up to server count, drop the rest.
            //
            // Trim against the FULL serverResults (not just this VM's sport
            // prefix) — `dfsHistoryData` is shared across all sport VMs, so
            // whichever VM happens to be syncing should clean up duplicates
            // for every sport in one pass. Otherwise MLB dupes never got
            // touched when NBA's sync was the only one to ever trim.
            var serverCountByTID: [String: Int] = [:]
            for result in serverResults {
                guard result.totalPoints > 0 else { continue }
                serverCountByTID[result.tournamentID, default: 0] += 1
            }
            var didTrim = false
            var pruned = dfsHistory
            for (tournamentID, serverCount) in serverCountByTID {
                let localForTID = pruned.filter { $0.tournamentId == tournamentID }
                if localForTID.count > serverCount, serverCount > 0 {
                    // Sort ascending by lineupNumber (nil last) and keep first N
                    let sorted = localForTID.sorted { a, b in
                        let an = a.lineupNumber ?? Int.max
                        let bn = b.lineupNumber ?? Int.max
                        return an < bn
                    }
                    let keepIDs = Set(sorted.prefix(serverCount).map(\.id))
                    pruned.removeAll { r in
                        r.tournamentId == tournamentID && !keepIDs.contains(r.id)
                    }
                    didTrim = true
                    print("[DFS] Trimmed \(tournamentID): \(localForTID.count) local rows → \(serverCount) (matched server count)")
                }
            }
            if didTrim {
                dfsHistoryData = encodedDFSHistory(pruned)
            }

            // Orphan-prune pass: remove local rows for THIS sport whose
            // tournament has ZERO server-side results AND the row was
            // logged within the last 24h. This catches phantom rows that
            // got written by buggy lobby-open settlement paths (now patched)
            // and survived a server-side `dfs_tournament_results` DELETE
            // because @AppStorage outlives a force-quit relaunch.
            //
            // Scoped narrowly to:
            //   - This VM's sport prefix (so MLB phantoms don't get nuked
            //     during an NBA sync that didn't fetch MLB results).
            //   - Tournaments with NO server rows at all (if even 1 server
            //     row exists for the tid, the existing trim pass above
            //     handles it).
            //   - loggedAt within last 24h (older rows may legitimately be
            //     missing from the server's 500-row cap — keep them).
            //
            // When we prune a row, also DEDUCT its `rrDelta` from `rrScore` so
            // the home-screen accumulator stays in sync with what My Contests
            // shows. Without this, the user sees the home screen DFS total
            // higher than the sum of visible contest cards (the phantom RR
            // was previously added but never refunded).
            let serverTIDsForSport = Set(
                serverResults.filter { matchesSport($0.tournamentID) }.map { $0.tournamentID }
            )
            let oneDayAgo = Date().addingTimeInterval(-24 * 3600)
            var localBeforePrune = dfsHistory
            let countBefore = localBeforePrune.count
            var refundedRR = 0
            localBeforePrune.removeAll { row in
                guard let tid = row.tournamentId, matchesSport(tid) else { return false }
                guard row.loggedAt > oneDayAgo else { return false }
                guard !serverTIDsForSport.contains(tid) else { return false }
                // A SETTLED contest is never a phantom. Its server results may
                // simply be absent from THIS fetch (the history query is recency/
                // count-limited, so older PGA events like RBC/Memorial fall out)
                // — pruning it here refunds real RR and is exactly what made the
                // DFS total drop from 399 back to 374 every launch, then climb
                // again when My Contests re-imported the rows.
                guard !settledTournaments.contains(tid) else { return false }
                refundedRR += row.rrDelta
                return true
            }
            if localBeforePrune.count != countBefore {
                let removed = countBefore - localBeforePrune.count
                print("[DFS-\(sport)] Orphan-pruned \(removed) local history rows, refunded \(refundedRR) RR")
                dfsHistoryData = encodedDFSHistory(localBeforePrune)
                if refundedRR != 0 {
                    rrScore -= refundedRR
                }
            }

            // Restore latestResult for the current tournament from history so the
            // active-contest card shows the correct rank/score immediately
            if latestResult == nil, let tid = tournament?.id,
               let historyMatch = dfsHistory.first(where: { $0.tournamentId == tid }) {
                latestResult = historyMatch
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
                // Tournament is locked — record the canonical for THIS
                // tournament so applyCanonicalSalaries can overlay it on
                // the active pool when this tid is selected.
                //
                // DO NOT mutate `players` or `singleGamePlayers` globally
                // here. They're shared across every tournament for the slate
                // (e.g. H2H, 5-Man, 2000-person, evening — all read from
                // the same `singleGamePlayers[gameID]`). Mutating them
                // means joining ONE locked sibling re-prices the entire
                // pool for the others — and worse, `storedSalaries` written
                // post-submission is already in SG dollars for SG tournaments,
                // so the old `singleGameSalary()` conversion double-converted
                // and produced ceiling/garbage prices.
                tournamentPlayerSalaries[tournament.id] = storedSalaries
                let record = DFSTournamentRecord(
                    id: tournament.id, title: tournament.title, league: tournament.league,
                    lockTime: lockTime, playerSalaries: storedSalaries,
                    isSingleGame: tournament.isSingleGame
                )
                try await SupabaseService.shared.upsertTournament(record: record, accessToken: token)
            } else {
                // Tournament is still open — sync metadata only (lockTime).
                // DO NOT write playerSalaries here. This path runs every time
                // anyone opens the lobby, often BEFORE the RotoGrinders slate
                // has loaded, which means we'd persist bad fallback prices
                // (e.g. Wemby at the SG $16K ceiling, Towns at $13.4K) as
                // canonical. Later, when the user actually submitted with the
                // real RG prices, the existing-snapshot guard would refuse to
                // overwrite — and the leaderboard would display bot rows at
                // the bogus prices forever. Canonical salaries are owned by
                // the submission path (`submitLineup`), which writes the full
                // 25-player slate the user actually saw at draft time.
                let record = DFSTournamentRecord(
                    id: tournament.id, title: tournament.title, league: tournament.league,
                    lockTime: lockTime, playerSalaries: nil,
                    isSingleGame: tournament.isSingleGame
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
        // Capture which tournament we started this refresh for. If the user
        // navigates to a different contest while the network call is in flight,
        // the late-arriving result must NOT clobber the new tournament's state
        // (selectedPlayerIDs, fieldEntries) — otherwise the wrong tournament's
        // lineup flashes on screen.
        let startedForTournament = tournament.id
        let startedForLineupNumber = activeLineupNumber
        do {
            let entries = try await SupabaseService.shared.fetchEntries(tournamentID: startedForTournament, accessToken: token)
            // Bail if the user switched tournaments while we were waiting.
            guard activeTournamentID == startedForTournament,
                  activeLineupNumber == startedForLineupNumber else {
                print("[DFS-\(sport)] refreshRemoteEntries: stale result for \(startedForTournament) (active now \(activeTournamentID ?? "nil")) — discarding")
                return
            }
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
                // Fallback: if remote entries were empty but we have a cached entry, include the user.
                // CRITICAL: only fall back when the user actually entered this tournament
                // (it must be in `enteredTournamentIDs`). Otherwise — e.g. when the user
                // navigates into a tournament they never submitted to but `userEntryRecords`
                // has stale data from a private-contest interaction — we'd inject a phantom
                // entry that then renders as a ghost "Heads Up" active-contest card.
                if (fieldEntries.isEmpty || !fieldEntries.contains(where: { $0.isCurrentUser })),
                   enteredTournamentIDs.contains(tournament.id),
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
                } else if enteredTournamentIDs.contains(tournament.id),
                          let cachedEntry = entryRecord(for: tournament.id, lineupNumber: activeLineupNumber) {
                    // Fallback: inject from cached records — ONLY when the
                    // user has actually entered this tournament. See above
                    // for the phantom-card explanation.
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
                            // Don't add a restored stub to the BROWSE pool when a
                            // real player with the same name is already in the
                            // field — the old DK-fallback IDs ("pga-dk-wyndham-
                            // clark") would otherwise show as a duplicate row
                            // next to the real golfer. The lineup strip still
                            // renders the saved entry via `selectedPlayers`'
                            // missing-ID stubs.
                            let poolNames = Set(players.map { RotoGrindersSalaryProvider.normalizeName($0.name) })
                            for await player in group {
                                let normalized = RotoGrindersSalaryProvider.normalizeName(player.name)
                                if poolNames.contains(normalized) {
                                    print("[DFS-PGA] Skipping restored stub \(player.id) (\(player.name)) — same-name golfer already in pool")
                                    continue
                                }
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
                                // Guard against re-adding an id already in the pool
                                // (e.g. an MLB two-way "-sp" entry across refresh
                                // cycles) — a duplicate id later crashes
                                // Dictionary(uniqueKeysWithValues:) in refreshLive.
                                guard !players.contains(where: { $0.id == player.id }) else { continue }
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
                        // Don't introduce a duplicate id into the pool (see above).
                        guard !players.contains(where: { $0.id == player.id }) else { continue }
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
        else if pid.hasPrefix("epl-") || pid.hasPrefix("ucl-") || pid.hasPrefix("wc-") { minSalary = 3500 }
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

        // DK-fallback IDs ("dk-wyndham-clark") aren't ESPN athlete IDs — the
        // lookups below can never resolve them, and the old "Golfer #dk-..."
        // fallback name leaked into the player list. Reconstruct the display
        // name straight from the slug.
        if rawID.hasPrefix("dk-") {
            let pretty = rawID.dropFirst(3)
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return DFSPlayer(id: pid, name: fallbackName ?? pretty, team: "", position: "G",
                             salary: salary, projectedPoints: Double(salary) / 1000.0, gameID: gameID)
        }

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

    // MARK: - Private Contests

    /// Generate a 6-character invite code (excludes ambiguous chars: 0/O, 1/I/L).
    private func generatePrivateContestInviteCode() -> String {
        let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    private static func privateContestsCacheKey(for userID: String) -> String {
        "dfs_my_private_contests_\(userID)"
    }

    /// Restore the cached private-contest list so the Active Contests view can
    /// render the correct number of cards (in shimmer) immediately, instead of
    /// the list popping from N→N+1 once the network fetch returns.
    func loadCachedPrivateContests() {
        guard let uid = userID, !uid.isEmpty else { return }
        let data = FileBlobStore.shared.load(key: Self.privateContestsCacheKey(for: uid))
        guard !data.isEmpty,
              let cached = try? JSONDecoder().decode([DFSPrivateContest].self, from: data) else { return }
        if myPrivateContests.isEmpty {
            myPrivateContests = cached
        }
    }

    private func persistPrivateContestsCache() {
        guard let uid = userID, !uid.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(myPrivateContests) else { return }
        // On disk, not UserDefaults — avoids the 4MB CFPreferences ceiling.
        FileBlobStore.shared.save(key: Self.privateContestsCacheKey(for: uid), data: data)
    }

    func loadMyPrivateContests() async {
        // Restore from cache first so the Active Contests view can immediately
        // render the right number of shimmer placeholders. The network fetch
        // below replaces this with the authoritative list.
        loadCachedPrivateContests()
        guard let token = accessToken, let uid = userID else { return }
        do {
            let records = try await SupabaseService.shared.fetchMyDFSPrivateContests(userID: uid, accessToken: token)
            myPrivateContests = records.map { $0.toModel() }
            persistPrivateContestsCache()
        } catch {
            print("[DFS-Private] Failed to load contests: \(error)")
        }
        // Eagerly fetch each private contest's entries + members in parallel so
        // the Active Contests card can render real data (not just a populated
        // contest list with empty FPTS/rank). Without this, the private card
        // pops in immediately with 0.0 while the public cards still shimmer.
        await withTaskGroup(of: Void.self) { group in
            for contest in myPrivateContests {
                group.addTask { [weak self] in
                    await self?.loadPrivateContestMembers(contestID: contest.id)
                }
                group.addTask { [weak self] in
                    await self?.loadPrivateContestEntries(contestID: contest.id)
                }
            }
        }
    }

    /// Whether a private contest's data is loaded enough to render its Active
    /// Contests card without placeholder values. Used to gate the card behind
    /// the same shimmer state the public cards use.
    func isPrivateContestReady(_ contestID: UUID) -> Bool {
        privateContestEntries[contestID] != nil && privateContestMembers[contestID] != nil
    }

    /// Fetches the parent tournament record from Supabase and populates the
    /// canonical salary snapshot for it. Needed when viewing a past private
    /// contest whose parent slate is no longer in the in-memory tournaments
    /// array — otherwise the roster sheet shows drifted salaries instead of
    /// the frozen prices used when the lineup was submitted.
    func loadParentTournamentSalariesIfNeeded(parentTournamentID: String) async {
        guard tournamentPlayerSalaries[parentTournamentID]?.isEmpty != false else { return }
        guard let token = accessToken else { return }
        guard let record = try? await SupabaseService.shared.fetchTournament(
            tournamentID: parentTournamentID, accessToken: token
        ) else { return }
        if let sals = record.playerSalaries, !sals.isEmpty {
            tournamentPlayerSalaries[parentTournamentID] = sals
        }
    }

    /// Final FPTS per private contest, keyed by contest ID. Computed by
    /// fetching the parent slate's box scores and summing the user's entry's
    /// player points. Populates the My Contests / Recent Results rows with
    /// real scores — without this, the rows show `entry.lineupTotalPoints`
    /// which is 0 (set at submit time before games started).
    var privateContestFinalScores: [UUID: Double] = [:]

    /// Computes and caches the current user's final FPTS for a settled
    /// private contest. Runs sequentially per call because the global
    /// `pastTournamentPlayerStats` dict gets replaced on each box-score
    /// fetch; serializing avoids cross-tournament data being overwritten
    /// before this call finishes summing.
    func ensureFinalScoreForPrivateContest(_ contest: DFSPrivateContest) async {
        guard privateContestFinalScores[contest.id] == nil else { return }
        let entries = privateContestEntries[contest.id] ?? []
        guard let me = userID.flatMap(UUID.init(uuidString:)),
              let entry = entries.first(where: { $0.userID == me }),
              !entry.lineupPlayerIDs.isEmpty else { return }
        // Already-cached stored value is good enough if non-zero
        if entry.lineupTotalPoints > 0 {
            privateContestFinalScores[contest.id] = entry.lineupTotalPoints
            return
        }
        await loadPastTournamentBoxScores(tournamentId: contest.parentTournamentID)
        let isSG = contest.parentTournamentID.contains("-sg-")
        var total = 0.0
        for (idx, pid) in entry.lineupPlayerIDs.enumerated() {
            let pts = pastTournamentPlayerStats[pid]?.fantasyPoints ?? 0
            total += (isSG && idx == 0) ? pts * 1.5 : pts
        }
        privateContestFinalScores[contest.id] = total
    }

    /// Loads final scores for every past private contest the user has been
    /// in. Serialized to avoid the box-score state being overwritten between
    /// fetch and compute. `ensureFinalScoreForPrivateContest` needs
    /// `privateContestEntries[contest.id]` populated — we pre-load entries
    /// (NOT the full leaderboard) here. Loading the leaderboard first would
    /// cache rows with 0 points because past-stats haven't been loaded yet,
    /// and that 0 would then beat the correct value in the row display.
    /// Entries-only is also dramatically cheaper than computing a full
    /// leaderboard for every past contest.
    func loadAllPrivateContestFinalScores() async {
        for contest in myPrivateContests {
            guard !privateContestBelongsToCurrentSlate(contest) else { continue }
            if (privateContestEntries[contest.id] ?? []).isEmpty {
                await loadPrivateContestEntries(contestID: contest.id)
            }
            await ensureFinalScoreForPrivateContest(contest)
        }
    }

    /// The 8-char "YYYYMMDD" date string for the current slate, derived from
    /// the first loaded tournament ID. Private contests should only appear
    /// alongside their own day's slate — yesterday's contest must not show up
    /// next to tomorrow's games.
    var currentSlateDateString: String? {
        for t in tournaments {
            let parts = t.id.split(separator: "-")
            if let dateLike = parts.first(where: { $0.count == 8 && Int($0) != nil }) {
                return String(dateLike)
            }
        }
        return nil
    }

    /// Whether the scores currently in `livePlayerPoints` were fetched for the
    /// same slate as the given parent tournament ID. Guards against showing a
    /// prior slate's points (player IDs are stable across days) in private
    /// contest standings.
    func livePointsBelongToSlate(ofParentTournamentID parentID: String) -> Bool {
        guard let prefix = livePlayerPointsSlatePrefix else { return false }
        return prefix == sportDatePrefix(from: parentID)
    }

    /// Whether a private contest belongs to the currently-displayed slate (by
    /// matching the YYYYMMDD date embedded in the parent tournament ID).
    func privateContestBelongsToCurrentSlate(_ contest: DFSPrivateContest) -> Bool {
        guard let today = currentSlateDateString else { return true } // can't determine — don't hide
        let parts = contest.parentTournamentID.split(separator: "-")
        guard let contestDate = parts.first(where: { $0.count == 8 && Int($0) != nil }) else { return true }
        return String(contestDate) == today
    }

    func createPrivateContest(parentTournamentID: String, name: String, maxMembers: Int = 20) async -> DFSPrivateContest? {
        guard let token = accessToken, let uid = userID else {
            privateContestError = "Please sign in to create a contest."
            return nil
        }
        isCreatingPrivateContest = true
        privateContestError = nil

        do {
            // Ensure the parent tournament row exists in Supabase — public tournaments
            // are only persisted on first lineup submission, so referencing one as a
            // foreign key requires a pre-upsert.
            if let parent = tournaments.first(where: { $0.id == parentTournamentID }) {
                let lockTime = lockTimeForTournament(parent)
                let parentRecord = DFSTournamentRecord(
                    id: parent.id,
                    title: parent.title,
                    league: parent.league,
                    lockTime: lockTime
                )
                try await SupabaseService.shared.upsertTournament(record: parentRecord, accessToken: token)
            } else {
                privateContestError = "Parent slate not found. Try refreshing the lobby."
                isCreatingPrivateContest = false
                return nil
            }

            let code = generatePrivateContestInviteCode()
            let record = try await SupabaseService.shared.createDFSPrivateContest(
                parentTournamentID: parentTournamentID,
                name: name,
                createdBy: uid,
                inviteCode: code,
                maxMembers: maxMembers,
                accessToken: token
            )
            let contest = record.toModel()
            let displayName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.joinDFSPrivateContest(
                contestID: record.id, userID: uid, displayName: displayName, accessToken: token
            )
            myPrivateContests.insert(contest, at: 0)
            isCreatingPrivateContest = false
            return contest
        } catch {
            privateContestError = "Failed to create contest: \(error.localizedDescription)"
            print("[DFS-Private] Create error: \(error)")
            isCreatingPrivateContest = false
            return nil
        }
    }

    func joinPrivateContestByCode(_ code: String) async -> DFSPrivateContest? {
        guard let token = accessToken, let uid = userID else {
            privateContestError = "Please sign in to join a contest."
            return nil
        }
        isJoiningPrivateContest = true
        privateContestError = nil
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            privateContestError = "Enter an invite code."
            isJoiningPrivateContest = false
            return nil
        }
        do {
            guard let record = try await SupabaseService.shared.fetchDFSPrivateContestByInviteCode(code: normalized, accessToken: token) else {
                privateContestError = "No contest found for that code."
                isJoiningPrivateContest = false
                return nil
            }
            let displayName = profileName.isEmpty ? "Player" : profileName
            try await SupabaseService.shared.joinDFSPrivateContest(
                contestID: record.id, userID: uid, displayName: displayName, accessToken: token
            )
            let contest = record.toModel()
            if !myPrivateContests.contains(where: { $0.id == contest.id }) {
                myPrivateContests.insert(contest, at: 0)
            }
            isJoiningPrivateContest = false
            return contest
        } catch {
            privateContestError = "Failed to join: \(error.localizedDescription)"
            print("[DFS-Private] Join error: \(error)")
            isJoiningPrivateContest = false
            return nil
        }
    }

    func loadPrivateContestMembers(contestID: UUID) async {
        guard let token = accessToken else { return }
        do {
            let records = try await SupabaseService.shared.fetchDFSPrivateContestMembers(
                contestID: contestID.uuidString.lowercased(), accessToken: token
            )
            privateContestMembers[contestID] = records.map { $0.toModel() }
        } catch {
            print("[DFS-Private] Failed to load members: \(error)")
        }
    }

    /// Opens the lineup builder for a private contest. Loads the parent slate
    /// (player pool, lock time) then marks the builder as routing submissions
    /// to the private contest entries table.
    func startPrivateContestLineup(_ contest: DFSPrivateContest) {
        selectTournament(contest.parentTournamentID)
        activePrivateContest = contest
        editingLineupNumber = nil

        // Pre-fill ONLY from the user's existing private-contest entry. If
        // they haven't submitted to this private contest yet, the builder
        // must start blank — not inherit the public-contest lineup that
        // `selectTournament` may have loaded from the parent tournament.
        // (Public entries to the parent slate are unrelated to this private
        // contest; reusing them silently was confusing — see the phantom
        // H2H bug where public-contest state leaked into private-contest
        // flows and back out into the active-contests list.)
        let myPrivateEntry: DFSPrivateContestEntry? = userID
            .flatMap(UUID.init(uuidString:))
            .flatMap { myUUID in
                (privateContestEntries[contest.id] ?? []).first(where: { $0.userID == myUUID })
            }

        if let entry = myPrivateEntry, !entry.lineupPlayerIDs.isEmpty {
            // Edit mode — user already submitted to THIS private contest.
            selectedPlayerIDs = Set(entry.lineupPlayerIDs)
            let isSG = tournaments.first(where: { $0.id == contest.parentTournamentID })?.isSingleGame
                ?? contest.parentTournamentID.contains("-sg-")
            if isSG, let firstID = entry.lineupPlayerIDs.first {
                mvpPlayerID = firstID
            } else {
                mvpPlayerID = nil
            }
        } else {
            // First-time entry — clear whatever `selectTournament` loaded
            // so the builder is empty.
            selectedPlayerIDs = []
            mvpPlayerID = nil
        }
        showLineupBuilder = true
    }

    func loadPrivateContestEntries(contestID: UUID) async {
        guard let token = accessToken else { return }
        do {
            let records = try await SupabaseService.shared.fetchDFSPrivateContestEntries(
                contestID: contestID.uuidString.lowercased(), accessToken: token
            )
            privateContestEntries[contestID] = records.map { $0.toModel() }
        } catch {
            print("[DFS-Private] Failed to load entries: \(error)")
        }
    }

    /// Submits the lineup currently in the builder to the active private contest.
    /// The score is computed against the parent slate's current live points
    /// (will be 0 pre-lock; refreshes on live data updates).
    func submitActivePrivateContestLineup() async -> Bool {
        guard let contest = activePrivateContest,
              let token = accessToken,
              let uid = userID else { return false }
        let lineupIDs = selectedPlayers.map { $0.id }
        guard !lineupIDs.isEmpty else { return false }

        // Compute current points using livePlayerPoints (will be 0 pre-game).
        let parentTournament = tournaments.first(where: { $0.id == contest.parentTournamentID })
        let isSG = parentTournament?.isSingleGame ?? false
        var totalPoints = 0.0
        for (i, pid) in lineupIDs.enumerated() {
            let pts = livePlayerPoints[pid] ?? 0
            totalPoints += (isSG && i == 0) ? pts * 1.5 : pts
        }
        let name = profileName.isEmpty ? "Player" : profileName

        do {
            try await SupabaseService.shared.submitDFSPrivateContestEntry(
                contestID: contest.id.uuidString.lowercased(),
                userID: uid,
                displayName: name,
                lineupPlayerIDs: lineupIDs,
                lineupTotalPoints: totalPoints,
                accessToken: token
            )
            await loadPrivateContestEntries(contestID: contest.id)
            await loadPrivateContestLeaderboard(contest)
            return true
        } catch {
            privateContestError = "Failed to submit lineup: \(error.localizedDescription)"
            print("[DFS-Private] Submit entry error: \(error)")
            return false
        }
    }

    /// Builds the private contest leaderboard from its own entries (not public
    /// dfs_entries). Members appear with hasSubmitted=false until they enter
    /// a lineup. Live scoring is applied when the parent slate is the currently
    /// selected tournament; otherwise stored lineup_total_points is used.
    func loadPrivateContestLeaderboard(_ contest: DFSPrivateContest) async {
        if privateContestMembers[contest.id] == nil {
            await loadPrivateContestMembers(contestID: contest.id)
        }
        if privateContestEntries[contest.id] == nil {
            await loadPrivateContestEntries(contestID: contest.id)
        }
        guard let members = privateContestMembers[contest.id] else { return }
        let entries = privateContestEntries[contest.id] ?? []

        let entryByUser: [UUID: DFSPrivateContestEntry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.userID, $0) })
        let parentTournament = tournaments.first(where: { $0.id == contest.parentTournamentID })
        let isSG = parentTournament?.isSingleGame ?? contest.parentTournamentID.contains("-sg-")
        let currentUID = userID?.lowercased() ?? ""
        // Past contest = parent slate isn't today's. For these we score using
        // the loaded box scores (`pastTournamentPlayerStats`) — `livePlayerPoints`
        // only covers today's slate, so without this past contest standings
        // show 0.0 FPTS forever.
        let isPastContest = !privateContestBelongsToCurrentSlate(contest)
        // No scores before the parent slate locks: player IDs are stable
        // across days, so pre-lock `livePlayerPoints` can still hold a PRIOR
        // slate's scores (whatever tournament last ran refreshLive) and the
        // standings would show yesterday's points for games that haven't
        // started. The slate-prefix check rejects that leftover data; the
        // lock check keeps everything at 0.0 until games can actually score.
        let parentLocked: Bool = {
            guard let parentTournament else { return true } // parent rotated out → old slate
            return Date() >= lockTimeForTournament(parentTournament)
        }()
        if !isPastContest && parentLocked && !slateGames.isEmpty
            && !livePointsBelongToSlate(ofParentTournamentID: contest.parentTournamentID) {
            // The loaded live data is for a different slate (or missing) —
            // fetch a fresh snapshot so private-only users still get live
            // scores without having opened a public contest first.
            if let snap = try? await scoringProvider.fetchScoreSnapshot(for: slateGames),
               !snap.playerFantasyPoints.isEmpty {
                livePlayerPoints = snap.playerFantasyPoints
                livePlayerStats = snap.playerLiveStats
                liveGameInfo = snap.gameLiveInfo
                livePlayerPointsSlatePrefix = sportDatePrefix(from: contest.parentTournamentID)
            }
        }
        let useLive = !isPastContest && parentLocked && !livePlayerPoints.isEmpty
            && livePointsBelongToSlate(ofParentTournamentID: contest.parentTournamentID)
        let usePastStats = isPastContest && !pastTournamentPlayerStats.isEmpty

        var rows: [DFSPrivateContestLeaderboardRow] = members.map { member in
            let isMe = member.userID.uuidString.lowercased() == currentUID
            guard let entry = entryByUser[member.userID] else {
                return DFSPrivateContestLeaderboardRow(
                    id: member.userID,
                    displayName: member.displayName,
                    lineupPlayerIDs: [],
                    points: 0, rank: 0,
                    isCurrentUser: isMe, hasSubmitted: false
                )
            }
            let pts: Double = {
                if useLive {
                    var total = 0.0
                    for (i, pid) in entry.lineupPlayerIDs.enumerated() {
                        let p = livePlayerPoints[pid] ?? 0
                        total += (isSG && i == 0) ? p * 1.5 : p
                    }
                    return total
                }
                if usePastStats {
                    var total = 0.0
                    for (i, pid) in entry.lineupPlayerIDs.enumerated() {
                        let p = pastTournamentPlayerStats[pid]?.fantasyPoints ?? 0
                        total += (isSG && i == 0) ? p * 1.5 : p
                    }
                    return total
                }
                return entry.lineupTotalPoints
            }()
            return DFSPrivateContestLeaderboardRow(
                id: member.userID,
                displayName: entry.displayName,
                lineupPlayerIDs: entry.lineupPlayerIDs,
                points: pts, rank: 0,
                isCurrentUser: isMe, hasSubmitted: true
            )
        }

        // Sort: submitted by points desc, unsubmitted at bottom
        rows.sort { lhs, rhs in
            if lhs.hasSubmitted != rhs.hasSubmitted { return lhs.hasSubmitted }
            return lhs.points > rhs.points
        }

        // Standard competition ranking on submitted entries
        var ranked: [DFSPrivateContestLeaderboardRow] = []
        var currentRank = 0
        var prevPoints: Double? = nil
        for (idx, row) in rows.enumerated() {
            guard row.hasSubmitted else { ranked.append(row); continue }
            let rank: Int
            if let p = prevPoints, abs(p - row.points) < 0.001 {
                rank = currentRank
            } else {
                rank = idx + 1
                currentRank = rank
                prevPoints = row.points
            }
            ranked.append(DFSPrivateContestLeaderboardRow(
                id: row.id, displayName: row.displayName,
                lineupPlayerIDs: row.lineupPlayerIDs,
                points: row.points, rank: rank,
                isCurrentUser: row.isCurrentUser, hasSubmitted: row.hasSubmitted
            ))
        }

        privateContestLeaderboards[contest.id] = ranked
    }

    func leavePrivateContest(_ contest: DFSPrivateContest) async {
        guard let token = accessToken, let uid = userID else { return }
        do {
            try await SupabaseService.shared.leaveDFSPrivateContest(
                contestID: contest.id.uuidString.lowercased(), userID: uid, accessToken: token
            )
            myPrivateContests.removeAll { $0.id == contest.id }
            privateContestMembers.removeValue(forKey: contest.id)
            privateContestEntries.removeValue(forKey: contest.id)
            privateContestLeaderboards.removeValue(forKey: contest.id)
        } catch {
            print("[DFS-Private] Leave error: \(error)")
        }
    }

    func deletePrivateContest(_ contest: DFSPrivateContest) async {
        guard let token = accessToken else { return }
        do {
            try await SupabaseService.shared.deleteDFSPrivateContest(
                contestID: contest.id.uuidString.lowercased(), accessToken: token
            )
            myPrivateContests.removeAll { $0.id == contest.id }
            privateContestMembers.removeValue(forKey: contest.id)
            privateContestEntries.removeValue(forKey: contest.id)
            privateContestLeaderboards.removeValue(forKey: contest.id)
        } catch {
            print("[DFS-Private] Delete error: \(error)")
        }
    }
}
