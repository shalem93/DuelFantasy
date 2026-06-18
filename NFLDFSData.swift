import Foundation

// MARK: - NFL DFS Slate Provider

/// Simple in-memory cache for NFL slates (mirrors UFCSlateCache pattern)
private final class NFLSlateCache {
    static let shared = NFLSlateCache()
    private var cached: DFSSlate?
    private var cachedAt: Date?

    func get() -> DFSSlate? {
        guard let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < 300 else { return nil }
        return cached
    }

    func set(_ slate: DFSSlate) {
        cached = slate
        cachedAt = Date()
    }
}

struct ESPNNFLDFSSlateProvider: DFSSlateProvider {
    private let session: URLSession

    private static let nflDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            let formatters: [DateFormatter] = [
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"; return f }(),
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f }(),
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return f }(),
            ]
            for formatter in formatters {
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unsupported NFL date: \(value)"))
        }
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        if let cached = NFLSlateCache.shared.get() {
            return cached
        }

        // Start fetching real DraftKings salaries in parallel with ESPN data
        async let rgSalaries = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "nfl", maxClassicSalary: 10000)

        // 1. Fetch NFL events (games) across the relevant date window
        let events = try await fetchNFLEvents()
        guard !events.isEmpty else {
            throw NSError(domain: "NFLDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No NFL games found"])
        }

        // 2. Build included games and collect team references
        var includedGames: [DFSSlateGame] = []
        var teamRefs: [(id: String, abbreviation: String, displayName: String, gameID: String)] = []
        var seenTeamIDs = Set<String>()

        for event in events {
            guard let competition = event.competitions.first else { continue }
            let state = competition.status.type.state
            let startTime = event.date

            var awayAbbrev = ""
            var homeAbbrev = ""

            for competitor in competition.competitors {
                let teamID = competitor.team.id
                let teamAbbrev = competitor.team.abbreviation
                let teamName = competitor.team.displayName ?? competitor.team.shortDisplayName ?? teamAbbrev

                if competitor.homeAway == "away" { awayAbbrev = teamAbbrev }
                else { homeAbbrev = teamAbbrev }

                if !seenTeamIDs.contains(teamID) {
                    seenTeamIDs.insert(teamID)
                    teamRefs.append((id: teamID, abbreviation: teamAbbrev, displayName: teamName, gameID: event.id))
                }
            }

            includedGames.append(DFSSlateGame(
                id: event.id,
                awayTeam: awayAbbrev,
                homeTeam: homeAbbrev,
                startTime: startTime,
                state: state
            ))
        }

        // 3. Fetch team ratings (stats) in parallel for FPPG calculation
        let allRatings: [String: [String: (fppg: Double, gamesPlayed: Int)]] = await withTaskGroup(of: (String, [String: (fppg: Double, gamesPlayed: Int)]).self) { group in
            for team in teamRefs {
                group.addTask {
                    let ratings = await self.fetchNFLRatings(teamID: team.id)
                    return (team.id, ratings)
                }
            }
            var results: [String: [String: (fppg: Double, gamesPlayed: Int)]] = [:]
            for await (teamID, ratings) in group {
                results[teamID] = ratings
            }
            return results
        }

        // 4. Fetch team rosters in parallel and build player pool
        let allPlayers: [DFSPlayer] = await withTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let ratings = allRatings[team.id] ?? [:]
                group.addTask {
                    return await self.fetchNFLRoster(
                        teamID: team.id,
                        teamAbbreviation: team.abbreviation,
                        teamDisplayName: team.displayName,
                        gameID: team.gameID,
                        ratings: ratings
                    )
                }
            }
            var players: [DFSPlayer] = []
            for await roster in group {
                players.append(contentsOf: roster)
            }
            return players
        }

        guard !allPlayers.isEmpty else {
            throw NSError(domain: "NFLDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No NFL players available"])
        }

        // 5. Apply real DraftKings salaries from RotoGrinders where available
        let realSalaries = await rgSalaries
        let finalPlayers: [DFSPlayer]
        if !realSalaries.isEmpty {
            let matchCount = allPlayers.filter { RotoGrindersSalaryProvider.lookupSalary(espnName: $0.name, in: realSalaries) != nil }.count
            let matchRate = Double(matchCount) / Double(max(1, allPlayers.count))
            let sameSlate = matchRate > 0.30

            if sameSlate {
                let rgMin = realSalaries.values.min() ?? 3000
                let rgMax = realSalaries.values.max() ?? 10000
                let allProjs = allPlayers.map { $0.projectedPoints }
                let projMin = allProjs.min() ?? 0
                let projMax = max(projMin + 1, allProjs.max() ?? 30)

                var applied = 0
                var calibrated = 0
                finalPlayers = allPlayers.map { player in
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
                    // Unmatched player -- calibrate salary to RG range using projection
                    calibrated += 1
                    let projFraction = min(1.0, max(0, (player.projectedPoints - projMin) / (projMax - projMin)))
                    let curved = pow(projFraction, 0.85)
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
                print("[NFL-DFS] sameSlate=true (\(matchCount)/\(allPlayers.count)), applied=\(applied), calibrated=\(calibrated), range=$\(rgMin)-$\(rgMax)")
            } else {
                throw NSError(domain: "NFLDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for DraftKings/LineupHQ to post today's NFL slate"])
            }
        } else {
            throw NSError(domain: "NFLDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for DraftKings/LineupHQ to post today's NFL slate"])
        }

        let sortedPlayers = finalPlayers.sorted(by: { $0.salary > $1.salary })

        // 6. Build tournaments using shared builder
        let slateDate = events.first?.date ?? Date()
        let tournamentID = "nfl-\(dateKey(for: slateDate))"
        let isSingleGame = includedGames.count == 1

        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: "NFL",
            mainSalaryCap: 50000,
            mainLineupSize: 9,
            mainRosterSlots: nil,
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
        NFLSlateCache.shared.set(slate)
        return slate
    }

    // MARK: - Fetch NFL Events

    /// Fetch NFL events across a wide date window (Thu/Sun/Mon game scheduling).
    /// Prefers live events, then upcoming (nearest date first), then recent post.
    private func fetchNFLEvents() async throws -> [NFLScoreboardEvent] {
        let calendar = Calendar.current
        // NFL games span Thu-Mon: check -2 to +7 days
        let datesToCheck = (-2...7).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
        let dateStrings = datesToCheck.map { dateKey(for: $0) }

        // Fetch all scoreboards in parallel
        let scoreboards: [NFLScoreboardResponse] = await withTaskGroup(of: NFLScoreboardResponse?.self) { group in
            for dk in dateStrings {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?dates=\(dk)") else { return nil }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    return try? Self.nflDecoder.decode(NFLScoreboardResponse.self, from: data)
                }
            }
            var results: [NFLScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        // Collect and deduplicate all events
        var allEvents: [NFLScoreboardEvent] = []
        for sb in scoreboards {
            allEvents.append(contentsOf: sb.events)
        }
        var seenIDs = Set<String>()
        allEvents = allEvents.filter { seenIDs.insert($0.id).inserted }

        // Categorize events by state
        var liveEvents: [NFLScoreboardEvent] = []
        var preEvents: [NFLScoreboardEvent] = []
        var postEvents: [NFLScoreboardEvent] = []

        for event in allEvents {
            guard let comp = event.competitions.first else { continue }
            let state = comp.status.type.state
            switch state {
            case "in":
                liveEvents.append(event)
            case "pre":
                preEvents.append(event)
            case "post":
                postEvents.append(event)
            default:
                break
            }
        }

        // Pick the best game day cluster
        // If there are live games, include them plus same-day pre/post games
        if !liveEvents.isEmpty {
            let liveDay = calendar.startOfDay(for: liveEvents.first!.date)
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let combined = liveEvents + sameDayPre + sameDayPost
            print("[NFL-DFS] Found \(combined.count) events (live day): \(liveEvents.count) live, \(sameDayPre.count) pre, \(sameDayPost.count) post")
            return combined.sorted { $0.date < $1.date }
        }

        // No live games: pick nearest upcoming game day
        if !preEvents.isEmpty {
            let sorted = preEvents.sorted { $0.date < $1.date }
            let nearestDay = calendar.startOfDay(for: sorted.first!.date)
            let sameDayPre = sorted.filter { calendar.startOfDay(for: $0.date) == nearestDay }
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == nearestDay }
            let combined = sameDayPre + sameDayPost
            print("[NFL-DFS] Found \(combined.count) upcoming events for \(dateKey(for: nearestDay))")
            return combined.sorted { $0.date < $1.date }
        }

        // All games finished: show most recent completed day
        if !postEvents.isEmpty {
            let sorted = postEvents.sorted { $0.date > $1.date }
            let recentDay = calendar.startOfDay(for: sorted.first!.date)
            let sameDayPost = sorted.filter { calendar.startOfDay(for: $0.date) == recentDay }
            print("[NFL-DFS] Found \(sameDayPost.count) recent post events for \(dateKey(for: recentDay))")
            return sameDayPost.sorted { $0.date < $1.date }
        }

        return []
    }

    // MARK: - Fetch NFL Roster

    /// Fetch roster for a single NFL team and build DFSPlayer entries.
    /// Returns top 12 players per team (starters + key reserves) plus a synthetic DEF player.
    private func fetchNFLRoster(
        teamID: String,
        teamAbbreviation: String,
        teamDisplayName: String,
        gameID: String,
        ratings: [String: (fppg: Double, gamesPlayed: Int)]
    ) async -> [DFSPlayer] {
        let urlString = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/\(teamID)/roster"
        guard let url = URL(string: urlString) else { return [] }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("[NFL-DFS] Failed to fetch roster for team \(teamAbbreviation) (\(teamID))")
            return []
        }

        // Parse roster -- ESPN NFL roster groups athletes by position category
        let athletes: [(id: String, name: String, position: String, injuryStatus: String?)]
        if let rosterResponse = try? JSONDecoder().decode(NFLRosterResponse.self, from: data),
           let groups = rosterResponse.athletes {
            // Grouped format: athletes is an array of position groups with items
            var parsed: [(id: String, name: String, position: String, injuryStatus: String?)] = []
            for group in groups {
                guard let items = group.items else { continue }
                for athlete in items {
                    let pos = athlete.position?.abbreviation ?? mapNFLGroupPosition(group.position)
                    guard isRelevantNFLPosition(mapNFLPosition(pos)) else { continue }
                    let name = athlete.displayName ?? athlete.fullName ?? "Player"
                    let injury = mapNFLInjuryStatus(athlete.injuries?.first?.status, athleteStatus: athlete.status?.type)
                    parsed.append((id: athlete.id, name: name, position: mapNFLPosition(pos), injuryStatus: injury))
                }
            }
            athletes = parsed
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Handle alternative formats (flat array or nested items)
            athletes = parseNFLRosterJSON(json)
        } else {
            print("[NFL-DFS] Could not parse roster for team \(teamAbbreviation)")
            return []
        }

        // Build DFSPlayer entries for individual players
        var players: [DFSPlayer] = []
        for athlete in athletes {
            let rating = ratings[athlete.id]
            let fppg = rating?.fppg ?? 0.0
            let gamesPlayed = rating?.gamesPlayed ?? 0
            let salary = estimateNFLSalary(position: athlete.position, fppg: fppg, athleteID: athlete.id)
            let projection = projectNFLPoints(position: athlete.position, fppg: fppg, salary: salary, athleteID: athlete.id)

            players.append(DFSPlayer(
                id: "nfl-\(athlete.id)",
                name: athlete.name,
                team: teamAbbreviation,
                position: athlete.position,
                salary: salary,
                projectedPoints: projection,
                gameID: gameID,
                injuryStatus: athlete.injuryStatus,
                gamesPlayed: gamesPlayed
            ))
        }

        // Add synthetic DEF player for the team defense
        let defFPPG = estimateTeamDefenseFPPG(ratings: ratings)
        let defSalary = estimateNFLSalary(position: "DEF", fppg: defFPPG, athleteID: "def-\(teamAbbreviation)")
        let defProjection = projectNFLPoints(position: "DEF", fppg: defFPPG, salary: defSalary, athleteID: "def-\(teamAbbreviation)")

        players.append(DFSPlayer(
            id: "nfl-def-\(teamAbbreviation)",
            name: teamDisplayName,
            team: teamAbbreviation,
            position: "DEF",
            salary: defSalary,
            projectedPoints: defProjection,
            gameID: gameID
        ))

        // Sort by projected points descending, return top 12
        players.sort { $0.projectedPoints > $1.projectedPoints }
        let topPlayers = Array(players.prefix(12))
        return topPlayers
    }

    // MARK: - Fetch NFL Ratings

    /// Fetch team athlete statistics and calculate FPPG based on DK scoring.
    /// Returns [athleteID: (fppg, gamesPlayed)]
    private func fetchNFLRatings(teamID: String) async -> [String: (fppg: Double, gamesPlayed: Int)] {
        let urlString = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/\(teamID)/athletes/statistics"
        guard let url = URL(string: urlString) else { return [:] }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var playerStats: [String: [String: Double]] = [:]  // athleteID -> statName -> value
        var playerGames: [String: Int] = [:]

        // ESPN team statistics response has "categories" array, each with "labels" and "athletes"
        if let categories = json["categories"] as? [[String: Any]] {
            for category in categories {
                let categoryName = category["name"] as? String ?? ""
                guard let labels = category["labels"] as? [String],
                      let athletes = category["athletes"] as? [[String: Any]] else { continue }

                for athleteEntry in athletes {
                    guard let athleteID = athleteEntry["id"] as? String
                            ?? (athleteEntry["athlete"] as? [String: Any])?["id"] as? String else { continue }
                    guard let statsArr = athleteEntry["stats"] as? [String] else { continue }

                    if playerStats[athleteID] == nil { playerStats[athleteID] = [:] }

                    for (i, label) in labels.enumerated() where i < statsArr.count {
                        let statValue = statsArr[i]

                        if label == "C/ATT" {
                            // Parse completions/attempts like "250/400"
                            let parts = statValue.split(separator: "/")
                            if parts.count == 2 {
                                playerStats[athleteID]?["\(categoryName)_completions"] = Double(parts[0]) ?? 0
                                playerStats[athleteID]?["\(categoryName)_attempts"] = Double(parts[1]) ?? 0
                            }
                        } else if label == "GP" || label == "G" {
                            if let gp = Int(statValue) {
                                playerGames[athleteID] = max(playerGames[athleteID] ?? 0, gp)
                            }
                        } else {
                            playerStats[athleteID]?["\(categoryName)_\(label)"] = Double(statValue) ?? 0
                        }
                    }
                }
            }
        }

        // Calculate FPPG for each player using DK NFL scoring
        var results: [String: (fppg: Double, gamesPlayed: Int)] = [:]
        for (athleteID, stats) in playerStats {
            let gp = max(1, playerGames[athleteID] ?? 1)

            var totalPts = 0.0

            // Passing
            let passYards = stats["passing_YDS"] ?? 0
            let passTDs = stats["passing_TD"] ?? 0
            let ints = stats["passing_INT"] ?? 0
            totalPts += passYards * 0.04
            totalPts += passTDs * 4.0
            totalPts -= ints * 1.0

            // Rushing
            let rushYards = stats["rushing_YDS"] ?? 0
            let rushTDs = stats["rushing_TD"] ?? 0
            totalPts += rushYards * 0.1
            totalPts += rushTDs * 6.0

            // Receiving
            let receptions = stats["receiving_REC"] ?? 0
            let recYards = stats["receiving_YDS"] ?? 0
            let recTDs = stats["receiving_TD"] ?? 0
            totalPts += receptions * 1.0  // PPR
            totalPts += recYards * 0.1
            totalPts += recTDs * 6.0

            // Fumbles
            let fumblesLost = stats["fumbles_LOST"] ?? stats["fumbles_FUM"] ?? 0
            totalPts -= fumblesLost * 1.0

            let fppg = totalPts / Double(gp)
            results[athleteID] = (fppg: fppg, gamesPlayed: gp)
        }

        return results
    }

    // MARK: - Salary Estimation

    /// Estimate NFL DFS salary based on position and FPPG rating.
    /// Uses position-tiered salary ranges with stable hash jitter.
    private func estimateNFLSalary(position: String, fppg: Double, athleteID: String) -> Int {
        let (minSal, maxSal, maxFPPG): (Int, Int, Double)
        switch position {
        case "QB":  (minSal, maxSal, maxFPPG) = (5500, 9500, 25.0)
        case "RB":  (minSal, maxSal, maxFPPG) = (4000, 8500, 20.0)
        case "WR":  (minSal, maxSal, maxFPPG) = (3500, 8000, 18.0)
        case "TE":  (minSal, maxSal, maxFPPG) = (3000, 6500, 14.0)
        case "K":   (minSal, maxSal, maxFPPG) = (3500, 5000, 10.0)
        case "DEF": (minSal, maxSal, maxFPPG) = (3000, 5500, 12.0)
        default:    (minSal, maxSal, maxFPPG) = (3500, 7000, 15.0)
        }

        let fraction = min(1.0, max(0, fppg / maxFPPG))
        let curved = pow(fraction, 0.7)
        let baseSalary = minSal + Int(curved * Double(maxSal - minSal))

        // Stable per-player jitter (+/-$100) from athlete ID hash
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = (abs(stableHash) % 200) - 100

        let salary = max(minSal, min(maxSal, baseSalary + jitter))
        return (salary / 100) * 100  // round to nearest $100
    }

    // MARK: - Projection

    /// Project fantasy points based on position, FPPG, and salary.
    private func projectNFLPoints(position: String, fppg: Double, salary: Int, athleteID: String) -> Double {
        // Blend FPPG with salary-implied projection
        let salaryFraction = Double(salary - 3000) / Double(10000 - 3000)
        let salaryProj: Double
        switch position {
        case "QB":  salaryProj = 10.0 + salaryFraction * 18.0   // 10-28 pts
        case "RB":  salaryProj = 6.0 + salaryFraction * 16.0    // 6-22 pts
        case "WR":  salaryProj = 5.0 + salaryFraction * 15.0    // 5-20 pts
        case "TE":  salaryProj = 4.0 + salaryFraction * 12.0    // 4-16 pts
        case "K":   salaryProj = 5.0 + salaryFraction * 7.0     // 5-12 pts
        case "DEF": salaryProj = 4.0 + salaryFraction * 8.0     // 4-12 pts
        default:    salaryProj = 5.0 + salaryFraction * 12.0
        }

        // Blend: weight FPPG heavily if available, else rely on salary projection
        let blended: Double
        if fppg > 0.5 {
            blended = fppg * 0.7 + salaryProj * 0.3
        } else {
            blended = salaryProj
        }

        // Stable per-player jitter (+/-5%)
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitterFraction = (Double(abs(stableHash) % 100) - 50.0) / 1000.0
        let adjusted = blended * (1.0 + jitterFraction)
        return max(2.0, (adjusted * 10).rounded() / 10)
    }

    // MARK: - Roster Parsing Helpers

    /// Parse NFL roster from raw JSON when Codable decoding fails.
    private func parseNFLRosterJSON(_ json: [String: Any]) -> [(id: String, name: String, position: String, injuryStatus: String?)] {
        var athletes: [(id: String, name: String, position: String, injuryStatus: String?)] = []

        // Try grouped format: { "athletes": [ { "position": "Quarterbacks", "items": [...] }, ... ] }
        if let athleteGroups = json["athletes"] as? [[String: Any]] {
            for group in athleteGroups {
                let groupPosition = group["position"] as? String
                let items = group["items"] as? [[String: Any]] ?? []
                for item in items {
                    guard let id = item["id"] as? String ?? (item["id"] as? Int).map({ String($0) }) else { continue }
                    let name = item["displayName"] as? String ?? item["fullName"] as? String ?? "Player"
                    var pos = "UTIL"
                    if let posDict = item["position"] as? [String: Any] {
                        pos = posDict["abbreviation"] as? String ?? posDict["displayName"] as? String ?? "UTIL"
                    } else if let gp = groupPosition {
                        pos = mapNFLGroupPosition(gp)
                    }
                    let mappedPos = mapNFLPosition(pos)
                    guard isRelevantNFLPosition(mappedPos) else { continue }

                    var injury: String? = nil
                    if let injuries = item["injuries"] as? [[String: Any]], let first = injuries.first {
                        injury = mapNFLInjuryStatus(first["status"] as? String, athleteStatus: nil)
                    }

                    athletes.append((id: id, name: name, position: mappedPos, injuryStatus: injury))
                }
            }
        }

        return athletes
    }

    /// Map ESPN position group name to abbreviation
    private func mapNFLGroupPosition(_ groupPosition: String?) -> String {
        guard let gp = groupPosition?.lowercased() else { return "UTIL" }
        if gp.contains("quarterback") { return "QB" }
        if gp.contains("running back") { return "RB" }
        if gp.contains("wide receiver") { return "WR" }
        if gp.contains("tight end") { return "TE" }
        if gp.contains("kicker") || gp.contains("place") { return "K" }
        if gp.contains("defensive") || gp.contains("linebacker") || gp.contains("safety") || gp.contains("corner") {
            return "LB"
        }
        if gp.contains("offensive") { return "OL" }
        return "UTIL"
    }

    /// Map raw position abbreviation to DFS-relevant position
    private func mapNFLPosition(_ raw: String) -> String {
        let upper = raw.uppercased().trimmingCharacters(in: .whitespaces)
        switch upper {
        case "QB": return "QB"
        case "RB", "HB", "FB": return "RB"
        case "WR": return "WR"
        case "TE": return "TE"
        case "K", "PK": return "K"
        case "DEF", "DST": return "DEF"
        default: return upper
        }
    }

    /// Check if position is relevant for NFL DFS player pool
    private func isRelevantNFLPosition(_ position: String) -> Bool {
        return ["QB", "RB", "WR", "TE", "K"].contains(position)
    }

    /// Map NFL injury status strings to abbreviated codes
    private func mapNFLInjuryStatus(_ injuryStatus: String?, athleteStatus: String?) -> String? {
        if let status = athleteStatus?.lowercased() {
            if status.contains("injured-reserve") || status.contains("injured reserve") { return "IR" }
        }
        guard let status = injuryStatus?.lowercased() else { return nil }
        if status.contains("out") { return "O" }
        if status.contains("questionable") { return "Q" }
        if status.contains("doubtful") { return "D" }
        if status.contains("probable") { return "P" }
        if status.contains("injured reserve") || status.contains("injured-reserve") { return "IR" }
        return nil
    }

    /// Estimate team defense FPPG from available individual defensive player ratings.
    private func estimateTeamDefenseFPPG(ratings: [String: (fppg: Double, gamesPlayed: Int)]) -> Double {
        // Default team defense FPPG (league average is roughly 7-8 DK pts)
        return 7.5
    }

    // MARK: - Helpers

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - NFL Live Scoring Provider

struct ESPNNFLDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession

    private static let nflDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            let formatters: [DateFormatter] = [
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"; return f }(),
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f }(),
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return f }(),
            ]
            for formatter in formatters {
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unsupported NFL date: \(value)"))
        }
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// DraftKings NFL Fantasy Scoring:
    /// - Pass Yard: +0.04 pts (25 yards per point)
    /// - Pass TD: +4.0 pts
    /// - Interception thrown: -1.0 pt
    /// - Rush Yard: +0.1 pts (10 yards per point)
    /// - Rush TD: +6.0 pts
    /// - Reception: +1.0 pt (PPR)
    /// - Receiving Yard: +0.1 pts
    /// - Receiving TD: +6.0 pts
    /// - Fumble Lost: -1.0 pt
    /// - 2PT Conversion: +2.0 pts
    /// - FG Made: +3.0 pts
    /// - PAT Made: +1.0 pt
    /// - Sack (DEF): +1.0 pt
    /// - INT (DEF): +2.0 pts
    /// - Fumble Recovery (DEF): +2.0 pts
    /// - Defensive TD: +6.0 pts
    /// - Safety (DEF): +2.0 pts
    /// - Points Allowed 0: +10.0, 1-6: +7.0, 7-13: +4.0, 14-20: +1.0, 21-27: 0, 28-34: -1.0, 35+: -4.0
    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfo: [String: DFSGameLiveInfo] = [:]
        var allGamesFinal = true

        guard !games.isEmpty else {
            return DFSScoreSnapshot(playerFantasyPoints: [:], playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: true)
        }

        // Fetch game summaries in parallel
        let gameResults: [(gameID: String, info: DFSGameLiveInfo, playerStats: [(String, Double, DFSPlayerLiveStats)], isFinal: Bool)] =
            await withTaskGroup(of: (String, DFSGameLiveInfo, [(String, Double, DFSPlayerLiveStats)], Bool)?.self) { group in
                for game in games {
                    group.addTask {
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/nfl/summary?event=\(game.id)") else {
                            return nil
                        }

                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            print("[NFL-Score] Failed to fetch summary for event \(game.id)")
                            return nil
                        }

                        let info = self.extractGameLiveInfo(payload: payload, game: game)
                        let isFinal = info.state == "post"

                        var playerResults: [(String, Double, DFSPlayerLiveStats)] = []
                        if info.state != "pre" {
                            playerResults = self.extractNFLPlayerStats(
                                payload: payload,
                                game: game,
                                gameInfo: info
                            )
                        }

                        return (game.id, info, playerResults, isFinal)
                    }
                }

                var results: [(String, DFSGameLiveInfo, [(String, Double, DFSPlayerLiveStats)], Bool)] = []
                for await result in group {
                    if let result { results.append(result) }
                }
                return results.map { (gameID: $0.0, info: $0.1, playerStats: $0.2, isFinal: $0.3) }
            }

        for result in gameResults {
            gameLiveInfo[result.gameID] = result.info
            if !result.isFinal { allGamesFinal = false }
            for (playerID, fantasy, stats) in result.playerStats {
                pointsByPlayerID[playerID] = fantasy
                statsByPlayerID[playerID] = stats
            }
        }

        if gameResults.isEmpty { allGamesFinal = false }

        print("[NFL-Score] Total: \(gameResults.count)/\(games.count) games fetched, \(pointsByPlayerID.count) player scores")

        return DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfo,
            allGamesFinal: allGamesFinal
        )
    }

    // MARK: - Extract Game Live Info

    nonisolated private func extractGameLiveInfo(payload: [String: Any], game: DFSSlateGame) -> DFSGameLiveInfo {
        var awayScore = 0, homeScore = 0
        var clock = "", period = 0, state = "pre"

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
                period = status["period"] as? Int ?? 0
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

        // Format game status
        let displayClock: String
        if state == "post" {
            displayClock = ""
        } else if period == 2 && clock == "0:00" {
            displayClock = "Half"
        } else if period > 0 {
            if period <= 4 {
                displayClock = "Q\(period) \(clock)"
            } else {
                displayClock = "OT \(clock)"
            }
        } else {
            displayClock = clock
        }

        return DFSGameLiveInfo(
            id: game.id,
            awayTeam: game.awayTeam,
            homeTeam: game.homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            clock: displayClock,
            period: period,
            state: state,
            sportType: "nfl"
        )
    }

    // MARK: - Extract NFL Player Stats from Boxscore

    nonisolated private func extractNFLPlayerStats(
        payload: [String: Any],
        game: DFSSlateGame,
        gameInfo: DFSGameLiveInfo
    ) -> [(String, Double, DFSPlayerLiveStats)] {
        guard let boxscore = payload["boxscore"] as? [String: Any],
              let playersArr = boxscore["players"] as? [[String: Any]] else {
            print("[NFL-Score] No boxscore.players in payload for event \(game.id)")
            return []
        }

        var results: [(String, Double, DFSPlayerLiveStats)] = []

        let gameStatus: String
        if gameInfo.state == "post" {
            gameStatus = "Final"
        } else if gameInfo.clock == "Half" {
            gameStatus = "Half"
        } else if gameInfo.period > 0 {
            gameStatus = gameInfo.clock.isEmpty ? "Q\(gameInfo.period)" : gameInfo.clock
        } else {
            gameStatus = "Pre"
        }
        let gameFinal = gameInfo.state == "post"

        // Track team abbreviations for DEF scoring
        let teamAbbrevs = [game.awayTeam, game.homeTeam]

        // Accumulate stats by player across all stat categories
        var playerStatAccum: [String: (name: String, passYards: Double, passTDs: Double, ints: Double,
                                        rushYards: Double, rushTDs: Double,
                                        receptions: Double, recYards: Double, recTDs: Double,
                                        fumblesLost: Double, twoPointConv: Double,
                                        fgMade: Double, fgAtt: Double, patMade: Double, patAtt: Double,
                                        completions: Double, passAttempts: Double,
                                        targets: Double,
                                        sacks: Double, defInts: Double, fumRec: Double, defTDs: Double, safeties: Double)] = [:]

        for teamBlock in playersArr {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }

            for statCategory in statistics {
                let categoryName = (statCategory["name"] as? String ?? "").lowercased()
                guard let labels = statCategory["labels"] as? [String],
                      let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }

                for athleteEntry in athletes {
                    guard let athleteDict = athleteEntry["athlete"] as? [String: Any],
                          let athleteID = athleteDict["id"] as? String,
                          let athleteName = athleteDict["displayName"] as? String ?? athleteDict["shortName"] as? String else { continue }
                    guard let statsArr = athleteEntry["stats"] as? [String] else { continue }

                    let playerID = "nfl-\(athleteID)"
                    if playerStatAccum[playerID] == nil {
                        playerStatAccum[playerID] = (name: athleteName,
                            passYards: 0, passTDs: 0, ints: 0,
                            rushYards: 0, rushTDs: 0,
                            receptions: 0, recYards: 0, recTDs: 0,
                            fumblesLost: 0, twoPointConv: 0,
                            fgMade: 0, fgAtt: 0, patMade: 0, patAtt: 0,
                            completions: 0, passAttempts: 0,
                            targets: 0,
                            sacks: 0, defInts: 0, fumRec: 0, defTDs: 0, safeties: 0)
                    }

                    for (i, label) in labels.enumerated() where i < statsArr.count {
                        let rawValue = statsArr[i]
                        let upperLabel = label.uppercased()

                        if upperLabel == "C/ATT" {
                            let parts = rawValue.split(separator: "/")
                            if parts.count == 2 {
                                if categoryName == "passing" {
                                    playerStatAccum[playerID]?.completions += Double(parts[0]) ?? 0
                                    playerStatAccum[playerID]?.passAttempts += Double(parts[1]) ?? 0
                                } else if categoryName == "kicking" {
                                    playerStatAccum[playerID]?.fgMade += Double(parts[0]) ?? 0
                                    playerStatAccum[playerID]?.fgAtt += Double(parts[1]) ?? 0
                                }
                            }
                        } else if categoryName == "passing" {
                            let val = Double(rawValue) ?? 0
                            switch upperLabel {
                            case "YDS": playerStatAccum[playerID]?.passYards += val
                            case "TD": playerStatAccum[playerID]?.passTDs += val
                            case "INT": playerStatAccum[playerID]?.ints += val
                            default: break
                            }
                        } else if categoryName == "rushing" {
                            let val = Double(rawValue) ?? 0
                            switch upperLabel {
                            case "YDS": playerStatAccum[playerID]?.rushYards += val
                            case "TD": playerStatAccum[playerID]?.rushTDs += val
                            default: break
                            }
                        } else if categoryName == "receiving" {
                            let val = Double(rawValue) ?? 0
                            switch upperLabel {
                            case "REC": playerStatAccum[playerID]?.receptions += val
                            case "YDS": playerStatAccum[playerID]?.recYards += val
                            case "TD": playerStatAccum[playerID]?.recTDs += val
                            case "TAR", "TGTS": playerStatAccum[playerID]?.targets += val
                            default: break
                            }
                        } else if categoryName == "fumbles" {
                            let val = Double(rawValue) ?? 0
                            switch upperLabel {
                            case "LOST", "FUM": playerStatAccum[playerID]?.fumblesLost += val
                            default: break
                            }
                        } else if categoryName == "kicking" {
                            if upperLabel == "XP" {
                                let parts = rawValue.split(separator: "/")
                                if parts.count == 2 {
                                    playerStatAccum[playerID]?.patMade += Double(parts[0]) ?? 0
                                    playerStatAccum[playerID]?.patAtt += Double(parts[1]) ?? 0
                                }
                            }
                        } else if categoryName == "defensive" {
                            let val = Double(rawValue) ?? 0
                            switch upperLabel {
                            case "SACKS", "SCK": playerStatAccum[playerID]?.sacks += val
                            case "INT": playerStatAccum[playerID]?.defInts += val
                            case "FR", "FUMREC": playerStatAccum[playerID]?.fumRec += val
                            case "TD": playerStatAccum[playerID]?.defTDs += val
                            case "SFTY", "SAF": playerStatAccum[playerID]?.safeties += val
                            default: break
                            }
                        }
                    }
                }
            }
        }

        // Calculate fantasy points for each player
        for (playerID, stats) in playerStatAccum {
            var pts = 0.0

            // Passing
            pts += stats.passYards * 0.04
            pts += stats.passTDs * 4.0
            pts -= stats.ints * 1.0

            // Rushing
            pts += stats.rushYards * 0.1
            pts += stats.rushTDs * 6.0

            // Receiving (PPR)
            pts += stats.receptions * 1.0
            pts += stats.recYards * 0.1
            pts += stats.recTDs * 6.0

            // Fumbles
            pts -= stats.fumblesLost * 1.0

            // Kicking
            pts += stats.fgMade * 3.0
            pts += stats.patMade * 1.0

            let roundedPts = (pts * 10).rounded() / 10

            let liveStats = DFSPlayerLiveStats(
                name: stats.name,
                points: Int(stats.passYards),           // passYards (scaled int)
                rebounds: Int(stats.rushYards),          // rushYards
                assists: Int(stats.receptions),         // receptions
                steals: Int(stats.passTDs),             // passTDs
                blocks: Int(stats.rushTDs),             // rushTDs
                turnovers: Int(stats.ints + stats.fumblesLost), // INTs + fumbles lost
                minutes: gameStatus,                    // game status string
                fgm: Int(stats.completions),            // pass completions
                fga: Int(stats.passAttempts),            // pass attempts
                threePM: Int(stats.recTDs),             // receiving TDs
                threePA: Int(stats.targets),            // targets
                ftm: Int(stats.fgMade),                 // field goals made
                fta: Int(stats.fgAtt),                  // field goals attempted
                fantasyPoints: roundedPts,
                gameStatus: gameStatus,
                gameFinal: gameFinal
            )

            results.append((playerID, roundedPts, liveStats))
        }

        // Build DEF scoring for each team
        for teamAbbrev in teamAbbrevs {
            let defPlayerID = "nfl-def-\(teamAbbrev)"
            let opposingScore: Int
            if teamAbbrev == game.homeTeam {
                opposingScore = gameInfo.awayScore
            } else {
                opposingScore = gameInfo.homeScore
            }

            // Aggregate defensive stats from boxscore for this team
            var teamSacks = 0.0, teamDefInts = 0.0, teamFumRec = 0.0, teamDefTDs = 0.0, teamSafeties = 0.0

            for teamBlock in playersArr {
                let teamDict = teamBlock["team"] as? [String: Any]
                let blockAbbrev = teamDict?["abbreviation"] as? String ?? ""
                guard blockAbbrev == teamAbbrev else { continue }
                guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }

                for statCategory in statistics {
                    let categoryName = (statCategory["name"] as? String ?? "").lowercased()
                    guard categoryName == "defensive" else { continue }
                    guard let labels = statCategory["labels"] as? [String],
                          let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }

                    for athleteEntry in athletes {
                        guard let statsArr = athleteEntry["stats"] as? [String] else { continue }
                        for (i, label) in labels.enumerated() where i < statsArr.count {
                            let val = Double(statsArr[i]) ?? 0
                            let upperLabel = label.uppercased()
                            switch upperLabel {
                            case "SACKS", "SCK": teamSacks += val
                            case "INT": teamDefInts += val
                            case "FR", "FUMREC": teamFumRec += val
                            case "TD": teamDefTDs += val
                            case "SFTY", "SAF": teamSafeties += val
                            default: break
                            }
                        }
                    }
                }
            }

            var defPts = 0.0
            defPts += teamSacks * 1.0
            defPts += teamDefInts * 2.0
            defPts += teamFumRec * 2.0
            defPts += teamDefTDs * 6.0
            defPts += teamSafeties * 2.0

            // Points allowed scoring
            if gameInfo.state == "in" || gameInfo.state == "post" {
                if opposingScore == 0 {
                    defPts += 10.0
                } else if opposingScore <= 6 {
                    defPts += 7.0
                } else if opposingScore <= 13 {
                    defPts += 4.0
                } else if opposingScore <= 20 {
                    defPts += 1.0
                } else if opposingScore <= 27 {
                    defPts += 0.0
                } else if opposingScore <= 34 {
                    defPts -= 1.0
                } else {
                    defPts -= 4.0
                }
            }

            let roundedDefPts = (defPts * 10).rounded() / 10

            let defStats = DFSPlayerLiveStats(
                name: "\(teamAbbrev) Defense",
                points: 0,
                rebounds: 0,
                assists: 0,
                steals: Int(teamSacks),
                blocks: Int(teamDefInts),
                turnovers: Int(teamFumRec),
                minutes: gameStatus,
                fgm: Int(teamDefTDs),
                fga: Int(teamSafeties),
                threePM: 0,
                threePA: 0,
                ftm: 0,
                fta: opposingScore,
                fantasyPoints: roundedDefPts,
                gameStatus: gameStatus,
                gameFinal: gameFinal
            )

            results.append((defPlayerID, roundedDefPts, defStats))
        }

        return results
    }

    private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - NFL ESPN Codable Models

struct NFLScoreboardResponse: Codable, Sendable {
    let events: [NFLScoreboardEvent]
}

struct NFLScoreboardEvent: Codable, Sendable {
    let id: String
    let name: String?
    let date: Date
    let competitions: [NFLScoreboardCompetition]
}

struct NFLScoreboardCompetition: Codable, Sendable {
    let id: String
    let date: Date
    let competitors: [NFLScoreboardCompetitor]
    let status: NFLCompetitionStatus
}

struct NFLScoreboardCompetitor: Codable, Sendable {
    let id: String
    let homeAway: String?
    let team: NFLTeamRef
    let score: String?
    let records: [NFLRecord]?
}

struct NFLTeamRef: Codable, Sendable {
    let id: String
    let abbreviation: String
    let displayName: String?
    let shortDisplayName: String?
}

struct NFLRecord: Codable, Sendable {
    let summary: String?
    let type: String?
}

struct NFLCompetitionStatus: Codable, Sendable {
    let clock: Double?
    let displayClock: String?
    let period: Int?
    let type: NFLStatusType
}

struct NFLStatusType: Codable, Sendable {
    let id: String?
    let name: String?
    let state: String  // "pre", "in", "post"
    let completed: Bool?
}

struct NFLRosterResponse: Codable, Sendable {
    let athletes: [NFLRosterAthleteGroup]?
}

struct NFLRosterAthleteGroup: Codable, Sendable {
    let position: String?
    let items: [NFLRosterAthlete]?
}

struct NFLRosterAthlete: Codable, Sendable {
    let id: String
    let fullName: String?
    let displayName: String?
    let shortName: String?
    let position: NFLRosterPosition?
    let injuries: [NFLRosterInjury]?
    let status: NFLAthleteStatus?
}

struct NFLRosterPosition: Codable, Sendable {
    let abbreviation: String?
}

struct NFLRosterInjury: Codable, Sendable {
    let status: String?
}

struct NFLAthleteStatus: Codable, Sendable {
    let type: String?  // "active", "injured-reserve", etc.
}
