import Foundation

// MARK: - ESPN NASCAR Codable Models

struct ESPNNASCARScoreboardResponse: Codable {
    let events: [ESPNNASCAREvent]
}

struct ESPNNASCAREvent: Codable {
    let id: String
    let name: String
    let shortName: String?
    let date: String
    let competitions: [ESPNNASCARCompetition]
    let status: ESPNNASCAREventStatus
}

struct ESPNNASCARCompetition: Codable {
    let id: String
    let competitors: [ESPNNASCARCompetitor]?
    let venue: ESPNNASCARVenue?
    let status: ESPNNASCAREventStatus?
}

struct ESPNNASCARCompetitor: Codable {
    let id: String
    let order: Int?
    let winner: Bool?
    let athlete: ESPNNASCARAthlete
}

struct ESPNNASCARAthlete: Codable {
    let fullName: String?
    let displayName: String?
    let shortName: String?
}

struct ESPNNASCARVenue: Codable {
    let fullName: String?
}

struct ESPNNASCAREventStatus: Codable {
    let period: Int?
    let type: ESPNNASCARStatusType?
}

struct ESPNNASCARStatusType: Codable {
    let name: String?
    let state: String?
    let completed: Bool?
    let shortDetail: String?
}

// MARK: - DraftKings NASCAR Classic scoring
//
// DK Cup Classic: 6 drivers, $50K cap.
//  - Finishing position: 1st = 43 + 3 win bonus = 46, 2nd = 42, then one
//    less per place (44 - place), floored at 1.
//  - Place differential: ±1 pt per position (start − finish).
//  - Laps led: 0.25 pts per lap.
//  - Fastest laps (0.5/lap) are NOT scored: ESPN's feed has no per-driver
//    fastest-lap counts. Users and bots grade on the same basis, so the
//    contest stays fair — totals just run slightly below DK's.

func nascarFinishPoints(place: Int) -> Double {
    guard place >= 1 else { return 0 }
    if place == 1 { return 46 }
    return Double(max(1, 44 - place))
}

func nascarFantasyPoints(place: Int, startPosition: Int, lapsLed: Int) -> Double {
    guard place >= 1 else { return 0 }
    var pts = nascarFinishPoints(place: place)
    if startPosition >= 1 {
        pts += Double(startPosition - place)
    }
    pts += Double(lapsLed) * 0.25
    return pts
}

// ESPN race dates come in a few ISO-ish shapes ("2026-07-26T18:00Z");
// file-scoped so both providers share it.
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

// MARK: - Slate cache

private final class NASCARSlateCache {
    static let shared = NASCARSlateCache()
    private var entry: (slate: DFSSlate, fetchedAt: Date)?
    private let ttl: TimeInterval = 300

    func get() -> DFSSlate? {
        guard let entry, Date().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry.slate
    }

    func set(_ slate: DFSSlate) {
        entry = (slate, Date())
    }
}

// MARK: - Slate Provider

nonisolated struct ESPNNASCARDFSSlateProvider: DFSSlateProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @concurrent func fetchSlate() async throws -> DFSSlate {
        if let cached = NASCARSlateCache.shared.get() {
            return cached
        }

        // 1. Find the current/next Cup race. The default scoreboard only
        // carries the most recent race once it finishes, so probe forward
        // when it has nothing upcoming (Cup races are weekly).
        var event = try await fetchBestEvent()

        // Reject long-finished races — the slate should be next week's race.
        if event?.status.type?.state == "post", let probed = await probeUpcomingEvent() {
            event = probed
        }
        guard let event else {
            throw NSError(domain: "NASCARDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No NASCAR Cup race found"])
        }
        let competition = event.competitions.first
        let raceDate = parseESPNDate(event.date) ?? Date()

        // 2. DraftKings salaries via RotoGrinders. NASCAR masters are keyed
        // by RACE day (single slate per week) — try the race date first, then
        // today and yesterday for early-week publishes. "(Cup)" filters out
        // Xfinity/Truck slates sharing the master.
        var dkSalaries = await RotoGrindersSalaryProvider.shared.fetchClassicSalariesFromMaster(
            sport: "nas", nameContains: "(Cup)", date: raceDate
        )
        if dkSalaries.isEmpty {
            dkSalaries = await RotoGrindersSalaryProvider.shared.fetchClassicSalariesFromMaster(
                sport: "nas", nameContains: "(Cup)"
            )
        }
        if dkSalaries.isEmpty, let prevDay = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Date()) {
            dkSalaries = await RotoGrindersSalaryProvider.shared.fetchClassicSalariesFromMaster(
                sport: "nas", nameContains: "(Cup)", date: prevDay
            )
        }
        guard !dkSalaries.isEmpty else {
            throw NSError(domain: "NASCARDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Waiting for salary data for this NASCAR slate"])
        }
        print("[NASCAR-DFS] Fetched \(dkSalaries.count) DK Cup salaries for \(event.name)")

        // 3. Driver pool. ESPN's competitor list is usually EMPTY until race
        // weekend, so the DK salary list IS the field. Resolve real ESPN
        // athlete IDs from recent races (driver roster is stable week to
        // week) so slate/bot/scoring all share `nascar-{espnID}`.
        let espnIndex = await fetchDriverIndex(currentEvent: event)

        var players: [DFSPlayer] = []
        if let competitors = competition?.competitors, !competitors.isEmpty {
            players = competitors.compactMap { competitor in
                let name = competitor.athlete.displayName ?? competitor.athlete.fullName ?? ""
                guard !name.isEmpty,
                      let salary = RotoGrindersSalaryProvider.lookupSalary(espnName: name, in: dkSalaries) else {
                    // Not priced by DK → not in the DK field; skip.
                    return nil
                }
                return nascarPlayer(id: competitor.id, name: name, salary: salary, gameID: event.id)
            }
        }
        if players.isEmpty {
            players = dkSalaries.map { (lowercaseName, salary) in
                let displayName = lowercaseName.split(separator: " ")
                    .map { String($0).prefix(1).uppercased() + String($0).dropFirst() }
                    .joined(separator: " ")
                let resolvedID = resolveESPNDriverID(dkName: displayName, in: espnIndex)
                    ?? "dk-\(lowercaseName.replacingOccurrences(of: " ", with: "-"))"
                return nascarPlayer(id: resolvedID, name: displayName, salary: salary, gameID: event.id)
            }
            let unresolved = players.filter { $0.id.hasPrefix("nascar-dk-") }.count
            print("[NASCAR-DFS] DK-only pool: \(players.count) drivers (\(unresolved) without ESPN IDs)")
        }
        players.sort { $0.salary > $1.salary }

        guard players.count >= 6 else {
            throw NSError(domain: "NASCARDFS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not enough priced drivers for \(event.name)"])
        }

        // 4. Contests. DK locks NASCAR at green flag — ESPN's event date IS
        // the green-flag time, so no synthetic lock hour needed.
        let tournamentID = "nascar-\(event.id)"
        let fieldSizes = [2, 3, 5, 10, 2000]
        let tournaments = fieldSizes.map { size in
            DFSTournament(
                id: "\(tournamentID)-\(size)",
                title: event.name,
                league: "NASCAR",
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
                    awayTeam: competition?.venue?.fullName ?? "",   // repurpose: venue
                    homeTeam: event.name,                           // repurpose: race name
                    startTime: raceDate,
                    state: event.status.type?.state ?? "pre"
                )
            ],
            players: players
        )
        NASCARSlateCache.shared.set(slate)
        return slate
    }

    /// DK and ESPN spell drivers differently ("John H. Nemechek" vs ESPN's
    /// "John Hunter Nemechek"), and an unresolved driver gets a dead "dk-"
    /// id that can never match a stat row — grading as DNP even though he
    /// finished the race. Exact normalized match first, then suffix-stripped,
    /// then first-initial + last-name when it's unambiguous.
    private func resolveESPNDriverID(dkName: String, in index: [String: String]) -> String? {
        func stripSuffix(_ s: String) -> String {
            s.replacingOccurrences(of: " (jr|sr|ii|iii|iv)$", with: "", options: .regularExpression)
        }
        let normalized = RotoGrindersSalaryProvider.normalizeName(dkName)
        if let id = index[normalized] { return id }

        let stripped = stripSuffix(normalized)
        for (key, id) in index where stripSuffix(key) == stripped {
            return id
        }

        let parts = stripped.components(separatedBy: " ")
        guard parts.count >= 2, let lastName = parts.last else { return nil }
        let firstInitial = String(parts[0].prefix(1))
        let candidates = index.filter { key, _ in
            let kp = stripSuffix(key).components(separatedBy: " ")
            guard kp.count >= 2, kp.last == lastName else { return false }
            return String(kp[0].prefix(1)) == firstInitial
        }
        return candidates.count == 1 ? candidates.first?.value : nil
    }

    private func nascarPlayer(id: String, name: String, salary: Int, gameID: String) -> DFSPlayer {
        // Salary-driven projection with a deterministic per-driver jitter so
        // equal-priced drivers don't project identically (bots weight on this).
        let base = Double(salary) / 200.0                       // $10,000 → 50 pts
        let jitter = Double(abs(id.hashValue % 700)) / 100.0 - 3.5
        return DFSPlayer(
            id: "nascar-\(id)",
            name: name,
            team: "",
            position: "D",
            salary: salary,
            projectedPoints: max(5, base + jitter),
            gameID: gameID
        )
    }

    private func fetchBestEvent() async throws -> ESPNNASCAREvent? {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/racing/nascar-premier/scoreboard") else {
            throw NSError(domain: "NASCARDFS", code: 4)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "NASCARDFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "NASCAR scoreboard request failed"])
        }
        let scoreboard = try JSONDecoder().decode(ESPNNASCARScoreboardResponse.self, from: data)
        // Prefer live, then upcoming, then most recent finished.
        let events = scoreboard.events
        return events.first(where: { $0.status.type?.state == "in" })
            ?? events.first(where: { $0.status.type?.state == "pre" })
            ?? events.last
    }

    /// Probe the next 9 days for an upcoming race (Cup races are weekly;
    /// the default scoreboard drops to the finished race after Sunday).
    private func probeUpcomingEvent() async -> ESPNNASCAREvent? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        let cal = Calendar(identifier: .gregorian)
        let candidates: [ESPNNASCAREvent] = await withTaskGroup(of: [ESPNNASCAREvent].self) { group in
            for offset in 0...9 {
                guard let date = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
                let dk = fmt.string(from: date)
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/racing/nascar-premier/scoreboard?dates=\(dk)"),
                          let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let sb = try? JSONDecoder().decode(ESPNNASCARScoreboardResponse.self, from: data) else {
                        return []
                    }
                    return sb.events
                }
            }
            var all: [ESPNNASCAREvent] = []
            for await events in group { all.append(contentsOf: events) }
            return all
        }
        var seen = Set<String>()
        let upcoming = candidates
            .filter { ($0.status.type?.state ?? "pre") != "post" }
            .filter { seen.insert($0.id).inserted }
            .sorted { (parseESPNDate($0.date) ?? .distantFuture) < (parseESPNDate($1.date) ?? .distantFuture) }
        return upcoming.first
    }

    /// Normalized driver name → ESPN athlete ID, from the last few weeks of
    /// race results (plus the current event when it has competitors).
    private func fetchDriverIndex(currentEvent: ESPNNASCAREvent) async -> [String: String] {
        var index: [String: String] = [:]
        for competitor in currentEvent.competitions.first?.competitors ?? [] {
            if let name = competitor.athlete.displayName ?? competitor.athlete.fullName {
                index[RotoGrindersSalaryProvider.normalizeName(name)] = competitor.id
            }
        }
        if !index.isEmpty { return index }

        // Recent Sundays: sweep the past 4 weeks of scoreboard dates.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        let cal = Calendar(identifier: .gregorian)
        let responses: [[ESPNNASCAREvent]] = await withTaskGroup(of: [ESPNNASCAREvent].self) { group in
            for daysBack in stride(from: 1, through: 28, by: 1) {
                guard let date = cal.date(byAdding: .day, value: -daysBack, to: Date()) else { continue }
                let dk = fmt.string(from: date)
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/racing/nascar-premier/scoreboard?dates=\(dk)"),
                          let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let sb = try? JSONDecoder().decode(ESPNNASCARScoreboardResponse.self, from: data) else {
                        return []
                    }
                    return sb.events
                }
            }
            var all: [[ESPNNASCAREvent]] = []
            for await events in group { all.append(events) }
            return all
        }
        for events in responses {
            for event in events {
                for competitor in event.competitions.first?.competitors ?? [] {
                    if let name = competitor.athlete.displayName ?? competitor.athlete.fullName {
                        index[RotoGrindersSalaryProvider.normalizeName(name)] = competitor.id
                    }
                }
            }
        }
        print("[NASCAR-DFS] Driver index: \(index.count) ESPN IDs from recent races")
        return index
    }
}

// MARK: - Live Scoring Provider

nonisolated struct ESPNNASCARDFSLiveScoringProvider: DFSLiveScoringProvider, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @concurrent func fetchScoreSnapshot(for games: [DFSSlateGame]) async throws -> DFSScoreSnapshot {
        guard let raceGame = games.first else {
            return DFSScoreSnapshot(playerFantasyPoints: [:], playerLiveStats: [:], gameLiveInfo: [:], allGamesFinal: false)
        }

        // Locate the event: current scoreboard first, then the race date
        // (from the tid-embedded event ID, which starts YYYYMMDD), then the
        // slate game's start time.
        var event = await fetchScoreboardEvent(eventID: raceGame.id, dateKey: nil)
        if event == nil {
            let idDate = String(raceGame.id.prefix(8))
            if idDate.count == 8, Int(idDate) != nil {
                event = await fetchScoreboardEvent(eventID: raceGame.id, dateKey: idDate)
            }
        }
        if event == nil {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = TimeZone(identifier: "America/New_York")
            event = await fetchScoreboardEvent(eventID: raceGame.id, dateKey: fmt.string(from: raceGame.startTime))
        }

        guard let event, let competition = event.competitions.first else {
            // Race not found — ESPN can briefly drop events; never mark final.
            print("[NASCAR-Score] Race \(raceGame.id) not on ESPN scoreboard — returning empty (NOT final)")
            let info = DFSGameLiveInfo(
                id: raceGame.id, awayTeam: raceGame.awayTeam, homeTeam: raceGame.homeTeam,
                awayScore: 0, homeScore: 0, clock: "Loading…", period: 1, state: "in"
            )
            return DFSScoreSnapshot(playerFantasyPoints: [:], playerLiveStats: [:], gameLiveInfo: [raceGame.id: info], allGamesFinal: false)
        }

        let state = event.status.type?.state ?? "pre"
        let completed = event.status.type?.completed ?? false
        let statusName = event.status.type?.name ?? ""
        let isFinal = state == "post" && (completed || statusName == "STATUS_FINAL")
        let competitors = competition.competitors ?? []

        var playerFantasyPoints: [String: Double] = [:]
        var playerLiveStats: [String: DFSPlayerLiveStats] = [:]

        if state != "pre" && !competitors.isEmpty {
            // startOrder and lapsLead live on the core API, per competitor.
            // ~40 small concurrent fetches per poll — same pattern as UFC's
            // per-fighter stats.
            let details = await fetchCompetitorDetails(
                eventID: event.id, competitionID: competition.id,
                competitorIDs: competitors.map(\.id)
            )
            for competitor in competitors {
                let playerID = "nascar-\(competitor.id)"
                let name = competitor.athlete.displayName ?? competitor.athlete.fullName ?? "Driver"
                let detail = details[competitor.id]
                // Prefer the core stats' classified place; the site
                // scoreboard's running order is the live fallback.
                let place = (detail?.place ?? 0) > 0 ? detail!.place : (competitor.order ?? 0)
                guard place >= 1 else { continue }
                let start = detail?.startOrder ?? 0
                let lapsLed = detail?.lapsLed ?? 0
                let fpts = nascarFantasyPoints(place: place, startPosition: start, lapsLed: lapsLed)
                playerFantasyPoints[playerID] = fpts

                // Repurposed stat fields for NASCAR:
                // points = position, rebounds = laps led, assists = laps
                // completed, ftm = start position, minutes = "P{pos}".
                let stats = DFSPlayerLiveStats(
                    name: name,
                    points: place,
                    rebounds: lapsLed,
                    assists: detail?.lapsCompleted ?? 0,
                    steals: 0, blocks: 0, turnovers: 0,
                    minutes: "P\(place)",
                    fgm: 0, fga: 0, threePM: 0, threePA: 0,
                    ftm: start, fta: 0,
                    fantasyPoints: fpts,
                    gameStatus: isFinal ? "Final" : (state == "in" ? "Racing" : "Pre-Race"),
                    gameFinal: isFinal
                )
                playerLiveStats[playerID] = stats

                // Alias keys for lineups drafted against the early-week
                // DK-only pool, whose unresolved ids are name slugs like
                // "nascar-dk-john-h-nemechek" (DK spells him "John H.
                // Nemechek"; ESPN "John Hunter Nemechek"). Register the
                // plausible slug spellings of this driver so those stored
                // lineups still match a stat row instead of grading DNP.
                for slug in Self.dkSlugVariants(for: name) {
                    let aliasID = "nascar-dk-\(slug)"
                    if playerFantasyPoints[aliasID] == nil {
                        playerFantasyPoints[aliasID] = fpts
                        playerLiveStats[aliasID] = stats
                    }
                }
            }
        }

        let statusLabel: String
        if isFinal {
            statusLabel = "Final"
        } else if state == "in" {
            statusLabel = event.status.type?.shortDetail ?? "Racing"
        } else {
            statusLabel = "Pre-Race"
        }
        let gameInfo = DFSGameLiveInfo(
            id: event.id,
            awayTeam: raceGame.awayTeam,
            homeTeam: raceGame.homeTeam,
            awayScore: 0, homeScore: 0,
            clock: statusLabel,
            period: 1,
            state: state
        )

        return DFSScoreSnapshot(
            playerFantasyPoints: playerFantasyPoints,
            playerLiveStats: playerLiveStats,
            gameLiveInfo: [event.id: gameInfo],
            allGamesFinal: isFinal
        )
    }

    /// Slug spellings a DK-derived player id could use for this ESPN
    /// driver name: full name, first+last, and first + middle-initial +
    /// last ("john-hunter-nemechek" / "john-nemechek" / "john-h-nemechek").
    nonisolated static func dkSlugVariants(for espnName: String) -> [String] {
        let tokens = RotoGrindersSalaryProvider.normalizeName(espnName)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return [tokens.joined(separator: "-")] }
        var variants = [tokens.joined(separator: "-")]
        if tokens.count >= 3 {
            let first = tokens[0], last = tokens[tokens.count - 1]
            variants.append("\(first)-\(last)")
            let middleInitial = String(tokens[1].prefix(1))
            variants.append("\(first)-\(middleInitial)-\(last)")
        }
        return variants
    }

    private func fetchScoreboardEvent(eventID: String, dateKey: String?) async -> ESPNNASCAREvent? {
        var urlString = "https://site.api.espn.com/apis/site/v2/sports/racing/nascar-premier/scoreboard"
        if let dateKey { urlString += "?dates=\(dateKey)" }
        guard let url = URL(string: urlString),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let scoreboard = try? JSONDecoder().decode(ESPNNASCARScoreboardResponse.self, from: data) else {
            return nil
        }
        return scoreboard.events.first(where: { $0.id == eventID })
    }

    struct CompetitorDetail {
        let startOrder: Int
        let place: Int
        let lapsLed: Int
        let lapsCompleted: Int
    }

    private func fetchCompetitorDetails(
        eventID: String, competitionID: String, competitorIDs: [String]
    ) async -> [String: CompetitorDetail] {
        await withTaskGroup(of: (String, CompetitorDetail)?.self, returning: [String: CompetitorDetail].self) { group in
            for cid in competitorIDs {
                group.addTask {
                    let base = "https://sports.core.api.espn.com/v2/sports/racing/leagues/nascar-premier/events/\(eventID)/competitions/\(competitionID)/competitors/\(cid)"
                    async let compData = self.fetchJSON(urlString: base)
                    async let statsData = self.fetchJSON(urlString: "\(base)/statistics")
                    let comp = await compData
                    let stats = await statsData

                    let startOrder = comp?["startOrder"] as? Int ?? 0
                    var place = 0, lapsLed = 0, lapsCompleted = 0
                    if let splits = stats?["splits"] as? [String: Any],
                       let categories = splits["categories"] as? [[String: Any]] {
                        for category in categories {
                            for stat in category["stats"] as? [[String: Any]] ?? [] {
                                guard let statName = stat["name"] as? String,
                                      let value = stat["value"] as? Double else { continue }
                                switch statName {
                                case "place": place = Int(value)
                                case "lapsLead": lapsLed = Int(value)
                                case "lapsCompleted": lapsCompleted = Int(value)
                                default: break
                                }
                            }
                        }
                    }
                    if startOrder == 0 && place == 0 { return nil }
                    return (cid, CompetitorDetail(startOrder: startOrder, place: place, lapsLed: lapsLed, lapsCompleted: lapsCompleted))
                }
            }
            var result: [String: CompetitorDetail] = [:]
            for await pair in group {
                if let (cid, detail) = pair { result[cid] = detail }
            }
            return result
        }
    }

    private func fetchJSON(urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
