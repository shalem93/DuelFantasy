import Foundation

// MARK: - Core Models

struct PlayoffTiersTournament: Equatable {
    let id: String                          // "nba-playoffs-2026"
    let title: String
    let season: String
    let status: String                      // open, locked, live, settled
    let lockTime: Date?                     // first playoff game tipoff
    let entryCount: Int
    let playoffRound: String                // "full"
    let isSettled: Bool
    let createdAt: Date
}

struct PlayoffTiersPlayer: Identifiable, Hashable {
    let id: String                          // "nba-{espnID}"
    let name: String
    let team: String
    let position: String
    let tier: Int                           // 1-6
    let projectedPoints: Double             // per-game FPPG average
    var gamesPlayed: Int
    var totalFantasyPoints: Double
    var perGameAvg: Double
    let imageURL: String?
    var isEliminated: Bool

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: PlayoffTiersPlayer, rhs: PlayoffTiersPlayer) -> Bool { lhs.id == rhs.id }
}

struct PlayoffTiersPick: Codable, Hashable {
    let tier: Int
    let playerID: String
    let playerName: String
    let playerTeam: String
}

struct PlayoffTiersEntry: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [PlayoffTiersPick]           // 6 picks (one per tier)
    var totalPoints: Double
    var rank: Int
    let isBot: Bool
    let isCurrentUser: Bool

    static func == (lhs: PlayoffTiersEntry, rhs: PlayoffTiersEntry) -> Bool {
        lhs.id == rhs.id && lhs.totalPoints == rhs.totalPoints && lhs.rank == rhs.rank
    }
}

struct PlayoffTiersLeaderboardEntry: Identifiable {
    let id: UUID
    let entryName: String
    let picks: [PlayoffTiersPick]
    let totalPoints: Double
    let rank: Int
    let isCurrentUser: Bool
    /// Breakdown: playerID → accumulated FPTS
    let playerPoints: [String: Double]
}

struct PlayoffTiersScoreSnapshot {
    /// playerID → accumulated playoff FPTS across all games
    let playerFantasyPoints: [String: Double]
    /// playerID → total games played in playoffs
    let playerGamesPlayed: [String: Int]
    /// Teams that have been eliminated from the playoffs
    let eliminatedTeams: Set<String>
    let isPlayoffsComplete: Bool
}

// MARK: - Private Groups

struct PlayoffTiersGroup: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let name: String
    let createdBy: String               // user ID of the group creator
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date
}

struct PlayoffTiersGroupMember: Identifiable, Equatable {
    let id: UUID
    let groupID: UUID
    let userID: String
    let displayName: String
    let joinedAt: Date
}

// MARK: - Tier Generation Engine

struct PlayoffTiersEngine {
    /// Tier sizes: Tier 1 = top 8 superstars, Tier 6 = bottom 30 role players
    static let tierSizes = [8, 12, 15, 20, 25, 30]  // = 110 players total

    /// Distribute players into 6 tiers based on per-game fantasy averages (descending).
    static func generateTiers(from players: [PlayoffTiersPlayer]) -> [[PlayoffTiersPlayer]] {
        let sorted = players.sorted { $0.projectedPoints > $1.projectedPoints }
        var tiers: [[PlayoffTiersPlayer]] = []
        var offset = 0

        for (tierIndex, size) in tierSizes.enumerated() {
            let end = min(offset + size, sorted.count)
            guard offset < end else {
                tiers.append([])
                continue
            }
            let tierPlayers = sorted[offset..<end].map { player in
                PlayoffTiersPlayer(
                    id: player.id,
                    name: player.name,
                    team: player.team,
                    position: player.position,
                    tier: tierIndex + 1,
                    projectedPoints: player.projectedPoints,
                    gamesPlayed: player.gamesPlayed,
                    totalFantasyPoints: player.totalFantasyPoints,
                    perGameAvg: player.perGameAvg,
                    imageURL: player.imageURL,
                    isEliminated: player.isEliminated
                )
            }
            tiers.append(tierPlayers)
            offset = end
        }

        // Pad to 6 tiers if needed
        while tiers.count < 6 { tiers.append([]) }
        return tiers
    }

    /// FanDuel NBA scoring: PTS×1 + REB×1.2 + AST×1.5 + STL×3 + BLK×3 - TO×1
    static func nbaFantasyPoints(pts: Int, reb: Int, ast: Int, stl: Int, blk: Int, tov: Int) -> Double {
        Double(pts) * 1.0 + Double(reb) * 1.2 + Double(ast) * 1.5
            + Double(stl) * 3.0 + Double(blk) * 3.0 - Double(tov) * 1.0
    }

    /// Compute leaderboard from entries + live scores
    static func computeLeaderboard(
        entries: [PlayoffTiersEntry],
        playerPoints: [String: Double],
        currentUserID: String?
    ) -> [PlayoffTiersLeaderboardEntry] {
        var scored: [(entry: PlayoffTiersEntry, total: Double, breakdown: [String: Double])] = []

        for entry in entries {
            var total = 0.0
            var breakdown: [String: Double] = [:]
            for pick in entry.picks {
                let pts = playerPoints[pick.playerID] ?? 0
                total += pts
                breakdown[pick.playerID] = pts
            }
            scored.append((entry, total, breakdown))
        }

        // Sort by total points descending
        scored.sort { $0.total > $1.total }

        return scored.enumerated().map { index, item in
            PlayoffTiersLeaderboardEntry(
                id: item.entry.id,
                entryName: item.entry.entryName,
                picks: item.entry.picks,
                totalPoints: item.total,
                rank: index + 1,
                isCurrentUser: item.entry.userID == currentUserID,
                playerPoints: item.breakdown
            )
        }
    }

    /// RR delta calculation (same tiers as DFS)
    static func rrDelta(forRank rank: Int, totalEntries: Int) -> Int {
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
}

// MARK: - ESPN Playoff Tiers Data Provider

/// Actor that caches playoff series events for a short window to avoid
/// redundant per-day scoreboard fetches within the same refresh cycle.
private actor PlayoffSeriesCache {
    var events: [[String: Any]] = []
    var fetchedAt: Date = .distantPast

    func get() -> [[String: Any]]? {
        guard Date().timeIntervalSince(fetchedAt) < 30 else { return nil }
        return events.isEmpty ? nil : events
    }

    func set(_ events: [[String: Any]]) {
        self.events = events
        self.fetchedAt = Date()
    }
}

struct ESPNPlayoffTiersDataProvider: Sendable {
    private let session: URLSession
    private let seriesCache = PlayoffSeriesCache()

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Fetch Playoff Players

    /// Fetch all players from playoff teams with per-game fantasy averages.
    /// Uses seasontype=3 (playoffs) if available, falls back to seasontype=2 (regular season).
    func fetchPlayoffPlayers() async throws -> [PlayoffTiersPlayer] {
        // Step 1: Get playoff teams from the playoff scoreboard
        let playoffTeams = try await fetchPlayoffTeamIDs()
        guard !playoffTeams.isEmpty else {
            print("[PlayoffTiers] No playoff teams found, trying regular season standings")
            return try await fetchFromRegularSeasonStandings()
        }

        // Step 2: Fetch each team's player stats in parallel
        let allPlayers: [PlayoffTiersPlayer] = try await withThrowingTaskGroup(of: [PlayoffTiersPlayer].self) { group in
            for team in playoffTeams {
                group.addTask {
                    return await self.fetchTeamPlayerStats(
                        teamID: team.id,
                        teamAbbreviation: team.abbreviation,
                        usePlayoffStats: true
                    )
                }
            }
            var results: [PlayoffTiersPlayer] = []
            for try await players in group {
                results.append(contentsOf: players)
            }
            return results
        }

        // If playoff stats are sparse (playoffs just started), supplement with regular season
        if allPlayers.filter({ $0.projectedPoints > 5 }).count < 80 {
            print("[PlayoffTiers] Sparse playoff data, using regular season stats for projections")
            return try await fetchPlayoffPlayersWithRegularSeasonStats(playoffTeams: playoffTeams)
        }

        return allPlayers
    }

    /// Fallback: use regular season stats for projection when playoffs haven't generated enough data
    private func fetchPlayoffPlayersWithRegularSeasonStats(
        playoffTeams: [PlayoffTeamInfo]
    ) async throws -> [PlayoffTiersPlayer] {
        try await withThrowingTaskGroup(of: [PlayoffTiersPlayer].self) { group in
            for team in playoffTeams {
                group.addTask {
                    return await self.fetchTeamPlayerStats(
                        teamID: team.id,
                        teamAbbreviation: team.abbreviation,
                        usePlayoffStats: false
                    )
                }
            }
            var results: [PlayoffTiersPlayer] = []
            for try await players in group {
                results.append(contentsOf: players)
            }
            return results
        }
    }

    private struct PlayoffTeamInfo: Sendable {
        let id: String
        let abbreviation: String
    }

    /// Parse the NBA playoff scoreboard to extract participating team IDs.
    /// Scans multiple days (today + next 3) to find Round 1+ series games,
    /// filtering out play-in games so eliminated play-in teams are excluded.
    /// Falls back to top 16 from standings if playoffs haven't started yet.
    private func fetchPlayoffTeamIDs() async throws -> [PlayoffTeamInfo] {
        let events = await fetchPlayoffSeriesEvents()

        var seen = Set<String>()
        var teams: [PlayoffTeamInfo] = []

        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let competitors = competition["competitors"] as? [[String: Any]] else { continue }

            for competitor in competitors {
                guard let team = competitor["team"] as? [String: Any],
                      let id = team["id"] as? String,
                      let abbreviation = team["abbreviation"] as? String else { continue }
                if seen.insert(id).inserted {
                    teams.append(PlayoffTeamInfo(id: id, abbreviation: abbreviation))
                }
            }
        }

        // If no real playoff games found, fall back to standings
        if teams.isEmpty {
            print("[PlayoffTiers] No Round 1+ playoff games found, using standings")
            return try await fetchTopTeamsFromStandings()
        }

        print("[PlayoffTiers] Found \(teams.count) playoff teams from Round 1+ series")
        return teams
    }

    /// Fetch playoff scoreboard events that are actual Round 1+ series (not play-in).
    /// Scans individual days (-14 to +3) on the default scoreboard, which reliably
    /// includes `series.type == "playoff"` for Round 1+ games. The `seasontype=3`
    /// endpoint with broad date ranges returns stale regular-season data capped at 100.
    /// Results are cached for 30 seconds to avoid redundant fetches within a refresh cycle.
    private func fetchPlayoffSeriesEvents() async -> [[String: Any]] {
        if let cached = await seriesCache.get() {
            return cached
        }
        let events = await fetchPlayoffSeriesEventsFromNetwork()
        await seriesCache.set(events)
        return events
    }

    private func fetchPlayoffSeriesEventsFromNetwork() async -> [[String: Any]] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = Calendar(identifier: .gregorian)

        // Scan today ± a window. Use -90..+3 to catch ALL playoff games from the entire
        // postseason (Round 1 through Finals spans ~2 months, mid-April through mid-June).
        // The old -14 window only captured the last 2 weeks, causing scores to drop when
        // earlier rounds fell outside the window.
        let dates = (-90...3).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: Date()) else { return nil }
            return formatter.string(from: date)
        }

        var allEvents: [[String: Any]] = []
        var seenIDs = Set<String>()

        // Fetch in parallel batches of 15 to balance speed vs hammering
        let batchSize = 15
        for batchStart in stride(from: 0, to: dates.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, dates.count)
            let batch = Array(dates[batchStart..<batchEnd])

            let batchResults: [[[String: Any]]] = await withTaskGroup(of: [[String: Any]].self) { group in
                for dateKey in batch {
                    group.addTask {
                        // Use default scoreboard (no seasontype) — it correctly marks playoff games
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=\(dateKey)") else { return [] }
                        guard let (data, response) = try? await self.session.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let events = json["events"] as? [[String: Any]] else { return [] }
                        // Only return actual postseason playoff games (season.type == 3).
                        // Regular-season games between playoff teams can have series.type == "playoff"
                        // as a preview, but season.type will be 2 (regular season).
                        return events.filter { event in
                            guard let season = event["season"] as? [String: Any],
                                  let seasonType = season["type"] as? Int,
                                  seasonType == 3,
                                  let competitions = event["competitions"] as? [[String: Any]],
                                  let competition = competitions.first,
                                  let series = competition["series"] as? [String: Any],
                                  let seriesType = series["type"] as? String else { return false }
                            return seriesType == "playoff"
                        }
                    }
                }
                var results: [[[String: Any]]] = []
                for await events in group {
                    results.append(events)
                }
                return results
            }

            for events in batchResults {
                for event in events {
                    if let id = event["id"] as? String, seenIDs.insert(id).inserted {
                        allEvents.append(event)
                    }
                }
            }
        }

        if !allEvents.isEmpty {
            print("[PlayoffTiers] Found \(allEvents.count) Round 1+ playoff events")
        }
        return allEvents
    }

    /// Fetch top 16 teams by wins from NBA standings (used before playoffs start)
    private func fetchTopTeamsFromStandings() async throws -> [PlayoffTeamInfo] {
        guard let url = URL(string: "https://site.api.espn.com/apis/v2/sports/basketball/nba/standings") else {
            return []
        }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let children = json["children"] as? [[String: Any]] else {
            return []
        }

        var allTeams: [(id: String, abbreviation: String, wins: Int)] = []

        for conference in children {
            guard let standings = conference["standings"] as? [String: Any],
                  let entries = standings["entries"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let team = entry["team"] as? [String: Any],
                      let id = team["id"] as? String,
                      let abbreviation = team["abbreviation"] as? String else { continue }
                var wins = 0
                if let stats = entry["stats"] as? [[String: Any]] {
                    for stat in stats {
                        if let name = stat["name"] as? String, name == "wins",
                           let value = stat["value"] as? Double {
                            wins = Int(value)
                        }
                    }
                }
                allTeams.append((id, abbreviation, wins))
            }
        }

        let top16 = allTeams.sorted { $0.wins > $1.wins }
            .prefix(16)
            .map { PlayoffTeamInfo(id: $0.id, abbreviation: $0.abbreviation) }

        print("[PlayoffTiers] Using top \(top16.count) teams from standings")
        return Array(top16)
    }

    /// Fallback: use regular season standings to get top 16 teams (likely playoff teams)
    private func fetchFromRegularSeasonStandings() async throws -> [PlayoffTiersPlayer] {
        // Fetch NBA standings
        guard let url = URL(string: "https://site.api.espn.com/apis/v2/sports/basketball/nba/standings") else {
            return []
        }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let children = json["children"] as? [[String: Any]] else {
            return []
        }

        var allTeams: [(id: String, abbreviation: String, wins: Int)] = []

        for conference in children {
            guard let standings = conference["standings"] as? [String: Any],
                  let entries = standings["entries"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let team = entry["team"] as? [String: Any],
                      let id = team["id"] as? String,
                      let abbreviation = team["abbreviation"] as? String else { continue }
                // Parse wins from stats
                var wins = 0
                if let stats = entry["stats"] as? [[String: Any]] {
                    for stat in stats {
                        if let name = stat["name"] as? String, name == "wins",
                           let value = stat["value"] as? Double {
                            wins = Int(value)
                        }
                    }
                }
                allTeams.append((id, abbreviation, wins))
            }
        }

        // Take top 16 by wins
        let playoffTeams = allTeams.sorted { $0.wins > $1.wins }
            .prefix(16)
            .map { PlayoffTeamInfo(id: $0.id, abbreviation: $0.abbreviation) }

        return try await fetchPlayoffPlayersWithRegularSeasonStats(playoffTeams: Array(playoffTeams))
    }

    /// Fetch player stats for a single team from ESPN
    private func fetchTeamPlayerStats(
        teamID: String,
        teamAbbreviation: String,
        usePlayoffStats: Bool
    ) async -> [PlayoffTiersPlayer] {
        // Fetch stats and current roster in parallel.
        // The statistics endpoint can include traded players who played for this team
        // earlier in the season, so we cross-reference with the current roster.
        let seasonType = usePlayoffStats ? "3" : "2"
        guard let statsURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/\(teamID)/athletes/statistics?seasontype=\(seasonType)"),
              let rosterURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/\(teamID)/roster") else {
            return []
        }

        async let statsTask = session.data(from: statsURL)
        async let rosterTask = session.data(from: rosterURL)

        // Build set of current roster player IDs
        var currentRosterIDs = Set<String>()
        if let (rosterData, _) = try? await rosterTask,
           let rosterJSON = try? JSONSerialization.jsonObject(with: rosterData) as? [String: Any],
           let athletes = rosterJSON["athletes"] as? [[String: Any]] {
            for athlete in athletes {
                if let id = athlete["id"] as? String {
                    currentRosterIDs.insert(id)
                }
            }
        }

        guard let (data, response) = try? await statsTask,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if usePlayoffStats {
                return await fetchTeamPlayerStats(teamID: teamID, teamAbbreviation: teamAbbreviation, usePlayoffStats: false)
            }
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let firstResult = results.first,
              let leaders = firstResult["leaders"] as? [[String: Any]],
              !leaders.isEmpty else {
            if usePlayoffStats {
                return await fetchTeamPlayerStats(teamID: teamID, teamAbbreviation: teamAbbreviation, usePlayoffStats: false)
            }
            return []
        }

        var players: [PlayoffTiersPlayer] = []

        for leader in leaders {
            guard let athlete = leader["athlete"] as? [String: Any],
                  let athleteID = athlete["id"] as? String,
                  let displayName = athlete["displayName"] as? String else { continue }

            // Skip players no longer on this team's current roster (traded mid-season)
            if !currentRosterIDs.isEmpty && !currentRosterIDs.contains(athleteID) {
                continue
            }

            let position = (athlete["position"] as? [String: Any])?["abbreviation"] as? String ?? "SF"
            let headshot = (athlete["headshot"] as? [String: Any])?["href"] as? String

            guard let statistics = leader["statistics"] as? [[String: Any]] else { continue }

            var ppg: Double = 0, rpg: Double = 0, apg: Double = 0
            var spg: Double = 0, bpg: Double = 0, topg: Double = 0
            var gp: Int = 0, mpg: Double = 0

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
                    default: break
                    }
                }
            }

            // FanDuel-style FPPG: PTS×1 + REB×1.2 + AST×1.5 + STL×3 + BLK×3 - TO×1
            let fppg = ppg * 1.0 + rpg * 1.2 + apg * 1.5 + spg * 3.0 + bpg * 3.0 - topg * 1.0

            // Skip players with very low minutes (likely deep bench / two-way)
            guard mpg >= 8.0 || gp == 0 else { continue }

            players.append(PlayoffTiersPlayer(
                id: "nba-\(athleteID)",
                name: displayName,
                team: teamAbbreviation,
                position: position,
                tier: 0,    // assigned later by engine
                projectedPoints: fppg,
                gamesPlayed: gp,
                totalFantasyPoints: 0,
                perGameAvg: fppg,
                imageURL: headshot,
                isEliminated: false
            ))
        }

        return players.sorted { $0.projectedPoints > $1.projectedPoints }
    }

    // MARK: Fetch Playoff Scores (Live)

    /// Fetch accumulated fantasy points for specified players across all playoff games.
    /// Returns total FPTS per player accumulated over the entire postseason.
    func fetchPlayoffScores(playerIDs: Set<String>) async -> [String: Double] {
        let events = await fetchPlayoffSeriesEvents()

        // Gather game IDs for completed and in-progress games
        var gameIDs: [String] = []
        for event in events {
            guard let id = event["id"] as? String,
                  let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let state = statusType["state"] as? String else { continue }
            if state == "in" || state == "post" {
                gameIDs.append(id)
            }
        }

        guard !gameIDs.isEmpty else {
            print("[PlayoffTiers] fetchPlayoffScores: no completed/in-progress games found")
            return [:]
        }
        print("[PlayoffTiers] fetchPlayoffScores: found \(gameIDs.count) games to score across full playoffs")

        // Strip "nba-" prefix for ESPN lookups
        let espnIDs = Set(playerIDs.compactMap { id -> String? in
            id.hasPrefix("nba-") ? String(id.dropFirst(4)) : nil
        })

        // Fetch box scores in parallel (batch of 10 at a time to avoid hammering)
        var allPoints: [String: Double] = [:]
        let batchSize = 10

        for batchStart in stride(from: 0, to: gameIDs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, gameIDs.count)
            let batch = Array(gameIDs[batchStart..<batchEnd])

            let batchResults: [String: Double] = await withTaskGroup(of: [String: Double].self) { group in
                for gameID in batch {
                    group.addTask {
                        return await self.fetchGameBoxScore(gameID: gameID, relevantPlayerIDs: espnIDs)
                    }
                }
                var merged: [String: Double] = [:]
                for await gamePoints in group {
                    for (playerID, pts) in gamePoints {
                        merged["nba-\(playerID)", default: 0] += pts
                    }
                }
                return merged
            }

            for (playerID, pts) in batchResults {
                allPoints[playerID, default: 0] += pts
            }
        }

        return allPoints
    }

    /// Fetch box score for a single game and compute fantasy points for relevant players
    private func fetchGameBoxScore(gameID: String, relevantPlayerIDs: Set<String>) async -> [String: Double] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(gameID)") else {
            return [:]
        }
        guard let (data, _) = try? await session.data(from: url) else {
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boxscore = json["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else {
            return [:]
        }

        var points: [String: Double] = [:]

        for team in players {
            guard let statistics = team["statistics"] as? [[String: Any]] else { continue }
            for statGroup in statistics {
                guard let athletes = statGroup["athletes"] as? [[String: Any]],
                      let labels = statGroup["labels"] as? [String] else { continue }

                // Build label index map
                var labelIndex: [String: Int] = [:]
                for (i, label) in labels.enumerated() {
                    labelIndex[label] = i
                }

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          relevantPlayerIDs.contains(athleteID) else { continue }

                    guard let stats = athlete["stats"] as? [String] else { continue }

                    func statValue(_ label: String) -> Int {
                        guard let idx = labelIndex[label], idx < stats.count,
                              let val = Int(stats[idx]) else { return 0 }
                        return val
                    }

                    func parseMinutes(_ label: String) -> Double {
                        guard let idx = labelIndex[label], idx < stats.count else { return 0 }
                        let parts = stats[idx].split(separator: ":")
                        guard let mins = Double(parts.first ?? "0") else { return 0 }
                        return mins
                    }

                    let mins = parseMinutes("MIN")
                    guard mins > 0 else { continue }  // DNP

                    let pts = statValue("PTS")
                    let reb = statValue("REB")
                    let ast = statValue("AST")
                    let stl = statValue("STL")
                    let blk = statValue("BLK")
                    let tov = statValue("TO")

                    let fpts = PlayoffTiersEngine.nbaFantasyPoints(
                        pts: pts, reb: reb, ast: ast, stl: stl, blk: blk, tov: tov
                    )
                    points[athleteID] = fpts
                }
            }
        }

        return points
    }

    // MARK: Check If Playoff Games Have Started

    /// Returns true if any Round 1+ playoff games are in progress or completed.
    /// Lighter than fetchEliminatedTeams — used for locked → live transition.
    func hasPlayoffGamesStarted() async -> Bool {
        let events = await fetchPlayoffSeriesEvents()
        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let state = statusType["state"] as? String else { continue }
            if state == "in" || state == "post" {
                return true
            }
        }
        return false
    }

    // MARK: Fetch Active/Eliminated Teams

    /// Determine which teams have been eliminated from the playoffs.
    /// Uses ESPN's series summary (e.g. "OKC wins series 4-0") which is present on every
    /// game in the series, so we only need one game from each completed series in our window.
    func fetchEliminatedTeams() async -> Set<String> {
        let events = await fetchPlayoffSeriesEvents()

        // Collect the best series info per matchup (keyed by sorted team pair).
        // Multiple games in the same series appear — we want the one marked completed.
        struct SeriesInfo {
            let team0: String
            let team1: String
            let summary: String
            let completed: Bool
        }
        var bestPerSeries: [String: SeriesInfo] = [:]

        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let competitors = competition["competitors"] as? [[String: Any]],
                  competitors.count == 2,
                  let series = competition["series"] as? [String: Any] else { continue }

            let team0 = (competitors[0]["team"] as? [String: Any])?["abbreviation"] as? String
            let team1 = (competitors[1]["team"] as? [String: Any])?["abbreviation"] as? String
            guard let t0 = team0, let t1 = team1 else { continue }

            let seriesKey = [t0, t1].sorted().joined(separator: "-")
            let summary = series["summary"] as? String ?? ""
            let completed = series["completed"] as? Bool ?? false

            // Prefer completed info over in-progress
            if completed || bestPerSeries[seriesKey] == nil || !(bestPerSeries[seriesKey]?.completed ?? false) {
                bestPerSeries[seriesKey] = SeriesInfo(team0: t0, team1: t1, summary: summary, completed: completed)
            }
        }

        // Determine eliminated teams from completed series.
        // Summary format: "OKC wins series 4-0" — always starts with the winning team abbreviation.
        var eliminated = Set<String>()
        for (_, info) in bestPerSeries {
            let summary = info.summary.lowercased()
            guard summary.contains("win") && summary.contains("series") else { continue }
            if summary.hasPrefix(info.team0.lowercased()) {
                eliminated.insert(info.team1)
            } else if summary.hasPrefix(info.team1.lowercased()) {
                eliminated.insert(info.team0)
            }
        }

        return eliminated
    }

    /// Check if the entire playoffs are complete (NBA Finals has a winner)
    func checkPlayoffsComplete() async -> Bool {
        let eliminated = await fetchEliminatedTeams()
        // If 15 of 16 teams are eliminated, the playoffs are complete
        if !eliminated.isEmpty && eliminated.count >= 15 {
            return true
        }

        // Also check for a completed Finals series
        let events = await fetchPlayoffSeriesEvents()
        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let series = competition["series"] as? [String: Any],
                  let summary = series["summary"] as? String,
                  series["completed"] as? Bool == true else { continue }

            // A completed series with "wins 4-" in the Finals
            if summary.lowercased().contains("wins 4-") {
                if let notes = competition["notes"] as? [[String: Any]],
                   let headline = notes.first?["headline"] as? String,
                   headline.lowercased().contains("final") {
                    return true
                }
            }
        }

        return false
    }

    /// Get the lock time (first Round 1 playoff game tipoff).
    /// Only considers actual playoff series (not play-in). Returns nil if Round 1 hasn't been scheduled.
    func fetchPlayoffLockTime() async -> Date? {
        let events = await fetchPlayoffSeriesEvents()

        var earliestDate: Date?

        for event in events {
            guard let dateStr = event["date"] as? String else { continue }
            if let date = parsePlayoffDate(dateStr) {
                if earliestDate == nil || date < earliestDate! {
                    earliestDate = date
                }
            }
        }

        if let earliest = earliestDate {
            print("[PlayoffTiers] Lock time from Round 1: \(earliest)")
        }
        return earliestDate
    }

    /// Parse an ESPN date string using multiple formatters
    private func parsePlayoffDate(_ dateStr: String) -> Date? {
        if let date = PlayoffTiersDateParsers.isoBasic.date(from: dateStr) { return date }
        if let date = PlayoffTiersDateParsers.withFractionalSeconds.date(from: dateStr) { return date }
        for formatter in PlayoffTiersDateParsers.allFormatters {
            if let date = formatter.date(from: dateStr) { return date }
        }
        return nil
    }

    // MARK: Fetch Games Played Per Player

    /// Count how many playoff games each player has appeared in
    func fetchPlayerGamesPlayed(playerIDs: Set<String>) async -> [String: Int] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?seasontype=3&limit=100") else {
            return [:]
        }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            return [:]
        }

        var gameIDs: [String] = []
        for event in events {
            guard let id = event["id"] as? String,
                  let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let state = statusType["state"] as? String else { continue }
            if state == "post" {
                gameIDs.append(id)
            }
        }

        let espnIDs = Set(playerIDs.compactMap { id -> String? in
            id.hasPrefix("nba-") ? String(id.dropFirst(4)) : nil
        })

        var gamesPlayed: [String: Int] = [:]
        let batchSize = 10

        for batchStart in stride(from: 0, to: gameIDs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, gameIDs.count)
            let batch = Array(gameIDs[batchStart..<batchEnd])

            let batchResults: [String: Bool] = await withTaskGroup(of: [(String, Bool)].self) { group in
                for gameID in batch {
                    group.addTask {
                        let played = await self.fetchPlayersInGame(gameID: gameID, relevantPlayerIDs: espnIDs)
                        return played.map { ($0, true) }
                    }
                }
                var merged: [(String, Bool)] = []
                for await pairs in group {
                    merged.append(contentsOf: pairs)
                }
                var result: [String: Bool] = [:]
                for (id, val) in merged { result[id] = val }
                return result
            }

            for (espnID, _) in batchResults {
                gamesPlayed["nba-\(espnID)", default: 0] += 1
            }
        }

        return gamesPlayed
    }

    /// Check which relevant players appeared in a specific game
    private func fetchPlayersInGame(gameID: String, relevantPlayerIDs: Set<String>) async -> [String] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(gameID)") else {
            return []
        }
        guard let (data, _) = try? await session.data(from: url) else {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boxscore = json["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        var appeared: [String] = []

        for team in players {
            guard let statistics = team["statistics"] as? [[String: Any]] else { continue }
            for statGroup in statistics {
                guard let athletes = statGroup["athletes"] as? [[String: Any]],
                      let labels = statGroup["labels"] as? [String] else { continue }

                let minIdx = labels.firstIndex(of: "MIN")

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          relevantPlayerIDs.contains(athleteID) else { continue }

                    // Check if they actually played (MIN > 0)
                    if let stats = athlete["stats"] as? [String],
                       let idx = minIdx, idx < stats.count {
                        let parts = stats[idx].split(separator: ":")
                        if let mins = Double(parts.first ?? "0"), mins > 0 {
                            appeared.append(athleteID)
                        }
                    }
                }
            }
        }

        return appeared
    }
}

// MARK: - Bot Generation

struct PlayoffTiersBotDrafter {
    /// Bot personality styles
    enum BotPersonality: CaseIterable {
        case starsFocused       // Picks highest-projected in each tier
        case teamDiversifier    // Spreads across many teams
        case upsideChaser       // Adds extra noise, loves high-ceiling
        case volumeSeeker       // Prefers players on teams likely to play many games
        case balanced           // Standard weighted random

        var noiseMultiplier: Double {
            switch self {
            case .starsFocused: return 0.15
            case .teamDiversifier: return 0.25
            case .upsideChaser: return 0.40
            case .volumeSeeker: return 0.20
            case .balanced: return 0.25
            }
        }
    }

    /// Bot name pool
    static let botNames = [
        "HoopsDreamer", "BracketBuster", "PlayoffPro", "RimProtector", "CourtGenius",
        "TripleThreat", "DunkCity", "SwishMaster", "FastBreak", "BuzzerBeater",
        "PostMove", "ThreeAndD", "FloorGeneral", "SixthMan", "ClutchTime",
        "NetRipper", "AlleyOop", "FullCourt", "CrossOver", "DeepRange",
        "PickAndRoll", "FadeAway", "HalfCourt", "LockerRoom", "DownTown",
        "HighRiser", "BallHawk", "ScreenSetter", "SpotUp", "TransitionKing",
        "PostSeason", "EliminationGame", "GameSeven", "SeriesSweep", "OvertimeHero",
        "ChampionChaser", "DynastyBuilder", "MarchMadness", "BracketKing", "CourtVision",
        "SlamDunkPro", "ThreePointKing", "ReboundKing", "AssistMaster", "StealsChamp"
    ]

    /// Deterministic RNG seeded from a tournament ID so all clients generate the same bots.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            // SplitMix64
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
    }

    /// Derive a stable seed from a tournament ID string.
    private static func seed(from tournamentID: String) -> UInt64 {
        // FNV-1a 64-bit hash
        var hash: UInt64 = 14695981039346656037
        for byte in tournamentID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    /// Generate 999 bot entries with diversified picks.
    /// When a `tournamentID` is provided, bot generation is deterministic — all clients
    /// produce the exact same bot field for the same tournament, so even if persistence
    /// fails the field stays stable.
    static func generateBotEntries(
        tiers: [[PlayoffTiersPlayer]],
        count: Int = 999,
        tournamentID: String? = nil
    ) -> [PlayoffTiersEntry] {
        guard tiers.count == 6, tiers.allSatisfy({ !$0.isEmpty }) else {
            print("[PlayoffTiers] Cannot generate bots: invalid tier data")
            return []
        }

        var rng: SeededRNG? = tournamentID.map { SeededRNG(seed: seed(from: $0)) }

        var entries: [PlayoffTiersEntry] = []

        for i in 0..<count {
            let personality = BotPersonality.allCases[i % BotPersonality.allCases.count]
            let nameIndex = i % botNames.count
            let nameSuffix = i / botNames.count
            let botName = nameSuffix == 0 ? botNames[nameIndex] : "\(botNames[nameIndex])\(nameSuffix + 1)"

            if let picks = generateBotPicks(tiers: tiers, personality: personality, rng: &rng) {
                entries.append(PlayoffTiersEntry(
                    id: UUID(),
                    tournamentID: "",  // Set by caller
                    userID: nil,
                    entryName: botName,
                    picks: picks,
                    totalPoints: 0,
                    rank: 0,
                    isBot: true,
                    isCurrentUser: false
                ))
            }
        }

        print("[PlayoffTiers] Generated \(entries.count) bot entries")
        return entries
    }

    /// Generate a random Double in the given range using the seeded RNG if available.
    private static func randomDouble(in range: Range<Double>, rng: inout SeededRNG?) -> Double {
        if var r = rng {
            let result = Double.random(in: range, using: &r)
            rng = r
            return result
        }
        return Double.random(in: range)
    }

    private static func randomDouble(in range: ClosedRange<Double>, rng: inout SeededRNG?) -> Double {
        if var r = rng {
            let result = Double.random(in: range, using: &r)
            rng = r
            return result
        }
        return Double.random(in: range)
    }

    /// Generate 6 picks (one per tier) for a bot with the given personality
    private static func generateBotPicks(
        tiers: [[PlayoffTiersPlayer]],
        personality: BotPersonality,
        rng: inout SeededRNG?
    ) -> [PlayoffTiersPick]? {
        var picks: [PlayoffTiersPick] = []
        var teamCounts: [String: Int] = [:]  // max 2 players from same team

        for tierIndex in 0..<6 {
            let tierPlayers = tiers[tierIndex]
            guard !tierPlayers.isEmpty else { return nil }

            // Add noise to projections
            let noiseRange = personality.noiseMultiplier
            var candidates: [(player: PlayoffTiersPlayer, weight: Double)] = []

            for player in tierPlayers {
                // Team constraint: max 2 from same team
                if (teamCounts[player.team] ?? 0) >= 2 { continue }

                let noise = randomDouble(in: (1.0 - noiseRange)...(1.0 + noiseRange), rng: &rng)
                var weight = max(player.projectedPoints * noise, 0.1)

                // Personality adjustments
                switch personality {
                case .starsFocused:
                    // Boost top projections in each tier
                    if player.projectedPoints >= tierPlayers.first!.projectedPoints * 0.85 {
                        weight *= 1.5
                    }
                case .teamDiversifier:
                    // Penalize teams already picked
                    let existing = teamCounts[player.team] ?? 0
                    if existing > 0 { weight *= 0.3 }
                case .upsideChaser:
                    // Extra noise already applied via higher noiseMultiplier
                    break
                case .volumeSeeker:
                    // Slight boost for players already picked (same team = more games together)
                    // This personality doesn't avoid same-team much
                    break
                case .balanced:
                    break
                }

                candidates.append((player, weight))
            }

            guard !candidates.isEmpty else { return nil }

            // Weighted random selection
            let totalWeight = candidates.reduce(0) { $0 + $1.weight }
            var roll = randomDouble(in: 0..<totalWeight, rng: &rng)
            var selected = candidates.last!.player

            for candidate in candidates {
                roll -= candidate.weight
                if roll <= 0 {
                    selected = candidate.player
                    break
                }
            }

            picks.append(PlayoffTiersPick(
                tier: tierIndex + 1,
                playerID: selected.id,
                playerName: selected.name,
                playerTeam: selected.team
            ))
            teamCounts[selected.team, default: 0] += 1
        }

        return picks.count == 6 ? picks : nil
    }
}

// MARK: - Date Parsing

private enum PlayoffTiersDateParsers {
    static let noSecondsUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mmZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let withSecondsUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let allFormatters: [DateFormatter] = [noSecondsUTC, withSecondsUTC]
}

extension JSONDecoder {
    nonisolated static var playoffTiersDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            if let date = PlayoffTiersDateParsers.noSecondsUTC.date(from: value) { return date }
            if let date = PlayoffTiersDateParsers.withSecondsUTC.date(from: value) { return date }
            if let date = PlayoffTiersDateParsers.withFractionalSeconds.date(from: value) { return date }
            if let date = PlayoffTiersDateParsers.isoBasic.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try container.singleValueContainer(),
                                                    debugDescription: "Cannot parse date: \(value)")
        }
        return decoder
    }
}

// MARK: - Tournament ID Helper

extension PlayoffTiersTournament {
    /// Generate a tournament ID based on the current NBA season
    static func currentSeasonID() -> String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        // NBA playoffs happen April-June, so if we're in Jan-June it's the current year's playoffs
        // If July-Dec, it would be next year's playoffs (preseason)
        return "nba-playoffs-\(year)"
    }

    static func currentSeasonTitle() -> String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        return "\(year) NBA Playoff Tiers"
    }

    static func currentSeason() -> String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        return "\(year)"
    }
}
