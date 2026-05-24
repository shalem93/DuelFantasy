import Foundation

// MARK: - ESPN PGA Scoreboard Codable Models

struct ESPNPGAScoreboardResponse: Codable {
    let events: [ESPNPGAEvent]
}

struct ESPNPGAEvent: Codable {
    let id: String
    let name: String
    let shortName: String?
    let date: String                        // ISO date string
    let endDate: String?                    // ISO date string
    let competitions: [ESPNPGACompetition]
    let status: ESPNPGAEventStatus
    let season: ESPNPGASeason?
}

struct ESPNPGACompetition: Codable {
    let id: String
    let competitors: [ESPNPGACompetitor]
    let venue: ESPNPGAVenue?
    let status: ESPNPGACompetitionStatus?
}

struct ESPNPGACompetitor: Codable {
    let id: String                          // this is the athlete ID
    let athlete: ESPNPGAAthlete
    let status: ESPNPGACompetitorStatus?
    let score: ESPNPGAScore?
    let linescores: [ESPNPGALineScore]?
    let order: Int?                         // field seeding (1 = top, 150 = bottom)
    let statistics: [ESPNPGAStatistic]?
}

struct ESPNPGAAthlete: Codable {
    let displayName: String
    let shortName: String?
    let fullName: String?
    let flag: ESPNPGAFlag?
    let headshot: ESPNPGAHeadshot?
}

struct ESPNPGAFlag: Codable {
    let alt: String?                       // country name
    let href: String?                      // flag image URL
}

struct ESPNPGAHeadshot: Codable {
    let href: String?
}

struct ESPNPGACompetitorStatus: Codable {
    let period: Int?                       // current round (1-4)
    let type: ESPNPGAStatusType?
    let displayValue: String?              // e.g. "T5", "CUT", "WD"
}

struct ESPNPGAStatusType: Codable {
    let id: String?
    let name: String?                      // "STATUS_ACTIVE", "STATUS_CUT", "STATUS_WITHDRAWN"
    let state: String?
    let completed: Bool?
    let description: String?
}

/// Score can be a plain string ("E", "-8") or an object with displayValue/value.
/// We handle both via custom decoding.
struct ESPNPGAScore: Codable {
    let displayValue: String?              // e.g. "-8" (total score to par)
    let value: Double?                     // numeric score to par

    init(displayValue: String?, value: Double?) {
        self.displayValue = displayValue
        self.value = value
    }

    init(from decoder: Decoder) throws {
        // Try decoding as a plain string first
        if let container = try? decoder.singleValueContainer(),
           let str = try? container.decode(String.self) {
            self.displayValue = str
            // Parse numeric value from string like "-8", "+2", "E"
            if str == "E" {
                self.value = 0
            } else {
                self.value = Double(str)
            }
            return
        }
        // Otherwise decode as object
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayValue = try container.decodeIfPresent(String.self, forKey: .displayValue)
        self.value = try container.decodeIfPresent(Double.self, forKey: .value)
    }

    enum CodingKeys: String, CodingKey {
        case displayValue, value
    }
}

struct ESPNPGALineScore: Codable {
    let period: Int?                       // round number (1-4)
    let displayValue: String?              // round score e.g. "68"
    let value: Double?                     // numeric round score
    let linescores: [ESPNPGAHoleScore]?    // per-hole scores within this round
}

struct ESPNPGAHoleScore: Codable {
    let period: Int?                       // hole number (1-18)
    let value: Double?                     // strokes taken
    let displayValue: String?              // strokes as string
    let scoreType: ESPNPGAScoreType?       // birdie/par/bogey/eagle etc.
}

struct ESPNPGAScoreType: Codable {
    let name: String?                      // "BIRDIE", "PAR", "BOGEY", "EAGLE", "DOUBLE_BOGEY", "DOUBLE_EAGLE"
    let displayName: String?               // "Birdie", "Par", "Bogey", etc.
    let displayValue: String?              // "-1", "0", "+1", "-2", "-3", etc.
}

struct ESPNPGAStatistic: Codable {
    let name: String?
    let displayValue: String?
}

struct ESPNPGAVenue: Codable {
    let fullName: String?
    let address: ESPNPGAVenueAddress?
}

struct ESPNPGAVenueAddress: Codable {
    let city: String?
    let state: String?
}

struct ESPNPGAEventStatus: Codable {
    let type: ESPNPGAEventStatusType
}

struct ESPNPGAEventStatusType: Codable {
    let id: String?
    let name: String?                      // "STATUS_SCHEDULED", "STATUS_IN_PROGRESS", "STATUS_FINAL"
    let state: String?                     // "pre", "in", "post"
    let completed: Bool?
}

struct ESPNPGASeason: Codable {
    let year: Int?
}

struct ESPNPGACompetitionStatus: Codable {
    let period: Int?                       // current round number
    let type: ESPNPGAStatusType?
}

// MARK: - ESPN PGA Slate Provider

struct ESPNPGADFSSlateProvider: DFSSlateProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSlate() async throws -> DFSSlate {
        // Fetch PGA Tour scoreboard
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard") else {
            throw NSError(domain: "GolfDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid PGA scoreboard URL"])
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GolfDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "PGA scoreboard request failed"])
        }

        let scoreboard = try JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: data)

        // Find current or next PGA event
        guard let event = pickActiveEvent(from: scoreboard.events) else {
            throw NSError(domain: "GolfDFS", code: 3, userInfo: [NSLocalizedDescriptionKey: "No active PGA Tour event found"])
        }

        guard let competition = event.competitions.first else {
            throw NSError(domain: "GolfDFS", code: 4, userInfo: [NSLocalizedDescriptionKey: "No competition data in event"])
        }

        // Fetch DraftKings salaries (primary) and OWGR world rankings (fallback)
        async let dkSalariesTask = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "golf", maxClassicSalary: 15000)
        async let worldRankTask = fetchOWGRRankings()
        let dkSalaries = await dkSalariesTask
        let worldRankByName = await worldRankTask

        if dkSalaries.isEmpty {
            print("[GolfDFS] No DK salaries found — using OWGR-based pricing")
        } else {
            print("[GolfDFS] Fetched \(dkSalaries.count) DraftKings golf salaries")
        }

        // Map competitors to DFSPlayer using DK salary (primary) or world ranking (fallback)
        let players: [DFSPlayer] = competition.competitors.compactMap { competitor in
            let athleteID = competitor.id
            let name = competitor.athlete.displayName
            let country = competitor.athlete.flag?.alt ?? ""
            let worldRank = matchWorldRanking(name: name, rankings: worldRankByName)

            // Try DK salary lookup first, fall back to OWGR-based estimate
            let salary: Int
            if let dkSalary = RotoGrindersSalaryProvider.lookupSalary(espnName: name, in: dkSalaries) {
                salary = dkSalary
            } else {
                salary = salaryFromWorldRanking(worldRank, athleteID: athleteID)
            }

            let projection = projectedGolfPoints(salary: salary, worldRank: worldRank, athleteID: athleteID)

            return DFSPlayer(
                id: "pga-\(athleteID)",
                name: name,
                team: country,          // country instead of team for golf
                position: "G",
                salary: salary,
                projectedPoints: projection,
                gameID: event.id
            )
        }

        guard !players.isEmpty else {
            throw NSError(domain: "GolfDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "No golfers found in event"])
        }

        // Parse start date and set lock time to 4:00 AM ET on tournament day
        // ESPN often returns midnight UTC which locks lineups too early.
        let rawDate = parseESPNDate(event.date) ?? Date()
        let startDate: Date = {
            let eastern = TimeZone(identifier: "America/New_York")!
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = eastern
            let components = cal.dateComponents([.year, .month, .day], from: rawDate)
            var lockComponents = components
            lockComponents.hour = 4
            lockComponents.minute = 0
            lockComponents.second = 0
            return cal.date(from: lockComponents) ?? rawDate
        }()
        let venueName = competition.venue?.fullName ?? ""
        let eventName = event.name

        let tournamentID = "pga-\(event.id)"

        // Create multiple contest sizes (matching other DFS sports)
        let fieldSizes = [2, 3, 5, 10, 2000]
        let tournaments = fieldSizes.map { size in
            DFSTournament(
                id: "\(tournamentID)-\(size)",
                title: eventName,
                league: "PGA",
                entryCount: size,
                lineupSize: 6,
                salaryCap: 50000
            )
        }

        let slate = DFSSlate(
            tournaments: tournaments,
            includedGames: [
                DFSSlateGame(
                    id: event.id,
                    awayTeam: venueName,           // repurpose: venue name
                    homeTeam: eventName,           // repurpose: event name
                    startTime: startDate,
                    state: event.status.type.state ?? "pre"
                )
            ],
            players: players.sorted(by: { $0.salary > $1.salary })
        )

        return slate
    }

    /// Pick the current in-progress or next upcoming PGA event
    private func pickActiveEvent(from events: [ESPNPGAEvent]) -> ESPNPGAEvent? {
        // Prefer in-progress events first
        if let live = events.first(where: { $0.status.type.state == "in" }) {
            return live
        }
        // Then upcoming (pre) events
        if let upcoming = events.first(where: { $0.status.type.state == "pre" }) {
            return upcoming
        }
        // Then recently finished (post) events — for settlement
        if let finished = events.first(where: { $0.status.type.state == "post" }) {
            return finished
        }
        // Fallback to first event
        return events.first
    }

    // MARK: - OWGR World Rankings

    /// Fetch Official World Golf Rankings for salary pricing.
    /// Returns a dictionary of normalized lowercase player name → world ranking position.
    private func fetchOWGRRankings() async -> [String: Int] {
        // Fetch top 400 to cover most PGA Tour fields
        guard let url = URL(string: "https://apiweb.owgr.com/api/owgr/rankings/getRankings?pageSize=400&pageNumber=1") else {
            return [:]
        }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rankingsList = json["rankingsList"] as? [[String: Any]] else {
            return [:]
        }

        var result: [String: Int] = [:]
        for entry in rankingsList {
            guard let rank = entry["rank"] as? Int,
                  let player = entry["player"] as? [String: Any],
                  let fullName = player["fullName"] as? String else { continue }
            result[fullName.lowercased()] = rank
        }
        return result
    }

    /// Normalize a name for matching: lowercase, strip diacritics, and replace special Nordic chars.
    private func normalizeForMatching(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ð", with: "d")
            .replacingOccurrences(of: "þ", with: "th")
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    /// Match an ESPN player name to OWGR rankings.
    /// Handles common name differences (e.g., accented characters, Nordic letters, Jr/III suffixes).
    private func matchWorldRanking(name: String, rankings: [String: Int]) -> Int {
        let normalized = normalizeForMatching(name)

        // Direct match
        if let rank = rankings[name.lowercased()] { return rank }

        // Normalized match (handles diacritics + Nordic chars)
        for (rName, rank) in rankings {
            if normalizeForMatching(rName) == normalized { return rank }
        }

        // Last name only match (unique last name in field)
        let parts = normalized.split(separator: " ")
        if parts.count >= 2 {
            let lastName = String(parts.last!)
            var matches: [(String, Int)] = []
            for (rName, rank) in rankings {
                let rNorm = normalizeForMatching(rName)
                let rParts = rNorm.split(separator: " ")
                if let rLast = rParts.last, String(rLast) == lastName {
                    matches.append((rName, rank))
                }
            }
            // Only use last-name match if it's unambiguous (exactly 1 match)
            if matches.count == 1 { return matches[0].1 }
        }

        // Not found in OWGR — return high value (unranked)
        return 999
    }

    /// Map OWGR world ranking to DK-style salary.
    /// Modeled after real DraftKings PGA pricing:
    ///   #1  Scheffler:  ~$12,000    #50 mid-tier:  ~$8,000
    ///   #5  Schauffele: ~$11,000    #100:          ~$7,000
    ///   #10 top-10:     ~$10,000    #200+:         ~$6,200-6,500
    ///   #25:            ~$9,000     Unranked:      ~$6,000-6,200
    private func salaryFromWorldRanking(_ worldRank: Int, athleteID: String = "") -> Int {
        let baseSalary: Int
        switch worldRank {
        case 1:
            baseSalary = 12200
        case 2...3:
            baseSalary = 11600 + (4 - worldRank) * 200     // $11,800 - $12,000
        case 4...7:
            baseSalary = 10800 + (8 - worldRank) * 200     // $11,000 - $11,600
        case 8...12:
            baseSalary = 10000 + (13 - worldRank) * 160    // $10,160 - $10,800
        case 13...20:
            baseSalary = 9200 + (21 - worldRank) * 100     // $9,300 - $10,000
        case 21...35:
            baseSalary = 8200 + (36 - worldRank) * 67      // $8,267 - $9,205
        case 36...50:
            baseSalary = 7600 + (51 - worldRank) * 40      // $7,640 - $8,200
        case 51...75:
            baseSalary = 7000 + (76 - worldRank) * 24      // $7,024 - $7,600
        case 76...100:
            baseSalary = 6600 + (101 - worldRank) * 16     // $6,616 - $7,000
        case 101...150:
            baseSalary = 6300 + (151 - worldRank) * 6      // $6,306 - $6,600
        case 151...250:
            baseSalary = 6100 + (251 - worldRank) * 2      // $6,102 - $6,300
        default:
            baseSalary = 6000                               // $6,000 floor
        }

        // Stable per-player jitter (±150) so same-tier golfers get slightly different prices
        guard !athleteID.isEmpty else { return baseSalary }
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = abs(stableHash % 300) - 150
        return max(6000, min(15000, baseSalary + jitter))
    }

    /// Projected DraftKings fantasy points based on salary tier and world ranking.
    /// DK scoring range: ~15 FPTS (cut golfer) to ~130 FPTS (tournament winner).
    /// Typical mid-field golfer: ~40-60 FPTS over 4 rounds.
    private func projectedGolfPoints(salary: Int, worldRank: Int, athleteID: String) -> Double {
        let salaryFraction = Double(salary - 6000) / Double(15000 - 6000)
        let curved = pow(max(0, salaryFraction), 0.8)
        let salaryBase = 25.0 + curved * 60.0

        // World ranking form adjustment
        let rankFactor: Double
        switch worldRank {
        case 1...10:   rankFactor = 1.10
        case 11...25:  rankFactor = 1.03
        case 26...50:  rankFactor = 0.97
        case 51...100: rankFactor = 0.92
        default:       rankFactor = 0.85
        }

        // Stable per-player jitter for variance (+/- 8%)
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitterFraction = (Double(abs(stableHash % 160)) - 80.0) / 1000.0

        let adjusted = salaryBase * rankFactor * (1.0 + jitterFraction)
        return (adjusted * 10).rounded() / 10
    }

    private func parseESPNDate(_ dateString: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: dateString) { return date }

        let iso2 = ISO8601DateFormatter()
        if let date = iso2.date(from: dateString) { return date }

        // Try ESPN's custom format
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

// MARK: - ESPN PGA Live Scoring Provider

struct ESPNPGADFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        // For golf, there's only one "game" (the tournament event)
        guard let tournamentGame = games.first else {
            return DFSScoreSnapshot(
                playerFantasyPoints: [:],
                playerLiveStats: [:],
                gameLiveInfo: [:],
                allGamesFinal: false
            )
        }

        // Fetch scoreboard to get live competitor data
        guard let baseURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard") else {
            throw NSError(domain: "GolfDFS", code: 10)
        }

        let (data, response) = try await session.data(from: baseURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GolfDFS", code: 11)
        }

        var scoreboard = try JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: data)

        // Find matching event by ID
        // If our tournament is no longer on the current scoreboard, try fetching
        // with a date parameter to get historical tournament data
        if scoreboard.events.first(where: { $0.id == tournamentGame.id }) == nil {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd"
            let dateStr = dateFormatter.string(from: tournamentGame.startTime)
            if let dateURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard?dates=\(dateStr)") {
                if let (dateData, dateResp) = try? await session.data(from: dateURL),
                   let dateHTTP = dateResp as? HTTPURLResponse, (200..<300).contains(dateHTTP.statusCode),
                   let dateScoreboard = try? JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: dateData) {
                    if dateScoreboard.events.first(where: { $0.id == tournamentGame.id }) != nil {
                        scoreboard = dateScoreboard
                        print("[GolfDFS] Found tournament \(tournamentGame.id) via date query (\(dateStr))")
                    }
                }
            }
        }

        guard let event = scoreboard.events.first(where: { $0.id == tournamentGame.id }),
              let competition = event.competitions.first else {
            // Tournament not found on scoreboard — do NOT mark as final.
            // ESPN can temporarily drop events between rounds. Marking as final
            // here was causing premature settlement during R1/R2.
            print("[GolfDFS] Tournament \(tournamentGame.id) not found on ESPN scoreboard — returning empty (NOT final)")
            let gameInfo = DFSGameLiveInfo(
                id: tournamentGame.id,
                awayTeam: tournamentGame.awayTeam,
                homeTeam: tournamentGame.homeTeam,
                awayScore: 0, homeScore: 0,
                clock: "Loading…", period: 1, state: "in"
            )
            return DFSScoreSnapshot(
                playerFantasyPoints: [:],
                playerLiveStats: [:],
                gameLiveInfo: [tournamentGame.id: gameInfo],
                allGamesFinal: false
            )
        }

        let eventState = event.status.type.state ?? "pre"
        let eventCompleted = event.status.type.completed ?? false
        let eventStatusName = event.status.type.name ?? ""
        let currentRound = competition.status?.period ?? competition.competitors.first?.status?.period ?? 1
        // PGA tournaments have 4 rounds (Thu–Sun). ESPN can temporarily mark the
        // event as "post" between rounds (e.g. after R1 finishes late Thursday night)
        // or even during the final round while late groups are still playing.
        // Only report allGamesFinal when the event is truly over.
        //
        // Key checks:
        // 1. Event state must be "post"
        // 2. Event must be marked "completed" OR have STATUS_FINAL name
        // 3. Round 4 must be in progress or complete
        // 4. At least 75% of non-cut/non-WD competitors have valid R4 linescore data
        //    (a full round score is >= 50 strokes; mid-round players have < 50)
        let hasR4Data: Bool = {
            // Only count competitors who made the cut (not CUT/WD/DQ)
            let activeCompetitors = competition.competitors.filter { competitor in
                let statusName = competitor.status?.type?.name ?? ""
                return statusName != "STATUS_CUT" && statusName != "STATUS_WITHDRAWN" && statusName != "STATUS_DISQUALIFIED"
            }
            let withR4 = activeCompetitors.filter { competitor in
                guard let linescores = competitor.linescores, linescores.count >= 4 else { return false }
                // R4 linescore exists and has a valid full-round score (>= 50 strokes)
                // Players still on the course have < 50 (strokes on completed holes only)
                let r4Value = linescores[3].value ?? 0
                return r4Value >= 50
            }
            // ALL active (non-cut) competitors must have completed R4.
            // Even one player still on the course means the tournament isn't over.
            return !activeCompetitors.isEmpty && withR4.count == activeCompetitors.count
        }()
        // Require either ESPN's completed flag OR STATUS_FINAL name, in addition to
        // our own R4 data validation. This prevents premature "Final" when ESPN sets
        // state="post" while late groups are still on the course during R4.
        let espnSaysFinal = eventCompleted || eventStatusName == "STATUS_FINAL"
        let allGamesFinal = eventState == "post" && currentRound >= 4 && hasR4Data && espnSaysFinal

        // Build game info (tournament-level status)
        let statusLabel: String
        if allGamesFinal {
            statusLabel = "Final"
        } else if eventState == "in" {
            statusLabel = "Round \(currentRound) - Active"
        } else if eventState == "post" && currentRound >= 4 {
            // ESPN says "post" during R4 but not all players have finished yet
            statusLabel = "Round 4 - Active"
        } else if eventState == "post" && currentRound < 4 {
            // ESPN says "post" but it's between rounds (e.g. R1 done, R2 not started)
            statusLabel = "Round \(currentRound) - Complete"
        } else {
            statusLabel = "Pre-Tournament"
        }

        let gameInfo = DFSGameLiveInfo(
            id: event.id,
            awayTeam: tournamentGame.awayTeam,
            homeTeam: tournamentGame.homeTeam,
            awayScore: 0,
            homeScore: 0,
            clock: statusLabel,
            period: currentRound,
            state: eventState
        )

        var playerFantasyPoints: [String: Double] = [:]
        var playerLiveStats: [String: DFSPlayerLiveStats] = [:]

        // Pre-compute positions from score-to-par rankings.
        // ESPN's displayValue can be nil or "-" during active play, so we derive
        // positions ourselves to ensure position points always apply.
        let computedPositions: [String: (pos: Int, display: String)] = {
            struct CompEntry: Comparable {
                let id: String
                let scoreToPar: Double
                let isCut: Bool
                let isWD: Bool
                static func < (lhs: CompEntry, rhs: CompEntry) -> Bool {
                    lhs.scoreToPar < rhs.scoreToPar
                }
            }
            var entries: [CompEntry] = []
            for comp in competition.competitors {
                let sName = comp.status?.type?.name ?? ""
                let cut = sName == "STATUS_CUT"
                let wd = sName == "STATUS_WITHDRAWN" || sName == "STATUS_DISQUALIFIED"
                let stp = comp.score?.value ?? 999
                // Only rank active players (not cut/WD)
                entries.append(CompEntry(id: comp.id, scoreToPar: stp, isCut: cut, isWD: wd))
            }
            // Sort: active players by score-to-par, cut/WD at bottom
            entries.sort { a, b in
                if a.isCut != b.isCut { return !a.isCut }
                if a.isWD != b.isWD { return !a.isWD }
                return a.scoreToPar < b.scoreToPar
            }
            var result: [String: (pos: Int, display: String)] = [:]
            var rank = 1
            var i = 0
            while i < entries.count {
                let e = entries[i]
                if e.isCut || e.isWD {
                    i += 1
                    continue
                }
                // Count how many share the same score
                var tieCount = 1
                while i + tieCount < entries.count &&
                      !entries[i + tieCount].isCut &&
                      !entries[i + tieCount].isWD &&
                      entries[i + tieCount].scoreToPar == e.scoreToPar {
                    tieCount += 1
                }
                let isTied = tieCount > 1
                for j in 0..<tieCount {
                    let display = isTied ? "T\(rank)" : "\(rank)"
                    result[entries[i + j].id] = (pos: rank, display: display)
                }
                rank += tieCount
                i += tieCount
            }
            return result
        }()

        for competitor in competition.competitors {
            let playerID = "pga-\(competitor.id)"
            let name = competitor.athlete.displayName

            // Extract round scores from linescores
            let roundLinescores = competitor.linescores ?? []

            // Determine status (need this before processing round scores)
            let statusName = competitor.status?.type?.name ?? ""
            var isCut = statusName == "STATUS_CUT"
            var isWithdrawn = statusName == "STATUS_WITHDRAWN" || statusName == "STATUS_DISQUALIFIED"
            let positionDisplay = competitor.status?.displayValue ?? "-"

            // ESPN scoreboard often doesn't set STATUS_WITHDRAWN. Detect WD from data:
            // A round with value < 50 and no hole-by-hole data means the player withdrew
            // during that round (no valid golf round can produce a score < 50).
            // Also check STATUS_CUT with description "Withdrawn" (ESPN sometimes uses this).
            if !isWithdrawn && !isCut {
                let statusDesc = competitor.status?.type?.description?.lowercased() ?? ""
                let statusShort = competitor.status?.type?.state ?? ""
                if statusDesc.contains("withdraw") || positionDisplay == "WD" {
                    isWithdrawn = true
                    isCut = false
                } else {
                    for roundLS in roundLinescores {
                        let roundScore = Int(roundLS.value ?? 0)
                        // A valid round score is 50-120. Below 50 with no hole data = WD mid-round.
                        if roundScore > 0 && roundScore < 50 && (roundLS.linescores ?? []).isEmpty {
                            isWithdrawn = true
                            break
                        }
                    }
                }
            }
            // ESPN may mark WD as STATUS_CUT with description "Withdrawn"
            if isCut {
                let statusDesc = competitor.status?.type?.description?.lowercased() ?? ""
                if statusDesc.contains("withdraw") || positionDisplay == "WD" {
                    isWithdrawn = true
                    isCut = false
                }
            }

            // Extract display round scores, filtering out partial WD rounds
            // A value < 50 for a WD player is strokes on completed holes, not a full round score
            func validRoundScore(_ idx: Int) -> Int {
                guard roundLinescores.count > idx else { return 0 }
                let v = Int(roundLinescores[idx].value ?? 0)
                if v > 0 && v < 50 && isWithdrawn { return 0 }
                return v
            }
            let r1 = validRoundScore(0)
            let r2 = validRoundScore(1)
            let r3 = validRoundScore(2)
            let r4 = validRoundScore(3)

            // Build hole-by-hole round data for DK scoring
            var roundsData: [GolfRoundHoleData] = []
            var hasHoleData = false

            for roundLS in roundLinescores {
                let roundScore = Int(roundLS.value ?? 0)
                guard roundScore > 0 else { continue }

                // Skip WD partial rounds (value < 50) — they aren't full rounds
                // For WD players, the low value represents strokes on completed holes only
                if roundScore < 50 && isWithdrawn {
                    // WD mid-round: use score-to-par from the overall score for DK pts
                    // The player gets points only for holes actually completed
                    // Since we don't have hole-by-hole data, approximate from score-to-par
                    continue
                }

                if let holes = roundLS.linescores, !holes.isEmpty {
                    hasHoleData = true
                    // ESPN may provide scoreType.name ("BIRDIE") or scoreType.displayValue ("-1")
                    // Map display values to canonical score type names
                    let scoreTypes: [String] = holes.compactMap { hole in
                        if let name = hole.scoreType?.name, !name.isEmpty {
                            return name
                        }
                        // Fallback: map displayValue to score type name
                        guard let dv = hole.scoreType?.displayValue else { return nil }
                        return Self.scoreTypeFromDisplayValue(dv)
                    }
                    roundsData.append(GolfRoundHoleData(
                        holeScoreTypes: scoreTypes,
                        roundScore: roundScore
                    ))
                } else {
                    // No hole data for this round — will use fallback
                    roundsData.append(GolfRoundHoleData(
                        holeScoreTypes: [],
                        roundScore: roundScore
                    ))
                }
            }

            // Calculate fantasy points using DK scoring
            // Include placement bonus based on current position (DraftKings awards
            // placement points throughout the tournament, not just at the end).
            // Use ESPN's displayValue when it's a valid position, otherwise fall back
            // to our computed position from score-to-par rankings.
            let fpts: Double
            let espnPos = parsePosition(positionDisplay)
            let computedEntry = computedPositions[competitor.id]
            let currentPos = espnPos ?? computedEntry?.pos

            if isWithdrawn && roundsData.isEmpty {
                // WD with no complete rounds — compute from score-to-par
                // Each hole at par = 0.5 DK pts. Use overall score-to-par to estimate.
                let scoreToPar = Int(competitor.score?.value ?? 0)
                // Count how many holes were actually played from the partial round value
                // For a WD mid-round, scoreToPar tells us net performance
                // Approximate: if E (even), they parred their holes → 0.5 per hole
                // We don't know exact hole count, so use the score-to-par as a proxy
                if scoreToPar == 0 {
                    // Even par — likely parred all completed holes
                    // Morikawa case: 1 hole, par = 0.5 pts
                    // Use the partial round value as hole count approximation
                    let partialRoundValue = roundLinescores.first(where: { Int($0.value ?? 0) > 0 && Int($0.value ?? 0) < 50 })
                    let approxHoles = partialRoundValue.flatMap { ls -> Int? in
                        // The value is the total strokes on completed holes
                        // Can't know exact holes from strokes alone, but for E par it's reasonable
                        // to assume strokes / 4 ≈ holes (avg par ~4)
                        let strokes = Int(ls.value ?? 0)
                        return max(1, strokes / 4)
                    } ?? 1
                    fpts = Double(approxHoles) * 0.5  // par = 0.5 per hole in DK
                } else if scoreToPar < 0 {
                    // Under par — birdies
                    let birdies = abs(scoreToPar)
                    let partialStrokes = Int(roundLinescores.first(where: { Int($0.value ?? 0) > 0 && Int($0.value ?? 0) < 50 })?.value ?? 4)
                    let approxHoles = max(1, partialStrokes / 4)
                    let pars = max(0, approxHoles - birdies)
                    fpts = Double(birdies) * 3.0 + Double(pars) * 0.5
                } else {
                    // Over par — bogeys
                    let bogeys = scoreToPar
                    let partialStrokes = Int(roundLinescores.first(where: { Int($0.value ?? 0) > 0 && Int($0.value ?? 0) < 50 })?.value ?? 4)
                    let approxHoles = max(1, partialStrokes / 4)
                    let pars = max(0, approxHoles - bogeys)
                    fpts = Double(pars) * 0.5 + Double(bogeys) * -0.5
                }
            } else if hasHoleData {
                fpts = DFSEngine.golfFantasyPoints(
                    rounds: roundsData,
                    isCut: isCut,
                    isWithdrawn: isWithdrawn,
                    finalPosition: currentPos
                )
            } else {
                // Fallback when no hole-by-hole data available
                let scores = roundLinescores.compactMap { ls -> Int? in
                    let v = Int(ls.value ?? 0)
                    return v > 0 ? v : nil
                }
                fpts = DFSEngine.golfFantasyPointsFallback(
                    roundScores: scores,
                    isCut: isCut,
                    isWithdrawn: isWithdrawn,
                    finalPosition: currentPos
                )
            }

            playerFantasyPoints[playerID] = fpts

            // Repurpose DFSPlayerLiveStats fields for golf:
            // points = score to par (integer), rebounds = current round
            // fgm/fga = R1/R2 scores, threePM/threePA = R3/R4 scores
            // ftm = position number, fta = total strokes
            // minutes = position display string
            // steals = 1 if cut, blocks = 1 if withdrawn

            let scoreToPar = Int(competitor.score?.value ?? 0)
            let totalStrokes = [r1, r2, r3, r4].filter { $0 > 0 }.reduce(0, +)
            // Show "WD" or "CUT" in position display even if ESPN doesn't set it.
            // Prefer ESPN's position display (which includes T-prefix for ties),
            // falling back to our computed position with T-prefix.
            let effectivePositionDisplay: String
            if isWithdrawn {
                effectivePositionDisplay = "WD"
            } else if isCut {
                effectivePositionDisplay = "CUT"
            } else if positionDisplay != "-" && !positionDisplay.isEmpty {
                effectivePositionDisplay = positionDisplay
            } else if let computed = computedEntry {
                effectivePositionDisplay = computed.display
            } else {
                effectivePositionDisplay = "-"
            }
            let positionNum = currentPos

            let stats = DFSPlayerLiveStats(
                name: name,
                points: scoreToPar,
                rebounds: currentRound,
                assists: 0,
                steals: isCut ? 1 : 0,
                blocks: isWithdrawn ? 1 : 0,
                turnovers: 0,
                minutes: effectivePositionDisplay,
                fgm: r1, fga: r2,
                threePM: r3, threePA: r4,
                ftm: positionNum ?? 999, fta: totalStrokes,
                fantasyPoints: fpts,
                gameStatus: statusLabel,
                gameFinal: allGamesFinal
            )

            playerLiveStats[playerID] = stats
        }

        return DFSScoreSnapshot(
            playerFantasyPoints: playerFantasyPoints,
            playerLiveStats: playerLiveStats,
            gameLiveInfo: [event.id: gameInfo],
            allGamesFinal: allGamesFinal
        )
    }

    /// Map ESPN scoreType.displayValue (e.g. "-1", "E", "+1") to canonical name
    private static func scoreTypeFromDisplayValue(_ dv: String) -> String {
        switch dv {
        case "-3": return "DOUBLE_EAGLE"
        case "-2": return "EAGLE"
        case "-1": return "BIRDIE"
        case "E", "0": return "PAR"
        case "+1", "1": return "BOGEY"
        case "+2", "2": return "DOUBLE_BOGEY"
        default:
            // +3 or worse → TRIPLE_BOGEY (treated same as double bogey in DK)
            if let val = Int(dv.replacingOccurrences(of: "+", with: "")), val >= 3 {
                return "TRIPLE_BOGEY"
            }
            // Negative values beyond -3
            if let val = Int(dv), val < -3 {
                return "DOUBLE_EAGLE"
            }
            return "PAR"
        }
    }

    /// Parse position string like "T5", "1", "CUT" → Int?
    private func parsePosition(_ display: String) -> Int? {
        let cleaned = display.replacingOccurrences(of: "T", with: "")
        return Int(cleaned)
    }
}

// MARK: - Golf Fantasy Points Calculation (DraftKings Scoring)

/// Per-round hole-level data used for DK scoring
struct GolfRoundHoleData {
    let holeScoreTypes: [String]   // e.g. ["BIRDIE", "PAR", "BOGEY", ...] for each hole played
    let roundScore: Int            // total strokes for the round (e.g. 68)
}

extension DFSEngine {

    /// Calculate golf fantasy points using DraftKings PGA scoring.
    ///
    /// **Hole Scoring:**
    /// - Double Eagle / Albatross: +20 pts
    /// - Eagle: +8 pts
    /// - Birdie: +3 pts
    /// - Par: +0.5 pts
    /// - Bogey: -0.5 pts
    /// - Double Bogey or Worse: -1 pt
    ///
    /// **Bonus Scoring:**
    /// - Hole-in-One: +10 pts (treated as eagle on par 3 + bonus)
    /// - 3 Birdies in a Row (Streak): +3 pts
    /// - Bogey-Free Round: +3 pts
    /// - All 4 Rounds Under 70: +5 pts
    ///
    /// **Finishing Position Points:**
    /// 1st: 30, 2nd: 20, 3rd: 18, 4th: 16, 5th: 14, 6th: 12, 7th: 10,
    /// 8th: 9, 9th: 8, 10th: 7, 11-15: 6, 16-20: 5, 21-25: 4,
    /// 26-30: 3, 31-40: 2, 41-50: 1
    static func golfFantasyPoints(
        rounds: [GolfRoundHoleData],
        isCut: Bool,
        isWithdrawn: Bool,
        finalPosition: Int?
    ) -> Double {
        var fpts: Double = 0

        // --- Hole-by-hole scoring ---
        var allRoundsUnder70 = true
        var totalRoundsCompleted = 0

        for round in rounds {
            guard !round.holeScoreTypes.isEmpty else { continue }
            totalRoundsCompleted += 1
            var hasBogey = false
            var birdieStreak = 0

            for scoreType in round.holeScoreTypes {
                let holePoints = dkHolePoints(scoreType)
                fpts += holePoints

                // Track bogey-free round
                if scoreType == "BOGEY" || scoreType == "DOUBLE_BOGEY" || scoreType == "TRIPLE_BOGEY" {
                    hasBogey = true
                }

                // Track birdie streak
                if scoreType == "BIRDIE" {
                    birdieStreak += 1
                    if birdieStreak >= 3 {
                        fpts += 3.0  // 3 birdies in a row bonus
                        birdieStreak = 0  // reset after awarding
                    }
                } else {
                    birdieStreak = 0
                }
            }

            // Bogey-free round bonus (only for complete 18-hole rounds)
            if !hasBogey && round.holeScoreTypes.count >= 18 {
                fpts += 3.0
            }

            // Track all-rounds-under-70
            if round.roundScore >= 70 || round.roundScore <= 0 {
                allRoundsUnder70 = false
            }
        }

        // All 4 rounds under 70 bonus
        if allRoundsUnder70 && totalRoundsCompleted == 4 {
            fpts += 5.0
        }

        // --- Finishing Position Points ---
        if let pos = finalPosition, pos > 0 {
            fpts += dkPositionPoints(pos)
        }

        return (fpts * 10).rounded() / 10
    }

    /// Fallback: estimate DK points from round totals when hole-by-hole data isn't available.
    /// Uses average hole distribution to approximate per-round DK scoring.
    static func golfFantasyPointsFallback(
        roundScores: [Int],
        isCut: Bool,
        isWithdrawn: Bool,
        finalPosition: Int?
    ) -> Double {
        var fpts: Double = 0

        for score in roundScores where score > 0 {
            // Approximate: a round of 72 (par) ≈ 18 pars = 9.0 pts
            // Each stroke under par adds roughly +2.5 (birdie vs par difference)
            // Each stroke over par subtracts roughly -1.0 (bogey vs par difference)
            let relativeToPar = 72 - score
            if relativeToPar >= 0 {
                fpts += 9.0 + Double(relativeToPar) * 2.5
            } else {
                fpts += 9.0 + Double(relativeToPar) * 1.0
            }
        }

        if let pos = finalPosition, pos > 0 {
            fpts += dkPositionPoints(pos)
        }

        return (fpts * 10).rounded() / 10
    }

    /// DK points for a single hole score type
    private static func dkHolePoints(_ scoreType: String) -> Double {
        switch scoreType {
        case "DOUBLE_EAGLE", "ALBATROSS":
            return 20.0
        case "EAGLE":
            return 8.0
        case "BIRDIE":
            return 3.0
        case "PAR":
            return 0.5
        case "BOGEY":
            return -0.5
        case "DOUBLE_BOGEY", "TRIPLE_BOGEY":
            return -1.0
        default:
            // Unknown score type — treat as par
            return 0.5
        }
    }

    /// DK finishing position points
    static func dkPositionPoints(_ position: Int) -> Double {
        switch position {
        case 1: return 30.0
        case 2: return 20.0
        case 3: return 18.0
        case 4: return 16.0
        case 5: return 14.0
        case 6: return 12.0
        case 7: return 10.0
        case 8: return 9.0
        case 9: return 8.0
        case 10: return 7.0
        case 11...15: return 6.0
        case 16...20: return 5.0
        case 21...25: return 4.0
        case 26...30: return 3.0
        case 31...40: return 2.0
        case 41...50: return 1.0
        default: return 0.0
        }
    }
}

// MARK: - Configured Golf Slate Provider

struct ConfiguredGolfDFSSlateProvider: DFSSlateProvider {
    private let liveProvider = ESPNPGADFSSlateProvider()

    func fetchSlate() async throws -> DFSSlate {
        let live = try await liveProvider.fetchSlate()
        if live.players.isEmpty {
            throw NSError(domain: "GolfDFS", code: 100, userInfo: [NSLocalizedDescriptionKey: "No PGA players available"])
        }
        return live
    }
}

// MARK: - Golf Tournament History

struct GolfTournamentResult: Identifiable {
    let id: String          // event name + date for uniqueness
    let name: String        // tournament name
    let date: String        // formatted date e.g. "Mar 14"
    let finishPosition: String  // "1", "T7", "CUT", "WD"
    let scoreToPar: String  // "-17", "E", "+1"
    let roundScores: [Int]  // e.g. [66, 65, 69, 67], 0 for unplayed
    let isCut: Bool
    let isWithdrawn: Bool
}

struct GolfTournamentHistoryProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch recent tournament results for a golfer by ESPN athlete ID.
    /// Returns up to 15 most recent tournaments across all tours.
    func fetchTournamentHistory(athleteID: String) async throws -> [GolfTournamentResult] {
        // Strip "pga-" prefix if present
        let rawID = athleteID.hasPrefix("pga-") ? String(athleteID.dropFirst(4)) : athleteID

        guard let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/golf/pga/athletes/\(rawID)/overview") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = json["recentTournaments"] as? [[String: Any]] else {
            return []
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d"

        var results: [GolfTournamentResult] = []

        for section in sections {
            guard let events = section["eventsStats"] as? [[String: Any]] else { continue }

            for event in events {
                let eventName = event["name"] as? String ?? "Unknown"
                let dateString = event["date"] as? String ?? ""

                // Parse date for display
                var displayDate = ""
                for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm'Z'"] {
                    dateFormatter.dateFormat = fmt
                    if let d = dateFormatter.date(from: dateString) {
                        displayDate = displayFormatter.string(from: d)
                        break
                    }
                }

                guard let comps = event["competitions"] as? [[String: Any]],
                      let comp = comps.first,
                      let competitors = comp["competitors"] as? [[String: Any]],
                      let player = competitors.first else { continue }

                // Score to par
                let scoreDV = (player["score"] as? [String: Any])?["displayValue"] as? String ?? "-"

                // Finish position and status
                let status = player["status"] as? [String: Any]
                let position = status?["position"] as? [String: Any]
                let posDisplay = position?["displayName"] as? String ?? "-"
                let statusType = status?["type"] as? [String: Any]
                let statusName = statusType?["name"] as? String ?? ""

                let isCut = statusName == "STATUS_CUT"
                let isWD = statusName == "STATUS_WITHDRAWN" || statusName == "STATUS_DISQUALIFIED"

                let finishPosition: String
                if isCut {
                    finishPosition = "CUT"
                } else if isWD {
                    finishPosition = "WD"
                } else if let posNum = posDisplay as? String, !posNum.isEmpty, posNum != "-" {
                    finishPosition = posNum
                } else {
                    finishPosition = posDisplay
                }

                // Round scores from linescores.items
                var roundScores: [Int] = []
                if let lsObj = player["linescores"] as? [String: Any],
                   let items = lsObj["items"] as? [[String: Any]] {
                    roundScores = items.compactMap { item in
                        let v = Int(item["value"] as? Double ?? 0)
                        return v > 0 && v < 100 ? v : 0  // filter out bogus values
                    }
                }

                let result = GolfTournamentResult(
                    id: "\(eventName)-\(dateString)",
                    name: eventName,
                    date: displayDate,
                    finishPosition: finishPosition,
                    scoreToPar: scoreDV,
                    roundScores: roundScores,
                    isCut: isCut,
                    isWithdrawn: isWD
                )
                results.append(result)
            }
        }

        // Return up to 15 most recent (they come sorted newest first from ESPN)
        return Array(results.prefix(15))
    }
}
