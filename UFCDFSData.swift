import Foundation

// MARK: - UFC DFS Slate Provider

/// Simple in-memory cache for UFC slates (mirrors SoccerSlateCache pattern)
private final class UFCSlateCache {
    static let shared = UFCSlateCache()
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

struct ESPNUFCDFSSlateProvider: DFSSlateProvider {
    private let session: URLSession

    private static let ufcDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            // Try ISO 8601 variants
            let formatters: [DateFormatter] = [
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"; return f }(),
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f }(),
                { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return f }(),
            ]
            for formatter in formatters {
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unsupported UFC date: \(value)"))
        }
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        if let cached = UFCSlateCache.shared.get() {
            return cached
        }

        // Start fetching real DraftKings salaries in parallel with ESPN data
        async let rgSalaries = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "mma", maxClassicSalary: 12000)

        // 1. Fetch the upcoming UFC card (event) with all fights (competitions)
        let (_, fights) = try await fetchUFCCard()
        guard !fights.isEmpty else {
            throw NSError(domain: "UFCDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No UFC fights found"])
        }

        // 2. Build included games — each fight is a "game"
        let includedGames: [DFSSlateGame] = fights.map { fight in
            DFSSlateGame(
                id: fight.id,
                awayTeam: fight.fighter1Abbrev,
                homeTeam: fight.fighter2Abbrev,
                startTime: fight.startTime,
                state: fight.state
            )
        }

        // 3. Build player pool — each fighter is a "player" (with estimated salaries as baseline)
        var players: [DFSPlayer] = []
        for fight in fights {
            let f1Salary = estimateUFCSalary(record: fight.fighter1Record, isFavorite: fight.fighter1Order == 1, fightIndex: fight.cardPosition, totalFights: fights.count, athleteID: fight.fighter1ID)
            let f2Salary = estimateUFCSalary(record: fight.fighter2Record, isFavorite: fight.fighter2Order == 1, fightIndex: fight.cardPosition, totalFights: fights.count, athleteID: fight.fighter2ID)
            let f1Proj = projectUFCPoints(salary: f1Salary, athleteID: fight.fighter1ID)
            let f2Proj = projectUFCPoints(salary: f2Salary, athleteID: fight.fighter2ID)

            players.append(DFSPlayer(
                id: "ufc-\(fight.fighter1ID)",
                name: fight.fighter1Name,
                team: fight.weightClass,
                position: "F",
                salary: f1Salary,
                projectedPoints: f1Proj,
                gameID: fight.id
            ))
            players.append(DFSPlayer(
                id: "ufc-\(fight.fighter2ID)",
                name: fight.fighter2Name,
                team: fight.weightClass,
                position: "F",
                salary: f2Salary,
                projectedPoints: f2Proj,
                gameID: fight.id
            ))
        }

        guard !players.isEmpty else {
            throw NSError(domain: "UFCDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "No UFC fighters available"])
        }

        // 4. Apply real DraftKings salaries from RotoGrinders where available
        let realSalaries = await rgSalaries
        let finalPlayers: [DFSPlayer]
        if !realSalaries.isEmpty {
            let matchCount = players.filter { RotoGrindersSalaryProvider.lookupSalary(espnName: $0.name, in: realSalaries) != nil }.count
            let matchRate = Double(matchCount) / Double(max(1, players.count))
            let sameSlate = matchRate > 0.30

            if sameSlate {
                let rgMin = realSalaries.values.min() ?? 5000
                let rgMax = realSalaries.values.max() ?? 12000
                let allProjs = players.map { $0.projectedPoints }
                let projMin = allProjs.min() ?? 0
                let projMax = max(projMin + 1, allProjs.max() ?? 50)

                var applied = 0
                var calibrated = 0
                finalPlayers = players.map { player in
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
                    // Unmatched fighter — calibrate salary to RG range using projection
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
                print("[UFC-DFS] sameSlate=true (\(matchCount)/\(players.count)), applied=\(applied), calibrated=\(calibrated), range=$\(rgMin)-$\(rgMax)")
            } else {
                // Slates don't match — keep estimated salaries
                print("[UFC-DFS] sameSlate=false (\(matchCount)/\(players.count)), keeping estimated salaries")
                finalPlayers = players
            }
        } else {
            print("[UFC-DFS] No real salary data available — using estimated salaries")
            finalPlayers = players
        }

        let sortedPlayers = finalPlayers.sorted(by: { $0.salary > $1.salary })

        // 5. Build tournaments using shared builder
        let slateDate = fights.first?.startTime ?? Date()
        let tournamentID = "ufc-\(dateKey(for: slateDate))"
        let isSingleGame = includedGames.count == 1

        let (tournaments, sgPlayers) = buildMultiTournamentSlate(
            baseID: tournamentID,
            league: "UFC",
            mainSalaryCap: 50000,
            mainLineupSize: 6,
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
        UFCSlateCache.shared.set(slate)
        return slate
    }

    // MARK: - Fetch UFC Card

    /// Represents a single fight on the card
    struct UFCFight {
        let id: String              // competition ID
        let fighter1ID: String
        let fighter1Name: String
        let fighter1Abbrev: String  // short name for display
        let fighter1Record: String  // "21-4-0"
        let fighter1Order: Int
        let fighter2ID: String
        let fighter2Name: String
        let fighter2Abbrev: String
        let fighter2Record: String
        let fighter2Order: Int
        let weightClass: String     // "Bantamweight", "Featherweight", etc.
        let startTime: Date
        let state: String           // "pre", "in", "post"
        let cardPosition: Int       // position on card (0 = main event)
        let rounds: Int             // 3 or 5
    }

    /// Fetch the next UFC card. Returns the event name and array of fights.
    private func fetchUFCCard() async throws -> (eventName: String, fights: [UFCFight]) {
        // Fetch scoreboard for today, tomorrow, and next 7 days to find the next card
        let calendar = Calendar.current
        let datesToCheck = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
        let dateStrings = datesToCheck.map { dateKey(for: $0) }

        // Also check recent past days for live/post events
        let pastDates = (-2...(-1)).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
        let pastDateStrings = pastDates.map { dateKey(for: $0) }
        let allDateStrings = pastDateStrings + dateStrings

        // Fetch all scoreboards in parallel
        let scoreboards: [UFCScoreboardResponse] = await withTaskGroup(of: UFCScoreboardResponse?.self) { group in
            for dk in allDateStrings {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=\(dk)") else { return nil }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    return try? Self.ufcDecoder.decode(UFCScoreboardResponse.self, from: data)
                }
            }
            var results: [UFCScoreboardResponse] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        // Find the best event: prefer live, then upcoming, then most recent completed
        var allEvents: [UFCScoreboardEvent] = []
        for sb in scoreboards {
            allEvents.append(contentsOf: sb.events)
        }

        // Deduplicate events by ID
        var seenIDs = Set<String>()
        allEvents = allEvents.filter { seenIDs.insert($0.id).inserted }

        // Categorize events
        var liveEvents: [UFCScoreboardEvent] = []
        var preEvents: [UFCScoreboardEvent] = []
        var postEvents: [UFCScoreboardEvent] = []

        for event in allEvents {
            // Check if any competition is live
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

        // Pick the best event
        let selectedEvent: UFCScoreboardEvent
        if let live = liveEvents.first {
            selectedEvent = live
        } else if let pre = preEvents.sorted(by: { $0.date < $1.date }).first {
            selectedEvent = pre
        } else if let post = postEvents.sorted(by: { $0.date > $1.date }).first {
            // Most recent completed event
            selectedEvent = post
        } else {
            throw NSError(domain: "UFCDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No UFC events found"])
        }

        let eventName = selectedEvent.name ?? "UFC"

        // Parse competitions (fights) — reverse so main event is last (highest card position)
        let sortedComps = selectedEvent.competitions.sorted { comp1, comp2 in
            comp1.date > comp2.date  // later fights = higher on card
        }

        var fights: [UFCFight] = []
        for (index, comp) in sortedComps.enumerated() {
            guard comp.competitors.count == 2 else { continue }
            let c1 = comp.competitors[0]
            let c2 = comp.competitors[1]

            let weightClass = comp.type?.abbreviation ?? "Unknown"
            let compDate = comp.date
            let state = comp.status.type.state
            let rounds = comp.format?.regulation?.periods ?? 3

            fights.append(UFCFight(
                id: comp.id,
                fighter1ID: c1.id,
                fighter1Name: c1.athlete.displayName ?? c1.athlete.fullName ?? "Fighter 1",
                fighter1Abbrev: c1.athlete.shortName ?? String((c1.athlete.displayName ?? "F1").prefix(12)),
                fighter1Record: c1.records?.first?.summary ?? "0-0-0",
                fighter1Order: c1.order ?? 1,
                fighter2ID: c2.id,
                fighter2Name: c2.athlete.displayName ?? c2.athlete.fullName ?? "Fighter 2",
                fighter2Abbrev: c2.athlete.shortName ?? String((c2.athlete.displayName ?? "F2").prefix(12)),
                fighter2Record: c2.records?.first?.summary ?? "0-0-0",
                fighter2Order: c2.order ?? 2,
                weightClass: weightClass,
                startTime: compDate,
                state: state,
                cardPosition: index,
                rounds: rounds
            ))
        }

        print("[UFC-DFS] Found \(fights.count) fights on card: \(eventName)")
        return (eventName: eventName, fights: fights)
    }

    // MARK: - Salary Estimation

    /// Estimate UFC DFS salary based on record, card position, and fight favoritism.
    /// Main event fighters get the highest salaries, prelim fighters get lower.
    /// Better records (more wins) push salary up.
    private func estimateUFCSalary(record: String, isFavorite: Bool, fightIndex: Int, totalFights: Int, athleteID: String) -> Int {
        // Parse record "W-L-D"
        let parts = record.split(separator: "-").compactMap { Int($0) }
        let wins = parts.count > 0 ? parts[0] : 0
        let losses = parts.count > 1 ? parts[1] : 0
        let totalFightsRecord = wins + losses

        // Win percentage (0.0 - 1.0)
        let winPct = totalFightsRecord > 0 ? Double(wins) / Double(totalFightsRecord) : 0.5

        // Card position factor: main event fighters (index 0-2) get premium
        let positionFactor: Double
        if fightIndex <= 1 {
            positionFactor = 1.3  // Main/co-main event
        } else if fightIndex <= 4 {
            positionFactor = 1.1  // Main card
        } else if fightIndex <= 8 {
            positionFactor = 0.9  // Prelims
        } else {
            positionFactor = 0.75 // Early prelims
        }

        // Experience factor: more experienced fighters get slight premium
        let expFactor = min(1.2, 0.7 + Double(min(totalFightsRecord, 30)) * 0.017)

        // Base salary: $7000-$10000 for average, adjusted by factors
        let baseSalary = 8000.0
        let rawSalary = baseSalary * positionFactor * expFactor * (0.7 + winPct * 0.6)

        // Favorite gets a slight bump
        let favoriteBump = isFavorite ? 1.08 : 0.92

        // Add deterministic per-player variance so fighters in the same fight
        // don't end up at identical salaries
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let hashVariance = Double(abs(stableHash % 500)) - 250.0  // -250 to +250

        let finalSalary = Int(rawSalary * favoriteBump) + Int(hashVariance)
        let rounded = (finalSalary / 100) * 100
        return max(5000, min(12000, rounded))
    }

    // MARK: - Projection

    /// Project fantasy points based on salary tier.
    /// UFC DK scoring: sig strikes landed (0.6), takedowns (5), knockdowns (10),
    /// submission attempts (3), win bonus (varies by method).
    private func projectUFCPoints(salary: Int, athleteID: String) -> Double {
        let salaryK = Double(salary) / 1000.0

        // Base projection scales with salary
        // $12K fighter: ~55-65 pts, $8K: ~35-45 pts, $5K: ~20-30 pts
        let baseProj: Double
        if salaryK >= 11.0 {
            baseProj = 58.0 + (salaryK - 11.0) * 5.0
        } else if salaryK >= 9.0 {
            baseProj = 42.0 + (salaryK - 9.0) * 8.0
        } else if salaryK >= 7.0 {
            baseProj = 30.0 + (salaryK - 7.0) * 6.0
        } else {
            baseProj = 18.0 + (salaryK - 5.0) * 6.0
        }

        // Deterministic per-fighter variance
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let hashFraction = Double(abs(stableHash % 1000)) / 1000.0
        let variance = (hashFraction - 0.5) * baseProj * 0.15  // +/- 7.5%

        return max(8.0, (baseProj + variance * 10).rounded() / 10)
    }

    // MARK: - Helpers

    private func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - UFC Live Scoring Provider

struct ESPNUFCDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession

    private static let ufcDecoder: JSONDecoder = {
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
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unsupported UFC date: \(value)"))
        }
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// DraftKings UFC Scoring:
    /// - Significant Strike Landed: +0.6 pts
    /// - Takedown Landed: +5.0 pts
    /// - Knockdown: +10.0 pts
    /// - Submission Attempt: +3.0 pts
    /// - Fight Win: +30.0 pts (base)
    /// - KO/TKO Win Bonus: +30.0 pts (total 60 for KO win)
    /// - Submission Win Bonus: +20.0 pts (total 50 for sub win)
    /// - Decision Win: +30.0 pts (just the base)
    /// - Reversal: +3.0 pts
    /// - Advance to mount/back: +5.0 pts
    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        var pointsByPlayerID: [String: Double] = [:]
        var statsByPlayerID: [String: DFSPlayerLiveStats] = [:]
        var gameLiveInfo: [String: DFSGameLiveInfo] = [:]
        var allGamesFinal = true

        // Fetch the UFC event scoreboard to get current state and results
        // We need the event ID — extract from the first game
        guard !games.isEmpty else {
            return DFSScoreSnapshot(playerFantasyPoints: [:], playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: true)
        }

        // Fetch the current scoreboard to get competition statuses
        let today = Self.dateKey(for: Date())
        let yesterday = Self.dateKey(for: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        let tomorrow = Self.dateKey(for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())

        var allComps: [String: UFCScoreboardCompetition] = [:]  // compID → competition
        var eventIDForComp: [String: String] = [:]  // compID → eventID

        for dk in [yesterday, today, tomorrow] {
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=\(dk)") else { continue }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let sb = try? Self.ufcDecoder.decode(UFCScoreboardResponse.self, from: data) else { continue }
            for event in sb.events {
                for comp in event.competitions {
                    allComps[comp.id] = comp
                    eventIDForComp[comp.id] = event.id
                }
            }
        }

        // Process each fight (game)
        for game in games {
            guard let comp = allComps[game.id] else {
                // Fight not found on scoreboard — assume still scheduled
                gameLiveInfo[game.id] = DFSGameLiveInfo(
                    id: game.id, awayTeam: game.awayTeam, homeTeam: game.homeTeam,
                    awayScore: 0, homeScore: 0, clock: "",
                    period: 0, state: "pre", sportType: "ufc"
                )
                allGamesFinal = false
                continue
            }

            let state = comp.status.type.state
            let period = comp.status.period ?? 0
            let clock = comp.status.displayClock ?? ""

            if state != "post" {
                allGamesFinal = false
            }

            // Build game info
            gameLiveInfo[game.id] = DFSGameLiveInfo(
                id: game.id, awayTeam: game.awayTeam, homeTeam: game.homeTeam,
                awayScore: 0, homeScore: 0,
                clock: clock.isEmpty ? "" : "R\(period) \(clock)",
                period: period, state: state, sportType: "ufc"
            )

            // For completed or in-progress fights, fetch detailed stats
            if state == "post" || state == "in" {
                guard let eventID = eventIDForComp[game.id] else { continue }

                for competitor in comp.competitors {
                    let playerID = "ufc-\(competitor.id)"
                    let isWinner = competitor.winner ?? false
                    let fighterName = competitor.athlete.shortName ?? competitor.athlete.displayName ?? "Fighter"

                    // Fetch detailed statistics from the core API
                    let stats = await fetchFighterStats(eventID: eventID, competitionID: game.id, athleteID: competitor.id)

                    var pts = 0.0
                    var statLine = ""

                    // Significant strikes
                    let sigStrikes = stats["sigStrikesLanded"] ?? 0
                    pts += sigStrikes * 0.6

                    // Takedowns
                    let takedowns = stats["takedownsLanded"] ?? 0
                    pts += takedowns * 5.0

                    // Knockdowns
                    let knockdowns = stats["knockDowns"] ?? 0
                    pts += knockdowns * 10.0

                    // Submission attempts
                    let subAttempts = stats["submissions"] ?? 0
                    pts += subAttempts * 3.0

                    // Reversals
                    let reversals = stats["reversals"] ?? 0
                    pts += reversals * 3.0

                    // Advances to mount/back
                    let advMount = stats["advanceToMount"] ?? 0
                    let advBack = stats["advanceToBack"] ?? 0
                    pts += (advMount + advBack) * 5.0

                    // Win bonus (only for completed fights)
                    if state == "post" && isWinner {
                        pts += 30.0  // Base win bonus

                        // Check finish type from status
                        let resultName = comp.status.result?.name ?? ""
                        if resultName.contains("kotko") {
                            pts += 30.0  // KO/TKO bonus
                            statLine = "W (KO/TKO)"
                        } else if resultName.contains("submission") {
                            pts += 20.0  // Submission bonus
                            statLine = "W (Sub)"
                        } else {
                            statLine = "W (Dec)"
                        }
                    } else if state == "post" && !isWinner {
                        statLine = "L"
                    } else {
                        statLine = "R\(period)"
                    }

                    // Build detailed stat line
                    let detailStats = "\(Int(sigStrikes))SS \(Int(takedowns))TD \(Int(knockdowns))KD"
                    if !statLine.isEmpty {
                        statLine = "\(statLine) | \(detailStats)"
                    } else {
                        statLine = detailStats
                    }

                    let roundedPts = (pts * 10).rounded() / 10
                    pointsByPlayerID[playerID] = roundedPts
                    statsByPlayerID[playerID] = DFSPlayerLiveStats(
                        name: fighterName,
                        points: Int(sigStrikes),
                        rebounds: Int(takedowns),
                        assists: Int(knockdowns),
                        steals: Int(subAttempts),
                        blocks: Int(reversals),
                        turnovers: Int(advMount + advBack),
                        minutes: statLine,
                        fgm: 0, fga: 0,
                        threePM: 0, threePA: 0,
                        ftm: 0, fta: 0,
                        fantasyPoints: roundedPts,
                        gameStatus: state == "post" ? "Final" : "R\(period)",
                        gameFinal: state == "post"
                    )
                }
            }
        }

        return DFSScoreSnapshot(
            playerFantasyPoints: pointsByPlayerID,
            playerLiveStats: statsByPlayerID,
            gameLiveInfo: gameLiveInfo,
            allGamesFinal: allGamesFinal
        )
    }

    /// Fetch detailed fight statistics for a specific fighter from the ESPN core API
    private func fetchFighterStats(eventID: String, competitionID: String, athleteID: String) async -> [String: Double] {
        let urlString = "https://sports.core.api.espn.com/v2/sports/mma/leagues/ufc/events/\(eventID)/competitions/\(competitionID)/competitors/\(athleteID)/statistics"
        guard let url = URL(string: urlString) else { return [:] }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let splits = json["splits"] as? [String: Any],
              let categories = splits["categories"] as? [[String: Any]] else {
            return [:]
        }

        var stats: [String: Double] = [:]
        for category in categories {
            guard let statArr = category["stats"] as? [[String: Any]] else { continue }
            for stat in statArr {
                if let name = stat["name"] as? String,
                   let value = stat["value"] as? Double {
                    stats[name] = value
                }
            }
        }
        return stats
    }

    private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - UFC ESPN Codable Models

struct UFCScoreboardResponse: Codable, Sendable {
    let events: [UFCScoreboardEvent]
}

struct UFCScoreboardEvent: Codable, Sendable {
    let id: String
    let name: String?
    let date: Date
    let competitions: [UFCScoreboardCompetition]
}

struct UFCScoreboardCompetition: Codable, Sendable {
    let id: String
    let date: Date
    let competitors: [UFCScoreboardCompetitor]
    let status: UFCCompetitionStatus
    let type: UFCCompetitionType?
    let format: UFCCompetitionFormat?
}

struct UFCScoreboardCompetitor: Codable, Sendable {
    let id: String
    let order: Int?
    let winner: Bool?
    let athlete: UFCAthleteInfo
    let records: [UFCRecord]?
}

struct UFCAthleteInfo: Codable, Sendable {
    let fullName: String?
    let displayName: String?
    let shortName: String?
}

struct UFCRecord: Codable, Sendable {
    let summary: String?
    let type: String?
}

struct UFCCompetitionStatus: Codable, Sendable {
    let clock: Double?
    let displayClock: String?
    let period: Int?
    let type: UFCStatusType
    let result: UFCStatusResult?
}

struct UFCStatusType: Codable, Sendable {
    let id: String?
    let name: String?
    let state: String        // "pre", "in", "post"
    let completed: Bool?
}

struct UFCStatusResult: Codable, Sendable {
    let id: Int?
    let name: String?        // "decision---unanimous", "kotko", "submission"
    let displayName: String?
    let shortDisplayName: String?
    let description: String?
}

struct UFCCompetitionType: Codable, Sendable {
    let id: String?
    let abbreviation: String?  // "Bantamweight", "Featherweight", etc.
}

struct UFCCompetitionFormat: Codable, Sendable {
    let regulation: UFCFormatRegulation?
}

struct UFCFormatRegulation: Codable, Sendable {
    let periods: Int?  // 3 or 5 rounds
}
