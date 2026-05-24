import Foundation

// MARK: - Scoring Mode

enum BestBallScoringMode: String, Equatable, Hashable, CaseIterable {
    case normal = "normal"
    case dingersOnly = "dingers_only"

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .dingersOnly: return "Dingers Only"
        }
    }
}

// MARK: - Models

struct BestBallLeague: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    let sport: String
    let season: String
    var status: String
    let draftStartTime: Date?
    var draftOrder: [String]
    var currentPickNumber: Int
    let pickTimerSeconds: Int
    var rosterSize: Int
    let scoringSlots: Int
    var currentWeek: Int
    let totalWeeks: Int
    let createdAt: Date
    var schedule: [[[String]]]    // [week][ [memberA, memberB], ... ]
    let weekStructure: String     // "mon_sun" or "thu_mon"
    var isPrivate: Bool
    let createdBy: String?        // commissioner's user ID
    var maxMembers: Int
    let inviteCode: String?
    var pitcherSlots: Int         // MLB: scoring pitcher count; NBA/NFL: ignored
    var batterSlots: Int          // MLB: scoring batter/UTIL count; NBA/NFL: ignored
    var scoringMode: BestBallScoringMode

    var memberCount: Int { draftOrder.count }
    var isFull: Bool { draftOrder.count >= maxMembers }
    var isDingersOnly: Bool { scoringMode == .dingersOnly }
}

struct BestBallMember: Identifiable, Equatable, Hashable {
    let id: String
    let leagueID: String
    let userID: String?
    let slotIndex: Int
    let displayName: String
    let isBot: Bool
}

struct BestBallPick: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    let pickNumber: Int
    let round: Int
    let playerID: String
    let playerName: String
    let playerTeam: String
    let playerPosition: String
    let pickedAt: Date
}

struct BestBallPlayer: Identifiable, Hashable {
    let id: String
    let name: String
    let team: String
    let position: String
    let projectedPoints: Double
    let sport: String
    let lastSeasonHR: Int
}

struct BestBallWeeklyScore: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    let week: Int
    let totalPoints: Double
    let scoringPlayerIDs: [String]
    let playerPoints: [String: Double]
    let playerStats: [String: [String: Double]]
    let opponentMemberID: String?
    let matchupResult: String?   // "win", "loss", "pending", nil
}

struct BestBallStanding: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    var totalPoints: Double
    var weeksScored: Int
    var rank: Int
    var wins: Int
    var losses: Int
}

// MARK: - H2H Matchup

struct BestBallMatchup: Identifiable, Equatable {
    var id: String { "\(week)-\(member1ID)-\(member2ID)" }
    let week: Int
    let member1ID: String
    let member2ID: String
    var member1Score: Double
    var member2Score: Double
    var winnerID: String?
}

// MARK: - Player Game Stats (full stat line)

struct BestBallPlayerGameStats: Identifiable, Equatable {
    let id: String
    let playerID: String
    let date: Date
    let opponent: String
    let stats: [String: Double]
    let fantasyPoints: Double
    let gameState: String
}

// MARK: - Daily Score

struct BestBallDailyScore: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    let week: Int
    let gameDate: Date
    let playerPoints: [String: Double]
    let playerStats: [String: [String: Double]]
}

// MARK: - Draft State

struct BestBallDraftState: Equatable {
    let league: BestBallLeague
    let members: [BestBallMember]
    let picks: [BestBallPick]
    let availablePlayers: [BestBallPlayer]

    var totalPicks: Int { league.rosterSize * members.count }
    var isDraftComplete: Bool { picks.count >= totalPicks }
    var currentPickNumber: Int { picks.count + 1 }

    var currentRound: Int {
        ((currentPickNumber - 1) / members.count) + 1
    }

    var positionInRound: Int {
        let indexInRound = (currentPickNumber - 1) % members.count
        let isReverse = currentRound % 2 == 0
        return isReverse ? (members.count - 1 - indexInRound) : indexInRound
    }

    var onTheClockMemberID: String? {
        guard !isDraftComplete else { return nil }
        let draftPosition = positionInRound
        // Use the league's shuffled draft order if available, otherwise fall back to slotIndex
        if !league.draftOrder.isEmpty, draftPosition < league.draftOrder.count {
            return league.draftOrder[draftPosition]
        }
        return members.first(where: { $0.slotIndex == draftPosition })?.id
    }

    func roster(for memberID: String) -> [BestBallPick] {
        picks.filter { $0.memberID == memberID }
    }

    func pickedPlayerIDs() -> Set<String> {
        Set(picks.map { $0.playerID })
    }
}

// MARK: - Position Configuration

struct BestBallPositionRequirement {
    let label: String
    let count: Int
    let eligible: Set<String>
}

enum BestBallLineupConfig {
    static func requirements(for sport: String, pitcherSlots: Int = 2, batterSlots: Int = 6, scoringMode: BestBallScoringMode = .normal) -> (starters: Int, constraints: [BestBallPositionRequirement]) {
        switch sport {
        case "NBA":
            // For NBA, total starters = pitcherSlots + batterSlots (reused as generic starters)
            let total = pitcherSlots + batterSlots
            return (total, [
                BestBallPositionRequirement(label: "PG", count: 1, eligible: ["PG"]),
                BestBallPositionRequirement(label: "SG", count: 1, eligible: ["SG"]),
                BestBallPositionRequirement(label: "SF", count: 1, eligible: ["SF"]),
                BestBallPositionRequirement(label: "PF", count: 1, eligible: ["PF"]),
                BestBallPositionRequirement(label: "C",  count: 1, eligible: ["C"]),
                BestBallPositionRequirement(label: "FLEX", count: max(0, total - 5), eligible: ["PG", "SG", "SF", "PF", "C"]),
            ])
        case "MLB":
            if scoringMode == .dingersOnly {
                // Dingers only: all batter slots, no pitchers
                return (batterSlots, [
                    BestBallPositionRequirement(label: "UTIL", count: batterSlots, eligible: ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]),
                ])
            }
            return (pitcherSlots + batterSlots, [
                BestBallPositionRequirement(label: "P",    count: pitcherSlots, eligible: ["SP", "P"]),
                BestBallPositionRequirement(label: "UTIL", count: batterSlots, eligible: ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]),
            ])
        case "NFL":
            return (8, [
                BestBallPositionRequirement(label: "QB",    count: 1, eligible: ["QB"]),
                BestBallPositionRequirement(label: "RB",    count: 2, eligible: ["RB"]),
                BestBallPositionRequirement(label: "WR",    count: 2, eligible: ["WR"]),
                BestBallPositionRequirement(label: "TE",    count: 1, eligible: ["TE"]),
                BestBallPositionRequirement(label: "FLEX",  count: 1, eligible: ["RB", "WR", "TE"]),
                BestBallPositionRequirement(label: "SFLEX", count: 1, eligible: ["QB", "RB", "WR", "TE"]),
            ])
        default:
            return (8, [])
        }
    }

    /// Minimum positions a roster must have by end of draft.
    static func draftMinimums(for sport: String, pitcherSlots: Int = 2, batterSlots: Int = 6) -> [String: Int] {
        switch sport {
        case "NBA": return ["PG": 1, "SG": 1, "SF": 1, "PF": 1, "C": 1]
        case "MLB": return ["SP": pitcherSlots]  // Must fill pitcher starter slots; batters handled by balanced pick logic
        case "NFL": return ["QB": 1, "RB": 2, "WR": 2, "TE": 1]
        default: return [:]
        }
    }

    /// Stat labels to display per sport
    static func statLabels(for sport: String, isPitcher: Bool = false) -> [String] {
        switch sport {
        case "NBA": return ["PTS", "REB", "AST", "STL", "BLK", "TO"]
        case "MLB" where isPitcher: return ["IP", "K", "ER", "W", "SV"]
        case "MLB": return ["H", "AB", "HR", "RBI", "R", "BB", "K", "SB"]
        case "NFL": return ["PYDS", "PTD", "INT", "RYDS", "RTD", "REC", "RECYDS", "RECTD"]
        default: return []
        }
    }

    /// Whether a position string represents a pitcher (RP excluded from best ball drafts).
    static func isPitcher(_ position: String) -> Bool {
        ["SP", "P"].contains(position)
    }

    /// Human-readable scoring formula blurb for a given sport.
    static func scoringDescription(for sport: String, scoringMode: BestBallScoringMode = .normal) -> String {
        switch sport {
        case "NBA":
            return """
            NBA Fantasy Points:
            PTS ×1.0 · REB ×1.2 · AST ×1.5 · STL ×3.0 · BLK ×3.0 · TO ×−1.0
            """
        case "MLB" where scoringMode == .dingersOnly:
            return """
            Dingers Only:
            Each batter's score = raw HR count
            Season standings = total HRs across all weeks
            No W-L matchups — pure HR leaderboard
            """
        case "MLB":
            return """
            MLB Batter Points:
            1B ×3 · 2B ×5 · 3B ×8 · HR ×10 · RBI ×2 · R ×2 · BB ×2 · SB ×5 · K ×−0.5

            MLB Pitcher Points:
            IP ×3 · K ×2 · W ×5 · ER ×−2 · SV ×5
            """
        case "NFL":
            return """
            NFL Fantasy Points:
            Pass YDS ×0.04 · Pass TD ×4 · INT ×−1
            Rush YDS ×0.1 · Rush TD ×6
            REC ×1 · Rec YDS ×0.1 · Rec TD ×6 · FUM ×−2
            """
        default:
            return ""
        }
    }
}

// MARK: - Schedule Generator

enum BestBallScheduleGenerator {
    /// Round-robin schedule for 12 teams. Returns [week][ [memberA, memberB], ... ]
    static func generateSchedule(memberIDs: [String], totalWeeks: Int) -> [[[String]]] {
        let n = memberIDs.count
        guard n >= 2, n % 2 == 0 else { return [] }

        var ids = memberIDs
        var rounds: [[[String]]] = []

        // Circle method: fix first element, rotate the rest
        for _ in 0..<(n - 1) {
            var weekMatchups: [[String]] = []
            for i in 0..<(n / 2) {
                weekMatchups.append([ids[i], ids[n - 1 - i]])
            }
            rounds.append(weekMatchups)
            // Rotate: keep first, shift rest
            let last = ids.removeLast()
            ids.insert(last, at: 1)
        }

        // Extend to totalWeeks by repeating the cycle
        var schedule: [[[String]]] = []
        for w in 0..<totalWeeks {
            schedule.append(rounds[w % rounds.count])
        }
        return schedule
    }
}

// MARK: - Scoring Engine

enum BestBallScoringEngine {
    /// Position-constrained best-ball optimizer.
    /// Enumerates C(N, starters) combos — for 12-choose-8 = 495, trivially fast.
    static func bestBallScore(
        playerPoints: [String: Double],
        playerPositions: [String: String],
        sport: String,
        scoringSlots: Int,
        pitcherSlots: Int = 2,
        batterSlots: Int = 6,
        scoringMode: BestBallScoringMode = .normal
    ) -> (total: Double, scoringIDs: [String]) {
        let (starters, constraints) = BestBallLineupConfig.requirements(for: sport, pitcherSlots: pitcherSlots, batterSlots: batterSlots, scoringMode: scoringMode)
        let candidates = playerPoints.sorted { $0.value > $1.value }

        guard !constraints.isEmpty, candidates.count >= starters else {
            // Fallback: top-N by points
            let topN = Array(candidates.prefix(scoringSlots))
            return (topN.reduce(0.0) { $0 + $1.value }, topN.map { $0.key })
        }

        let playerIDs = candidates.map { $0.key }
        let count = min(starters, playerIDs.count)
        var bestTotal = -Double.infinity
        var bestLineup: [String] = []

        for combo in combinations(of: Array(0..<playerIDs.count), choose: count) {
            let lineup = combo.map { playerIDs[$0] }
            if satisfiesConstraints(lineup: lineup, positions: playerPositions, constraints: constraints) {
                let total = lineup.reduce(0.0) { $0 + (playerPoints[$1] ?? 0) }
                if total > bestTotal {
                    bestTotal = total
                    bestLineup = lineup
                }
            }
        }

        if bestLineup.isEmpty {
            let topN = Array(candidates.prefix(scoringSlots))
            return (topN.reduce(0.0) { $0 + $1.value }, topN.map { $0.key })
        }
        return (bestTotal, bestLineup)
    }

    private static func combinations(of elements: [Int], choose k: Int) -> [[Int]] {
        guard k > 0, k <= elements.count else { return k == 0 ? [[]] : [] }
        if k == elements.count { return [elements] }

        var result: [[Int]] = []
        func build(_ start: Int, _ current: [Int]) {
            if current.count == k {
                result.append(current)
                return
            }
            let remaining = k - current.count
            for i in start...(elements.count - remaining) {
                build(i + 1, current + [elements[i]])
            }
        }
        build(0, [])
        return result
    }

    private static func satisfiesConstraints(
        lineup: [String],
        positions: [String: String],
        constraints: [BestBallPositionRequirement]
    ) -> Bool {
        var assigned = Set<String>()
        for constraint in constraints {
            var filled = 0
            for playerID in lineup where !assigned.contains(playerID) {
                if let pos = positions[playerID], constraint.eligible.contains(pos) {
                    filled += 1
                    assigned.insert(playerID)
                    if filled >= constraint.count { break }
                }
            }
            if filled < constraint.count { return false }
        }
        return true
    }

    /// Compute standings sorted by wins first, then total points as tiebreaker.
    /// For dingers-only mode, sorts purely by total HRs (stored in totalPoints).
    static func computeStandings(
        weeklyScores: [BestBallWeeklyScore],
        members: [BestBallMember],
        scoringMode: BestBallScoringMode = .normal
    ) -> [BestBallStanding] {
        var pointsByMember: [String: Double] = [:]
        var weeksByMember: [String: Int] = [:]
        var winsByMember: [String: Int] = [:]
        var lossesByMember: [String: Int] = [:]

        for score in weeklyScores {
            pointsByMember[score.memberID, default: 0] += score.totalPoints
            weeksByMember[score.memberID, default: 0] += 1
            if scoringMode == .normal {
                if score.matchupResult == "win" {
                    winsByMember[score.memberID, default: 0] += 1
                } else if score.matchupResult == "loss" {
                    lossesByMember[score.memberID, default: 0] += 1
                }
            }
        }

        let sorted: [BestBallMember]
        if scoringMode == .dingersOnly {
            // Dingers only: sort purely by total HRs
            sorted = members.sorted {
                (pointsByMember[$0.id] ?? 0) > (pointsByMember[$1.id] ?? 0)
            }
        } else {
            // Normal: sort by wins first, then total points
            sorted = members.sorted {
                let w0 = winsByMember[$0.id] ?? 0
                let w1 = winsByMember[$1.id] ?? 0
                if w0 != w1 { return w0 > w1 }
                return (pointsByMember[$0.id] ?? 0) > (pointsByMember[$1.id] ?? 0)
            }
        }

        return sorted.enumerated().map { index, member in
            BestBallStanding(
                id: member.id,
                leagueID: member.leagueID,
                memberID: member.id,
                totalPoints: pointsByMember[member.id] ?? 0,
                weeksScored: weeksByMember[member.id] ?? 0,
                rank: index + 1,
                wins: winsByMember[member.id] ?? 0,
                losses: lossesByMember[member.id] ?? 0
            )
        }
    }

    // MARK: - Fantasy Points Formulas

    nonisolated static func nbaFantasyPoints(pts: Int, reb: Int, ast: Int, stl: Int, blk: Int, tov: Int) -> Double {
        Double(pts) * 1.0 + Double(reb) * 1.2 + Double(ast) * 1.5 + Double(stl) * 3.0 + Double(blk) * 3.0 - Double(tov) * 1.0
    }

    nonisolated static func mlbHitterPoints(singles: Int, doubles: Int, triples: Int, hr: Int, rbi: Int, runs: Int, bb: Int, sb: Int, k: Int) -> Double {
        Double(singles) * 3 + Double(doubles) * 5 + Double(triples) * 8 + Double(hr) * 10 +
        Double(rbi) * 2 + Double(runs) * 2 + Double(bb) * 2 + Double(sb) * 5 - Double(k) * 0.5
    }

    nonisolated static func mlbPitcherPoints(ip: Double, k: Int, w: Int, er: Int, sv: Int) -> Double {
        ip * 3 + Double(k) * 2 + Double(w) * 5 - Double(er) * 2 + Double(sv) * 5
    }

    nonisolated static func nflFantasyPoints(
        passYds: Int, passTD: Int, interceptions: Int,
        rushYds: Int, rushTD: Int,
        recYds: Int, receptions: Int, recTD: Int,
        fumblesLost: Int
    ) -> Double {
        Double(passYds) * 0.04 + Double(passTD) * 4 - Double(interceptions) * 1 +
        Double(rushYds) * 0.1 + Double(rushTD) * 6 +
        Double(recYds) * 0.1 + Double(receptions) * 1 + Double(recTD) * 6 -
        Double(fumblesLost) * 2
    }
}

// MARK: - Bot Drafter

enum BestBallBotDrafter {
    private static let botNames = [
        "Bot Alpha", "Bot Bravo", "Bot Charlie", "Bot Delta",
        "Bot Echo", "Bot Foxtrot", "Bot Golf", "Bot Hotel",
        "Bot India", "Bot Juliet", "Bot Kilo", "Bot Lima"
    ]

    static func botName(at index: Int) -> String {
        botNames[index % botNames.count]
    }

    static func pickForBot(
        available: [BestBallPlayer],
        existingRoster: [BestBallPick],
        sport: String,
        rosterSize: Int,
        scoringMode: BestBallScoringMode = .normal,
        pitcherSlots: Int = 2,
        batterSlots: Int = 6
    ) -> BestBallPlayer? {
        // Filter out pitchers for dingers-only leagues
        var candidates = available
        if sport == "MLB" && scoringMode == .dingersOnly {
            candidates = candidates.filter { !BestBallLineupConfig.isPitcher($0.position) }
        }

        let minimums = BestBallLineupConfig.draftMinimums(for: sport, pitcherSlots: pitcherSlots, batterSlots: batterSlots)
        let pickedPositions = Dictionary(grouping: existingRoster, by: \.playerPosition)
            .mapValues { $0.count }
        let remainingPicks = rosterSize - existingRoster.count

        // Determine which minimums are NOT yet met
        var neededPositions: [String] = []
        for (pos, minCount) in minimums {
            let have = pickedPositions[pos] ?? 0
            if have < minCount {
                for _ in 0..<(minCount - have) {
                    neededPositions.append(pos)
                }
            }
        }

        let sorted: [BestBallPlayer]
        if scoringMode == .dingersOnly {
            sorted = candidates.sorted { $0.lastSeasonHR > $1.lastSeasonHR }
        } else {
            sorted = candidates.sorted { $0.projectedPoints > $1.projectedPoints }
        }

        // For MLB: fill starter slots (SP + batters) before allowing bench pitchers
        if sport == "MLB" && scoringMode != .dingersOnly {
            let spCount = (pickedPositions["SP"] ?? 0) + (pickedPositions["P"] ?? 0)
            let batterCount = existingRoster.filter { !BestBallLineupConfig.isPitcher($0.playerPosition) }.count
            let starterSlots = pitcherSlots + batterSlots

            // Priority 1: If we still need SP starters, pick the best SP
            if spCount < pitcherSlots {
                if let bestSP = sorted.first(where: { BestBallLineupConfig.isPitcher($0.position) }) {
                    return bestSP
                }
            }

            // Priority 2: If we still need batters to fill starter slots, pick batters only
            if batterCount < batterSlots {
                if let bestBatter = sorted.first(where: { !BestBallLineupConfig.isPitcher($0.position) }) {
                    return bestBatter
                }
            }

            // Priority 3: Once starters are filled, fill bench with best available (balanced)
            if existingRoster.count >= starterSlots {
                if let balanced = sorted.first(where: { (pickedPositions[$0.position] ?? 0) < 3 }) {
                    return balanced
                }
                return sorted.first
            }
        }

        // If we're running out of picks, force-fill needed positions
        if neededPositions.count >= remainingPicks, let mustFillPos = neededPositions.first {
            if let forced = sorted.first(where: { $0.position == mustFillPos }) {
                return forced
            }
        }

        // Prefer balanced approach: underrepresented positions (< 3)
        if let balanced = sorted.first(where: { (pickedPositions[$0.position] ?? 0) < 3 }) {
            return balanced
        }
        return sorted.first
    }
}

// MARK: - Protocols

protocol BestBallPlayerProvider {
    func fetchPlayers(sport: String) async throws -> [BestBallPlayer]
}

/// Result from weekly scoring with full stat lines
struct BestBallWeeklyStatsResult {
    let playerPoints: [String: Double]
    let playerStats: [String: [String: Double]]
    let dailyBreakdown: [String: [String: Double]]  // "YYYYMMDD" -> { playerID: points }
    let dailyStats: [String: [String: [String: Double]]]  // "YYYYMMDD" -> { playerID: { stat: val } }
}

protocol BestBallWeeklyScoringProvider {
    func fetchWeeklyPoints(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> [String: Double]
    func fetchWeeklyPointsWithStats(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> BestBallWeeklyStatsResult
    /// Bulk fetch: fetches all ESPN data for a week once and returns stats for ALL players found.
    /// Much faster than calling fetchWeeklyPointsWithStats per member since HTTP requests are shared.
    func fetchWeeklyAllPlayerStats(sport: String, weekStartDate: Date, weekEndDate: Date) async throws -> BestBallWeeklyStatsResult
    /// Lightweight fetch: returns season HR count for each player via ESPN athlete stats endpoint.
    /// Much cheaper than fetching full box scores for every game of the season.
    func fetchSeasonHRCounts(playerIDs: [String]) async -> [String: Int]
}

// MARK: - ESPN Best Ball Player Provider

/// Simple reference-type cache for player projection data
private class BBProjectionCache {
    /// Team-level performance ratings: [teamID: [espnAthleteID: 0-1 rating]]
    var teamRatings: [String: [String: Double]] = [:]
    /// League-wide fantasy point projections from leaders endpoint: [espnAthleteID: projectedPoints]
    var leagueProjections: [String: Double] = [:]
    /// Last season HR counts from ESPN leaders: [espnAthleteID: hrCount]
    var leagueHRCounts: [String: Int] = [:]
    /// Whether league-wide projections have been fetched for a given sport key
    var leagueProjectionsFetched: Set<String> = []
}

struct ESPNBestBallPlayerProvider: BestBallPlayerProvider {
    private let session: URLSession
    private let cache = BBProjectionCache()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchPlayers(sport: String) async throws -> [BestBallPlayer] {
        switch sport {
        case "NBA": return try await fetchSportPlayers(sport: "basketball", league: "nba", sportName: "NBA", teamLimit: 30)
        case "MLB": return try await fetchSportPlayers(sport: "baseball", league: "mlb", sportName: "MLB", teamLimit: 30)
        case "NFL": return try await fetchSportPlayers(sport: "football", league: "nfl", sportName: "NFL", teamLimit: 32)
        default: return []
        }
    }

    private func fetchSportPlayers(sport: String, league: String, sportName: String, teamLimit: Int) async throws -> [BestBallPlayer] {
        // Step 1: Fetch league-wide leader stats to get real projections for top players
        try await fetchLeagueWideProjections(sport: sport, league: league, sportName: sportName)

        let teams = try await fetchAllTeams(sport: sport, league: league)
        var players: [BestBallPlayer] = []
        for team in teams.prefix(teamLimit) {
            // Pre-fetch per-team performance ratings (used as fallback for non-leaders)
            let ratings = try await fetchTeamPerformanceRatings(sport: sport, league: league, teamID: team.id)
            let roster = try await fetchRoster(sport: sport, league: league, teamID: team.id, teamAbbr: team.abbreviation, sportName: sportName, ratings: ratings)
            players.append(contentsOf: roster)
        }
        return deduplicatePlayers(players).sorted { $0.projectedPoints > $1.projectedPoints }
    }

    private func fetchAllTeams(sport: String, league: String) async throws -> [BBTeamRef] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/teams?limit=50") else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teamsList = json["sports"] as? [[String: Any]],
              let sportObj = teamsList.first,
              let leagues = sportObj["leagues"] as? [[String: Any]],
              let leagueObj = leagues.first,
              let teams = leagueObj["teams"] as? [[String: Any]] else { return [] }

        return teams.compactMap { wrapper in
            guard let team = wrapper["team"] as? [String: Any],
                  let id = team["id"] as? String ?? (team["id"] as? Int).map({ String($0) }),
                  let abbr = team["abbreviation"] as? String else { return nil }
            return BBTeamRef(id: id, abbreviation: abbr)
        }
    }

    private func fetchRoster(sport: String, league: String, teamID: String, teamAbbr: String, sportName: String, ratings: [String: Double]) async throws -> [BestBallPlayer] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/teams/\(teamID)/roster") else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let athletes = json["athletes"] as? [[String: Any]] else { return [] }

        var players: [BestBallPlayer] = []
        let flatAthletes: [[String: Any]]
        if let firstGroup = athletes.first, firstGroup["items"] != nil {
            flatAthletes = athletes.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
        } else {
            flatAthletes = athletes
        }

        for athlete in flatAthletes {
            guard let id = athlete["id"] as? String ?? (athlete["id"] as? Int).map({ String($0) }),
                  let fullName = athlete["fullName"] as? String ?? athlete["displayName"] as? String else { continue }
            let positionAbbr: String
            if let pos = athlete["position"] as? [String: Any] {
                positionAbbr = pos["abbreviation"] as? String ?? "UTIL"
            } else {
                positionAbbr = "UTIL"
            }

            // Skip relief pitchers for MLB — they aren't useful in best ball
            if sportName == "MLB" && positionAbbr == "RP" { continue }

            let projection: Double
            if let leagueProj = cache.leagueProjections[id] {
                // Use real stat-based projection from league-wide leaders
                projection = leagueProj
            } else {
                // Fallback: use team-level rating scaled to a lower range (these are non-elite players)
                let rating = ratings[id] ?? 0.0
                projection = fallbackProjection(rating: rating, sport: sportName, position: positionAbbr, playerID: id)
            }

            let hrCount = cache.leagueHRCounts[id] ?? 0

            players.append(BestBallPlayer(
                id: "\(sportName.lowercased())-\(id)",
                name: fullName, team: teamAbbr,
                position: positionAbbr, projectedPoints: projection,
                sport: sportName, lastSeasonHR: hrCount
            ))
        }
        return players
    }

    // MARK: - League-Wide Projections from ESPN Leaders

    /// Fetches league-wide stat leaders and computes season-long fantasy point projections.
    /// Uses the ESPN core API leaders endpoint which returns top ~50 players per stat category
    /// with full season stat lines in the displayValue field.
    private func fetchLeagueWideProjections(sport: String, league: String, sportName: String) async throws {
        let cacheKey = "\(sport)-\(league)"
        guard !cache.leagueProjectionsFetched.contains(cacheKey) else { return }
        cache.leagueProjectionsFetched.insert(cacheKey)

        let primarySeason = espnSeasonYear(for: sportName)
        let fallbackSeason = primarySeason - 1

        // For MLB, fetch BOTH current and previous season leaders to maximize player coverage.
        // Early in the season, current-year data is sparse — previous season provides a baseline.
        if sportName == "MLB" {
            await fetchPreviousSeasonHRs(sport: sport, league: league, sportName: sportName)

            // Fetch previous season first as baseline
            if let prevData = await fetchLeadersData(sport: sport, league: league, season: fallbackSeason) {
                parseMLBLeaders(data: prevData, sportName: sportName)
            }

            // Then overlay current season (overwrites previous season projections where available)
            if let currentData = await fetchLeadersData(sport: sport, league: league, season: primarySeason) {
                // Clear previous-season projections for players who have current data
                let prevProjections = cache.leagueProjections
                parseMLBLeaders(data: currentData, sportName: sportName)
                // For players only in previous season (not in current leaders), keep their projection
                for (id, proj) in prevProjections where cache.leagueProjections[id] == nil {
                    cache.leagueProjections[id] = proj
                }
            }
            return
        }

        // Non-MLB: try current season first, fall back to previous year
        var fetchedData: Data?
        for season in [primarySeason, fallbackSeason] {
            if let data = await fetchLeadersData(sport: sport, league: league, season: season) {
                fetchedData = data
                break
            }
        }

        guard let data = fetchedData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = json["categories"] as? [[String: Any]] else { return }

        if sportName == "NBA" {
            parseNBALeaders(categories: categories)
        } else {
            for category in categories {
                let categoryName = category["name"] as? String ?? ""
                guard let leaders = category["leaders"] as? [[String: Any]] else { continue }
                for leader in leaders {
                    guard let athleteRef = leader["athlete"] as? [String: Any],
                          let refURL = athleteRef["$ref"] as? String,
                          let displayValue = leader["displayValue"] as? String else { continue }

                    let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                    guard let athleteID = pathParts.last.map(String.init) else { continue }

                    guard cache.leagueProjections[athleteID] == nil else { continue }

                    let fpts = computeSeasonProjection(sport: sportName, statLine: displayValue, category: categoryName)
                    if fpts > 0 {
                        cache.leagueProjections[athleteID] = fpts
                    }
                }
            }
        }
    }

    /// Fetch leaders data for a given season; returns nil if unavailable.
    private func fetchLeadersData(sport: String, league: String, season: Int) async -> Data? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/\(sport)/leagues/\(league)/seasons/\(season)/types/2/leaders?limit=100") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    /// Parse MLB leaders from raw data, computing projections and HR counts.
    private func parseMLBLeaders(data: Data, sportName: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = json["categories"] as? [[String: Any]] else { return }

        for category in categories {
            let categoryName = category["name"] as? String ?? ""
            guard let leaders = category["leaders"] as? [[String: Any]] else { continue }
            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String else { continue }

                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }

                // Overwrite any existing projection (current season takes priority)
                let fpts = computeSeasonProjection(sport: sportName, statLine: displayValue, category: categoryName)
                if fpts > 0 {
                    cache.leagueProjections[athleteID] = fpts
                }

                // Extract HR count for MLB batters
                if !displayValue.contains(" IP") {
                    let hrCount = extractHRCount(from: displayValue)
                    if hrCount > 0 {
                        cache.leagueHRCounts[athleteID] = max(cache.leagueHRCounts[athleteID] ?? 0, hrCount)
                    }
                }
            }
        }
    }

    /// Fetch previous season's HR leaders for MLB to populate lastSeasonHR.
    /// The current season may have just started with very few games, so we specifically
    /// fetch last year's full-season HR data.
    private func fetchPreviousSeasonHRs(sport: String, league: String, sportName: String) async {
        guard sportName == "MLB" else { return }
        let prevSeason = espnSeasonYear(for: sportName) - 1
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/\(sport)/leagues/\(league)/seasons/\(prevSeason)/types/2/leaders?limit=100") else { return }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = json["categories"] as? [[String: Any]] else { return }

        for category in categories {
            guard let leaders = category["leaders"] as? [[String: Any]] else { continue }
            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String,
                      !displayValue.contains(" IP") else { continue }

                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }

                let hrCount = extractHRCount(from: displayValue)
                if hrCount > 0 {
                    // Use max of current and previous season (in case current season already has data)
                    cache.leagueHRCounts[athleteID] = max(cache.leagueHRCounts[athleteID] ?? 0, hrCount)
                }
            }
        }
    }

    /// Accumulate NBA per-game stats across categories and compute full fantasy projection.
    /// NBA scoring: PTS×1.0 + REB×1.2 + AST×1.5 + STL×3.0 + BLK×3.0 + TO×−1.0
    private func parseNBALeaders(categories: [[String: Any]]) {
        // Collect per-player stats from relevant categories
        var playerStats: [String: [String: Double]] = [:]  // athleteID -> { "ppg": 30.2, "rpg": 10.1, ... }

        let relevantCategories: Set<String> = ["pointsPerGame", "reboundsPerGame", "assistsPerGame", "stealsPerGame", "blocksPerGame", "avgTurnovers"]

        for category in categories {
            let catName = category["name"] as? String ?? ""
            guard relevantCategories.contains(catName),
                  let leaders = category["leaders"] as? [[String: Any]] else { continue }

            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String,
                      let value = Double(displayValue.trimmingCharacters(in: .whitespaces)) else { continue }

                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }

                if playerStats[athleteID] == nil { playerStats[athleteID] = [:] }
                playerStats[athleteID]?[catName] = value
            }
        }

        // Compute full fantasy projection for each player
        for (athleteID, stats) in playerStats {
            let ppg = stats["pointsPerGame"] ?? 0
            let rpg = stats["reboundsPerGame"] ?? 0
            let apg = stats["assistsPerGame"] ?? 0
            let spg = stats["stealsPerGame"] ?? 0
            let bpg = stats["blocksPerGame"] ?? 0
            let tpg = stats["avgTurnovers"] ?? 0

            // NBA fantasy formula per game
            let fptsPerGame = ppg * 1.0 + rpg * 1.2 + apg * 1.5 + spg * 3.0 + bpg * 3.0 - tpg * 1.0

            // Convert to weekly: ~3.5 games/week
            let weeklyFPTS = fptsPerGame * 3.5

            // Only store if we have at least PPG (the primary stat)
            if ppg > 0 && weeklyFPTS > 0 {
                cache.leagueProjections[athleteID] = weeklyFPTS
            }
        }
    }

    /// Parse a season stat line string from ESPN leaders and compute weekly fantasy points.
    /// Called for MLB and NFL only — NBA is handled by parseNBALeaders().
    private func computeSeasonProjection(sport: String, statLine: String, category: String) -> Double {
        switch sport {
        case "MLB":
            // Pitcher categories have displayValue like "187.2 IP, 41 ER, ..."
            // Batter categories have displayValue like "179-541, 53 HR, ..."
            if statLine.contains(" IP") {
                return parseMLBPitcherProjection(statLine)
            } else {
                return parseMLBSeasonProjection(statLine)
            }
        case "NFL": return parseNFLSeasonProjection(statLine)
        default: return 0
        }
    }

    /// Parse MLB batter stat line: "H-AB, 53 HR, 3B, 30 2B, 114 RBI, 137 R, 124 BB, 12 SB, 160 K"
    /// Note: bare stat labels like "3B" (no number) mean a count of 1.
    /// Compute weekly projected fantasy points from season totals.
    private func parseMLBSeasonProjection(_ statLine: String) -> Double {
        let parts = statLine.components(separatedBy: ", ")
        guard parts.count >= 2 else { return 0 }

        var h = 0, ab = 0, hr = 0, triples = 0, doubles = 0, rbi = 0, runs = 0, bb = 0, sb = 0, k = 0

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-") && !trimmed.contains(" ") {
                // H-AB format (e.g. "179-541")
                let hAb = trimmed.split(separator: "-")
                if hAb.count == 2 {
                    h = Int(hAb[0]) ?? 0
                    ab = Int(hAb[1]) ?? 0
                }
            } else if trimmed == "HR" {
                hr = 1
            } else if trimmed.hasSuffix(" HR") {
                hr = Int(trimmed.replacingOccurrences(of: " HR", with: "")) ?? 0
            } else if trimmed == "3B" {
                triples = 1
            } else if trimmed.hasSuffix(" 3B") {
                triples = Int(trimmed.replacingOccurrences(of: " 3B", with: "")) ?? 0
            } else if trimmed == "2B" {
                doubles = 1
            } else if trimmed.hasSuffix(" 2B") {
                doubles = Int(trimmed.replacingOccurrences(of: " 2B", with: "")) ?? 0
            } else if trimmed == "RBI" {
                rbi = 1
            } else if trimmed.hasSuffix(" RBI") {
                rbi = Int(trimmed.replacingOccurrences(of: " RBI", with: "")) ?? 0
            } else if trimmed == "R" {
                runs = 1
            } else if trimmed.hasSuffix(" R") {
                runs = Int(trimmed.replacingOccurrences(of: " R", with: "")) ?? 0
            } else if trimmed == "BB" {
                bb = 1
            } else if trimmed.hasSuffix(" BB") {
                bb = Int(trimmed.replacingOccurrences(of: " BB", with: "")) ?? 0
            } else if trimmed == "SB" {
                sb = 1
            } else if trimmed.hasSuffix(" SB") {
                sb = Int(trimmed.replacingOccurrences(of: " SB", with: "")) ?? 0
            } else if trimmed == "K" {
                k = 1
            } else if trimmed.hasSuffix(" K") {
                k = Int(trimmed.replacingOccurrences(of: " K", with: "")) ?? 0
            }
        }

        // If we couldn't parse H-AB, this might be a pitcher or other format — skip
        guard ab > 0 || h > 0 || hr > 0 else { return 0 }

        // Require minimum 200 AB for reliable rate stats — below this, small-sample
        // specialists (pinch runners, etc.) get inflated per-game projections
        guard ab >= 200 else { return 0 }

        let singles = max(0, h - doubles - triples - hr)
        let seasonTotal = BestBallScoringEngine.mlbHitterPoints(
            singles: singles, doubles: doubles, triples: triples, hr: hr,
            rbi: rbi, runs: runs, bb: bb, sb: sb, k: k
        )

        // Convert season total to per-week projection
        // Assume ~3.8 AB per game, ~6 games per week in best ball
        let gamesPlayed = max(1.0, Double(ab) / 3.8)
        let pointsPerGame = seasonTotal / gamesPlayed
        return pointsPerGame * 6.0  // 6 games/week for MLB
    }

    /// Extract raw HR count from an MLB batter stat line.
    private func extractHRCount(from statLine: String) -> Int {
        for part in statLine.components(separatedBy: ", ") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed == "HR" { return 1 }
            if trimmed.hasSuffix(" HR") {
                return Int(trimmed.replacingOccurrences(of: " HR", with: "")) ?? 0
            }
        }
        return 0
    }

    /// Parse MLB pitcher stat line: "187.2 IP, 41 ER, 136 H, 216 K, 42 BB"
    /// Compute weekly projected fantasy points from season totals.
    private func parseMLBPitcherProjection(_ statLine: String) -> Double {
        let parts = statLine.components(separatedBy: ", ")
        guard parts.count >= 2 else { return 0 }

        var ip = 0.0, er = 0, k = 0

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(" IP") {
                // IP can be fractional like "187.2" — the .2 means 2/3 of an inning
                let ipStr = trimmed.replacingOccurrences(of: " IP", with: "")
                ip = Double(ipStr) ?? 0
            } else if trimmed.hasSuffix(" ER") {
                er = Int(trimmed.replacingOccurrences(of: " ER", with: "")) ?? 0
            } else if trimmed.hasSuffix(" K") {
                k = Int(trimmed.replacingOccurrences(of: " K", with: "")) ?? 0
            } else if trimmed == "K" {
                k = 1
            }
        }

        // Require minimum 30 IP for reliable projections
        guard ip >= 30 else { return 0 }

        // Compute season total without W/SV (not available in displayValue)
        // IP×3 + K×2 − ER×2 covers the primary pitcher value
        let seasonTotal = BestBallScoringEngine.mlbPitcherPoints(ip: ip, k: k, w: 0, er: er, sv: 0)

        // Convert season total to per-week: ~26 weeks in MLB season
        return seasonTotal / 26.0
    }



    /// Parse NFL leader displayValue (season total stat).
    private func parseNFLSeasonProjection(_ statLine: String) -> Double {
        guard let value = Double(statLine.trimmingCharacters(in: .whitespaces)) else { return 0 }
        // NFL season totals: convert to per-game (17 games), 1 game/week
        return value / 17.0
    }

    /// Determine the ESPN season year for the current sport.
    private func espnSeasonYear(for sport: String) -> Int {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: Date())
        switch sport {
        case "NBA":
            return month >= 7 ? year + 1 : year
        case "NFL":
            return month >= 7 ? year : year - 1
        case "MLB":
            return month >= 3 ? year : year - 1
        default:
            return year
        }
    }

    // MARK: - Per-Team Performance Ratings (fallback for non-leaders)

    /// Fetches per-team stat leaders from ESPN and computes a 0-1 performance rating for each athlete.
    /// Used as fallback for players who don't appear in league-wide leaders.
    private func fetchTeamPerformanceRatings(sport: String, league: String, teamID: String) async throws -> [String: Double] {
        if let cached = cache.teamRatings[teamID] { return cached }

        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/teams/\(teamID)/athletes/statistics") else { return [:] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [:] }

        var rawScores: [String: Double] = [:]
        for result in results {
            guard let leaders = result["leaders"] as? [[String: Any]] else { continue }
            for (index, leader) in leaders.enumerated() {
                guard let athlete = leader["athlete"] as? [String: Any],
                      let athleteID = athlete["id"] as? String ?? (athlete["id"] as? Int).map({ String($0) }) else { continue }
                let placementWeight = max(1.0, 20.0 - Double(index))
                rawScores[athleteID, default: 0.0] += placementWeight
            }
        }

        guard let maxScore = rawScores.values.max(), maxScore > 0 else {
            cache.teamRatings[teamID] = [:]
            return [:]
        }
        let normalized = rawScores.mapValues { $0 / maxScore }
        cache.teamRatings[teamID] = normalized
        return normalized
    }

    /// Fallback projection for players not in league-wide leaders.
    /// These are role players / bench players — projected lower than the leaders.
    private func fallbackProjection(rating: Double, sport: String, position: String, playerID: String) -> Double {
        let clamped = max(0.0, min(1.0, rating))
        // Small stable jitter so identical ratings don't produce identical projections
        let seed = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = Double(abs(seed % 100)) / 500.0

        // These ranges represent non-elite players — below the leaders threshold.
        // The ceiling is set near the bottom of what league leaders typically produce.
        let floor: Double
        let ceiling: Double

        switch sport {
        case "NBA":
            // Non-leaders: role players below the top ~100
            // Leaders bottom out around 50-60 weekly, so cap fallback below that
            floor = 15.0; ceiling = 50.0
        case "MLB":
            // Non-leaders: low-end regulars and bench bats
            // Leader batters bottom out ~31, so cap fallback below that
            floor = 2.0; ceiling = 30.0
        case "NFL":
            // Non-leaders: low-tier starters / backups
            floor = 2.0; ceiling = 10.0
        default:
            floor = 2.0; ceiling = 15.0
        }

        return floor + clamped * (ceiling - floor) + jitter
    }

    private func deduplicatePlayers(_ players: [BestBallPlayer]) -> [BestBallPlayer] {
        var seen = Set<String>()
        return players.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - ESPN Weekly Scoring Provider (with stat lines)

struct ESPNBestBallWeeklyScoringProvider: BestBallWeeklyScoringProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // Legacy simple version
    func fetchWeeklyPoints(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> [String: Double] {
        let result = try await fetchWeeklyPointsWithStats(sport: sport, playerIDs: playerIDs, weekStartDate: weekStartDate, weekEndDate: weekEndDate)
        return result.playerPoints
    }

    // Full version with stat lines and daily breakdown
    func fetchWeeklyPointsWithStats(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> BestBallWeeklyStatsResult {
        guard !playerIDs.isEmpty else {
            return BestBallWeeklyStatsResult(playerPoints: [:], playerStats: [:], dailyBreakdown: [:], dailyStats: [:])
        }

        let (sportPath, leaguePath) = espnPaths(for: sport)
        guard !sportPath.isEmpty else {
            return BestBallWeeklyStatsResult(playerPoints: [:], playerStats: [:], dailyBreakdown: [:], dailyStats: [:])
        }

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = calendar

        // Collect game IDs per date
        var gamesByDate: [String: [String]] = [:]  // dateKey -> [gameID]
        var date = weekStartDate
        while date <= weekEndDate {
            let dateKey = formatter.string(from: date)
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/scoreboard?dates=\(dateKey)") else {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
                continue
            }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
                continue
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let events = json["events"] as? [[String: Any]] {
                for event in events {
                    if let comp = (event["competitions"] as? [[String: Any]])?.first,
                       let status = (comp["status"] as? [String: Any])?["type"] as? [String: Any],
                       let state = status["state"] as? String,
                       (state == "post" || state == "in"),
                       let eventID = event["id"] as? String {
                        gamesByDate[dateKey, default: []].append(eventID)
                    }
                }
            }
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
        }

        let playerIDSet = Set(playerIDs)
        let prefix = sport.lowercased() + "-"
        var totalPoints: [String: Double] = [:]
        var totalStats: [String: [String: Double]] = [:]
        var dailyBreakdown: [String: [String: Double]] = [:]  // dateKey -> {fullID: pts}
        var dailyStats: [String: [String: [String: Double]]] = [:]  // dateKey -> {fullID: {stat: val}}

        for (dateKey, gameIDs) in gamesByDate {
            for gameID in gameIDs {
                guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/summary?event=\(gameID)") else { continue }
                guard let (data, response) = try? await session.data(from: url),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let boxscore = json["boxscore"] as? [String: Any],
                      let playerGroups = boxscore["players"] as? [[String: Any]] else { continue }

                for group in playerGroups {
                    guard let statistics = group["statistics"] as? [[String: Any]] else { continue }
                    for stat in statistics {
                        guard let labels = stat["labels"] as? [String],
                              let athletes = stat["athletes"] as? [[String: Any]] else { continue }
                        for athlete in athletes {
                            guard let athleteInfo = athlete["athlete"] as? [String: Any],
                                  let athleteID = athleteInfo["id"] as? String ?? (athleteInfo["id"] as? Int).map({ String($0) }) else { continue }
                            let fullID = prefix + athleteID
                            guard playerIDSet.contains(fullID) else { continue }
                            guard let stats = athlete["stats"] as? [String] else { continue }

                            // Build stat lookup
                            var lookup: [String: Double] = [:]
                            for (i, label) in labels.enumerated() where i < stats.count {
                                lookup[label] = Double(stats[i]) ?? 0
                            }

                            let fpts = Self.computeFantasyPoints(sport: sport, labels: labels, stats: stats)
                            totalPoints[fullID, default: 0] += fpts

                            // Merge stat lines (accumulate across games)
                            for (key, val) in lookup {
                                totalStats[fullID, default: [:]][key, default: 0] += val
                            }

                            // Daily breakdown
                            dailyBreakdown[dateKey, default: [:]][fullID, default: 0] += fpts
                            for (key, val) in lookup {
                                dailyStats[dateKey, default: [:]][fullID, default: [:]][key, default: 0] += val
                            }
                        }
                    }
                }
            }
        }

        return BestBallWeeklyStatsResult(
            playerPoints: totalPoints,
            playerStats: totalStats,
            dailyBreakdown: dailyBreakdown,
            dailyStats: dailyStats
        )
    }

    /// Bulk fetch: fetches all ESPN box scores for a week with concurrent requests,
    /// returning stats for every player found. Call once per week, then filter per member locally.
    func fetchWeeklyAllPlayerStats(sport: String, weekStartDate: Date, weekEndDate: Date) async throws -> BestBallWeeklyStatsResult {
        let (sportPath, leaguePath) = espnPaths(for: sport)
        guard !sportPath.isEmpty else {
            return BestBallWeeklyStatsResult(playerPoints: [:], playerStats: [:], dailyBreakdown: [:], dailyStats: [:])
        }

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = calendar

        let prefix = sport.lowercased() + "-"

        // Build list of dates in the week
        var dates: [Date] = []
        var date = weekStartDate
        while date <= weekEndDate {
            dates.append(date)
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
        }

        // Phase 1: Fetch all scoreboards concurrently to collect game IDs
        var gamesByDate: [String: [String]] = [:]  // dateKey -> [gameID]
        await withTaskGroup(of: (String, [String]).self) { group in
            for d in dates {
                let dateKey = formatter.string(from: d)
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/scoreboard?dates=\(dateKey)") else {
                        return (dateKey, [])
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return (dateKey, [])
                    }
                    var ids: [String] = []
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let events = json["events"] as? [[String: Any]] {
                        for event in events {
                            if let comp = (event["competitions"] as? [[String: Any]])?.first,
                               let status = (comp["status"] as? [String: Any])?["type"] as? [String: Any],
                               let state = status["state"] as? String,
                               (state == "post" || state == "in"),
                               let eventID = event["id"] as? String {
                                ids.append(eventID)
                            }
                        }
                    }
                    return (dateKey, ids)
                }
            }
            for await (dateKey, ids) in group {
                if !ids.isEmpty {
                    gamesByDate[dateKey] = ids
                }
            }
        }

        // Phase 2: Fetch all box scores concurrently
        struct BoxScoreResult: Sendable {
            let dateKey: String
            let playerEntries: [(fullID: String, fpts: Double, lookup: [String: Double])]
        }

        // Flatten all (dateKey, gameID) pairs for concurrent fetch
        var allGameFetches: [(dateKey: String, gameID: String)] = []
        for (dateKey, gameIDs) in gamesByDate {
            for gameID in gameIDs {
                allGameFetches.append((dateKey, gameID))
            }
        }

        var totalPoints: [String: Double] = [:]
        var totalStats: [String: [String: Double]] = [:]
        var dailyBreakdown: [String: [String: Double]] = [:]
        var dailyStats: [String: [String: [String: Double]]] = [:]

        await withTaskGroup(of: BoxScoreResult.self) { group in
            for fetch in allGameFetches {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/summary?event=\(fetch.gameID)") else {
                        return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: [])
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: [])
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let boxscore = json["boxscore"] as? [String: Any],
                          let playerGroups = boxscore["players"] as? [[String: Any]] else {
                        return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: [])
                    }

                    var entries: [(fullID: String, fpts: Double, lookup: [String: Double])] = []
                    for playerGroup in playerGroups {
                        guard let statistics = playerGroup["statistics"] as? [[String: Any]] else { continue }
                        for stat in statistics {
                            guard let labels = stat["labels"] as? [String],
                                  let athletes = stat["athletes"] as? [[String: Any]] else { continue }
                            for athlete in athletes {
                                guard let athleteInfo = athlete["athlete"] as? [String: Any],
                                      let athleteID = athleteInfo["id"] as? String ?? (athleteInfo["id"] as? Int).map({ String($0) }) else { continue }
                                let fullID = prefix + athleteID
                                guard let stats = athlete["stats"] as? [String] else { continue }
                                var lookup: [String: Double] = [:]
                                for (i, label) in labels.enumerated() where i < stats.count {
                                    lookup[label] = Double(stats[i]) ?? 0
                                }
                                let fpts = Self.computeFantasyPoints(sport: sport, labels: labels, stats: stats)
                                entries.append((fullID, fpts, lookup))
                            }
                        }
                    }
                    return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: entries)
                }
            }

            for await result in group {
                for entry in result.playerEntries {
                    totalPoints[entry.fullID, default: 0] += entry.fpts
                    for (key, val) in entry.lookup {
                        totalStats[entry.fullID, default: [:]][key, default: 0] += val
                    }
                    dailyBreakdown[result.dateKey, default: [:]][entry.fullID, default: 0] += entry.fpts
                    for (key, val) in entry.lookup {
                        dailyStats[result.dateKey, default: [:]][entry.fullID, default: [:]][key, default: 0] += val
                    }
                }
            }
        }

        return BestBallWeeklyStatsResult(
            playerPoints: totalPoints,
            playerStats: totalStats,
            dailyBreakdown: dailyBreakdown,
            dailyStats: dailyStats
        )
    }

    /// Fetches season HR counts by hitting each player's ESPN athlete stats endpoint.
    /// This is ~1 lightweight call per unique player instead of fetching every box score of the season.
    func fetchSeasonHRCounts(playerIDs: [String]) async -> [String: Int] {
        let prefix = "mlb-"
        var result: [String: Int] = [:]

        // Deduplicate and extract ESPN IDs
        let uniqueIDs = Array(Set(playerIDs))

        let currentYear = Calendar.current.component(.year, from: Date())

        // Use TaskGroup for concurrent fetches
        await withTaskGroup(of: (String, Int)?.self) { group in
            for fullID in uniqueIDs {
                guard fullID.hasPrefix(prefix) else { continue }
                let espnID = String(fullID.dropFirst(prefix.count))

                group.addTask {
                    // ESPN athlete stats endpoint — returns career/season statistics
                    guard let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/baseball/mlb/athletes/\(espnID)/stats") else {
                        return nil
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        return nil
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let categories = json["categories"] as? [[String: Any]],
                          let battingCategory = categories.first else {
                        return nil
                    }

                    // Find HR index from labels array
                    guard let labels = battingCategory["labels"] as? [String],
                          let hrIndex = labels.firstIndex(of: "HR"),
                          let statistics = battingCategory["statistics"] as? [[String: Any]] else {
                        return nil
                    }

                    // Find the current season entry (most recent year)
                    // Each statistics entry has a "season" with "year" and a "stats" array
                    var totalHR = 0
                    for seasonEntry in statistics {
                        let season = seasonEntry["season"] as? [String: Any]
                        let year = season?["year"] as? Int ?? 0
                        guard year == currentYear else { continue }
                        if let stats = seasonEntry["stats"] as? [String],
                           hrIndex < stats.count,
                           let hr = Int(stats[hrIndex]) {
                            totalHR += hr
                        }
                    }

                    return totalHR > 0 ? (fullID, totalHR) : nil
                }
            }

            for await item in group {
                if let (id, hr) = item {
                    result[id] = hr
                }
            }
        }

        return result
    }

    private func espnPaths(for sport: String) -> (String, String) {
        switch sport {
        case "NBA": return ("basketball", "nba")
        case "MLB": return ("baseball", "mlb")
        case "NFL": return ("football", "nfl")
        default: return ("", "")
        }
    }

    private nonisolated static func computeFantasyPoints(sport: String, labels: [String], stats: [String]) -> Double {
        var lookup: [String: Double] = [:]
        for (i, label) in labels.enumerated() where i < stats.count {
            lookup[label] = Double(stats[i]) ?? 0
        }

        switch sport {
        case "NBA":
            return BestBallScoringEngine.nbaFantasyPoints(
                pts: Int(lookup["PTS"] ?? 0), reb: Int(lookup["REB"] ?? 0),
                ast: Int(lookup["AST"] ?? 0), stl: Int(lookup["STL"] ?? 0),
                blk: Int(lookup["BLK"] ?? 0), tov: Int(lookup["TO"] ?? 0)
            )
        case "MLB":
            let h = Int(lookup["H"] ?? 0)
            let doubles = Int(lookup["2B"] ?? 0)
            let triples = Int(lookup["3B"] ?? 0)
            let hr = Int(lookup["HR"] ?? 0)
            let singles = h - doubles - triples - hr
            if lookup["IP"] != nil {
                return BestBallScoringEngine.mlbPitcherPoints(
                    ip: lookup["IP"] ?? 0, k: Int(lookup["K"] ?? lookup["SO"] ?? 0),
                    w: Int(lookup["W"] ?? 0), er: Int(lookup["ER"] ?? 0), sv: Int(lookup["SV"] ?? 0)
                )
            } else {
                return BestBallScoringEngine.mlbHitterPoints(
                    singles: max(0, singles), doubles: doubles, triples: triples, hr: hr,
                    rbi: Int(lookup["RBI"] ?? 0), runs: Int(lookup["R"] ?? 0),
                    bb: Int(lookup["BB"] ?? 0), sb: Int(lookup["SB"] ?? 0),
                    k: Int(lookup["K"] ?? lookup["SO"] ?? 0)
                )
            }
        case "NFL":
            return BestBallScoringEngine.nflFantasyPoints(
                passYds: Int(lookup["YDS"] ?? 0), passTD: Int(lookup["TD"] ?? 0),
                interceptions: Int(lookup["INT"] ?? 0),
                rushYds: Int(lookup["RYDS"] ?? lookup["YDS"] ?? 0), rushTD: Int(lookup["RTD"] ?? 0),
                recYds: Int(lookup["RECYDS"] ?? 0), receptions: Int(lookup["REC"] ?? 0),
                recTD: Int(lookup["RECTD"] ?? 0), fumblesLost: Int(lookup["FUM"] ?? 0)
            )
        default:
            return 0
        }
    }
}

// MARK: - Season Helpers

enum BestBallSeasonHelper {
    static func totalWeeks(for sport: String) -> Int {
        switch sport {
        case "NBA": return 24
        case "MLB": return 26
        case "NFL": return 18
        default: return 20
        }
    }

    static func currentSeason() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let month = Calendar.current.component(.month, from: Date())
        if month >= 7 {
            return "\(year)-\(String(year + 1).suffix(2))"
        } else {
            return "\(year - 1)-\(String(year).suffix(2))"
        }
    }

    static func weekDateRange(sport: String, week: Int) -> (start: Date, end: Date) {
        let calendar = Calendar(identifier: .gregorian)

        let seasonStart = seasonStartDate(for: sport)

        if sport == "MLB" {
            // MLB: Week 1 is a short opening week ending on Sunday.
            // Week 2+ are standard Mon–Sun.
            let firstSunday = sundayOnOrAfter(seasonStart, calendar: calendar)
            if week == 1 {
                return (seasonStart, firstSunday)
            }
            // Week 2 starts the Monday after the first Sunday
            let week2Start = calendar.date(byAdding: .day, value: 1, to: firstSunday) ?? firstSunday
            let weekStart = calendar.date(byAdding: .day, value: (week - 2) * 7, to: week2Start) ?? week2Start
            let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart  // Mon→Sun
            return (weekStart, weekEnd)
        }

        let weekStart = calendar.date(byAdding: .day, value: (week - 1) * 7, to: seasonStart) ?? seasonStart
        let weekEnd: Date
        if sport == "NFL" {
            weekEnd = calendar.date(byAdding: .day, value: 4, to: weekStart) ?? weekStart  // Thu→Mon
        } else {
            weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart  // Mon→Sun
        }
        return (weekStart, weekEnd)
    }

    /// Determines the correct season start date based on current date and sport schedule.
    /// NBA/NFL: season starts in fall of previous year if we're currently before July.
    /// MLB: season starts in spring of current year.
    static func seasonStartDate(for sport: String) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: Date())

        switch sport {
        case "NBA":
            // NBA runs Oct→Apr. If before July, the season started last October.
            let startYear = month < 7 ? year - 1 : year
            return mondayOnOrAfter(calendar.date(from: DateComponents(year: startYear, month: 10, day: 22)) ?? Date(), calendar: calendar)
        case "MLB":
            // MLB runs late Mar→Sep. 2026 Opening Day is Wed March 25.
            // Use the actual date without rounding so all opening week games are included.
            let startYear = month < 3 ? year - 1 : year
            let raw = calendar.date(from: DateComponents(year: startYear, month: 3, day: 25)) ?? Date()
            return calendar.startOfDay(for: raw)
        case "NFL":
            // NFL runs Sep→Feb. If before July, the season started last September.
            let startYear = month < 7 ? year - 1 : year
            return thursdayOnOrAfter(calendar.date(from: DateComponents(year: startYear, month: 9, day: 4)) ?? Date(), calendar: calendar)
        default:
            return Date()
        }
    }

    /// Returns the current week number for a sport based on today's date
    static func currentWeekNumber(for sport: String) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())

        if sport == "MLB" {
            // Week 1 ends on the first Sunday after season start.
            // Week 2+ are standard Mon-Sun.
            let seasonStart = seasonStartDate(for: sport)
            let firstSunday = sundayOnOrAfter(seasonStart, calendar: calendar)
            if today <= firstSunday {
                return 1
            }
            let week2Start = calendar.date(byAdding: .day, value: 1, to: firstSunday) ?? firstSunday
            let days = calendar.dateComponents([.day], from: week2Start, to: today).day ?? 0
            return 2 + (days / 7)
        }

        let (start, _) = weekDateRange(sport: sport, week: 1)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(1, (days / 7) + 1)
    }

    private static func mondayOnOrAfter(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        // weekday: 1=Sun, 2=Mon, ...
        let daysToAdd = weekday == 2 ? 0 : ((9 - weekday) % 7)
        return calendar.date(byAdding: .day, value: daysToAdd, to: date) ?? date
    }

    private static func thursdayOnOrAfter(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        // weekday: 5=Thu
        let daysToAdd = weekday == 5 ? 0 : ((12 - weekday) % 7)
        return calendar.date(byAdding: .day, value: daysToAdd, to: date) ?? date
    }

    private static func sundayOnOrAfter(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        // weekday: 1=Sun
        let daysToAdd = weekday == 1 ? 0 : (8 - weekday)
        return calendar.date(byAdding: .day, value: daysToAdd, to: date) ?? date
    }
}

// MARK: - Private Types

private struct BBTeamRef {
    let id: String
    let abbreviation: String
}
