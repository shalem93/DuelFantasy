import Foundation

enum DFSTournamentType: String, Codable, Equatable {
    case main = "main"
    case singleGame = "sg"
    case evening = "eve"

    /// Derive the tournament type from a tournament ID string.
    /// IDs follow the pattern: "sport-date[-suffix]" where suffix indicates type.
    static func from(tournamentID: String) -> DFSTournamentType {
        if tournamentID.contains("-sg-") { return .singleGame }
        if tournamentID.contains("-eve") { return .evening }
        return .main
    }

    /// Whether this is an evening-slate tournament type.
    var isEvening: Bool { self == .evening }

    /// Whether this is a main-slate (all-day or evening) multi-game tournament.
    var isMainSlateFormat: Bool { self != .singleGame }
}

struct DFSTournament: Equatable {
    let id: String
    let title: String
    let league: String
    let entryCount: Int
    let lineupSize: Int
    let salaryCap: Int
    /// Named roster slots (e.g. ["SP","C","1B","2B","3B","SS","OF","OF","OF"] for MLB).
    /// When nil, the lineup builder uses generic numbered slots.
    let rosterSlots: [String]?
    /// True when the slate has only 1 game — uses FanDuel Single Game format
    /// (MVP + 5 FLEX, $60K cap, MVP costs 1.5x salary and scores 1.5x points).
    let isSingleGame: Bool
    /// The type of tournament (main, single-game, 10-man, 5-man WTA, 3-man H2H)
    let tournamentType: DFSTournamentType
    /// ESPN event ID for single-game tournaments (nil for main-slate tournaments)
    let gameID: String?
    /// Entry fee in RR points
    let entryFee: Int

    init(id: String, title: String, league: String, entryCount: Int, lineupSize: Int, salaryCap: Int, rosterSlots: [String]? = nil, isSingleGame: Bool = false, tournamentType: DFSTournamentType = .main, gameID: String? = nil, entryFee: Int = 10) {
        self.id = id
        self.title = title
        self.league = league
        self.entryCount = entryCount
        self.lineupSize = lineupSize
        self.salaryCap = salaryCap
        self.rosterSlots = rosterSlots
        self.isSingleGame = isSingleGame
        self.tournamentType = tournamentType
        self.gameID = gameID
        self.entryFee = entryFee
    }
}

struct DFSPlayer: Identifiable, Hashable {
    let id: String
    let name: String
    let team: String
    let position: String
    let salary: Int
    let projectedPoints: Double
    var gameID: String?         // event ID for looking up live game status
    var injuryStatus: String?   // "O" (Out), "GTD" (Game Time Decision), "Q" (Questionable), "D" (Doubtful)
    var battingOrder: Int?      // MLB batting order position (1-9), nil if not in starting lineup
    var isConfirmedActive: Bool = true  // true if confirmed in tonight's player pool (e.g. matched by RotoGrinders salary data)
    var gamesPlayed: Int?       // season games played (NHL: used to filter low-activity players)
    var playedRecently: Bool = true     // NHL: true if player appeared in their team's most recent game(s)
    var isStartingGoalie: Bool = false  // NHL: confirmed starting goalie from ESPN probables
}

struct DFSSlate {
    let tournaments: [DFSTournament]
    let includedGames: [DFSSlateGame]
    let players: [DFSPlayer]
    /// Per-game player pools with adjusted single-game salaries, keyed by ESPN event ID
    let singleGamePlayers: [String: [DFSPlayer]]

    /// Convenience: the first (main) tournament, for backward compatibility
    var tournament: DFSTournament { tournaments.first! }

    /// Legacy init for backward compatibility — wraps a single tournament
    init(tournament: DFSTournament, includedGames: [DFSSlateGame], players: [DFSPlayer]) {
        self.tournaments = [tournament]
        self.includedGames = includedGames
        self.players = players
        self.singleGamePlayers = [:]
    }

    init(tournaments: [DFSTournament], includedGames: [DFSSlateGame], players: [DFSPlayer], singleGamePlayers: [String: [DFSPlayer]] = [:]) {
        self.tournaments = tournaments
        self.includedGames = includedGames
        self.players = players
        self.singleGamePlayers = singleGamePlayers
    }
}

struct DFSSlateGame: Identifiable, Hashable, Sendable {
    let id: String
    let awayTeam: String
    let homeTeam: String
    let startTime: Date
    var state: String = "pre" // "pre", "in", "post"
}

struct DFSFieldEntry: Identifiable, Hashable {
    let id: UUID
    let name: String
    let playerIDs: [String]
    let isCurrentUser: Bool
    var isRealUser: Bool = false
    var realUserID: String? = nil
}

struct DFSResult: Codable, Identifiable, Hashable {
    let id: UUID
    let tournamentTitle: String
    let rank: Int
    let totalEntries: Int
    let lineupPoints: Double
    let rrDelta: Int
    let loggedAt: Date
    let tournamentId: String?
    let lineupNumber: Int?

    init(id: UUID, tournamentTitle: String, rank: Int, totalEntries: Int, lineupPoints: Double, rrDelta: Int, loggedAt: Date, tournamentId: String? = nil, lineupNumber: Int? = nil) {
        self.id = id
        self.tournamentTitle = tournamentTitle
        self.rank = rank
        self.totalEntries = totalEntries
        self.lineupPoints = lineupPoints
        self.rrDelta = rrDelta
        self.loggedAt = loggedAt
        self.tournamentId = tournamentId
        self.lineupNumber = lineupNumber
    }
}

struct DFSLeaderboardEntry: Identifiable {
    let id: UUID
    let name: String
    let rank: Int
    let points: Double
    let isCurrentUser: Bool
}

/// Live stat line for a single player in the current game
struct DFSPlayerLiveStats: Sendable {
    let name: String             // athlete display name
    let points: Int
    let rebounds: Int
    let assists: Int
    let steals: Int
    let blocks: Int
    let turnovers: Int
    let minutes: String          // e.g. "28:14"
    let fgm: Int
    let fga: Int
    let threePM: Int
    let threePA: Int
    let ftm: Int
    let fta: Int
    let fantasyPoints: Double
    /// Game status for the player's game — e.g. "Q3 4:22", "Half", "Final"
    let gameStatus: String
    /// true when this player's game is finished
    let gameFinal: Bool
}

/// Races an async operation against a deadline. Throws if the deadline wins.
/// Used to keep a single hung network call inside a slate fetch from pinning
/// the UI in its loading state forever.
func withDFSTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(domain: "DFS", code: -1001,
                          userInfo: [NSLocalizedDescriptionKey: "Load timed out — please retry."])
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

/// Compact one-line box-score string for a player, matching the per-sport
/// stat-field mapping used by the live-contest leaderboard (DFSPlayerLiveStats
/// reuses NBA field names for every sport — e.g. MLB batters store H in
/// `points`, HR in `rebounds`, RBI in `assists`). Shared by the public live
/// contest view and private contest standings.
func dfsCompactStatLine(stats: DFSPlayerLiveStats, position: String, sport: String) -> String {
    switch sport.uppercased() {
    case "MLB":
        if position == "SP" || position == "RP" || position == "P" {
            // Pitcher: IP K ER W (minutes = IP, points = K, rebounds = ER, assists = W)
            var parts = ["\(stats.minutes) IP", "\(stats.points) K", "\(stats.rebounds) ER"]
            if stats.assists > 0 { parts.append("W") }
            return parts.joined(separator: "  ")
        }
        // Batter: H/AB + hit types + RBI/R/BB/SB
        let ab = stats.minutes.replacingOccurrences(of: " AB", with: "")
        var hitTypes: [String] = []
        if stats.fga > 0 { hitTypes.append(stats.fga == 1 ? "2B" : "\(stats.fga)x2B") }
        if stats.threePM > 0 { hitTypes.append(stats.threePM == 1 ? "3B" : "\(stats.threePM)x3B") }
        if stats.rebounds > 0 { hitTypes.append(stats.rebounds == 1 ? "HR" : "\(stats.rebounds)xHR") }
        var extras: [String] = []
        if stats.assists > 0 { extras.append("\(stats.assists) RBI") }
        if stats.steals > 0 { extras.append("\(stats.steals) R") }
        if stats.blocks > 0 { extras.append("\(stats.blocks) BB") }
        if stats.turnovers > 0 { extras.append("\(stats.turnovers) SB") }
        return (["\(stats.points)/\(ab)"] + hitTypes + extras).joined(separator: "  ")
    case "NHL":
        if position == "G" {
            var parts = ["\(stats.points) SV", "\(stats.rebounds) GA"]
            if stats.assists > 0 { parts.append("W") }
            if stats.steals > 0 { parts.append("SO") }
            return parts.joined(separator: "  ")
        }
        return "\(stats.fgm) G  \(stats.fga) A  \(stats.threePM) SOG  \(stats.threePA) BLK"
    case "PGA":
        let rounds = [stats.fgm, stats.fga, stats.threePM, stats.threePA]
            .enumerated()
            .map { "R\($0.offset + 1):\($0.element > 0 ? "\($0.element)" : "-")" }
            .joined(separator: " ")
        let par = stats.points == 0 ? "E" : (stats.points > 0 ? "+\(stats.points)" : "\(stats.points)")
        var line = "\(rounds)  \(par)"
        if stats.steals == 1 { line += "  MC" }
        if stats.blocks == 1 { line += "  WD" }
        return line
    case "UFC":
        return "\(stats.points) SIG  \(stats.rebounds) TD  \(stats.assists) KD  \(stats.steals) SUB  \(stats.turnovers) ABS"
    case "EPL", "UCL", "WC":
        return "\(stats.points) G  \(stats.assists) A  \(stats.rebounds) SOT  \(stats.blocks) SV  \(stats.fgm) FD  \(stats.ftm) YC"
    default:
        // NBA / CFB / NFL share the basketball-style mapping
        return "\(stats.points) PTS  \(stats.rebounds) REB  \(stats.assists) AST  \(stats.blocks) BLK  \(stats.steals) STL  \(stats.turnovers) TO"
    }
}

struct DFSGameLiveInfo: Identifiable, Sendable {
    let id: String               // event ID
    let awayTeam: String
    let homeTeam: String
    let awayScore: Int
    let homeScore: Int
    let clock: String            // e.g. "4:22", "0:00"
    let period: Int              // 1-4, 5+ for OT (or 1-9+ for MLB innings)
    let state: String            // "pre", "in", "post"
    let inningHalf: String?      // MLB only: "Top" or "Bot" (nil for other sports)
    let sportType: String?       // "nhl" for hockey period display, nil for basketball
    /// True when ESPN reports the game as postponed/suspended/canceled.
    /// Used by settlement to grade single-game contests as a push (RR=0)
    /// instead of stranding them in shimmer forever waiting for scoring
    /// data that will never arrive.
    let isPostponed: Bool

    init(id: String, awayTeam: String, homeTeam: String, awayScore: Int, homeScore: Int,
         clock: String, period: Int, state: String, inningHalf: String? = nil, sportType: String? = nil,
         isPostponed: Bool = false) {
        self.id = id; self.awayTeam = awayTeam; self.homeTeam = homeTeam
        self.awayScore = awayScore; self.homeScore = homeScore
        self.clock = clock; self.period = period; self.state = state
        self.inningHalf = inningHalf; self.sportType = sportType
        self.isPostponed = isPostponed
    }

    /// Human-readable status like "Q3 4:22", "Half", "Final", "Top 8th", "P2 12:05"
    nonisolated var displayStatus: String {
        if isPostponed { return "PPD" }
        if state == "post" { return "Final" }
        if state == "pre" { return "Pre" }
        // MLB: use inning format ("Top 8th", "Bot 3rd")
        if let half = inningHalf {
            return "\(half) \(ordinal(period))"
        }
        // NHL: use period format ("P1 12:05", "OT 2:30")
        if sportType == "nhl" {
            if period <= 3 {
                return "P\(period) \(clock)"
            } else {
                let otNum = period - 3
                return otNum == 1 ? "OT \(clock)" : "OT\(otNum) \(clock)"
            }
        }
        // UFC: "R1 4:32", "R3 2:15"
        if sportType == "ufc" {
            return clock.isEmpty ? "R\(period)" : clock  // clock already formatted as "R1 4:32"
        }
        // Soccer: "1H 34'", "2H 67'", "HT", "ET 105'"
        if sportType == "soccer" {
            if period == 1 { return "1H \(clock)" }
            if period == 2 { return clock == "0:00" ? "HT" : "2H \(clock)" }
            return "ET \(clock)"
        }
        // Basketball / other sports
        if period == 2 && clock == "0:00" { return "Half" }
        let periodLabel: String
        if period <= 4 {
            periodLabel = "Q\(period)"
        } else {
            let otNum = period - 4
            periodLabel = otNum == 1 ? "OT" : "OT\(otNum)"
        }
        return "\(periodLabel) \(clock)"
    }

    /// Convert inning number to ordinal string: 1→"1st", 2→"2nd", 3→"3rd", 4→"4th", etc.
    nonisolated private func ordinal(_ n: Int) -> String {
        let suffix: String
        let tens = n % 100
        if tens >= 11 && tens <= 13 {
            suffix = "th"
        } else {
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}

struct DFSScoreSnapshot: Sendable {
    let playerFantasyPoints: [String: Double]
    let playerLiveStats: [String: DFSPlayerLiveStats]
    let gameLiveInfo: [String: DFSGameLiveInfo]     // keyed by event ID
    let allGamesFinal: Bool
}

protocol DFSSlateProvider {
    func fetchSlate() async throws -> DFSSlate
}

protocol DFSLiveScoringProvider: Sendable {
    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot
}

struct ConfiguredDFSSlateProvider: DFSSlateProvider {
    private let liveProvider = ESPNNBADFSSlateProvider()

    func fetchSlate() async throws -> DFSSlate {
        let live = try await liveProvider.fetchSlate()
        if live.players.isEmpty {
            throw NSError(domain: "DFS", code: 100, userInfo: [NSLocalizedDescriptionKey: "No live DFS players available"])
        }
        return live
    }
}

/// Returns a pre-built slate — used when creating per-tournament ViewModels from shared data.
struct PreloadedDFSSlateProvider: DFSSlateProvider {
    let slate: DFSSlate
    func fetchSlate() async throws -> DFSSlate { return slate }
}

/// Convert a main-slate salary to single-game (showdown) salary.
/// DK Showdown uses the same $50K cap but only 6 players instead of 10 (MLB) or 8 (NBA/NHL).
/// This means the average spend per slot is much higher (~$8,333 vs ~$5,000 for MLB).
/// DK re-prices showdown players with a non-linear curve: stars get scaled up more.
///
/// Calibrated against real DK pricing:
///   MLB main $6,300 → showdown ~$10,200  (1.62x)
///   MLB main $4,500 → showdown ~$7,000   (1.56x)
///   MLB main $3,000 → showdown ~$5,400   (1.80x — floor players get bumped up)
///   NBA main $10,000 → showdown ~$13,500  (1.35x — NBA has 8 main slots, less scaling)
///   NHL main $8,000  → showdown ~$11,000  (1.38x — NHL has 8 main slots)
func singleGameSalary(from mainSalary: Int, league: String = "NBA") -> Int {
    // MLB uses a dedicated conversion — see mlbShowdownSalary()
    if league == "MLB" {
        return mlbShowdownSalary(from: mainSalary)
    }

    let mainSlots: Double
    let showdownSlots: Double = 6.0

    switch league {
    case "NBA":
        mainSlots = 8.0
    case "NHL":
        mainSlots = 8.0
    case "EPL", "UCL":
        mainSlots = 8.0
    case "UFC":
        mainSlots = 6.0
    case "NFL":
        mainSlots = 9.0
    case "CFB":
        mainSlots = 8.0
    default:
        mainSlots = 8.0
    }

    // Base multiplier from slot ratio
    let baseMultiplier = mainSlots / showdownSlots

    // Non-linear curve: cheaper players get scaled up more (floor bump),
    // mid-tier scaled near base, expensive players scaled slightly above base.
    // This prevents single-game lineups from being trivially easy to fill.
    let salaryFraction = Double(mainSalary) / 50000.0  // fraction of cap
    let curveFactor: Double
    if salaryFraction < 0.06 {
        curveFactor = baseMultiplier * 1.10
    } else if salaryFraction < 0.10 {
        curveFactor = baseMultiplier * 1.02
    } else if salaryFraction < 0.16 {
        curveFactor = baseMultiplier * 0.98
    } else {
        curveFactor = baseMultiplier * 0.95
    }

    let scaled = Int(Double(mainSalary) * curveFactor)
    let rounded = (scaled / 100) * 100
    // NHL minimum salaries can be as low as $2,000 on DraftKings;
    // use a league-appropriate floor so fallback conversions don't
    // inflate cheap players beyond their real showdown prices.
    let floor = (league == "NHL") ? 2000 : 4000
    return max(floor, min(16000, rounded))
}

/// Dedicated MLB showdown salary conversion for BATTERS (pitchers use
/// mlbShowdownPitcherSalary below).
/// Calibrated to a real DK MLB Showdown distribution (SD @ ATL,
/// 2026-07-21, 42 batters): floor $3,000 flat for the whole bench,
/// median $4,900, good starters $6-8K, stars $8-9.6K. The previous
/// curve floored at $4,800 and put average starters at $7-8K — roughly
/// $2-3K/player over DK across the middle of the pool, which made any
/// non-minimum lineup blow through the $50K cap (the "can only afford
/// the 6 cheapest guys" complaint).
///
/// Our estimated main-slate batter prices run $2,200-$6,500.
func mlbShowdownSalary(from mainSalary: Int) -> Int {
    let salary = Double(mainSalary)

    let showdown: Double
    if salary <= 2200 {
        // Bench / min-price players → DK lists the whole bottom tier flat
        showdown = 3000.0
    } else if salary <= 3000 {
        // Fringe starters ($2,200-$3,000) → $3,000-$3,600
        showdown = 3000.0 + (salary - 2200.0) * 0.75
    } else if salary <= 4000 {
        // Average starters ($3,000-$4,000) → $3,600-$5,400 (median zone)
        showdown = 3600.0 + (salary - 3000.0) * 1.80
    } else if salary <= 5000 {
        // Good starters ($4,000-$5,000) → $5,400-$7,200
        showdown = 5400.0 + (salary - 4000.0) * 1.80
    } else if salary <= 6500 {
        // Elite/MVP bats ($5,000-$6,500) → $7,200-$9,600 (Tatis/Acuna tier)
        showdown = 7200.0 + (salary - 5000.0) * 1.60
    } else {
        // Beyond the usual batter range — extend gently
        showdown = 9600.0 + (salary - 6500.0) * 1.0
    }

    let rounded = (Int(showdown) / 100) * 100
    return max(3000, min(11000, rounded))
}

/// DK showdown price for an MLB probable starter, from their main-slate price.
/// Fit to real DK main-vs-showdown pairs (STL @ NYM, 2026-06-11):
///   $9.3K → $12.4K, $8.3K → $11.8K, $6.5K → $10.4K, $6.3K → $10.2K
/// i.e. showdown ≈ 0.733 × main + $5,580. The generic batter curve above
/// overprices pitchers ($9.3K main would map to $14.4K vs DK's $12.4K).
func mlbShowdownPitcherSalary(from mainSalary: Int) -> Int {
    let raw = 0.733 * Double(mainSalary) + 5580.0
    let rounded = (Int(raw) / 100) * 100
    return max(7000, min(16000, rounded))
}

/// Builds the full array of tournaments (main 1000, per-game single games, 10-man, 5-man WTA, 3-man H2H)
/// and the per-game single-game player pools from the main-slate player pool.
func buildMultiTournamentSlate(
    baseID: String,
    league: String,
    mainSalaryCap: Int,
    mainLineupSize: Int,
    mainRosterSlots: [String]?,
    isSingleGameSlate: Bool,
    includedGames: [DFSSlateGame],
    mainPlayers: [DFSPlayer],
    singleGameSalaryCap: Int = 50000,
    showdownSalaries: [String: Int]? = nil,
    // Per-game DK showdown salaries keyed by ESPN game ID. Preferred over the
    // flat `showdownSalaries` for multi-game days (MLB): looking each player up
    // only against THEIR game's slate avoids cross-game name collisions — e.g.
    // a globally-merged map mapping star "Julio Rodriguez" (SEA) onto a cheap
    // "J. Rodriguez" from another game via the fuzzy name fallback.
    perGameShowdownSalaries: [String: [String: Int]]? = nil
) -> (tournaments: [DFSTournament], singleGamePlayers: [String: [DFSPlayer]]) {
    var tournaments: [DFSTournament] = []
    var sgPlayers: [String: [DFSPlayer]] = [:]

    let fieldSizes = [2, 3, 5, 10, 2000]

    let isMLBSlate = league.uppercased() == "MLB"

    if isSingleGameSlate {
        // When the entire day is a single game, generate all field sizes for it
        let game = includedGames.first!
        // Build single-game player pool — use real showdown salaries if available,
        // otherwise fall back to singleGameSalary() transform
        let sgPool = mainPlayers
            .filter { player in
                // MLB showdown matches DK: the two probable starters are in
                // the pool (the main pool only carries probable SPs), but no
                // relievers.
                if isMLBSlate {
                    let pos = player.position.uppercased()
                    return pos != "RP" && pos != "P"
                }
                return true
            }
            .map { player in
                let sgSalary: Int
                if let showdown = showdownSalaries,
                   let dkPrice = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: showdown) {
                    sgSalary = dkPrice
                } else if isMLBSlate && player.position.uppercased() == "SP" {
                    sgSalary = mlbShowdownPitcherSalary(from: player.salary)
                } else {
                    sgSalary = singleGameSalary(from: player.salary, league: league)
                }
                var sgPlayer = DFSPlayer(
                    id: player.id, name: player.name, team: player.team,
                    position: player.position,
                    salary: sgSalary,
                    projectedPoints: player.projectedPoints,
                    gameID: player.gameID, injuryStatus: player.injuryStatus,
                    battingOrder: player.battingOrder,
                    isConfirmedActive: player.isConfirmedActive,
                    gamesPlayed: player.gamesPlayed
                )
                sgPlayer.isStartingGoalie = player.isStartingGoalie
                // CRITICAL: without this, every SG-pool skater defaults to
                // playedRecently=false, the NHL SG bot gate (confirmed AND
                // recent) rejects the whole pool, and bot generation falls
                // back to random lineups full of scratches.
                sgPlayer.playedRecently = player.playedRecently
                return sgPlayer
            }
            .sorted(by: { $0.salary > $1.salary })
        sgPlayers[game.id] = sgPool
        for size in fieldSizes {
            tournaments.append(DFSTournament(
                id: "\(baseID)-sg-\(game.id)-\(size)",
                title: "\(game.awayTeam) @ \(game.homeTeam)",
                league: league,
                entryCount: size,
                lineupSize: 6,
                salaryCap: singleGameSalaryCap,
                rosterSlots: ["MVP", "FLEX", "FLEX", "FLEX", "FLEX", "FLEX"],
                isSingleGame: true,
                tournamentType: .singleGame,
                gameID: game.id
            ))
        }
        return (tournaments, sgPlayers)
    }

    // 1. Main slate tournaments — all 8 field sizes
    // Captain-mode main slates (rosterSlots starting with "MVP", e.g. UFC
    // multi-fight showdown cards) report isSingleGame=true so the lineup
    // builder, scoring, and bot logic all treat slot 0 as the 1.5x MVP.
    // The pool itself is still the full main-slate pool — `computeActivePool`
    // falls through to `return players` when isSingleGame=true and gameID=nil.
    let mainIsCaptain = mainRosterSlots?.first == "MVP"
    for size in fieldSizes {
        tournaments.append(DFSTournament(
            id: "\(baseID)-\(size)",
            title: tournamentTitle(for: size, league: league),
            league: league,
            entryCount: size,
            lineupSize: mainLineupSize,
            salaryCap: mainSalaryCap,
            rosterSlots: mainRosterSlots,
            isSingleGame: mainIsCaptain,
            tournamentType: .main
        ))
    }

    // 2. Per-game single-game tournaments — all 8 field sizes per game
    for game in includedGames {
        // Prefer this game's own showdown salaries (no cross-game name
        // collisions); fall back to the flat map for sports that don't
        // supply a per-game breakdown.
        let gameShowdown = perGameShowdownSalaries?[game.id] ?? showdownSalaries
        let preFilterCount = mainPlayers.filter { $0.gameID == game.id }.count
        let gamePlayers = mainPlayers
            .filter { $0.gameID == game.id }
            // MLB showdown matches DK: include the game's two probable
            // starters (the main pool only carries probable SPs) but no
            // relievers.
            .filter { player in
                if isMLBSlate {
                    let pos = player.position.uppercased()
                    return pos != "RP" && pos != "P"
                }
                return true
            }
            .map { player in
                let sgSalary: Int
                if let showdown = gameShowdown,
                   let dkPrice = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: showdown) {
                    sgSalary = dkPrice
                } else if isMLBSlate && player.position.uppercased() == "SP" {
                    sgSalary = mlbShowdownPitcherSalary(from: player.salary)
                } else {
                    sgSalary = singleGameSalary(from: player.salary, league: league)
                }
                var sgPlayer = DFSPlayer(
                    id: player.id, name: player.name, team: player.team,
                    position: player.position,
                    salary: sgSalary,
                    projectedPoints: player.projectedPoints,
                    gameID: player.gameID, injuryStatus: player.injuryStatus,
                    battingOrder: player.battingOrder,
                    isConfirmedActive: player.isConfirmedActive,
                    gamesPlayed: player.gamesPlayed
                )
                sgPlayer.isStartingGoalie = player.isStartingGoalie
                // CRITICAL: without this, every SG-pool skater defaults to
                // playedRecently=false, the NHL SG bot gate (confirmed AND
                // recent) rejects the whole pool, and bot generation falls
                // back to random lineups full of scratches.
                sgPlayer.playedRecently = player.playedRecently
                return sgPlayer
            }
            .sorted(by: { $0.salary > $1.salary })

        // Only add single-game tournaments if there are enough players
        if gamePlayers.count < 6 {
            print("[DFS-Slate] \(game.awayTeam) @ \(game.homeTeam) (id=\(game.id)): only \(gamePlayers.count) showdown players (\(preFilterCount) pre-filter). Skipping single-game.")
        }
        if gamePlayers.count >= 6 {
            let sgRange = gamePlayers.map(\.salary)
            print("[DFS-Slate] \(game.awayTeam) @ \(game.homeTeam): \(gamePlayers.count) showdown players (\(preFilterCount) pre-filter), salary $\(sgRange.min() ?? 0)-$\(sgRange.max() ?? 0)")
            // Log first 3 conversions for MLB diagnostic
            if league == "MLB" {
                let mainForGame = mainPlayers.filter { $0.gameID == game.id && $0.position != "SP" && $0.position != "RP" && $0.position != "P" }
                for p in mainForGame.prefix(3) {
                    let sg = singleGameSalary(from: p.salary, league: "MLB")
                    print("[MLB-SG] \(p.name): main $\(p.salary) → showdown $\(sg) (mlbShowdownSalary)")
                }
            }
            sgPlayers[game.id] = gamePlayers
            for size in fieldSizes {
                tournaments.append(DFSTournament(
                    id: "\(baseID)-sg-\(game.id)-\(size)",
                    title: "\(game.awayTeam) @ \(game.homeTeam)",
                    league: league,
                    entryCount: size,
                    lineupSize: 6,
                    salaryCap: singleGameSalaryCap,
                    rosterSlots: ["MVP", "FLEX", "FLEX", "FLEX", "FLEX", "FLEX"],
                    isSingleGame: true,
                    tournamentType: .singleGame,
                    gameID: game.id
                ))
            }
        }
    }

    // 3. Evening slate (6pm ET and later games only)
    // Only generate if there are at least 2 evening games and some early games
    // (otherwise the all-day slate IS the evening slate).
    // UFC is one card per night — prelims + main card are conceptually a
    // single event and shouldn't be split into early/evening slates.
    if league.uppercased() == "UFC" {
        return (tournaments, sgPlayers)
    }
    let eveningCutoff: Date = {
        let cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "America/New_York")!
        // Get today's date in ET, then set to 7:00 PM
        var comps = cal.dateComponents(in: tz, from: Date())
        comps.hour = 18
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps) ?? .distantFuture
    }()
    let eveningGames = includedGames.filter { $0.startTime >= eveningCutoff }
    let earlyGames = includedGames.filter { $0.startTime < eveningCutoff }

    // Only create evening slate if there are enough evening games AND there are early games
    // (if all games are evening, no need for a separate evening slate)
    if eveningGames.count >= 2 && !earlyGames.isEmpty {
        let eveningPlayerIDs = Set(eveningGames.map { $0.id })
        let eveningPlayers = mainPlayers.filter { eveningPlayerIDs.contains($0.gameID ?? "") }

        if eveningPlayers.count >= mainLineupSize {
            for size in fieldSizes {
                tournaments.append(DFSTournament(
                    id: "\(baseID)-eve-\(size)",
                    title: "Evening \(tournamentTitle(for: size, league: league))",
                    league: league,
                    entryCount: size,
                    lineupSize: mainLineupSize,
                    salaryCap: mainSalaryCap,
                    rosterSlots: mainRosterSlots,
                    isSingleGame: false,
                    tournamentType: .evening
                ))
            }
        }
    }

    return (tournaments, sgPlayers)
}

/// Human-readable tournament title based on field size
func tournamentTitle(for fieldSize: Int, league: String) -> String {
    switch fieldSize {
    case 2: return "Heads Up"
    case 3: return "3-Man H2H"
    case 5: return "5-Man WTA"
    case 10: return "10-Man Challenge"
    case 2000: return "\(league) Grand Tournament"
    default: return "\(fieldSize)-Entry Tournament"
    }
}

/// In-memory cache for ESPN roster and performance data to avoid redundant network calls
private final class ESPNRosterCache {
    static let shared = ESPNRosterCache()

    struct CachedRoster {
        let players: [DFSPlayer]
        let fetchedAt: Date
    }

    struct CachedRatings {
        let ratings: [String: Double]
        let fetchedAt: Date
    }

    struct CachedSlate {
        let slate: DFSSlate
        let fetchedAt: Date
    }

    private var rosters: [String: CachedRoster] = [:]        // keyed by "teamID-gameID"
    private var ratings: [String: CachedRatings] = [:]        // keyed by teamID
    private var cachedSlates: [String: CachedSlate] = [:]     // keyed by sport
    private let ttl: TimeInterval = 300  // 5 minute cache

    func getSlate(key: String = "nba") -> DFSSlate? {
        guard let cached = cachedSlates[key],
              Date().timeIntervalSince(cached.fetchedAt) < ttl else { return nil }
        return cached.slate
    }

    func setSlate(_ slate: DFSSlate, key: String = "nba") {
        cachedSlates[key] = CachedSlate(slate: slate, fetchedAt: Date())
    }

    func getRoster(teamID: String, gameID: String?) -> [DFSPlayer]? {
        let key = "\(teamID)-\(gameID ?? "none")"
        guard let cached = rosters[key],
              Date().timeIntervalSince(cached.fetchedAt) < ttl else { return nil }
        return cached.players
    }

    func setRoster(teamID: String, gameID: String?, players: [DFSPlayer]) {
        let key = "\(teamID)-\(gameID ?? "none")"
        rosters[key] = CachedRoster(players: players, fetchedAt: Date())
    }

    func getRatings(teamID: String) -> [String: Double]? {
        guard let cached = ratings[teamID],
              Date().timeIntervalSince(cached.fetchedAt) < ttl else { return nil }
        return cached.ratings
    }

    func setRatings(teamID: String, ratings: [String: Double]) {
        self.ratings[teamID] = CachedRatings(ratings: ratings, fetchedAt: Date())
    }
}

struct ESPNNBADFSSlateProvider: DFSSlateProvider {
    private let session: URLSession
    private let cache = ESPNRosterCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        // Return cached slate if recent
        if let cached = cache.getSlate() {
            return cached
        }

        // Start fetching real DraftKings salaries in parallel with ESPN data
        async let rgSalaries = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "nba", maxClassicSalary: 13000)

        let events = try await fetchUpcomingNBAEvents()
        guard !events.isEmpty else {
            throw NSError(domain: "DFS", code: 1)
        }

        // Build team abbreviation → event ID mapping
        var teamToGameID: [String: String] = [:]
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                teamToGameID[competitor.team.abbreviation] = event.id
            }
        }

        let teamRefs = Array(uniqueTeams(from: events).prefix(30))

        // Fetch all rosters in parallel using TaskGroup. We need TWO outputs
        // from this pass: the top-9-per-team pool that becomes the slate's
        // primary player list (unchanged behavior), AND a FULL-roster name
        // lookup table so Phase 2.5 can resolve injected RG players to
        // their real ESPN IDs. Without the full-roster table, Clarkson-
        // style bench players get stub IDs like `nba-<dkDraftableId>` and
        // ESPN box scores can't match them at scoring time → empty stats.
        let rostersResult: (top9: [DFSPlayer], fullByName: [String: DFSPlayer]) = try await withThrowingTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let gameID = teamToGameID[team.abbreviation]
                group.addTask {
                    return try await self.fetchRoster(teamID: team.id, teamAbbreviation: team.abbreviation, gameID: gameID)
                }
            }
            var top9Pool: [DFSPlayer] = []
            var fullLookup: [String: DFSPlayer] = [:]
            for try await roster in group {
                top9Pool.append(contentsOf: roster.prefix(9))
                for player in roster {
                    let key = RotoGrindersSalaryProvider.normalizeName(player.name)
                    if fullLookup[key] == nil { fullLookup[key] = player }
                }
            }
            return (top9Pool, fullLookup)
        }
        let players = rostersResult.top9
        let fullNBARosterByName = rostersResult.fullByName

        let deduped = deduplicatePlayers(players)
        guard !deduped.isEmpty else {
            throw NSError(domain: "DFS", code: 2)
        }

        // Apply real DraftKings salaries from DFF/RotoGrinders where available.
        // Only use real data when the slate clearly matches (>30% players found).
        // When slates don't match, keep the FPPG-based estimatedSalary values.
        let realSalaries = await rgSalaries
        let finalPlayers: [DFSPlayer]
        if !realSalaries.isEmpty {
            let matchCount = deduped.filter { RotoGrindersSalaryProvider.lookupSalary(espnName: $0.name, in: realSalaries) != nil }.count
            let matchRate = Double(matchCount) / Double(max(1, deduped.count))
            let sameSlate = matchRate > 0.30

            if sameSlate {
                // RG salary range for calibrating unmatched players
                let rgMin = realSalaries.values.min() ?? 3500
                let rgMax = realSalaries.values.max() ?? 13000
                let allFPPGs = deduped.map { $0.projectedPoints }
                let fppgMin = allFPPGs.min() ?? 0
                let fppgMax = max(fppgMin + 1, allFPPGs.max() ?? 50)

                var applied = 0
                var calibrated = 0
                finalPlayers = deduped.map { player in
                    if let realSalary = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: realSalaries) {
                        applied += 1
                        var matched = DFSPlayer(
                            id: player.id, name: player.name, team: player.team,
                            position: player.position, salary: realSalary,
                            projectedPoints: player.projectedPoints,
                            gameID: player.gameID, injuryStatus: player.injuryStatus
                        )
                        matched.isConfirmedActive = true
                        return matched
                    }
                    calibrated += 1
                    let fppgFraction = min(1.0, max(0, (player.projectedPoints - fppgMin) / (fppgMax - fppgMin)))
                    let curved = pow(fppgFraction, 0.85)
                    let salary = rgMin + Int(curved * Double(rgMax - rgMin))
                    let roundedSalary = (salary / 100) * 100
                    var unmatched = DFSPlayer(
                        id: player.id, name: player.name, team: player.team,
                        position: player.position, salary: max(rgMin, roundedSalary),
                        projectedPoints: player.projectedPoints,
                        gameID: player.gameID, injuryStatus: player.injuryStatus
                    )
                    unmatched.isConfirmedActive = false
                    return unmatched
                }
                print("[NBA-DFS] sameSlate=true (\(matchCount)/\(deduped.count)), applied=\(applied), calibrated=\(calibrated), range=$\(rgMin)-$\(rgMax)")
            } else {
                // RG data is for a different slate — no real prices for today's
                // games yet. Don't offer a slate built on estimated salaries.
                throw NSError(domain: "NBADFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's NBA slate"])
            }
        } else {
            throw NSError(domain: "NBADFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's NBA slate"])
        }

        let slateDate = events.first?.date ?? Date()
        let tournamentID = "nba-\(dateKey(for: slateDate))"

        let includedGames: [DFSSlateGame] = events.compactMap { event in
            guard let competition = event.competitions.first else { return nil }
            guard let away = competition.competitors.first(where: { $0.homeAway == "away" }) else { return nil }
            guard let home = competition.competitors.first(where: { $0.homeAway == "home" }) else { return nil }
            return DFSSlateGame(
                id: event.id,
                awayTeam: away.team.abbreviation,
                homeTeam: home.team.abbreviation,
                startTime: event.date,
                state: competition.status.type.state
            )
        }

        // Detect single-game slate: the entire day has only 1 game scheduled
        // (common during NBA playoffs). Use total games, not active games,
        // so it doesn't flip mid-slate as games finish.
        let isSingleGame = includedGames.count == 1
        var sortedPlayers = finalPlayers.sorted(by: { $0.salary > $1.salary })

        // Fetch real DraftKings salaries for single-game pricing.
        // Phase 2: pull the slate-specific LineupHQ JSON. Phase 2.5: also
        // pull the full player roster so we can inject any DK-eligible
        // player ESPN missed (e.g. Jordan Clarkson off the bench).
        var nbaSlatePlayers: [RotoGrindersSalaryProvider.LineupHQSlatePlayer] = []
        let dkShowdownSalaries: [String: Int]? = await {
            if isSingleGame, let firstGame = includedGames.first {
                let slate = await RotoGrindersSalaryProvider.shared.fetchShowdownPlayersForGame(
                    sport: "nba",
                    awayHashtag: firstGame.awayTeam,
                    homeHashtag: firstGame.homeTeam,
                    startTime: firstGame.startTime
                )
                if !slate.isEmpty {
                    nbaSlatePlayers = slate
                    var byName: [String: Int] = [:]
                    for p in slate { byName[p.normalizedName] = p.utilSalary }
                    return byName
                }
            }
            let names = sortedPlayers.map(\.name)
            let dk = await RotoGrindersSalaryProvider.shared.fetchDKSalaries(sport: "nba", slatePlayerNames: names)
            return dk.isEmpty ? nil : dk
        }()

        // Phase 2.5: augment the player pool with any RG-slate player not
        // already in our ESPN-derived list. Without this, slate-builder
        // bench players (Harrison Barnes, Jordan Clarkson, etc.) never
        // show up even though DK lists them as eligible. We create a stub
        // `DFSPlayer` keyed off the DK draftableId so live scoring can
        // still match by name to ESPN box scores once the game starts.
        print("[NBA-DFS-2.5] candidate slate players: \(nbaSlatePlayers.count), pool before augmentation: \(sortedPlayers.count)")
        if !nbaSlatePlayers.isEmpty {
            let ourNames = Set(sortedPlayers.map { RotoGrindersSalaryProvider.normalizeName($0.name) })
            var augmented = sortedPlayers
            var injectedNames: [String] = []
            var skippedAlreadyInPool = 0
            let firstGameID = includedGames.first?.id ?? ""
            var resolvedFromRoster = 0
            for rgPlayer in nbaSlatePlayers {
                let normalized = RotoGrindersSalaryProvider.normalizeName(rgPlayer.fullName)
                if ourNames.contains(normalized) {
                    skippedAlreadyInPool += 1
                    continue
                }
                // Prefer the ESPN-roster match — Clarkson, Barnes, etc. are
                // on their team's full ESPN roster, just outside the top-9
                // pool. Using the ESPN ID means live box-score scoring will
                // match them naturally during the game. Fall back to a DK
                // draftableId stub only when ESPN has no record of them.
                let rosterMatch = fullNBARosterByName[normalized]
                let resolvedID = rosterMatch?.id ?? "nba-\(rgPlayer.dkPlayerID ?? rgPlayer.rgPlayerID ?? rgPlayer.normalizedName)"
                let resolvedTeam = rosterMatch?.team ?? ""
                let resolvedProjection = rosterMatch?.projectedPoints ?? 0
                if rosterMatch != nil { resolvedFromRoster += 1 }
                augmented.append(DFSPlayer(
                    id: resolvedID,
                    name: rgPlayer.fullName,
                    team: resolvedTeam,
                    position: rgPlayer.position,
                    salary: rgPlayer.utilSalary,
                    projectedPoints: resolvedProjection,
                    gameID: firstGameID,
                    injuryStatus: nil
                ))
                injectedNames.append(rgPlayer.fullName)
            }
            print("[NBA-DFS-2.5] resolved-from-roster: \(resolvedFromRoster)/\(injectedNames.count) — these will have live ESPN box-score stats")
            if !injectedNames.isEmpty {
                let preview = injectedNames.prefix(10).joined(separator: ", ")
                print("[NBA-DFS-2.5] injected \(injectedNames.count) DK-eligible players missing from ESPN pool: \(preview)\(injectedNames.count > 10 ? "…" : "")")
            } else {
                print("[NBA-DFS-2.5] no missing players to inject (slate had \(nbaSlatePlayers.count), \(skippedAlreadyInPool) already in pool)")
            }
            // Re-sort by salary so the augmented list flows back through the builder correctly.
            sortedPlayers = augmented.sorted(by: { $0.salary > $1.salary })
        }

        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: "NBA",
            mainSalaryCap: 50000,
            mainLineupSize: 8,
            mainRosterSlots: nil,
            isSingleGameSlate: isSingleGame,
            includedGames: includedGames,
            mainPlayers: sortedPlayers,
            showdownSalaries: dkShowdownSalaries
        )

        let slate = DFSSlate(
            tournaments: tournaments,
            includedGames: includedGames,
            players: sortedPlayers,
            singleGamePlayers: sgPlayers
        )
        cache.setSlate(slate)
        return slate
    }

    private func fetchUpcomingNBAEvents() async throws -> [NBAScoreboardEvent] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let dateKeys = [dateKey(for: yesterday), dateKey(for: Date()), dateKey(for: tomorrow)]

        // Fetch all 3 days in parallel
        let allScoreboards: [NBAScoreboardResponse] = await withTaskGroup(of: NBAScoreboardResponse?.self) { group in
            for dk in dateKeys {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=\(dk)") else {
                        return nil
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return nil
                    }
                    return try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data)
                }
            }
            var results: [NBAScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var preEvents: [NBAScoreboardEvent] = []
        var liveEvents: [NBAScoreboardEvent] = []
        var postEvents: [NBAScoreboardEvent] = []

        for scoreboard in allScoreboards {
            for event in scoreboard.events {
                guard let competition = event.competitions.first else { continue }
                let state = competition.status.type.state
                // Accept "pre" games from today or later. A game that is "pre" but
                // whose scheduled start has already passed (delayed tip-off) must
                // still be included — ESPN's state is authoritative.
                if state == "pre" && calendar.startOfDay(for: event.date) >= today {
                    preEvents.append(event)
                } else if state == "in" {
                    liveEvents.append(event)
                } else if state == "post" {
                    postEvents.append(event)
                }
            }
        }

        // If there are live games, include them AND finished/upcoming games from the same day
        // so that all players from the full slate are available for scoring
        if !liveEvents.isEmpty {
            let liveDay = calendar.startOfDay(for: liveEvents.first!.date)
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            return (liveEvents + sameDayPost + sameDayPre).sorted(by: { $0.date < $1.date })
        }

        // All-day slate: if there are finished (post) games from today AND upcoming (pre)
        // games from today, include BOTH so the slate doesn't shrink when early games
        // finish before late games start (e.g. 1pm NBA game ends, 7pm games haven't started).
        if !preEvents.isEmpty {
            let earliestPreDay = preEvents.map { calendar.startOfDay(for: $0.date) }.min()!
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == earliestPreDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == earliestPreDay }
            if !sameDayPost.isEmpty {
                return (sameDayPre + sameDayPost).sorted(by: { $0.date < $1.date })
            }
            let groupedByDay = Dictionary(grouping: preEvents) { calendar.startOfDay(for: $0.date) }
            if let earliestDay = groupedByDay.keys.sorted().first {
                return (groupedByDay[earliestDay] ?? []).sorted(by: { $0.date < $1.date })
            }
            return preEvents
        }

        // No live or pre games — return today's finished (post) games so the tournament
        // can still be loaded for settlement. This handles the case where the user opens
        // the app after all games have finished.
        if !postEvents.isEmpty {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let todaysPost = postEvents.filter { calendar.startOfDay(for: $0.date) == today }
            if !todaysPost.isEmpty {
                return todaysPost.sorted(by: { $0.date < $1.date })
            }
            // If no games today, return the most recent day's finished games
            let groupedByDay = Dictionary(grouping: postEvents) { calendar.startOfDay(for: $0.date) }
            if let mostRecentDay = groupedByDay.keys.sorted().last {
                return (groupedByDay[mostRecentDay] ?? []).sorted(by: { $0.date < $1.date })
            }
        }

        return []
    }

    private func uniqueTeams(from events: [NBAScoreboardEvent]) -> [NBATeamRef] {
        var seen = Set<String>()
        var result: [NBATeamRef] = []

        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                let id = competitor.team.id
                guard seen.insert(id).inserted else { continue }
                result.append(NBATeamRef(id: id, abbreviation: competitor.team.abbreviation))
            }
        }

        return result
    }

    private func fetchRoster(teamID: String, teamAbbreviation: String, gameID: String? = nil) async throws -> [DFSPlayer] {
        // Check cache first
        if let cached = cache.getRoster(teamID: teamID, gameID: gameID) {
            return cached
        }

        let performanceRatings = try await fetchPerformanceRatings(teamID: teamID)
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/\(teamID)/roster") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let roster = try? JSONDecoder().decode(NBARosterResponse.self, from: data) else {
            return []
        }

        let players = roster.athletes.map { athlete in
            let position = athlete.position?.abbreviation ?? "UTIL"
            let fppg = performanceRatings[athlete.id] ?? 0.0
            let salary = estimatedSalary(for: athlete.id, position: position, rating: fppg)
            let projection = projectedPoints(for: salary, position: position, rating: fppg)

            // Parse injury status
            let injuryStatus: String?
            if let injury = athlete.injuries?.first, let status = injury.status {
                switch status.lowercased() {
                case "out": injuryStatus = "O"
                case "day-to-day": injuryStatus = "GTD"
                case "questionable": injuryStatus = "Q"
                case "doubtful": injuryStatus = "D"
                case "probable": injuryStatus = "P"
                default: injuryStatus = nil
                }
            } else {
                injuryStatus = nil
            }

            return DFSPlayer(
                id: "nba-\(athlete.id)",
                name: athlete.fullName,
                team: teamAbbreviation,
                position: position,
                salary: salary,
                projectedPoints: projection,
                gameID: gameID,
                injuryStatus: injuryStatus
            )
        }
        .sorted { $0.projectedPoints > $1.projectedPoints }

        cache.setRoster(teamID: teamID, gameID: gameID, players: players)
        return players
    }

    /// Per-player stats parsed from ESPN: FPPG (fantasy points per game), GP, and minutes
    struct PlayerStatProfile {
        let fppg: Double          // fantasy points per game using DK formula
        let gamesPlayed: Int
        let minutesPerGame: Double
        let ppg: Double
    }

    /// Fetch actual per-player stats from ESPN and compute fantasy point averages.
    /// Returns [athleteID: PlayerStatProfile] for all players on the team.
    private func fetchPerformanceRatings(teamID: String) async throws -> [String: Double] {
        // Check cache first
        if let cached = cache.getRatings(teamID: teamID) {
            return cached
        }

        let profiles = try await fetchPlayerStatProfiles(teamID: teamID)
        // Convert to simple ratings dictionary for cache compatibility
        // Use FPPG directly as the "rating" — salary function will handle mapping
        let ratings = profiles.mapValues { $0.fppg }
        cache.setRatings(teamID: teamID, ratings: ratings)
        return ratings
    }

    /// Parsed stat profiles cache (separate from the simple ratings cache)
    private func fetchPlayerStatProfiles(teamID: String) async throws -> [String: PlayerStatProfile] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/\(teamID)/athletes/statistics") else {
            return [:]
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return [:]
        }

        var profiles: [String: PlayerStatProfile] = [:]

        // results[0] contains all players with full statistics
        guard let firstResult = results.first,
              let leaders = firstResult["leaders"] as? [[String: Any]] else {
            return [:]
        }

        for leader in leaders {
            guard let athlete = leader["athlete"] as? [String: Any],
                  let athleteID = athlete["id"] as? String else { continue }

            guard let statistics = leader["statistics"] as? [[String: Any]] else { continue }

            // Parse stats from all 3 sections (general, offensive, defensive)
            var ppg: Double = 0, rpg: Double = 0, apg: Double = 0
            var spg: Double = 0, bpg: Double = 0, topg: Double = 0
            var gp: Int = 0, mpg: Double = 0
            var threepmg: Double = 0

            for section in statistics {
                guard let stats = section["stats"] as? [[String: Any]] else { continue }
                for stat in stats {
                    guard let name = stat["name"] as? String,
                          let value = stat["value"] as? Double else { continue }
                    switch name {
                    case "avgPoints": ppg = value
                    case "avgRebounds": rpg = value
                    case "avgAssists": apg = value
                    case "avgSteals": spg = value
                    case "avgBlocks": bpg = value
                    case "avgTurnovers": topg = value
                    case "gamesPlayed": gp = Int(value)
                    case "avgMinutes": mpg = value
                    case "avgThreePointFieldGoalsMade": threepmg = value
                    default: break
                    }
                }
            }

            // Compute DK-style fantasy points per game
            // DK NBA: PTS×1 + REB×1.25 + AST×1.5 + STL×2 + BLK×2 + TO×-0.5 + 3PM×0.5
            let fppg = ppg * 1.0
                + rpg * 1.25
                + apg * 1.5
                + spg * 2.0
                + bpg * 2.0
                - topg * 0.5
                + threepmg * 0.5

            profiles[athleteID] = PlayerStatProfile(
                fppg: fppg,
                gamesPlayed: gp,
                minutesPerGame: mpg,
                ppg: ppg
            )
        }

        return profiles
    }

    /// Map fantasy points per game to DK-style salary.
    /// DK NBA salary range: $3,500 - $12,500
    /// FPPG ranges: ~5 (end of bench) to ~65 (Jokic/Luka)
    private func estimatedSalary(for playerID: String, position: String, rating: Double) -> Int {
        // rating is now FPPG (fantasy points per game)
        let fppg = rating

        // DK-like salary mapping based on FPPG tiers
        // Superstars (50+ FPPG): $10,000 - $12,500
        // Stars (40-50 FPPG): $8,000 - $10,000
        // Starters (25-40 FPPG): $5,500 - $8,000
        // Role players (15-25 FPPG): $4,000 - $5,500
        // Bench (0-15 FPPG): $3,500 - $4,000
        let salary: Int
        if fppg >= 50 {
            // Superstars: steep curve at the top
            let fraction = min(1.0, (fppg - 50.0) / 15.0)
            salary = 10000 + Int(fraction * 2500.0)
        } else if fppg >= 40 {
            let fraction = (fppg - 40.0) / 10.0
            salary = 8000 + Int(fraction * 2000.0)
        } else if fppg >= 25 {
            let fraction = (fppg - 25.0) / 15.0
            salary = 5500 + Int(fraction * 2500.0)
        } else if fppg >= 15 {
            let fraction = (fppg - 15.0) / 10.0
            salary = 4000 + Int(fraction * 1500.0)
        } else {
            let fraction = max(0, fppg) / 15.0
            salary = 3500 + Int(fraction * 500.0)
        }

        // Round to nearest $100 (FanDuel standard) with small stable jitter
        let stableHash = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = (abs(stableHash % 3) - 1) * 100  // -100, 0, or +100
        let rounded = ((salary + jitter + 50) / 100) * 100
        return max(3500, min(12500, rounded))
    }

    /// Project fantasy points based on actual FPPG from ESPN stats.
    private func projectedPoints(for salary: Int, position: String, rating: Double) -> Double {
        // rating is now FPPG — use it directly with slight regression to mean
        let fppg = rating
        // Players with no stats at all shouldn't get a free projection boost
        guard fppg > 0 else { return 0.0 }
        // Regress slightly toward position average to account for variance
        let positionAvg: Double
        switch position {
        case "PG": positionAvg = 28.0
        case "SG", "SF": positionAvg = 25.0
        case "PF", "C": positionAvg = 27.0
        default: positionAvg = 20.0
        }
        // 85% actual FPPG + 15% position average (mild regression)
        let projected = fppg * 0.85 + positionAvg * 0.15
        return (projected * 10).rounded() / 10
    }

    private func deduplicatePlayers(_ players: [DFSPlayer]) -> [DFSPlayer] {
        var seen = Set<String>()
        return players.filter { seen.insert($0.id).inserted }
    }

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - RotoGrinders FanDuel Salary Provider

/// Fetches real DraftKings salary data from DFF/RotoGrinders for more accurate DFS pricing.
/// Falls back gracefully — callers should use FPPG-based estimates when this returns empty.
actor RotoGrindersSalaryProvider {
    static let shared = RotoGrindersSalaryProvider()

    /// Cached salary data: [sport: [normalizedName: salary]]
    private var cache: [String: [String: Int]] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheDuration: TimeInterval = 600 // 10 minutes

    /// Fetch DraftKings classic-slate salaries for the given sport ("mlb", "nba", "nhl").
    /// Returns a dictionary mapping normalized player names to salary in dollars.
    /// **Primary:** DailyFantasyFuel DraftKings — reliable full-slate DK prices.
    /// **Fallback:** RotoGrinders DraftKings — may return showdown pricing (detected & rejected).
    func fetchSalaries(sport: String, maxClassicSalary: Int? = nil, date: Date = Date()) async -> [String: Int] {
        // Cache key is per-sport per-date so the UFC-on-June-14 fetch
        // doesn't clobber the MLB-on-June-9 fetch in the same cache slot.
        let cacheKey = "\(sport)@\(Self.dateKeyStatic(for: date))"
        if let cached = cache[cacheKey],
           let timestamp = cacheTimestamps[cacheKey],
           Date().timeIntervalSince(timestamp) < cacheDuration,
           !cached.isEmpty {
            return cached
        }

        // --- Primary: RotoGrinders LineupHQ JSON (S3 public bucket) ---
        // Authoritative DK salaries for the day, no auth required, no
        // showdown/captain conversion needed for main slates. For showdown
        // slates this returns the UTIL (base) price; the caller's
        // showdown-detection still runs below to gate the cache.
        var lineupHQ = await fetchLineupHQ(sport: sport, date: date)
        // RG doesn't publish the aggregate `players.json` for every sport
        // on every date (MMA and soccer routinely 404). Fall back to
        // merging the per-slate classic JSONs from the date master.
        if lineupHQ.isEmpty {
            lineupHQ = await fetchClassicSalariesFromMaster(sport: sport, date: date)
        }
        // Last-ditch: for single-event cards like UFC 250, the only
        // LineupHQ slates published are showdown/captain mode. Pull
        // those directly so we still surface real DK salaries instead
        // of falling back to estimates.
        if lineupHQ.isEmpty {
            lineupHQ = await fetchAllShowdownSalaries(sport: sport, date: date)
        }
        // Final last-ditch: hit DraftKings' public API directly. For
        // sports where RotoGrinders' aggregate isn't published at all
        // (MMA almost always falls into this hole), DK exposes a
        // contest-listing endpoint that includes the draft-group ID,
        // and the per-draft-group `draftables` endpoint returns every
        // player with their DK salary.
        if lineupHQ.isEmpty {
            lineupHQ = await fetchDraftKingsDirect(sport: sport)
        }
        if !lineupHQ.isEmpty {
            // Apply the same showdown-inflation guard as DFF so we don't
            // accept a single-game slate's prices as main-slate data when
            // the caller asked for classic.
            if let maxClassic = maxClassicSalary {
                let sorted = lineupHQ.values.sorted()
                let median = sorted[sorted.count / 2]
                let top = sorted.last ?? 0
                let aboveClassicMax = sorted.filter { $0 > maxClassic }.count
                if median > maxClassic / 2 || top > maxClassic * 5 / 4 || aboveClassicMax >= 2 {
                    print("[LineupHQ] Detected showdown for \(sport.uppercased()): median=$\(median), top=$\(top), aboveMax=\(aboveClassicMax). Falling through to DFF/RG.")
                } else {
                    cache[cacheKey] = lineupHQ
                    cacheTimestamps[cacheKey] = Date()
                    return lineupHQ
                }
            } else {
                cache[sport] = lineupHQ
                cacheTimestamps[sport] = Date()
                return lineupHQ
            }
        }

        // --- Secondary: DailyFantasyFuel DraftKings ---
        let dffSalaries = await fetchDailyFantasyFuel(sport: sport, platform: "draftkings")
        if !dffSalaries.isEmpty {
            // Validate DFF data against showdown/single-game slate inflation.
            // During playoffs with few games, DFF may return showdown prices as the primary page.
            // Detection: if ANY player exceeds maxClassicSalary * 1.25, it's showdown pricing.
            // Also check median > maxClassic/2 for heavily inflated slates.
            if let maxClassic = maxClassicSalary {
                let sorted = dffSalaries.values.sorted()
                let median = sorted[sorted.count / 2]
                let top = sorted.last ?? 0
                let aboveClassicMax = sorted.filter { $0 > maxClassic }.count
                if median > maxClassic / 2 || top > maxClassic * 5 / 4 || aboveClassicMax >= 2 {
                    print("[DFF-Salary] Detected showdown/single-game slate for \(sport.uppercased()): median=$\(median), top=$\(top), aboveMax=\(aboveClassicMax), maxClassic=$\(maxClassic). Skipping to fallbacks.")
                } else {
                    cache[cacheKey] = dffSalaries
                    cacheTimestamps[cacheKey] = Date()
                    print("[DFF-Salary] Fetched \(dffSalaries.count) \(sport.uppercased()) DraftKings salaries (range $\(dffSalaries.values.min() ?? 0)-$\(dffSalaries.values.max() ?? 0))")
                    return dffSalaries
                }
            } else {
                cache[sport] = dffSalaries
                cacheTimestamps[sport] = Date()
                print("[DFF-Salary] Fetched \(dffSalaries.count) \(sport.uppercased()) DraftKings salaries (range $\(dffSalaries.values.min() ?? 0)-$\(dffSalaries.values.max() ?? 0))")
                return dffSalaries
            }
        }

        // --- Fallback: RotoGrinders DraftKings ---
        let rgSalaries = await fetchRotoGrinders(sport: sport, maxClassicSalary: maxClassicSalary)
        if !rgSalaries.isEmpty {
            cache[cacheKey] = rgSalaries
            cacheTimestamps[cacheKey] = Date()
            return rgSalaries
        }

        return [:]
    }

    /// Fetch salaries directly from DraftKings' public lobby + draft
    /// group endpoints. Used when both LineupHQ and DFF have nothing
    /// for the sport (MMA on PPV nights, EuroLeague specials, etc).
    /// Returns the same `[normalizedName: salary]` shape as the rest of
    /// the salary providers.
    func fetchDraftKingsDirect(sport: String) async -> [String: Int] {
        // DK's sport codes are mostly the same as ours, lowercased.
        // NOTE: DraftKings files WNBA draft groups under Sport "NBA" with a
        // " (WNBA)" suffix on ContestStartTimeSuffix — there is no "WNBA" sport
        // param (querying sport=WNBA returns an unfiltered lobby). So for WNBA
        // we query the NBA lobby and filter to the WNBA-suffixed groups; for
        // regular NBA we exclude them.
        let wantWNBA = sport.lowercased() == "wnba"
        let dkSportCode: String
        switch sport.lowercased() {
        case "ufc", "mma": dkSportCode = "MMA"
        case "mlb": dkSportCode = "MLB"
        case "nba", "wnba": dkSportCode = "NBA"
        case "nhl": dkSportCode = "NHL"
        case "nfl": dkSportCode = "NFL"
        case "epl", "ucl", "wc", "soc", "soccer": dkSportCode = "SOC"
        case "golf", "pga": dkSportCode = "GOLF"
        default: dkSportCode = sport.uppercased()
        }
        // Step 1: Get the lobby contest list to find an active draftGroupId.
        guard let lobbyURL = URL(string: "https://www.draftkings.com/lobby/getcontests?sport=\(dkSportCode)") else {
            return [:]
        }
        guard let (lobbyData, lobbyResp) = try? await URLSession.shared.data(from: lobbyURL),
              let lobbyHTTP = lobbyResp as? HTTPURLResponse,
              (200..<300).contains(lobbyHTTP.statusCode),
              let lobbyJSON = try? JSONSerialization.jsonObject(with: lobbyData) as? [String: Any] else {
            print("[DK-Direct] lobby fetch failed for \(dkSportCode)")
            return [:]
        }
        let draftGroups = (lobbyJSON["DraftGroups"] as? [[String: Any]]) ?? []
        guard !draftGroups.isEmpty else {
            print("[DK-Direct] no draft groups for \(dkSportCode)")
            return [:]
        }
        // Prefer non-tier (classic/showdown) groups over Tiers/Pickem.
        // Sort by start time so we hit the soonest contest first.
        let candidates = draftGroups
            .compactMap { group -> (id: Int, gameType: String, startISO: String, suffix: String, gameCount: Int)? in
                guard let id = group["DraftGroupId"] as? Int else { return nil }
                let gameType = (group["GameTypeId"] as? Int).map(String.init) ?? ""
                let startISO = (group["StartDate"] as? String) ?? ""
                let suffix = ((group["ContestStartTimeSuffix"] as? String) ?? "").uppercased()
                let gameCount = (group["GameCount"] as? Int) ?? 0
                return (id, gameType, startISO, suffix, gameCount)
            }
            // WNBA shares the NBA lobby — keep only the " (WNBA)" groups for
            // WNBA, and drop them for plain NBA so the two don't cross-pollute.
            .filter { wantWNBA ? $0.suffix.contains("WNBA") : !$0.suffix.contains("WNBA") }
            // For WNBA, prefer the main classic slate (most games, no "POINTS"/
            // "TIERS" pricing variant) so we land on real salaries first.
            .sorted {
                if wantWNBA {
                    let aMain = !$0.suffix.contains("POINTS") && !$0.suffix.contains("TIER")
                    let bMain = !$1.suffix.contains("POINTS") && !$1.suffix.contains("TIER")
                    if aMain != bMain { return aMain }
                    if $0.gameCount != $1.gameCount { return $0.gameCount > $1.gameCount }
                }
                return $0.startISO < $1.startISO
            }

        var salaries: [String: Int] = [:]
        for candidate in candidates.prefix(5) {
            // Step 2: For each candidate draft group, fetch its
            // draftables list. The endpoint includes every player with
            // their DK salary for that slate.
            guard let draftablesURL = URL(string: "https://api.draftkings.com/draftgroups/v1/draftgroups/\(candidate.id)/draftables") else { continue }
            guard let (data, resp) = try? await URLSession.shared.data(from: draftablesURL),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let draftables = (json["draftables"] as? [[String: Any]]) ?? []
            for player in draftables {
                guard let name = player["displayName"] as? String, !name.isEmpty,
                      let salary = player["salary"] as? Int, salary > 0 else { continue }
                let key = Self.normalizeName(name)
                // Captain prices are 1.5x UTIL. If we see two prices for
                // the same player, prefer the smaller one (UTIL price).
                if let existing = salaries[key], existing <= salary { continue }
                salaries[key] = salary
            }
            if !salaries.isEmpty {
                print("[DK-Direct] \(salaries.count) \(dkSportCode) salaries from draftGroup=\(candidate.id) (range $\(salaries.values.min() ?? 0)-$\(salaries.values.max() ?? 0))")
                break
            }
        }
        return salaries
    }

    /// True when the LineupHQ master for the given sport+date contains
    /// only showdown/captain-mode slates and no classic slates. Used by
    /// callers (UFC, MLB single-game) to decide whether to expose a
    /// captain-mode lineup (MVP + 5 UTIL) instead of a classic roster.
    func detectCaptainMode(sport: String, date: Date) async -> Bool {
        let master = await fetchSlateMaster(sport: sport, date: date)
        guard !master.isEmpty else { return false }
        let hasClassic = master.values.contains { $0.type == "classic" }
        let hasShowdown = master.values.contains { $0.type == "showdown" }
        return !hasClassic && hasShowdown
    }

    /// Format Date → "YYYYMMDD" in America/New_York (the time zone all
    /// LineupHQ slate-file paths are bucketed under).
    static func dateKeyStatic(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Fetch DraftKings main-slate MLB salaries from DFF (no scaling — DK prices used directly).
    /// Used as a per-player fallback when the primary DK source has showdown-contaminated prices.
    func fetchDKMLBSalaries() async -> [String: Int] {
        let dkSalaries = await fetchDailyFantasyFuel(sport: "mlb", platform: "draftkings")
        guard !dkSalaries.isEmpty else { return [:] }

        // Validate DK data isn't showdown (DK main-slate max is ~$13K for pitchers)
        let top = dkSalaries.values.max() ?? 0
        guard top <= 14000 else {
            print("[DFF-Salary] MLB DK data looks like showdown (top=$\(top)), skipping DK fallback")
            return [:]
        }

        if !dkSalaries.isEmpty {
            print("[DFF-Salary] MLB DK fallback ready: \(dkSalaries.count) players (range $\(dkSalaries.values.min() ?? 0)-$\(dkSalaries.values.max() ?? 0))")
        }
        return dkSalaries
    }

    /// Fetch DraftKings showdown UTIL salaries for the given sport.
    /// Pass `slatePlayerNames` to validate that the returned data matches the current slate.
    /// Tries DailyFantasyFuel first, then RotoGrinders DK as fallback.
    /// RotoGrinders DK page shows **captain prices (1.5x)** during showdown slates,
    /// so we detect and convert to UTIL prices by dividing by 1.5.
    func fetchDKSalaries(sport: String, slatePlayerNames: [String] = []) async -> [String: Int] {

        // Helper: check if a salary map matches the current slate (>40% overlap)
        func matchesSlate(_ salaries: [String: Int]) -> Bool {
            guard !slatePlayerNames.isEmpty else { return true }
            let matchCount = slatePlayerNames.filter { Self.lookupSalary(espnName: $0, in: salaries) != nil }.count
            let rate = Double(matchCount) / Double(max(1, slatePlayerNames.count))
            print("[DK-Salary] Slate match: \(matchCount)/\(slatePlayerNames.count) = \(Int(rate * 100))%")
            return rate > 0.40
        }

        // Helper: convert captain prices (1.5x) to UTIL prices if detected.
        // Both DFF and RG can return captain prices during showdown slates.
        // DK showdown captains are 1.5x UTIL — if top salary > $14,000, assume captain pricing.
        func convertCaptainToUtil(_ salaries: [String: Int], source: String) -> [String: Int] {
            let top = salaries.values.max() ?? 0
            if top > 14000 {
                let util = salaries.mapValues { salary in
                    ((Int(Double(salary) / 1.5)) / 100) * 100
                }
                print("[DK-Salary] \(source): Converted \(util.count) \(sport.uppercased()) captain→UTIL (top $\(top)→$\(util.values.max() ?? 0), range $\(util.values.min() ?? 0)-$\(util.values.max() ?? 0))")
                return util
            }
            return salaries
        }

        // Helper: fetch from RG DK page
        func fetchFromRG() async -> [String: Int] {
            let rgURL = "https://rotogrinders.com/lineups/\(sport)?site=draftkings"
            guard let url = URL(string: rgURL) else { return [:] }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                print("[DK-Salary] RG: Failed to fetch \(sport) DK salaries")
                return [:]
            }

            let rawSalaries = parseRGSalaries(from: html)
            guard !rawSalaries.isEmpty else {
                print("[DK-Salary] RG: No \(sport) DK salary data parsed")
                return [:]
            }

            print("[DK-Salary] RG: \(rawSalaries.count) \(sport.uppercased()) DK salaries (range $\(rawSalaries.values.min() ?? 0)-$\(rawSalaries.values.max() ?? 0))")
            return rawSalaries
        }

        // 0. Try LineupHQ JSON first — authoritative DK prices, no captain
        //    conversion needed since the S3 file returns UTIL/base salaries
        //    directly. For showdown slates the slate's player list is
        //    typically the only thing in `players.json` for that sport on
        //    that date, so name-matching against the live slate just works.
        let hqSalaries = await fetchLineupHQ(sport: sport)
        if !hqSalaries.isEmpty {
            if matchesSlate(hqSalaries) {
                print("[DK-Salary] Using LineupHQ: \(hqSalaries.count) \(sport.uppercased()) salaries (range $\(hqSalaries.values.min() ?? 0)-$\(hqSalaries.values.max() ?? 0))")
                return hqSalaries
            }
            print("[DK-Salary] LineupHQ data doesn't match current slate, trying DFF...")
        }

        // 1. Try DailyFantasyFuel DK
        let dffSalaries = await fetchDailyFantasyFuel(sport: sport, platform: "draftkings")
        if !dffSalaries.isEmpty {
            let converted = convertCaptainToUtil(dffSalaries, source: "DFF")
            if matchesSlate(converted) {
                print("[DK-Salary] Using DFF: \(converted.count) \(sport.uppercased()) salaries (range $\(converted.values.min() ?? 0)-$\(converted.values.max() ?? 0))")
                return converted
            }
            print("[DK-Salary] DFF data doesn't match current slate, trying RG...")
        }

        // 2. Fallback: RotoGrinders DK
        let rgSalaries = await fetchFromRG()
        if !rgSalaries.isEmpty {
            let converted = convertCaptainToUtil(rgSalaries, source: "RG")
            if matchesSlate(converted) {
                print("[DK-Salary] Using RG: \(converted.count) \(sport.uppercased()) salaries (range $\(converted.values.min() ?? 0)-$\(converted.values.max() ?? 0))")
                return converted
            }
        }

        print("[DK-Salary] No matching \(sport.uppercased()) DK salaries found from DFF or RG")
        return [:]
    }

    /// Fetch from DailyFantasyFuel — uses `data-name` and `data-salary` attributes on `<tr>` elements.
    /// Returns main/classic slate pricing for the specified platform.
    private func fetchDailyFantasyFuel(sport: String, platform: String = "draftkings") async -> [String: Int] {
        let urlString = "https://www.dailyfantasyfuel.com/\(sport)/projections/\(platform)"
        guard let url = URL(string: urlString) else { return [:] }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            print("[DFF-Salary] Failed to fetch \(sport) \(platform) salaries from DailyFantasyFuel")
            return [:]
        }

        return parseDFFSalaries(from: html)
    }

    /// Fetch from RotoGrinders DraftKings with showdown detection.
    private func fetchRotoGrinders(sport: String, maxClassicSalary: Int?) async -> [String: Int] {
        let urlString = "https://rotogrinders.com/lineups/\(sport)?site=draftkings"
        guard let url = URL(string: urlString) else { return [:] }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            print("[RG-Salary] Failed to fetch \(sport) salaries from RotoGrinders")
            return [:]
        }

        let salaries = parseRGSalaries(from: html)
        if !salaries.isEmpty {
            // Detect single-game showdown slate pricing.
            if let maxClassic = maxClassicSalary {
                let sorted = salaries.values.sorted()
                let median = sorted[sorted.count / 2]
                let top = sorted.last ?? 0
                let aboveClassicMax = sorted.filter { $0 > maxClassic }.count
                if median > maxClassic / 2 || top > maxClassic * 5 / 4 || aboveClassicMax >= 2 {
                    print("[RG-Salary] Detected showdown slate for \(sport.uppercased()): median=$\(median), top=$\(top), aboveMax=\(aboveClassicMax), maxClassic=$\(maxClassic). Rejecting data.")
                    return [:]
                }
            }
            print("[RG-Salary] Fetched \(salaries.count) \(sport.uppercased()) DraftKings salaries (range $\(salaries.values.min() ?? 0)-$\(salaries.values.max() ?? 0))")
        } else {
            print("[RG-Salary] No salary data parsed for \(sport)")
        }
        return salaries
    }

    /// Parse player names and salaries from DailyFantasyFuel HTML.
    /// Each player row is a `<tr>` with `data-name="Full Name"` and `data-salary="XXXXX"` attributes.
    /// Always returns classic/main slate pricing.
    private func parseDFFSalaries(from html: String) -> [String: Int] {
        var result: [String: Int] = [:]

        // Pattern: data-name="Player Name" ... data-salary="XXXXX"
        let pattern = #"data-name="([^"]+)"[^>]*data-salary="(\d+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [:] }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let nameRange = match.range(at: 1)
            let salaryRange = match.range(at: 2)
            guard nameRange.location != NSNotFound, salaryRange.location != NSNotFound else { continue }

            let name = nsHTML.substring(with: nameRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let salaryStr = nsHTML.substring(with: salaryRange)

            guard let salary = Int(salaryStr), salary > 0 else { continue }

            let normalizedName = Self.normalizeName(name)
            // DFF shows each player once — no dedup needed, but guard against duplicates
            if result[normalizedName] == nil {
                result[normalizedName] = salary
            }
        }

        return result
    }

    // MARK: - LineupHQ S3 JSON fetcher
    //
    // RotoGrinders' LineupHQ optimizer pulls from public S3 buckets at:
    //   https://s3.amazonaws.com/json.rotogrinders.com/lineuphq/v1.00/{YYYY-MM-DD}/{sport}/players.json
    //
    // Response shape (keyed by RG player ID):
    //   { "13460": {
    //       "name": "Sandy Leon",
    //       "site_ids":  { "draftkings": "392375", ... },
    //       "salaries":  { "draftkings": "2000",   ... },
    //       "positions": { "draftkings": "C",       ... }
    //   } }
    //
    // No auth required, no cookies, no API key — plain GET. These are the
    // authoritative DK prices RG uses internally; far more reliable than
    // scraping the projections HTML or DailyFantasyFuel pages, and works
    // for every sport including soccer, UFC, and showdown slates.

    /// Per-player record in LineupHQ's `players.json`. We decode only the
    /// fields we use; unknown keys are ignored.
    private struct LineupHQPlayer: Decodable {
        let name: String?
        struct SiteIDs: Decodable { let draftkings: String? }
        struct Positions: Decodable { let draftkings: String? }
        struct Salaries: Decodable {
            let draftkings: SalaryValue?
        }
        /// DK salaries come through as strings (e.g. "2000"); other sites
        /// sometimes use ints. Accept either, parse to Int defensively.
        enum SalaryValue: Decodable {
            case string(String)
            case int(Int)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .string(s); return }
                if let i = try? c.decode(Int.self) { self = .int(i); return }
                throw DecodingError.typeMismatch(SalaryValue.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Salary not String or Int"))
            }
            var intValue: Int? {
                switch self {
                case .int(let i): return i
                case .string(let s): return Int(s)
                }
            }
        }
        let site_ids: SiteIDs?
        let positions: Positions?
        let salaries: Salaries?
    }

    /// Maps internal sport codes to RotoGrinders' LineupHQ path segments.
    /// Lowercase; matches DK conventions (mma for UFC, soc for soccer).
    private static func lineupHQSportPath(for sport: String) -> String {
        switch sport.lowercased() {
        case "ufc", "mma": return "mma"
        case "epl", "ucl", "wc", "soccer", "soc": return "soc"
        case "ncaaf", "cfb": return "cfb"
        case "ncaab", "ncaam": return "ncaab"
        default: return sport.lowercased()
        }
    }

    /// A LineupHQ aggregate record with the fields we use downstream.
    struct LineupHQAggregateRecord {
        let salary: Int
        let position: String  // DK eligible positions, e.g. "1B/OF"
    }

    /// Fetch DK salaries AND positions from LineupHQ's public S3 JSON.
    /// Returns a map of normalized name → record (salary + DK position
    /// string). Useful when callers need to remap pool players whose
    /// upstream position doesn't fit any DK lineup slot (e.g. Ohtani as
    /// "UTIL" or "DH" in ESPN → "1B/OF" on DK, draftable at 1B or OF).
    private func fetchLineupHQRecords(sport: String, date: Date = Date()) async -> [String: LineupHQAggregateRecord] {
        let path = Self.lineupHQSportPath(for: sport)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        let dateStr = fmt.string(from: date)

        let urlStr = "https://s3.amazonaws.com/json.rotogrinders.com/lineuphq/v1.00/\(dateStr)/\(path)/players.json"
        guard let url = URL(string: urlStr) else { return [:] }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("[LineupHQ] Failed to fetch \(path) for \(dateStr)")
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: LineupHQPlayer].self, from: data) else {
            print("[LineupHQ] Failed to decode \(path) players.json")
            return [:]
        }

        var result: [String: LineupHQAggregateRecord] = [:]
        for (_, player) in decoded {
            guard let name = player.name, !name.isEmpty,
                  let salary = player.salaries?.draftkings?.intValue, salary > 0 else { continue }
            let position = player.positions?.draftkings ?? ""
            let key = Self.normalizeName(name)
            if let existing = result[key], existing.salary >= salary { continue }
            result[key] = LineupHQAggregateRecord(salary: salary, position: position)
        }

        if result.isEmpty {
            print("[LineupHQ] No DK salaries in \(path) for \(dateStr) (got \(decoded.count) records)")
        } else {
            let mn = result.values.map(\.salary).min() ?? 0
            let mx = result.values.map(\.salary).max() ?? 0
            print("[LineupHQ] \(result.count) \(sport.uppercased()) DK salaries (range $\(mn)-$\(mx)) for \(dateStr)")
        }
        return result
    }

    /// Thin wrapper returning just salaries — used everywhere we don't
    /// care about positions.
    private func fetchLineupHQ(sport: String, date: Date = Date()) async -> [String: Int] {
        let records = await fetchLineupHQRecords(sport: sport, date: date)
        return records.mapValues { $0.salary }
    }

    /// Public accessor for DK positions from LineupHQ's aggregate. Returns
    /// a map of normalized name → eligible DK positions string (e.g.
    /// "1B/OF", "C", "SP"). Empty if the aggregate isn't published for
    /// the sport+date. Used by MLB main-slate to remap UTIL / DH players
    /// to their actual DK-eligible positions so they're draftable.
    func fetchLineupHQPositions(sport: String) async -> [String: String] {
        let records = await fetchLineupHQRecords(sport: sport)
        return records.compactMapValues { rec in
            rec.position.isEmpty ? nil : rec.position
        }
    }

    // MARK: - LineupHQ Slate-Specific Pricing (Phase 2)
    //
    // The aggregate `players.json` covers every slate on a date, so a
    // player can appear with two salaries (e.g. the main showdown UTIL
    // price AND a Pick'em-mode price). Showdown contests need the EXACT
    // slate's pricing, not a merge. Lookup chain:
    //
    //   1. `.../v2.00/{YYYY}/{MM}/{DD}/slates/{sport}-master.json`
    //      → returns `{ "draftkings": { "<slateId>": { name, type, games[], slate_path, ... } } }`.
    //   2. Filter slates: `type == "showdown"` AND `games.length == 1`
    //      AND `games[0].teamAwayHashtag/teamHomeHashtag` matches our game.
    //   3. Read `slate_path` (DO NOT hardcode the contest-type code in the
    //      URL — slate 148615 uses `/draftkings/15/`, 148614 uses `/14/`).
    //   4. GET the per-slate JSON. It's an ARRAY of records; each has
    //      `player.first_name/last_name/position` and
    //      `schedule.salaries: [{position, salary, player_id}]`.
    //      For showdown there are exactly 2 salary entries per player —
    //      higher = CPT draftableId, lower = UTIL. We use the LOWER as the
    //      UTIL price and let the caller's MVP-slot logic apply the 1.5x
    //      multiplier (matches `fpts_multipliers.CPT` from definitions).

    private struct RGSlateMaster: Decodable {
        let draftkings: [String: RGSlateMasterEntry]?
    }
    private struct RGSlateMasterEntry: Decodable {
        let name: String?
        let type: String?
        let date: String?
        let salaryCap: Int?
        let slate_path: String?
        let games: [RGSlateGame]?
    }
    private struct RGSlateGame: Decodable {
        let scheduleId: String?
        let rgScheduleId: String?
        let teamAwayHashtag: String?
        let teamHomeHashtag: String?
        let date: String?
    }
    private struct RGSlateDetailRecord: Decodable {
        let stat_group: String?
        let player: RGSlatePlayer?
        let schedule: RGSlateScheduleBlock?
        let attributes: RGSlateAttributes?
    }
    /// Per-record metadata RG attaches when relevant. Soccer slates carry
    /// `starting_lineup` (0/1) once XIs are announced. Golf classic slates
    /// carry `score`, `rank`, and `status` (live scoring fields). MLB
    /// classic slates carry batting order. Other sports leave this empty.
    private struct RGSlateAttributes: Decodable {
        let starting_lineup: AttrInt?
    }
    /// RG sometimes serves boolean-ish flags as raw ints, sometimes as
    /// strings; tolerate both.
    enum AttrInt: Decodable {
        case value(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .value(i); return }
            if let s = try? c.decode(String.self), let i = Int(s) { self = .value(i); return }
            if let b = try? c.decode(Bool.self) { self = .value(b ? 1 : 0); return }
            self = .value(0)
        }
        var intValue: Int { if case .value(let v) = self { return v }; return 0 }
    }
    private struct RGSlatePlayer: Decodable {
        let id: String?
        let rg_id: String?
        let first_name: String?
        let last_name: String?
        let position: String?
        let team_id: String?
    }
    private struct RGSlateScheduleBlock: Decodable {
        let id: String?
        let salaries: [RGSlateSalaryEntry]?
    }
    private struct RGSlateSalaryEntry: Decodable {
        let position: String?
        let salary: Int?
        let player_id: String?
    }

    /// Fetch the master slate index for a sport on a date. Keys are RG
    /// slate IDs, values describe the slate (name, type, games, path).
    private func fetchSlateMaster(sport: String, date: Date) async -> [String: RGSlateMasterEntry] {
        let path = Self.lineupHQSportPath(for: sport)
        let cal = Calendar(identifier: .gregorian)
        let dc = cal.dateComponents(in: TimeZone(identifier: "America/New_York")!, from: date)
        guard let y = dc.year, let m = dc.month, let d = dc.day else { return [:] }
        let mm = String(format: "%02d", m)
        let dd = String(format: "%02d", d)
        // NOTE: v2.00 master files live at `.../json.rotogrinders.com/v2.00/...`
        // — there is NO `/lineuphq/` segment here, even though the v1.00
        // aggregate `players.json` DOES use `/lineuphq/`. RG uses two
        // different prefixes for v1 vs v2; mixing them returns 404.
        let urlStr = "https://s3.amazonaws.com/json.rotogrinders.com/v2.00/\(y)/\(mm)/\(dd)/slates/\(path)-master.json"
        guard let url = URL(string: urlStr) else { return [:] }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("[LineupHQ-Slate] Failed to fetch \(path)-master for \(y)-\(mm)-\(dd)")
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode(RGSlateMaster.self, from: data) else {
            print("[LineupHQ-Slate] Failed to decode \(path)-master")
            return [:]
        }
        return decoded.draftkings ?? [:]
    }

    /// Pull the per-slate detail JSON by following the `slate_path` from
    /// the master. Returns the decoded records.
    private func fetchSlateDetail(slatePath: String) async -> [RGSlateDetailRecord] {
        guard let url = URL(string: slatePath) else { return [] }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("[LineupHQ-Slate] Failed to fetch slate detail at \(slatePath)")
            return []
        }
        guard let decoded = try? JSONDecoder().decode([RGSlateDetailRecord].self, from: data) else {
            print("[LineupHQ-Slate] Failed to decode slate detail at \(slatePath)")
            return []
        }
        return decoded
    }

    /// Resolve a showdown slate for the given matchup and return its UTIL
    /// salaries by normalized player name.
    ///
    /// Match priority:
    ///   1. Single-game showdown (`type=="showdown"`, `games.count==1`,
    ///      team hashtags match). Most accurate when present.
    ///   2. Series-level showdown (`type=="showdown"`, `games.count>1`,
    ///      ANY game's hashtags match). NHL Finals tonight is exactly this
    ///      shape — only the series showdown is published (`games.count==7`,
    ///      slate 148804), no per-game variant.
    /// Picks the best single-game showdown slate among team-tag matches.
    /// MLB doubleheaders publish TWO slates with identical team tags —
    /// dictionary order picked one arbitrarily, so the nightcap could get
    /// the matinee's prices (and vice versa). When several match and a
    /// start time is known, take the slate whose game time is closest.
    private func pickSingleGameShowdownSlate(
        master: [String: RGSlateMasterEntry],
        teamsMatch: (RGSlateGame) -> Bool,
        startTime: Date?,
        label: String
    ) -> (key: String, value: RGSlateMasterEntry)? {
        let matches = master.filter { (_, slate) -> Bool in
            guard slate.type == "showdown",
                  let games = slate.games, games.count == 1,
                  let g = games.first else { return false }
            return teamsMatch(g)
        }
        guard matches.count > 1, let target = startTime else {
            return matches.first.map { (key: $0.key, value: $0.value) }
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let best = matches.min { a, b in
            func distance(_ entry: RGSlateMasterEntry) -> TimeInterval {
                guard let ds = entry.games?.first?.date, let d = fmt.date(from: ds) else {
                    return .greatestFiniteMagnitude
                }
                return abs(d.timeIntervalSince(target))
            }
            return distance(a.value) < distance(b.value)
        }
        print("[LineupHQ-Slate] \(matches.count) showdown slates match \(label) (doubleheader) — picked \(best?.value.name ?? "?") by start time")
        return best.map { (key: $0.key, value: $0.value) }
    }

    func fetchShowdownSalariesForGame(
        sport: String,
        awayHashtag: String,
        homeHashtag: String,
        startTime: Date? = nil
    ) async -> [String: Int] {
        let master = await fetchSlateMaster(sport: sport, date: Date())
        guard !master.isEmpty else { return [:] }

        let awayN = awayHashtag.uppercased()
        let homeN = homeHashtag.uppercased()
        // ESPN uses 2-letter team codes for some leagues (NBA: "NY"/"SA";
        // MLB: "BOS"/"NYY" — already 3 char so no issue) while RG uses
        // DK's 3-letter codes (NBA: "NYK"/"SAS"). Strict equality misses
        // valid matches, so accept either exact equality or
        // mutual-prefix containment in either direction. This covers
        // NY↔NYK, SA↔SAS, MIA↔MIA, etc. without false positives between
        // similarly-prefixed but distinct teams (NBA codes are unique in
        // their first 2-3 chars within any given matchup).
        func codesMatch(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            if a.hasPrefix(b) || b.hasPrefix(a) { return true }
            return false
        }
        func teamsMatch(_ g: RGSlateGame) -> Bool {
            guard let a = g.teamAwayHashtag?.uppercased(),
                  let h = g.teamHomeHashtag?.uppercased() else { return false }
            return (codesMatch(a, awayN) && codesMatch(h, homeN))
                || (codesMatch(a, homeN) && codesMatch(h, awayN))
        }

        let single = pickSingleGameShowdownSlate(
            master: master, teamsMatch: teamsMatch,
            startTime: startTime, label: "\(sport.uppercased()) \(awayHashtag)@\(homeHashtag)"
        )
        let series = master.first { (_, slate) -> Bool in
            guard slate.type == "showdown",
                  let games = slate.games, games.count > 1 else { return false }
            return games.contains(where: teamsMatch)
        }
        let candidate = single.map { ($0.key, $0.value) } ?? series
        guard let (slateID, slate) = candidate, let path = slate.slate_path else {
            print("[LineupHQ-Slate] No showdown slate found for \(sport.uppercased()) \(awayHashtag) @ \(homeHashtag)")
            return [:]
        }
        if single == nil {
            print("[LineupHQ-Slate] Using series-level showdown for \(sport.uppercased()) \(awayHashtag)@\(homeHashtag) (no single-game variant published)")
        }

        let records = await fetchSlateDetail(slatePath: path)
        guard !records.isEmpty else { return [:] }

        // Showdown: 2 salary entries per player (CPT higher, UTIL lower).
        // Group salaries by player name → take MIN as the UTIL price.
        var byName: [String: Int] = [:]
        for record in records {
            guard let first = record.player?.first_name,
                  let last = record.player?.last_name,
                  let salaries = record.schedule?.salaries, !salaries.isEmpty else { continue }
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            // Lower of the two = UTIL (the higher one is CPT at 1.5x).
            let util = salaries.compactMap(\.salary).min() ?? 0
            guard util > 0 else { continue }
            let key = Self.normalizeName(name)
            if let existing = byName[key], existing <= util { continue }
            byName[key] = util
        }
        if !byName.isEmpty {
            let mn = byName.values.min() ?? 0
            let mx = byName.values.max() ?? 0
            print("[LineupHQ-Slate] Showdown \(sport.uppercased()) slate \(slateID) (\(awayHashtag)@\(homeHashtag)): \(byName.count) UTIL salaries (range $\(mn)-$\(mx))")
        }
        return byName
    }

    /// Fetch classic-slate UTIL salaries by merging every classic slate
    /// for `sport` on today's date. Used as a fallback when the aggregate
    /// `players.json` is missing for a sport (RG doesn't publish it for
    /// every sport on every date — MMA and soccer routinely 404). Reads
    /// `schedule.salaries[].salary` directly from the per-slate JSON.
    ///
    /// `nameContains` lets soccer callers filter to the slate of their
    /// league (e.g. `(WC)`, `(EPL)`, `(UCL)`). For sports where there's
    /// only one classic slate (MMA), pass `nil`.
    func fetchClassicSalariesFromMaster(sport: String, nameContains: String? = nil, date: Date = Date()) async -> [String: Int] {
        let master = await fetchSlateMaster(sport: sport, date: date)
        guard !master.isEmpty else { return [:] }

        let classicSlates = master.values.filter { slate in
            guard slate.type == "classic", slate.slate_path != nil else { return false }
            if let filter = nameContains {
                return (slate.name ?? "").localizedCaseInsensitiveContains(filter)
            }
            return true
        }
        guard !classicSlates.isEmpty else {
            print("[LineupHQ-Slate] No classic slates for \(sport.uppercased())\(nameContains.map { " (filter: \($0))" } ?? "")")
            return [:]
        }

        let allRecords = await withTaskGroup(of: [RGSlateDetailRecord].self, returning: [RGSlateDetailRecord].self) { group in
            for slate in classicSlates {
                guard let path = slate.slate_path else { continue }
                group.addTask { await self.fetchSlateDetail(slatePath: path) }
            }
            var merged: [RGSlateDetailRecord] = []
            for await chunk in group { merged.append(contentsOf: chunk) }
            return merged
        }

        var byName: [String: Int] = [:]
        for record in allRecords {
            guard let first = record.player?.first_name,
                  let last = record.player?.last_name,
                  let salary = record.schedule?.salaries?.first?.salary, salary > 0 else { continue }
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            let key = Self.normalizeName(name)
            if let existing = byName[key], existing >= salary { continue }
            byName[key] = salary
        }

        if !byName.isEmpty {
            print("[LineupHQ-Slate] Classic-from-master \(sport.uppercased()): \(byName.count) salaries from \(classicSlates.count) slates (range $\(byName.values.min() ?? 0)-$\(byName.values.max() ?? 0))")
        }
        return byName
    }

    /// Golf-only: DK salaries from the week's PRIMARY full-tournament
    /// classic slate. The aggregate players.json merges EVERY golf slate
    /// keeping the max price per player — during tournament weekends DK
    /// posts single-round and "Late Round" captain slates on a whole
    /// different scale ($15K+ mid-tier golfers), which contaminated the
    /// pool and made prices drift day to day. RG names the primary slate
    /// "(PGA TOUR)" or "(PGA)" depending on the week, so select classic
    /// slates by EXCLUDING the specialty variants instead.
    func fetchGolfPrimaryClassicSalaries(date: Date = Date()) async -> [String: Int] {
        let master = await fetchSlateMaster(sport: "golf", date: date)
        guard !master.isEmpty else { return [:] }

        let excluded = ["weekend", "round", "alternate", "tiers", "showdown", "captain"]
        let primarySlates = master.values.filter { slate in
            guard slate.type == "classic", slate.slate_path != nil else { return false }
            let name = (slate.name ?? "").lowercased()
            return !excluded.contains(where: { name.contains($0) })
        }
        guard !primarySlates.isEmpty else {
            print("[LineupHQ-Slate] No primary golf classic slate for \(Self.dateKeyStatic(for: date))")
            return [:]
        }

        let allRecords = await withTaskGroup(of: [RGSlateDetailRecord].self, returning: [RGSlateDetailRecord].self) { group in
            for slate in primarySlates {
                guard let path = slate.slate_path else { continue }
                group.addTask { await self.fetchSlateDetail(slatePath: path) }
            }
            var merged: [RGSlateDetailRecord] = []
            for await chunk in group { merged.append(contentsOf: chunk) }
            return merged
        }

        var byName: [String: Int] = [:]
        for record in allRecords {
            guard let first = record.player?.first_name,
                  let last = record.player?.last_name,
                  let salary = record.schedule?.salaries?.first?.salary, salary > 0 else { continue }
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            let key = Self.normalizeName(name)
            if let existing = byName[key], existing >= salary { continue }
            byName[key] = salary
        }
        if !byName.isEmpty {
            print("[LineupHQ-Slate] Golf primary classic: \(byName.count) salaries (range $\(byName.values.min() ?? 0)-$\(byName.values.max() ?? 0))")
        }
        return byName
    }

    /// Same as `fetchClassicSalariesFromMaster` but returns the FULL
    /// LineupHQ player records (names, positions, team IDs, salaries,
    /// DK ids). Used for Phase 2.5 main-slate augmentation — e.g. NHL
    /// call-ups or deep-bench skaters that appear on DK but not in
    /// ESPN's top-14-per-team pool.
    func fetchClassicPlayersFromMaster(
        sport: String,
        nameContains: String? = nil
    ) async -> [LineupHQSlatePlayer] {
        let master = await fetchSlateMaster(sport: sport, date: Date())
        guard !master.isEmpty else { return [] }

        let classicSlates = master.values.filter { slate in
            guard slate.type == "classic", slate.slate_path != nil else { return false }
            if let filter = nameContains {
                return (slate.name ?? "").localizedCaseInsensitiveContains(filter)
            }
            return true
        }
        guard !classicSlates.isEmpty else { return [] }

        let allRecords = await withTaskGroup(of: [RGSlateDetailRecord].self, returning: [RGSlateDetailRecord].self) { group in
            for slate in classicSlates {
                guard let path = slate.slate_path else { continue }
                group.addTask { await self.fetchSlateDetail(slatePath: path) }
            }
            var merged: [RGSlateDetailRecord] = []
            for await chunk in group { merged.append(contentsOf: chunk) }
            return merged
        }

        // Dedupe by normalized name — same player can appear in multiple
        // classic slates on the same day. Prefer the highest salary entry
        // (mirrors the main classic-salary helper's behavior).
        var bestByName: [String: LineupHQSlatePlayer] = [:]
        for record in allRecords {
            guard let first = record.player?.first_name,
                  let last = record.player?.last_name,
                  let position = record.player?.position,
                  let teamID = record.player?.team_id,
                  let salaries = record.schedule?.salaries, !salaries.isEmpty else { continue }
            let entry = salaries.compactMap { (s: RGSlateSalaryEntry) -> (salary: Int, playerID: String?)? in
                guard let sal = s.salary, sal > 0 else { return nil }
                return (sal, s.player_id)
            }.max(by: { $0.salary < $1.salary })
            guard let best = entry else { continue }
            let key = Self.normalizeName("\(first) \(last)")
            let candidate = LineupHQSlatePlayer(
                firstName: first,
                lastName: last,
                position: position,
                teamID: teamID,
                utilSalary: best.salary,
                dkPlayerID: best.playerID,
                rgPlayerID: record.player?.rg_id
            )
            if let existing = bestByName[key], existing.utilSalary >= best.salary { continue }
            bestByName[key] = candidate
        }
        let result = Array(bestByName.values)
        if !result.isEmpty {
            print("[LineupHQ-Slate] Classic-players-from-master \(sport.uppercased()): \(result.count) players from \(classicSlates.count) slates")
        }
        return result
    }

    /// Pull RG's confirmed-starter flags for the soccer classic slates of
    /// today. Returns the set of normalized player names whose
    /// `attributes.starting_lineup` is 1 (announced in the starting XI).
    /// Soccer is the only sport that publishes this attribute today; for
    /// other sports the field is empty and this returns an empty set.
    ///
    /// `nameContains` lets callers filter to a specific league's slate
    /// (e.g. `(WC)`, `(EPL)`); passing nil unions across every classic
    /// slate the master returns.
    func fetchSoccerConfirmedStarters(nameContains: String? = nil) async -> Set<String> {
        let master = await fetchSlateMaster(sport: "soc", date: Date())
        guard !master.isEmpty else { return [] }

        let classicSlates = master.values.filter { slate in
            guard slate.type == "classic", slate.slate_path != nil else { return false }
            if let filter = nameContains {
                return (slate.name ?? "").localizedCaseInsensitiveContains(filter)
            }
            return true
        }
        guard !classicSlates.isEmpty else { return [] }

        let allRecords = await withTaskGroup(of: [RGSlateDetailRecord].self, returning: [RGSlateDetailRecord].self) { group in
            for slate in classicSlates {
                guard let path = slate.slate_path else { continue }
                group.addTask { await self.fetchSlateDetail(slatePath: path) }
            }
            var merged: [RGSlateDetailRecord] = []
            for await chunk in group { merged.append(contentsOf: chunk) }
            return merged
        }

        var starters = Set<String>()
        for record in allRecords {
            guard record.attributes?.starting_lineup?.intValue == 1,
                  let first = record.player?.first_name,
                  let last = record.player?.last_name else { continue }
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            starters.insert(Self.normalizeName(name))
        }

        if !starters.isEmpty {
            print("[LineupHQ-Slate] Soccer confirmed starters from RG: \(starters.count)\(nameContains.map { " (filter: \($0))" } ?? "")")
        }
        return starters
    }

    /// A DK-eligible player from a LineupHQ slate, with the data we need
    /// to either match against our existing pool or inject as a new entry.
    struct LineupHQSlatePlayer {
        let firstName: String
        let lastName: String
        let position: String
        let teamID: String       // RG's internal team id
        let utilSalary: Int
        let dkPlayerID: String?  // DK draftableId (UTIL variant)
        let rgPlayerID: String?
        var fullName: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }
        var normalizedName: String { RotoGrindersSalaryProvider.normalizeName(fullName) }
    }

    /// Resolve a single-game showdown slate and return its FULL player
    /// pool — names, positions, team IDs, UTIL salaries, DK draftable IDs.
    /// Used for Phase 2.5 player-pool augmentation: any RG player not
    /// already in our ESPN-derived pool gets injected as a stub so the
    /// lineup builder shows everyone DK actually has on the slate.
    func fetchShowdownPlayersForGame(
        sport: String,
        awayHashtag: String,
        homeHashtag: String,
        startTime: Date? = nil
    ) async -> [LineupHQSlatePlayer] {
        let master = await fetchSlateMaster(sport: sport, date: Date())
        guard !master.isEmpty else {
            print("[LineupHQ-Slate] fetchShowdownPlayersForGame: master empty for \(sport.uppercased())")
            return []
        }

        let awayN = awayHashtag.uppercased()
        let homeN = homeHashtag.uppercased()
        // ESPN uses 2-letter team codes for some leagues (NBA: "NY"/"SA";
        // MLB: "BOS"/"NYY" — already 3 char so no issue) while RG uses
        // DK's 3-letter codes (NBA: "NYK"/"SAS"). Strict equality misses
        // valid matches, so accept either exact equality or
        // mutual-prefix containment in either direction. This covers
        // NY↔NYK, SA↔SAS, MIA↔MIA, etc. without false positives between
        // similarly-prefixed but distinct teams (NBA codes are unique in
        // their first 2-3 chars within any given matchup).
        func codesMatch(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            if a.hasPrefix(b) || b.hasPrefix(a) { return true }
            return false
        }
        func teamsMatch(_ g: RGSlateGame) -> Bool {
            guard let a = g.teamAwayHashtag?.uppercased(),
                  let h = g.teamHomeHashtag?.uppercased() else { return false }
            return (codesMatch(a, awayN) && codesMatch(h, homeN))
                || (codesMatch(a, homeN) && codesMatch(h, awayN))
        }
        let single = pickSingleGameShowdownSlate(
            master: master, teamsMatch: teamsMatch,
            startTime: startTime, label: "\(sport.uppercased()) \(awayHashtag)@\(homeHashtag)"
        )
        let series = master.first { (_, slate) -> Bool in
            guard slate.type == "showdown",
                  let games = slate.games, games.count > 1 else { return false }
            return games.contains(where: teamsMatch)
        }
        let candidate = single.map { ($0.key, $0.value) } ?? series
        guard let (slateID, slate) = candidate, let path = slate.slate_path else {
            print("[LineupHQ-Slate] fetchShowdownPlayersForGame: no matching slate for \(sport.uppercased()) \(awayHashtag)@\(homeHashtag) (master had \(master.count) slates)")
            return []
        }
        let slateKind = (single != nil) ? "SINGLE-GAME" : "SERIES"
        print("[LineupHQ-Slate] fetchShowdownPlayersForGame: using \(slateKind) slate \(slateID) for \(sport.uppercased()) \(awayHashtag)@\(homeHashtag) — name=\(slate.name ?? "?")")

        let records = await fetchSlateDetail(slatePath: path)
        guard !records.isEmpty else { return [] }

        var result: [LineupHQSlatePlayer] = []
        for record in records {
            guard let first = record.player?.first_name,
                  let last = record.player?.last_name,
                  let position = record.player?.position,
                  let teamID = record.player?.team_id,
                  let salaries = record.schedule?.salaries, !salaries.isEmpty else { continue }

            // For showdown: 2 salary entries. Lower = UTIL, higher = CPT.
            let sorted = salaries.compactMap { (s: RGSlateSalaryEntry) -> (salary: Int, playerID: String?)? in
                guard let sal = s.salary, sal > 0 else { return nil }
                return (sal, s.player_id)
            }.sorted(by: { $0.salary < $1.salary })
            guard let util = sorted.first else { continue }

            result.append(LineupHQSlatePlayer(
                firstName: first,
                lastName: last,
                position: position,
                teamID: teamID,
                utilSalary: util.salary,
                dkPlayerID: util.playerID,
                rgPlayerID: record.player?.rg_id
            ))
        }
        // Diagnostic: log resolved player count + a few sample prices so we
        // can verify min-salary players are coming through at their real DK
        // prices ($1,000 floor) rather than our SG-fallback ($4,000+).
        let minSal = result.map(\.utilSalary).min() ?? 0
        let maxSal = result.map(\.utilSalary).max() ?? 0
        let cheapest = result.sorted(by: { $0.utilSalary < $1.utilSalary }).prefix(4)
            .map { "\($0.fullName)=$\($0.utilSalary)" }.joined(separator: ", ")
        print("[LineupHQ-Slate] fetchShowdownPlayersForGame: \(result.count) players, salary $\(minSal)-$\(maxSal). Cheapest: \(cheapest)")
        return result
    }

    /// Fetch UTIL salaries from every showdown (`games.length == 1`) slate
    /// for `sport` on today's date and merge them into one map.
    ///
    /// Use this when the caller is building per-game showdown pools across
    /// many games at once (MLB main day → 15 per-game SG slates, UFC card →
    /// 12 per-fight SG slates, soccer matchday → N per-match SG slates).
    /// Each player is unique to a single game on a date, so name-key
    /// dedup never collides.
    func fetchAllShowdownSalaries(sport: String, nameContains: String? = nil, teamFilter: Set<String>? = nil, date: Date = Date()) async -> [String: Int] {
        var master = await fetchSlateMaster(sport: sport, date: date)
        // RG sometimes hasn't published the current day's master yet while the
        // PREVIOUS day's master already lists the upcoming matchup's showdown
        // (WC final weekend: the 07/18 master carried the 07/19 ESP-ARG
        // slate). Only safe when a team filter scopes the lookup to the exact
        // matchup — without one, a day-back fallback would import a whole
        // prior day's unrelated showdowns.
        if master.isEmpty, teamFilter != nil,
           let prevDay = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: date) {
            master = await fetchSlateMaster(sport: sport, date: prevDay)
        }
        guard !master.isEmpty else { return [:] }

        // Only true single-game showdowns (games.length == 1). Series-level
        // showdowns (games.length > 1, e.g. NBA finals series captain mode)
        // would mix players across many games and shouldn't bleed into
        // a per-game pricing lookup.
        //
        // Matching: a slate qualifies if its game's team hashtags hit
        // `teamFilter`, OR its name contains `nameContains`. The team filter
        // matters for soccer: RG names SHOWDOWN slates with the matchup only
        // ("2026-06-11 3:00pm (MEX vs RSA)") — no league tag — so the
        // "(WC)"/"(EPL)" name filter alone silently excluded every soccer
        // showdown and the app never saw DK's real SG prices.
        let showdownSlates = master.values.filter { slate in
            guard slate.type == "showdown",
                  (slate.games?.count ?? 0) == 1,
                  slate.slate_path != nil else { return false }
            if let teams = teamFilter, let game = slate.games?.first {
                let away = (game.teamAwayHashtag ?? "").uppercased()
                let home = (game.teamHomeHashtag ?? "").uppercased()
                if !away.isEmpty, teams.contains(away) { return true }
                if !home.isEmpty, teams.contains(home) { return true }
            }
            if let filter = nameContains {
                return (slate.name ?? "").localizedCaseInsensitiveContains(filter)
            }
            // No name filter: include everything only when no team filter
            // was requested either (e.g. MLB/UFC callers want all showdowns).
            return teamFilter == nil
        }
        guard !showdownSlates.isEmpty else {
            print("[LineupHQ-Slate] No single-game showdown slates for \(sport.uppercased()) today")
            return [:]
        }

        // Fetch all detail JSONs in parallel — bounded by `showdownSlates.count`.
        let allRecords = await withTaskGroup(of: [RGSlateDetailRecord].self, returning: [RGSlateDetailRecord].self) { group in
            for slate in showdownSlates {
                guard let path = slate.slate_path else { continue }
                group.addTask { await self.fetchSlateDetail(slatePath: path) }
            }
            var merged: [RGSlateDetailRecord] = []
            for await chunk in group { merged.append(contentsOf: chunk) }
            return merged
        }

        var byName: [String: Int] = [:]
        for record in allRecords {
            guard let first = record.player?.first_name,
                  let last = record.player?.last_name,
                  let salaries = record.schedule?.salaries, !salaries.isEmpty else { continue }
            let util = salaries.compactMap(\.salary).min() ?? 0
            guard util > 0 else { continue }
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            let key = Self.normalizeName(name)
            // Keep the LOWER salary if duplicate (player happens to appear in
            // multiple showdown variants like classic showdown + captain mode).
            if let existing = byName[key], existing <= util { continue }
            byName[key] = util
        }

        if !byName.isEmpty {
            print("[LineupHQ-Slate] All-showdown \(sport.uppercased()): merged \(byName.count) UTIL salaries from \(showdownSlates.count) slates (range $\(byName.values.min() ?? 0)-$\(byName.values.max() ?? 0))")
        }
        return byName
    }

    /// Resolve a classic/main slate for the given set of game team-hashtag
    /// pairs and return its salaries by normalized player name.
    /// Match key: `games.length == ourGames.count` AND every team appears
    /// in the slate's games array.
    func fetchClassicSalariesForGames(
        sport: String,
        gameHashtagPairs: [(away: String, home: String)]
    ) async -> [String: Int] {
        guard !gameHashtagPairs.isEmpty else { return [:] }
        let master = await fetchSlateMaster(sport: sport, date: Date())
        guard !master.isEmpty else { return [:] }

        let ourSet = Set(gameHashtagPairs.flatMap { [$0.away.uppercased(), $0.home.uppercased()] })
        let candidate = master.first { (_, slate) -> Bool in
            guard slate.type == "classic",
                  let games = slate.games, games.count == gameHashtagPairs.count else { return false }
            let slateTeams = Set(games.flatMap { [
                $0.teamAwayHashtag?.uppercased() ?? "",
                $0.teamHomeHashtag?.uppercased() ?? ""
            ]})
            return ourSet.isSubset(of: slateTeams)
        }
        guard let (slateID, slate) = candidate, let path = slate.slate_path else {
            print("[LineupHQ-Slate] No classic slate found for \(sport.uppercased()) (\(gameHashtagPairs.count) games)")
            return [:]
        }

        let records = await fetchSlateDetail(slatePath: path)
        guard !records.isEmpty else { return [:] }

        // Classic: one salary entry per player.
        var byName: [String: Int] = [:]
        for record in records {
            guard let first = record.player?.first_name,
                  let last = record.player?.last_name,
                  let salary = record.schedule?.salaries?.first?.salary, salary > 0 else { continue }
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            let key = Self.normalizeName(name)
            if let existing = byName[key], existing >= salary { continue }
            byName[key] = salary
        }
        if !byName.isEmpty {
            let mn = byName.values.min() ?? 0
            let mx = byName.values.max() ?? 0
            print("[LineupHQ-Slate] Classic \(sport.uppercased()) slate \(slateID) (\(gameHashtagPairs.count) games): \(byName.count) salaries (range $\(mn)-$\(mx))")
        }
        return byName
    }

    /// Parse player names and salaries from RotoGrinders HTML.
    /// Uses the `data-salary` attribute on player nameplates for accurate FanDuel salaries,
    /// paired with the player name from the `/players/` link that follows.
    /// Filters out single-game showdown slates where salaries are inflated (captain = 1.5x).
    private func parseRGSalaries(from html: String) -> [String: Int] {
        var result: [String: Int] = [:]

        // RotoGrinders HTML structure:
        //   <span class="player-nameplate " data-position="PG" data-salary="8600">
        //     <div class="player-nameplate-info">
        //       <a href="/players/lamelo-ball-2439295" ...>LaMelo Ball</a>
        //
        // Match: data-salary="(\d+)" ... href="/players/..." ... >Player Name</a>
        // Use .{0,400} (non-greedy, up to 400 chars) between data-salary and the player link,
        // because MLB HTML has batting order spans and divs between the attribute and the player name.
        let playerPattern = #"data-salary="(\d+)".{0,400}?href="/players/[^"]*"\s*>([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: playerPattern, options: [.dotMatchesLineSeparators]) else {
            return [:]
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let salaryRange = match.range(at: 1)
            let nameRange = match.range(at: 2)
            guard salaryRange.location != NSNotFound, nameRange.location != NSNotFound else { continue }

            let salaryStr = nsHTML.substring(with: salaryRange)
            let name = nsHTML.substring(with: nameRange).trimmingCharacters(in: .whitespacesAndNewlines)

            guard let salary = Int(salaryStr), salary > 0 else { continue }

            let normalizedName = Self.normalizeName(name)
            // Keep the LOWER salary if a player appears multiple times —
            // the higher one is likely from a single-game showdown slate (1.5x captain inflation)
            if let existing = result[normalizedName] {
                result[normalizedName] = min(existing, salary)
            } else {
                result[normalizedName] = salary
            }
        }

        // Filter out single-game showdown salaries (captain = 1.5x inflation).
        // The min() deduplication above already handles players who appear on both
        // classic and showdown slates. This filter catches any remaining outliers that
        // are ONLY on a showdown slate (so they have no classic-price duplicate).
        // Use a conservative 1.8x multiplier on the 90th percentile — this catches
        // showdown captains (~1.5x normal) without removing legitimate star salaries
        // (NBA stars can be 1.4x the P95 in a normal distribution).
        if result.count > 10 {
            let sortedSalaries = result.values.sorted()
            let p90Index = min(sortedSalaries.count - 1, sortedSalaries.count * 90 / 100)
            let p90 = sortedSalaries[p90Index]
            let cutoff = Int(Double(p90) * 1.8)
            let filtered = result.filter { $0.value <= cutoff }
            if filtered.count < result.count {
                print("[RG-Salary] Filtered out \(result.count - filtered.count) showdown-inflated salaries (cutoff=$\(cutoff), p90=$\(p90))")
            }
            return filtered
        }

        return result
    }

    /// Normalize a player name for fuzzy matching: lowercase, remove periods/accents, trim suffixes
    static func normalizeName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        // Remove periods and extra spaces
        let cleaned = folded.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned.lowercased()
    }

    /// Look up salary for a player by ESPN name. Tries exact match first, then last-name match.
    static func lookupSalary(espnName: String, in salaryMap: [String: Int]) -> Int? {
        let normalized = normalizeName(espnName)

        // Exact match
        if let salary = salaryMap[normalized] { return salary }

        // Try without Jr/Sr suffixes (ESPN might use "Ronald Acuna Jr." vs RG "Ronald Acuna")
        let withoutSuffix = normalized
            .replacingOccurrences(of: " jr$", with: "", options: .regularExpression)
            .replacingOccurrences(of: " sr$", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ii$", with: "", options: .regularExpression)
            .replacingOccurrences(of: " iii$", with: "", options: .regularExpression)
            .replacingOccurrences(of: " iv$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if withoutSuffix != normalized, let salary = salaryMap[withoutSuffix] { return salary }

        // Try the reverse — RG name might have suffix but ESPN doesn't
        for (rgName, salary) in salaryMap {
            let rgWithoutSuffix = rgName
                .replacingOccurrences(of: " jr$", with: "", options: .regularExpression)
                .replacingOccurrences(of: " sr$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if rgWithoutSuffix == normalized { return salary }
        }

        // Last-name + first-initial match for common mismatches
        // e.g. "J.T. Realmuto" vs "JT Realmuto"
        let parts = normalized.components(separatedBy: " ")
        if parts.count >= 2 {
            let lastName = parts.last!
            let firstInitial = String(parts[0].prefix(1))
            for (rgName, salary) in salaryMap {
                let rgParts = rgName.components(separatedBy: " ")
                guard rgParts.count >= 2, rgParts.last == lastName else { continue }
                if String(rgParts[0].prefix(1)) == firstInitial { return salary }
            }
        }

        return nil
    }
}

// MARK: - MLB DFS Slate Provider

struct ESPNMLBDFSSlateProvider: DFSSlateProvider {
    private let session: URLSession
    private let cache = ESPNRosterCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        // Start fetching DraftKings salaries in parallel with ESPN data.
        // Primary source: fetchSalaries (DFF DK → RG DK fallback).
        // Secondary fallback: fetchDKMLBSalaries (DFF DK only, separate showdown validation).
        async let rgSalaries = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "mlb", maxClassicSalary: 12000)
        async let dkFallbackSalaries = RotoGrindersSalaryProvider.shared.fetchDKMLBSalaries()
        // DK eligible-positions lookup. ESPN gives us positions like "DH"
        // or "UTIL" for designated hitters and two-way players (Ohtani);
        // those don't map to any MLB main-slate slot (P/C/1B/2B/3B/SS/OF),
        // making the player undraftable. DK actually classifies Ohtani as
        // "1B/OF", so we use this map to remap our position to the first
        // valid main-slate slot.
        async let mlbPositionsTask = RotoGrindersSalaryProvider.shared.fetchLineupHQPositions(sport: "mlb")

        let events = try await fetchMLBEvents()
        guard !events.isEmpty else {
            throw NSError(domain: "DFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No MLB games found"])
        }

        // Build team abbreviation → event ID mapping.
        // Doubleheader-aware: the same two teams can play TWICE in one day.
        // The old blind overwrite pointed every roster player at whichever
        // event iterated last, so one game's showdown pool held BOTH games'
        // probables (three SPs on the BAL@BOS nightcap) with the other
        // game's prices bleeding in. Map each team to its earliest game
        // that hasn't started; once game 1 goes live/final, slate rebuilds
        // remap the roster to the nightcap.
        var teamToGameID: [String: String] = [:]
        let eventsByStart = events.sorted { $0.date < $1.date }
        for event in eventsByStart {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                let abbrev = competitor.team.abbreviation
                if let existingID = teamToGameID[abbrev] {
                    let existingState = eventsByStart.first(where: { $0.id == existingID })?
                        .competitions.first?.status.type.state ?? "pre"
                    // Keep the earlier game while it's still upcoming;
                    // advance to this one once it's underway or finished.
                    if existingState == "pre" { continue }
                    print("[MLB-DFS] Doubleheader: remapping \(abbrev) to later game \(event.id) (earlier game is \(existingState))")
                }
                teamToGameID[abbrev] = event.id
            }
        }

        // Collect probable pitcher IDs from the scoreboard, remembering
        // WHICH event each probable belongs to — in a doubleheader the
        // team-level map above can only point at one of the two games,
        // but a probable is announced for a specific game.
        var probablePitcherIDs = Set<String>()
        var probableEventByAthleteID: [String: String] = [:]
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                if let probables = competitor.probables {
                    for probable in probables {
                        if let id = probable.athlete?.id {
                            probablePitcherIDs.insert(id)
                            probableEventByAthleteID[id] = event.id
                        }
                    }
                }
            }
        }

        let teamRefs = Array(uniqueTeams(from: events).prefix(30))

        // Pre-fetch all team ratings in parallel BEFORE the roster task group
        let allRatings: [String: [String: Double]] = await withTaskGroup(of: (String, [String: Double]).self) { group in
            for team in teamRefs {
                group.addTask { @Sendable in
                    let base = "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/teams/\(team.id)/athletes/statistics"
                    let priorYear = Calendar.current.component(.year, from: Date()) - 1
                    let urls = [
                        "\(base)?season=\(priorYear)&seasontype=2",
                        base
                    ]

                    var ratings: [String: Double] = [:]
                    for (index, urlStr) in urls.enumerated() {
                        guard let url = URL(string: urlStr) else { continue }
                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode) else { continue }

                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let results = json["results"] as? [[String: Any]] else { continue }

                        let isPrimary = index == 0
                        // Track athletes seen within THIS URL to detect two-way players
                        // (same athlete appearing in both Pitching and Batting blocks).
                        // This must be per-URL to avoid cross-season confusion.
                        var seenInThisURL = Set<String>()
                        for resultBlock in results {
                            // Skip Fielding block — no fantasy-relevant stats
                            let blockName = resultBlock["name"] as? String ?? ""
                            if blockName.lowercased() == "fielding" { continue }
                            guard let leaders = resultBlock["leaders"] as? [[String: Any]] else { continue }
                            for leader in leaders {
                                guard let athlete = leader["athlete"] as? [String: Any],
                                      let athleteID = athlete["id"] as? String,
                                      let statistics = leader["statistics"] as? [[String: Any]] else { continue }

                                // Detect two-way players: same athlete in both Pitching and Batting
                                // blocks within this season's data. Use per-URL tracking so prior
                                // season data doesn't interfere.
                                let isTwoWayRepeat = seenInThisURL.contains(athleteID)
                                seenInThisURL.insert(athleteID)

                                var gamesPlayed: Double = 0
                                var hits: Double = 0, doubles: Double = 0, triples: Double = 0
                                var homeRuns: Double = 0, rbis: Double = 0, runs: Double = 0
                                var walks: Double = 0, stolenBases: Double = 0, hbp: Double = 0
                                var inningsPitched: Double = 0, strikeouts: Double = 0
                                var earnedRuns: Double = 0, wins: Double = 0
                                var isPitcher = false

                                for section in statistics {
                                    guard let stats = section["stats"] as? [[String: Any]] else { continue }
                                    for stat in stats {
                                        guard let name = stat["name"] as? String,
                                              let value = stat["value"] as? Double else { continue }
                                        switch name {
                                        case "gamesPlayed": gamesPlayed = max(gamesPlayed, value)
                                        case "hits": hits = value
                                        case "doubles": doubles = value
                                        case "triples": triples = value
                                        case "homeRuns": homeRuns = value
                                        case "RBIs": rbis = value
                                        case "runs": runs = value
                                        case "walks": walks = value
                                        case "stolenBases": stolenBases = value
                                        case "hitByPitches", "hitByPitch": hbp = value
                                        case "inningsPitched", "innings": inningsPitched = value; isPitcher = true
                                        case "strikeouts": strikeouts = value
                                        case "earnedRuns": earnedRuns = value
                                        case "wins": wins = value
                                        default: break
                                        }
                                    }
                                }

                                guard gamesPlayed > 0 else { continue }

                                let fppg: Double
                                if isPitcher && inningsPitched > 0 {
                                    let totalFP = inningsPitched * 3.0 + strikeouts * 3.0 + wins * 6.0 - earnedRuns * 3.0
                                    fppg = totalFP / gamesPlayed
                                } else {
                                    let singles = hits - doubles - triples - homeRuns
                                    let totalFP = singles * 3.0 + doubles * 6.0 + triples * 9.0 + homeRuns * 12.0
                                        + rbis * 3.0 + runs * 3.0 + walks * 3.0 + stolenBases * 6.0 + hbp * 3.0
                                    fppg = totalFP / gamesPlayed
                                }
                                if isTwoWayRepeat {
                                    // Two-way player: same athlete in both Pitching and Batting
                                    // blocks within this season. Store pitching under "-sp" key
                                    // and batting under the base key.
                                    if isPitcher && inningsPitched > 0 {
                                        // Pitching stats came second — store under -sp key
                                        ratings[athleteID + "-sp"] = fppg
                                    } else if !isPitcher {
                                        // Batting stats came second — pitching was stored under
                                        // the base key first. Move pitching to -sp and store batting.
                                        if let existingFPPG = ratings[athleteID] {
                                            ratings[athleteID + "-sp"] = existingFPPG
                                        }
                                        ratings[athleteID] = fppg
                                    }
                                } else {
                                    ratings[athleteID] = fppg
                                }
                            }
                        }
                    }
                    return (team.id, ratings)
                }
            }
            var result: [String: [String: Double]] = [:]
            for await (teamID, ratings) in group {
                result[teamID] = ratings
            }
            return result
        }
        // Fetch all rosters in parallel, passing pre-fetched ratings
        let allRosterPlayers: [DFSPlayer] = try await withThrowingTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let gameID = teamToGameID[team.abbreviation]
                if gameID == nil {
                    print("[MLB-DFS] WARNING: No gameID for team \(team.abbreviation) (id=\(team.id))")
                }
                let ratings = allRatings[team.id] ?? [:]
                group.addTask {
                    let roster = try await self.fetchMLBRoster(teamID: team.id, teamAbbreviation: team.abbreviation, gameID: gameID, ratings: ratings)
                    // Sort batters first so they aren't cut off by the roster limit
                    // (40-man rosters are pitcher-heavy; showdown needs batters)
                    let sorted = roster.sorted { a, b in
                        let aIsPitcher = ["SP", "RP", "P"].contains(a.position)
                        let bIsPitcher = ["SP", "RP", "P"].contains(b.position)
                        if aIsPitcher != bIsPitcher { return !aIsPitcher }
                        return a.projectedPoints > b.projectedPoints
                    }
                    return Array(sorted.prefix(40))
                }
            }
            var allPlayers: [DFSPlayer] = []
            for try await roster in group {
                allPlayers.append(contentsOf: roster)
            }
            return allPlayers
        }

        // Fetch batting orders from game summaries in parallel, keyed PER
        // EVENT. A flat cross-game merge stamped doubleheader players with
        // GAME 1's posted lineup while their pool entry belonged to the
        // nightcap — orders showed for a game whose lineups weren't out.
        let gameIDs = Set(events.map { $0.id })
        let battingOrdersByGame: [String: [String: Int]] = await withTaskGroup(of: (String, [String: Int]).self) { group in
            for gameID in gameIDs {
                group.addTask { @Sendable in
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/summary?event=\(gameID)") else { return (gameID, [:]) }
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else { return (gameID, [:]) }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let rosters = json["rosters"] as? [[String: Any]] else { return (gameID, [:]) }

                    var orders: [String: Int] = [:]
                    for teamRoster in rosters {
                        let rosterPlayers = teamRoster["roster"] as? [[String: Any]] ?? []
                        for player in rosterPlayers {
                            let starter = (player["starter"] as? Bool) ?? ((player["starter"] as? Int) == 1)
                            let batOrder = player["batOrder"] as? Int ?? 0
                            guard starter, batOrder > 0 else { continue }
                            if let athlete = player["athlete"] as? [String: Any],
                               let athleteID = athlete["id"] as? String {
                                orders[athleteID] = batOrder
                            }
                        }
                    }
                    return (gameID, orders)
                }
            }
            var result: [String: [String: Int]] = [:]
            for await (gameID, orders) in group where !orders.isEmpty {
                result[gameID] = orders
            }
            return result
        }

        // Apply batting orders to players — only from the player's OWN game.
        let playersWithOrders: [DFSPlayer] = allRosterPlayers.map { player in
            let espnID = String(player.id.dropFirst(4)) // remove "mlb-"
            guard let gid = player.gameID,
                  let order = battingOrdersByGame[gid]?[espnID] else { return player }
            var updated = player
            updated.battingOrder = order
            return updated
        }

        // Keep only the day's probable pitchers; drop every other arm.
        // IMPORTANT: check the probables list BEFORE the roster position —
        // spot starters (e.g. Tyler Phillips) are listed as "RP" on ESPN's
        // team roster even when they're the announced probable, and the old
        // "drop all RPs first" order silently removed them from the slate.
        // Probables listed as RP are relabeled SP so every downstream
        // consumer (P slot, single-game pools, pitcher pricing) treats them
        // as the starter they are that day.
        var filtered = playersWithOrders.compactMap { player -> DFSPlayer? in
            guard player.position == "SP" || player.position == "RP" else {
                return player // all position players pass
            }
            // Extract the ESPN athlete ID from the DFS player ID (format: "mlb-{id}")
            let espnID = String(player.id.dropFirst(4)) // remove "mlb-"
            guard probablePitcherIDs.contains(espnID) else { return nil }
            guard player.position == "RP" else { return player }
            var relabeled = DFSPlayer(
                id: player.id, name: player.name, team: player.team,
                position: "SP", salary: player.salary,
                projectedPoints: player.projectedPoints,
                gameID: player.gameID, injuryStatus: player.injuryStatus,
                battingOrder: player.battingOrder
            )
            relabeled.isConfirmedActive = player.isConfirmedActive
            relabeled.gamesPlayed = player.gamesPlayed
            relabeled.playedRecently = player.playedRecently
            print("[MLB-DFS] Probable starter \(player.name) listed as RP on roster — relabeled SP")
            return relabeled
        }

        // Two-way player handling: create separate batter + pitcher entries for players
        // who both bat AND pitch. This handles players like Ohtani who have two FanDuel entries.
        //
        // Case 1: Player's ESPN position is a batter position (DH/UTIL/OF) but they're also
        //          a probable pitcher → create a new SP entry (mlb-{id}-sp).
        // Case 2: Player's ESPN position is "SP" but they also have a batting order (DH slot)
        //          → change existing entry to batter (UTIL) and create SP entry (mlb-{id}-sp).
        //
        // Build a flat map of all pitching ratings (stored under "{id}-sp" keys)
        let pitchingRatings: [String: Double] = {
            var result: [String: Double] = [:]
            for (_, teamRatings) in allRatings {
                for (key, value) in teamRatings where key.hasSuffix("-sp") {
                    let baseID = String(key.dropLast(3)) // remove "-sp"
                    result[baseID] = value
                }
            }
            return result
        }()
        // Build a lookup of batting FPPG for players who have both batting and pitching ratings.
        // This identifies two-way players even before lineups are posted.
        let batterRatings: [String: Double] = {
            var result: [String: Double] = [:]
            for (_, teamRatings) in allRatings {
                for (key, value) in teamRatings where !key.hasSuffix("-sp") {
                    // Only include if there's also a -sp entry (two-way player)
                    if teamRatings[key + "-sp"] != nil {
                        result[key] = value
                    }
                }
            }
            return result
        }()
        // Augment probable pitchers with KNOWN two-way players (both a batting and
        // an `-sp` pitching season rating) whom DraftKings lists as a pitcher today.
        // ESPN's scoreboard `probables` intermittently omits a two-way starter
        // (Ohtani) — when it does, neither two-way branch below fires, so he was
        // built as ONE entry (the batter, wrongly stamped with his $10k+ DK PITCHER
        // price and no SP half). DK's own position feed is the reliable "he's
        // pitching today" signal and avoids a phantom SP on his DH-only days.
        let mlbDKPositions = await mlbPositionsTask
        for espnID in batterRatings.keys where !probablePitcherIDs.contains(espnID) {
            guard let name = filtered.first(where: { $0.id == "mlb-\(espnID)" })?.name else { continue }
            let dkPos = (mlbDKPositions[RotoGrindersSalaryProvider.normalizeName(name)] ?? "").uppercased()
            if dkPos.contains("SP") || dkPos.contains("RP") || dkPos == "P" {
                probablePitcherIDs.insert(espnID)
                print("[MLB-DFS] Augmented probables: two-way \(name) listed by DK as \(dkPos) — building pitcher half")
            }
        }
        // Track indices of SP players who need to be converted to batter entries
        var spToBatterIndices: [Int] = []
        for (index, player) in filtered.enumerated() {
            let espnID = String(player.id.dropFirst(4)) // remove "mlb-"
            guard probablePitcherIDs.contains(espnID) else { continue }
            
            if player.position == "SP" {
                // Case 2: ESPN lists them as SP but they're also a batter (two-way player).
                // The signal must separate a REAL two-way HITTER (Ohtani ~9-11 batting
                // FPPG) from a pitcher who merely logged a few plate appearances
                // (Colin Rea, ~5-7 — a false positive that put a phantom batter half
                // in the pool). Two tiers:
                //   • Elite batting FPPG (> 7.5): unmistakably a two-way hitter — accept
                //     even before the batting order posts (Ohtani's order isn't out until
                //     ~gametime on the days he starts; requiring it left him pitcher-only).
                //   • Moderate (5–7.5): only a two-way if he's ALSO in today's batting
                //     order — a pitcher-who-bats won't be (universal DH), so Rea is
                //     excluded until proven otherwise.
                let batterFPPG = batterRatings[espnID] ?? 0
                let isTwoWay = batterFPPG > 7.5 || (batterFPPG > 5.0 && player.battingOrder != nil)
                guard isTwoWay else { continue }
                spToBatterIndices.append(index)
            } else {
                // Case 1: Batter position but also a probable pitcher — standard two-way detection
                // (no action needed here, handled below)
            }
            
            // Create the SP entry for both cases
            let spFPPG = pitchingRatings[espnID] ?? 25.0 // fallback: decent SP
            let spSalary = mlbEstimatedSalary(fppg: spFPPG, position: "SP", playerID: espnID)
            let spProjection = mlbProjectedPoints(fppg: spFPPG, position: "SP", playerID: espnID)
            let spEntry = DFSPlayer(
                id: "mlb-\(espnID)-sp",
                name: player.name,
                team: player.team,
                position: "SP",
                salary: spSalary,
                projectedPoints: spProjection,
                gameID: player.gameID,
                injuryStatus: player.injuryStatus
            )
            filtered.append(spEntry)
            print("[MLB-DFS] Two-way player \(player.name): batter (\(player.position) $\(player.salary)) + pitcher (SP $\(spSalary), \(String(format: "%.1f", spProjection)) FPTS)")
        }
        // Convert the SP-listed entry into the BATTER half for two-way players
        // (Case 2). Type it 1B — MLB classic has no UTIL slot, and DK classifies
        // Ohtani as 1B/OF — so the batter is directly draftable/slottable and the
        // `mlb-X` id ALWAYS means the batter (its `mlb-X-sp` sibling is the pitcher).
        for index in spToBatterIndices {
            let player = filtered[index]
            let espnID = String(player.id.dropFirst(4))
            let batterFPPG = batterRatings[espnID] ?? 10.0 // fallback: decent DH batter
            let batterSalary = mlbEstimatedSalary(fppg: batterFPPG, position: "1B", playerID: espnID)
            let batterProjection = mlbProjectedPoints(fppg: batterFPPG, position: "1B", playerID: espnID)
            filtered[index] = DFSPlayer(
                id: player.id,
                name: player.name,
                team: player.team,
                position: "1B",
                salary: batterSalary,
                projectedPoints: batterProjection,
                gameID: player.gameID,
                injuryStatus: player.injuryStatus,
                battingOrder: player.battingOrder
            )
            print("[MLB-DFS] Two-way player \(player.name): converted SP → 1B batter ($\(batterSalary), \(String(format: "%.1f", batterProjection)) FPTS)")
        }

        let deduped = deduplicatePlayers(filtered)
        guard !deduped.isEmpty else {
            throw NSError(domain: "DFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No MLB players available"])
        }

        // Apply real DraftKings salaries from DFF/RotoGrinders.
        // Players with DK prices get real salaries; the rest keep estimated salaries.
        // ALL players are included so the slate covers every game today (all-day slate).
        // When a price is detected as single-game inflated, fall back to DFF DK price.
        let realSalaries = await rgSalaries
        let dkFallback = await dkFallbackSalaries
        // mlbDKPositions already awaited above (probable-pitcher augmentation).
        // Main-slate slots MLB can fill. Anything else (DH, UTIL, unknown)
        // gets remapped from DK's eligible-positions string if available.
        let mlbValidPositions: Set<String> = ["P", "SP", "RP", "C", "1B", "2B", "3B", "SS", "OF"]
        func remappedMLBPosition(forESPNPosition espnPos: String, playerName: String) -> String {
            if mlbValidPositions.contains(espnPos) { return espnPos }
            // ESPN gave us DH/UTIL/etc — look up DK's eligible positions.
            // Example DK value: "1B/OF". Pick the first slash-separated
            // token that's a valid main-slate slot.
            let normalized = RotoGrindersSalaryProvider.normalizeName(playerName)
            guard let dkPos = mlbDKPositions[normalized] else { return espnPos }
            let tokens = dkPos.split(separator: "/").map { String($0).uppercased() }
            for token in tokens where mlbValidPositions.contains(token) {
                print("[MLB-DFS] Position remap: \(playerName) ESPN=\(espnPos) DK=\(dkPos) → \(token)")
                return token
            }
            return espnPos
        }
        let finalPlayers: [DFSPlayer]
        if !realSalaries.isEmpty || !dkFallback.isEmpty {
            // DK MLB main-slate caps: batters top ~$6.5K, pitchers top ~$13K.
            // Single-game slates inflate batters to $9K-$16K.
            let mlbBatterMaxSalary = 7500
            let mlbPitcherMaxSalary = 14000
            // Identify two-way batter entries: players who have a corresponding "-sp" entry.
            // Salary feeds only have ONE price per player (the pitcher price), so these
            // batter entries must keep their estimated batter salary.
            let twoWayBatterIDs: Set<String> = {
                let spIDs = Set(deduped.filter { $0.id.hasSuffix("-sp") }.map { String($0.id.dropLast(3)) })
                return spIDs
            }()
            var result: [DFSPlayer] = []
            var matchCount = 0
            var dkFallbackCount = 0
            for player in deduped {
                // Two-way batter entry: salary feeds only have the pitcher price for this player.
                // Keep the estimated batter salary instead of applying the pitcher price.
                // NOTE: `twoWayBatterIDs` holds only the BASE id (the batter); the
                // pitcher is the "-sp" sibling, which is NOT in this set. So this
                // branch only ever matches the batter half. We must remap it to a
                // batter slot EVEN IF it's currently typed "SP" — when the two-way
                // conversion left it as SP (or the day's DK feed lists Ohtani only
                // as a pitcher), the old `!= "SP"` guard skipped it, leaving the
                // batter stuck as a second SP that can't fill 1B in late swap.
                if twoWayBatterIDs.contains(player.id) {
                    // The generic remap can't be used here: on days the player
                    // pitches, the DK feed lists him only as "SP" (Ohtani), which
                    // would turn the batter entry back into a pitcher. Accept only
                    // batter tokens from DK; if none, fall back to 1B (DK
                    // classifies Ohtani as "1B/OF") — a raw UTIL/DH/SP position fits
                    // no main-slate batter slot and leaves the entry undraftable.
                    let batterTokens: Set<String> = ["C", "1B", "2B", "3B", "SS", "OF"]
                    var batterPos = player.position
                    if !batterTokens.contains(batterPos) {
                        let normalized = RotoGrindersSalaryProvider.normalizeName(player.name)
                        let dkTokens = (mlbDKPositions[normalized] ?? "").split(separator: "/").map { String($0).uppercased() }
                        batterPos = dkTokens.first(where: { batterTokens.contains($0) }) ?? "1B"
                    }
                    if batterPos != player.position {
                        var remapped = DFSPlayer(
                            id: player.id, name: player.name, team: player.team,
                            position: batterPos, salary: player.salary,
                            projectedPoints: player.projectedPoints,
                            gameID: player.gameID, injuryStatus: player.injuryStatus,
                            battingOrder: player.battingOrder
                        )
                        remapped.isConfirmedActive = player.isConfirmedActive
                        result.append(remapped)
                        print("[MLB-DFS] Two-way batter \(player.name): \(player.position) → \(batterPos), keeping estimated $\(player.salary)")
                    } else {
                        result.append(player)
                        print("[MLB-DFS] Two-way batter \(player.name) (\(player.position)): keeping estimated $\(player.salary) (salary feeds only have pitcher price)")
                    }
                    continue
                }
                let remappedPos = remappedMLBPosition(forESPNPosition: player.position, playerName: player.name)
                if let realSalary = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: realSalaries) {
                    let isPitcher = remappedPos == "SP" || remappedPos == "RP" || remappedPos == "P"
                    let maxAllowed = isPitcher ? mlbPitcherMaxSalary : mlbBatterMaxSalary
                    if realSalary > maxAllowed {
                        // Price is from single-game slate — try DFF DK fallback instead
                        if let dkPrice = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: dkFallback) {
                            var matched = DFSPlayer(
                                id: player.id, name: player.name, team: player.team,
                                position: remappedPos, salary: dkPrice,
                                projectedPoints: player.projectedPoints,
                                gameID: player.gameID, injuryStatus: player.injuryStatus,
                                battingOrder: player.battingOrder
                            )
                            matched.isConfirmedActive = true
                            result.append(matched)
                            dkFallbackCount += 1
                            print("[MLB-DFS] Showdown price rejected for \(player.name) (\(remappedPos)): $\(realSalary) → DK fallback $\(dkPrice)")
                        } else {
                            // No DK fallback available — keep estimated salary
                            print("[MLB-DFS] Showdown price rejected for \(player.name) (\(remappedPos)): $\(realSalary) → estimated $\(player.salary)")
                            var keptOriginal = player
                            if remappedPos != player.position {
                                keptOriginal = DFSPlayer(
                                    id: player.id, name: player.name, team: player.team,
                                    position: remappedPos, salary: player.salary,
                                    projectedPoints: player.projectedPoints,
                                    gameID: player.gameID, injuryStatus: player.injuryStatus,
                                    battingOrder: player.battingOrder
                                )
                            }
                            result.append(keptOriginal)
                        }
                    } else {
                        var matched = DFSPlayer(
                            id: player.id, name: player.name, team: player.team,
                            position: remappedPos, salary: realSalary,
                            projectedPoints: player.projectedPoints,
                            gameID: player.gameID, injuryStatus: player.injuryStatus,
                            battingOrder: player.battingOrder
                        )
                        matched.isConfirmedActive = true
                        result.append(matched)
                        matchCount += 1
                    }
                } else if let dkPrice = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: dkFallback) {
                    // No primary DK price but DFF fallback available
                    var matched = DFSPlayer(
                        id: player.id, name: player.name, team: player.team,
                        position: remappedPos, salary: dkPrice,
                        projectedPoints: player.projectedPoints,
                        gameID: player.gameID, injuryStatus: player.injuryStatus,
                        battingOrder: player.battingOrder
                    )
                    matched.isConfirmedActive = true
                    result.append(matched)
                    dkFallbackCount += 1
                } else {
                    // No real salary data at all — keep estimated, but
                    // still remap the position so UTIL/DH players are
                    // draftable in their DK-eligible main-slate slot.
                    if remappedPos != player.position {
                        var repositioned = DFSPlayer(
                            id: player.id, name: player.name, team: player.team,
                            position: remappedPos, salary: player.salary,
                            projectedPoints: player.projectedPoints,
                            gameID: player.gameID, injuryStatus: player.injuryStatus,
                            battingOrder: player.battingOrder
                        )
                        repositioned.isConfirmedActive = player.isConfirmedActive
                        result.append(repositioned)
                    } else {
                        result.append(player)
                    }
                }
            }
            finalPlayers = result
            let salaryRange = result.filter { $0.isConfirmedActive }.map { $0.salary }
            let estimatedCount = result.count - matchCount - dkFallbackCount
            var logMsg = "[MLB-DFS] All-day slate: \(matchCount) DK prices, \(dkFallbackCount) DK-fallback"
            if estimatedCount > 0 { logMsg += ", \(estimatedCount) estimated" }
            if !salaryRange.isEmpty { logMsg += " (range $\(salaryRange.min() ?? 0)-$\(salaryRange.max() ?? 0))" }
            print(logMsg)
        } else {
            throw NSError(domain: "MLBDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's MLB slate"])
        }

        let slateDate = events.first?.date ?? Date()
        let tournamentID = "mlb-\(dateKey(for: slateDate))"
        let sortedPlayers = finalPlayers.sorted(by: { $0.salary > $1.salary })

        // Log per-game player counts for single-game diagnostics
        let nilGameCount = sortedPlayers.filter { $0.gameID == nil }.count
        if nilGameCount > 0 {
            print("[MLB-DFS] WARNING: \(nilGameCount)/\(sortedPlayers.count) players have nil gameID — they won't appear in single-game contests")
        }

        let includedGames: [DFSSlateGame] = events.compactMap { event -> DFSSlateGame? in
            guard let competition = event.competitions.first else { return nil }
            // Filter out postponed, suspended, cancelled games — they shouldn't
            // appear in single-game options or contribute players to the slate.
            let gameState = competition.status.type.state.lowercased()
            let detail = (competition.status.type.detail ?? "").lowercased()
            if gameState == "postponed" || gameState == "suspended" || gameState == "canceled" || gameState == "cancelled" {
                let away = competition.competitors.first(where: { $0.homeAway == "away" })?.team.abbreviation ?? "?"
                let home = competition.competitors.first(where: { $0.homeAway == "home" })?.team.abbreviation ?? "?"
                print("[MLB-DFS] Excluding \(away) @ \(home) (event \(event.id)): game is \(gameState)")
                return nil
            }
            if detail.contains("postpone") || detail.contains("suspend") || detail.contains("cancel") {
                let away = competition.competitors.first(where: { $0.homeAway == "away" })?.team.abbreviation ?? "?"
                let home = competition.competitors.first(where: { $0.homeAway == "home" })?.team.abbreviation ?? "?"
                print("[MLB-DFS] Excluding \(away) @ \(home) (event \(event.id)): \(detail)")
                return nil
            }
            guard let away = competition.competitors.first(where: { $0.homeAway == "away" }) else { return nil }
            guard let home = competition.competitors.first(where: { $0.homeAway == "home" }) else { return nil }
            return DFSSlateGame(
                id: event.id,
                awayTeam: away.team.abbreviation,
                homeTeam: home.team.abbreviation,
                startTime: event.date,
                state: competition.status.type.state
            )
        }

        // Also remove players from postponed games so they don't inflate the main-slate pool
        let validGameIDs = Set(includedGames.map(\.id))
        var sortedPlayersFiltered = sortedPlayers.filter { p in
            guard let gid = p.gameID else { return true } // keep players without gameID
            return validGameIDs.contains(gid)
        }
        if sortedPlayersFiltered.count < sortedPlayers.count {
            print("[MLB-DFS] Removed \(sortedPlayers.count - sortedPlayersFiltered.count) players from postponed/excluded games")
        }

        // Doubleheader: stamp each probable SP with HIS game's event ID.
        // The team-level map assigns the whole roster to one of the two
        // games, which put both games' starters in the same showdown pool.
        sortedPlayersFiltered = sortedPlayersFiltered.map { player in
            guard player.position == "SP" else { return player }
            let rawID = String(player.id.dropFirst(4))                 // strip "mlb-"
            let athleteID = rawID.hasSuffix("-sp") ? String(rawID.dropLast(3)) : rawID
            guard let eventID = probableEventByAthleteID[athleteID],
                  validGameIDs.contains(eventID),
                  player.gameID != eventID else { return player }
            var updated = player
            updated.gameID = eventID
            print("[MLB-DFS] Doubleheader: \(player.name) assigned to his own game \(eventID)")
            return updated
        }

        // Phase 2: pull showdown salaries from RG's slate-specific JSON,
        // PER GAME. A globally-merged map (every MLB showdown that day in one
        // dict) collides on common names: with the fuzzy first-initial+last-
        // name fallback in lookupSalary, star "Julio Rodriguez" (SEA) matched
        // a cheap "J. Rodriguez" from a different game and priced at $3,400.
        // Scoping each game to its own slate eliminates the cross-game bleed;
        // the in-app `mlbShowdownSalary()` curve still runs as a fallback for
        // players RG doesn't list.
        let mlbPerGameShowdownSalaries: [String: [String: Int]] = await {
            await withTaskGroup(of: (String, [String: Int]).self) { group in
                for game in includedGames {
                    group.addTask {
                        let salaries = await RotoGrindersSalaryProvider.shared.fetchShowdownSalariesForGame(
                            sport: "mlb",
                            awayHashtag: game.awayTeam,
                            homeHashtag: game.homeTeam,
                            startTime: game.startTime
                        )
                        return (game.id, salaries)
                    }
                }
                var byGame: [String: [String: Int]] = [:]
                for await (gameID, salaries) in group where !salaries.isEmpty {
                    byGame[gameID] = salaries
                }
                return byGame
            }
        }()

        // A 1-game MLB day (All-Star break, weather wipeouts) gets ONLY the
        // showdown contest, same as every other sport — a 10-player classic
        // slate drawn from two teams is redundant with the single game.
        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: "MLB",
            mainSalaryCap: 50000,
            mainLineupSize: 10,
            mainRosterSlots: ["P", "P", "C", "1B", "2B", "3B", "SS", "OF", "OF", "OF"],
            isSingleGameSlate: includedGames.count == 1,
            includedGames: includedGames,
            mainPlayers: sortedPlayersFiltered,
            perGameShowdownSalaries: mlbPerGameShowdownSalaries.isEmpty ? nil : mlbPerGameShowdownSalaries
        )

        let slate = DFSSlate(
            tournaments: tournaments,
            includedGames: includedGames,
            players: sortedPlayersFiltered,
            singleGamePlayers: sgPlayers
        )
        return slate
    }

    // MARK: - ESPN MLB API

    private func fetchMLBEvents() async throws -> [NBAScoreboardEvent] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let dateKeys = [dateKey(for: yesterday), dateKey(for: Date()), dateKey(for: tomorrow)]

        let allScoreboards: [NBAScoreboardResponse] = await withTaskGroup(of: NBAScoreboardResponse?.self) { group in
            for dk in dateKeys {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?dates=\(dk)") else {
                        return nil
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return nil
                    }
                    return try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data)
                }
            }
            var results: [NBAScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var preEvents: [NBAScoreboardEvent] = []
        var liveEvents: [NBAScoreboardEvent] = []
        var postEvents: [NBAScoreboardEvent] = []

        for scoreboard in allScoreboards {
            for event in scoreboard.events {
                guard let competition = event.competitions.first else { continue }
                let state = competition.status.type.state
                if state == "pre" && calendar.startOfDay(for: event.date) >= today {
                    preEvents.append(event)
                } else if state == "in" {
                    liveEvents.append(event)
                } else if state == "post" {
                    postEvents.append(event)
                }
            }
        }

        // If there are live games, include them AND finished games from the same slate day
        if !liveEvents.isEmpty {
            let liveDay = calendar.startOfDay(for: liveEvents.first!.date)
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            return (liveEvents + sameDayPost + sameDayPre).sorted(by: { $0.date < $1.date })
        }

        // All-day slate: if there are finished (post) games from the same day as upcoming
        // (pre) games, include BOTH so the slate doesn't shrink when early games finish
        // before late games start (e.g. 1pm game ends, 7pm games haven't started).
        if !preEvents.isEmpty {
            let groupedByDay = Dictionary(grouping: preEvents) { calendar.startOfDay(for: $0.date) }

            // Prefer today's slate if it has games
            if let todayGames = groupedByDay[today], !todayGames.isEmpty {
                let todaysPost = postEvents.filter { calendar.startOfDay(for: $0.date) == today }
                return (todayGames + todaysPost).sorted(by: { $0.date < $1.date })
            }

            // Otherwise pick the earliest upcoming day, including any finished games from that day
            if let selectedDay = groupedByDay.keys.sorted().first {
                let sameDayPre = groupedByDay[selectedDay] ?? []
                let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == selectedDay }
                return (sameDayPre + sameDayPost).sorted(by: { $0.date < $1.date })
            }
            return preEvents
        }

        // No live or pre games — return today's finished (post) games
        if !postEvents.isEmpty {
            let todaysPost = postEvents.filter { calendar.startOfDay(for: $0.date) == today }
            if !todaysPost.isEmpty {
                return todaysPost.sorted(by: { $0.date < $1.date })
            }
            let groupedByDay = Dictionary(grouping: postEvents) { calendar.startOfDay(for: $0.date) }
            if let mostRecentDay = groupedByDay.keys.sorted().last {
                return (groupedByDay[mostRecentDay] ?? []).sorted(by: { $0.date < $1.date })
            }
        }

        return []
    }

    private func uniqueTeams(from events: [NBAScoreboardEvent]) -> [NBATeamRef] {
        var seen = Set<String>()
        var result: [NBATeamRef] = []
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                let id = competitor.team.id
                guard seen.insert(id).inserted else { continue }
                result.append(NBATeamRef(id: id, abbreviation: competitor.team.abbreviation))
            }
        }
        return result
    }

    private func fetchMLBRoster(teamID: String, teamAbbreviation: String, gameID: String?, ratings: [String: Double]) async throws -> [DFSPlayer] {
        let fppgRatings = ratings

        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/teams/\(teamID)/roster") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        // MLB roster API returns categories (Pitchers, Catchers, etc.) with nested items
        let athletes: [NBARosterAthlete]
        if let mlbRoster = try? JSONDecoder().decode(MLBRosterResponse.self, from: data) {
            athletes = mlbRoster.allAthletes
        } else if let flatRoster = try? JSONDecoder().decode(NBARosterResponse.self, from: data) {
            athletes = flatRoster.athletes
        } else {
            return []
        }

        let players = athletes.map { athlete in
            let position = mapMLBPosition(athlete.position?.abbreviation)
            let fppg = fppgRatings[athlete.id] ?? 0.0
            let salary = mlbEstimatedSalary(fppg: fppg, position: position, playerID: athlete.id)
            let projection = mlbProjectedPoints(fppg: fppg, position: position, playerID: athlete.id)

            let injuryStatus: String?
            if let injury = athlete.injuries?.first, let status = injury.status {
                switch status.lowercased() {
                case "out": injuryStatus = "O"
                case "day-to-day": injuryStatus = "GTD"
                case "10-day-il": injuryStatus = "IL10"
                case "15-day-il": injuryStatus = "IL15"
                case "60-day-il": injuryStatus = "IL60"
                default: injuryStatus = nil
                }
            } else {
                injuryStatus = nil
            }

            return DFSPlayer(
                id: "mlb-\(athlete.id)",
                name: athlete.fullName,
                team: teamAbbreviation,
                position: position,
                salary: salary,
                projectedPoints: projection,
                gameID: gameID,
                injuryStatus: injuryStatus
            )
        }
        .sorted { $0.projectedPoints > $1.projectedPoints }

        return players
    }

    /// Maps ESPN MLB position abbreviations to DFS-style positions
    private func mapMLBPosition(_ raw: String?) -> String {
        guard let raw else { return "UTIL" }
        switch raw.uppercased() {
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
    }

    /// DraftKings MLB main-slate salary mapping ($50K cap, 10-man lineup)
    /// Based on DK pricing: top batters ~$5,500-$6,500, catchers ~$3,000-$4,500,
    /// ace pitchers ~$10,000-$13,000, mid-rotation ~$7,000-$9,500.
    private func mlbEstimatedSalary(fppg: Double, position: String, playerID: String) -> Int {
        let isPitcher = position == "SP" || position == "RP"

        // Stable hash for per-player jitter and unknown-player distribution
        let stableHash = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let hashFraction = Double(abs(stableHash % 1000)) / 1000.0 // 0.0 - 0.999

        let salary: Int
        if fppg <= 0 {
            // No stats — distribute across a realistic range using player hash
            if isPitcher {
                // Unknown pitcher: $7,000 - $8,500
                salary = Int(7000.0 + 1500.0 * hashFraction)
            } else {
                // Unknown batter: $2,500 - $3,200
                salary = Int(2500.0 + 700.0 * hashFraction)
            }
        } else if isPitcher {
            // DraftKings MLB pitcher salary tiers
            // Ace (FPPG 35+)        → $10,500 - $13,000
            // Good starter (25-35)  → $8,500 - $10,500
            // Mid-rotation (18-25)  → $7,000 - $8,500
            // Back-end (<18)        → $6,000 - $7,000
            if fppg >= 35 {
                let fraction = min(1.0, (fppg - 35.0) / 15.0)
                salary = 10500 + Int(fraction * 2500.0)
            } else if fppg >= 25 {
                let fraction = (fppg - 25.0) / 10.0
                salary = 8500 + Int(fraction * 2000.0)
            } else if fppg >= 18 {
                let fraction = (fppg - 18.0) / 7.0
                salary = 7000 + Int(fraction * 1500.0)
            } else {
                salary = 6000 + Int(max(0, fppg) / 18.0 * 1000.0)
            }
        } else {
            // DraftKings MLB batter salary tiers — calibrated to DK $50K main slate pricing
            // On DK MLB: Judge ~$6,200, good starters ~$4,500-$5,500, catchers ~$3,000-$4,500
            // MVP-tier (FPPG 13+)   → $5,500 - $6,500  (Judge, Ohtani, Soto)
            // Elite (FPPG 11-13)    → $4,800 - $5,500  (top ~15 batters)
            // Good (9-11)           → $4,000 - $4,800  (solid everyday starters)
            // Average (7-9)         → $3,200 - $4,000  (platoon/average)
            // Below avg (5-7)       → $2,700 - $3,200  (bench bats, low upside)
            // Low (<5)              → $2,200 - $2,700  (minimum salary)
            if fppg >= 13 {
                let fraction = min(1.0, (fppg - 13.0) / 4.0)
                salary = 5500 + Int(fraction * 1000.0)
            } else if fppg >= 11 {
                let fraction = (fppg - 11.0) / 2.0
                salary = 4800 + Int(fraction * 700.0)
            } else if fppg >= 9 {
                let fraction = (fppg - 9.0) / 2.0
                salary = 4000 + Int(fraction * 800.0)
            } else if fppg >= 7 {
                let fraction = (fppg - 7.0) / 2.0
                salary = 3200 + Int(fraction * 800.0)
            } else if fppg >= 5 {
                let fraction = (fppg - 5.0) / 2.0
                salary = 2700 + Int(fraction * 500.0)
            } else {
                salary = 2200 + Int(max(0, fppg) / 5.0 * 500.0)
            }
        }

        // Stable per-player jitter (±100) for variety, then round to $100 like DraftKings
        let jitter = abs(stableHash % 200) - 100
        let raw = max(2200, min(13000, salary + jitter))
        return (raw / 100) * 100
    }

    /// MLB projected points (FanDuel scoring): FPPG with mild regression to mean
    private func mlbProjectedPoints(fppg: Double, position: String, playerID: String) -> Double {
        // FanDuel-era averages (3x inflated scoring)
        let positionAvg: Double
        switch position {
        case "SP": positionAvg = 30.0   // good SP averages ~30 FD pts
        case "C": positionAvg = 8.0
        case "SS": positionAvg = 11.0
        default: positionAvg = 10.0     // typical batter
        }
        if fppg <= 0 {
            // No stats — use position average with some per-player variation
            let stableHash = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
            let variation = Double(abs(stableHash % 60)) / 10.0 - 3.0 // -3.0 to +3.0
            return max(1.0, (positionAvg + variation) * 10).rounded() / 10
        }
        let projected = fppg * 0.85 + positionAvg * 0.15
        return (projected * 10).rounded() / 10
    }

    private func deduplicatePlayers(_ players: [DFSPlayer]) -> [DFSPlayer] {
        var seen = Set<String>()
        return players.filter { seen.insert($0.id).inserted }
    }

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - MLB Live Scoring Provider

struct ESPNMLBDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }

    private struct GameFetchResult: Sendable {
        let gameID: String
        let gameInfo: DFSGameLiveInfo
        let playerResults: [(String, Double, DFSPlayerLiveStats)]
        let isFinal: Bool
    }

    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        // Return cached snapshot if recent enough and for the same set of games
        let gameIDs = Set(games.map { $0.id })
        if let cached = LiveScoreCache.shared.get(gameIDs: gameIDs) {
            return cached
        }

        let results: [GameFetchResult] = await withTaskGroup(of: GameFetchResult?.self) { group in
            for game in games {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/summary?event=\(game.id)") else {
                        return nil
                    }

                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        print("[MLB-Score] Failed to fetch summary for event \(game.id)")
                        return nil
                    }

                    let rawGameInfo = self.extractGameLiveInfo(payload: payload, game: game)

                    // Detect postponed/suspended games from ESPN status description
                    var isPostponed = false
                    if let header = payload["header"] as? [String: Any],
                       let competitions = header["competitions"] as? [[String: Any]],
                       let competition = competitions.first,
                       let status = competition["status"] as? [String: Any],
                       let typeInfo = status["type"] as? [String: Any],
                       let desc = typeInfo["description"] as? String {
                        let d = desc.lowercased()
                        if d.contains("postpone") || d.contains("suspend") || d.contains("cancel") {
                            isPostponed = true
                        }
                    }

                    // Rebuild gameInfo with the postponed flag so downstream
                    // (settlement, live header) can render "PPD" and grade
                    // the contest as a push instead of stranding it.
                    let gameInfo = DFSGameLiveInfo(
                        id: rawGameInfo.id,
                        awayTeam: rawGameInfo.awayTeam,
                        homeTeam: rawGameInfo.homeTeam,
                        awayScore: rawGameInfo.awayScore,
                        homeScore: rawGameInfo.homeScore,
                        clock: rawGameInfo.clock,
                        period: rawGameInfo.period,
                        state: rawGameInfo.state,
                        inningHalf: rawGameInfo.inningHalf,
                        sportType: rawGameInfo.sportType,
                        isPostponed: isPostponed
                    )
                    // Treat postponed games as final for snapshot purposes —
                    // there's no further state to wait for, and we want
                    // settlement to fire and grade the contest as a push.
                    let gameFinal = gameInfo.state == "post" || isPostponed

                    // Skip player stat extraction for games that haven't started,
                    // are delayed, or are postponed — ESPN may return season/projected
                    // stats that shouldn't count as real per-game scores.
                    let playerResults: [(String, Double, DFSPlayerLiveStats)]
                    if gameInfo.state == "pre" || gameInfo.state == "delayed" || isPostponed {
                        if isPostponed {
                            print("[MLB-Score] Game \(game.id) (\(game.awayTeam)@\(game.homeTeam)): POSTPONED/SUSPENDED — skipping stats, marking final for push grading")
                        }
                        playerResults = []
                    } else {
                        playerResults = self.extractMLBPlayerStats(payload: payload, gameStatus: gameInfo.displayStatus, gameFinal: gameFinal)
                    }
                    print("[MLB-Score] Game \(game.id) (\(game.awayTeam)@\(game.homeTeam)): state=\(gameInfo.state), \(playerResults.count) players scored, final=\(gameFinal), postponed=\(isPostponed)")

                    return GameFetchResult(
                        gameID: game.id,
                        gameInfo: gameInfo,
                        playerResults: playerResults,
                        isFinal: gameFinal
                    )
                }
            }

            var collected: [GameFetchResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfoByID: [String: DFSGameLiveInfo] = [:]

        let fetchedGameIDs = Set(results.map { $0.gameID })
        let failedGames = games.filter { !fetchedGameIDs.contains($0.id) }
        // Consider all games final if every successfully-fetched game is final
        // and we fetched at least half the slate. A few transient API failures
        // shouldn't block settlement when we have enough data.
        var allFetchedAreFinal = true

        for result in results {
            gameLiveInfoByID[result.gameID] = result.gameInfo
            if !result.isFinal { allFetchedAreFinal = false }
            for (playerID, fantasy, stats) in result.playerResults {
                pointsByPlayerID[playerID] = fantasy
                statsByPlayerID[playerID] = stats
            }
        }

        // A game we couldn't fetch is NOT assumed done unless its start is long
        // past (a broken/stale event). ESPN endpoints 404 for games that haven't
        // started, so a staggered slate's late game must keep the slate LIVE
        // until it actually finishes rather than be tolerated as a failed fetch
        // (which would settle the contest before the late game is played).
        let staleFetchCutoff: TimeInterval = 8 * 3600
        let unfetchedStillPending = failedGames.contains { Date().timeIntervalSince($0.startTime) < staleFetchCutoff }
        let allGamesFinal = allFetchedAreFinal && !results.isEmpty && !unfetchedStillPending
        
        print("[MLB-Score] Total: \(results.count)/\(games.count) games fetched, \(pointsByPlayerID.count) player scores, failed=\(failedGames.count)")

        let snapshot = DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfoByID,
            allGamesFinal: allGamesFinal
        )
        LiveScoreCache.shared.set(snapshot, gameIDs: gameIDs)
        return snapshot
    }

    nonisolated private func extractGameLiveInfo(payload: [String: Any], game: DFSSlateGame) -> DFSGameLiveInfo {
        var awayScore = 0, homeScore = 0
        var clock = "", period = 1, state = "pre"
        var inningHalf: String? = nil

        if let header = payload["header"] as? [String: Any],
           let competitions = header["competitions"] as? [[String: Any]],
           let competition = competitions.first {

            if let status = competition["status"] as? [String: Any],
               let typeInfo = status["type"] as? [String: Any],
               let stateStr = typeInfo["state"] as? String {
                state = stateStr
            }

            if let status = competition["status"] as? [String: Any] {
                clock = status["displayClock"] as? String ?? ""
                period = status["period"] as? Int ?? 1
                // MLB: capture "Top" or "Bot" (periodPrefix) for inning half
                if let prefix = status["periodPrefix"] as? String, !prefix.isEmpty {
                    // Shorten "Bottom" to "Bot" if ESPN ever sends the full word
                    inningHalf = prefix.hasPrefix("Bot") ? "Bot" : prefix
                }
            }

            if let competitors = competition["competitors"] as? [[String: Any]] {
                for competitor in competitors {
                    let score = Int(competitor["score"] as? String ?? "0") ?? 0
                    let homeAway = competitor["homeAway"] as? String ?? ""
                    if homeAway == "home" { homeScore = score }
                    else { awayScore = score }
                }
            }
        }

        return DFSGameLiveInfo(
            id: game.id,
            awayTeam: game.awayTeam,
            homeTeam: game.homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            clock: clock,
            period: period,
            state: state,
            inningHalf: inningHalf
        )
    }

    /// Parse play-by-play data to extract per-batter stats not in the boxscore
    /// (doubles, triples, stolen bases, hit-by-pitches).
    nonisolated private func extractPlayByPlayStats(payload: [String: Any]) -> [String: (doubles: Int, triples: Int, stolenBases: Int, hbp: Int)] {
        guard let plays = payload["plays"] as? [[String: Any]] else { return [:] }
        var statsByAthleteID: [String: (doubles: Int, triples: Int, stolenBases: Int, hbp: Int)] = [:]

        for play in plays {
            guard let type = play["type"] as? [String: Any],
                  let typeText = type["text"] as? String else { continue }

            let participants = play["participants"] as? [[String: Any]] ?? []
            let batterID = participants.first(where: { ($0["type"] as? String) == "batter" })?["athlete"] as? [String: Any]
            let batterAthleteID = (batterID?["id"] as? String) ?? (batterID?["id"] as? Int).map(String.init)

            switch typeText {
            case "Double":
                guard let id = batterAthleteID else { continue }
                var s = statsByAthleteID[id, default: (0, 0, 0, 0)]
                s.doubles += 1
                statsByAthleteID[id] = s
            case "Triple":
                guard let id = batterAthleteID else { continue }
                var s = statsByAthleteID[id, default: (0, 0, 0, 0)]
                s.triples += 1
                statsByAthleteID[id] = s
            case "Hit By Pitch":
                guard let id = batterAthleteID else { continue }
                var s = statsByAthleteID[id, default: (0, 0, 0, 0)]
                s.hbp += 1
                statsByAthleteID[id] = s
            case "Play Result":
                // Stolen bases appear as "Play Result" with text containing "stole"
                let text = play["text"] as? String ?? ""
                if text.lowercased().contains("stole") {
                    // The runner who stole is the first non-pitcher participant
                    for p in participants {
                        guard (p["type"] as? String) != "pitcher" else { continue }
                        let athleteInfo = p["athlete"] as? [String: Any]
                        let runnerID = (athleteInfo?["id"] as? String) ?? (athleteInfo?["id"] as? Int).map(String.init)
                        guard let id = runnerID else { continue }
                        var s = statsByAthleteID[id, default: (0, 0, 0, 0)]
                        s.stolenBases += 1
                        statsByAthleteID[id] = s
                        break // only credit first runner
                    }
                }
            default:
                break
            }
        }
        return statsByAthleteID
    }

    nonisolated private func extractMLBPlayerStats(
        payload: [String: Any],
        gameStatus: String,
        gameFinal: Bool
    ) -> [(String, Double, DFSPlayerLiveStats)] {
        guard let boxscore = payload["boxscore"] as? [String: Any],
              let playersArr = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        // Extract extra batting stats from play-by-play (2B, 3B, SB, HBP)
        let playStats = extractPlayByPlayStats(payload: payload)

        var results: [(String, Double, DFSPlayerLiveStats)] = []

        // Pre-pass: collect every athlete that appears in a BATTING category.
        // A two-way player (Ohtani) shows up in both batting and pitching; we
        // route his pitching line to the "-sp" DFS entry and his batting line to
        // the base id. This must be ORDER-INDEPENDENT: ESPN doesn't guarantee
        // batting is listed before pitching, and when a two-way player is the
        // starting pitcher his pitching category can come first — the old
        // "seen batting already?" check then failed, the "-sp" entry was never
        // created, and the batter slot rendered pitching stats ("5/6.0").
        var battingAthleteIDs = Set<String>()
        for teamBlock in playersArr {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }
            for statCategory in statistics {
                let categoryName = (statCategory["type"] as? String)
                    ?? (statCategory["name"] as? String) ?? ""
                guard categoryName.lowercased().contains("bat") else { continue }
                guard let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }
                for athlete in athletes {
                    if let info = athlete["athlete"] as? [String: Any], let id = info["id"] as? String {
                        battingAthleteIDs.insert(id)
                    }
                }
            }
        }

        for teamBlock in playersArr {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }

            for statCategory in statistics {
                guard let labels = statCategory["labels"] as? [String],
                      let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }
                // ESPN uses "type" for the category identifier ("batting"/"pitching"),
                // falling back to "name" for compatibility
                let categoryName = (statCategory["type"] as? String)
                    ?? (statCategory["name"] as? String)
                    ?? ""

                let lowerCategory = categoryName.lowercased()
                // Only process batting and pitching stats — skip any other categories
                // (e.g., "fielding", "season", etc.) that ESPN might include.
                guard lowerCategory.contains("bat") || lowerCategory.contains("pitch") else {
                    print("[MLB-Score] Skipping unrecognized stat category: \(categoryName)")
                    continue
                }

                var labelIndex: [String: Int] = [:]
                for (i, label) in labels.enumerated() {
                    labelIndex[label.uppercased()] = i
                }

                let isPitchingCategory = lowerCategory.contains("pitch")

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          let values = athlete["stats"] as? [String] else { continue }

                    let athleteName = (athleteInfo["displayName"] as? String)
                        ?? (athleteInfo["shortName"] as? String)
                        ?? "Player \(athleteID)"

                    func strStat(_ key: String) -> String {
                        guard let idx = labelIndex[key], idx < values.count else { return "0" }
                        return values[idx]
                    }
                    func intStat(_ key: String) -> Int {
                        Int(Double(strStat(key)) ?? 0)
                    }
                    func doubleStat(_ key: String) -> Double {
                        Double(strStat(key)) ?? 0
                    }

                    let fantasy: Double
                    let basePlayerID = "mlb-\(athleteID)"
                    // Two-way players: pitching stats go to the "-sp" SP entry,
                    // batting stats to the base id. Detect two-way by whether the
                    // athlete also appears in a batting category (order-independent
                    // — see battingAthleteIDs pre-pass). A pure pitcher isn't in
                    // that set, so his pitching stays on the base id.
                    let playerID: String
                    if isPitchingCategory && battingAthleteIDs.contains(athleteID) {
                        playerID = basePlayerID + "-sp"
                    } else {
                        playerID = basePlayerID
                    }

                    if isPitchingCategory {
                        // FanDuel Pitching: IP*3 + K*3 + W*6 + ER*-3
                        let ip = doubleStat("IP")
                        let k = intStat("K")
                        let er = intStat("ER")
                        let w = intStat("W")

                        // Sanity check: no pitcher throws 15+ innings in a single game.
                        // If we see values this high, ESPN likely returned season stats.
                        if ip > 15.0 || k > 25 || er > 20 {
                            print("[MLB-Score] SANITY SKIP pitcher \(athleteName) (id=\(athleteID)): IP=\(ip) K=\(k) ER=\(er) — likely season stats")
                            continue
                        }

                        fantasy = ip * 3.0 + Double(k) * 3.0 + Double(w) * 6.0 - Double(er) * 3.0

                        let stats = DFSPlayerLiveStats(
                            name: athleteName,
                            points: intStat("K"), rebounds: intStat("ER"), assists: w,
                            steals: 0, blocks: 0, turnovers: 0,
                            minutes: strStat("IP"),
                            fgm: 0, fga: 0, threePM: 0, threePA: 0, ftm: 0, fta: 0,
                            fantasyPoints: fantasy,
                            gameStatus: gameStatus,
                            gameFinal: gameFinal
                        )
                        results.append((playerID, fantasy, stats))
                    } else {
                        // FanDuel Batting: 1B=3, 2B=6, 3B=9, HR=12, RBI=3, R=3, BB=3, SB=6, HBP=3
                        let ab = intStat("AB")
                        let h = intStat("H")
                        let hr = intStat("HR")
                        let rbi = intStat("RBI")
                        let r = intStat("R")
                        let bb = intStat("BB")

                        // Sanity check: a single MLB game maxes out around 7-8 AB per player
                        // (even in extra innings). If AB > 12, ESPN likely returned season stats.
                        if ab > 12 || h > 10 || hr > 5 || rbi > 12 || r > 8 || bb > 6 {
                            print("[MLB—Score] SANITY SKIP batter \(athleteName) (id=\(athleteID)): AB=\(ab) H=\(h) HR=\(hr) RBI=\(rbi) R=\(r) BB=\(bb) — likely season stats")
                            continue
                        }

                        // ESPN boxscore doesn't include 2B/3B/SB/HBP as columns —
                        // extract these from play-by-play data
                        let extra = playStats[athleteID] ?? (0, 0, 0, 0)
                        let doubles = extra.doubles
                        let triples = extra.triples
                        let sb = extra.stolenBases
                        let hbp = extra.hbp
                        let singles = max(0, h - doubles - triples - hr)

                        fantasy = Double(singles) * 3.0 + Double(doubles) * 6.0 + Double(triples) * 9.0
                            + Double(hr) * 12.0 + Double(rbi) * 3.0 + Double(r) * 3.0
                            + Double(bb) * 3.0 + Double(sb) * 6.0 + Double(hbp) * 3.0

                        // Reuse DFSPlayerLiveStats — map MLB stats into available fields
                        let stats = DFSPlayerLiveStats(
                            name: athleteName,
                            points: h, rebounds: hr, assists: rbi,
                            steals: r, blocks: bb, turnovers: sb,
                            minutes: "\(ab) AB",
                            fgm: singles, fga: doubles, threePM: triples, threePA: hr,
                            ftm: rbi, fta: r,
                            fantasyPoints: fantasy,
                            gameStatus: gameStatus,
                            gameFinal: gameFinal
                        )
                        results.append((playerID, fantasy, stats))
                    }
                }
            }
        }
        return results
    }
}

// MARK: - NCAAM March Madness DFS Providers

struct ESPNNCAAMDFSSlateProvider: DFSSlateProvider {
    private let session: URLSession
    private let cache = ESPNRosterCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        // Return cached slate if recent
        if let cached = cache.getSlate(key: "ncaam") {
            return cached
        }

        let events = try await fetchTournamentEvents()
        guard !events.isEmpty else {
            throw NSError(domain: "NCAAMDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No upcoming March Madness games found"])
        }

        // Build team abbreviation → event ID mapping
        var teamToGameID: [String: String] = [:]
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                teamToGameID[competitor.team.abbreviation] = event.id
            }
        }

        let teamRefs = Array(uniqueTeams(from: events).prefix(32))

        // Fetch all rosters in parallel
        let players: [DFSPlayer] = try await withThrowingTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let gameID = teamToGameID[team.abbreviation]
                group.addTask {
                    let roster = try await self.fetchNCAAMRoster(teamID: team.id, teamAbbreviation: team.abbreviation, gameID: gameID)
                    return Array(roster.prefix(10))
                }
            }
            var allPlayers: [DFSPlayer] = []
            for try await roster in group {
                allPlayers.append(contentsOf: roster)
            }
            return allPlayers
        }

        let deduped = deduplicatePlayers(players)
        guard !deduped.isEmpty else {
            throw NSError(domain: "NCAAMDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No players found for March Madness games"])
        }

        // Require real DraftKings/LineupHQ prices — don't offer a slate built on
        // our own performance-rating estimates. Apply DK college-basketball
        // ("cbb") prices and bail if none are posted yet.
        let cbbSalaries = await RotoGrindersSalaryProvider.shared.fetchClassicSalariesFromMaster(sport: "cbb")
        var dkApplied = 0
        let pricedPlayers: [DFSPlayer] = deduped.map { player in
            guard let realSalary = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: cbbSalaries) else { return player }
            dkApplied += 1
            var p = DFSPlayer(
                id: player.id, name: player.name, team: player.team,
                position: player.position, salary: realSalary,
                projectedPoints: player.projectedPoints,
                gameID: player.gameID, injuryStatus: player.injuryStatus
            )
            p.isConfirmedActive = player.isConfirmedActive
            return p
        }
        guard dkApplied > 0 else {
            throw NSError(domain: "NCAAMDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's NCAAM slate"])
        }

        let slateDate = events.first?.date ?? Date()
        let tournamentID = "ncaam-\(dateKey(for: slateDate))"

        // Format the slate date for the title (e.g. "Thu Mar 20")
        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "EEE MMM d"
        let dateLabel = titleFormatter.string(from: slateDate)
        let gameCount = events.count

        let slate = DFSSlate(
            tournament: DFSTournament(
                id: tournamentID,
                title: "March Madness — \(dateLabel) (\(gameCount)G)",
                league: "NCAAM",
                entryCount: 1000,
                lineupSize: 6,
                salaryCap: 50000
            ),
            includedGames: events.compactMap { event in
                guard let competition = event.competitions.first else { return nil }
                guard let away = competition.competitors.first(where: { $0.homeAway == "away" }) else { return nil }
                guard let home = competition.competitors.first(where: { $0.homeAway == "home" }) else { return nil }
                return DFSSlateGame(
                    id: event.id,
                    awayTeam: away.team.abbreviation,
                    homeTeam: home.team.abbreviation,
                    startTime: event.date,
                    state: competition.status.type.state
                )
            },
            players: pricedPlayers.sorted(by: { $0.salary > $1.salary })
        )
        cache.setSlate(slate, key: "ncaam")
        return slate
    }

    /// Fetch the best upcoming NCAA Tournament (March Madness) daily slate.
    /// Looks at today + the next 7 days to find the optimal slate.
    /// Prefers the day with the most games to skip small play-in slates
    /// in favor of the main bracket when it's coming up soon.
    private func fetchTournamentEvents() async throws -> [NBAScoreboardEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Gather slates for today + next 3 days in parallel to find the best one
        let dayRange = 0...7
        var slatesByOffset: [(offset: Int, live: [NBAScoreboardEvent], pre: [NBAScoreboardEvent], post: [NBAScoreboardEvent])] = []

        // Fetch today and next few days in parallel
        let fetched: [(Int, [NBAScoreboardEvent])] = await withTaskGroup(of: (Int, [NBAScoreboardEvent]).self) { group in
            for dayOffset in dayRange {
                guard let checkDate = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                let dk = dateKey(for: checkDate)
                group.addTask {
                    let events = await self.fetchNCAAMScoreboard(dateKey: dk)
                    return (dayOffset, self.filterTournamentEvents(events))
                }
            }
            var results: [(Int, [NBAScoreboardEvent])] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted(by: { $0.0 < $1.0 })
        }

        for (offset, filtered) in fetched {
            let live = filtered.filter { $0.competitions.first?.status.type.state == "in" }
            let pre = filtered.filter { $0.competitions.first?.status.type.state == "pre" }
            let post = filtered.filter { $0.competitions.first?.status.type.state == "post" }
            slatesByOffset.append((offset, live, pre, post))
        }

        // Find the next day with upcoming (pre) games the user can actually enter
        let nextUpcomingDay = slatesByOffset.first(where: { !$0.pre.isEmpty })

        // Priority 1: Day with live games — BUT skip small locked slates
        // (e.g. 2-game play-ins) if there's a bigger upcoming slate the user can build for
        if let liveDay = slatesByOffset.first(where: { !$0.live.isEmpty }) {
            let liveTotal = liveDay.live.count + liveDay.pre.count + liveDay.post.count
            let hasUpcomingPre = !liveDay.pre.isEmpty  // some games on this day haven't started

            // If the live day still has pre games, show the combined slate
            // Include post games so finished-game player scores are fetched
            if hasUpcomingPre {
                return (liveDay.post + liveDay.live + liveDay.pre).sorted(by: { $0.date < $1.date })
            }

            // All games on this day are locked. If it's a small slate and a bigger
            // upcoming slate exists, skip to the upcoming one so users can build lineups
            if liveTotal <= 4, let nextUp = nextUpcomingDay, nextUp.pre.count >= 6 {
                return (nextUp.post + nextUp.pre).sorted(by: { $0.date < $1.date })
            }

            // Otherwise show the live day (large slate in progress, or no better option)
            return (liveDay.live + liveDay.post).sorted(by: { $0.date < $1.date })
        }

        // Priority 2: Best upcoming slate
        // Skip small play-in slates (≤4 games) if a bigger main bracket slate (≥8) is next
        let upcomingDays = slatesByOffset.filter { !$0.pre.isEmpty }
        if upcomingDays.count >= 2 {
            let firstDay = upcomingDays[0]
            let secondDay = upcomingDays[1]
            if firstDay.pre.count <= 4 && secondDay.pre.count >= 8 && secondDay.offset <= firstDay.offset + 2 {
                return (secondDay.post + secondDay.pre).sorted(by: { $0.date < $1.date })
            }
        }

        // Use the first day with upcoming games — include same-day post games
        // so the full slate is shown (e.g. Final Four: one game finished, one upcoming)
        if let firstPre = upcomingDays.first {
            return (firstPre.post + firstPre.pre).sorted(by: { $0.date < $1.date })
        }

        // Fallback: today's finished games (for settlement)
        if let todaySlate = slatesByOffset.first, !todaySlate.post.isEmpty, todaySlate.offset == 0 {
            return todaySlate.post.sorted(by: { $0.date < $1.date })
        }

        return []
    }

    /// Fetch NCAAM scoreboard for a specific date (group 100 = NCAA Tournament)
    private func fetchNCAAMScoreboard(dateKey dk: String) async -> [NBAScoreboardEvent] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/scoreboard?dates=\(dk)&limit=100&groups=100") else {
            return []
        }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        guard let scoreboard = try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data) else {
            return []
        }
        return scoreboard.events
    }

    /// Filter out NIT and other non-tournament games
    private func filterTournamentEvents(_ events: [NBAScoreboardEvent]) -> [NBAScoreboardEvent] {
        events.filter { event in
            let name = event.name ?? ""
            let shortName = event.shortName ?? ""
            if name.uppercased().contains("NIT") || shortName.uppercased().contains("NIT") {
                return false
            }
            return true
        }
    }

    private func fetchNCAAMRoster(teamID: String, teamAbbreviation: String, gameID: String?) async throws -> [DFSPlayer] {
        let cacheKey = "ncaam-\(teamID)"
        if let cached = cache.getRoster(teamID: cacheKey, gameID: gameID) {
            return cached
        }

        let performanceRatings = try await fetchNCAAMPerformanceRatings(teamID: teamID)
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/teams/\(teamID)/roster") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let roster = try? JSONDecoder().decode(NBARosterResponse.self, from: data) else {
            return []
        }

        let players = roster.athletes.map { athlete in
            let position = mapNCAAMPosition(athlete.position?.abbreviation)
            let fppg = performanceRatings[athlete.id] ?? 0.0
            let salary = ncaamEstimatedSalary(fppg: fppg, playerID: athlete.id)
            let projection = ncaamProjectedPoints(fppg: fppg, position: position)

            let injuryStatus: String?
            if let injury = athlete.injuries?.first, let status = injury.status {
                switch status.lowercased() {
                case "out": injuryStatus = "O"
                case "day-to-day": injuryStatus = "GTD"
                case "questionable": injuryStatus = "Q"
                case "doubtful": injuryStatus = "D"
                default: injuryStatus = nil
                }
            } else {
                injuryStatus = nil
            }

            return DFSPlayer(
                id: "ncaam-\(athlete.id)",
                name: athlete.fullName,
                team: teamAbbreviation,
                position: position,
                salary: salary,
                projectedPoints: projection,
                gameID: gameID,
                injuryStatus: injuryStatus
            )
        }
        .sorted { $0.projectedPoints > $1.projectedPoints }

        cache.setRoster(teamID: cacheKey, gameID: gameID, players: players)
        return players
    }

    /// Map ESPN college basketball position abbreviations to DFS-style positions
    private func mapNCAAMPosition(_ raw: String?) -> String {
        guard let raw else { return "SF" }
        switch raw.uppercased() {
        case "PG": return "PG"
        case "SG": return "SG"
        case "SF": return "SF"
        case "PF": return "PF"
        case "C": return "C"
        // College-specific: ESPN sometimes uses generic "G" or "F"
        case "G": return "PG"
        case "F": return "PF"
        default: return "SF"
        }
    }

    private func fetchNCAAMPerformanceRatings(teamID: String) async throws -> [String: Double] {
        let cacheKey = "ncaam-\(teamID)"
        if let cached = cache.getRatings(teamID: cacheKey) {
            return cached
        }

        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/teams/\(teamID)/athletes/statistics") else {
            return [:]
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return [:]
        }

        var ratings: [String: Double] = [:]

        guard let firstResult = results.first,
              let leaders = firstResult["leaders"] as? [[String: Any]] else {
            return [:]
        }

        for leader in leaders {
            guard let athlete = leader["athlete"] as? [String: Any],
                  let athleteID = athlete["id"] as? String else { continue }
            guard let statistics = leader["statistics"] as? [[String: Any]] else { continue }

            var ppg: Double = 0, rpg: Double = 0, apg: Double = 0
            var spg: Double = 0, bpg: Double = 0, topg: Double = 0
            var threepmg: Double = 0

            for section in statistics {
                guard let stats = section["stats"] as? [[String: Any]] else { continue }
                for stat in stats {
                    guard let name = stat["name"] as? String,
                          let value = stat["value"] as? Double else { continue }
                    switch name {
                    case "avgPoints": ppg = value
                    case "avgRebounds": rpg = value
                    case "avgAssists": apg = value
                    case "avgSteals": spg = value
                    case "avgBlocks": bpg = value
                    case "avgTurnovers": topg = value
                    case "avgThreePointFieldGoalsMade": threepmg = value
                    default: break
                    }
                }
            }

            // DK-style fantasy points: PTS×1 + REB×1.25 + AST×1.5 + STL×2 + BLK×2 - TO×0.5 + 3PM×0.5
            let fppg = ppg * 1.0
                + rpg * 1.25
                + apg * 1.5
                + spg * 2.0
                + bpg * 2.0
                - topg * 0.5
                + threepmg * 0.5

            ratings[athleteID] = fppg
        }

        cache.setRatings(teamID: cacheKey, ratings: ratings)
        return ratings
    }

    /// College salary mapping — stats are lower than NBA so curves are compressed
    private func ncaamEstimatedSalary(fppg: Double, playerID: String) -> Int {
        // Elite college (25+ FPPG): $9,000 - $11,500
        // Star starters (18-25):     $7,000 - $9,000
        // Solid starters (12-18):    $5,500 - $7,000
        // Role players (7-12):       $4,000 - $5,500
        // Bench (0-7):               $3,000 - $4,000
        let salary: Int
        if fppg >= 25 {
            let fraction = min(1.0, (fppg - 25.0) / 10.0)
            salary = 9000 + Int(fraction * 2500.0)
        } else if fppg >= 18 {
            let fraction = (fppg - 18.0) / 7.0
            salary = 7000 + Int(fraction * 2000.0)
        } else if fppg >= 12 {
            let fraction = (fppg - 12.0) / 6.0
            salary = 5500 + Int(fraction * 1500.0)
        } else if fppg >= 7 {
            let fraction = (fppg - 7.0) / 5.0
            salary = 4000 + Int(fraction * 1500.0)
        } else {
            let fraction = max(0, fppg) / 7.0
            salary = 3000 + Int(fraction * 1000.0)
        }

        // Stable per-player jitter ±100
        let stableHash = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = abs(stableHash % 200) - 100
        return max(3000, min(11500, salary + jitter))
    }

    /// College projected points — regression toward college-level position averages
    private func ncaamProjectedPoints(fppg: Double, position: String) -> Double {
        guard fppg > 0 else { return 0.0 }
        let positionAvg: Double
        switch position {
        case "PG": positionAvg = 14.0
        case "SG", "SF": positionAvg = 12.5
        case "PF", "C": positionAvg = 13.5
        default: positionAvg = 10.0
        }
        let projected = fppg * 0.85 + positionAvg * 0.15
        return (projected * 10).rounded() / 10
    }

    private func uniqueTeams(from events: [NBAScoreboardEvent]) -> [NBATeamRef] {
        var seen = Set<String>()
        var result: [NBATeamRef] = []
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                let id = competitor.team.id
                guard seen.insert(id).inserted else { continue }
                result.append(NBATeamRef(id: id, abbreviation: competitor.team.abbreviation))
            }
        }
        return result
    }

    private func deduplicatePlayers(_ players: [DFSPlayer]) -> [DFSPlayer] {
        var seen = Set<String>()
        return players.filter { seen.insert($0.id).inserted }
    }

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - NCAAM Live Scoring Provider

struct ESPNNCAAMDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }

    private struct GameFetchResult: Sendable {
        let gameID: String
        let gameInfo: DFSGameLiveInfo
        let playerResults: [(String, Double, DFSPlayerLiveStats)]
        let isFinal: Bool
    }

    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        let gameIDs = Set(games.map { $0.id })
        if let cached = LiveScoreCache.shared.get(gameIDs: gameIDs) {
            return cached
        }

        let results: [GameFetchResult] = await withTaskGroup(of: GameFetchResult?.self) { group in
            for game in games {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/summary?event=\(game.id)") else {
                        return nil
                    }

                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }

                    let state = self.extractState(fromSummaryPayload: payload)
                    let gameInfo = self.extractGameLiveInfo(fromSummaryPayload: payload, game: game)
                    let gameStatus = gameInfo.displayStatus
                    let gameFinal = gameInfo.state == "post"
                    let playerResults = self.extractPlayerStats(fromSummaryPayload: payload, gameStatus: gameStatus, gameFinal: gameFinal)

                    return GameFetchResult(
                        gameID: game.id,
                        gameInfo: gameInfo,
                        playerResults: playerResults,
                        isFinal: state == "post"
                    )
                }
            }

            var collected: [GameFetchResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfoByID: [String: DFSGameLiveInfo] = [:]

        let fetchedGameIDs = Set(results.map { $0.gameID })
        let failedGames = games.filter { !fetchedGameIDs.contains($0.id) }
        var allFetchedAreFinal = true

        for result in results {
            gameLiveInfoByID[result.gameID] = result.gameInfo
            if !result.isFinal { allFetchedAreFinal = false }
            for (playerID, fantasy, stats) in result.playerResults {
                pointsByPlayerID[playerID] = fantasy
                statsByPlayerID[playerID] = stats
            }
        }

        // A game we couldn't fetch is NOT assumed done unless its start is long
        // past (a broken/stale event). ESPN endpoints 404 for games that haven't
        // started, so a staggered slate's late game must keep the slate LIVE
        // until it actually finishes rather than be tolerated as a failed fetch
        // (which would settle the contest before the late game is played).
        let staleFetchCutoff: TimeInterval = 8 * 3600
        let unfetchedStillPending = failedGames.contains { Date().timeIntervalSince($0.startTime) < staleFetchCutoff }
        let allGamesFinal = allFetchedAreFinal && !results.isEmpty && !unfetchedStillPending

        let snapshot = DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfoByID,
            allGamesFinal: allGamesFinal
        )
        LiveScoreCache.shared.set(snapshot, gameIDs: gameIDs)
        return snapshot
    }

    nonisolated private func extractState(fromSummaryPayload payload: [String: Any]) -> String? {
        guard let header = payload["header"] as? [String: Any],
              let competitions = header["competitions"] as? [[String: Any]],
              let competition = competitions.first,
              let status = competition["status"] as? [String: Any],
              let type = status["type"] as? [String: Any],
              let state = type["state"] as? String else {
            return nil
        }
        return state
    }

    nonisolated private func extractGameLiveInfo(fromSummaryPayload payload: [String: Any], game: DFSSlateGame) -> DFSGameLiveInfo {
        var awayScore = 0
        var homeScore = 0
        var clock = "0:00"
        var period = 1
        var state = "pre"

        if let header = payload["header"] as? [String: Any],
           let competitions = header["competitions"] as? [[String: Any]],
           let competition = competitions.first {

            if let status = competition["status"] as? [String: Any],
               let typeInfo = status["type"] as? [String: Any],
               let stateStr = typeInfo["state"] as? String {
                state = stateStr
            }

            if let status = competition["status"] as? [String: Any] {
                clock = status["displayClock"] as? String ?? "0:00"
                period = status["period"] as? Int ?? 1
            }

            if let competitors = competition["competitors"] as? [[String: Any]] {
                for competitor in competitors {
                    let score = Int(competitor["score"] as? String ?? "0") ?? 0
                    let homeAway = competitor["homeAway"] as? String ?? ""
                    if homeAway == "home" { homeScore = score }
                    else { awayScore = score }
                }
            }
        }

        return DFSGameLiveInfo(
            id: game.id,
            awayTeam: game.awayTeam,
            homeTeam: game.homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            clock: clock,
            period: period,
            state: state
        )
    }

    nonisolated private func extractPlayerStats(
        fromSummaryPayload payload: [String: Any],
        gameStatus: String,
        gameFinal: Bool
    ) -> [(String, Double, DFSPlayerLiveStats)] {
        guard let boxscore = payload["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        var results: [(String, Double, DFSPlayerLiveStats)] = []
        for teamBlock in players {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }
            for statCategory in statistics {
                guard let labels = statCategory["labels"] as? [String],
                      let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }

                var labelIndex: [String: Int] = [:]
                for (i, label) in labels.enumerated() {
                    labelIndex[label.uppercased()] = i
                }

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          let values = athlete["stats"] as? [String] else { continue }

                    let athleteName = (athleteInfo["displayName"] as? String)
                        ?? (athleteInfo["shortName"] as? String)
                        ?? "Player \(athleteID)"

                    func doubleStat(_ key: String) -> Double {
                        guard let idx = labelIndex[key], idx < values.count else { return 0 }
                        return Double(values[idx]) ?? 0
                    }
                    func intStat(_ key: String) -> Int {
                        Int(doubleStat(key))
                    }
                    func strStat(_ key: String) -> String {
                        guard let idx = labelIndex[key], idx < values.count else { return "0" }
                        return values[idx]
                    }

                    let pts = intStat("PTS")
                    let reb = intStat("REB")
                    let ast = intStat("AST")
                    let stl = intStat("STL")
                    let blk = intStat("BLK")
                    let to = intStat("TO")
                    let min = strStat("MIN")

                    let fgStr = strStat("FG")
                    let fgParts = fgStr.split(separator: "-")
                    let fgm = fgParts.count >= 1 ? Int(fgParts[0]) ?? 0 : 0
                    let fga = fgParts.count >= 2 ? Int(fgParts[1]) ?? 0 : 0

                    let threeStr = strStat("3PT")
                    let threeParts = threeStr.split(separator: "-")
                    let threePM = threeParts.count >= 1 ? Int(threeParts[0]) ?? 0 : 0
                    let threePA = threeParts.count >= 2 ? Int(threeParts[1]) ?? 0 : 0

                    let ftStr = strStat("FT")
                    let ftParts = ftStr.split(separator: "-")
                    let ftm = ftParts.count >= 1 ? Int(ftParts[0]) ?? 0 : 0
                    let fta = ftParts.count >= 2 ? Int(ftParts[1]) ?? 0 : 0

                    let fantasy =
                        Double(pts) * 1.0 +
                        Double(reb) * 1.2 +
                        Double(ast) * 1.5 +
                        Double(stl) * 3.0 +
                        Double(blk) * 3.0 -
                        Double(to) * 1.0

                    let playerID = "ncaam-\(athleteID)"
                    let stats = DFSPlayerLiveStats(
                        name: athleteName,
                        points: pts, rebounds: reb, assists: ast,
                        steals: stl, blocks: blk, turnovers: to,
                        minutes: min,
                        fgm: fgm, fga: fga,
                        threePM: threePM, threePA: threePA,
                        ftm: ftm, fta: fta,
                        fantasyPoints: fantasy,
                        gameStatus: gameStatus,
                        gameFinal: gameFinal
                    )
                    results.append((playerID, fantasy, stats))
                }
            }
        }
        return results
    }
}

// MARK: - NHL DFS Providers

struct ESPNNHLDFSSlateProvider: DFSSlateProvider {
    private let session: URLSession
    private let cache = ESPNRosterCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        if let cached = cache.getSlate(key: "nhl") {
            return cached
        }

        // Start fetching real DraftKings salaries in parallel with ESPN data
        async let rgSalaries = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "nhl", maxClassicSalary: 10000)

        let events = try await fetchNHLEvents()
        guard !events.isEmpty else {
            throw NSError(domain: "NHLDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No NHL games found"])
        }

        // Build team abbreviation → event ID mapping and collect probable starting goalies
        var teamToGameID: [String: String] = [:]
        var probableGoalieIDs = Set<String>()
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                teamToGameID[competitor.team.abbreviation] = event.id
                // Extract confirmed starting goalie from ESPN probables.
                // ESPN lists the confirmed starter first; only take the first
                // goalie per team to avoid marking backups as starters.
                if let probables = competitor.probables, let firstProbable = probables.first,
                   let id = firstProbable.athlete?.id {
                    probableGoalieIDs.insert(id)
                }
            }
        }
        if !probableGoalieIDs.isEmpty {
            print("[NHL-DFS] Found \(probableGoalieIDs.count) probable starting goalies from scoreboard")
        }

        let teamRefs = Array(uniqueTeams(from: events).prefix(32))

        // Pre-fetch all team ratings AND recently-active player IDs in parallel
        typealias NHLRating = (fppg: Double, gamesPlayed: Int)
        let teamIDs = teamRefs.map(\.id)

        async let ratingsTask: [String: [String: NHLRating]] = withTaskGroup(of: (String, [String: NHLRating]).self) { group in
            for team in teamRefs {
                group.addTask { @Sendable in
                    let ratings = await self.fetchNHLRatings(teamID: team.id)
                    return (team.id, ratings)
                }
            }
            var result: [String: [String: NHLRating]] = [:]
            for await (teamID, ratings) in group {
                result[teamID] = ratings
            }
            return result
        }
        async let recentlyActiveTask = fetchNHLRecentlyActivePlayerIDs(teamIDs: teamIDs)
        async let recentStartingGoaliesTask = fetchRecentStartingGoalies(teamIDs: teamIDs)

        let allRatings = await ratingsTask
        let recentlyActiveIDs = await recentlyActiveTask
        let recentStartingGoaliesByTeam = await recentStartingGoaliesTask

        // Merge ESPN probables with recent-starter signal. The recent
        // boxscore-derived starter catches two failure modes of ESPN's
        // probables feed:
        //   • Probable feed doesn't list a goalie for that team at all
        //     (intermittent — happens in playoffs surprisingly often)
        //   • Probable lists the regular starter but they're listed GTD
        //     on the roster (caught separately by the injury filter
        //     downstream)
        // We union the two sets so any goalie identified by either signal
        // gets marked. Adds the recent starter as a candidate even when
        // probables already cover the team — costs nothing, hedges
        // against late switches.
        for (_, athleteID) in recentStartingGoaliesByTeam {
            probableGoalieIDs.insert(athleteID)
        }
        if !recentStartingGoaliesByTeam.isEmpty {
            print("[NHL-DFS] Added \(recentStartingGoaliesByTeam.count) recent-starter goalie(s) to probable set")
        }

        // Fetch all rosters in parallel, passing pre-fetched ratings + recency data
        let allPlayers: [DFSPlayer] = try await withThrowingTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let gameID = teamToGameID[team.abbreviation]
                let ratings = allRatings[team.id] ?? [:]
                let recentIDs = recentlyActiveIDs
                group.addTask {
                    let roster = try await self.fetchNHLRoster(teamID: team.id, teamAbbreviation: team.abbreviation, gameID: gameID, ratings: ratings, recentlyActiveIDs: recentIDs)
                    // Keep everyone who actually DRESSES, drop true scratches.
                    // The old "top 14 by projection" cap skewed toward forwards
                    // and cut top-pair defensemen (Slavin, Hanifin) plus call-up
                    // goalies (Bussi) — the DK feed then re-injected them as
                    // teamless stubs with no game logs. Recency (dressed in a
                    // recent game) is the real scratch filter; fall back to a
                    // generous projection cut only when recency data is missing.
                    // Goalies are ALWAYS kept — starters can be surprise call-ups.
                    let goalies = roster.filter { $0.position == "G" }
                    let skaters = roster.filter { $0.position != "G" }
                    let teamHasRecency = skaters.contains { $0.playedRecently }
                    let keptSkaters = teamHasRecency
                        ? skaters.filter { $0.playedRecently }
                        : Array(skaters.prefix(16))
                    return keptSkaters + goalies
                }
            }
            var players: [DFSPlayer] = []
            for try await roster in group {
                players.append(contentsOf: roster)
            }
            return players
        }

        let deduped = deduplicatePlayers(allPlayers)
        guard !deduped.isEmpty else {
            throw NSError(domain: "NHLDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No NHL players available"])
        }

        // Apply real DraftKings salaries from DFF/RotoGrinders where available
        let realSalaries = await rgSalaries
        let useRealSalaries: Bool
        var finalPlayers: [DFSPlayer]
        if !realSalaries.isEmpty {
            let matchCount = deduped.filter { RotoGrindersSalaryProvider.lookupSalary(espnName: $0.name, in: realSalaries) != nil }.count
            let matchRate = Double(matchCount) / Double(max(1, deduped.count))
            let sameSlate = matchRate > 0.30

            if sameSlate {
                // Separate goalie vs skater salary ranges
                var matchedSkaterSalaries: [Int] = []
                var matchedGoalieSalaries: [Int] = []
                var firstPassPlayers: [(DFSPlayer, Bool)] = []

                for player in deduped {
                    let isGoalie = player.position == "G"
                    if let realSalary = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: realSalaries) {
                        var matched = DFSPlayer(
                            id: player.id, name: player.name, team: player.team,
                            position: player.position, salary: realSalary,
                            projectedPoints: player.projectedPoints,
                            gameID: player.gameID, injuryStatus: player.injuryStatus
                        )
                        matched.isConfirmedActive = true
                        matched.gamesPlayed = player.gamesPlayed
                        if isGoalie {
                            matchedGoalieSalaries.append(realSalary)
                        } else {
                            matchedSkaterSalaries.append(realSalary)
                        }
                        firstPassPlayers.append((matched, true))
                    } else {
                        // Not in RotoGrinders pool — likely a scratch or reserve player
                        var unmatched = player
                        unmatched.isConfirmedActive = false
                        firstPassPlayers.append((unmatched, false))
                    }
                }

                let skaterMin = matchedSkaterSalaries.min() ?? 3500
                let skaterMax = matchedSkaterSalaries.max() ?? 9500
                let goalieMin = matchedGoalieSalaries.min() ?? 6500
                let goalieMax = matchedGoalieSalaries.max() ?? 8500

                let skaterFPPGs = deduped.filter { $0.position != "G" }.map { $0.projectedPoints }
                let goalieFPPGs = deduped.filter { $0.position == "G" }.map { $0.projectedPoints }
                let skaterFPPGMin = skaterFPPGs.min() ?? 0
                let skaterFPPGMax = max(skaterFPPGMin + 1, skaterFPPGs.max() ?? 30)
                let goalieFPPGMin = goalieFPPGs.min() ?? 0
                let goalieFPPGMax = max(goalieFPPGMin + 1, goalieFPPGs.max() ?? 20)

                var applied = 0
                var calibrated = 0
                finalPlayers = firstPassPlayers.map { (player, wasMatched) in
                    if wasMatched {
                        applied += 1
                        return player
                    }
                    calibrated += 1
                    let isGoalie = player.position == "G"
                    let fppg = player.projectedPoints
                    let (fMin, fMax) = isGoalie ? (goalieFPPGMin, goalieFPPGMax) : (skaterFPPGMin, skaterFPPGMax)
                    let (sMin, sMax) = isGoalie ? (goalieMin, goalieMax) : (skaterMin, skaterMax)
                    let fraction = min(1.0, max(0, (fppg - fMin) / (fMax - fMin)))
                    let curved = pow(fraction, 0.85)
                    let salary = sMin + Int(curved * Double(sMax - sMin))
                    let rounded = (salary / 100) * 100
                    var calibratedPlayer = DFSPlayer(
                        id: player.id, name: player.name, team: player.team,
                        position: player.position, salary: max(sMin, rounded),
                        projectedPoints: player.projectedPoints,
                        gameID: player.gameID, injuryStatus: player.injuryStatus
                    )
                    calibratedPlayer.isConfirmedActive = false
                    calibratedPlayer.gamesPlayed = player.gamesPlayed
                    return calibratedPlayer
                }
                print("[NHL-DFS] sameSlate=true (\(matchCount)/\(deduped.count)), applied=\(applied), calibrated=\(calibrated), skater=$\(skaterMin)-$\(skaterMax), goalie=$\(goalieMin)-$\(goalieMax)")
                useRealSalaries = true
            } else {
                throw NSError(domain: "NHLDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's NHL slate"])
            }
        } else {
            throw NSError(domain: "NHLDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's NHL slate"])
        }

        // Mark confirmed starting goalies from scoreboard probables. Probables
        // can be stale — if ESPN lists Andersen as probable but he's marked
        // GTD/D/O on the team roster, the team likely flipped to the
        // backup. Don't mark such goalies as confirmed starters; the bot
        // weighting will then treat them as backups (heavily penalized).
        let teamsWithMarkedStarter = NSCountedSet()
        if !probableGoalieIDs.isEmpty {
            var starterCount = 0
            var skippedInjured = 0
            finalPlayers = finalPlayers.map { p in
                guard p.position == "G" else { return p }
                let espnID = String(p.id.dropFirst(4))
                if probableGoalieIDs.contains(espnID) {
                    let status = p.injuryStatus ?? ""
                    let injured = status == "O" || status == "D" || status == "GTD" || status.hasPrefix("IL")
                    if injured {
                        skippedInjured += 1
                        print("[NHL-DFS] Probable goalie \(p.name) (\(p.team)) is \(status) — NOT marking as starter")
                        return p
                    }
                    var starter = p
                    starter.isStartingGoalie = true
                    starterCount += 1
                    teamsWithMarkedStarter.add(p.team)
                    return starter
                }
                return p
            }
            print("[NHL-DFS] Marked \(starterCount) goalies as confirmed starters (\(skippedInjured) skipped for injury)")
        }

        // Surface teams with NO marked starter — common cause of bots
        // either skipping goalies or randomly drafting backups. Worth
        // logging so we can spot data gaps in the probables feed.
        let teamsInSlate = Set(finalPlayers.filter { $0.position == "G" }.map(\.team))
        let unmarkedTeams = teamsInSlate.filter { teamsWithMarkedStarter.count(for: $0) == 0 }
        if !unmarkedTeams.isEmpty {
            print("[NHL-DFS] WARNING: no probable starter identified for \(unmarkedTeams.sorted())")
        }

        let slateDate = events.first?.date ?? Date()
        let tournamentID = "nhl-\(dateKey(for: slateDate))"

        let includedGames: [DFSSlateGame] = events.compactMap { event in
            guard let competition = event.competitions.first else { return nil }
            guard let away = competition.competitors.first(where: { $0.homeAway == "away" }) else { return nil }
            guard let home = competition.competitors.first(where: { $0.homeAway == "home" }) else { return nil }
            return DFSSlateGame(
                id: event.id,
                awayTeam: away.team.abbreviation,
                homeTeam: home.team.abbreviation,
                startTime: event.date,
                state: competition.status.type.state
            )
        }

        // Detect single-game slate: the entire day has only 1 game scheduled
        // (common during NHL playoffs). Use total games, not active games,
        // so it doesn't flip mid-slate as games finish.
        let isSingleGame = includedGames.count == 1
        var sortedPlayers = finalPlayers.sorted(by: { $0.salary > $1.salary })

        // Fetch real DraftKings salaries for single-game pricing.
        // Phase 2: prefer slate-specific LineupHQ JSON for showdown.
        var nhlSlatePlayers: [RotoGrindersSalaryProvider.LineupHQSlatePlayer] = []
        let dkShowdownSalaries: [String: Int]? = await {
            if isSingleGame, let firstGame = includedGames.first {
                // Phase 2.5 fuel: pull the FULL LineupHQ slate (names,
                // IDs, salaries) so we can inject any DK-eligible NHL
                // player ESPN's roster missed — same approach NBA uses
                // for bench guys like Clarkson/Barnes. Falls back to the
                // salary-only endpoint if the rich one returns empty.
                let slatePlayers = await RotoGrindersSalaryProvider.shared.fetchShowdownPlayersForGame(
                    sport: "nhl",
                    awayHashtag: firstGame.awayTeam,
                    homeHashtag: firstGame.homeTeam,
                    startTime: firstGame.startTime
                )
                if !slatePlayers.isEmpty {
                    nhlSlatePlayers = slatePlayers
                    var byName: [String: Int] = [:]
                    for p in slatePlayers { byName[p.normalizedName] = p.utilSalary }
                    return byName
                }
                let slateSpecific = await RotoGrindersSalaryProvider.shared.fetchShowdownSalariesForGame(
                    sport: "nhl",
                    awayHashtag: firstGame.awayTeam,
                    homeHashtag: firstGame.homeTeam,
                    startTime: firstGame.startTime
                )
                if !slateSpecific.isEmpty { return slateSpecific }
            }
            let names = sortedPlayers.map(\.name)
            let dk = await RotoGrindersSalaryProvider.shared.fetchDKSalaries(sport: "nhl", slatePlayerNames: names)
            return dk.isEmpty ? nil : dk
        }()

        // Phase 2.5: augment the NHL pool with DK-eligible players that
        // ESPN's roster didn't return (call-ups, deep-bench skaters that
        // appear on LineupHQ but not in ESPN's top-14-per-team). Without
        // this, a bot's saved lineup that references one of these IDs
        // can't be resolved at display time and shows as "Unknown".
        //
        // Bot-draftability gate: injected players default to
        // isConfirmedActive=false AND playedRecently=false. The NHL bot
        // generator's existing filters (DFSViewModel.swift lines ~1784,
        // ~1770) already exclude such players from bot lineups, so this
        // ONLY makes them available to the human builder / lineup
        // resolver — bots won't draft them unless ESPN data later proves
        // they actually played.
        //
        // For MAIN slate (multi-game days), pull the full classic
        // LineupHQ pool — same injection rule (visible to user, hidden
        // from bots without proven recency).
        if !isSingleGame {
            let classicPlayers = await RotoGrindersSalaryProvider.shared.fetchClassicPlayersFromMaster(sport: "nhl")
            if !classicPlayers.isEmpty {
                nhlSlatePlayers = classicPlayers
            }
        }
        if !nhlSlatePlayers.isEmpty {
            let ourNames = Set(sortedPlayers.map { RotoGrindersSalaryProvider.normalizeName($0.name) })
            let fullNHLRosterByName: [String: DFSPlayer] = Dictionary(uniqueKeysWithValues:
                sortedPlayers.map { (RotoGrindersSalaryProvider.normalizeName($0.name), $0) }
            )
            let firstGameID = includedGames.first?.id ?? ""
            var augmented = sortedPlayers
            var injectedNames: [String] = []
            var skippedAlreadyInPool = 0
            for rg in nhlSlatePlayers {
                let normalized = RotoGrindersSalaryProvider.normalizeName(rg.fullName)
                if ourNames.contains(normalized) {
                    skippedAlreadyInPool += 1
                    continue
                }
                let rosterMatch = fullNHLRosterByName[normalized]
                let resolvedID = rosterMatch?.id
                    ?? "nhl-\(rg.dkPlayerID ?? rg.rgPlayerID ?? rg.normalizedName)"
                var injected = DFSPlayer(
                    id: resolvedID,
                    name: rg.fullName,
                    team: rosterMatch?.team ?? "",
                    position: rg.position,
                    salary: rg.utilSalary,
                    projectedPoints: rosterMatch?.projectedPoints ?? 0,
                    gameID: firstGameID,
                    injuryStatus: nil
                )
                // Bots skip players without confirmed activity / recency
                // (see NHL filters in DFSViewModel.generateBotLineup).
                // User can still see and pick them, but bots won't.
                injected.isConfirmedActive = false
                injected.playedRecently = false
                injected.gamesPlayed = 0
                augmented.append(injected)
                injectedNames.append(rg.fullName)
            }
            if !injectedNames.isEmpty {
                let preview = injectedNames.prefix(10).joined(separator: ", ")
                print("[NHL-DFS-2.5] injected \(injectedNames.count) DK-eligible players missing from ESPN pool (\(skippedAlreadyInPool) already in pool): \(preview)\(injectedNames.count > 10 ? "…" : "")")
            } else {
                print("[NHL-DFS-2.5] no missing players to inject (LineupHQ had \(nhlSlatePlayers.count), \(skippedAlreadyInPool) already in pool)")
            }
            sortedPlayers = augmented.sorted(by: { $0.salary > $1.salary })
        }

        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: "NHL",
            mainSalaryCap: 50000,
            mainLineupSize: 9,
            mainRosterSlots: ["C", "C", "W", "W", "D", "D", "UTIL", "UTIL", "G"],
            isSingleGameSlate: isSingleGame,
            includedGames: includedGames,
            mainPlayers: sortedPlayers,
            showdownSalaries: dkShowdownSalaries
        )

        let slate = DFSSlate(
            tournaments: tournaments,
            includedGames: includedGames,
            players: sortedPlayers,
            singleGamePlayers: sgPlayers
        )
        cache.setSlate(slate, key: "nhl")
        return slate
    }

    // MARK: - ESPN NHL API

    private func fetchNHLEvents() async throws -> [NBAScoreboardEvent] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let dateKeys = [dateKey(for: yesterday), dateKey(for: Date()), dateKey(for: tomorrow)]

        let allScoreboards: [NBAScoreboardResponse] = await withTaskGroup(of: NBAScoreboardResponse?.self) { group in
            for dk in dateKeys {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/scoreboard?dates=\(dk)") else {
                        return nil
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return nil
                    }
                    return try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data)
                }
            }
            var results: [NBAScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        var preEvents: [NBAScoreboardEvent] = []
        var liveEvents: [NBAScoreboardEvent] = []
        var postEvents: [NBAScoreboardEvent] = []

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for scoreboard in allScoreboards {
            for event in scoreboard.events {
                guard let competition = event.competitions.first else { continue }
                let state = competition.status.type.state
                // Accept "pre" games from today or later. A game that is "pre" but
                // whose scheduled start has already passed (delayed tip-off/puck drop)
                // must still be included — ESPN's state is authoritative.
                if state == "pre" && calendar.startOfDay(for: event.date) >= today {
                    preEvents.append(event)
                } else if state == "in" {
                    liveEvents.append(event)
                } else if state == "post" {
                    postEvents.append(event)
                }
            }
        }

        // If there are live games, include them AND finished/upcoming games from the same slate day
        if !liveEvents.isEmpty {
            let liveDay = calendar.startOfDay(for: liveEvents.first!.date)
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            return (liveEvents + sameDayPost + sameDayPre).sorted(by: { $0.date < $1.date })
        }

        // All-day slate: if there are finished (post) games from the same day as upcoming
        // (pre) games, include BOTH so the slate doesn't shrink when early games finish
        // before late games start.
        if !preEvents.isEmpty {
            let groupedByDay = Dictionary(grouping: preEvents) { calendar.startOfDay(for: $0.date) }
            if let todayGames = groupedByDay[today], !todayGames.isEmpty {
                let todaysPost = postEvents.filter { calendar.startOfDay(for: $0.date) == today }
                return (todayGames + todaysPost).sorted(by: { $0.date < $1.date })
            }
            if let selectedDay = groupedByDay.keys.sorted().first {
                let sameDayPre = groupedByDay[selectedDay] ?? []
                let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == selectedDay }
                return (sameDayPre + sameDayPost).sorted(by: { $0.date < $1.date })
            }
            return preEvents
        }

        if !postEvents.isEmpty {
            let todaysPost = postEvents.filter { calendar.startOfDay(for: $0.date) == today }
            if !todaysPost.isEmpty {
                return todaysPost.sorted(by: { $0.date < $1.date })
            }
            let groupedByDay = Dictionary(grouping: postEvents) { calendar.startOfDay(for: $0.date) }
            if let mostRecentDay = groupedByDay.keys.sorted().last {
                return (groupedByDay[mostRecentDay] ?? []).sorted(by: { $0.date < $1.date })
            }
        }

        return []
    }

    private func uniqueTeams(from events: [NBAScoreboardEvent]) -> [NBATeamRef] {
        var seen = Set<String>()
        var result: [NBATeamRef] = []
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                let id = competitor.team.id
                guard seen.insert(id).inserted else { continue }
                result.append(NBATeamRef(id: id, abbreviation: competitor.team.abbreviation))
            }
        }
        return result
    }

    private func fetchNHLRoster(teamID: String, teamAbbreviation: String, gameID: String?, ratings: [String: (fppg: Double, gamesPlayed: Int)], recentlyActiveIDs: Set<String> = []) async throws -> [DFSPlayer] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/teams/\(teamID)/roster") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        // NHL roster API returns categories (Forwards, Defensemen, Goalies) with nested items
        let athletes: [NBARosterAthlete]
        if let mlbRoster = try? JSONDecoder().decode(MLBRosterResponse.self, from: data) {
            athletes = mlbRoster.allAthletes
        } else if let flatRoster = try? JSONDecoder().decode(NBARosterResponse.self, from: data) {
            athletes = flatRoster.athletes
        } else {
            return []
        }

        let players = athletes.map { athlete in
            let position = mapNHLPosition(athlete.position?.abbreviation)
            let ratingInfo = ratings[athlete.id]
            let fppg = ratingInfo?.fppg ?? 0.0
            let gp = ratingInfo?.gamesPlayed
            let isGoalie = position == "G"
            let salary = nhlEstimatedSalary(fppg: fppg, isGoalie: isGoalie, playerID: athlete.id)
            let projection = nhlProjectedPoints(fppg: fppg, position: position, playerID: athlete.id)

            let injuryStatus: String?
            if let injury = athlete.injuries?.first, let status = injury.status {
                switch status.lowercased() {
                case "out": injuryStatus = "O"
                case "day-to-day": injuryStatus = "GTD"
                case "injured-reserve", "ir": injuryStatus = "IR"
                default: injuryStatus = nil
                }
            } else {
                injuryStatus = nil
            }

            var player = DFSPlayer(
                id: "nhl-\(athlete.id)",
                name: athlete.fullName,
                team: teamAbbreviation,
                position: position,
                salary: salary,
                projectedPoints: projection,
                gameID: gameID,
                injuryStatus: injuryStatus
            )
            player.gamesPlayed = gp
            // Mark recency: if we have boxscore data, check if this player appeared;
            // if no boxscore data was available (empty set), assume recently active
            if !recentlyActiveIDs.isEmpty {
                player.playedRecently = recentlyActiveIDs.contains(athlete.id)
            }
            return player
        }
        .sorted { $0.projectedPoints > $1.projectedPoints }

        return players
    }

    /// Maps ESPN NHL position abbreviations to FanDuel DFS positions
    /// ESPN: C, LW, RW, D, G → FanDuel: C, W (LW+RW), D, G
    private func mapNHLPosition(_ raw: String?) -> String {
        guard let raw else { return "C" }
        switch raw.uppercased() {
        case "C": return "C"
        case "LW", "RW", "F": return "W"
        case "D": return "D"
        case "G": return "G"
        default: return "C"
        }
    }

    /// Fetch per-player FPPG ratings from ESPN team statistics
    /// NHL stat names: goals, assists, shots, blockedShots, powerPlayGoals, powerPlayAssists,
    /// shortHandedGoals, shortHandedAssists, saves, goalsAgainst, wins, shutouts
    private func fetchNHLRatings(teamID: String) async -> [String: (fppg: Double, gamesPlayed: Int)] {
        let base = "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/teams/\(teamID)/athletes/statistics"
        let priorYear = Calendar.current.component(.year, from: Date()) - 1
        let urls = [
            "\(base)?season=\(priorYear)&seasontype=2",
            base
        ]

        var ratings: [String: (fppg: Double, gamesPlayed: Int)] = [:]
        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { continue }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { continue }

            for resultBlock in results {
                guard let leaders = resultBlock["leaders"] as? [[String: Any]] else { continue }
                for leader in leaders {
                    guard let athlete = leader["athlete"] as? [String: Any],
                          let athleteID = athlete["id"] as? String,
                          let statistics = leader["statistics"] as? [[String: Any]] else { continue }

                    if ratings[athleteID] != nil { continue }

                    var gamesPlayed: Double = 0
                    var goals: Double = 0, assists: Double = 0
                    var shots: Double = 0, blockedShots: Double = 0
                    var ppGoals: Double = 0, ppAssists: Double = 0
                    var shGoals: Double = 0, shAssists: Double = 0
                    var saves: Double = 0, goalsAgainst: Double = 0
                    var wins: Double = 0, shutouts: Double = 0
                    var isGoalie = false

                    for section in statistics {
                        guard let stats = section["stats"] as? [[String: Any]] else { continue }
                        for stat in stats {
                            guard let name = stat["name"] as? String,
                                  let value = stat["value"] as? Double else { continue }
                            switch name {
                            case "games", "gamesPlayed": gamesPlayed = max(gamesPlayed, value)
                            case "goals": goals = value
                            case "assists": assists = value
                            case "shots", "shotsOnGoal", "shotsTotal": shots = value
                            case "blockedShots": blockedShots = value
                            case "powerPlayGoals": ppGoals = value
                            case "powerPlayAssists": ppAssists = value
                            case "shortHandedGoals": shGoals = value
                            case "shortHandedAssists": shAssists = value
                            case "saves": saves = value; isGoalie = true
                            case "goalsAgainst": goalsAgainst = value; isGoalie = true
                            case "wins": wins = value
                            case "shutouts": shutouts = value
                            default: break
                            }
                        }
                    }

                    guard gamesPlayed > 0 else { continue }

                    var fppg: Double
                    if isGoalie {
                        // Goalie: W*12 + SO*8 + SV*0.8 + GA*(-4)
                        let totalFP = wins * 12.0 + shutouts * 8.0 + saves * 0.8 - goalsAgainst * 4.0
                        fppg = totalFP / gamesPlayed
                    } else {
                        // Skater: G*12 + A*8 + SOG*1.6 + BLK*1.6 + PPG*0.5 + PPA*0.5 + SHG*2 + SHA*2
                        let totalFP = goals * 12.0 + assists * 8.0 + shots * 1.6 + blockedShots * 1.6
                            + ppGoals * 0.5 + ppAssists * 0.5 + shGoals * 2.0 + shAssists * 2.0
                        fppg = totalFP / gamesPlayed
                    }
                    // Penalize players with very few games — likely AHL call-ups
                    // or recently recalled players who may not dress tonight.
                    if gamesPlayed < 5 {
                        fppg *= 0.4  // Heavy discount for tiny sample
                    } else if gamesPlayed < 15 {
                        fppg *= 0.7  // Moderate discount for small sample
                    }
                    ratings[athleteID] = (fppg: fppg, gamesPlayed: Int(gamesPlayed))
                }
            }
        }
        return ratings
    }

    /// Fetch the set of ESPN athlete IDs who appeared in each team's most recent
    /// completed game. Uses the ESPN event summary endpoint for the team's last
    /// finished game from the past few days. Returns a set of raw ESPN IDs (without
    /// the "nhl-" prefix) — callers must compare accordingly.
    func fetchNHLRecentlyActivePlayerIDs(teamIDs: [String]) async -> Set<String> {
        // Fetch recent scores (last 3 days) to find completed games per team
        let calendar = Calendar.current
        var recentEventsByTeam: [String: String] = [:]  // teamID → most recent completed eventID

        // Look back 7 days — NHL playoff teams often have 3-5 rest days between games,
        // so a 3-day window misses a team's most recent box score and leaves their
        // roster's playedRecently flag at default-true, slipping DNPs through.
        let datesToCheck = (-7...(-1)).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
        let dateStrings = datesToCheck.map { dateKey(for: $0) }

        // Fetch scoreboards for recent days
        let recentScoreboards: [NBAScoreboardResponse] = await withTaskGroup(of: NBAScoreboardResponse?.self) { group in
            for dk in dateStrings {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/scoreboard?dates=\(dk)") else { return nil }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    return try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data)
                }
            }
            var results: [NBAScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        // Find most recent completed game for each team playing tonight
        let teamIDSet = Set(teamIDs)
        var allEvents: [(date: Date, eventID: String, teamIDs: [String])] = []
        for sb in recentScoreboards {
            for event in sb.events {
                guard let comp = event.competitions.first,
                      comp.status.type.state == "post" else { continue }
                let eventTeamIDs = comp.competitors.map { $0.team.id }
                allEvents.append((date: event.date, eventID: event.id, teamIDs: eventTeamIDs))
            }
        }
        // Sort newest first
        allEvents.sort { $0.date > $1.date }
        for event in allEvents {
            for tid in event.teamIDs where teamIDSet.contains(tid) {
                if recentEventsByTeam[tid] == nil {
                    recentEventsByTeam[tid] = event.eventID
                }
            }
        }

        guard !recentEventsByTeam.isEmpty else { return [] }

        // Fetch boxscores for each recent event in parallel
        let uniqueEventIDs = Set(recentEventsByTeam.values)
        let activeIDs: Set<String> = await withTaskGroup(of: Set<String>.self) { group in
            for eventID in uniqueEventIDs {
                group.addTask {
                    await self.fetchBoxscorePlayerIDs(eventID: eventID)
                }
            }
            var combined = Set<String>()
            for await ids in group {
                combined.formUnion(ids)
            }
            return combined
        }

        print("[NHL-DFS] Found \(activeIDs.count) recently active players from \(uniqueEventIDs.count) recent game boxscores")
        return activeIDs
    }

    /// For each team in `teamIDs`, returns the ESPN athlete ID of the goalie
    /// who started in their most recent completed game (identified by the
    /// "goalies" stat group + highest time-on-ice). Used as a second source
    /// alongside ESPN's `probables` so:
    ///   • teams with no probable still get a starter marked (probables feed
    ///     intermittently misses teams entirely)
    ///   • when probable and recent-starter disagree (rare, e.g. last-minute
    ///     scratch announcement after probables were set), we can flag both
    ///     as candidates instead of locking ownership onto a stale name.
    /// Returns map of teamID → most-recent-starter ESPN athlete id.
    func fetchRecentStartingGoalies(teamIDs: [String]) async -> [String: String] {
        let calendar = Calendar.current
        let datesToCheck = (-7...(-1)).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
        let dateStrings = datesToCheck.map { dateKey(for: $0) }

        let recentScoreboards: [NBAScoreboardResponse] = await withTaskGroup(of: NBAScoreboardResponse?.self) { group in
            for dk in dateStrings {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/scoreboard?dates=\(dk)") else { return nil }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    return try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data)
                }
            }
            var results: [NBAScoreboardResponse] = []
            for await r in group { if let r { results.append(r) } }
            return results
        }

        // Map team → most recent completed eventID
        let teamIDSet = Set(teamIDs)
        var allEvents: [(date: Date, eventID: String, teamIDs: [String])] = []
        for sb in recentScoreboards {
            for event in sb.events {
                guard let comp = event.competitions.first,
                      comp.status.type.state == "post" else { continue }
                allEvents.append((date: event.date, eventID: event.id, teamIDs: comp.competitors.map { $0.team.id }))
            }
        }
        allEvents.sort { $0.date > $1.date }
        var recentEventByTeam: [String: String] = [:]
        for event in allEvents {
            for tid in event.teamIDs where teamIDSet.contains(tid) {
                if recentEventByTeam[tid] == nil { recentEventByTeam[tid] = event.eventID }
            }
        }
        guard !recentEventByTeam.isEmpty else { return [:] }

        // Fetch boxscores in parallel, extract starting goalie per team
        let result: [String: String] = await withTaskGroup(of: (String, String?).self) { group in
            for (teamID, eventID) in recentEventByTeam {
                group.addTask {
                    let starter = await self.startingGoalieFromBoxscore(eventID: eventID, teamID: teamID)
                    return (teamID, starter)
                }
            }
            var dict: [String: String] = [:]
            for await (teamID, starter) in group {
                if let s = starter { dict[teamID] = s }
            }
            return dict
        }
        print("[NHL-DFS] Recent starting goalies: \(result.count) teams resolved")
        return result
    }

    /// Pulls the starting goalie from a single boxscore: the athlete in the
    /// "goalies" stat group with the highest time-on-ice (TOI). Returns the
    /// ESPN athlete id (numeric string) or nil if the boxscore is missing
    /// or both goalies have ≤ 30 min TOI (split start, no clear starter).
    private func startingGoalieFromBoxscore(eventID: String, teamID: String) async -> String? {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/summary?event=\(eventID)") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boxscore = json["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else { return nil }

        // Find the matching team block
        var teamBlock: [String: Any]? = nil
        for block in players {
            let team = (block["team"] as? [String: Any])
            let id = team?["id"] as? String
            if id == teamID { teamBlock = block; break }
        }
        guard let teamBlock else { return nil }
        guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { return nil }

        // Locate the goalies group (name = "goalies" or label = "Goalies")
        var goalieGroup: [String: Any]? = nil
        for group in statistics {
            let name = (group["name"] as? String)?.lowercased() ?? ""
            let label = (group["text"] as? String)?.lowercased() ?? ""
            if name.contains("goalie") || label.contains("goalie") {
                goalieGroup = group
                break
            }
        }
        guard let goalieGroup,
              let goalieKeys = goalieGroup["keys"] as? [String],
              let athletes = goalieGroup["athletes"] as? [[String: Any]] else { return nil }

        // TOI is usually a stat keyed "timeOnIce" or labeled "TOI". Index
        // varies per ESPN response; find the column dynamically.
        let toiKeyIdx = goalieKeys.firstIndex(where: { $0.lowercased().contains("timeonice") || $0.lowercased() == "toi" })

        var best: (athleteID: String, toiSeconds: Int)? = nil
        for athlete in athletes {
            guard let info = athlete["athlete"] as? [String: Any],
                  let id = info["id"] as? String,
                  let stats = athlete["stats"] as? [String] else { continue }
            // Parse TOI as "mm:ss" → seconds. Fallback to count of stats if
            // column not found (still picks any goalie that played).
            var toiSeconds = 0
            if let idx = toiKeyIdx, idx < stats.count {
                let parts = stats[idx].split(separator: ":")
                if parts.count == 2,
                   let m = Int(parts[0]), let s = Int(parts[1]) {
                    toiSeconds = m * 60 + s
                }
            }
            if best == nil || toiSeconds > best!.toiSeconds {
                best = (id, toiSeconds)
            }
        }
        // Require ≥ 30 min TOI so split starts (both goalies in net) don't
        // produce a misleading starter id.
        guard let best, best.toiSeconds >= 30 * 60 else { return nil }
        return best.athleteID
    }

    /// Extract all player IDs from an ESPN NHL event boxscore
    private func fetchBoxscorePlayerIDs(eventID: String) async -> Set<String> {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/summary?event=\(eventID)") else {
            return []
        }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boxscore = json["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        var ids = Set<String>()
        for teamBlock in players {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }
            for statGroup in statistics {
                guard let athletes = statGroup["athletes"] as? [[String: Any]] else { continue }
                for athlete in athletes {
                    if let athleteInfo = athlete["athlete"] as? [String: Any],
                       let athleteID = athleteInfo["id"] as? String {
                        ids.insert(athleteID)
                    }
                }
            }
        }
        return ids
    }

    /// FanDuel-style NHL salary mapping ($55K cap, 9-player lineup)
    /// Real FanDuel FPPG ranges: elite skaters ~14-18, good ~10-14, mid ~6-10, low <6
    /// Goalies: starters $7K-$8.5K, backups $6K-$7K
    private func nhlEstimatedSalary(fppg: Double, isGoalie: Bool, playerID: String) -> Int {
        let stableHash = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let hashFraction = Double(abs(stableHash % 1000)) / 1000.0

        let salary: Int
        if fppg <= 0 {
            if isGoalie {
                salary = Int(6500.0 + 500.0 * hashFraction)
            } else {
                salary = Int(3500.0 + 1000.0 * hashFraction)
            }
        } else if isGoalie {
            // Goalie tiers — FanDuel starters $7K-$8.5K, backups $6K-$7K
            if fppg >= 16 {
                // Elite starter (Bobrovsky, Shesterkin)
                let fraction = min(1.0, (fppg - 16.0) / 6.0)
                salary = 7800 + Int(fraction * 700.0)
            } else if fppg >= 10 {
                // Solid starter
                let fraction = (fppg - 10.0) / 6.0
                salary = 7000 + Int(fraction * 800.0)
            } else if fppg >= 5 {
                // Backup / platoon
                let fraction = (fppg - 5.0) / 5.0
                salary = 6200 + Int(fraction * 800.0)
            } else {
                salary = 6000 + Int(max(0, fppg) / 5.0 * 200.0)
            }
        } else {
            // Skater tiers — calibrated to real FanDuel NHL pricing
            // McDavid/Crosby ~15-18 FPPG → $8.5K-$9.5K
            // Stars ~12-15 → $7K-$8.5K
            // Top-six ~8-12 → $5.5K-$7K
            // Bottom-six ~4-8 → $4K-$5.5K
            // Low <4 → $3.5K-$4K
            if fppg >= 15 {
                // Superstar (McDavid, Crosby, Kucherov)
                let fraction = min(1.0, (fppg - 15.0) / 5.0)
                salary = 8500 + Int(fraction * 1000.0)
            } else if fppg >= 12 {
                // Star (Draisaitl, MacKinnon, Makar)
                let fraction = (fppg - 12.0) / 3.0
                salary = 7000 + Int(fraction * 1500.0)
            } else if fppg >= 8 {
                // Top-six forward / top-4 D
                let fraction = (fppg - 8.0) / 4.0
                salary = 5500 + Int(fraction * 1500.0)
            } else if fppg >= 4 {
                // Bottom-six / depth D
                let fraction = (fppg - 4.0) / 4.0
                salary = 4000 + Int(fraction * 1500.0)
            } else {
                // Minimum salary players
                salary = 3500 + Int(max(0, fppg) / 4.0 * 500.0)
            }
        }

        let jitter = abs(stableHash % 200) - 100
        let raw = max(3500, min(9500, salary + jitter))
        // Round to nearest $100 to match DraftKings salary increments
        return (raw / 100) * 100
    }

    /// NHL projected points: FPPG with mild regression to position mean
    private func nhlProjectedPoints(fppg: Double, position: String, playerID: String) -> Double {
        let positionAvg: Double
        switch position {
        case "C": positionAvg = 10.0
        case "W": positionAvg = 8.0
        case "D": positionAvg = 7.0
        case "G": positionAvg = 10.0
        default: positionAvg = 8.0
        }
        if fppg <= 0 {
            // No season stats — likely AHL/reserve player or healthy scratch.
            // Return 0.5 so they fall below the bot eligibility threshold (> 1.0).
            return 0.5
        }
        let projected = fppg * 0.85 + positionAvg * 0.15
        return (projected * 10).rounded() / 10
    }

    private func deduplicatePlayers(_ players: [DFSPlayer]) -> [DFSPlayer] {
        var seen = Set<String>()
        return players.filter { seen.insert($0.id).inserted }
    }

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - NHL Live Scoring Provider

struct ESPNNHLDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }

    private struct GameFetchResult: Sendable {
        let gameID: String
        let gameInfo: DFSGameLiveInfo
        let playerResults: [(String, Double, DFSPlayerLiveStats)]
        let isFinal: Bool
    }

    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        let gameIDs = Set(games.map { $0.id })
        if let cached = LiveScoreCache.shared.get(gameIDs: gameIDs) {
            return cached
        }

        let results: [GameFetchResult] = await withTaskGroup(of: GameFetchResult?.self) { group in
            for game in games {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/summary?event=\(game.id)") else {
                        return nil
                    }

                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        print("[NHL-Score] Failed to fetch summary for event \(game.id)")
                        return nil
                    }

                    let gameInfo = self.extractGameLiveInfo(payload: payload, game: game)
                    let gameFinal = gameInfo.state == "post"
                    let playerResults: [(String, Double, DFSPlayerLiveStats)]
                    if gameInfo.state == "pre" {
                        playerResults = []
                    } else {
                        playerResults = self.extractNHLPlayerStats(payload: payload, gameStatus: gameInfo.displayStatus, gameFinal: gameFinal)
                    }
                    print("[NHL-Score] Game \(game.id) (\(game.awayTeam)@\(game.homeTeam)): state=\(gameInfo.state), \(playerResults.count) players scored, final=\(gameFinal)")

                    return GameFetchResult(
                        gameID: game.id,
                        gameInfo: gameInfo,
                        playerResults: playerResults,
                        isFinal: gameFinal
                    )
                }
            }

            var collected: [GameFetchResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfoByID: [String: DFSGameLiveInfo] = [:]

        let fetchedGameIDs = Set(results.map { $0.gameID })
        let failedGames = games.filter { !fetchedGameIDs.contains($0.id) }
        var allFetchedAreFinal = true

        for result in results {
            gameLiveInfoByID[result.gameID] = result.gameInfo
            if !result.isFinal { allFetchedAreFinal = false }
            for (playerID, fantasy, stats) in result.playerResults {
                pointsByPlayerID[playerID] = fantasy
                statsByPlayerID[playerID] = stats
            }
        }

        // A game we couldn't fetch is NOT assumed done unless its start is long
        // past (a broken/stale event). ESPN endpoints 404 for games that haven't
        // started, so a staggered slate's late game must keep the slate LIVE
        // until it actually finishes rather than be tolerated as a failed fetch
        // (which would settle the contest before the late game is played).
        let staleFetchCutoff: TimeInterval = 8 * 3600
        let unfetchedStillPending = failedGames.contains { Date().timeIntervalSince($0.startTime) < staleFetchCutoff }
        let allGamesFinal = allFetchedAreFinal && !results.isEmpty && !unfetchedStillPending

        print("[NHL-Score] Total: \(results.count)/\(games.count) games fetched, \(pointsByPlayerID.count) player scores, failed=\(failedGames.count)")

        let snapshot = DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfoByID,
            allGamesFinal: allGamesFinal
        )
        LiveScoreCache.shared.set(snapshot, gameIDs: gameIDs)
        return snapshot
    }

    nonisolated private func extractGameLiveInfo(payload: [String: Any], game: DFSSlateGame) -> DFSGameLiveInfo {
        var awayScore = 0, homeScore = 0
        var clock = "", period = 1, state = "pre"

        if let header = payload["header"] as? [String: Any],
           let competitions = header["competitions"] as? [[String: Any]],
           let competition = competitions.first {

            if let status = competition["status"] as? [String: Any],
               let typeInfo = status["type"] as? [String: Any],
               let stateStr = typeInfo["state"] as? String {
                state = stateStr
            }

            if let status = competition["status"] as? [String: Any] {
                clock = status["displayClock"] as? String ?? ""
                period = status["period"] as? Int ?? 1
            }

            if let competitors = competition["competitors"] as? [[String: Any]] {
                for competitor in competitors {
                    let score = Int(competitor["score"] as? String ?? "0") ?? 0
                    let homeAway = competitor["homeAway"] as? String ?? ""
                    if homeAway == "home" { homeScore = score }
                    else { awayScore = score }
                }
            }
        }

        return DFSGameLiveInfo(
            id: game.id,
            awayTeam: game.awayTeam,
            homeTeam: game.homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            clock: clock,
            period: period,
            state: state,
            sportType: "nhl"
        )
    }

    /// Parse NHL boxscore data. ESPN separates goalies ("goaltending") and skaters ("skating")
    nonisolated private func extractNHLPlayerStats(
        payload: [String: Any],
        gameStatus: String,
        gameFinal: Bool
    ) -> [(String, Double, DFSPlayerLiveStats)] {
        guard let boxscore = payload["boxscore"] as? [String: Any],
              let playersArr = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        var results: [(String, Double, DFSPlayerLiveStats)] = []

        for teamBlock in playersArr {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }

            for statCategory in statistics {
                guard let labels = statCategory["labels"] as? [String],
                      let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }

                let categoryName = (statCategory["type"] as? String)
                    ?? (statCategory["name"] as? String)
                    ?? ""

                var labelIndex: [String: Int] = [:]
                for (i, label) in labels.enumerated() {
                    labelIndex[label.uppercased()] = i
                }

                let isGoaltending = categoryName.lowercased().contains("goaltend") || categoryName.lowercased().contains("goalie")

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          let values = athlete["stats"] as? [String] else { continue }

                    let athleteName = (athleteInfo["displayName"] as? String)
                        ?? (athleteInfo["shortName"] as? String)
                        ?? "Player \(athleteID)"

                    func strStat(_ keys: [String]) -> String {
                        for key in keys {
                            if let idx = labelIndex[key.uppercased()], idx < values.count {
                                return values[idx]
                            }
                        }
                        return "0"
                    }
                    func intStat(_ keys: [String]) -> Int {
                        Int(Double(strStat(keys)) ?? 0)
                    }

                    let fantasy: Double
                    let playerID = "nhl-\(athleteID)"

                    if isGoaltending {
                        // Goalie stats: SV (saves), GA (goals against), W (wins), SO (shutouts)
                        let sv = intStat(["SV", "SAVES"])
                        let ga = intStat(["GA", "GOALSAGAINST"])
                        let w = intStat(["W", "WINS"])
                        // Shutout: ESPN may not have a direct column — infer from GA==0 and game final
                        let soColumn = intStat(["SO", "SHUTOUTS"])
                        let so = soColumn > 0 ? soColumn : (ga == 0 && gameFinal ? 1 : 0)

                        // FanDuel Goalie: W*12 + SO*8 + SV*0.8 + GA*(-4)
                        fantasy = Double(w) * 12.0 + Double(so) * 8.0 + Double(sv) * 0.8 - Double(ga) * 4.0

                        // Map into DFSPlayerLiveStats: points=SV, rebounds=GA, assists=W, steals=SO
                        // minutes="G" marks this player as a goalie for display purposes
                        let stats = DFSPlayerLiveStats(
                            name: athleteName,
                            points: sv, rebounds: ga, assists: w,
                            steals: so, blocks: 0, turnovers: 0,
                            minutes: "G",
                            fgm: 0, fga: 0, threePM: 0, threePA: 0, ftm: 0, fta: 0,
                            fantasyPoints: fantasy,
                            gameStatus: gameStatus,
                            gameFinal: gameFinal
                        )
                        results.append((playerID, fantasy, stats))
                    } else {
                        // Skater stats: G (goals), A (assists), SOG (shots on goal), BLK (blocked shots)
                        // PP and SH bonuses from PPG/PPA/SHG/SHA columns
                        let g = intStat(["G", "GOALS"])
                        let a = intStat(["A", "ASSISTS"])
                        let sog = intStat(["SOG", "S", "SHOTS"])
                        let blk = intStat(["BLK", "BS", "BLOCKEDSHOTS"])
                        let ppg = intStat(["PPG", "PPGOALS", "POWERPLAYGOALS"])
                        let ppa = intStat(["PPA", "PPASSISTS", "POWERPLAYASSISTS"])
                        let shg = intStat(["SHG", "SHGOALS", "SHORTHANDEDGOALS"])
                        let sha = intStat(["SHA", "SHASSISTS", "SHORTHANDEDASSISTS"])

                        // FanDuel Skater: G*12 + A*8 + SOG*1.6 + BLK*1.6 + PPG*0.5 + PPA*0.5 + SHG*2 + SHA*2
                        fantasy = Double(g) * 12.0 + Double(a) * 8.0
                            + Double(sog) * 1.6 + Double(blk) * 1.6
                            + Double(ppg) * 0.5 + Double(ppa) * 0.5
                            + Double(shg) * 2.0 + Double(sha) * 2.0

                        // Map into DFSPlayerLiveStats: points=G, rebounds=A, assists=SOG, steals=BLK
                        let stats = DFSPlayerLiveStats(
                            name: athleteName,
                            points: g, rebounds: a, assists: sog,
                            steals: blk, blocks: ppg + ppa, turnovers: shg + sha,
                            minutes: "",
                            fgm: g, fga: a, threePM: sog, threePA: blk,
                            ftm: ppg + ppa, fta: shg + sha,
                            fantasyPoints: fantasy,
                            gameStatus: gameStatus,
                            gameFinal: gameFinal
                        )
                        results.append((playerID, fantasy, stats))
                    }
                }
            }
        }
        return results
    }
}

struct MockDFSSlateProvider: DFSSlateProvider {
    func fetchSlate() async throws -> DFSSlate {
        DFSSlate(
            tournament: DFSTournament(
                id: "mock-dfs-tod",
                title: "Free Tournament of the Day",
                league: "NBA",
                entryCount: 250,
                lineupSize: 8,
                salaryCap: 50000
            ),
            includedGames: [
                DFSSlateGame(id: "mock-lal-bos", awayTeam: "LAL", homeTeam: "BOS", startTime: .now.addingTimeInterval(60 * 60 * 2)),
                DFSSlateGame(id: "mock-gsw-sac", awayTeam: "GSW", homeTeam: "SAC", startTime: .now.addingTimeInterval(60 * 60 * 3))
            ],
            players: [
                DFSPlayer(id: "p1", name: "Jayson Tatum", team: "BOS", position: "SF", salary: 11200, projectedPoints: 48.3),
                DFSPlayer(id: "p2", name: "Jaylen Brown", team: "BOS", position: "SG", salary: 8900, projectedPoints: 39.6),
                DFSPlayer(id: "p3", name: "LeBron James", team: "LAL", position: "SF", salary: 10800, projectedPoints: 47.1),
                DFSPlayer(id: "p4", name: "Anthony Davis", team: "LAL", position: "PF", salary: 10400, projectedPoints: 45.9),
                DFSPlayer(id: "p5", name: "Stephen Curry", team: "GSW", position: "PG", salary: 10100, projectedPoints: 44.8),
                DFSPlayer(id: "p6", name: "Jimmy Butler", team: "MIA", position: "SF", salary: 8600, projectedPoints: 37.2),
                DFSPlayer(id: "p7", name: "Donovan Mitchell", team: "CLE", position: "SG", salary: 9300, projectedPoints: 40.8),
                DFSPlayer(id: "p8", name: "Domantas Sabonis", team: "SAC", position: "C", salary: 9400, projectedPoints: 41.2),
                DFSPlayer(id: "p9", name: "Myles Turner", team: "IND", position: "C", salary: 7200, projectedPoints: 31.4),
                DFSPlayer(id: "p10", name: "Tyrese Haliburton", team: "IND", position: "PG", salary: 9800, projectedPoints: 42.7),
                DFSPlayer(id: "p11", name: "RJ Barrett", team: "TOR", position: "SG", salary: 6300, projectedPoints: 27.2),
                DFSPlayer(id: "p12", name: "Cam Thomas", team: "BKN", position: "SG", salary: 6600, projectedPoints: 28.6)
            ]
        )
    }
}

/// Fetches NBA slate games for a specific date key (YYYYMMDD format) from ESPN.
/// Returns the games as DFSSlateGame objects suitable for live scoring.
func fetchSlateGamesForDate(_ dateKey: String) async -> [DFSSlateGame] {
    return await fetchSlateGamesForDate(dateKey, espnSport: "basketball/nba")
}

func fetchSlateGamesForDate(_ dateKey: String, espnSport: String) async -> [DFSSlateGame] {
    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(espnSport)/scoreboard?dates=\(dateKey)") else { return [] }
    guard let (data, response) = try? await URLSession.shared.data(from: url),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let scoreboard = try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data) else { return [] }

    return scoreboard.events.compactMap { event in
        guard let competition = event.competitions.first else { return nil }
        guard let away = competition.competitors.first(where: { $0.homeAway == "away" }) else { return nil }
        guard let home = competition.competitors.first(where: { $0.homeAway == "home" }) else { return nil }
        return DFSSlateGame(
            id: event.id,
            awayTeam: away.team.abbreviation,
            homeTeam: home.team.abbreviation,
            startTime: event.date,
            state: competition.status.type.state
        )
    }
}

enum DFSEngine {
    static func simulateResult(for lineup: [DFSPlayer], tournament: DFSTournament) -> (rank: Int, points: Double, rrDelta: Int) {
        let lineupPoints = lineup.reduce(0.0) { partial, player in
            partial + player.projectedPoints + Double.random(in: -7.0...7.0)
        }

        let fieldScores: [Double] = (0..<max(0, tournament.entryCount - 1)).map { _ in
            Double.random(in: 130.0...250.0)
        }

        let betterCount = fieldScores.filter { $0 > lineupPoints }.count
        let rank = betterCount + 1

        let rrDelta = rrDelta(forRank: rank, entryCount: tournament.entryCount)

        return (rank, lineupPoints, rrDelta)
    }

    /// Entry-count-based payout table
    static func rrDelta(forRank rank: Int, entryCount: Int) -> Int {
        switch entryCount {
        case 2:    return rrDelta2Man(forRank: rank)
        case 3:    return rrDelta3Man(forRank: rank)
        case 5:    return rrDelta5Man(forRank: rank)
        case 10:   return rrDelta10Man(forRank: rank)
        case 100:  return rrDelta100Man(forRank: rank)
        case 500:  return rrDelta500Man(forRank: rank)
        case 1000: return rrDelta1000(forRank: rank)
        case 2000: return rrDelta2000Man(forRank: rank)
        default:   return rrDelta2000Man(forRank: rank)
        }
    }

    /// Legacy overload for backward compatibility
    static func rrDelta(forRank rank: Int, totalEntries: Int) -> Int {
        return rrDelta(forRank: rank, entryCount: totalEntries)
    }

    /// Pooled RR for a tie group: sums the RR for ranks `tiedRank..<(tiedRank+tieCount)`
    /// and divides evenly. E.g., 17 entries tied for 1st pool the top 17 payouts and split.
    static func pooledRRDelta(tiedRank: Int, tieCount: Int, entryCount: Int) -> Int {
        guard tieCount > 1 else { return rrDelta(forRank: tiedRank, entryCount: entryCount) }
        var totalPool = 0
        for r in tiedRank..<(tiedRank + tieCount) {
            totalPool += rrDelta(forRank: r, entryCount: entryCount)
        }
        return totalPool / tieCount
    }

    private static func rrDelta2Man(forRank rank: Int) -> Int {
        rank == 1 ? 10 : -10
    }

    private static func rrDelta3Man(forRank rank: Int) -> Int {
        rank == 1 ? 20 : -10
    }

    private static func rrDelta5Man(forRank rank: Int) -> Int {
        rank == 1 ? 40 : -10
    }

    private static func rrDelta10Man(forRank rank: Int) -> Int {
        switch rank {
        case 1:  return 40
        case 2:  return 20
        case 3:  return 10
        default: return -10
        }
    }

    private static func rrDelta100Man(forRank rank: Int) -> Int {
        switch rank {
        case 1:        return 350
        case 2:        return 200
        case 3:        return 120
        case 4:        return 80
        case 5:        return 60
        case 6...8:    return 40
        case 9...12:   return 30
        case 13...20:  return 20
        case 21...30:  return 10
        default:       return -10
        }
    }

    private static func rrDelta500Man(forRank rank: Int) -> Int {
        switch rank {
        case 1:         return 500
        case 2:         return 350
        case 3:         return 250
        case 4:         return 180
        case 5:         return 140
        case 6:         return 110
        case 7...8:     return 90
        case 9...12:    return 70
        case 13...18:   return 55
        case 19...27:   return 45
        case 28...40:   return 35
        case 41...60:   return 30
        case 61...90:   return 25
        case 91...150:  return 20
        default:        return -10
        }
    }

    private static func rrDelta1000(forRank rank: Int) -> Int {
        switch rank {
        case 1:         return 700
        case 2:         return 500
        case 3:         return 350
        case 4:         return 250
        case 5:         return 200
        case 6:         return 160
        case 7:         return 130
        case 8:         return 110
        case 9:         return 100
        case 10...12:   return 80
        case 13...15:   return 70
        case 16...18:   return 60
        case 19...27:   return 50
        case 28...36:   return 40
        case 37...54:   return 35
        case 55...81:   return 30
        case 82...126:  return 25
        case 127...300: return 20
        default:        return -10
        }
    }

    private static func rrDelta2000Man(forRank rank: Int) -> Int {
        switch rank {
        case 1:          return 1000
        case 2:          return 700
        case 3:          return 500
        case 4:          return 350
        case 5:          return 280
        case 6:          return 220
        case 7:          return 180
        case 8:          return 150
        case 9...10:     return 130
        case 11...15:    return 100
        case 16...20:    return 80
        case 21...30:    return 65
        case 31...45:    return 55
        case 46...72:    return 45
        case 73...108:   return 35
        case 109...162:  return 30
        case 163...252:  return 25
        case 253...600:  return 20
        default:         return -10
        }
    }

    /// Returns the payout tiers for display in the lobby UI
    static func payoutTiers(forEntryCount entryCount: Int) -> [(rankLabel: String, rrDelta: Int)] {
        switch entryCount {
        case 2:
            return [("1st", 10), ("2nd", -10)]
        case 3:
            return [("1st", 20), ("2nd-3rd", -10)]
        case 5:
            return [("1st", 40), ("2nd-5th", -10)]
        case 10:
            return [("1st", 40), ("2nd", 20), ("3rd", 10), ("4th-10th", -10)]
        case 100:
            return [
                ("1st", 350), ("2nd", 200), ("3rd", 120), ("4th", 80), ("5th", 60),
                ("6th-8th", 40), ("9th-12th", 30), ("13th-20th", 20), ("21st-30th", 10),
                ("31st+", -10)
            ]
        case 500:
            return [
                ("1st", 500), ("2nd", 350), ("3rd", 250), ("4th", 180), ("5th", 140),
                ("6th", 110), ("7th-8th", 90), ("9th-12th", 70), ("13th-18th", 55),
                ("19th-27th", 45), ("28th-40th", 35), ("41st-60th", 30),
                ("61st-90th", 25), ("91st-150th", 20), ("151st+", -10)
            ]
        case 1000:
            return [
                ("1st", 700), ("2nd", 500), ("3rd", 350), ("4th", 250), ("5th", 200),
                ("6th", 160), ("7th", 130), ("8th", 110), ("9th", 100),
                ("10th-12th", 80), ("13th-15th", 70), ("16th-18th", 60),
                ("19th-27th", 50), ("28th-36th", 40), ("37th-54th", 35),
                ("55th-81st", 30), ("82nd-126th", 25), ("127th-300th", 20),
                ("301st+", -10)
            ]
        case 2000:
            return [
                ("1st", 1000), ("2nd", 700), ("3rd", 500), ("4th", 350), ("5th", 280),
                ("6th", 220), ("7th", 180), ("8th", 150), ("9th-10th", 130),
                ("11th-15th", 100), ("16th-20th", 80), ("21st-30th", 65),
                ("31st-45th", 55), ("46th-72nd", 45), ("73rd-108th", 35),
                ("109th-162nd", 30), ("163rd-252nd", 25), ("253rd-600th", 20),
                ("601st+", -10)
            ]
        default:
            return DFSEngine.payoutTiers(forEntryCount: 2000)
        }
    }

    static func generateLeaderboard(
        currentUserName: String,
        userLineupPoints: Double,
        totalEntries: Int
    ) -> [DFSLeaderboardEntry] {
        var entries: [DFSLeaderboardEntry] = []
        let normalizedName = currentUserName.isEmpty ? "You" : currentUserName

        entries.append(
            DFSLeaderboardEntry(
                id: UUID(),
                name: normalizedName,
                rank: 1,
                points: userLineupPoints,
                isCurrentUser: true
            )
        )

        let sampleNames = [
            "AceLock", "CourtVision", "ClutchFan", "HalfCourtHero", "StatSavage",
            "UnderdogKing", "BoxScoreBoss", "PrimePicks", "FastBreak", "ZoneDefense"
        ]

        let competitorCount = max(0, min(24, totalEntries - 1))
        for index in 0..<competitorCount {
            let points = Double.random(in: 130.0...250.0)
            entries.append(
                DFSLeaderboardEntry(
                    id: UUID(),
                    name: sampleNames[index % sampleNames.count],
                    rank: 1,
                    points: points,
                    isCurrentUser: false
                )
            )
        }

        let sorted = entries.sorted(by: { $0.points > $1.points })
        return sorted.enumerated().map { offset, entry in
            DFSLeaderboardEntry(
                id: entry.id,
                name: entry.name,
                rank: offset + 1,
                points: entry.points,
                isCurrentUser: entry.isCurrentUser
            )
        }
    }

    static func generateFieldEntries(
        currentUserName: String,
        userLineupIDs: [String],
        availablePlayers: [DFSPlayer],
        totalEntries: Int
    ) -> [DFSFieldEntry] {
        let normalizedName = currentUserName.isEmpty ? "You" : currentUserName
        var entries: [DFSFieldEntry] = [
            DFSFieldEntry(id: UUID(), name: normalizedName, playerIDs: userLineupIDs, isCurrentUser: true)
        ]

        guard !availablePlayers.isEmpty else { return entries }
        let ids = availablePlayers.map { $0.id }
        let lineupSize = max(1, userLineupIDs.count)
        let sampleNames = [
            "AceLock", "CourtVision", "ClutchFan", "HalfCourtHero", "StatSavage",
            "UnderdogKing", "BoxScoreBoss", "PrimePicks", "FastBreak", "ZoneDefense",
            "SplashZone", "LineupLab", "FourthQuarter", "RimRunner", "PaintPoints"
        ]

        let opponentCount = max(0, totalEntries - 1)
        for index in 0..<opponentCount {
            var shuffled = ids.shuffled()
            if shuffled.count < lineupSize {
                shuffled += ids.shuffled()
            }
            let lineup = Array(shuffled.prefix(lineupSize))
            entries.append(
                DFSFieldEntry(
                    id: UUID(),
                    name: sampleNames[index % sampleNames.count],
                    playerIDs: lineup,
                    isCurrentUser: false
                )
            )
        }
        return entries
    }

    static func computeLeaderboard(
        fieldEntries: [DFSFieldEntry],
        playersByID: [String: DFSPlayer],
        scoreSnapshot: DFSScoreSnapshot,
        isSingleGame: Bool = false
    ) -> [DFSLeaderboardEntry] {
        let scored: [(DFSFieldEntry, Double)] = fieldEntries.map { entry in
            var total = 0.0
            for (index, playerID) in entry.playerIDs.enumerated() {
                if let live = scoreSnapshot.playerFantasyPoints[playerID] {
                    // Single-game MVP (index 0) scores 1.5x
                    total += (isSingleGame && index == 0) ? live * 1.5 : live
                }
            }
            return (entry, total)
        }

        let sorted = scored.sorted { lhs, rhs in
            lhs.1 > rhs.1
        }

        // Assign ranks with proper tie handling:
        // Entries with the same points share the same rank.
        // The next rank after a tie group skips ahead (e.g., 1,1,1,4,5).
        var result: [DFSLeaderboardEntry] = []
        for (offset, tuple) in sorted.enumerated() {
            let rank: Int
            if offset == 0 {
                rank = 1
            } else if abs(tuple.1 - sorted[offset - 1].1) < 0.001 {
                // Same points as previous entry — share rank
                rank = result[offset - 1].rank
            } else {
                rank = offset + 1
            }
            result.append(DFSLeaderboardEntry(
                id: tuple.0.id,
                name: tuple.0.name,
                rank: rank,
                points: tuple.1,
                isCurrentUser: tuple.0.isCurrentUser
            ))
        }
        return result
    }
}
private struct NBAScoreboardResponse: Codable, Sendable {
    let events: [NBAScoreboardEvent]
}

private struct NBAScoreboardEvent: Codable, Sendable {
    let id: String
    let name: String?
    let shortName: String?
    let date: Date
    let competitions: [NBAScoreboardCompetition]
}

private struct NBAScoreboardCompetition: Codable, Sendable {
    let status: NBAScoreboardStatus
    let competitors: [NBAScoreboardCompetitor]
}

private struct NBAScoreboardStatus: Codable, Sendable {
    let type: NBAScoreboardStatusType
}

private struct NBAScoreboardStatusType: Codable, Sendable {
    let state: String
    let detail: String?
    let shortDetail: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        shortDetail = try container.decodeIfPresent(String.self, forKey: .shortDetail)
    }

    private enum CodingKeys: String, CodingKey {
        case state, detail, shortDetail
    }
}

private struct NBAScoreboardCompetitor: Codable, Sendable {
    let homeAway: String
    let team: NBATeamRef
    let probables: [NBAScoreboardProbable]?
}

private struct NBAScoreboardProbable: Codable, Sendable {
    let athlete: NBAScoreboardProbableAthlete?
}

private struct NBAScoreboardProbableAthlete: Codable, Sendable {
    let id: String
    let displayName: String?
}

private struct NBATeamRef: Codable, Sendable {
    let id: String
    let abbreviation: String
}

private struct NBARosterResponse: Codable {
    let athletes: [NBARosterAthlete]
}

private struct NBARosterAthlete: Codable {
    let id: String
    let fullName: String
    let position: NBARosterPosition?
    let injuries: [NBARosterInjury]?
}

/// ESPN MLB roster endpoint returns athletes grouped by category (Pitchers, Catchers, etc.)
/// Each category has a `position` string and `items` array of athletes.
private struct MLBRosterResponse: Codable {
    let athletes: [MLBRosterCategory]

    /// Flattens all category items into a single array of NBARosterAthlete
    var allAthletes: [NBARosterAthlete] {
        athletes.flatMap { category in
            category.items.compactMap { item in
                guard let id = item.id else { return nil }
                let fullName = item.fullName ?? item.displayName ?? "\(item.firstName ?? "") \(item.lastName ?? "")".trimmingCharacters(in: .whitespaces)
                guard !fullName.isEmpty else { return nil }
                let position: NBARosterPosition? = item.position?.abbreviation.map { NBARosterPosition(abbreviation: $0) }
                let injuries = item.injuries
                return NBARosterAthlete(id: id, fullName: fullName, position: position, injuries: injuries)
            }
        }
    }
}

private struct MLBRosterCategory: Codable {
    let position: String?
    let items: [MLBRosterItem]
}

private struct MLBRosterItem: Codable {
    let id: String?
    let firstName: String?
    let lastName: String?
    let fullName: String?
    let displayName: String?
    let position: MLBRosterItemPosition?
    let injuries: [NBARosterInjury]?
}

private struct MLBRosterItemPosition: Codable {
    let abbreviation: String?
}

private struct NBARosterPosition: Codable {
    let abbreviation: String
}

private struct NBARosterInjury: Codable {
    let status: String?      // "Out", "Day-To-Day"
    let date: String?
}

private extension JSONDecoder {
    nonisolated static var dfsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            if let date = DFSDateParsers.noSecondsUTC.date(from: value) {
                return date
            }
            if let date = DFSDateParsers.withSecondsUTC.date(from: value) {
                return date
            }
            if let date = DFSDateParsers.withFractionalSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported DFS date format: \(value)"
                )
            )
        }
        return decoder
    }
}

private enum DFSDateParsers {
    static let noSecondsUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter
    }()

    static let withSecondsUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Player Game Log

struct DFSPlayerGameLog: Identifiable {
    let id: String
    let date: String
    let sortDate: Date      // for reliable chronological sorting
    let opponent: String
    let minutes: String
    let points: Int
    let rebounds: Int
    let assists: Int
    let steals: Int
    let blocks: Int
    let turnovers: Int
    let fgm: Int
    let fga: Int
    let threePM: Int
    let threePA: Int
    let ftm: Int
    let fta: Int
    let fantasyPoints: Double

    var fgPct: String {
        guard fga > 0 else { return "-" }
        return String(format: "%.1f", Double(fgm) / Double(fga) * 100)
    }
}

struct ESPNPlayerGameLogProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches the last 15 game logs for a player given their DFS player ID (e.g. "nba-12345" or "ncaam-67890")
    func fetchGameLog(playerID: String, position: String = "", limit: Int = 15) async throws -> [DFSPlayerGameLog] {
        // Two-way player SP entries have IDs like "mlb-12345-sp" — strip suffix for ESPN lookup
        let isTwoWaySP = playerID.hasSuffix("-sp")
        let cleanedID = isTwoWaySP ? String(playerID.dropLast(3)) : playerID
        let (espnID, sportPath) = Self.parsePlayerID(cleanedID)
        let isMLB = cleanedID.hasPrefix("mlb-")
        let isNHL = cleanedID.hasPrefix("nhl-")
        let isSoccer = cleanedID.hasPrefix("epl-") || cleanedID.hasPrefix("ucl-") || cleanedID.hasPrefix("wc-")
        let isUFC = cleanedID.hasPrefix("ufc-")
        let isNASCAR = cleanedID.hasPrefix("nascar-")

        // Soccer uses a different approach — ESPN's soccer gamelog endpoint doesn't return game data.
        // Instead, fetch team schedule → recent match summaries → extract player stats.
        if isSoccer {
            return try await fetchSoccerGameLog(espnID: espnID, sportPath: sportPath, position: position, limit: limit)
        }

        // UFC: fetch fight history from ESPN MMA athlete event log
        if isUFC {
            return try await fetchUFCFightLog(espnID: espnID, limit: limit)
        }

        // NASCAR: the common-v3 racing gamelog returns an empty shell
        // (filters only) — walk the core-API eventlog like UFC instead.
        if isNASCAR {
            return await fetchNASCARRaceLog(espnID: espnID, limit: min(limit, 10))
        }

        // MLB/NHL require a category parameter
        let urlString: String
        if isMLB {
            let isPitcher = isTwoWaySP || ["SP", "RP", "P"].contains(position.uppercased())
            let category = isPitcher ? "pitching" : "batting"
            urlString = "https://site.web.api.espn.com/apis/common/v3/sports/\(sportPath)/athletes/\(espnID)/gamelog?category=\(category)"
        } else if isNHL {
            // NHL gamelog API does not support category parameters (returns 404).
            // All players (skaters and goalies) return skating-style stats.
            urlString = "https://site.web.api.espn.com/apis/common/v3/sports/\(sportPath)/athletes/\(espnID)/gamelog"
        } else {
            urlString = "https://site.web.api.espn.com/apis/common/v3/sports/\(sportPath)/athletes/\(espnID)/gamelog"
        }

        guard let url = URL(string: urlString) else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if isMLB {
            let isPitcher = ["SP", "RP", "P"].contains(position.uppercased())
            return parseMLBGameLog(json: json, limit: limit, isPitcher: isPitcher)
        }

        if isNHL {
            let isGoalie = position.uppercased() == "G"
            return parseNHLGameLog(json: json, limit: limit, isGoalie: isGoalie)
        }

        return parseGameLog(json: json, limit: limit)
    }

    /// Fetches recent news headlines for a player, filtered to only include articles mentioning the player's name
    func fetchNews(playerID: String, playerName: String, limit: Int = 5) async throws -> [ESPNPlayerNews] {
        // Strip two-way player "-sp" suffix for ESPN lookup
        let cleanedID = playerID.hasSuffix("-sp") ? String(playerID.dropLast(3)) : playerID
        let (espnID, sportPath) = Self.parsePlayerID(cleanedID)
        // Fetch more articles than needed so we have enough after filtering
        let fetchLimit = max(limit * 4, 20)
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/news?player=\(espnID)&limit=\(fetchLimit)") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let articles = json["articles"] as? [[String: Any]] else {
            return []
        }

        // Build name variants to match (e.g. "LeBron James" → check "LeBron", "James", full name)
        let nameLower = playerName.lowercased()
        let nameParts = playerName.split(separator: " ").map { String($0).lowercased() }
        let suffixes: Set<String> = ["jr.", "jr", "sr.", "sr", "ii", "iii", "iv", "v"]
        // Use the last non-suffix part as the "last name" (e.g. "Darius Acuff Jr." → "acuff")
        let lastNameLower = nameParts.last(where: { !suffixes.contains($0) }) ?? nameLower

        var results: [ESPNPlayerNews] = []
        for article in articles {
            guard let headline = article["headline"] as? String else { continue }
            let published = article["published"] as? String ?? ""
            let description = article["description"] as? String

            // Check if the article mentions the player by name
            let headlineLower = headline.lowercased()
            let descLower = (description ?? "").lowercased()
            let mentionsPlayer = headlineLower.contains(nameLower)
                || headlineLower.contains(lastNameLower)
                || descLower.contains(nameLower)
                || descLower.contains(lastNameLower)

            guard mentionsPlayer else { continue }

            results.append(ESPNPlayerNews(
                headline: headline,
                description: description,
                published: formatNewsDate(published)
            ))

            if results.count >= limit { break }
        }

        return results
    }

    /// Extracts the raw ESPN athlete ID and the full sport/league URL path from a DFS player ID
    private static func parsePlayerID(_ playerID: String) -> (espnID: String, sportPath: String) {
        if playerID.hasPrefix("ncaam-") {
            return (String(playerID.dropFirst(6)), "basketball/mens-college-basketball")
        } else if playerID.hasPrefix("wnba-") {
            return (String(playerID.dropFirst(5)), "basketball/wnba")
        } else if playerID.hasPrefix("nba-") {
            return (String(playerID.dropFirst(4)), "basketball/nba")
        } else if playerID.hasPrefix("mlb-") {
            return (String(playerID.dropFirst(4)), "baseball/mlb")
        } else if playerID.hasPrefix("nhl-") {
            return (String(playerID.dropFirst(4)), "hockey/nhl")
        } else if playerID.hasPrefix("epl-") {
            return (String(playerID.dropFirst(4)), "soccer/eng.1")
        } else if playerID.hasPrefix("ucl-") {
            return (String(playerID.dropFirst(4)), "soccer/uefa.champions")
        } else if playerID.hasPrefix("wc-") {
            return (String(playerID.dropFirst(3)), "soccer/fifa.world")
        } else if playerID.hasPrefix("ufc-") {
            return (String(playerID.dropFirst(4)), "mma/ufc")
        } else if playerID.hasPrefix("nfl-") {
            return (String(playerID.dropFirst(4)), "football/nfl")
        } else if playerID.hasPrefix("cfb-") {
            return (String(playerID.dropFirst(4)), "football/college-football")
        } else if playerID.hasPrefix("nascar-") {
            return (String(playerID.dropFirst(7)), "racing/nascar-premier")
        }
        // Fallback: assume NBA
        return (playerID, "basketball/nba")
    }

    // MARK: - UFC Fight Log

    /// Fetches fight history for a UFC fighter by scanning past UFC events from the scoreboard.
    /// ESPN MMA doesn't have a traditional athlete gamelog endpoint, so we iterate through
    /// recent weekly scoreboards to find completed fights involving this fighter.
    /// NASCAR race log via the core-API season eventlog. Each played event
    /// needs three small fetches (event name/date, competitor startOrder,
    /// statistics place/lapsLead) — run concurrently per race.
    /// Repurposed DFSPlayerGameLog fields: points = finish, ftm = start,
    /// rebounds = laps led, assists = laps completed, minutes = "P{fin}".
    private func fetchNASCARRaceLog(espnID: String, limit: Int = 10) async -> [DFSPlayerGameLog] {
        func fetchJSON(_ urlString: String) async -> [String: Any]? {
            guard let url = URL(string: urlString),
                  let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        // Season eventlog: current year, falling back one year early in
        // the season (January, before the Clash).
        let year = Calendar.current.component(.year, from: Date())
        var items: [[String: Any]] = []
        for seasonYear in [year, year - 1] {
            let logURL = "https://sports.core.api.espn.com/v2/sports/racing/leagues/nascar-premier/seasons/\(seasonYear)/athletes/\(espnID)/eventlog?limit=100"
            if let json = await fetchJSON(logURL),
               let events = json["events"] as? [String: Any],
               let list = events["items"] as? [[String: Any]], !list.isEmpty {
                items = list
                break
            }
        }
        guard !items.isEmpty else { return [] }

        // Eventlog is chronological (opener first) — take the most recent
        // played races.
        let played = items.filter { ($0["played"] as? Bool) == true }
        let recent = played.suffix(limit)

        let logs: [DFSPlayerGameLog] = await withTaskGroup(of: DFSPlayerGameLog?.self, returning: [DFSPlayerGameLog].self) { group in
            for item in recent {
                guard let eventID = item["eventId"] as? String,
                      let competitionID = item["competitionId"] as? String else { continue }
                group.addTask {
                    let base = "https://sports.core.api.espn.com/v2/sports/racing/leagues/nascar-premier/events/\(eventID)"
                    async let eventJSONTask = fetchJSON(base)
                    async let competitorJSONTask = fetchJSON("\(base)/competitions/\(competitionID)/competitors/\(espnID)")
                    async let statsJSONTask = fetchJSON("\(base)/competitions/\(competitionID)/competitors/\(espnID)/statistics")
                    let eventJSON = await eventJSONTask
                    let competitorJSON = await competitorJSONTask
                    let statsJSON = await statsJSONTask

                    var place = 0, lapsLed = 0, lapsCompleted = 0
                    if let splits = statsJSON?["splits"] as? [String: Any],
                       let categories = splits["categories"] as? [[String: Any]] {
                        for category in categories {
                            for stat in category["stats"] as? [[String: Any]] ?? [] {
                                guard let name = stat["name"] as? String,
                                      let value = stat["value"] as? Double else { continue }
                                switch name {
                                case "place": place = Int(value)
                                case "lapsLead": lapsLed = Int(value)
                                case "lapsCompleted": lapsCompleted = Int(value)
                                default: break
                                }
                            }
                        }
                    }
                    // Fall back to the competitor's finishing order if the
                    // stats block is missing a place.
                    if place == 0 { place = competitorJSON?["order"] as? Int ?? 0 }
                    guard place >= 1 else { return nil }   // DNS / no result
                    let start = competitorJSON?["startOrder"] as? Int ?? 0

                    let rawName = (eventJSON?["name"] as? String) ?? "Race"
                    // "NASCAR Cup Series at Indianapolis" → "Indianapolis";
                    // one-off names ("Daytona 500") pass through whole.
                    let raceName = rawName.components(separatedBy: " at ").count > 1
                        ? rawName.components(separatedBy: " at ").dropFirst().joined(separator: " at ")
                        : rawName

                    let dateString = (eventJSON?["date"] as? String) ?? ""
                    let raceDate: Date = {
                        let fmt = DateFormatter()
                        fmt.locale = Locale(identifier: "en_US_POSIX")
                        fmt.timeZone = TimeZone(secondsFromGMT: 0)
                        for format in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
                            fmt.dateFormat = format
                            if let d = fmt.date(from: dateString) { return d }
                        }
                        return ISO8601DateFormatter().date(from: dateString) ?? .distantPast
                    }()
                    let displayFmt = DateFormatter()
                    displayFmt.dateFormat = "M/d"

                    return DFSPlayerGameLog(
                        id: eventID,
                        date: raceDate == .distantPast ? "-" : displayFmt.string(from: raceDate),
                        sortDate: raceDate,
                        opponent: raceName,
                        minutes: "P\(place)",
                        points: place,
                        rebounds: lapsLed,
                        assists: lapsCompleted,
                        steals: 0, blocks: 0, turnovers: 0,
                        fgm: 0, fga: 0, threePM: 0, threePA: 0,
                        ftm: start, fta: 0,
                        fantasyPoints: nascarFantasyPoints(place: place, startPosition: start, lapsLed: lapsLed)
                    )
                }
            }
            var results: [DFSPlayerGameLog] = []
            for await log in group {
                if let log { results.append(log) }
            }
            return results
        }
        return logs.sorted { $0.sortDate > $1.sortDate }
    }

    private func fetchUFCFightLog(espnID: String, limit: Int = 10) async throws -> [DFSPlayerGameLog] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"

        let shortDF = DateFormatter()
        shortDF.dateFormat = "M/d"

        // Scan past weeks of UFC events (UFC runs weekly cards)
        var fightRefs: [(eventID: String, compID: String, opponentName: String, date: Date, round: Int, isWinner: Bool, resultType: String)] = []

        // Scan ~40 weeks back to find up to `limit` fights.
        // ESPN's MMA scoreboard with `dates=YYYYMMDD` only returns events on
        // that exact calendar date — and UFC cards usually fall on Saturdays.
        // Iterating by `-weekOfYear` from "today" anchors the query to the
        // current weekday (e.g. Tuesday), so every Saturday event is missed.
        // Use 7-day date ranges (`dates=YYYYMMDD-YYYYMMDD`) instead so each
        // query covers a full week regardless of weekday alignment.
        let today = Date()
        let cal = Calendar.current
        var dateRanges: [(start: String, end: String)] = []
        for weekOffset in 0..<40 {
            guard let end = cal.date(byAdding: .day, value: -7 * weekOffset, to: today),
                  let start = cal.date(byAdding: .day, value: -6, to: end) else { continue }
            dateRanges.append((start: formatter.string(from: start), end: formatter.string(from: end)))
        }

        // Fetch scoreboards concurrently in batches
        await withTaskGroup(of: [(eventID: String, compID: String, opponentName: String, date: Date, round: Int, isWinner: Bool, resultType: String)].self) { group in
            for range in dateRanges {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=\(range.start)-\(range.end)") else { return [] }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let events = json["events"] as? [[String: Any]] else { return [] }

                    var found: [(eventID: String, compID: String, opponentName: String, date: Date, round: Int, isWinner: Bool, resultType: String)] = []
                    for event in events {
                        let eventID = event["id"] as? String ?? ""
                        let eventDateStr = event["date"] as? String ?? ""
                        // Parse event date (ESPN uses formats like "2026-05-09T21:00Z")
                        let eventDate: Date = {
                            let fmts = [
                                "yyyy-MM-dd'T'HH:mm'Z'",
                                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
                            ]
                            for fmt in fmts {
                                let df = DateFormatter()
                                df.locale = Locale(identifier: "en_US_POSIX")
                                df.timeZone = TimeZone(secondsFromGMT: 0)
                                df.dateFormat = fmt
                                if let d = df.date(from: eventDateStr) { return d }
                            }
                            return ISO8601DateFormatter().date(from: eventDateStr) ?? Date.distantPast
                        }()

                        guard let comps = event["competitions"] as? [[String: Any]] else { continue }
                        for comp in comps {
                            let compID = comp["id"] as? String ?? ""
                            guard let competitors = comp["competitors"] as? [[String: Any]] else { continue }

                            // Check if this fighter is in this competition
                            var fighterFound = false
                            var opponentName = "OPP"
                            var isWinner = false
                            var round = 0
                            var resultType = ""

                            for c in competitors {
                                let cid = c["id"] as? String ?? ""
                                if cid == espnID {
                                    fighterFound = true
                                    isWinner = c["winner"] as? Bool ?? false
                                } else {
                                    let athlete = c["athlete"] as? [String: Any]
                                    let lastName = athlete?["shortName"] as? String ?? athlete?["displayName"] as? String ?? "OPP"
                                    opponentName = lastName
                                }
                            }

                            if fighterFound {
                                if let status = comp["status"] as? [String: Any] {
                                    round = status["period"] as? Int ?? 0
                                    if let statusType = status["type"] as? [String: Any] {
                                        let state = statusType["state"] as? String ?? ""
                                        if state != "post" { continue }  // Only include completed fights
                                        resultType = statusType["name"] as? String ?? ""
                                    }
                                }
                                found.append((eventID: eventID, compID: compID, opponentName: opponentName, date: eventDate, round: round, isWinner: isWinner, resultType: resultType))
                            }
                        }
                    }
                    return found
                }
            }

            for await results in group {
                fightRefs.append(contentsOf: results)
            }
        }

        // Sort by date descending and take limit
        fightRefs.sort { $0.date > $1.date }
        let recent = Array(fightRefs.prefix(limit))

        if recent.isEmpty { return [] }

        // Fetch detailed stats for each fight concurrently
        var logs: [DFSPlayerGameLog] = []

        await withTaskGroup(of: (Int, DFSPlayerGameLog?).self) { group in
            for (index, ref) in recent.enumerated() {
                group.addTask {
                    let log = await self.fetchUFCFightStats(
                        espnID: espnID,
                        eventID: ref.eventID,
                        compID: ref.compID,
                        opponentName: ref.opponentName,
                        date: ref.date,
                        round: ref.round,
                        isWinner: ref.isWinner,
                        resultType: ref.resultType
                    )
                    return (index, log)
                }
            }

            var indexedResults: [(Int, DFSPlayerGameLog)] = []
            for await (index, log) in group {
                if let log { indexedResults.append((index, log)) }
            }
            logs = indexedResults.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }

        return logs
    }

    /// Fetches detailed stats for a single UFC fight from ESPN core API
    private func fetchUFCFightStats(
        espnID: String,
        eventID: String,
        compID: String,
        opponentName: String,
        date: Date,
        round: Int,
        isWinner: Bool,
        resultType: String
    ) async -> DFSPlayerGameLog? {
        let statsURL = "https://sports.core.api.espn.com/v2/sports/mma/leagues/ufc/events/\(eventID)/competitions/\(compID)/competitors/\(espnID)/statistics"
        var sigStrikes = 0.0
        var takedowns = 0.0
        var knockdowns = 0.0
        var subAttempts = 0.0
        var controlTimeSec = 0.0
        var reversals = 0.0
        var advMount = 0.0
        var advBack = 0.0

        if let url = URL(string: statsURL),
           let (data, response) = try? await session.data(from: url),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let splits = json["splits"] as? [String: Any],
           let categories = splits["categories"] as? [[String: Any]] {

            for category in categories {
                guard let statArr = category["stats"] as? [[String: Any]] else { continue }
                for stat in statArr {
                    if let name = stat["name"] as? String,
                       let value = stat["value"] as? Double {
                        switch name {
                        case "sigStrikesLanded": sigStrikes = value
                        case "takedownsLanded": takedowns = value
                        case "knockDowns": knockdowns = value
                        case "submissions": subAttempts = value
                        case "timeInControl": controlTimeSec = value
                        case "reversals": reversals = value
                        case "advanceToMount": advMount = value
                        case "advanceToBack": advBack = value
                        default: break
                        }
                    }
                }
            }
        }

        // Calculate fantasy points (same scoring as live)
        var fpts = sigStrikes * 0.6
        fpts += takedowns * 5.0
        fpts += knockdowns * 10.0
        fpts += subAttempts * 3.0
        fpts += reversals * 3.0
        fpts += (advMount + advBack) * 5.0

        if isWinner {
            fpts += 30.0
            if resultType.contains("kotko") {
                fpts += 30.0
            } else if resultType.contains("submission") {
                fpts += 20.0
            }
        }

        let shortDF = DateFormatter()
        shortDF.dateFormat = "M/d"
        let displayDate = shortDF.string(from: date)

        // Extract last name for display
        let oppParts = opponentName.components(separatedBy: " ")
        let oppDisplay = String((oppParts.last ?? opponentName).prefix(6))

        return DFSPlayerGameLog(
            id: "\(eventID)-\(compID)",
            date: displayDate,
            sortDate: date,
            opponent: oppDisplay,
            minutes: "\(round)",  // Round number
            points: Int(sigStrikes),
            rebounds: Int(takedowns),
            assists: Int(knockdowns),
            steals: Int(subAttempts),
            blocks: Int(controlTimeSec),
            turnovers: Int(reversals),
            fgm: 0, fga: 0,
            threePM: 0, threePA: 0,
            ftm: isWinner ? 1 : 0,
            fta: 0,
            fantasyPoints: (fpts * 10).rounded() / 10
        )
    }

    // MARK: - Soccer Game Log

    /// Fetches game log for a soccer player by iterating through their team's recent completed matches.
    /// ESPN's soccer gamelog endpoint doesn't return per-game stats, so we fetch the team schedule
    /// and then retrieve match summaries to extract individual player stats.
    private func fetchSoccerGameLog(espnID: String, sportPath: String, position: String, limit: Int) async throws -> [DFSPlayerGameLog] {
        // 1. Find the player's team ESPN ID by checking the player in a team roster lookup.
        //    We use the athlete overview to get the team, or iterate via teams endpoint.
        let leaguePath = sportPath.replacingOccurrences(of: "soccer/", with: "") // "eng.1" or "uefa.champions"

        // Fetch the athlete's current team from ESPN
        guard let teamID = try await lookupSoccerTeamID(espnID: espnID, leaguePath: leaguePath) else {
            return []
        }

        // 2. Fetch team schedule to get recent completed match event IDs.
        // For national teams (World Cup), the team's `fifa.world` schedule
        // only includes the active tournament's fixtures — which is empty
        // before kickoff. National teams play in MANY competitions: club
        // friendlies, qualifiers, Nations League, the Cup itself. ESPN
        // exposes those under sibling league paths. We try a series of
        // likely competitions and merge whatever events come back.
        let scheduleLeagues: [String] = {
            switch leaguePath {
            case "fifa.world":
                // National-team competitions ESPN exposes that fit men's
                // World Cup teams. Order matters only for which schedule
                // call wins the team-abbreviation tiebreaker.
                return [
                    "fifa.world",
                    "fifa.friendly",
                    "fifa.worldq.uefa",
                    "fifa.worldq.conmebol",
                    "fifa.worldq.concacaf",
                    "fifa.worldq.afc",
                    "fifa.worldq.caf",
                    "fifa.worldq.ofc",
                    "uefa.nations",
                    "conmebol.copa_america",
                    "concacaf.gold",
                    "afc.asian_cup",
                    "caf.nations"
                ]
            default:
                return [leaguePath]
            }
        }()

        // Pair each event with the league slug that returned it — the
        // per-event summary endpoint is league-scoped (`/soccer/{league}/
        // summary?event=X`), so a friendly returned under fifa.friendly
        // can't be looked up under fifa.world. Keep them tagged.
        var aggregatedEvents: [(event: [String: Any], league: String)] = []
        var firstScheduleData: [String: Any]?
        for scheduleLeague in scheduleLeagues {
            let scheduleURL = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(scheduleLeague)/teams/\(teamID)/schedule"
            guard let url = URL(string: scheduleURL) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if firstScheduleData == nil { firstScheduleData = json }
            if let evts = json["events"] as? [[String: Any]], !evts.isEmpty {
                for e in evts { aggregatedEvents.append((event: e, league: scheduleLeague)) }
            }
        }
        guard !aggregatedEvents.isEmpty, let json = firstScheduleData else { return [] }
        // Dedupe by event id.
        var seenIDs = Set<String>()
        var leagueByEventID: [String: String] = [:]
        let events: [[String: Any]] = aggregatedEvents.compactMap { pair in
            guard let id = pair.event["id"] as? String else { return nil }
            guard seenIDs.insert(id).inserted else { return nil }
            leagueByEventID[id] = pair.league
            return pair.event
        }
        if events.isEmpty { return [] }

        // Find the team's abbreviation from the schedule
        var teamAbbreviation = ""
        if let firstEvent = events.first,
           let competitions = firstEvent["competitions"] as? [[String: Any]],
           let competition = competitions.first,
           let competitors = competition["competitors"] as? [[String: Any]] {
            for competitor in competitors {
                if let cTeam = competitor["team"] as? [String: Any],
                   let cID = cTeam["id"] as? String, cID == teamID {
                    teamAbbreviation = cTeam["abbreviation"] as? String ?? ""
                    break
                }
            }
        }

        // Filter to completed matches only, sorted by date descending
        var completedEvents: [(id: String, date: String, opponent: String, isHome: Bool, teamScore: Int, opponentScore: Int)] = []

        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let state = statusType["state"] as? String,
                  state == "post",
                  let eventID = event["id"] as? String else { continue }

            let eventDate = event["date"] as? String ?? ""

            guard let competitors = competition["competitors"] as? [[String: Any]] else { continue }

            var opponentAbbrev = ""
            var isHome = false
            var teamScore = 0
            var opponentScore = 0

            for competitor in competitors {
                guard let team = competitor["team"] as? [String: Any],
                      let cID = team["id"] as? String else { continue }
                let abbrev = team["abbreviation"] as? String ?? ""
                let scoreDict = competitor["score"] as? [String: Any]
                let score = Int(scoreDict?["value"] as? Double ?? 0)

                if cID == teamID {
                    teamScore = score
                    isHome = (competitor["homeAway"] as? String) == "home"
                    if teamAbbreviation.isEmpty { teamAbbreviation = abbrev }
                } else {
                    opponentAbbrev = abbrev
                    opponentScore = score
                }
            }

            completedEvents.append((id: eventID, date: eventDate, opponent: opponentAbbrev, isHome: isHome, teamScore: teamScore, opponentScore: opponentScore))
        }

        // Sort by date descending and take the most recent games
        completedEvents.sort { parseRawDate($0.date) > parseRawDate($1.date) }
        let recentEvents = Array(completedEvents.prefix(limit))

        guard !recentEvents.isEmpty else { return [] }

        // 3. Fetch match summaries in parallel and extract player stats.
        // For each event, use the league it actually came from (the team
        // schedule may have surfaced events from friendlies / qualifiers /
        // Nations League) — the summary endpoint is league-scoped.
        let gameLogs = try await withThrowingTaskGroup(of: DFSPlayerGameLog?.self) { group in
            for event in recentEvents {
                let eventLeague = leagueByEventID[event.id] ?? leaguePath
                group.addTask {
                    return try await self.fetchSoccerPlayerStatsFromSummary(
                        eventID: event.id,
                        espnAthleteID: espnID,
                        leaguePath: eventLeague,
                        position: position,
                        eventDate: event.date,
                        opponent: event.opponent,
                        isHome: event.isHome,
                        teamScore: event.teamScore,
                        opponentScore: event.opponentScore,
                        teamAbbreviation: teamAbbreviation,
                        teamID: teamID
                    )
                }
            }

            var results: [DFSPlayerGameLog] = []
            for try await log in group {
                if let log { results.append(log) }
            }
            return results
        }

        // Sort by date descending (most recent first)
        return gameLogs.sorted { $0.sortDate > $1.sortDate }
    }

    /// Looks up a soccer player's team ESPN ID by fetching all league teams and checking rosters.
    /// Uses a fast approach: fetch athlete page directly if available, or search through teams.
    private func lookupSoccerTeamID(espnID: String, leaguePath: String) async throws -> String? {
        // Try fetching the teams list and checking each roster for the player
        // This is more reliable than the athlete endpoint which may not exist
        let teamsURL = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(leaguePath)/teams?limit=100"
        guard let url = URL(string: teamsURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sports = json["sports"] as? [[String: Any]] else {
            // Try alternate format: direct teams array
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let teams = json["teams"] as? [[String: Any]] {
                // Check rosters in parallel for the athlete
                return try await findTeamWithAthlete(teams: teams, espnID: espnID, leaguePath: leaguePath)
            }
            return nil
        }

        // Navigate: sports[0].leagues[0].teams[]
        for sport in sports {
            if let leagues = sport["leagues"] as? [[String: Any]] {
                for league in leagues {
                    if let teams = league["teams"] as? [[String: Any]] {
                        return try await findTeamWithAthlete(teams: teams, espnID: espnID, leaguePath: leaguePath)
                    }
                }
            }
        }

        return nil
    }

    /// Searches through team rosters to find which team has the given athlete.
    private func findTeamWithAthlete(teams: [[String: Any]], espnID: String, leaguePath: String) async throws -> String? {
        // First try a quick parallel roster check on all teams
        return try await withThrowingTaskGroup(of: String?.self) { group in
            for teamEntry in teams {
                let team = teamEntry["team"] as? [String: Any] ?? teamEntry
                guard let teamID = team["id"] as? String else { continue }

                group.addTask {
                    let rosterURL = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(leaguePath)/teams/\(teamID)/roster"
                    guard let url = URL(string: rosterURL) else { return nil }

                    var req = URLRequest(url: url)
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

                    guard let (data, resp) = try? await self.session.data(for: req),
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let rosterJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }

                    // Check both flat and grouped roster formats
                    if let athletes = rosterJSON["athletes"] as? [[String: Any]] {
                        // Could be grouped: [{ "items": [...] }] or flat: [{ "id": "123" }]
                        for entry in athletes {
                            if let items = entry["items"] as? [[String: Any]] {
                                // Grouped format
                                for item in items {
                                    if let id = item["id"] as? String, id == espnID { return teamID }
                                }
                            } else {
                                // Flat format
                                if let id = entry["id"] as? String, id == espnID { return teamID }
                            }
                        }
                    }

                    return nil
                }
            }

            for try await result in group {
                if let teamID = result {
                    group.cancelAll()
                    return teamID
                }
            }
            return nil
        }
    }

    /// Fetches a single match summary and extracts stats for a specific player.
    /// Soccer summaries store per-player stats in rosters[].roster[].stats (array of dicts),
    /// NOT in boxscore.players like basketball/hockey.
    ///
    /// The `/summary?event=` payload only exposes a thin set of stats (goals,
    /// assists, shots, cards, fouls). Defensive actions (tackles, interceptions,
    /// clearances, blocked shots) live at a separate core-API endpoint, so we
    /// fetch both in parallel and merge.
    private func fetchSoccerPlayerStatsFromSummary(
        eventID: String,
        espnAthleteID: String,
        leaguePath: String,
        position: String,
        eventDate: String,
        opponent: String,
        isHome: Bool,
        teamScore: Int,
        opponentScore: Int,
        teamAbbreviation: String,
        teamID: String
    ) async throws -> DFSPlayerGameLog? {
        let summaryURL = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(leaguePath)/summary?event=\(eventID)"
        guard let url = URL(string: summaryURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Soccer player stats are in rosters[].roster[].stats (array of stat dicts)
        guard let rosters = json["rosters"] as? [[String: Any]] else { return nil }

        for rosterBlock in rosters {
            let teamAbbrev = (rosterBlock["team"] as? [String: Any])?["abbreviation"] as? String ?? ""
            guard let rosterEntries = rosterBlock["roster"] as? [[String: Any]] else { continue }

            for entry in rosterEntries {
                guard let athlete = entry["athlete"] as? [String: Any],
                      let athleteID = athlete["id"] as? String,
                      athleteID == espnAthleteID,
                      let stats = entry["stats"] as? [[String: Any]] else { continue }

                // Build stat lookup under BOTH abbreviation and name keys.
                // ESPN soccer's `/summary?event=` endpoint exposes goals/assists/
                // shots under short abbreviations (G/A/SH/ST...), but the rich
                // defensive stats (tackles, interceptions, clearances) only
                // appear under their full `name` field (wonTackle, totalInter-
                // ceptions, etc). Reading both lets us pick up either.
                var statLookup: [String: Double] = [:]
                for stat in stats {
                    let rawValue: Double? = {
                        if let v = stat["value"] as? Double { return v }
                        if let v = stat["value"] as? Int { return Double(v) }
                        return nil
                    }()
                    guard let val = rawValue else { continue }
                    if let abbr = stat["abbreviation"] as? String, !abbr.isEmpty {
                        statLookup[abbr] = val
                    }
                    if let name = stat["name"] as? String, !name.isEmpty {
                        statLookup[name] = val
                    }
                }

                // Get position from roster entry
                let posDict = entry["position"] as? [String: Any]
                let rawPos = posDict?["abbreviation"] as? String ?? posDict?["displayName"] as? String ?? position
                let playerPos = mapSoccerGameLogPosition(rawPos)

                // Extract stats — prefer the `name` keys (richer + match the
                // live boxscore parser in SoccerDFSData), fall back to short
                // abbreviations for the basics ESPN always exposes.
                let goals = Int(statLookup["totalGoals"] ?? statLookup["G"] ?? 0)
                let assists = Int(statLookup["goalAssists"] ?? statLookup["A"] ?? 0)
                let shotsOnTarget = Int(statLookup["shotsOnTarget"] ?? statLookup["ST"] ?? 0)
                let totalShots = Int(statLookup["totalShots"] ?? statLookup["SH"] ?? 0)
                let saves = Int(statLookup["saves"] ?? statLookup["SV"] ?? 0)
                let yellowCards = Int(statLookup["yellowCards"] ?? statLookup["YC"] ?? 0)
                let redCards = Int(statLookup["redCards"] ?? statLookup["RC"] ?? 0)
                let foulsDrawn = Int(statLookup["foulsSuffered"] ?? statLookup["FA"] ?? 0)
                let goalsAgainst = Int(statLookup["goalsConceded"] ?? statLookup["GA"] ?? 0)
                // Defensive actions are NOT in the summary endpoint. Fetch
                // them from the per-player core-API stats endpoint. Failures
                // return zeros (same as before — we just lose the defender
                // bonus for that game).
                let defStats = await self.fetchSoccerDefensiveStats(
                    eventID: eventID, leaguePath: leaguePath,
                    teamID: teamID, athleteID: espnAthleteID
                )
                let tackles = defStats.tackles
                let interceptions = defStats.interceptions
                let blockedShots = defStats.blockedShots
                let clearances = defStats.clearances

                // Estimate minutes played from starter/sub status
                let isStarter = (entry["starter"] as? Int ?? entry["starter"] as? Bool as? Int ?? 0) != 0
                let subbedOut = (entry["subbedOut"] as? Int ?? entry["subbedOut"] as? Bool as? Int ?? 0) != 0
                let subbedIn = (entry["subbedIn"] as? Int ?? entry["subbedIn"] as? Bool as? Int ?? 0) != 0

                let minutesPlayed: Int
                if isStarter && !subbedOut {
                    minutesPlayed = 90  // Full match
                } else if isStarter && subbedOut {
                    minutesPlayed = 65  // Starter subbed off — estimate ~65 min
                } else if subbedIn {
                    minutesPlayed = 25  // Sub came on — estimate ~25 min
                } else {
                    minutesPlayed = 0   // Unused sub
                }

                // Clean sheet: opposing team scored 0
                let cleanSheet = opponentScore == 0
                // Team won: our team scored more than opponent
                let teamWon = teamScore > opponentScore

                // Compute fantasy points (FanDuel-style)
                var fpts = 0.0
                fpts += Double(goals) * 15.0
                fpts += Double(assists) * 7.0
                fpts += Double(shotsOnTarget) * 4.0
                fpts += Double(max(0, totalShots - shotsOnTarget)) * 1.0  // non-SOT shots
                fpts += Double(foulsDrawn) * 1.0
                fpts -= Double(yellowCards) * 1.0
                fpts -= Double(redCards) * 3.0
                fpts += Double(tackles) * 1.6
                fpts += Double(interceptions) * 1.0
                fpts += Double(blockedShots) * 1.5
                fpts += Double(clearances) * 0.3
                if playerPos == "DEF" {
                    if cleanSheet { fpts += 5.0 }
                    fpts -= Double(goalsAgainst) * 0.6
                }
                if playerPos == "GK" {
                    fpts += Double(saves) * 2.5
                    if cleanSheet { fpts += 8.0 }
                    if teamWon { fpts += 6.0 }
                    fpts -= Double(goalsAgainst) * 2.5
                }

                let parsedDate = parseRawDate(eventDate)
                let df = DateFormatter()
                df.dateFormat = "M/d"
                let dateStr = df.string(from: parsedDate)

                let oppDisplay = (isHome ? "vs " : "@ ") + opponent

                // Repurpose threePM/threePA (unused for soccer) to carry the
                // headline defensive numbers so the gamelog row can show why
                // a centre-back's FPTS isn't zero on a 0g/0a/0sot night.
                let defActions = tackles + interceptions + blockedShots + clearances
                return DFSPlayerGameLog(
                    id: eventID,
                    date: dateStr,
                    sortDate: parsedDate,
                    opponent: oppDisplay,
                    minutes: "\(minutesPlayed)",
                    points: goals,              // goals
                    rebounds: shotsOnTarget,     // shots on target
                    assists: assists,            // assists
                    steals: foulsDrawn,          // fouls drawn
                    blocks: saves,               // saves (GK)
                    turnovers: totalShots,       // total shots
                    fgm: yellowCards,            // yellow cards
                    fga: redCards,               // red cards
                    threePM: tackles,           // tackles
                    threePA: defActions,        // tackles + ints + blocks + clearances
                    ftm: cleanSheet ? 1 : 0,    // clean sheet flag
                    fta: 0,
                    fantasyPoints: fpts
                )
            }
        }

        // Player wasn't in the roster for this match (didn't play)
        return nil
    }

    /// Fetches the per-player defensive stats for one event from ESPN's
    /// core-API. The `/summary?event=` endpoint we use for the basic stats
    /// returns only a thin slice (goals/assists/shots/cards) — defenders'
    /// tackles, interceptions, clearances, and blocked shots only show up
    /// here. Returns zeros on any failure so the caller can degrade gracefully.
    private func fetchSoccerDefensiveStats(
        eventID: String,
        leaguePath: String,
        teamID: String,
        athleteID: String
    ) async -> (tackles: Int, interceptions: Int, blockedShots: Int, clearances: Int) {
        let urlString = "https://sports.core.api.espn.com/v2/sports/soccer/leagues/\(leaguePath)/events/\(eventID)/competitions/\(eventID)/competitors/\(teamID)/roster/\(athleteID)/statistics/0"
        guard let url = URL(string: urlString) else { return (0, 0, 0, 0) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let splits = json["splits"] as? [String: Any],
              let categories = splits["categories"] as? [[String: Any]] else {
            return (0, 0, 0, 0)
        }
        var values: [String: Double] = [:]
        for cat in categories {
            guard let stats = cat["stats"] as? [[String: Any]] else { continue }
            for s in stats {
                guard let name = s["name"] as? String else { continue }
                if let v = s["value"] as? Double {
                    values[name] = v
                } else if let v = s["value"] as? Int {
                    values[name] = Double(v)
                }
            }
        }
        // Prefer "totalTackles" over "effectiveTackles" — total includes both
        // won and lost tackles and is the closer analogue to FanDuel's
        // "tackle" stat. Defenders get rewarded for attempts even if not all
        // result in dispossession, mirroring how the live boxscore counts.
        let tackles = Int(values["totalTackles"] ?? values["effectiveTackles"] ?? 0)
        let interceptions = Int(values["interceptions"] ?? 0)
        let blockedShots = Int(values["blockedShots"] ?? 0)
        let clearances = Int(values["totalClearance"] ?? values["effectiveClearance"] ?? 0)
        return (tackles, interceptions, blockedShots, clearances)
    }

    /// Maps ESPN soccer position abbreviations to DFS positions for game log display
    private func mapSoccerGameLogPosition(_ raw: String) -> String {
        let upper = raw.uppercased()
        switch upper {
        case "G", "GK", "GOALKEEPER": return "GK"
        case "D", "CB", "LB", "RB", "LWB", "RWB", "SW", "DEFENDER", "CENTER BACK",
             "LEFT BACK", "RIGHT BACK": return "DEF"
        case "M", "CM", "CAM", "CDM", "LM", "RM", "AM", "DM", "MIDFIELDER",
             "CENTRAL MIDFIELDER", "ATTACKING MIDFIELDER", "DEFENSIVE MIDFIELDER": return "MID"
        case "F", "ST", "CF", "LW", "RW", "SS", "FORWARD", "STRIKER",
             "CENTER FORWARD", "LEFT WING", "RIGHT WING": return "FWD"
        default: return "MID"
        }
    }

    private func parseGameLog(json: [String: Any], limit: Int) -> [DFSPlayerGameLog] {
        // ESPN web API structure:
        // - labels at top level: json["labels"] = ["MIN", "FG", "FG%", ...]
        // - events metadata: json["events"] = { "eventID": { gameDate, opponent, ... } }
        // - stats: json["seasonTypes"][].categories[].events[] = { eventId, stats: [...] }
        // Labels may also be inside categories for the older API format.

        // Get labels — try top-level first, then from categories
        let topLabels = json["labels"] as? [String]

        // Collect all events from season types. Don't assume ordering —
        // NBA returns events oldest-first within categories, while NCAAM returns
        // newest-first. We'll sort by date at the end.
        var allEvents: [[String: Any]] = []
        if let seasonTypes = json["seasonTypes"] as? [[String: Any]] {
            for seasonType in seasonTypes {
                if let cats = seasonType["categories"] as? [[String: Any]] {
                    for cat in cats {
                        if let events = cat["events"] as? [[String: Any]] {
                            allEvents.append(contentsOf: events)
                        }
                    }
                }
            }
        }

        // Also try direct categories (older API format)
        if allEvents.isEmpty, let directCategories = json["categories"] as? [[String: Any]] {
            for cat in directCategories {
                if let events = cat["events"] as? [[String: Any]] {
                    allEvents.append(contentsOf: events)
                }
            }
        }

        // Determine the labels to use
        let labels: [String]
        if let topLabels, !topLabels.isEmpty {
            labels = topLabels
        } else if let directCategories = json["categories"] as? [[String: Any]],
                  let catWithLabels = directCategories.first(where: { ($0["labels"] as? [String]) != nil }),
                  let catLabels = catWithLabels["labels"] as? [String] {
            labels = catLabels
        } else {
            return []
        }

        guard !allEvents.isEmpty else { return [] }

        // Event metadata dictionary
        let eventMeta = json["events"] as? [String: [String: Any]] ?? [:]

        // Build label -> index map
        var labelIndex: [String: Int] = [:]
        for (index, label) in labels.enumerated() {
            labelIndex[label.uppercased()] = index
        }

        var gameLogs: [DFSPlayerGameLog] = []

        // Process all events; we'll sort and trim after building the full list
        for event in allEvents {
            guard let stats = event["stats"] as? [String] else { continue }

            let eventID: String = {
                if let s = event["eventId"] as? String { return s }
                if let n = event["eventId"] as? Int { return String(n) }
                if let s = event["id"] as? String { return s }
                if let n = event["id"] as? Int { return String(n) }
                return UUID().uuidString
            }()
            let meta = eventMeta[eventID]
            let gameDate = (meta?["gameDate"] as? String)
                ?? (event["gameDate"] as? String)
                ?? ""
            let opponent = parseOpponent(from: event, eventMeta: meta)

            func stat(_ key: String) -> String {
                guard let idx = labelIndex[key], idx < stats.count else { return "0" }
                return stats[idx]
            }

            func intStat(_ key: String) -> Int {
                Int(stat(key)) ?? 0
            }

            let fgParts = stat("FG").split(separator: "-")
            let fgm = fgParts.count >= 1 ? Int(fgParts[0]) ?? 0 : 0
            let fga = fgParts.count >= 2 ? Int(fgParts[1]) ?? 0 : 0

            let threeParts = stat("3PT").split(separator: "-")
            let threePM = threeParts.count >= 1 ? Int(threeParts[0]) ?? 0 : 0
            let threePA = threeParts.count >= 2 ? Int(threeParts[1]) ?? 0 : 0

            let ftParts = stat("FT").split(separator: "-")
            let ftm = ftParts.count >= 1 ? Int(ftParts[0]) ?? 0 : 0
            let fta = ftParts.count >= 2 ? Int(ftParts[1]) ?? 0 : 0

            let pts = intStat("PTS")
            let reb = intStat("REB")
            let ast = intStat("AST")
            let stl = intStat("STL")
            let blk = intStat("BLK")
            let to = intStat("TO")
            let min = stat("MIN")

            let fantasy = Double(pts) * 1.0
                + Double(reb) * 1.2
                + Double(ast) * 1.5
                + Double(stl) * 3.0
                + Double(blk) * 3.0
                - Double(to) * 1.0

            let parsedDate = parseRawDate(gameDate)

            gameLogs.append(DFSPlayerGameLog(
                id: eventID,
                date: formatGameDate(gameDate),
                sortDate: parsedDate,
                opponent: opponent,
                minutes: min,
                points: pts,
                rebounds: reb,
                assists: ast,
                steals: stl,
                blocks: blk,
                turnovers: to,
                fgm: fgm,
                fga: fga,
                threePM: threePM,
                threePA: threePA,
                ftm: ftm,
                fta: fta,
                fantasyPoints: fantasy
            ))
        }

        // Sort by date descending (most recent first) and take only the requested number
        return Array(gameLogs.sorted { $0.sortDate > $1.sortDate }.prefix(limit))
    }

    // MARK: - MLB Game Log Parsing

    private func parseMLBGameLog(json: [String: Any], limit: Int, isPitcher: Bool) -> [DFSPlayerGameLog] {
        // ESPN MLB gamelog labels:
        // Batting: ["AB", "R", "H", "2B", "3B", "HR", "RBI", "BB", "HBP", "SO", "SB", "CS", "AVG", "OBP", "SLG", "OPS"]
        // Pitching: ["IP", "H", "R", "ER", "HR", "BB", "K", "GB", "FB", "P", "TBF", "GSC", "Dec", "Rel", "ERA"]

        let topLabels = json["labels"] as? [String]

        var allEvents: [[String: Any]] = []
        if let seasonTypes = json["seasonTypes"] as? [[String: Any]] {
            for seasonType in seasonTypes {
                if let cats = seasonType["categories"] as? [[String: Any]] {
                    for cat in cats {
                        if let events = cat["events"] as? [[String: Any]] {
                            allEvents.append(contentsOf: events)
                        }
                    }
                }
            }
        }

        if allEvents.isEmpty, let directCategories = json["categories"] as? [[String: Any]] {
            for cat in directCategories {
                if let events = cat["events"] as? [[String: Any]] {
                    allEvents.append(contentsOf: events)
                }
            }
        }

        let labels: [String]
        if let topLabels, !topLabels.isEmpty {
            labels = topLabels
        } else if let seasonTypes = json["seasonTypes"] as? [[String: Any]] {
            let catLabels = seasonTypes.compactMap { st in
                (st["categories"] as? [[String: Any]])?.compactMap { $0["labels"] as? [String] }.first
            }.first
            labels = catLabels ?? []
        } else {
            return []
        }

        guard !allEvents.isEmpty else { return [] }

        let eventMeta = json["events"] as? [String: [String: Any]] ?? [:]

        var labelIndex: [String: Int] = [:]
        for (index, label) in labels.enumerated() {
            labelIndex[label.uppercased()] = index
        }

        var gameLogs: [DFSPlayerGameLog] = []

        for event in allEvents {
            guard let stats = event["stats"] as? [String] else { continue }

            let eventID: String = {
                if let s = event["eventId"] as? String { return s }
                if let n = event["eventId"] as? Int { return String(n) }
                if let s = event["id"] as? String { return s }
                if let n = event["id"] as? Int { return String(n) }
                return UUID().uuidString
            }()
            let meta = eventMeta[eventID]
            let gameDate = (meta?["gameDate"] as? String)
                ?? (event["gameDate"] as? String)
                ?? ""
            let opponent = parseOpponent(from: event, eventMeta: meta)

            func stat(_ key: String) -> String {
                guard let idx = labelIndex[key], idx < stats.count else { return "0" }
                return stats[idx]
            }

            func intStat(_ key: String) -> Int {
                Int(stat(key)) ?? 0
            }

            func doubleStat(_ key: String) -> Double {
                Double(stat(key)) ?? 0.0
            }

            let parsedDate = parseRawDate(gameDate)

            if isPitcher {
                // Pitching stats mapped to DFSPlayerGameLog fields:
                // minutes = IP, points = K, rebounds = ER, assists = W (from Dec),
                // steals = H, blocks = BB, turnovers = HR
                // fgm = R, fga = P (pitches), threePM = GSC (game score)
                let ip = stat("IP")
                let k = intStat("K")
                let er = intStat("ER")
                let h = intStat("H")
                let bb = intStat("BB")
                let hr = intStat("HR")
                let r = intStat("R")
                let p = intStat("P")
                let dec = stat("DEC")

                // Parse IP for fantasy: "6.2" means 6 and 2/3 innings
                let ipParts = ip.split(separator: ".")
                let fullInnings = Double(ipParts.first ?? "0") ?? 0
                let partialOuts = ipParts.count > 1 ? (Double(ipParts[1]) ?? 0) / 3.0 : 0
                let ipValue = fullInnings + partialOuts

                // FanDuel-style MLB pitching fantasy scoring
                let fantasy = ipValue * 3.0 + Double(k) * 3.0 - Double(er) * 3.0
                    + (dec.contains("W") ? 6.0 : 0.0)

                // Encode W/L/- from Dec field into assists (1=W, -1=L, 0=other)
                let decValue: Int = dec.contains("W") ? 1 : (dec.contains("L") ? -1 : 0)

                gameLogs.append(DFSPlayerGameLog(
                    id: eventID,
                    date: formatGameDate(gameDate),
                    sortDate: parsedDate,
                    opponent: opponent,
                    minutes: ip,         // IP
                    points: k,           // K (strikeouts)
                    rebounds: er,         // ER
                    assists: decValue,    // W/L decision
                    steals: h,           // Hits allowed
                    blocks: bb,          // BB allowed
                    turnovers: hr,       // HR allowed
                    fgm: r,              // Runs allowed
                    fga: p,              // Pitches
                    threePM: Int(doubleStat("GSC")),  // Game Score
                    threePA: 0,
                    ftm: 0,
                    fta: 0,
                    fantasyPoints: fantasy
                ))
            } else {
                // Batting stats mapped to DFSPlayerGameLog fields:
                // minutes = "AB" (at bats), points = H, rebounds = HR, assists = RBI,
                // steals = R, blocks = BB, turnovers = SO
                // fgm = SB, fga = 2B, threePM = 3B, threePA = HBP
                let ab = intStat("AB")
                let h = intStat("H")
                let doubles = intStat("2B")
                let triples = intStat("3B")
                let hr = intStat("HR")
                let rbi = intStat("RBI")
                let r = intStat("R")
                let bb = intStat("BB")
                let hbp = intStat("HBP")
                let so = intStat("SO")
                let sb = intStat("SB")

                // FanDuel-style MLB batting fantasy scoring
                let singles = h - doubles - triples - hr
                let fantasy = Double(singles) * 3.0
                    + Double(doubles) * 6.0
                    + Double(triples) * 9.0
                    + Double(hr) * 12.0
                    + Double(rbi) * 3.0
                    + Double(r) * 3.0
                    + Double(bb) * 3.0
                    + Double(hbp) * 3.0
                    + Double(sb) * 6.0

                gameLogs.append(DFSPlayerGameLog(
                    id: eventID,
                    date: formatGameDate(gameDate),
                    sortDate: parsedDate,
                    opponent: opponent,
                    minutes: "\(ab)",    // AB
                    points: h,           // Hits
                    rebounds: hr,        // HR
                    assists: rbi,        // RBI
                    steals: r,           // Runs
                    blocks: bb,          // BB
                    turnovers: so,       // SO (strikeouts)
                    fgm: sb,             // SB
                    fga: doubles,        // 2B
                    threePM: triples,    // 3B
                    threePA: hbp,        // HBP
                    ftm: 0,
                    fta: 0,
                    fantasyPoints: fantasy
                ))
            }
        }

        return Array(gameLogs.sorted { $0.sortDate > $1.sortDate }.prefix(limit))
    }

    private func parseNHLGameLog(json: [String: Any], limit: Int, isGoalie: Bool) -> [DFSPlayerGameLog] {
        // ESPN NHL gamelog API returns skating stats for ALL players (including goalies).
        // Labels: ["G", "A", "PTS", "+/-", "PIM", "S", "SPCT", "PPG", "PPA", "SHG", "SHA", "GWG", "TOI/G", "PROD"]
        // For goalies, these stats are all 0 — so we extract W/L and score from event metadata.

        let topLabels = json["labels"] as? [String]

        var allEvents: [[String: Any]] = []
        if let seasonTypes = json["seasonTypes"] as? [[String: Any]] {
            for seasonType in seasonTypes {
                if let cats = seasonType["categories"] as? [[String: Any]] {
                    for cat in cats {
                        if let events = cat["events"] as? [[String: Any]] {
                            allEvents.append(contentsOf: events)
                        }
                    }
                }
            }
        }

        if allEvents.isEmpty, let directCategories = json["categories"] as? [[String: Any]] {
            for cat in directCategories {
                if let events = cat["events"] as? [[String: Any]] {
                    allEvents.append(contentsOf: events)
                }
            }
        }

        let labels: [String]
        if let topLabels, !topLabels.isEmpty {
            labels = topLabels
        } else if let seasonTypes = json["seasonTypes"] as? [[String: Any]] {
            let catLabels = seasonTypes.compactMap { st in
                (st["categories"] as? [[String: Any]])?.compactMap { $0["labels"] as? [String] }.first
            }.first
            labels = catLabels ?? []
        } else {
            return []
        }

        guard !allEvents.isEmpty else { return [] }

        let eventMeta = json["events"] as? [String: [String: Any]] ?? [:]

        var labelIndex: [String: Int] = [:]
        for (index, label) in labels.enumerated() {
            labelIndex[label.uppercased()] = index
        }

        var gameLogs: [DFSPlayerGameLog] = []

        for event in allEvents {
            guard let stats = event["stats"] as? [String] else { continue }

            let eventID: String = {
                if let s = event["eventId"] as? String { return s }
                if let n = event["eventId"] as? Int { return String(n) }
                if let s = event["id"] as? String { return s }
                if let n = event["id"] as? Int { return String(n) }
                return UUID().uuidString
            }()
            let meta = eventMeta[eventID]
            let gameDate = (meta?["gameDate"] as? String)
                ?? (event["gameDate"] as? String)
                ?? ""
            let opponent = parseOpponent(from: event, eventMeta: meta)

            func stat(_ key: String) -> String {
                guard let idx = labelIndex[key], idx < stats.count else { return "0" }
                return stats[idx]
            }

            func intStat(_ key: String) -> Int {
                Int(stat(key)) ?? 0
            }

            let parsedDate = parseRawDate(gameDate)

            if isGoalie {
                // ESPN NHL gamelog doesn't provide goaltending stats (SV/GA/etc.).
                // Extract W/L and score from event metadata instead.
                let gameResult = (meta?["gameResult"] as? String)
                    ?? (event["gameResult"] as? String)
                    ?? ""
                let score = (meta?["score"] as? String)
                    ?? (event["score"] as? String)
                    ?? ""

                let isWin = gameResult == "W"
                let isLoss = gameResult == "L"

                // Parse score "5-2" to extract goals against
                let scoreParts = score.split(separator: "-").compactMap { Int($0) }
                let teamScore = scoreParts.first ?? 0
                let opponentScore = scoreParts.count > 1 ? scoreParts[1] : 0
                // If it's an away game, the score format might be reversed
                let atVs = (meta?["atVs"] as? String) ?? ""
                let goalsAgainst: Int
                if atVs == "@" {
                    // Away: score is "awayScore-homeScore", so opponent's goals = homeScore
                    goalsAgainst = opponentScore
                } else {
                    // Home: score is "homeScore-awayScore", so opponent's goals = awayScore
                    goalsAgainst = opponentScore
                }
                let isShutout = goalsAgainst == 0 && isWin

                // Estimate saves based on typical ~30 shots per game
                let estimatedSaves = max(0, 30 - goalsAgainst)

                // FanDuel Goalie: W*12 + SO*8 + SV*0.8 + GA*(-4)
                let fantasy = (isWin ? 12.0 : 0.0) + (isShutout ? 8.0 : 0.0)
                    + Double(estimatedSaves) * 0.8 - Double(goalsAgainst) * 4.0

                gameLogs.append(DFSPlayerGameLog(
                    id: eventID,
                    date: formatGameDate(gameDate),
                    sortDate: parsedDate,
                    opponent: opponent,
                    minutes: score,          // Show score as context
                    points: estimatedSaves,  // Saves (estimated)
                    rebounds: goalsAgainst,  // Goals against
                    assists: isWin ? 1 : 0,  // Win
                    steals: isShutout ? 1 : 0, // Shutout
                    blocks: 0,
                    turnovers: isLoss ? 1 : 0, // Loss
                    fgm: 0, fga: 0, threePM: 0, threePA: 0, ftm: 0, fta: 0,
                    fantasyPoints: fantasy
                ))
            } else {
                // Skater stats — NHL gamelog labels: G, A, PTS, +/-, PIM, S, SPCT, PPG, PPA, SHG, SHA, GWG, TOI/G, PROD
                let g = intStat("G")
                let a = intStat("A")
                let sog = intStat("S") // "S" = shots in NHL gamelog (not "SOG")
                let ppg = intStat("PPG")
                let ppa = intStat("PPA")
                let shg = intStat("SHG")
                let sha = intStat("SHA")
                // BLK is not available in the NHL gamelog API — use 0
                let blk = 0

                // FanDuel Skater: G*12 + A*8 + SOG*1.6 + BLK*1.6 + PPG*0.5 + PPA*0.5 + SHG*2 + SHA*2
                let fantasy = Double(g) * 12.0 + Double(a) * 8.0
                    + Double(sog) * 1.6 + Double(blk) * 1.6
                    + Double(ppg) * 0.5 + Double(ppa) * 0.5
                    + Double(shg) * 2.0 + Double(sha) * 2.0

                gameLogs.append(DFSPlayerGameLog(
                    id: eventID,
                    date: formatGameDate(gameDate),
                    sortDate: parsedDate,
                    opponent: opponent,
                    minutes: "",
                    points: g,           // Goals
                    rebounds: a,         // Assists
                    assists: sog,        // Shots
                    steals: blk,         // Blocked shots (unavailable)
                    blocks: ppg + ppa,   // PP points
                    turnovers: shg + sha, // SH points
                    fgm: g, fga: a, threePM: sog, threePA: blk,
                    ftm: ppg + ppa, fta: shg + sha,
                    fantasyPoints: fantasy
                ))
            }
        }

        return Array(gameLogs.sorted { $0.sortDate > $1.sortDate }.prefix(limit))
    }

    private func parseOpponent(from event: [String: Any], eventMeta: [String: Any]? = nil) -> String {
        // Try from event metadata first (more reliable in web API)
        if let meta = eventMeta {
            if let opponent = meta["opponent"] as? [String: Any],
               let abbr = opponent["abbreviation"] as? String {
                let atVs = meta["atVs"] as? String ?? "vs"
                return "\(atVs) \(abbr)"
            }
        }
        // Try from the event itself
        if let opponent = event["opponent"] as? [String: Any] {
            if let abbr = opponent["abbreviation"] as? String {
                let homeAway = event["homeAway"] as? String ?? ""
                return homeAway == "away" ? "@\(abbr)" : "vs \(abbr)"
            }
        }
        if let atVs = event["atVs"] as? String,
           let opponentAbbreviation = event["opponentAbbreviation"] as? String {
            return "\(atVs) \(opponentAbbreviation)"
        }
        return "-"
    }

    private func formatNewsDate(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f.localizedString(for: date, relativeTo: Date())
        }
        return ""
    }

    private func formatGameDate(_ raw: String) -> String {
        let outputFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "M/d"
            return f
        }()

        // Try ISO8601 with fractional seconds (ESPN web API format)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) {
            return outputFormatter.string(from: date)
        }

        // Try standard ISO8601
        let iso2 = ISO8601DateFormatter()
        if let date = iso2.date(from: raw) {
            return outputFormatter.string(from: date)
        }

        // Fallback: extract date portion
        if raw.count >= 10 {
            let dateOnly = String(raw.prefix(10))
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let date = f.date(from: dateOnly) {
                return outputFormatter.string(from: date)
            }
        }

        return raw.prefix(10).description
    }

    /// Parse raw date string into a Date for sorting purposes
    private func parseRawDate(_ raw: String) -> Date {
        // Try ISO8601 with fractional seconds
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }

        // Try standard ISO8601
        let iso2 = ISO8601DateFormatter()
        if let date = iso2.date(from: raw) { return date }

        // Fallback: yyyy-MM-dd
        if raw.count >= 10 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let date = f.date(from: String(raw.prefix(10))) { return date }
        }

        return .distantPast
    }
}

struct ESPNPlayerNews: Identifiable {
    let id = UUID()
    let headline: String
    let description: String?
    let published: String
}

// MARK: - Live Scoring

/// Cache for the most recent score snapshot to avoid re-fetching on rapid tab switches.
/// Keyed by the set of game IDs so different slates (e.g. today vs yesterday) don't collide.
private final class LiveScoreCache: @unchecked Sendable {
    static let shared = LiveScoreCache()
    private let lock = NSLock()
    private var cachedSnapshot: DFSScoreSnapshot?
    private var cachedAt: Date?
    private var cachedGameIDs: Set<String>?
    private let ttl: TimeInterval = 25  // 25 seconds — slightly shorter than the 35s poll interval

    nonisolated func get(gameIDs: Set<String>) -> DFSScoreSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = cachedSnapshot,
              let at = cachedAt,
              let cached = cachedGameIDs,
              cached == gameIDs,
              Date().timeIntervalSince(at) < ttl else { return nil }
        return snapshot
    }

    nonisolated func set(_ snapshot: DFSScoreSnapshot, gameIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        cachedSnapshot = snapshot
        cachedAt = Date()
        cachedGameIDs = gameIDs
    }
}

struct ESPNDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Result from fetching a single game's live data
    private struct GameFetchResult: Sendable {
        let gameID: String
        let gameInfo: DFSGameLiveInfo
        let playerResults: [(String, Double, DFSPlayerLiveStats)]
        let isFinal: Bool
    }

    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        // Return cached snapshot if recent enough and for the same set of games
        let gameIDs = Set(games.map { $0.id })
        if let cached = LiveScoreCache.shared.get(gameIDs: gameIDs) {
            return cached
        }

        // Fetch all game summaries in parallel
        let results: [GameFetchResult] = await withTaskGroup(of: GameFetchResult?.self) { group in
            for game in games {
                guard !game.id.starts(with: "mock-") else { continue }
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(game.id)") else {
                        return nil
                    }

                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }

                    let state = self.extractState(fromSummaryPayload: payload)
                    let gameInfo = self.extractGameLiveInfo(fromSummaryPayload: payload, game: game)
                    let gameStatus = gameInfo.displayStatus
                    let gameFinal = gameInfo.state == "post"
                    let playerResults = self.extractPlayerStats(fromSummaryPayload: payload, gameStatus: gameStatus, gameFinal: gameFinal)

                    return GameFetchResult(
                        gameID: game.id,
                        gameInfo: gameInfo,
                        playerResults: playerResults,
                        isFinal: state == "post"
                    )
                }
            }

            var collected: [GameFetchResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfoByID: [String: DFSGameLiveInfo] = [:]

        let hasMockGames = games.contains { $0.id.starts(with: "mock-") }
        let fetchedGameIDs = Set(results.map { $0.gameID })
        let failedNonMockGames = games.filter { !$0.id.starts(with: "mock-") && !fetchedGameIDs.contains($0.id) }

        var allFetchedAreFinal = true

        for result in results {
            gameLiveInfoByID[result.gameID] = result.gameInfo
            if !result.isFinal { allFetchedAreFinal = false }
            for (playerID, fantasy, stats) in result.playerResults {
                pointsByPlayerID[playerID] = fantasy
                statsByPlayerID[playerID] = stats
            }
        }

        // A real game we couldn't fetch is NOT assumed done unless its start is
        // long past (a broken/stale event). A staggered slate's late game (e.g.
        // a midnight kickoff) must keep the slate LIVE until it finishes instead
        // of being tolerated as a failed fetch and settling the contest early.
        let staleFetchCutoff: TimeInterval = 8 * 3600
        let unfetchedStillPending = failedNonMockGames.contains { Date().timeIntervalSince($0.startTime) < staleFetchCutoff }
        let allGamesFinal = !hasMockGames && allFetchedAreFinal && !results.isEmpty && !unfetchedStillPending

        let snapshot = DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfoByID,
            allGamesFinal: allGamesFinal
        )
        LiveScoreCache.shared.set(snapshot, gameIDs: gameIDs)
        return snapshot
    }

    nonisolated private func extractState(fromSummaryPayload payload: [String: Any]) -> String? {
        guard let header = payload["header"] as? [String: Any],
              let competitions = header["competitions"] as? [[String: Any]],
              let competition = competitions.first,
              let status = competition["status"] as? [String: Any],
              let type = status["type"] as? [String: Any],
              let state = type["state"] as? String else {
            return nil
        }
        return state
    }

    nonisolated private func extractGameLiveInfo(fromSummaryPayload payload: [String: Any], game: DFSSlateGame) -> DFSGameLiveInfo {
        var awayScore = 0
        var homeScore = 0
        var clock = "0:00"
        var period = 1
        var state = "pre"

        if let header = payload["header"] as? [String: Any],
           let competitions = header["competitions"] as? [[String: Any]],
           let competition = competitions.first {

            // Game state
            if let status = competition["status"] as? [String: Any],
               let typeInfo = status["type"] as? [String: Any],
               let stateStr = typeInfo["state"] as? String {
                state = stateStr
            }

            // Clock and period
            if let status = competition["status"] as? [String: Any] {
                clock = status["displayClock"] as? String ?? "0:00"
                period = status["period"] as? Int ?? 1
            }

            // Team scores
            if let competitors = competition["competitors"] as? [[String: Any]] {
                for competitor in competitors {
                    let score = Int(competitor["score"] as? String ?? "0") ?? 0
                    let homeAway = competitor["homeAway"] as? String ?? ""
                    if homeAway == "home" { homeScore = score }
                    else { awayScore = score }
                }
            }
        }

        return DFSGameLiveInfo(
            id: game.id,
            awayTeam: game.awayTeam,
            homeTeam: game.homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            clock: clock,
            period: period,
            state: state
        )
    }

    nonisolated private func extractPlayerStats(
        fromSummaryPayload payload: [String: Any],
        gameStatus: String,
        gameFinal: Bool
    ) -> [(String, Double, DFSPlayerLiveStats)] {
        guard let boxscore = payload["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        var results: [(String, Double, DFSPlayerLiveStats)] = []
        for teamBlock in players {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }
            for statCategory in statistics {
                guard let labels = statCategory["labels"] as? [String],
                      let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }

                // Build label index
                var labelIndex: [String: Int] = [:]
                for (i, label) in labels.enumerated() {
                    labelIndex[label.uppercased()] = i
                }

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          let values = athlete["stats"] as? [String] else { continue }

                    let athleteName = (athleteInfo["displayName"] as? String)
                        ?? (athleteInfo["shortName"] as? String)
                        ?? "Player \(athleteID)"

                    func doubleStat(_ key: String) -> Double {
                        guard let idx = labelIndex[key], idx < values.count else { return 0 }
                        return Double(values[idx]) ?? 0
                    }
                    func intStat(_ key: String) -> Int {
                        Int(doubleStat(key))
                    }
                    func strStat(_ key: String) -> String {
                        guard let idx = labelIndex[key], idx < values.count else { return "0" }
                        return values[idx]
                    }

                    let pts = intStat("PTS")
                    let reb = intStat("REB")
                    let ast = intStat("AST")
                    let stl = intStat("STL")
                    let blk = intStat("BLK")
                    let to = intStat("TO")
                    let min = strStat("MIN")

                    // Parse FG, 3PT, FT split stats
                    let fgStr = strStat("FG")
                    let fgParts = fgStr.split(separator: "-")
                    let fgm = fgParts.count >= 1 ? Int(fgParts[0]) ?? 0 : 0
                    let fga = fgParts.count >= 2 ? Int(fgParts[1]) ?? 0 : 0

                    let threeStr = strStat("3PT")
                    let threeParts = threeStr.split(separator: "-")
                    let threePM = threeParts.count >= 1 ? Int(threeParts[0]) ?? 0 : 0
                    let threePA = threeParts.count >= 2 ? Int(threeParts[1]) ?? 0 : 0

                    let ftStr = strStat("FT")
                    let ftParts = ftStr.split(separator: "-")
                    let ftm = ftParts.count >= 1 ? Int(ftParts[0]) ?? 0 : 0
                    let fta = ftParts.count >= 2 ? Int(ftParts[1]) ?? 0 : 0

                    let fantasy =
                        Double(pts) * 1.0 +
                        Double(reb) * 1.2 +
                        Double(ast) * 1.5 +
                        Double(stl) * 3.0 +
                        Double(blk) * 3.0 -
                        Double(to) * 1.0

                    let playerID = "nba-\(athleteID)"
                    let stats = DFSPlayerLiveStats(
                        name: athleteName,
                        points: pts, rebounds: reb, assists: ast,
                        steals: stl, blocks: blk, turnovers: to,
                        minutes: min,
                        fgm: fgm, fga: fga,
                        threePM: threePM, threePA: threePA,
                        ftm: ftm, fta: fta,
                        fantasyPoints: fantasy,
                        gameStatus: gameStatus,
                        gameFinal: gameFinal
                    )
                    results.append((playerID, fantasy, stats))
                }
            }
        }
        return results
    }
}

// MARK: - WNBA DFS Slate Provider
//
// Faithful clone of `ESPNNBADFSSlateProvider` with WNBA substitutions:
// ESPN endpoints use `basketball/wnba`, player/tournament IDs use the
// `wnba-` prefix, salary lookups pass sport `"wnba"`, the shared roster
// cache uses a distinct `"wnba"` slate key, and logs use `[WNBA-DFS]`.
// Roster/scoring config (50000 cap, 8-player classic, showdown) and the
// DraftKings basketball scoring formula are IDENTICAL to NBA.

struct ESPNWNBADFSSlateProvider: DFSSlateProvider {
    private let session: URLSession
    private let cache = ESPNRosterCache.shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        // Return cached slate if recent
        if let cached = cache.getSlate(key: "wnba") {
            return cached
        }

        // Start fetching real DraftKings salaries in parallel with ESPN data
        async let rgSalaries = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "wnba", maxClassicSalary: 13000)

        var events = try await fetchUpcomingWNBAEvents()
        guard !events.isEmpty else {
            throw NSError(domain: "DFS", code: 1)
        }

        // Build team abbreviation → event ID mapping
        var teamToGameID: [String: String] = [:]
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                teamToGameID[competitor.team.abbreviation] = event.id
            }
        }

        let teamRefs = Array(uniqueTeams(from: events).prefix(30))

        // Fetch all rosters in parallel using TaskGroup. We need TWO outputs
        // from this pass: the top-9-per-team pool that becomes the slate's
        // primary player list (unchanged behavior), AND a FULL-roster name
        // lookup table so Phase 2.5 can resolve injected RG players to
        // their real ESPN IDs. Without the full-roster table, bench players
        // get stub IDs like `wnba-<dkDraftableId>` and ESPN box scores can't
        // match them at scoring time → empty stats.
        let rostersResult: (top9: [DFSPlayer], fullByName: [String: DFSPlayer]) = try await withThrowingTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let gameID = teamToGameID[team.abbreviation]
                group.addTask {
                    return try await self.fetchRoster(teamID: team.id, teamAbbreviation: team.abbreviation, gameID: gameID)
                }
            }
            var top9Pool: [DFSPlayer] = []
            var fullLookup: [String: DFSPlayer] = [:]
            for try await roster in group {
                top9Pool.append(contentsOf: roster.prefix(9))
                for player in roster {
                    let key = RotoGrindersSalaryProvider.normalizeName(player.name)
                    if fullLookup[key] == nil { fullLookup[key] = player }
                }
            }
            return (top9Pool, fullLookup)
        }
        let players = rostersResult.top9
        let fullWNBARosterByName = rostersResult.fullByName

        var deduped = deduplicatePlayers(players)
        guard !deduped.isEmpty else {
            throw NSError(domain: "DFS", code: 2)
        }

        // Apply real DraftKings salaries from DFF/RotoGrinders where available.
        // Only use real data when the slate clearly matches (>30% players found).
        // When slates don't match, keep the FPPG-based estimatedSalary values.
        let realSalaries = await rgSalaries

        // Align the slate to the SOONEST day DraftKings actually priced. ESPN's
        // window (today + tomorrow) can surface a lone early-week game DK hasn't
        // posted, while DK's next slate is a day later. Pick the earliest day we
        // can price — a single game is "priced" if DK posts its showdown slate,
        // a multi-game day is "priced" if classic salaries match its players —
        // and restrict events + the player pool to it. This keeps today's single
        // game when DK has its showdown, but yields an unpriced orphan game to a
        // posted later-day slate.
        do {
            let cal = Calendar.current
            let daysAsc = Set(events.map { cal.startOfDay(for: $0.date) }).sorted()
            var chosenDay: Date? = nil
            if daysAsc.count > 1 {
                for day in daysAsc {
                    let dayEvents = events.filter { cal.startOfDay(for: $0.date) == day }
                    if dayEvents.count == 1, let comp = dayEvents.first?.competitions.first,
                       let away = comp.competitors.first(where: { $0.homeAway == "away" })?.team.abbreviation,
                       let home = comp.competitors.first(where: { $0.homeAway == "home" })?.team.abbreviation {
                        let sd = await RotoGrindersSalaryProvider.shared.fetchShowdownPlayersForGame(
                            sport: "wnba", awayHashtag: away, homeHashtag: home
                        )
                        if !sd.isEmpty { chosenDay = day; break }
                    } else if dayEvents.count > 1, !realSalaries.isEmpty {
                        let dayIDs = Set(dayEvents.map { $0.id })
                        let matched = deduped.filter {
                            dayIDs.contains($0.gameID ?? "")
                            && RotoGrindersSalaryProvider.lookupSalary(espnName: $0.name, in: realSalaries) != nil
                        }.count
                        if matched >= 5 { chosenDay = day; break }
                    }
                }
            }
            if let chosenDay {
                let kept = events.filter { cal.startOfDay(for: $0.date) == chosenDay }
                if !kept.isEmpty && kept.count < events.count {
                    let keepIDs = Set(kept.map { $0.id })
                    print("[WNBA-DFS] DK-day alignment: \(events.count) games across window → \(kept.count) on DK-priced day \(dateKey(for: chosenDay))")
                    events = kept
                    deduped = deduped.filter { keepIDs.contains($0.gameID ?? "") }
                }
            }
        }

        // Build the game list + single-game detection up front so we can fall
        // back to DraftKings SHOWDOWN (captain) pricing when there's no classic
        // main slate. On a single-game WNBA night DK only publishes showdown
        // pricing; the old code required classic salaries and threw — which hid
        // the user's already-entered contest. Mirror UFC: price off showdown.
        let slateDate = events.first?.date ?? Date()
        let tournamentID = "wnba-\(dateKey(for: slateDate))"
        let includedGames: [DFSSlateGame] = events.compactMap { event in
            guard let competition = event.competitions.first else { return nil }
            guard let away = competition.competitors.first(where: { $0.homeAway == "away" }) else { return nil }
            guard let home = competition.competitors.first(where: { $0.homeAway == "home" }) else { return nil }
            return DFSSlateGame(
                id: event.id,
                awayTeam: away.team.abbreviation,
                homeTeam: home.team.abbreviation,
                startTime: event.date,
                state: competition.status.type.state
            )
        }
        // Single-game slate: the entire day has only 1 game scheduled. Use
        // total games (not active) so it doesn't flip mid-slate as games finish.
        let isSingleGame = includedGames.count == 1

        // Pull DK showdown (captain) pricing up front for single-game nights —
        // both to price the main pool when no classic slate exists and to feed
        // the captain-mode tournament + Phase 2.5 augmentation below.
        var wnbaSlatePlayers: [RotoGrindersSalaryProvider.LineupHQSlatePlayer] = []
        var showdownUtilSalaries: [String: Int] = [:]
        if isSingleGame, let firstGame = includedGames.first {
            let slatePlayers = await RotoGrindersSalaryProvider.shared.fetchShowdownPlayersForGame(
                sport: "wnba", awayHashtag: firstGame.awayTeam, homeHashtag: firstGame.homeTeam,
                startTime: firstGame.startTime
            )
            if !slatePlayers.isEmpty {
                wnbaSlatePlayers = slatePlayers
                for p in slatePlayers { showdownUtilSalaries[p.normalizedName] = p.utilSalary }
            }
        }

        // Decide which salary map prices the slate. Classic main-slate salaries
        // win when they actually match this slate (>30%); otherwise fall back to
        // single-game showdown pricing. Only give up (show "no slate") when
        // neither source is usable.
        let classicMatch = realSalaries.isEmpty ? 0 :
            deduped.filter { RotoGrindersSalaryProvider.lookupSalary(espnName: $0.name, in: realSalaries) != nil }.count
        let classicMatchRate = Double(classicMatch) / Double(max(1, deduped.count))
        let salarySource: [String: Int]
        let pricingMode: String
        if !realSalaries.isEmpty && classicMatchRate > 0.30 {
            salarySource = realSalaries
            pricingMode = "classic"
        } else if isSingleGame && !showdownUtilSalaries.isEmpty {
            salarySource = showdownUtilSalaries
            pricingMode = "showdown"
        } else {
            throw NSError(domain: "WNBADFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's WNBA slate"])
        }

        let rgMin = salarySource.values.min() ?? 3500
        let rgMax = salarySource.values.max() ?? 13000
        let allFPPGs = deduped.map { $0.projectedPoints }
        let fppgMin = allFPPGs.min() ?? 0
        let fppgMax = max(fppgMin + 1, allFPPGs.max() ?? 50)
        var applied = 0
        var calibrated = 0
        let finalPlayers: [DFSPlayer] = deduped.map { player in
            if let realSalary = RotoGrindersSalaryProvider.lookupSalary(espnName: player.name, in: salarySource) {
                applied += 1
                var matched = DFSPlayer(
                    id: player.id, name: player.name, team: player.team,
                    position: player.position, salary: realSalary,
                    projectedPoints: player.projectedPoints,
                    gameID: player.gameID, injuryStatus: player.injuryStatus
                )
                matched.isConfirmedActive = true
                return matched
            }
            calibrated += 1
            let fppgFraction = min(1.0, max(0, (player.projectedPoints - fppgMin) / (fppgMax - fppgMin)))
            let curved = pow(fppgFraction, 0.85)
            let salary = rgMin + Int(curved * Double(rgMax - rgMin))
            let roundedSalary = (salary / 100) * 100
            var unmatched = DFSPlayer(
                id: player.id, name: player.name, team: player.team,
                position: player.position, salary: max(rgMin, roundedSalary),
                projectedPoints: player.projectedPoints,
                gameID: player.gameID, injuryStatus: player.injuryStatus
            )
            unmatched.isConfirmedActive = false
            return unmatched
        }
        print("[WNBA-DFS] priced \(applied)/\(deduped.count) (calibrated \(calibrated)) via \(pricingMode), range=$\(rgMin)-$\(rgMax)")

        var sortedPlayers = finalPlayers.sorted(by: { $0.salary > $1.salary })

        // Showdown pricing for the captain-mode tournament. Single-game nights
        // already fetched it above; multi-game slates fetch the per-player DK
        // map as a fallback.
        let dkShowdownSalaries: [String: Int]? = await {
            if isSingleGame { return showdownUtilSalaries.isEmpty ? nil : showdownUtilSalaries }
            let names = sortedPlayers.map(\.name)
            let dk = await RotoGrindersSalaryProvider.shared.fetchDKSalaries(sport: "wnba", slatePlayerNames: names)
            return dk.isEmpty ? nil : dk
        }()

        // Phase 2.5: augment the player pool with any RG-slate player not
        // already in our ESPN-derived list. Without this, slate-builder
        // bench players never show up even though DK lists them as eligible.
        // We create a stub `DFSPlayer` keyed off the DK draftableId so live
        // scoring can still match by name to ESPN box scores once the game
        // starts.
        print("[WNBA-DFS-2.5] candidate slate players: \(wnbaSlatePlayers.count), pool before augmentation: \(sortedPlayers.count)")
        if !wnbaSlatePlayers.isEmpty {
            let ourNames = Set(sortedPlayers.map { RotoGrindersSalaryProvider.normalizeName($0.name) })
            var augmented = sortedPlayers
            var injectedNames: [String] = []
            var skippedAlreadyInPool = 0
            let firstGameID = includedGames.first?.id ?? ""
            var resolvedFromRoster = 0
            for rgPlayer in wnbaSlatePlayers {
                let normalized = RotoGrindersSalaryProvider.normalizeName(rgPlayer.fullName)
                if ourNames.contains(normalized) {
                    skippedAlreadyInPool += 1
                    continue
                }
                // Prefer the ESPN-roster match — bench players are on their
                // team's full ESPN roster, just outside the top-9 pool. Using
                // the ESPN ID means live box-score scoring will match them
                // naturally during the game. Fall back to a DK draftableId
                // stub only when ESPN has no record of them.
                let rosterMatch = fullWNBARosterByName[normalized]
                let resolvedID = rosterMatch?.id ?? "wnba-\(rgPlayer.dkPlayerID ?? rgPlayer.rgPlayerID ?? rgPlayer.normalizedName)"
                let resolvedTeam = rosterMatch?.team ?? ""
                let resolvedProjection = rosterMatch?.projectedPoints ?? 0
                if rosterMatch != nil { resolvedFromRoster += 1 }
                augmented.append(DFSPlayer(
                    id: resolvedID,
                    name: rgPlayer.fullName,
                    team: resolvedTeam,
                    position: rgPlayer.position,
                    salary: rgPlayer.utilSalary,
                    projectedPoints: resolvedProjection,
                    gameID: firstGameID,
                    injuryStatus: nil
                ))
                injectedNames.append(rgPlayer.fullName)
            }
            print("[WNBA-DFS-2.5] resolved-from-roster: \(resolvedFromRoster)/\(injectedNames.count) — these will have live ESPN box-score stats")
            if !injectedNames.isEmpty {
                let preview = injectedNames.prefix(10).joined(separator: ", ")
                print("[WNBA-DFS-2.5] injected \(injectedNames.count) DK-eligible players missing from ESPN pool: \(preview)\(injectedNames.count > 10 ? "…" : "")")
            } else {
                print("[WNBA-DFS-2.5] no missing players to inject (slate had \(wnbaSlatePlayers.count), \(skippedAlreadyInPool) already in pool)")
            }
            // Re-sort by salary so the augmented list flows back through the builder correctly.
            sortedPlayers = augmented.sorted(by: { $0.salary > $1.salary })
        }

        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: "WNBA",
            mainSalaryCap: 50000,
            mainLineupSize: 8,
            mainRosterSlots: nil,
            isSingleGameSlate: isSingleGame,
            includedGames: includedGames,
            mainPlayers: sortedPlayers,
            showdownSalaries: dkShowdownSalaries
        )

        let slate = DFSSlate(
            tournaments: tournaments,
            includedGames: includedGames,
            players: sortedPlayers,
            singleGamePlayers: sgPlayers
        )
        cache.setSlate(slate, key: "wnba")
        return slate
    }

    private func fetchUpcomingWNBAEvents() async throws -> [NBAScoreboardEvent] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let dateKeys = [dateKey(for: yesterday), dateKey(for: Date()), dateKey(for: tomorrow)]

        // Fetch all 3 days in parallel
        let allScoreboards: [NBAScoreboardResponse] = await withTaskGroup(of: NBAScoreboardResponse?.self) { group in
            for dk in dateKeys {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/scoreboard?dates=\(dk)") else {
                        return nil
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return nil
                    }
                    return try? JSONDecoder.dfsDecoder.decode(NBAScoreboardResponse.self, from: data)
                }
            }
            var results: [NBAScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var preEvents: [NBAScoreboardEvent] = []
        var liveEvents: [NBAScoreboardEvent] = []
        var postEvents: [NBAScoreboardEvent] = []

        for scoreboard in allScoreboards {
            for event in scoreboard.events {
                guard let competition = event.competitions.first else { continue }
                let state = competition.status.type.state
                // Accept "pre" games from today or later. A game that is "pre" but
                // whose scheduled start has already passed (delayed tip-off) must
                // still be included — ESPN's state is authoritative.
                if state == "pre" && calendar.startOfDay(for: event.date) >= today {
                    preEvents.append(event)
                } else if state == "in" {
                    liveEvents.append(event)
                } else if state == "post" {
                    postEvents.append(event)
                }
            }
        }

        // If there are live games, include them AND finished/upcoming games from the same day
        // so that all players from the full slate are available for scoring
        if !liveEvents.isEmpty {
            let liveDay = calendar.startOfDay(for: liveEvents.first!.date)
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            return (liveEvents + sameDayPost + sameDayPre).sorted(by: { $0.date < $1.date })
        }

        // All-day slate: if there are finished (post) games from today AND upcoming (pre)
        // games from today, include BOTH so the slate doesn't shrink when early games
        // finish before late games start.
        if !preEvents.isEmpty {
            let earliestPreDay = preEvents.map { calendar.startOfDay(for: $0.date) }.min()!
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == earliestPreDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == earliestPreDay }
            if !sameDayPost.isEmpty {
                return (sameDayPre + sameDayPost).sorted(by: { $0.date < $1.date })
            }
            // No games have started yet. Return the FULL upcoming window (today
            // + tomorrow) rather than collapsing to the earliest day — the
            // caller (fetchSlate) aligns the slate to whichever day DraftKings
            // has actually priced. DK frequently posts tomorrow's main slate
            // when today has only a lone early game it never made a slate for.
            return preEvents.sorted(by: { $0.date < $1.date })
        }

        // No live or pre games — return today's finished (post) games so the tournament
        // can still be loaded for settlement.
        if !postEvents.isEmpty {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let todaysPost = postEvents.filter { calendar.startOfDay(for: $0.date) == today }
            if !todaysPost.isEmpty {
                return todaysPost.sorted(by: { $0.date < $1.date })
            }
            // If no games today, return the most recent day's finished games
            let groupedByDay = Dictionary(grouping: postEvents) { calendar.startOfDay(for: $0.date) }
            if let mostRecentDay = groupedByDay.keys.sorted().last {
                return (groupedByDay[mostRecentDay] ?? []).sorted(by: { $0.date < $1.date })
            }
        }

        return []
    }

    private func uniqueTeams(from events: [NBAScoreboardEvent]) -> [NBATeamRef] {
        var seen = Set<String>()
        var result: [NBATeamRef] = []

        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                let id = competitor.team.id
                guard seen.insert(id).inserted else { continue }
                result.append(NBATeamRef(id: id, abbreviation: competitor.team.abbreviation))
            }
        }

        return result
    }

    private func fetchRoster(teamID: String, teamAbbreviation: String, gameID: String? = nil) async throws -> [DFSPlayer] {
        // Check cache first
        if let cached = cache.getRoster(teamID: teamID, gameID: gameID) {
            return cached
        }

        let performanceRatings = try await fetchPerformanceRatings(teamID: teamID)
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/teams/\(teamID)/roster") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let roster = try? JSONDecoder().decode(NBARosterResponse.self, from: data) else {
            return []
        }

        let players = roster.athletes.map { athlete in
            let position = athlete.position?.abbreviation ?? "UTIL"
            let fppg = performanceRatings[athlete.id] ?? 0.0
            let salary = estimatedSalary(for: athlete.id, position: position, rating: fppg)
            let projection = projectedPoints(for: salary, position: position, rating: fppg)

            // Parse injury status
            let injuryStatus: String?
            if let injury = athlete.injuries?.first, let status = injury.status {
                switch status.lowercased() {
                case "out": injuryStatus = "O"
                case "day-to-day": injuryStatus = "GTD"
                case "questionable": injuryStatus = "Q"
                case "doubtful": injuryStatus = "D"
                case "probable": injuryStatus = "P"
                default: injuryStatus = nil
                }
            } else {
                injuryStatus = nil
            }

            return DFSPlayer(
                id: "wnba-\(athlete.id)",
                name: athlete.fullName,
                team: teamAbbreviation,
                position: position,
                salary: salary,
                projectedPoints: projection,
                gameID: gameID,
                injuryStatus: injuryStatus
            )
        }
        .sorted { $0.projectedPoints > $1.projectedPoints }

        cache.setRoster(teamID: teamID, gameID: gameID, players: players)
        return players
    }

    /// Per-player stats parsed from ESPN: FPPG (fantasy points per game), GP, and minutes
    struct PlayerStatProfile {
        let fppg: Double          // fantasy points per game using DK formula
        let gamesPlayed: Int
        let minutesPerGame: Double
        let ppg: Double
    }

    /// Fetch actual per-player stats from ESPN and compute fantasy point averages.
    /// Returns [athleteID: PlayerStatProfile] for all players on the team.
    private func fetchPerformanceRatings(teamID: String) async throws -> [String: Double] {
        // Check cache first
        if let cached = cache.getRatings(teamID: teamID) {
            return cached
        }

        let profiles = try await fetchPlayerStatProfiles(teamID: teamID)
        // Convert to simple ratings dictionary for cache compatibility
        // Use FPPG directly as the "rating" — salary function will handle mapping
        let ratings = profiles.mapValues { $0.fppg }
        cache.setRatings(teamID: teamID, ratings: ratings)
        return ratings
    }

    /// Parsed stat profiles cache (separate from the simple ratings cache)
    private func fetchPlayerStatProfiles(teamID: String) async throws -> [String: PlayerStatProfile] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/teams/\(teamID)/athletes/statistics") else {
            return [:]
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return [:]
        }

        var profiles: [String: PlayerStatProfile] = [:]

        // results[0] contains all players with full statistics
        guard let firstResult = results.first,
              let leaders = firstResult["leaders"] as? [[String: Any]] else {
            return [:]
        }

        for leader in leaders {
            guard let athlete = leader["athlete"] as? [String: Any],
                  let athleteID = athlete["id"] as? String else { continue }

            guard let statistics = leader["statistics"] as? [[String: Any]] else { continue }

            // Parse stats from all 3 sections (general, offensive, defensive)
            var ppg: Double = 0, rpg: Double = 0, apg: Double = 0
            var spg: Double = 0, bpg: Double = 0, topg: Double = 0
            var gp: Int = 0, mpg: Double = 0
            var threepmg: Double = 0

            for section in statistics {
                guard let stats = section["stats"] as? [[String: Any]] else { continue }
                for stat in stats {
                    guard let name = stat["name"] as? String,
                          let value = stat["value"] as? Double else { continue }
                    switch name {
                    case "avgPoints": ppg = value
                    case "avgRebounds": rpg = value
                    case "avgAssists": apg = value
                    case "avgSteals": spg = value
                    case "avgBlocks": bpg = value
                    case "avgTurnovers": topg = value
                    case "gamesPlayed": gp = Int(value)
                    case "avgMinutes": mpg = value
                    case "avgThreePointFieldGoalsMade": threepmg = value
                    default: break
                    }
                }
            }

            // Compute DK-style fantasy points per game
            // DK NBA/WNBA: PTS×1 + REB×1.25 + AST×1.5 + STL×2 + BLK×2 + TO×-0.5 + 3PM×0.5
            let fppg = ppg * 1.0
                + rpg * 1.25
                + apg * 1.5
                + spg * 2.0
                + bpg * 2.0
                - topg * 0.5
                + threepmg * 0.5

            profiles[athleteID] = PlayerStatProfile(
                fppg: fppg,
                gamesPlayed: gp,
                minutesPerGame: mpg,
                ppg: ppg
            )
        }

        return profiles
    }

    /// Map fantasy points per game to DK-style salary.
    /// DK salary range: $3,500 - $12,500
    private func estimatedSalary(for playerID: String, position: String, rating: Double) -> Int {
        // rating is now FPPG (fantasy points per game)
        let fppg = rating

        let salary: Int
        if fppg >= 50 {
            // Superstars: steep curve at the top
            let fraction = min(1.0, (fppg - 50.0) / 15.0)
            salary = 10000 + Int(fraction * 2500.0)
        } else if fppg >= 40 {
            let fraction = (fppg - 40.0) / 10.0
            salary = 8000 + Int(fraction * 2000.0)
        } else if fppg >= 25 {
            let fraction = (fppg - 25.0) / 15.0
            salary = 5500 + Int(fraction * 2500.0)
        } else if fppg >= 15 {
            let fraction = (fppg - 15.0) / 10.0
            salary = 4000 + Int(fraction * 1500.0)
        } else {
            let fraction = max(0, fppg) / 15.0
            salary = 3500 + Int(fraction * 500.0)
        }

        // Round to nearest $100 with small stable jitter
        let stableHash = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = (abs(stableHash % 3) - 1) * 100  // -100, 0, or +100
        let rounded = ((salary + jitter + 50) / 100) * 100
        return max(3500, min(12500, rounded))
    }

    /// Project fantasy points based on actual FPPG from ESPN stats.
    private func projectedPoints(for salary: Int, position: String, rating: Double) -> Double {
        // rating is now FPPG — use it directly with slight regression to mean
        let fppg = rating
        // Players with no stats at all shouldn't get a free projection boost
        guard fppg > 0 else { return 0.0 }
        // Regress slightly toward position average to account for variance
        let positionAvg: Double
        switch position {
        case "PG": positionAvg = 28.0
        case "SG", "SF": positionAvg = 25.0
        case "PF", "C": positionAvg = 27.0
        default: positionAvg = 20.0
        }
        // 85% actual FPPG + 15% position average (mild regression)
        let projected = fppg * 0.85 + positionAvg * 0.15
        return (projected * 10).rounded() / 10
    }

    private func deduplicatePlayers(_ players: [DFSPlayer]) -> [DFSPlayer] {
        var seen = Set<String>()
        return players.filter { seen.insert($0.id).inserted }
    }

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - WNBA DFS Live Scoring Provider
//
// Faithful clone of the NBA live scoring provider (`ESPNDFSLiveScoringProvider`)
// with WNBA substitutions: ESPN summary endpoint uses `basketball/wnba` and
// player IDs use the `wnba-` prefix. The DraftKings basketball box-score
// scoring formula is IDENTICAL to NBA.

struct ESPNWNBADFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Result from fetching a single game's live data
    private struct GameFetchResult: Sendable {
        let gameID: String
        let gameInfo: DFSGameLiveInfo
        let playerResults: [(String, Double, DFSPlayerLiveStats)]
        let isFinal: Bool
    }

    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        // Return cached snapshot if recent enough and for the same set of games
        let gameIDs = Set(games.map { $0.id })
        if let cached = LiveScoreCache.shared.get(gameIDs: gameIDs) {
            return cached
        }

        // Fetch all game summaries in parallel
        let results: [GameFetchResult] = await withTaskGroup(of: GameFetchResult?.self) { group in
            for game in games {
                guard !game.id.starts(with: "mock-") else { continue }
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/summary?event=\(game.id)") else {
                        return nil
                    }

                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }

                    let state = self.extractState(fromSummaryPayload: payload)
                    let gameInfo = self.extractGameLiveInfo(fromSummaryPayload: payload, game: game)
                    let gameStatus = gameInfo.displayStatus
                    let gameFinal = gameInfo.state == "post"
                    let playerResults = self.extractPlayerStats(fromSummaryPayload: payload, gameStatus: gameStatus, gameFinal: gameFinal)

                    return GameFetchResult(
                        gameID: game.id,
                        gameInfo: gameInfo,
                        playerResults: playerResults,
                        isFinal: state == "post"
                    )
                }
            }

            var collected: [GameFetchResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfoByID: [String: DFSGameLiveInfo] = [:]

        let hasMockGames = games.contains { $0.id.starts(with: "mock-") }
        let fetchedGameIDs = Set(results.map { $0.gameID })
        let failedNonMockGames = games.filter { !$0.id.starts(with: "mock-") && !fetchedGameIDs.contains($0.id) }

        var allFetchedAreFinal = true

        for result in results {
            gameLiveInfoByID[result.gameID] = result.gameInfo
            if !result.isFinal { allFetchedAreFinal = false }
            for (playerID, fantasy, stats) in result.playerResults {
                pointsByPlayerID[playerID] = fantasy
                statsByPlayerID[playerID] = stats
            }
        }

        // A real game we couldn't fetch is NOT assumed done unless its start is
        // long past (a broken/stale event). A staggered slate's late game (e.g.
        // a midnight kickoff) must keep the slate LIVE until it finishes instead
        // of being tolerated as a failed fetch and settling the contest early.
        let staleFetchCutoff: TimeInterval = 8 * 3600
        let unfetchedStillPending = failedNonMockGames.contains { Date().timeIntervalSince($0.startTime) < staleFetchCutoff }
        let allGamesFinal = !hasMockGames && allFetchedAreFinal && !results.isEmpty && !unfetchedStillPending

        let snapshot = DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfoByID,
            allGamesFinal: allGamesFinal
        )
        LiveScoreCache.shared.set(snapshot, gameIDs: gameIDs)
        return snapshot
    }

    nonisolated private func extractState(fromSummaryPayload payload: [String: Any]) -> String? {
        guard let header = payload["header"] as? [String: Any],
              let competitions = header["competitions"] as? [[String: Any]],
              let competition = competitions.first,
              let status = competition["status"] as? [String: Any],
              let type = status["type"] as? [String: Any],
              let state = type["state"] as? String else {
            return nil
        }
        return state
    }

    nonisolated private func extractGameLiveInfo(fromSummaryPayload payload: [String: Any], game: DFSSlateGame) -> DFSGameLiveInfo {
        var awayScore = 0
        var homeScore = 0
        var clock = "0:00"
        var period = 1
        var state = "pre"

        if let header = payload["header"] as? [String: Any],
           let competitions = header["competitions"] as? [[String: Any]],
           let competition = competitions.first {

            // Game state
            if let status = competition["status"] as? [String: Any],
               let typeInfo = status["type"] as? [String: Any],
               let stateStr = typeInfo["state"] as? String {
                state = stateStr
            }

            // Clock and period
            if let status = competition["status"] as? [String: Any] {
                clock = status["displayClock"] as? String ?? "0:00"
                period = status["period"] as? Int ?? 1
            }

            // Team scores
            if let competitors = competition["competitors"] as? [[String: Any]] {
                for competitor in competitors {
                    let score = Int(competitor["score"] as? String ?? "0") ?? 0
                    let homeAway = competitor["homeAway"] as? String ?? ""
                    if homeAway == "home" { homeScore = score }
                    else { awayScore = score }
                }
            }
        }

        return DFSGameLiveInfo(
            id: game.id,
            awayTeam: game.awayTeam,
            homeTeam: game.homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            clock: clock,
            period: period,
            state: state
        )
    }

    nonisolated private func extractPlayerStats(
        fromSummaryPayload payload: [String: Any],
        gameStatus: String,
        gameFinal: Bool
    ) -> [(String, Double, DFSPlayerLiveStats)] {
        guard let boxscore = payload["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        var results: [(String, Double, DFSPlayerLiveStats)] = []
        for teamBlock in players {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }
            for statCategory in statistics {
                guard let labels = statCategory["labels"] as? [String],
                      let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }

                // Build label index
                var labelIndex: [String: Int] = [:]
                for (i, label) in labels.enumerated() {
                    labelIndex[label.uppercased()] = i
                }

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          let values = athlete["stats"] as? [String] else { continue }

                    let athleteName = (athleteInfo["displayName"] as? String)
                        ?? (athleteInfo["shortName"] as? String)
                        ?? "Player \(athleteID)"

                    func doubleStat(_ key: String) -> Double {
                        guard let idx = labelIndex[key], idx < values.count else { return 0 }
                        return Double(values[idx]) ?? 0
                    }
                    func intStat(_ key: String) -> Int {
                        Int(doubleStat(key))
                    }
                    func strStat(_ key: String) -> String {
                        guard let idx = labelIndex[key], idx < values.count else { return "0" }
                        return values[idx]
                    }

                    let pts = intStat("PTS")
                    let reb = intStat("REB")
                    let ast = intStat("AST")
                    let stl = intStat("STL")
                    let blk = intStat("BLK")
                    let to = intStat("TO")
                    let min = strStat("MIN")

                    // Parse FG, 3PT, FT split stats
                    let fgStr = strStat("FG")
                    let fgParts = fgStr.split(separator: "-")
                    let fgm = fgParts.count >= 1 ? Int(fgParts[0]) ?? 0 : 0
                    let fga = fgParts.count >= 2 ? Int(fgParts[1]) ?? 0 : 0

                    let threeStr = strStat("3PT")
                    let threeParts = threeStr.split(separator: "-")
                    let threePM = threeParts.count >= 1 ? Int(threeParts[0]) ?? 0 : 0
                    let threePA = threeParts.count >= 2 ? Int(threeParts[1]) ?? 0 : 0

                    let ftStr = strStat("FT")
                    let ftParts = ftStr.split(separator: "-")
                    let ftm = ftParts.count >= 1 ? Int(ftParts[0]) ?? 0 : 0
                    let fta = ftParts.count >= 2 ? Int(ftParts[1]) ?? 0 : 0

                    let fantasy =
                        Double(pts) * 1.0 +
                        Double(reb) * 1.2 +
                        Double(ast) * 1.5 +
                        Double(stl) * 3.0 +
                        Double(blk) * 3.0 -
                        Double(to) * 1.0

                    let playerID = "wnba-\(athleteID)"
                    let stats = DFSPlayerLiveStats(
                        name: athleteName,
                        points: pts, rebounds: reb, assists: ast,
                        steals: stl, blocks: blk, turnovers: to,
                        minutes: min,
                        fgm: fgm, fga: fga,
                        threePM: threePM, threePA: threePA,
                        ftm: ftm, fta: fta,
                        fantasyPoints: fantasy,
                        gameStatus: gameStatus,
                        gameFinal: gameFinal
                    )
                    results.append((playerID, fantasy, stats))
                }
            }
        }
        return results
    }
}

// MARK: - Private DFS Contests

/// A user-created private contest tied to a public DFS tournament (slate).
/// Friends join by entering the 6-char invite code. No bots — leaderboard
/// contains only real human entries.
struct DFSPrivateContest: Identifiable, Hashable, Codable {
    let id: UUID
    let parentTournamentID: String
    let name: String
    let createdBy: UUID
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date
}

struct DFSPrivateContestMember: Identifiable, Hashable, Codable {
    let id: UUID
    let contestID: UUID
    let userID: UUID
    let displayName: String
    let joinedAt: Date
}

/// A lineup submitted to a private contest. Stored in its own table — entirely
/// separate from public dfs_entries.
struct DFSPrivateContestEntry: Identifiable, Hashable, Codable {
    let id: UUID
    let contestID: UUID
    let userID: UUID
    let displayName: String
    let lineupPlayerIDs: [String]
    let lineupTotalPoints: Double
    let submittedAt: Date
}

/// Computed leaderboard row for a private contest. Built from private entries
/// scored against current live player points.
struct DFSPrivateContestLeaderboardRow: Identifiable, Hashable {
    let id: UUID            // member user_id
    let displayName: String
    let lineupPlayerIDs: [String]
    let points: Double
    let rank: Int
    let isCurrentUser: Bool
    let hasSubmitted: Bool   // false when member joined but hasn't entered a lineup
}

