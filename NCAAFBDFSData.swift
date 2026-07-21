import Foundation

// MARK: - NCAAFB DFS Slate Provider

/// Simple in-memory cache for NCAAFB slates (mirrors UFCSlateCache pattern)
private final class NCAAFBSlateCache {
    static let shared = NCAAFBSlateCache()
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

struct ESPNNCAAFBDFSSlateProvider: DFSSlateProvider {
    private let session: URLSession

    private static let cfbDecoder: JSONDecoder = {
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
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unsupported CFB date: \(value)"))
        }
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        if let cached = NCAAFBSlateCache.shared.get() {
            return cached
        }

        // Start fetching real DraftKings salaries in parallel with ESPN data
        async let rgSalaries = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "cfb", maxClassicSalary: 10000)

        // 1. Fetch NCAAFB scoreboard events
        let events = try await fetchNCAAFBEvents()
        guard !events.isEmpty else {
            throw NSError(domain: "NCAAFBDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No college football games found"])
        }

        // 2. Build team abbreviation -> event ID mapping
        var teamToGameID: [String: String] = [:]
        for event in events {
            for competition in event.competitions {
                for competitor in competition.competitors {
                    teamToGameID[competitor.team.abbreviation] = event.id
                }
            }
        }

        // 3. Build included games
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

        // 4. Collect unique teams from events (limit to teams playing in fetched events)
        let teamRefs = uniqueTeams(from: events)

        // 5. Fetch team rosters and ratings in parallel using TaskGroup
        let players: [DFSPlayer] = try await withThrowingTaskGroup(of: [DFSPlayer].self) { group in
            for team in teamRefs {
                let gameID = teamToGameID[team.abbreviation]
                group.addTask {
                    let ratings = await self.fetchNCAAFBRatings(teamID: team.id)
                    let roster = await self.fetchNCAAFBRoster(
                        teamID: team.id,
                        teamAbbreviation: team.abbreviation,
                        gameID: gameID,
                        ratings: ratings
                    )
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
            throw NSError(domain: "NCAAFBDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No college football players available"])
        }

        // 6. Apply real DraftKings salaries from RotoGrinders where available
        let realSalaries = await rgSalaries
        let finalPlayers: [DFSPlayer]
        if !realSalaries.isEmpty {
            let matchCount = deduped.filter { RotoGrindersSalaryProvider.lookupSalary(espnName: $0.name, in: realSalaries) != nil }.count
            let matchRate = Double(matchCount) / Double(max(1, deduped.count))
            let sameSlate = matchRate > 0.30

            if sameSlate {
                let rgMin = realSalaries.values.min() ?? 3000
                let rgMax = realSalaries.values.max() ?? 10000
                let allProjs = deduped.map { $0.projectedPoints }
                let projMin = allProjs.min() ?? 0
                let projMax = max(projMin + 1, allProjs.max() ?? 50)

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
                print("[CFB-DFS] sameSlate=true (\(matchCount)/\(deduped.count)), applied=\(applied), calibrated=\(calibrated), range=$\(rgMin)-$\(rgMax)")
            } else {
                throw NSError(domain: "CFBDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's CFB slate"])
            }
        } else {
            throw NSError(domain: "CFBDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for today's CFB slate"])
        }

        let sortedPlayers = finalPlayers.sorted(by: { $0.salary > $1.salary })

        // 7. Build tournaments using shared builder
        let slateDate = events.first?.date ?? Date()
        let tournamentID = "cfb-\(dateKey(for: slateDate))"
        let isSingleGame = includedGames.count == 1

        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: "CFB",
            mainSalaryCap: 50000,
            mainLineupSize: 8,
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
        NCAAFBSlateCache.shared.set(slate)
        return slate
    }

    // MARK: - Fetch NCAAFB Events

    /// Fetch college football scoreboards for -1 to +7 days.
    /// College football games are mostly Saturday -- need wider window to catch them.
    /// Prefers live events, then upcoming (nearest date first), then recent post.
    private func fetchNCAAFBEvents() async throws -> [NCAAFBScoreboardEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Check yesterday through next 7 days (college football is mostly Saturday)
        let dayRange = -1...7
        let datesToCheck = dayRange.compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let dateStrings = datesToCheck.map { dateKey(for: $0) }

        // Fetch all scoreboards in parallel
        let scoreboards: [NCAAFBScoreboardResponse] = await withTaskGroup(of: NCAAFBScoreboardResponse?.self) { group in
            for dk in dateStrings {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard?dates=\(dk)&groups=80&limit=50") else { return nil }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    return try? Self.cfbDecoder.decode(NCAAFBScoreboardResponse.self, from: data)
                }
            }
            var results: [NCAAFBScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        // Collect all events and deduplicate by ID
        var allEvents: [NCAAFBScoreboardEvent] = []
        for sb in scoreboards {
            allEvents.append(contentsOf: sb.events)
        }
        var seenIDs = Set<String>()
        allEvents = allEvents.filter { seenIDs.insert($0.id).inserted }

        // Categorize events
        var liveEvents: [NCAAFBScoreboardEvent] = []
        var preEvents: [NCAAFBScoreboardEvent] = []
        var postEvents: [NCAAFBScoreboardEvent] = []

        for event in allEvents {
            let hasLive = event.competitions.contains { $0.status.type.state == "in" }
            let hasPre = event.competitions.contains { $0.status.type.state == "pre" }
            let allPost = event.competitions.allSatisfy { $0.status.type.state == "post" }

            if hasLive {
                liveEvents.append(event)
            } else if hasPre {
                preEvents.append(event)
            } else if allPost {
                postEvents.append(event)
            }
        }

        // If there are live games, include them AND finished/upcoming games from the same day
        if !liveEvents.isEmpty {
            let liveDay = calendar.startOfDay(for: liveEvents.first!.date)
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == liveDay }
            let combined = (liveEvents + sameDayPost + sameDayPre).sorted(by: { $0.date < $1.date })
            print("[CFB-DFS] Found \(combined.count) events (live day): \(liveEvents.count) live, \(sameDayPost.count) post, \(sameDayPre.count) pre")
            return combined
        }

        // All-day slate: upcoming (pre) games from the nearest date
        if !preEvents.isEmpty {
            let earliestPreDay = preEvents.map { calendar.startOfDay(for: $0.date) }.min()!
            let sameDayPost = postEvents.filter { calendar.startOfDay(for: $0.date) == earliestPreDay }
            let sameDayPre = preEvents.filter { calendar.startOfDay(for: $0.date) == earliestPreDay }
            if !sameDayPost.isEmpty {
                let combined = (sameDayPre + sameDayPost).sorted(by: { $0.date < $1.date })
                print("[CFB-DFS] Found \(combined.count) events (pre+post day)")
                return combined
            }
            let groupedByDay = Dictionary(grouping: preEvents) { calendar.startOfDay(for: $0.date) }
            if let earliestDay = groupedByDay.keys.sorted().first {
                let dayEvents = (groupedByDay[earliestDay] ?? []).sorted(by: { $0.date < $1.date })
                print("[CFB-DFS] Found \(dayEvents.count) upcoming events")
                return dayEvents
            }
            return preEvents
        }

        // No live or pre games -- return most recent finished games for settlement
        if !postEvents.isEmpty {
            let groupedByDay = Dictionary(grouping: postEvents) { calendar.startOfDay(for: $0.date) }
            if let mostRecentDay = groupedByDay.keys.sorted().last {
                let dayEvents = (groupedByDay[mostRecentDay] ?? []).sorted(by: { $0.date < $1.date })
                print("[CFB-DFS] Found \(dayEvents.count) recent post events")
                return dayEvents
            }
        }

        return []
    }

    // MARK: - Fetch NCAAFB Roster

    /// Fetch roster for a college football team. Returns up to 10 DFS-eligible players
    /// sorted by projected points descending.
    private func fetchNCAAFBRoster(teamID: String, teamAbbreviation: String, gameID: String?, ratings: [String: (fppg: Double, gamesPlayed: Int)]) async -> [DFSPlayer] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/teams/\(teamID)/roster") else {
            return []
        }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let roster = try? JSONDecoder().decode(NCAAFBRosterResponse.self, from: data) else {
            return []
        }

        let validPositions: Set<String> = ["QB", "RB", "WR", "TE", "K", "PK"]
        var players: [DFSPlayer] = []

        // Parse athletes from roster groups
        if let groups = roster.athletes {
            for group in groups {
                guard let items = group.items else { continue }
                for athlete in items {
                    let posAbbr = athlete.position?.abbreviation?.uppercased() ?? ""
                    // Map PK to K for consistency
                    let normalizedPos = posAbbr == "PK" ? "K" : posAbbr
                    guard validPositions.contains(posAbbr) || validPositions.contains(normalizedPos) else { continue }

                    let name = athlete.displayName ?? athlete.fullName ?? athlete.shortName ?? "Player \(athlete.id)"
                    let rating = ratings[athlete.id]
                    let fppg = rating?.fppg ?? 0.0
                    let salary = estimateNCAAFBSalary(position: normalizedPos, fppg: fppg, playerID: athlete.id)
                    let projection = projectNCAAFBPoints(fppg: fppg, position: normalizedPos)

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

                    players.append(DFSPlayer(
                        id: "cfb-\(athlete.id)",
                        name: name,
                        team: teamAbbreviation,
                        position: normalizedPos,
                        salary: salary,
                        projectedPoints: projection,
                        gameID: gameID,
                        injuryStatus: injuryStatus
                    ))
                }
            }
        }

        // Sort by projected points descending and return top 10
        players.sort { $0.projectedPoints > $1.projectedPoints }
        return Array(players.prefix(10))
    }

    // MARK: - Fetch NCAAFB Ratings

    /// Fetch per-player statistics from ESPN and compute DK-style fantasy point averages.
    /// Returns [athleteID: (fppg, gamesPlayed)] for all players on the team.
    private func fetchNCAAFBRatings(teamID: String) async -> [String: (fppg: Double, gamesPlayed: Int)] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/teams/\(teamID)/athletes/statistics") else {
            return [:]
        }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return [:]
        }

        var ratings: [String: (fppg: Double, gamesPlayed: Int)] = [:]

        guard let firstResult = results.first,
              let leaders = firstResult["leaders"] as? [[String: Any]] else {
            return [:]
        }

        for leader in leaders {
            guard let athlete = leader["athlete"] as? [String: Any],
                  let athleteID = athlete["id"] as? String else { continue }
            guard let statistics = leader["statistics"] as? [[String: Any]] else { continue }

            // Parse stats from all sections
            var passYards: Double = 0, passTDs: Double = 0, interceptions: Double = 0
            var rushYards: Double = 0, rushTDs: Double = 0
            var receptions: Double = 0, recYards: Double = 0, recTDs: Double = 0
            var fumblesLost: Double = 0
            var fgMade: Double = 0, patMade: Double = 0
            var gp: Int = 0

            for section in statistics {
                guard let stats = section["stats"] as? [[String: Any]] else { continue }
                for stat in stats {
                    guard let name = stat["name"] as? String,
                          let value = stat["value"] as? Double else { continue }
                    switch name {
                    case "passingYards": passYards = value
                    case "passingTouchdowns": passTDs = value
                    case "interceptions": interceptions = value
                    case "rushingYards": rushYards = value
                    case "rushingTouchdowns": rushTDs = value
                    case "receptions": receptions = value
                    case "receivingYards": recYards = value
                    case "receivingTouchdowns": recTDs = value
                    case "fumblesLost": fumblesLost = value
                    case "fieldGoalsMade": fgMade = value
                    case "extraPointsMade": patMade = value
                    case "gamesPlayed": gp = Int(value)
                    default: break
                    }
                }
            }

            // Compute DK-style fantasy points per game using college football scoring
            // Pass Yard: +0.04, Pass TD: +4.0, INT: -1.0
            // Rush Yard: +0.1, Rush TD: +6.0
            // Reception: +1.0 (PPR), Rec Yard: +0.1, Rec TD: +6.0
            // Fumble Lost: -1.0
            // FG Made: +3.0, PAT Made: +1.0
            let totalFantasyPoints =
                passYards * 0.04 +
                passTDs * 4.0 -
                interceptions * 1.0 +
                rushYards * 0.1 +
                rushTDs * 6.0 +
                receptions * 1.0 +
                recYards * 0.1 +
                recTDs * 6.0 -
                fumblesLost * 1.0 +
                fgMade * 3.0 +
                patMade * 1.0

            let gamesPlayed = max(1, gp)
            let fppg = totalFantasyPoints / Double(gamesPlayed)

            ratings[athleteID] = (fppg: fppg, gamesPlayed: gamesPlayed)
        }

        return ratings
    }

    // MARK: - Salary Estimation

    /// Estimate NCAAFB DFS salary based on position and FPPG rating.
    /// QB: $5,000-$9,000, RB: $3,500-$7,500, WR: $3,000-$7,000,
    /// TE: $2,500-$5,500, K: $3,000-$4,500
    private func estimateNCAAFBSalary(position: String, fppg: Double, playerID: String) -> Int {
        let salary: Int

        switch position {
        case "QB":
            // QB: $5,000-$9,000 based on FPPG
            if fppg >= 25 {
                let fraction = min(1.0, (fppg - 25.0) / 15.0)
                salary = 7500 + Int(fraction * 1500.0)
            } else if fppg >= 15 {
                let fraction = (fppg - 15.0) / 10.0
                salary = 6000 + Int(fraction * 1500.0)
            } else if fppg >= 8 {
                let fraction = (fppg - 8.0) / 7.0
                salary = 5000 + Int(fraction * 1000.0)
            } else {
                salary = 5000
            }

        case "RB":
            // RB: $3,500-$7,500
            if fppg >= 20 {
                let fraction = min(1.0, (fppg - 20.0) / 10.0)
                salary = 6000 + Int(fraction * 1500.0)
            } else if fppg >= 12 {
                let fraction = (fppg - 12.0) / 8.0
                salary = 4500 + Int(fraction * 1500.0)
            } else if fppg >= 5 {
                let fraction = (fppg - 5.0) / 7.0
                salary = 3500 + Int(fraction * 1000.0)
            } else {
                salary = 3500
            }

        case "WR":
            // WR: $3,000-$7,000
            if fppg >= 18 {
                let fraction = min(1.0, (fppg - 18.0) / 10.0)
                salary = 5500 + Int(fraction * 1500.0)
            } else if fppg >= 10 {
                let fraction = (fppg - 10.0) / 8.0
                salary = 4000 + Int(fraction * 1500.0)
            } else if fppg >= 4 {
                let fraction = (fppg - 4.0) / 6.0
                salary = 3000 + Int(fraction * 1000.0)
            } else {
                salary = 3000
            }

        case "TE":
            // TE: $2,500-$5,500
            if fppg >= 12 {
                let fraction = min(1.0, (fppg - 12.0) / 8.0)
                salary = 4000 + Int(fraction * 1500.0)
            } else if fppg >= 6 {
                let fraction = (fppg - 6.0) / 6.0
                salary = 3000 + Int(fraction * 1000.0)
            } else {
                let fraction = max(0, fppg) / 6.0
                salary = 2500 + Int(fraction * 500.0)
            }

        case "K":
            // K: $3,000-$4,500
            if fppg >= 8 {
                let fraction = min(1.0, (fppg - 8.0) / 6.0)
                salary = 3800 + Int(fraction * 700.0)
            } else {
                let fraction = max(0, fppg) / 8.0
                salary = 3000 + Int(fraction * 800.0)
            }

        default:
            salary = 3000
        }

        // Stable per-player jitter +/-100, rounded to $100
        let stableHash = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = abs(stableHash % 200) - 100
        let rounded = ((salary + jitter + 50) / 100) * 100
        return max(2500, min(9000, rounded))
    }

    // MARK: - Projection

    /// Project fantasy points based on FPPG with regression toward position average.
    private func projectNCAAFBPoints(fppg: Double, position: String) -> Double {
        guard fppg > 0 else { return 0.0 }
        let positionAvg: Double
        switch position {
        case "QB": positionAvg = 18.0
        case "RB": positionAvg = 12.0
        case "WR": positionAvg = 10.0
        case "TE": positionAvg = 6.0
        case "K": positionAvg = 7.0
        default: positionAvg = 8.0
        }
        // 85% actual FPPG + 15% position average (mild regression)
        let projected = fppg * 0.85 + positionAvg * 0.15
        return (projected * 10).rounded() / 10
    }

    // MARK: - Helpers

    private func uniqueTeams(from events: [NCAAFBScoreboardEvent]) -> [(id: String, abbreviation: String)] {
        var seen = Set<String>()
        var result: [(id: String, abbreviation: String)] = []

        for event in events {
            for competition in event.competitions {
                for competitor in competition.competitors {
                    let id = competitor.team.id
                    guard seen.insert(id).inserted else { continue }
                    result.append((id: id, abbreviation: competitor.team.abbreviation))
                }
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

// MARK: - NCAAFB Live Scoring Provider

struct ESPNNCAAFBDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession

    private static let cfbDecoder: JSONDecoder = {
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
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unsupported CFB date: \(value)"))
        }
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// DraftKings College Football Scoring (same as NFL):
    /// - Pass Yard: +0.04 pts per yard
    /// - Pass TD: +4.0 pts
    /// - Interception thrown: -1.0 pt
    /// - Rush Yard: +0.1 pts per yard
    /// - Rush TD: +6.0 pts
    /// - Reception: +1.0 pt (PPR)
    /// - Receiving Yard: +0.1 pts per yard
    /// - Receiving TD: +6.0 pts
    /// - Fumble Lost: -1.0 pt
    /// - 2PT Conversion: +2.0 pts
    /// - FG Made: +3.0 pts
    /// - PAT Made: +1.0 pt
    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfo: [String: DFSGameLiveInfo] = [:]
        var allGamesFinal = true

        guard !games.isEmpty else {
            return DFSScoreSnapshot(playerFantasyPoints: [:], playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: true)
        }

        // Fetch all game summaries in parallel
        let gameResults: [(String, DFSGameLiveInfo, [(String, Double, DFSPlayerLiveStats)], Bool)] =
            await withTaskGroup(of: (String, DFSGameLiveInfo, [(String, Double, DFSPlayerLiveStats)], Bool)?.self) { group in
                for game in games {
                    group.addTask {
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/summary?event=\(game.id)") else {
                            return nil
                        }

                        guard let (data, response) = try? await self.session.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            return nil
                        }

                        // Extract game state
                        let gameInfo = self.extractGameLiveInfo(fromSummaryPayload: payload, game: game)
                        let gameFinal = gameInfo.state == "post"
                        let gameStatus = self.buildGameStatus(period: gameInfo.period, clock: gameInfo.clock, state: gameInfo.state)

                        // Extract player stats from boxscore
                        let playerResults = self.extractFootballPlayerStats(
                            fromSummaryPayload: payload,
                            gameStatus: gameStatus,
                            gameFinal: gameFinal
                        )

                        return (game.id, gameInfo, playerResults, gameFinal)
                    }
                }

                var collected: [(String, DFSGameLiveInfo, [(String, Double, DFSPlayerLiveStats)], Bool)] = []
                for await result in group {
                    if let result { collected.append(result) }
                }
                return collected
            }

        for (gameID, info, playerResults, isFinal) in gameResults {
            gameLiveInfo[gameID] = info
            if !isFinal { allGamesFinal = false }
            for (playerID, fantasy, stats) in playerResults {
                pointsByPlayerID[playerID] = fantasy
                statsByPlayerID[playerID] = stats
            }
        }

        if gameResults.isEmpty { allGamesFinal = false }

        return DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfo,
            allGamesFinal: allGamesFinal
        )
    }

    // MARK: - Extract Game Info

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
            state: state,
            sportType: "cfb"
        )
    }

    // MARK: - Build Game Status

    nonisolated private func buildGameStatus(period: Int, clock: String, state: String) -> String {
        if state == "post" { return "Final" }
        if state == "pre" { return "Pre" }
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

    // MARK: - Extract Football Player Stats

    /// Parse boxscore from ESPN summary for college football.
    /// ESPN football summaries have stat categories: passing, rushing, receiving, kicking.
    /// Each category has labels (column headers) and athletes with stat arrays.
    nonisolated private func extractFootballPlayerStats(
        fromSummaryPayload payload: [String: Any],
        gameStatus: String,
        gameFinal: Bool
    ) -> [(String, Double, DFSPlayerLiveStats)] {
        guard let boxscore = payload["boxscore"] as? [String: Any],
              let players = boxscore["players"] as? [[String: Any]] else {
            return []
        }

        // Accumulate stats per athlete across all categories (passing, rushing, receiving, kicking)
        struct AccumulatedStats {
            var name: String = ""
            var passYards: Int = 0
            var passTDs: Int = 0
            var interceptions: Int = 0
            var completions: Int = 0
            var passAttempts: Int = 0
            var rushYards: Int = 0
            var rushTDs: Int = 0
            var receptions: Int = 0
            var recYards: Int = 0
            var recTDs: Int = 0
            var targets: Int = 0
            var fumblesLost: Int = 0
            var fgMade: Int = 0
            var fgAttempted: Int = 0
            var patMade: Int = 0
            var patAttempted: Int = 0
        }

        var accumulated: [String: AccumulatedStats] = [:]

        for teamBlock in players {
            guard let statistics = teamBlock["statistics"] as? [[String: Any]] else { continue }
            for statCategory in statistics {
                guard let categoryName = statCategory["name"] as? String,
                      let labels = statCategory["labels"] as? [String],
                      let athletes = statCategory["athletes"] as? [[String: Any]] else { continue }

                var labelIndex: [String: Int] = [:]
                for (i, label) in labels.enumerated() {
                    labelIndex[label.uppercased()] = i
                }

                let category = categoryName.lowercased()

                for athlete in athletes {
                    guard let athleteInfo = athlete["athlete"] as? [String: Any],
                          let athleteID = athleteInfo["id"] as? String,
                          let values = athlete["stats"] as? [String] else { continue }

                    let athleteName = (athleteInfo["displayName"] as? String)
                        ?? (athleteInfo["shortName"] as? String)
                        ?? "Player \(athleteID)"

                    if accumulated[athleteID] == nil {
                        accumulated[athleteID] = AccumulatedStats(name: athleteName)
                    }

                    func intStat(_ key: String) -> Int {
                        guard let idx = labelIndex[key], idx < values.count else { return 0 }
                        return Int(Double(values[idx]) ?? 0)
                    }

                    func parseSlashStat(_ key: String) -> (Int, Int) {
                        guard let idx = labelIndex[key], idx < values.count else { return (0, 0) }
                        let parts = values[idx].split(separator: "/")
                        let a = parts.count >= 1 ? Int(parts[0]) ?? 0 : 0
                        let b = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
                        return (a, b)
                    }

                    switch category {
                    case "passing":
                        let (comp, att) = parseSlashStat("C/ATT")
                        accumulated[athleteID]?.completions += comp
                        accumulated[athleteID]?.passAttempts += att
                        accumulated[athleteID]?.passYards += intStat("YDS")
                        accumulated[athleteID]?.passTDs += intStat("TD")
                        accumulated[athleteID]?.interceptions += intStat("INT")

                    case "rushing":
                        accumulated[athleteID]?.rushYards += intStat("YDS")
                        accumulated[athleteID]?.rushTDs += intStat("TD")
                        accumulated[athleteID]?.fumblesLost += intStat("FUM")

                    case "receiving":
                        accumulated[athleteID]?.receptions += intStat("REC")
                        accumulated[athleteID]?.recYards += intStat("YDS")
                        accumulated[athleteID]?.recTDs += intStat("TD")
                        accumulated[athleteID]?.targets += intStat("TAR")

                    case "kicking":
                        let (fgm, fga) = parseSlashStat("FG")
                        let (patm, pata) = parseSlashStat("XP")
                        accumulated[athleteID]?.fgMade += fgm
                        accumulated[athleteID]?.fgAttempted += fga
                        accumulated[athleteID]?.patMade += patm
                        accumulated[athleteID]?.patAttempted += pata

                    default:
                        break
                    }
                }
            }
        }

        // Calculate fantasy points and build results
        var results: [(String, Double, DFSPlayerLiveStats)] = []

        for (athleteID, stats) in accumulated {
            // DraftKings College Football Scoring
            let fantasyPoints =
                Double(stats.passYards) * 0.04 +
                Double(stats.passTDs) * 4.0 -
                Double(stats.interceptions) * 1.0 +
                Double(stats.rushYards) * 0.1 +
                Double(stats.rushTDs) * 6.0 +
                Double(stats.receptions) * 1.0 +
                Double(stats.recYards) * 0.1 +
                Double(stats.recTDs) * 6.0 -
                Double(stats.fumblesLost) * 1.0 +
                Double(stats.fgMade) * 3.0 +
                Double(stats.patMade) * 1.0

            let roundedPts = (fantasyPoints * 10).rounded() / 10

            let playerID = "cfb-\(athleteID)"

            // Map college football stats to DFSPlayerLiveStats fields:
            // points -> passYards (int, scaled)
            // rebounds -> rushYards (int)
            // assists -> receptions (int)
            // steals -> passTDs (int)
            // blocks -> rushTDs (int)
            // turnovers -> interceptions + fumbles lost (int)
            // minutes -> game status string
            // fgm/fga -> completions/attempts
            // threePM/threePA -> receiving TDs / targets
            // ftm/fta -> field goals made/attempted
            let liveStats = DFSPlayerLiveStats(
                name: stats.name,
                points: stats.passYards,
                rebounds: stats.rushYards,
                assists: stats.receptions,
                steals: stats.passTDs,
                blocks: stats.rushTDs,
                turnovers: stats.interceptions + stats.fumblesLost,
                minutes: gameStatus,
                fgm: stats.completions, fga: stats.passAttempts,
                threePM: stats.recTDs, threePA: stats.targets,
                ftm: stats.fgMade, fta: stats.fgAttempted,
                fantasyPoints: roundedPts,
                gameStatus: gameStatus,
                gameFinal: gameFinal
            )

            results.append((playerID, roundedPts, liveStats))
        }

        return results
    }

    static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - NCAAFB ESPN Codable Models

struct NCAAFBScoreboardResponse: Codable, Sendable {
    let events: [NCAAFBScoreboardEvent]
}

struct NCAAFBScoreboardEvent: Codable, Sendable {
    let id: String
    let name: String?
    let date: Date
    let competitions: [NCAAFBScoreboardCompetition]
}

struct NCAAFBScoreboardCompetition: Codable, Sendable {
    let id: String
    let date: Date
    let competitors: [NCAAFBScoreboardCompetitor]
    let status: NCAAFBCompetitionStatus
}

struct NCAAFBScoreboardCompetitor: Codable, Sendable {
    let id: String
    let homeAway: String?
    let team: NCAAFBTeamRef
    let score: String?
}

struct NCAAFBTeamRef: Codable, Sendable {
    let id: String
    let abbreviation: String
    let displayName: String?
    let shortDisplayName: String?
}

struct NCAAFBCompetitionStatus: Codable, Sendable {
    let clock: Double?
    let displayClock: String?
    let period: Int?
    let type: NCAAFBStatusType
}

struct NCAAFBStatusType: Codable, Sendable {
    let id: String?
    let name: String?
    let state: String
    let completed: Bool?
}

struct NCAAFBRosterResponse: Codable, Sendable {
    let athletes: [NCAAFBRosterAthleteGroup]?
}

struct NCAAFBRosterAthleteGroup: Codable, Sendable {
    let position: String?
    let items: [NCAAFBRosterAthlete]?
}

struct NCAAFBRosterAthlete: Codable, Sendable {
    let id: String
    let fullName: String?
    let displayName: String?
    let shortName: String?
    let position: NCAAFBRosterPosition?
    let injuries: [NCAAFBRosterInjury]?
}

struct NCAAFBRosterPosition: Codable, Sendable {
    let abbreviation: String?
}

struct NCAAFBRosterInjury: Codable, Sendable {
    let status: String?
}
