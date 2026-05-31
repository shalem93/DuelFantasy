import Foundation

// MARK: - Soccer League Configuration

enum SoccerLeague: String, Sendable {
    case epl = "eng.1"
    case ucl = "uefa.champions"
    case worldCup = "fifa.world"

    var displayName: String {
        switch self {
        case .epl: return "EPL"
        case .ucl: return "UCL"
        case .worldCup: return "WC"
        }
    }

    var tournamentIDPrefix: String {
        switch self {
        case .epl: return "epl-"
        case .ucl: return "ucl-"
        case .worldCup: return "wc-"
        }
    }

    var playerIDPrefix: String {
        switch self {
        case .epl: return "epl-"
        case .ucl: return "ucl-"
        case .worldCup: return "wc-"
        }
    }
}

// MARK: - ESPN Soccer Scoreboard Codable Models

private struct SoccerScoreboardResponse: Codable, Sendable {
    let events: [SoccerScoreboardEvent]
}

private struct SoccerScoreboardEvent: Codable, Sendable {
    let id: String
    let name: String?
    let shortName: String?
    let date: String
    let competitions: [SoccerScoreboardCompetition]
    let status: SoccerEventStatus
}

private struct SoccerScoreboardCompetition: Codable, Sendable {
    let id: String?
    let competitors: [SoccerScoreboardCompetitor]
    let status: SoccerCompetitionStatus?
}

private struct SoccerScoreboardCompetitor: Codable, Sendable {
    let id: String
    let homeAway: String
    let team: SoccerTeamRef
    let score: String?
}

private struct SoccerTeamRef: Codable, Sendable {
    let id: String
    let abbreviation: String
    let displayName: String?
    let shortDisplayName: String?
}

private struct SoccerEventStatus: Codable, Sendable {
    let type: SoccerEventStatusType
}

private struct SoccerEventStatusType: Codable, Sendable {
    let state: String      // "pre", "in", "post"
    let completed: Bool?
}

private struct SoccerCompetitionStatus: Codable, Sendable {
    let clock: Double?
    let displayClock: String?
    let period: Int?
    let type: SoccerEventStatusType?
}

// MARK: - ESPN Soccer Roster Codable Models

private struct SoccerRosterResponse: Codable {
    let athletes: [SoccerRosterAthlete]?
    // ESPN soccer roster sometimes groups by position category
    let team: SoccerRosterTeam?
}

private struct SoccerRosterTeam: Codable {
    let id: String?
    let abbreviation: String?
}

private struct SoccerRosterAthlete: Codable {
    let id: String
    let fullName: String?
    let displayName: String?
    let position: SoccerRosterPosition?
    let injuries: [SoccerRosterInjury]?
    let statistics: SoccerAthleteStatistics?

    struct SoccerAthleteStatistics: Codable {
        let splits: SoccerStatSplits?
    }

    struct SoccerStatSplits: Codable {
        let categories: [SoccerStatCategory]?
    }

    struct SoccerStatCategory: Codable {
        let name: String?
        let stats: [SoccerStatEntry]?
    }

    struct SoccerStatEntry: Codable {
        let name: String?
        let value: Double?
    }
}

private struct SoccerRosterPosition: Codable {
    let abbreviation: String?
    let displayName: String?
    let name: String?
}

private struct SoccerRosterInjury: Codable {
    let status: String?
}

// MARK: - ESPN Soccer Slate Provider

/// Simple in-memory slate cache for soccer providers
private final class SoccerSlateCache {
    static let shared = SoccerSlateCache()
    private var slates: [String: (slate: DFSSlate, fetchedAt: Date)] = [:]
    private let ttl: TimeInterval = 300 // 5 minutes

    func get(key: String) -> DFSSlate? {
        guard let entry = slates[key],
              Date().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry.slate
    }

    func set(_ slate: DFSSlate, key: String) {
        slates[key] = (slate, Date())
    }
}

struct ESPNSoccerDFSSlateProvider: DFSSlateProvider {
    let league: SoccerLeague
    private let session: URLSession

    init(league: SoccerLeague, session: URLSession = .shared) {
        self.league = league
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        let cacheKey = league.displayName.lowercased()
        if let cached = SoccerSlateCache.shared.get(key: cacheKey) {
            return cached
        }

        // 1. Fetch today's fixtures
        let events = try await fetchTodayFixtures()
        guard !events.isEmpty else {
            throw NSError(domain: "SoccerDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No \(league.displayName) fixtures found today"])
        }

        // 2. Build team abbreviation → event ID mapping
        var teamToGameID: [String: String] = [:]
        var teamRefs: [(id: String, abbreviation: String)] = []
        var seenTeamIDs = Set<String>()
        for event in events {
            guard let competition = event.competitions.first else { continue }
            for competitor in competition.competitors {
                teamToGameID[competitor.team.abbreviation] = event.id
                if !seenTeamIDs.contains(competitor.team.id) {
                    seenTeamIDs.insert(competitor.team.id)
                    teamRefs.append((id: competitor.team.id, abbreviation: competitor.team.abbreviation))
                }
            }
        }

        // 3. Fetch all rosters in parallel
        let allPlayers: [DFSPlayer] = try await withThrowingTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let gameID = teamToGameID[team.abbreviation]
                group.addTask {
                    return try await self.fetchRoster(
                        teamID: team.id,
                        teamAbbreviation: team.abbreviation,
                        gameID: gameID
                    )
                }
            }
            var players: [DFSPlayer] = []
            for try await roster in group {
                players.append(contentsOf: roster)
            }
            return players
        }

        guard !allPlayers.isEmpty else {
            throw NSError(domain: "SoccerDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No \(league.displayName) players available"])
        }

        // 3b. Fetch confirmed starters AND recently active players in parallel
        let teamIDs = teamRefs.map(\.id)
        async let confirmedIDsTask = fetchConfirmedStarterIDs(events: events)
        async let recentlyActiveIDsTask = fetchRecentlyActivePlayerIDs(teamIDs: teamIDs)

        let confirmedIDs = await confirmedIDsTask
        let recentlyActiveIDs = await recentlyActiveIDsTask

        var markedPlayers: [DFSPlayer]
        if !confirmedIDs.isEmpty {
            markedPlayers = allPlayers.map { p in
                var player = p
                player.isConfirmedActive = confirmedIDs.contains(p.id)
                if !recentlyActiveIDs.isEmpty {
                    player.playedRecently = recentlyActiveIDs.contains(p.id)
                }
                return player
            }
            let starterCount = markedPlayers.filter { $0.isConfirmedActive }.count
            print("[Soccer-DFS] Confirmed starters: \(starterCount)/\(markedPlayers.count) players marked from \(events.count) events")
        } else {
            // No lineup data available yet — keep all as unconfirmed
            markedPlayers = allPlayers.map { p in
                var player = p
                player.isConfirmedActive = false
                if !recentlyActiveIDs.isEmpty {
                    player.playedRecently = recentlyActiveIDs.contains(p.id)
                }
                return player
            }
            print("[Soccer-DFS] No confirmed lineups available yet — all \(markedPlayers.count) players unmarked")
        }

        // 4. Build included games
        let includedGames: [DFSSlateGame] = events.compactMap { event in
            guard let competition = event.competitions.first else { return nil }
            guard let away = competition.competitors.first(where: { $0.homeAway == "away" }) else { return nil }
            guard let home = competition.competitors.first(where: { $0.homeAway == "home" }) else { return nil }
            let startDate = parseESPNDate(event.date) ?? Date()
            return DFSSlateGame(
                id: event.id,
                awayTeam: away.team.abbreviation,
                homeTeam: home.team.abbreviation,
                startTime: startDate,
                state: event.status.type.state
            )
        }

        // 5. Build tournaments using shared builder
        let slateDate = parseESPNDate(events.first?.date ?? "") ?? Date()
        let tournamentID = "\(league.tournamentIDPrefix)\(dateKey(for: slateDate))"
        let isSingleGame = includedGames.count == 1
        let sortedPlayers = markedPlayers.sorted(by: { $0.salary > $1.salary })

        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: league.displayName,
            mainSalaryCap: 50000,
            mainLineupSize: 8,
            mainRosterSlots: ["GK", "DEF", "DEF", "MID", "MID", "FWD", "FWD", "FLEX"],
            isSingleGameSlate: isSingleGame,
            includedGames: includedGames,
            mainPlayers: sortedPlayers
        )

        let slate = DFSSlate(
            tournaments: tournaments,
            includedGames: includedGames,
            players: sortedPlayers,
            singleGamePlayers: sgPlayers
        )
        SoccerSlateCache.shared.set(slate, key: cacheKey)
        return slate
    }

    // MARK: - Fetch Confirmed Starters

    /// Fetches event summary for each game and extracts confirmed starter athlete IDs.
    /// ESPN populates the "rosters" array with "starter": true once lineups are announced
    /// (typically ~1 hour before kickoff). Returns player IDs in the format "epl-{athleteID}".
    private func fetchConfirmedStarterIDs(events: [SoccerScoreboardEvent]) async -> Set<String> {
        await withTaskGroup(of: Set<String>.self) { group in
            for event in events {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(self.league.rawValue)/summary?event=\(event.id)") else {
                        return []
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let rostersArr = payload["rosters"] as? [[String: Any]] else {
                        return []
                    }

                    var ids = Set<String>()
                    for rosterBlock in rostersArr {
                        guard let entries = rosterBlock["roster"] as? [[String: Any]] else { continue }
                        for entry in entries {
                            let isStarter = entry["starter"] as? Bool ?? false
                            let subbedIn = entry["subbedIn"] as? Bool ?? false
                            guard isStarter || subbedIn else { continue }
                            guard let athleteDict = entry["athlete"] as? [String: Any],
                                  let athleteID = athleteDict["id"] as? String else { continue }
                            ids.insert("\(self.league.playerIDPrefix)\(athleteID)")
                        }
                    }
                    return ids
                }
            }

            var allIDs = Set<String>()
            for await ids in group {
                allIDs.formUnion(ids)
            }
            return allIDs
        }
    }

    // MARK: - Fetch Today's Fixtures

    private func fetchTodayFixtures() async throws -> [SoccerScoreboardEvent] {
        // Look back 1 day (catches just-finished games) and forward up to 10
        // days. UCL knockout / final stages can be 3-6 days away with no
        // intermediate fixtures, and World Cup rest days between knockout
        // rounds can stretch to 5-7 days — a narrow window misses those.
        let calendarBase = Calendar.current
        var dateKeys: [String] = []
        for offset in -1...10 {
            if let date = calendarBase.date(byAdding: .day, value: offset, to: Date()) {
                dateKeys.append(dateKey(for: date))
            }
        }

        let allScoreboards: [SoccerScoreboardResponse] = await withTaskGroup(of: SoccerScoreboardResponse?.self) { group in
            for dk in dateKeys {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(self.league.rawValue)/scoreboard?dates=\(dk)") else {
                        return nil
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return nil
                    }
                    return try? JSONDecoder().decode(SoccerScoreboardResponse.self, from: data)
                }
            }
            var results: [SoccerScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var preEvents: [SoccerScoreboardEvent] = []
        var liveEvents: [SoccerScoreboardEvent] = []
        var postEvents: [SoccerScoreboardEvent] = []

        for scoreboard in allScoreboards {
            for event in scoreboard.events {
                let state = event.status.type.state
                let eventDate = parseESPNDate(event.date) ?? Date()
                if state == "pre" && calendar.startOfDay(for: eventDate) >= today {
                    preEvents.append(event)
                } else if state == "in" {
                    liveEvents.append(event)
                } else if state == "post" {
                    postEvents.append(event)
                }
            }
        }

        // If there are live games, include them + same-day post/pre
        if !liveEvents.isEmpty {
            let liveDay = calendar.startOfDay(for: parseESPNDate(liveEvents.first!.date) ?? Date())
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: parseESPNDate($0.date) ?? Date()) == liveDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: parseESPNDate($0.date) ?? Date()) == liveDay }
            return (liveEvents + sameDayPost + sameDayPre).sorted { (parseESPNDate($0.date) ?? Date()) < (parseESPNDate($1.date) ?? Date()) }
        }

        // Upcoming games: include all same-day pre + any same-day post (finished earlier)
        if !preEvents.isEmpty {
            let earliestPreDay = preEvents.compactMap { parseESPNDate($0.date) }.map { calendar.startOfDay(for: $0) }.min()!
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: parseESPNDate($0.date) ?? Date()) == earliestPreDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: parseESPNDate($0.date) ?? Date()) == earliestPreDay }
            if !sameDayPost.isEmpty {
                return (sameDayPre + sameDayPost).sorted { (parseESPNDate($0.date) ?? Date()) < (parseESPNDate($1.date) ?? Date()) }
            }
            return sameDayPre.sorted { (parseESPNDate($0.date) ?? Date()) < (parseESPNDate($1.date) ?? Date()) }
        }

        // Today's post events (all games finished)
        let todayPost = postEvents.filter { calendar.startOfDay(for: parseESPNDate($0.date) ?? Date()) == today }
        if !todayPost.isEmpty { return todayPost }

        return []
    }

    // MARK: - Fetch Roster

    private func fetchRoster(teamID: String, teamAbbreviation: String, gameID: String?) async throws -> [DFSPlayer] {
        let urlString = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league.rawValue)/teams/\(teamID)/roster"
        guard let url = URL(string: urlString) else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("[Soccer-DFS] Failed to fetch roster for team \(teamAbbreviation) (\(teamID))")
            return []
        }

        // ESPN soccer roster can be structured differently than basketball
        // Try parsing as a flat athletes array first, then handle grouped format
        let athletes: [SoccerRosterAthlete]
        if let rosterResponse = try? JSONDecoder().decode(SoccerRosterResponse.self, from: data),
           let athleteArray = rosterResponse.athletes {
            athletes = athleteArray
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Handle grouped format: { "athletes": [ { "position": "Goalkeepers", "items": [...] }, ... ] }
            athletes = parseSoccerRosterJSON(json)
        } else {
            print("[Soccer-DFS] Could not parse roster for team \(teamAbbreviation)")
            return []
        }

        // Map athletes to DFSPlayer — include full squad so all positions are represented
        var players: [DFSPlayer] = []
        for athlete in athletes {
            let name = athlete.displayName ?? athlete.fullName ?? "Player"
            let rawPosition = athlete.position?.abbreviation
                ?? athlete.position?.displayName
                ?? athlete.position?.name
                ?? "MID"
            let dfsPosition = mapSoccerPosition(rawPosition)
            let athleteID = athlete.id

            // Extract season stats for salary generation
            let seasonStats = extractSeasonStats(athlete)
            let salary = generateSoccerSalary(
                position: dfsPosition,
                goals: seasonStats.goals,
                assists: seasonStats.assists,
                appearances: seasonStats.appearances,
                athleteID: athleteID
            )
            let projection = projectedSoccerPoints(
                position: dfsPosition,
                salary: salary,
                athleteID: athleteID
            )

            players.append(DFSPlayer(
                id: "\(league.playerIDPrefix)\(athleteID)",
                name: name,
                team: teamAbbreviation,
                position: dfsPosition,
                salary: salary,
                projectedPoints: projection,
                gameID: gameID
            ))
        }

        return players.sorted(by: { $0.salary > $1.salary })
    }

    // MARK: - Roster JSON Parsing (grouped format)

    private func parseSoccerRosterJSON(_ json: [String: Any]) -> [SoccerRosterAthlete] {
        guard let athleteGroups = json["athletes"] as? [[String: Any]] else { return [] }

        var athletes: [SoccerRosterAthlete] = []
        for group in athleteGroups {
            guard let items = group["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let id = item["id"] as? String ?? (item["id"] as? Int).map({ String($0) }) else { continue }
                let fullName = item["fullName"] as? String ?? item["displayName"] as? String
                let displayName = item["displayName"] as? String ?? fullName

                var posAbbrev: String? = nil
                if let posDict = item["position"] as? [String: Any] {
                    posAbbrev = posDict["abbreviation"] as? String ?? posDict["displayName"] as? String
                }

                // Also try top-level group position (e.g., "Goalkeepers", "Defenders")
                if posAbbrev == nil, let groupPos = group["position"] as? String {
                    posAbbrev = groupPos
                }

                athletes.append(SoccerRosterAthlete(
                    id: id,
                    fullName: fullName,
                    displayName: displayName,
                    position: posAbbrev.map { SoccerRosterPosition(abbreviation: $0, displayName: nil, name: nil) },
                    injuries: nil,
                    statistics: nil
                ))
            }
        }
        return athletes
    }

    // MARK: - Season Stats Extraction

    private struct SeasonStats {
        let goals: Int
        let assists: Int
        let appearances: Int
    }

    private func extractSeasonStats(_ athlete: SoccerRosterAthlete) -> SeasonStats {
        var goals = 0, assists = 0, appearances = 0
        if let categories = athlete.statistics?.splits?.categories {
            for category in categories {
                guard let stats = category.stats else { continue }
                for stat in stats {
                    switch stat.name?.lowercased() {
                    case "totalgoals", "goals": goals = Int(stat.value ?? 0)
                    case "goalassists", "assists": assists = Int(stat.value ?? 0)
                    case "appearances", "gamesplayed": appearances = Int(stat.value ?? 0)
                    default: break
                    }
                }
            }
        }
        return SeasonStats(goals: goals, assists: assists, appearances: appearances)
    }

    // MARK: - Position Mapping

    private func mapSoccerPosition(_ raw: String) -> String {
        let upper = raw.uppercased().trimmingCharacters(in: .whitespaces)
        // Goalkeeper variants
        if upper == "G" || upper == "GK" || upper.contains("GOALKEEPER") || upper.contains("KEEPER") {
            return "GK"
        }
        // Defender variants
        if upper == "D" || upper == "DEF" || upper == "CB" || upper == "LB" || upper == "RB"
            || upper == "LWB" || upper == "RWB" || upper.contains("DEFENDER") || upper.contains("BACK") {
            return "DEF"
        }
        // Midfielder variants
        if upper == "M" || upper == "MID" || upper == "CM" || upper == "CAM" || upper == "CDM"
            || upper == "LM" || upper == "RM" || upper == "AM" || upper == "DM"
            || upper.contains("MIDFIELDER") || upper.contains("MIDFIELD") {
            return "MID"
        }
        // Forward variants
        if upper == "F" || upper == "FWD" || upper == "ST" || upper == "CF" || upper == "LW" || upper == "RW"
            || upper == "SS" || upper.contains("FORWARD") || upper.contains("STRIKER") || upper.contains("WINGER") {
            return "FWD"
        }
        return "MID" // default fallback
    }

    // MARK: - Salary Generation

    private func generateSoccerSalary(position: String, goals: Int, assists: Int, appearances: Int, athleteID: String) -> Int {
        // Compute pseudo-FPPG from season stats
        let effectiveApps = max(1, appearances)
        let rawFPPG = (Double(goals) * 10.0 + Double(assists) * 6.0) / Double(effectiveApps)

        // Position-tiered salary ranges
        let (minSal, maxSal): (Int, Int)
        switch position {
        case "GK":  (minSal, maxSal) = (3500, 6000)
        case "DEF": (minSal, maxSal) = (3500, 7500)
        case "MID": (minSal, maxSal) = (3500, 9500)
        case "FWD": (minSal, maxSal) = (4000, 10500)
        default:    (minSal, maxSal) = (3500, 9500)
        }

        // Map FPPG to salary range. Top FPPG ~15 (elite FWD: 25 goals + 10 assists in 35 apps)
        // Clamp fraction for players with extreme stats
        let maxFPPG: Double
        switch position {
        case "GK": maxFPPG = 3.0     // GK rarely score
        case "DEF": maxFPPG = 5.0
        case "MID": maxFPPG = 10.0
        case "FWD": maxFPPG = 15.0
        default: maxFPPG = 10.0
        }
        let fraction = min(1.0, max(0, rawFPPG / maxFPPG))
        let curved = pow(fraction, 0.7)  // slight boost to lower-end players
        let baseSalary = minSal + Int(curved * Double(maxSal - minSal))

        // Stable per-player jitter (±$100) from athlete ID hash
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = (abs(stableHash) % 200) - 100

        let salary = max(minSal, min(maxSal, baseSalary + jitter))
        return (salary / 100) * 100 // round to nearest $100
    }

    // MARK: - Projected Points

    private func projectedSoccerPoints(position: String, salary: Int, athleteID: String) -> Double {
        // Map salary to projected FPTS: $3,500 ~ 5 FPTS, $10,500 ~ 25 FPTS
        let salaryFraction = Double(salary - 3500) / Double(10500 - 3500)
        let base = 5.0 + pow(max(0, salaryFraction), 0.85) * 20.0

        // Stable per-player jitter (±8%)
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitterFraction = (Double(abs(stableHash) % 160) - 80.0) / 1000.0
        let adjusted = base * (1.0 + jitterFraction)
        return (adjusted * 10).rounded() / 10
    }

    // MARK: - Recency Filtering

    /// Fetch the set of player IDs who appeared in recent matches (last ~10 days)
    /// for the teams playing tonight. Uses the same event summary rosters endpoint
    /// as fetchConfirmedStarterIDs but for past matches.
    func fetchRecentlyActivePlayerIDs(teamIDs: [String]) async -> Set<String> {
        let calendar = Calendar.current
        // Fetch scoreboards from the past 10 days to find recent completed matches
        let datesToCheck = (-10...(-1)).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
        let dateStrings = datesToCheck.map { dateKey(for: $0) }

        // Fetch all recent scoreboards in parallel (batch by 3-day chunks to reduce calls)
        let recentScoreboards: [SoccerScoreboardResponse] = await withTaskGroup(of: SoccerScoreboardResponse?.self) { group in
            for dk in dateStrings {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(self.league.rawValue)/scoreboard?dates=\(dk)") else { return nil }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    return try? JSONDecoder().decode(SoccerScoreboardResponse.self, from: data)
                }
            }
            var results: [SoccerScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        // Find completed events involving tonight's teams
        let teamIDSet = Set(teamIDs)
        var recentEventIDs: Set<String> = []
        for sb in recentScoreboards {
            for event in sb.events {
                let state = event.status.type.state
                guard state == "post" else { continue }
                guard let comp = event.competitions.first else { continue }
                let eventTeamIDs = comp.competitors.map { $0.id }
                if eventTeamIDs.contains(where: { teamIDSet.contains($0) }) {
                    recentEventIDs.insert(event.id)
                }
            }
        }

        guard !recentEventIDs.isEmpty else { return [] }

        // Fetch rosters from each recent event to find who played
        let activeIDs: Set<String> = await withTaskGroup(of: Set<String>.self) { group in
            for eventID in recentEventIDs {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(self.league.rawValue)/summary?event=\(eventID)") else {
                        return []
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let rostersArr = payload["rosters"] as? [[String: Any]] else {
                        return []
                    }

                    var ids = Set<String>()
                    for rosterBlock in rostersArr {
                        guard let entries = rosterBlock["roster"] as? [[String: Any]] else { continue }
                        for entry in entries {
                            let isStarter = entry["starter"] as? Bool ?? false
                            let subbedIn = entry["subbedIn"] as? Bool ?? false
                            guard isStarter || subbedIn else { continue }
                            guard let athleteDict = entry["athlete"] as? [String: Any],
                                  let athleteID = athleteDict["id"] as? String else { continue }
                            // Store with league prefix to match DFSPlayer.id format
                            ids.insert("\(self.league.playerIDPrefix)\(athleteID)")
                        }
                    }
                    return ids
                }
            }
            var combined = Set<String>()
            for await ids in group {
                combined.formUnion(ids)
            }
            return combined
        }

        print("[Soccer-DFS] Found \(activeIDs.count) recently active players from \(recentEventIDs.count) recent matches (last 10 days)")
        return activeIDs
    }

    // MARK: - Helpers

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter.string(from: date)
    }

    private func parseESPNDate(_ dateString: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: dateString) { return date }
        let iso2 = ISO8601DateFormatter()
        if let date = iso2.date(from: dateString) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) { return date }
        }
        return nil
    }
}

// MARK: - ESPN Soccer Live Scoring Provider

struct ESPNSoccerDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    let league: SoccerLeague
    private let session: URLSession

    init(league: SoccerLeague, session: URLSession = .shared) {
        self.league = league
        self.session = session
    }

    private struct GameFetchResult: Sendable {
        let gameID: String
        let gameInfo: DFSGameLiveInfo
        let playerResults: [(String, Double, DFSPlayerLiveStats)]
        let isFinal: Bool
        let homeScore: Int
        let awayScore: Int
        /// Maps team abbreviation → set of athlete IDs on that team
        let teamRosters: [String: Set<String>]
    }

    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        let results: [GameFetchResult] = await withTaskGroup(of: GameFetchResult?.self) { group in
            for game in games {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(self.league.rawValue)/summary?event=\(game.id)") else {
                        return nil
                    }

                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        print("[Soccer-Score] Failed to fetch summary for event \(game.id)")
                        return nil
                    }

                    let gameInfo = self.extractGameLiveInfo(payload: payload, game: game)
                    let gameFinal = gameInfo.state == "post"

                    let playerResults: [(String, Double, DFSPlayerLiveStats)]
                    let teamRosters: [String: Set<String>]
                    if gameInfo.state == "pre" {
                        playerResults = []
                        teamRosters = [:]
                    } else {
                        let (stats, rosters) = await self.extractSoccerPlayerStats(
                            payload: payload,
                            eventID: game.id,
                            gameStatus: gameInfo.displayStatus,
                            gameFinal: gameFinal,
                            homeTeam: game.homeTeam,
                            awayTeam: game.awayTeam,
                            homeScore: gameInfo.homeScore,
                            awayScore: gameInfo.awayScore
                        )
                        playerResults = stats
                        teamRosters = rosters
                    }

                    print("[Soccer-Score] Game \(game.id) (\(game.awayTeam)@\(game.homeTeam)): state=\(gameInfo.state), \(playerResults.count) players scored, final=\(gameFinal)")

                    return GameFetchResult(
                        gameID: game.id,
                        gameInfo: gameInfo,
                        playerResults: playerResults,
                        isFinal: gameFinal,
                        homeScore: gameInfo.homeScore,
                        awayScore: gameInfo.awayScore,
                        teamRosters: teamRosters
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

        let allGamesFinal = allFetchedAreFinal && !results.isEmpty && failedGames.count <= results.count

        print("[Soccer-Score] Total: \(results.count)/\(games.count) games fetched, \(pointsByPlayerID.count) player scores, failed=\(failedGames.count)")

        let snapshot = DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfoByID,
            allGamesFinal: allGamesFinal
        )
        return snapshot
    }

    // MARK: - Extract Game Live Info

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
            sportType: "soccer"
        )
    }

    // MARK: - Extract Player Stats

    nonisolated private func extractSoccerPlayerStats(
        payload: [String: Any],
        eventID: String,
        gameStatus: String,
        gameFinal: Bool,
        homeTeam: String,
        awayTeam: String,
        homeScore: Int,
        awayScore: Int
    ) async -> ([(String, Double, DFSPlayerLiveStats)], [String: Set<String>]) {
        // ESPN soccer summary uses top-level "rosters" array (NOT boxscore.players)
        guard let rostersArr = payload["rosters"] as? [[String: Any]] else {
            print("[Soccer-Score] No 'rosters' key in payload")
            return ([], [:])
        }

        // Defensive stats (tackles/ints/blocks/clearances) aren't in the
        // summary payload — fetch them per-player from ESPN's core-API stats
        // endpoint. Collect (athleteID, teamID) pairs in the first pass, then
        // fan out in parallel, then build the final result with merged stats.
        var defensiveStatsByPlayerID: [String: (tackles: Int, interceptions: Int, blockedShots: Int, clearances: Int)] = [:]
        var defensiveFetchInputs: [(playerID: String, athleteID: String, teamID: String)] = []
        for rosterBlock in rostersArr {
            let teamDict = rosterBlock["team"] as? [String: Any]
            guard let teamID = teamDict?["id"] as? String else { continue }
            guard let rosterEntries = rosterBlock["roster"] as? [[String: Any]] else { continue }
            for entry in rosterEntries {
                let isActive = entry["active"] as? Bool ?? false
                let isStarter = entry["starter"] as? Bool ?? false
                let subbedIn = entry["subbedIn"] as? Bool ?? false
                guard isActive || isStarter || subbedIn else { continue }
                guard let athleteDict = entry["athlete"] as? [String: Any],
                      let athleteID = athleteDict["id"] as? String else { continue }
                let playerID = "\(self.league.playerIDPrefix)\(athleteID)"
                defensiveFetchInputs.append((playerID, athleteID, teamID))
            }
        }
        await withTaskGroup(of: (String, (Int, Int, Int, Int))?.self) { group in
            for input in defensiveFetchInputs {
                group.addTask {
                    let stats = await self.fetchSoccerDefensiveStatsLive(
                        eventID: eventID, teamID: input.teamID, athleteID: input.athleteID
                    )
                    return (input.playerID, stats)
                }
            }
            for await result in group {
                if let (pid, s) = result {
                    defensiveStatsByPlayerID[pid] = (s.0, s.1, s.2, s.3)
                }
            }
        }

        var results: [(String, Double, DFSPlayerLiveStats)] = []
        var teamRosters: [String: Set<String>] = [:]

        for rosterBlock in rostersArr {
            let teamDict = rosterBlock["team"] as? [String: Any]
            let teamAbbrev = teamDict?["abbreviation"] as? String ?? ""
            let homeAway = rosterBlock["homeAway"] as? String ?? ""

            // Determine if this team kept a clean sheet and if team won
            let isHomeTeam = homeAway == "home"
            let teamScore = isHomeTeam ? homeScore : awayScore
            let opposingScore = isHomeTeam ? awayScore : homeScore
            let cleanSheet = gameFinal && opposingScore == 0
            let teamWon = gameFinal && teamScore > opposingScore

            guard let rosterEntries = rosterBlock["roster"] as? [[String: Any]] else { continue }

            for entry in rosterEntries {
                let isActive = entry["active"] as? Bool ?? false
                let isStarter = entry["starter"] as? Bool ?? false
                let subbedIn = entry["subbedIn"] as? Bool ?? false
                let subbedOut = entry["subbedOut"] as? Bool ?? false

                // Skip players who didn't participate
                guard isActive || isStarter || subbedIn else { continue }

                guard let athleteDict = entry["athlete"] as? [String: Any],
                      let athleteID = athleteDict["id"] as? String else { continue }

                let athleteName = (athleteDict["displayName"] as? String)
                    ?? (athleteDict["shortName"] as? String)
                    ?? "Player \(athleteID)"

                let playerID = "\(league.playerIDPrefix)\(athleteID)"

                // Track team roster
                teamRosters[teamAbbrev, default: []].insert(playerID)

                // Get position
                let posDict = entry["position"] as? [String: Any]
                let posAbbrev = posDict?["abbreviation"] as? String
                    ?? posDict?["displayName"] as? String
                    ?? "MID"
                let dfsPosition = mapPosition(posAbbrev)

                // Parse stats: each stat is {name: String, value: Double, displayValue: String}
                let statsArr = entry["stats"] as? [[String: Any]] ?? []
                var statMap: [String: Double] = [:]
                for stat in statsArr {
                    if let name = stat["name"] as? String {
                        let value = stat["value"] as? Double
                            ?? (stat["displayValue"] as? String).flatMap { Double($0) }
                            ?? 0
                        statMap[name] = value
                    }
                }

                let goals = Int(statMap["totalGoals"] ?? 0)
                let assists = Int(statMap["goalAssists"] ?? 0)
                let shotsOnTarget = Int(statMap["shotsOnTarget"] ?? 0)
                let totalShots = Int(statMap["totalShots"] ?? 0)
                let saves = Int(statMap["saves"] ?? 0)
                let yellowCards = Int(statMap["yellowCards"] ?? 0)
                let redCards = Int(statMap["redCards"] ?? 0)
                let foulsDrawn = Int(statMap["foulsSuffered"] ?? 0)
                let goalsAgainst = Int(statMap["goalsConceded"] ?? 0)
                // Defensive stats come from the per-player core-API fetch we
                // did above — the `/summary` payload doesn't expose them.
                let defStats = defensiveStatsByPlayerID[playerID] ?? (tackles: 0, interceptions: 0, blockedShots: 0, clearances: 0)
                let interceptions = defStats.interceptions
                let blockedShots = defStats.blockedShots
                let clearances = defStats.clearances

                // Estimate minutes played from substitution events in "plays" array
                var minutesPlayed = 0
                let plays = entry["plays"] as? [[String: Any]] ?? []

                // Helper to parse clock strings like "72'" or "90'+3'"
                func parseMinute(_ displayVal: String) -> Int? {
                    // Take the base minute before any stoppage time indicator
                    let cleaned = displayVal.components(separatedBy: "'").first ?? displayVal
                    return Int(cleaned)
                }

                if isStarter && !subbedOut {
                    minutesPlayed = 90
                } else if isStarter && subbedOut {
                    if let subPlay = plays.first(where: { $0["substitution"] as? Bool == true }),
                       let clock = subPlay["clock"] as? [String: Any],
                       let displayVal = clock["displayValue"] as? String,
                       let minute = parseMinute(displayVal) {
                        minutesPlayed = minute
                    } else {
                        minutesPlayed = 60
                    }
                } else if subbedIn {
                    if let subPlay = plays.first(where: { $0["substitution"] as? Bool == true }),
                       let clock = subPlay["clock"] as? [String: Any],
                       let displayVal = clock["displayValue"] as? String,
                       let minute = parseMinute(displayVal) {
                        minutesPlayed = max(1, 90 - minute)
                    } else {
                        minutesPlayed = 25
                    }
                }

                // Tackles also come from the core-API stats fetch (statMap
                // doesn't include them — verified against PSG@MUN payload).
                let tackles = defStats.tackles

                // Compute fantasy points
                let fantasy = computeSoccerFantasyPoints(
                    position: dfsPosition,
                    goals: goals,
                    assists: assists,
                    shotsOnTarget: shotsOnTarget,
                    totalShots: totalShots,
                    tackles: tackles,
                    interceptions: interceptions,
                    blockedShots: blockedShots,
                    clearances: clearances,
                    saves: saves,
                    yellowCards: yellowCards,
                    redCards: redCards,
                    foulsDrawn: foulsDrawn,
                    goalsAgainst: goalsAgainst,
                    cleanSheet: cleanSheet,
                    gameFinal: gameFinal,
                    teamWon: teamWon
                )

                // Map stats to DFSPlayerLiveStats fields:
                // points → goals, assists → assists, rebounds → shots on target
                // steals → tackles, blocks → saves, ftm → yellow cards, fta → red cards
                let liveStats = DFSPlayerLiveStats(
                    name: athleteName,
                    points: goals,
                    rebounds: shotsOnTarget,
                    assists: assists,
                    steals: tackles,
                    blocks: saves,
                    turnovers: totalShots,
                    minutes: "\(dfsPosition):\(minutesPlayed)'",
                    fgm: foulsDrawn,
                    fga: goalsAgainst,
                    threePM: 0,
                    threePA: 0,
                    ftm: yellowCards,
                    fta: redCards,
                    fantasyPoints: fantasy,
                    gameStatus: gameStatus,
                    gameFinal: gameFinal
                )

                results.append((playerID, fantasy, liveStats))
            }
        }

        print("[Soccer-Score] Extracted \(results.count) player stats from rosters")
        return (results, teamRosters)
    }

    // MARK: - Soccer Fantasy Scoring (FanDuel-style)

    nonisolated private func computeSoccerFantasyPoints(
        position: String,
        goals: Int,
        assists: Int,
        shotsOnTarget: Int,
        totalShots: Int,
        tackles: Int,
        interceptions: Int,
        blockedShots: Int,
        clearances: Int,
        saves: Int,
        yellowCards: Int,
        redCards: Int,
        foulsDrawn: Int,
        goalsAgainst: Int,
        cleanSheet: Bool,
        gameFinal: Bool,
        teamWon: Bool
    ) -> Double {
        var pts = 0.0

        // --- All outfield players (DEF / MID / FWD) ---
        // Goal: +15
        pts += Double(goals) * 15.0

        // Assist: +7
        pts += Double(assists) * 7.0

        // Shot on Goal: +4
        pts += Double(shotsOnTarget) * 4.0

        // Shot (total, not on target): +1
        // Only count non-on-target shots to avoid double counting with SOT
        let nonTargetShots = max(0, totalShots - shotsOnTarget)
        pts += Double(nonTargetShots) * 1.0

        // Tackle: +1.6
        pts += Double(tackles) * 1.6

        // Foul Drawn: +1
        pts += Double(foulsDrawn) * 1.0

        // Yellow Card: -1
        pts -= Double(yellowCards) * 1.0

        // Red Card: -3
        pts -= Double(redCards) * 3.0

        // Defensive actions — applied to every position but disproportionately
        // benefit DEF/CDM players who rack these up without scoring goals.
        // Without these, centre-backs averaged ~1.7 FPTS and were unplayable.
        pts += Double(interceptions) * 1.0
        pts += Double(blockedShots) * 1.5
        pts += Double(clearances) * 0.3

        // --- Defenders only ---
        if position == "DEF" {
            // Clean Sheet: +5 (only when match is final)
            if cleanSheet && gameFinal {
                pts += 5.0
            }
            // Goal Against: -0.6
            pts -= Double(goalsAgainst) * 0.6
        }

        // --- Goalkeeper ---
        if position == "GK" {
            // Save: +2.5
            pts += Double(saves) * 2.5

            // Clean Sheet: +8 (only when match is final)
            if cleanSheet && gameFinal {
                pts += 8.0
            }

            // Win Bonus: +6 (only when match is final and team won)
            if gameFinal && teamWon {
                pts += 6.0
            }

            // Goal Against: -2.5
            pts -= Double(goalsAgainst) * 2.5
        }

        return pts
    }

    // MARK: - Defensive Stats Fetch

    /// Fetches a single player's defensive stats for one event from ESPN's
    /// core-API. The `/summary?event=` endpoint we use for the main payload
    /// omits these stats entirely, so we make a separate request per player.
    /// Returns zeros on any failure so callers degrade gracefully.
    nonisolated private func fetchSoccerDefensiveStatsLive(
        eventID: String,
        teamID: String,
        athleteID: String
    ) async -> (tackles: Int, interceptions: Int, blockedShots: Int, clearances: Int) {
        let urlString = "https://sports.core.api.espn.com/v2/sports/soccer/leagues/\(self.league.rawValue)/events/\(eventID)/competitions/\(eventID)/competitors/\(teamID)/roster/\(athleteID)/statistics/0"
        guard let url = URL(string: urlString) else { return (0, 0, 0, 0) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await self.session.data(for: request),
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
        // Match the past-gamelog fetcher: prefer `total*` over `effective*`
        // so attempted-but-failed actions still earn partial credit.
        let tackles = Int(values["totalTackles"] ?? values["effectiveTackles"] ?? 0)
        let interceptions = Int(values["interceptions"] ?? 0)
        let blockedShots = Int(values["blockedShots"] ?? 0)
        let clearances = Int(values["totalClearance"] ?? values["effectiveClearance"] ?? 0)
        return (tackles, interceptions, blockedShots, clearances)
    }

    // MARK: - Position Helper

    nonisolated private func mapPosition(_ raw: String) -> String {
        let upper = raw.uppercased().trimmingCharacters(in: .whitespaces)
        // Strip dash-suffix for compound abbreviations (e.g. "CD-L" → "CD", "AM-R" → "AM", "CF-L" → "CF")
        let base = upper.components(separatedBy: "-").first ?? upper

        if base == "G" || base == "GK" || upper.contains("GOALKEEPER") || upper.contains("KEEPER") { return "GK" }
        if base == "D" || base == "DEF" || base == "CB" || base == "CD" || base == "LB" || base == "RB"
            || base == "LWB" || base == "RWB" || upper.contains("DEFENDER") || upper.contains("BACK") { return "DEF" }
        if base == "M" || base == "MID" || base == "CM" || base == "CAM" || base == "CDM"
            || base == "LM" || base == "RM" || base == "AM" || base == "DM"
            || upper.contains("MIDFIELDER") || upper.contains("MIDFIELD") { return "MID" }
        if base == "F" || base == "FWD" || base == "ST" || base == "CF" || base == "LW" || base == "RW"
            || base == "SS" || upper.contains("FORWARD") || upper.contains("STRIKER") || upper.contains("WINGER") { return "FWD" }
        if base == "SUB" { return "MID" } // Substitute with unknown position defaults to MID
        return "MID"
    }
}
