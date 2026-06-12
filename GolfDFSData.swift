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
        // Fetch PGA Tour scoreboard (current week)
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard") else {
            throw NSError(domain: "GolfDFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid PGA scoreboard URL"])
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GolfDFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "PGA scoreboard request failed"])
        }

        var scoreboard = try JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: data)
        let defaultStates = scoreboard.events.map { "\($0.id):\($0.status.type.state ?? "?")" }.joined(separator: ", ")
        print("[GolfDFS] Default scoreboard events: \(defaultStates.isEmpty ? "<empty>" : defaultStates)")

        // Try to pick an event from the default scoreboard first.
        var pickedEvent = pickActiveEvent(from: scoreboard.events)

        // Probe forward when (a) the default scoreboard surfaced
        // nothing usable OR (b) the only thing it returned is a "post"
        // tournament — in that case there's a more useful upcoming
        // tournament we'd rather show, and ESPN's date-targeted
        // scoreboard often has it before the default scoreboard does.
        // We only ACCEPT a probe result that's an upcoming/live event
        // (state "pre" or "in"), so we don't replace one finished
        // tournament with another.
        let shouldProbe = pickedEvent == nil || (pickedEvent?.status.type.state == "post")
        if shouldProbe {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd"
            let calendar = Calendar(identifier: .gregorian)
            let today = Date()
            for offset in 0..<14 {
                guard let probeDate = calendar.date(byAdding: .day, value: offset, to: today),
                      let probeURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard?dates=\(dateFormatter.string(from: probeDate))") else {
                    continue
                }
                guard let (probeData, probeResp) = try? await session.data(from: probeURL),
                      let probeHTTP = probeResp as? HTTPURLResponse, (200..<300).contains(probeHTTP.statusCode),
                      let probeScoreboard = try? JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: probeData) else {
                    print("[GolfDFS] date probe +\(offset)d (\(dateFormatter.string(from: probeDate))) HTTP fetch failed")
                    continue
                }
                let probeStates = probeScoreboard.events.map { "\($0.id):\($0.status.type.state ?? "?")" }.joined(separator: ", ")
                if !probeScoreboard.events.isEmpty {
                    print("[GolfDFS] date probe +\(offset)d (\(dateFormatter.string(from: probeDate))) events: \(probeStates)")
                }
                // Find a non-"post" event in the probed scoreboard so we
                // don't keep adopting last week's finished tournament.
                if let probeEvent = probeScoreboard.events.first(where: {
                    let s = $0.status.type.state ?? ""
                    return s == "pre" || s == "in"
                }) {
                    print("[GolfDFS] Found upcoming event \(probeEvent.id) (\(probeEvent.name)) via date probe +\(offset)d, state=\(probeEvent.status.type.state ?? "?")")
                    scoreboard = probeScoreboard
                    pickedEvent = probeEvent
                    break
                }
            }
        }

        // Season-events fallback: try ESPN's core API season events
        // listing first (most reliable for season schedules).
        if pickedEvent == nil || (pickedEvent?.status.type.state == "post") {
            if let nextEvent = await findNextScheduledEventFromSeason() {
                print("[GolfDFS] Found upcoming event \(nextEvent.id) (\(nextEvent.name)) via season-events fallback")
                scoreboard = ESPNPGAScoreboardResponse(events: [nextEvent])
                pickedEvent = nextEvent
            }
        }

        // Sequential-ID probe: as a last resort, walk a small range of
        // event IDs forward from the most-recent known event. ESPN's
        // event IDs are largely sequential per league per season, so if
        // the listing endpoints are all failing we can usually find the
        // next event by guessing IDs near the previous one.
        if pickedEvent == nil || (pickedEvent?.status.type.state == "post") {
            let baseID: Int = {
                if let scoreboardLastID = scoreboard.events.last.map({ Int($0.id) ?? 0 }), scoreboardLastID > 0 {
                    return scoreboardLastID
                }
                return 401_811_950 // Memorial Tournament 2026 — empirically known anchor
            }()
            if let nextEvent = await probeSequentialEventIDs(startingFrom: baseID) {
                print("[GolfDFS] Found upcoming event \(nextEvent.id) (\(nextEvent.name)) via sequential-ID probe")
                scoreboard = ESPNPGAScoreboardResponse(events: [nextEvent])
                pickedEvent = nextEvent
            }
        }

        guard let event = pickedEvent else {
            throw NSError(domain: "GolfDFS", code: 3, userInfo: [NSLocalizedDescriptionKey: "No active PGA Tour event found"])
        }

        guard let competition = event.competitions.first else {
            throw NSError(domain: "GolfDFS", code: 4, userInfo: [NSLocalizedDescriptionKey: "No competition data in event"])
        }

        // If the event came from the core API (sequential-ID probe or
        // season-events listing), its competitors are usually a `$ref`
        // URL rather than an inline array — and our existing Codable
        // decoder maps that to an empty array. Re-fetch the competitor
        // list directly so the player pool below has someone to map.
        let competitors: [ESPNPGACompetitor]
        if competition.competitors.isEmpty {
            print("[GolfDFS] Competitors empty in event payload — hydrating from core API")
            competitors = await hydrateCompetitors(eventID: event.id, competitionID: competition.id)
            print("[GolfDFS] Hydrated \(competitors.count) competitors from core API")
        } else {
            competitors = competition.competitors
        }

        // Fetch DraftKings salaries (primary) and OWGR world rankings (fallback).
        // Golf doesn't have showdown/single-game DK variants — the salary
        // distribution is naturally compressed (top ~$11k, bottom ~$6k), so
        // the median-based showdown detection in the salary provider was
        // false-positive-ing every PGA fetch. Pass nil to skip that gate.
        async let dkSalariesTask = RotoGrindersSalaryProvider.shared.fetchSalaries(sport: "golf", maxClassicSalary: nil)
        async let worldRankTask = fetchOWGRRankings()
        let dkSalaries = await dkSalariesTask
        let worldRankByName = await worldRankTask

        if dkSalaries.isEmpty {
            print("[GolfDFS] No DK salaries found — using OWGR-based pricing")
        } else {
            print("[GolfDFS] Fetched \(dkSalaries.count) DraftKings golf salaries")
        }

        // Map competitors to DFSPlayer using DK salary (primary) or world ranking (fallback)
        var dkMatched = 0
        var dkMissed = 0
        var sampleMisses: [String] = []
        var players: [DFSPlayer] = competitors.compactMap { competitor in
            let athleteID = competitor.id
            let name = competitor.athlete.displayName
            let country = competitor.athlete.flag?.alt ?? ""
            let worldRank = matchWorldRanking(name: name, rankings: worldRankByName)

            // Try DK salary lookup first, fall back to OWGR-based estimate
            let salary: Int
            if let dkSalary = RotoGrindersSalaryProvider.lookupSalary(espnName: name, in: dkSalaries) {
                salary = dkSalary
                dkMatched += 1
            } else {
                salary = salaryFromWorldRanking(worldRank, athleteID: athleteID)
                dkMissed += 1
                if sampleMisses.count < 5 && !dkSalaries.isEmpty {
                    sampleMisses.append(name)
                }
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
        if !dkSalaries.isEmpty {
            print("[GolfDFS] DK match rate: \(dkMatched)/\(dkMatched + dkMissed) — sample misses: \(sampleMisses.joined(separator: ", "))")
            if let firstKey = dkSalaries.keys.sorted().first {
                print("[GolfDFS] Sample DK keys: \(dkSalaries.keys.sorted().prefix(5).joined(separator: ", ")) (first=\(firstKey))")
            }
        }

        // DK-only fallback: when ESPN hasn't published competitors yet
        // (typical for events 2+ days out from R1 kickoff), the players
        // array above is empty. Synthesize a pool directly from the DK
        // salary list — those names ARE the field, and DK publishes
        // them as soon as the tournament's signups are confirmed.
        // World ranking still works for projection because it's
        // matched on name.
        if players.isEmpty && !dkSalaries.isEmpty {
            print("[GolfDFS] No competitors from ESPN — building pool from \(dkSalaries.count) DK salaries")
            players = dkSalaries.map { (lowercaseName, salary) -> DFSPlayer in
                // dkSalaries keys are lowercase e.g. "scottie scheffler".
                // Title-case them for display.
                let displayName = lowercaseName.split(separator: " ")
                    .map { word -> String in
                        let s = String(word)
                        return s.prefix(1).uppercased() + s.dropFirst()
                    }
                    .joined(separator: " ")
                let worldRank = matchWorldRanking(name: displayName, rankings: worldRankByName)
                let stableID = "dk-\(lowercaseName.replacingOccurrences(of: " ", with: "-"))"
                let projection = projectedGolfPoints(salary: salary, worldRank: worldRank, athleteID: stableID)
                return DFSPlayer(
                    id: "pga-\(stableID)",
                    name: displayName,
                    team: "",          // country unknown from DK alone
                    position: "G",
                    salary: salary,
                    projectedPoints: projection,
                    gameID: event.id
                )
            }
            // Highest salary first — gives the lobby a sensible default
            // sort even before the user filters.
            players.sort { $0.salary > $1.salary }
            print("[GolfDFS] DK-only fallback: built \(players.count) players, salary range $\(players.last?.salary ?? 0)-$\(players.first?.salary ?? 0)")
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

    /// Walk the season's calendar of scheduled events from ESPN and
    /// pick the soonest one whose start date is today or in the future.
    /// Tries several URL shapes because ESPN's `?dates=` parameter is
    /// finicky about the format it accepts — some endpoints want
    /// `YYYYMMDD-YYYYMMDD` ranges, others want a single `YYYY`, and the
    /// schedule endpoint returns different payloads.
    private func findNextScheduledEventFromSeason() async -> ESPNPGAEvent? {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let year = calendar.component(.year, from: now)
        let lowerBound = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now

        // The site API's `?dates=` parameter is currently rejecting most
        // queries (returning non-2xx for `20260611`, `2025`, `2026`,
        // YYYYMMDD-YYYYMMDD ranges, etc.) so go straight to ESPN's
        // CORE API instead — its `/seasons/<year>/events` endpoint is
        // a reliable list of every scheduled event for the season.
        // Each item is a `$ref` URL that we dereference in parallel to
        // get the full ESPNPGAEvent payload.
        for season in [year, year - 1] {
            guard let listURL = URL(string: "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/\(season)/events?limit=100") else { continue }
            guard let (listData, listResp) = try? await session.data(from: listURL),
                  let listHTTP = listResp as? HTTPURLResponse,
                  (200..<300).contains(listHTTP.statusCode) else {
                print("[GolfDFS] core-events: season=\(season) list fetch failed")
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                print("[GolfDFS] core-events: season=\(season) JSON parse failed")
                continue
            }
            let refURLs = items.compactMap { $0["$ref"] as? String }
                .compactMap { URL(string: $0) }
            print("[GolfDFS] core-events: season=\(season) found \(refURLs.count) event ref(s)")

            let events = await withTaskGroup(of: ESPNPGAEvent?.self, returning: [ESPNPGAEvent].self) { group in
                for url in refURLs {
                    group.addTask {
                        guard let (data, resp) = try? await self.session.data(from: url),
                              let http = resp as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              let event = try? JSONDecoder().decode(ESPNPGAEvent.self, from: data)
                        else { return nil }
                        return event
                    }
                }
                var collected: [ESPNPGAEvent] = []
                for await event in group {
                    if let event { collected.append(event) }
                }
                return collected
            }
            print("[GolfDFS] core-events: season=\(season) dereferenced \(events.count) event(s)")

            let upcoming = events
                .compactMap { ev -> (ESPNPGAEvent, Date)? in
                    guard let d = parseESPNDate(ev.date) else { return nil }
                    return (ev, d)
                }
                .filter { $0.1 >= lowerBound }
                .sorted { $0.1 < $1.1 }
            if let (event, eventDate) = upcoming.first {
                print("[GolfDFS] core-events: picking \(event.id) (\(event.name)) startDate=\(eventDate)")
                return event
            }
        }
        return nil
    }

    /// Fetch the competitor list for an event/competition directly from
    /// ESPN's core API and decode each one into an `ESPNPGACompetitor`.
    /// Used when the event was sourced from the core `/events/<id>`
    /// endpoint — that endpoint returns competitors as a `$ref` URL,
    /// so the inline competitors array on the decoded event is empty.
    private func hydrateCompetitors(eventID: String, competitionID: String) async -> [ESPNPGACompetitor] {
        guard let listURL = URL(string: "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/\(eventID)/competitions/\(competitionID)/competitors?limit=200") else {
            return []
        }
        guard let (listData, listResp) = try? await session.data(from: listURL),
              let listHTTP = listResp as? HTTPURLResponse,
              (200..<300).contains(listHTTP.statusCode),
              let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            print("[GolfDFS] hydrateCompetitors: list fetch failed")
            return []
        }
        let refURLs = items.compactMap { $0["$ref"] as? String }
            .compactMap { URL(string: $0) }
        print("[GolfDFS] hydrateCompetitors: dereferencing \(refURLs.count) competitor refs")

        // Each competitor ref returns a JSON object with an athlete `$ref`
        // inside — we need to dereference that too to get the display
        // name. Fetch both layers in parallel per competitor.
        return await withTaskGroup(of: ESPNPGACompetitor?.self, returning: [ESPNPGACompetitor].self) { group in
            for url in refURLs {
                group.addTask { [session = self.session] in
                    guard let (cData, cResp) = try? await session.data(from: url),
                          let cHTTP = cResp as? HTTPURLResponse,
                          (200..<300).contains(cHTTP.statusCode),
                          let cJSON = try? JSONSerialization.jsonObject(with: cData) as? [String: Any] else {
                        return nil
                    }
                    // Competitor's athlete is usually a `$ref` URL to the
                    // athlete record. Resolve it for the display name.
                    var athleteName = "Unknown"
                    var athleteID = "0"
                    var country = ""
                    if let athleteRef = (cJSON["athlete"] as? [String: Any])?["$ref"] as? String,
                       let athleteURL = URL(string: athleteRef),
                       let (aData, aResp) = try? await session.data(from: athleteURL),
                       let aHTTP = aResp as? HTTPURLResponse,
                       (200..<300).contains(aHTTP.statusCode),
                       let aJSON = try? JSONSerialization.jsonObject(with: aData) as? [String: Any] {
                        athleteName = (aJSON["displayName"] as? String)
                            ?? (aJSON["fullName"] as? String)
                            ?? athleteName
                        if let id = aJSON["id"] as? String {
                            athleteID = id
                        } else if let id = aJSON["id"] as? Int {
                            athleteID = String(id)
                        }
                        if let flag = aJSON["flag"] as? [String: Any],
                           let alt = flag["alt"] as? String {
                            country = alt
                        }
                    }
                    // The competitor record itself can also carry id /
                    // athlete fields inline — prefer those when present.
                    if let id = cJSON["id"] as? String {
                        athleteID = id
                    } else if let id = cJSON["id"] as? Int {
                        athleteID = String(id)
                    }
                    let athlete = ESPNPGAAthlete(
                        displayName: athleteName,
                        shortName: nil,
                        fullName: athleteName,
                        flag: country.isEmpty ? nil : ESPNPGAFlag(alt: country, href: nil),
                        headshot: nil
                    )
                    return ESPNPGACompetitor(
                        id: athleteID,
                        athlete: athlete,
                        status: nil,
                        score: nil,
                        linescores: nil,
                        order: nil,
                        statistics: nil
                    )
                }
            }
            var collected: [ESPNPGACompetitor] = []
            for await competitor in group {
                if let competitor { collected.append(competitor) }
            }
            return collected
        }
    }

    /// Probe a small range of event IDs forward from a known anchor
    /// (typically the last-known event ID) and return the soonest
    /// event whose start date is today-or-later. ESPN IDs are nearly
    /// sequential per league/season — usually the next tournament's
    /// ID is within 1–20 of the previous one. Each probe hits the core
    /// API directly which has been the most reliable endpoint shape.
    private func probeSequentialEventIDs(startingFrom anchor: Int) async -> ESPNPGAEvent? {
        let calendar = Calendar(identifier: .gregorian)
        let lowerBound = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()

        let candidateIDs = Array((anchor + 1)...(anchor + 30))
        let events = await withTaskGroup(of: ESPNPGAEvent?.self, returning: [ESPNPGAEvent].self) { group in
            for id in candidateIDs {
                guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/\(id)") else { continue }
                group.addTask {
                    guard let (data, resp) = try? await self.session.data(from: url),
                          let http = resp as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let event = try? JSONDecoder().decode(ESPNPGAEvent.self, from: data)
                    else { return nil }
                    return event
                }
            }
            var collected: [ESPNPGAEvent] = []
            for await event in group {
                if let event { collected.append(event) }
            }
            return collected
        }
        print("[GolfDFS] sequential-ID probe: found \(events.count) event(s) in ID range \(anchor + 1)...\(anchor + 30)")

        let upcoming = events
            .compactMap { ev -> (ESPNPGAEvent, Date)? in
                guard let d = parseESPNDate(ev.date) else { return nil }
                return (ev, d)
            }
            .filter { $0.1 >= lowerBound }
            .sorted { $0.1 < $1.1 }
        if let (event, eventDate) = upcoming.first {
            print("[GolfDFS] sequential-ID probe: picking \(event.id) (\(event.name)) startDate=\(eventDate)")
            return event
        }
        return nil
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
        // Then a RECENTLY finished (post) event. Window the recency from the
        // tournament END date (Sunday) — not start date — because a PGA event
        // runs Thursday→Sunday, so by the time it goes "post" Sunday evening
        // it's already ~3.5 days past start, which would otherwise instantly
        // filter it out before we can settle. We still want to exclude *last*
        // week's tournament once the new pre/in event materializes, so cap at
        // 2 days past end. If endDate is missing, fall back to start + 6 days
        // (covers full Thu→Sun + 2-day grace).
        let now = Date()
        if let finished = events.first(where: { event in
            guard event.status.type.state == "post" else { return false }
            let referenceDate: Date? = {
                if let end = event.endDate, let parsed = parseESPNDate(end) { return parsed }
                if let start = parseESPNDate(event.date) {
                    return start.addingTimeInterval(4 * 24 * 3600) // ~Thu→Sun
                }
                return nil
            }()
            guard let ref = referenceDate else { return false }
            return now.timeIntervalSince(ref) < 2 * 24 * 3600
        }) {
            return finished
        }
        return nil
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

        // Stable per-player jitter so same-tier golfers get slightly different
        // prices. Round to $100 increments so the OWGR fallback matches DK's
        // pricing style (no $10,504 weirdness — always $10,500 / $10,600 etc).
        guard !athleteID.isEmpty else { return (baseSalary / 100) * 100 }
        let stableHash = athleteID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitterSteps = (abs(stableHash) % 3) - 1   // -1, 0, or +1 — three buckets
        let jittered = baseSalary + jitterSteps * 100
        let snapped = (jittered / 100) * 100
        return max(6000, min(15000, snapped))
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

        // Track whether we had to use the date-fallback to find the event.
        // When true, the event has already rotated off the live scoreboard
        // (i.e., it's a completed past tournament). ESPN's date-query
        // response for past events frequently strips status fields
        // (status.type.completed/name = nil, status.period = nil), which
        // would normally cause every `allGamesFinal` gate to fail. We use
        // this flag below to relax those gates when we have score-to-par
        // data confirming a solo winner.
        var usedDateFallback = false

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
                        usedDateFallback = true
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
        // Playoff detection: a playoff is in progress when 2+ active
        // competitors share the lowest score-to-par AND ESPN hasn't yet
        // broken the tie via its position field. Once the playoff
        // resolves, ESPN updates each competitor's `score.value` (score
        // to par) — the winner stays at the regulation total and the
        // runner-up's score-to-par stays the same too, but their POSITION
        // diverges (the playoff loser is no longer "T1" but "2"). When
        // ESPN's date-fallback response is stripped (status fields nil),
        // we fall back to score-to-par tie detection — different
        // score-to-par values prove the playoff is resolved regardless of
        // what raw stroke linescores say.
        //
        // We use `score.value` (score-to-par) instead of summing R1-R4
        // strokes because the date-fallback ESPN response sometimes
        // returns degenerate linescores (all rounds = 67 even though the
        // actual scores differ), which previously triggered a false tie.
        let activeForLeaderCheck = competition.competitors.filter { competitor in
            let statusName = competitor.status?.type?.name ?? ""
            return statusName != "STATUS_CUT" && statusName != "STATUS_WITHDRAWN" && statusName != "STATUS_DISQUALIFIED"
        }
        let leadingScore: Double? = activeForLeaderCheck.compactMap { c -> Double? in
            c.score?.value
        }.min()
        let leadersAtLow: Int = {
            guard let low = leadingScore else { return 0 }
            return activeForLeaderCheck.filter { c -> Bool in
                guard let v = c.score?.value else { return false }
                return abs(v - low) < 0.001
            }.count
        }()
        // Position-based playoff resolution check (only used as a tiebreak
        // signal when score-to-par values match exactly): the playoff is
        // resolved when ESPN shows exactly ONE competitor at position "1"
        // with no leading "T".
        let soloLeaderPerESPN: Bool = {
            let leadersByPosition = activeForLeaderCheck.filter { c in
                guard let pos = c.status?.displayValue else { return false }
                return pos == "1"
            }
            return leadersByPosition.count == 1
        }()
        let tiedAtTop = leadersAtLow >= 2 && !soloLeaderPerESPN
        // Standard path: tournament is on the LIVE scoreboard, so all the
        // status fields are populated and we can require the full set of
        // gates before marking final.
        //
        // Trust ESPN when it explicitly says STATUS_FINAL / completed=true.
        // After a playoff resolves, the winner's score-to-par equals the
        // runner-up's (the playoff is sudden-death; both finished
        // regulation at the same number). Our `tiedAtTop` check was
        // still firing on that real-final state, leaving last week's
        // playoff-decided tournament stuck "in progress" forever — no
        // settlement, no bots generated, no past results in My Contests.
        // ESPN's explicit final flag overrides the score-tie signal.
        // Two ways to mark final on the live scoreboard:
        //   A. ESPN explicitly says completed/STATUS_FINAL → trust it. ESPN
        //      doesn't set STATUS_FINAL between rounds, only at true end of
        //      tournament. During a sudden-death playoff ESPN flips the
        //      event-level final flag while the per-competitor R4 strokes
        //      linescore can still be stale or report a "5th period" for
        //      playoff participants — which broke our `hasR4Data` gate and
        //      left last week's playoff-decided tournament stuck in shimmer.
        //   B. No explicit final flag, but R4 has played out fully across the
        //      whole cut field (≥50 strokes for everyone). Covers the rare
        //      case where ESPN lags on flipping the event status.
        let liveScoreboardFinal = eventState == "post"
            && (espnSaysFinal || (currentRound >= 4 && hasR4Data))
        if tiedAtTop && espnSaysFinal {
            print("[PGA-Score] \(leadersAtLow) competitors tied at score-to-par but ESPN says \(eventStatusName)/completed=\(eventCompleted) — treating as final (playoff resolved)")
        }
        // Date-fallback path: the event has rotated off the live scoreboard
        // (i.e., it's a completed past tournament — for live/in-progress
        // events ESPN keeps them on the main scoreboard). The date-query
        // response strips status fields, so the live-scoreboard gates all
        // fail. In this case we trust two things:
        //   1. We have score-to-par data for the leaders (proves the
        //      tournament finished — mid-tournament events on the date
        //      query wouldn't have completed score.value for the winner).
        //   2. No regulation tie at the top (or ESPN broke the tie via
        //      a solo "1" position).
        // Together these are sufficient to mark final. The R4 stroke
        // linescores ESPN serves on the date-fallback are degenerate
        // (every round = same value), so we can't use them — but the
        // overall score.value field IS correct.
        let dateFallbackFinal = usedDateFallback
            && leadingScore != nil
            && !tiedAtTop
            && activeForLeaderCheck.count >= 2
        let allGamesFinal = liveScoreboardFinal || dateFallbackFinal
        if tiedAtTop && !allGamesFinal {
            print("[PGA-Score] \(leadersAtLow) competitors tied at \(leadingScore ?? 0) — playoff in progress, not final")
        }
        if dateFallbackFinal && !liveScoreboardFinal {
            print("[PGA-Score] Date-fallback final: leader=\(leadingScore ?? 0), leadersAtLow=\(leadersAtLow), active=\(activeForLeaderCheck.count) — marking allGamesFinal=true")
        }

        // Build game info (tournament-level status)
        let statusLabel: String
        if allGamesFinal {
            statusLabel = "Final"
        } else if tiedAtTop && hasR4Data {
            statusLabel = "Playoff"
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

    /// Resolve a human-readable player name to an ESPN athlete ID by
    /// hitting ESPN's site search endpoint. Used to convert DK-fallback
    /// IDs (which encode only the name, not an ESPN ID) into something
    /// the per-athlete history endpoint can use.
    private func resolveESPNAthleteID(forName name: String) async -> String? {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let url = URL(string: "https://site.web.api.espn.com/apis/search/v2?query=\(query)&type=player&sport=golf&limit=5") else {
            return nil
        }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The search response shape: { results: [{ contents: [{ id, uid, displayName, sport, ... }] }] }
        // IMPORTANT: `id` is a GUID like "38cbeebe-aac8-fb36-dce0-cf45436086e4"
        // that the per-athlete overview endpoint rejects with HTTP 400. The
        // *numeric* athlete ID needed by `/athletes/{id}/overview` lives inside
        // `uid` (e.g. "s:1100~a:9478" → 9478) and `link.web`
        // (e.g. ".../id/9478/scottie-scheffler"). Parse one of those instead.
        let resultSections = (json["results"] as? [[String: Any]]) ?? []
        for section in resultSections {
            let contents = (section["contents"] as? [[String: Any]]) ?? []
            for item in contents {
                let sport = (item["sport"] as? String)?.lowercased() ?? ""
                guard sport.contains("golf") else { continue }
                // 1. uid: "s:1100~a:9478" — extract digits after "a:"
                if let uid = item["uid"] as? String,
                   let aRange = uid.range(of: "a:") {
                    let tail = uid[aRange.upperBound...]
                    let digits = tail.prefix(while: { $0.isNumber })
                    if !digits.isEmpty { return String(digits) }
                }
                // 2. link.web: ".../id/9478/scottie-scheffler"
                if let link = item["link"] as? [String: Any],
                   let web = link["web"] as? String,
                   let idRange = web.range(of: "/id/") {
                    let tail = web[idRange.upperBound...]
                    let digits = tail.prefix(while: { $0.isNumber })
                    if !digits.isEmpty { return String(digits) }
                }
            }
        }
        return nil
    }

    /// Fetch recent tournament results for a golfer by ESPN athlete ID.
    /// Returns up to 15 most recent tournaments across all tours.
    func fetchTournamentHistory(athleteID: String) async throws -> [GolfTournamentResult] {
        // Strip "pga-" prefix if present
        var rawID = athleteID.hasPrefix("pga-") ? String(athleteID.dropFirst(4)) : athleteID

        // DK-fallback IDs look like "dk-eric-cole" (built from the DK
        // salary list when ESPN hadn't published competitors yet for an
        // upcoming event). Resolve those to a real ESPN athlete ID via
        // the site search API so tournament history lookups work.
        if rawID.hasPrefix("dk-") {
            let nameSlug = String(rawID.dropFirst(3)).replacingOccurrences(of: "-", with: " ")
            if let resolvedID = await resolveESPNAthleteID(forName: nameSlug) {
                print("[GolfDFS] resolved DK player '\(nameSlug)' → ESPN athlete ID \(resolvedID)")
                rawID = resolvedID
            } else {
                print("[GolfDFS] couldn't resolve ESPN athlete ID for DK player '\(nameSlug)'")
                return []
            }
        }

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
