import Foundation

// MARK: - Core Models

struct GolfTiersTournament: Equatable {
    let id: String                          // "pga-championship-2026"
    let title: String
    let majorName: String                   // "pga-championship", "masters", "us-open", "the-open"
    let season: String
    let status: String                      // open, locked, live, settled
    let lockTime: Date?
    let espnEventID: String?
    let entryCount: Int
    let isSettled: Bool
    let createdAt: Date
}

struct GolfTiersGolfer: Identifiable, Hashable {
    let id: String                          // "pga-{espnAthleteID}"
    let name: String
    let country: String
    let tier: Int                           // 1-6
    let owgrRank: Int
    var scoreToPar: Int                     // overall tournament score-to-par (0 = E)
    var roundScores: [Int]                  // [68, 70, 0, 0] for R1-R4 (0 = not played)
    var status: GolferStatus                // .active, .cut, .withdrawn
    let imageURL: String?

    enum GolferStatus: String, Codable {
        case active, cut, withdrawn
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: GolfTiersGolfer, rhs: GolfTiersGolfer) -> Bool { lhs.id == rhs.id }
}

struct GolfTiersPick: Codable, Hashable {
    let tier: Int
    let playerID: String
    let playerName: String
    let playerCountry: String
}

struct GolfTiersEntry: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [GolfTiersPick]              // 6 picks (one per tier)
    var totalScore: Int                     // best-4-of-6 combined score-to-par (lower = better)
    var rank: Int
    let isBot: Bool
    let isCurrentUser: Bool

    static func == (lhs: GolfTiersEntry, rhs: GolfTiersEntry) -> Bool {
        lhs.id == rhs.id && lhs.totalScore == rhs.totalScore && lhs.rank == rhs.rank
    }
}

struct GolfTiersLeaderboardEntry: Identifiable {
    let id: UUID
    let entryName: String
    let picks: [GolfTiersPick]
    let totalScore: Int                     // best 4 of 6 combined score-to-par
    let rank: Int
    let isCurrentUser: Bool
    /// Breakdown: playerID → effective score-to-par
    let pickScores: [String: Int]
    /// Which 4 picks are counting (the best 4)
    let countingPicks: Set<String>
}

struct GolfTiersScoreSnapshot {
    let golferScoresToPar: [String: Int]
    let golferRoundScores: [String: [Int]]
    let golferStatuses: [String: GolfTiersGolfer.GolferStatus]
    let currentRound: Int
    let isTournamentComplete: Bool
}

// MARK: - Private Groups

struct GolfTiersGroup: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date
}

struct GolfTiersGroupMember: Identifiable, Equatable {
    let id: UUID
    let groupID: UUID
    let userID: String
    let displayName: String
    let joinedAt: Date
}

// MARK: - Tier Generation Engine

struct GolfTiersEngine {
    /// Tier sizes for a major field (~156 golfers)
    /// Tier 1 = 10 elite, Tier 6 absorbs remainder
    static let tierSizes = [10, 15, 20, 25, 30]  // Tier 6 = everything left

    /// Distribute golfers into 6 tiers based on OWGR ranking (ascending = better).
    static func generateTiers(from golfers: [GolfTiersGolfer]) -> [[GolfTiersGolfer]] {
        let sorted = golfers.sorted { $0.owgrRank < $1.owgrRank }
        var tiers: [[GolfTiersGolfer]] = []
        var offset = 0

        for (tierIndex, size) in tierSizes.enumerated() {
            let end = min(offset + size, sorted.count)
            guard offset < end else {
                tiers.append([])
                continue
            }
            let tierPlayers = sorted[offset..<end].map { golfer in
                GolfTiersGolfer(
                    id: golfer.id,
                    name: golfer.name,
                    country: golfer.country,
                    tier: tierIndex + 1,
                    owgrRank: golfer.owgrRank,
                    scoreToPar: golfer.scoreToPar,
                    roundScores: golfer.roundScores,
                    status: golfer.status,
                    imageURL: golfer.imageURL
                )
            }
            tiers.append(tierPlayers)
            offset = end
        }

        // Tier 6: everything remaining
        if offset < sorted.count {
            let remaining = sorted[offset...].map { golfer in
                GolfTiersGolfer(
                    id: golfer.id,
                    name: golfer.name,
                    country: golfer.country,
                    tier: 6,
                    owgrRank: golfer.owgrRank,
                    scoreToPar: golfer.scoreToPar,
                    roundScores: golfer.roundScores,
                    status: golfer.status,
                    imageURL: golfer.imageURL
                )
            }
            tiers.append(remaining)
        } else {
            tiers.append([])
        }

        // Pad to 6 tiers if needed
        while tiers.count < 6 { tiers.append([]) }
        return tiers
    }

    /// Compute effective score-to-par with cut/WD penalties.
    /// Missed cut: actual score + flat 20 penalty. WD: actual score + 10 per unplayed round.
    static func effectiveScoreToPar(
        golferScoreToPar: Int,
        roundScores: [Int],
        status: GolfTiersGolfer.GolferStatus
    ) -> Int {
        switch status {
        case .active:
            return golferScoreToPar
        case .cut:
            // Flat +20 penalty for missed cut (matches EasyOffice pool scoring)
            return golferScoreToPar + 20
        case .withdrawn:
            let unplayedRounds = max(0, 4 - roundScores.filter({ $0 > 0 }).count)
            return golferScoreToPar + (unplayedRounds * 10)
        }
    }

    /// Compute "Best 4 of 6" leaderboard. Lowest combined score wins.
    static func computeLeaderboard(
        entries: [GolfTiersEntry],
        golferScores: [String: Int],
        golferStatuses: [String: GolfTiersGolfer.GolferStatus],
        golferRoundScores: [String: [Int]],
        currentUserID: String?
    ) -> [GolfTiersLeaderboardEntry] {
        var scored: [(entry: GolfTiersEntry, total: Int, breakdown: [String: Int], counting: Set<String>)] = []

        for entry in entries {
            var pickScores: [String: Int] = [:]
            for pick in entry.picks {
                let rawScore = golferScores[pick.playerID] ?? 0
                let rounds = golferRoundScores[pick.playerID] ?? []
                let status = golferStatuses[pick.playerID] ?? .active
                let effective = effectiveScoreToPar(
                    golferScoreToPar: rawScore,
                    roundScores: rounds,
                    status: status
                )
                pickScores[pick.playerID] = effective
            }

            // Best 4 of 6: sort by score ascending, take lowest 4
            let sortedPicks = pickScores.sorted { $0.value < $1.value }
            let best4 = Array(sortedPicks.prefix(4))
            let total = best4.reduce(0) { $0 + $1.value }
            let countingIDs = Set(best4.map { $0.key })

            scored.append((entry, total, pickScores, countingIDs))
        }

        // Sort ascending (lowest score wins — golf style)
        scored.sort { $0.total < $1.total }

        // Assign ranks with tie handling
        var result: [GolfTiersLeaderboardEntry] = []
        var currentRank = 1
        for (index, item) in scored.enumerated() {
            if index > 0 && item.total > scored[index - 1].total {
                currentRank = index + 1
            }
            result.append(GolfTiersLeaderboardEntry(
                id: item.entry.id,
                entryName: item.entry.entryName,
                picks: item.entry.picks,
                totalScore: item.total,
                rank: currentRank,
                isCurrentUser: item.entry.userID == currentUserID,
                pickScores: item.breakdown,
                countingPicks: item.counting
            ))
        }
        return result
    }

    /// Score-to-par display: -8 → "-8", 0 → "E", +3 → "+3"
    static func scoreToParDisplay(_ score: Int) -> String {
        if score == 0 { return "E" }
        return score > 0 ? "+\(score)" : "\(score)"
    }

    /// RR delta calculation (same tiers as PlayoffTiers/DFS)
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

// MARK: - ESPN Golf Tiers Data Provider

struct ESPNGolfTiersDataProvider: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Fetch Major Field

    /// Fetch all golfers in the current/next major field with OWGR rankings.
    /// Reuses ESPNPGAScoreboardResponse types from GolfDFSData.swift.
    func fetchMajorField() async throws -> (golfers: [GolfTiersGolfer], event: ESPNPGAEvent?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard") else {
            throw NSError(domain: "GolfTiers", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid PGA scoreboard URL"])
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GolfTiers", code: 2, userInfo: [NSLocalizedDescriptionKey: "PGA scoreboard request failed"])
        }

        let scoreboard = try JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: data)

        var pickedEvent = pickActiveEvent(from: scoreboard.events)

        // The default scoreboard only carries the CURRENT week's events — in a
        // major's pick window it can still be showing LAST week's finished
        // tournaments while the major's full field is already published on the
        // date-targeted scoreboard (The Open's 156 players were up 2+ days out
        // while the default board still listed the Scottish Open/ISCO, leaving
        // Golf Tiers stuck on "Signups will open when the field is announced").
        // If the default pick isn't an upcoming/live MAJOR, probe forward for
        // one. Regular Tour weeks find no major and keep the default pick, so
        // non-major behavior is unchanged. min-id tiebreak matches the DFS
        // provider: never adopt the opposite-field event (Corales) over the
        // major it shares the week with.
        let seasonYear = Calendar.current.component(.year, from: Date())
        let pickedIsUpcomingMajor: Bool = {
            guard let e = pickedEvent else { return false }
            guard (e.status.type.state ?? "") != "post" else { return false }
            return GolfTiersTournament.matchEventToMajor(eventName: e.name, year: seasonYear) != nil
        }()
        if !pickedIsUpcomingMajor {
            // Probe all 14 dates CONCURRENTLY and pick across the union —
            // cache-busted so one stale edge-cache listing (e.g. a Corales-only
            // payload from before The Open's field was posted) can't hide the
            // major. Mirrors GolfDFSData's probe.
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd"
            let cal = Calendar(identifier: .gregorian)
            let cacheBust = Int(Date().timeIntervalSince1970)
            let probed: [ESPNPGAEvent] = await withTaskGroup(of: [ESPNPGAEvent].self, returning: [ESPNPGAEvent].self) { group in
                for offset in 0..<14 {
                    guard let probeDate = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
                    let dateKey = df.string(from: probeDate)
                    group.addTask {
                        guard let probeURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard?dates=\(dateKey)&_cb=\(cacheBust)") else { return [] }
                        var request = URLRequest(url: probeURL)
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        guard let (probeData, probeResp) = try? await self.session.data(for: request),
                              let probeHTTP = probeResp as? HTTPURLResponse, (200..<300).contains(probeHTTP.statusCode),
                              let probeScoreboard = try? JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: probeData) else {
                            return []
                        }
                        return probeScoreboard.events
                    }
                }
                var merged: [ESPNPGAEvent] = []
                for await chunk in group { merged.append(contentsOf: chunk) }
                return merged
            }
            let majorCandidates = probed.filter {
                // Anything not finished counts — a just-posted event can
                // briefly carry a nil/unknown state.
                guard ($0.status.type.state ?? "") != "post" else { return false }
                return GolfTiersTournament.matchEventToMajor(eventName: $0.name, year: seasonYear) != nil
            }
            if let major = majorCandidates.min(by: { (Int($0.id) ?? .max) < (Int($1.id) ?? .max) }) {
                print("[GolfTiers] Found upcoming major \(major.id) (\(major.name)) via date probes (\(majorCandidates.count) candidates)")
                pickedEvent = major
            } else {
                // Sequential core-API walk — the only ESPN endpoint shape that
                // kept working on-device while the site API's ?dates= queries
                // returned empty (The Open week: every date probe came back
                // blank on the phone but core /events/<id> fetches succeeded).
                // Walk ids forward from the newest default-scoreboard event and
                // take the min-id upcoming event whose name matches a major.
                let anchor = scoreboard.events.compactMap { Int($0.id) }.max() ?? 401_811_950
                let cal2 = Calendar(identifier: .gregorian)
                let lowerBound = cal2.date(byAdding: .day, value: -1, to: cal2.startOfDay(for: Date())) ?? Date()
                let walked: [ESPNPGAEvent] = await withTaskGroup(of: ESPNPGAEvent?.self, returning: [ESPNPGAEvent].self) { group in
                    for id in (anchor + 1)...(anchor + 30) {
                        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/\(id)") else { continue }
                        group.addTask {
                            guard let (data, resp) = try? await self.session.data(from: url),
                                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                                  let event = try? JSONDecoder().decode(ESPNPGAEvent.self, from: data) else { return nil }
                            return event
                        }
                    }
                    var collected: [ESPNPGAEvent] = []
                    for await e in group { if let e { collected.append(e) } }
                    return collected
                }
                let walkedMajors = walked.filter { ev in
                    guard GolfTiersTournament.matchEventToMajor(eventName: ev.name, year: seasonYear) != nil else { return false }
                    guard let d = parseGolfTiersDate(ev.date) else { return false }
                    return d >= lowerBound
                }
                if let major = walkedMajors.min(by: { (Int($0.id) ?? .max) < (Int($1.id) ?? .max) }) {
                    print("[GolfTiers] Found upcoming major \(major.id) (\(major.name)) via sequential-ID walk")
                    pickedEvent = major
                }
            }
        }

        guard let event = pickedEvent else {
            throw NSError(domain: "GolfTiers", code: 3, userInfo: [NSLocalizedDescriptionKey: "No active PGA Tour event found"])
        }

        guard let competition = event.competitions.first else {
            throw NSError(domain: "GolfTiers", code: 4, userInfo: [NSLocalizedDescriptionKey: "No competition data in event"])
        }

        // Core-API events (sequential-ID walk) carry competitors as $refs, so
        // the inline array decodes empty — hydrate the field the same way the
        // DFS provider does.
        let fieldCompetitors: [ESPNPGACompetitor]
        if competition.competitors.isEmpty {
            print("[GolfTiers] Competitors empty in event payload — hydrating from core API")
            fieldCompetitors = await ESPNPGADFSSlateProvider().hydrateCompetitors(
                eventID: event.id, competitionID: competition.id
            )
            print("[GolfTiers] Hydrated \(fieldCompetitors.count) competitors from core API")
        } else {
            fieldCompetitors = competition.competitors
        }

        let worldRankByName = await fetchOWGRRankings()

        let golfers: [GolfTiersGolfer] = fieldCompetitors.compactMap { competitor in
            let athleteID = competitor.id
            let name = competitor.athlete.displayName
            let country = competitor.athlete.flag?.alt ?? ""
            let worldRank = matchWorldRanking(name: name, rankings: worldRankByName)
            let imageURL = competitor.athlete.headshot?.href

            // Parse current score-to-par
            let scoreToPar = Int(competitor.score?.value ?? 0)

            // Parse round scores
            var roundScores: [Int] = []
            if let linescores = competitor.linescores {
                roundScores = linescores.map { Int($0.value ?? 0) }
            }
            while roundScores.count < 4 { roundScores.append(0) }

            // Detect status
            let status: GolfTiersGolfer.GolferStatus
            let statusName = competitor.status?.type?.name?.lowercased() ?? ""
            if statusName.contains("cut") {
                status = .cut
            } else if statusName.contains("wd") || statusName.contains("withdraw") {
                status = .withdrawn
            } else {
                status = .active
            }

            return GolfTiersGolfer(
                id: "pga-\(athleteID)",
                name: name,
                country: country,
                tier: 0,  // Assigned during tier generation
                owgrRank: worldRank,
                scoreToPar: scoreToPar,
                roundScores: roundScores,
                status: status,
                imageURL: imageURL
            )
        }

        return (golfers, event)
    }

    // MARK: Live Scores

    /// Fetch live scores for all golfers in the tournament field.
    /// `searchAroundDate` lets us look up past majors via the dates-based scoreboard
    /// query (ESPN's current scoreboard only carries the active week's event).
    func fetchLiveScores(espnEventID: String, searchAroundDate: Date? = nil) async throws -> GolfTiersScoreSnapshot {
        var resolvedEvent: ESPNPGAEvent?

        // PREFERRED: the leaderboard endpoint. It's the only ESPN shape that
        // reliably carries per-competitor STATUS (STATUS_CUT / withdrawals)
        // and per-round linescores — the scoreboard endpoints return bare
        // competitors (id + total score only) for date-targeted/past events,
        // which meant NO golfer was ever flagged .cut and the missed-cut +20
        // penalty in effectiveScoreToPar never fired.
        if !espnEventID.isEmpty,
           let lbURL = URL(string: "https://site.web.api.espn.com/apis/site/v2/sports/golf/leaderboard?league=pga&event=\(espnEventID)") {
            if let (lbData, lbResp) = try? await session.data(from: lbURL),
               let lbHTTP = lbResp as? HTTPURLResponse, (200..<300).contains(lbHTTP.statusCode),
               let lbBoard = try? JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: lbData),
               let match = lbBoard.events.first(where: { $0.id == espnEventID }) {
                resolvedEvent = match
            } else {
                print("[GolfTiers ESPN] leaderboard endpoint miss for \(espnEventID) — falling back to scoreboard")
            }
        }

        // Fallback: main scoreboard (also the only path when espnEventID is empty)
        if resolvedEvent == nil {
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard") else {
                throw NSError(domain: "GolfTiers", code: 1)
            }

            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "GolfTiers", code: 2)
            }

            let scoreboard = try JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: data)

            resolvedEvent = scoreboard.events.first(where: { $0.id == espnEventID })
                ?? (espnEventID.isEmpty ? scoreboard.events.first : nil)
        }

        // Fallback A: direct event URL (works for any past event without needing the date).
        if resolvedEvent == nil, !espnEventID.isEmpty {
            print("[GolfTiers ESPN] enter fallback for event \(espnEventID) — trying direct URLs")
            for candidateURL in [
                "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard/\(espnEventID)",
                "https://site.api.espn.com/apis/site/v2/sports/golf/pga/leaderboard?event=\(espnEventID)",
                "https://site.web.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard?event=\(espnEventID)"
            ] {
                guard let url = URL(string: candidateURL) else { continue }
                do {
                    let (dData, dResp) = try await session.data(from: url)
                    let status = (dResp as? HTTPURLResponse)?.statusCode ?? -1
                    print("[GolfTiers ESPN] \(candidateURL) → status=\(status) bytes=\(dData.count)")
                    guard (200..<300).contains(status) else { continue }
                    // Only accept the response if it actually contains our event ID.
                    // Falling back to the first event was wrong — that's the current
                    // week's event (different golfers) and produces 0 scores against
                    // historical picks.
                    if let dBoard = try? JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: dData),
                       let match = dBoard.events.first(where: { $0.id == espnEventID }) {
                        resolvedEvent = match
                        break
                    }
                    // Try alternate shape: response with the event at the root level.
                    if let rootEvent = try? JSONDecoder().decode(ESPNPGAEvent.self, from: dData),
                       rootEvent.id == espnEventID {
                        resolvedEvent = rootEvent
                        break
                    }
                    struct SingleEventResponse: Codable { let events: [ESPNPGAEvent]? }
                    if let single = try? JSONDecoder().decode(SingleEventResponse.self, from: dData),
                       let match = single.events?.first(where: { $0.id == espnEventID }) {
                        resolvedEvent = match
                        break
                    }
                } catch {
                    print("[GolfTiers ESPN] \(candidateURL) → error=\(error.localizedDescription)")
                }
            }
        }

        // Fallback B: dates-based scoreboard for past majors. ESPN's scoreboard supports
        // `dates=YYYYMMDD`; we walk a wide window around the tournament's lockTime AND
        // around the same week one year earlier (in case the stored event ID maps to a
        // real-world year that doesn't match the simulator/test date).
        if resolvedEvent == nil, !espnEventID.isEmpty, let centerDate = searchAroundDate {
            let cal = Calendar.current
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = TimeZone(identifier: "America/New_York")
            let candidateCenters: [Date] = [
                centerDate,
                cal.date(byAdding: .year, value: -1, to: centerDate),
                cal.date(byAdding: .year, value: -2, to: centerDate)
            ].compactMap { $0 }
            outer: for center in candidateCenters {
                for offset in -3...7 {
                    guard let date = cal.date(byAdding: .day, value: offset, to: center) else { continue }
                    let dateKey = fmt.string(from: date)
                    guard let dateURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard?dates=\(dateKey)"),
                          let (dData, dResp) = try? await session.data(from: dateURL),
                          let dHttp = dResp as? HTTPURLResponse, (200..<300).contains(dHttp.statusCode),
                          let dBoard = try? JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: dData) else { continue }
                    if let match = dBoard.events.first(where: { $0.id == espnEventID }) {
                        resolvedEvent = match
                        break outer
                    }
                }
            }
        }
        guard let event = resolvedEvent, let competition = event.competitions.first else {
            throw NSError(domain: "GolfTiers", code: 3, userInfo: [NSLocalizedDescriptionKey: "Event \(espnEventID) not found on ESPN scoreboard"])
        }

        var golferScoresToPar: [String: Int] = [:]
        var golferRoundScores: [String: [Int]] = [:]
        var golferStatuses: [String: GolfTiersGolfer.GolferStatus] = [:]
        var maxRound = 0

        // "+4"/"-2"/"E" → Int; "-" (round not started) → nil.
        func parseToPar(_ s: String?) -> Int? {
            guard let s, !s.isEmpty, s != "-" else { return nil }
            if s.uppercased() == "E" { return 0 }
            return Int(s.replacingOccurrences(of: "+", with: ""))
        }

        for competitor in competition.competitors {
            let playerID = "pga-\(competitor.id)"
            // LIVE leaderboard quirk: competitor.score.value is raw STROKES
            // (e.g. 17 through 9 holes) and score.displayValue lags at "E"
            // mid-round — using them showed the whole field at E during R1.
            // The true running to-par is the SUM of per-round to-par
            // displayValues ("-2", "+4", "E"), which also sums correctly for
            // finished events.
            let scoreToPar: Int = {
                if let linescores = competitor.linescores {
                    let perRound = linescores.compactMap { parseToPar($0.displayValue) }
                    if !perRound.isEmpty { return perRound.reduce(0, +) }
                }
                if let dv = parseToPar(competitor.score?.displayValue) { return dv }
                return Int(competitor.score?.value ?? 0)
            }()
            golferScoresToPar[playerID] = scoreToPar

            var rounds: [Int] = []
            if let linescores = competitor.linescores {
                // Round STROKES. Mid-round the value is a running partial —
                // only accept plausible complete-round totals so the R1-R4
                // row stays "-" until a round actually finishes.
                rounds = linescores.map { ls in
                    let v = Int(ls.value ?? 0)
                    return v >= 55 ? v : 0
                }
                // A round counts as underway once it has a to-par value.
                let startedRounds = linescores.filter { parseToPar($0.displayValue) != nil }.count
                maxRound = max(maxRound, startedRounds)
            }
            while rounds.count < 4 { rounds.append(0) }
            golferRoundScores[playerID] = rounds

            let statusName = competitor.status?.type?.name?.lowercased() ?? ""
            if statusName.contains("cut") {
                golferStatuses[playerID] = .cut
            } else if statusName.contains("wd") || statusName.contains("withdraw") {
                golferStatuses[playerID] = .withdrawn
            } else {
                golferStatuses[playerID] = .active
            }
        }

        // Determine if tournament is complete
        let eventState = event.status.type.state ?? "pre"
        let eventCompleted = event.status.type.completed ?? false
        let statusName = event.status.type.name?.lowercased() ?? ""
        let isComplete = (eventState == "post" && (eventCompleted || statusName.contains("final")))
            && maxRound >= 4

        return GolfTiersScoreSnapshot(
            golferScoresToPar: golferScoresToPar,
            golferRoundScores: golferRoundScores,
            golferStatuses: golferStatuses,
            currentRound: maxRound,
            isTournamentComplete: isComplete
        )
    }

    /// Extract lock time (R1 start) from ESPN event
    func fetchLockTime(event: ESPNPGAEvent?) -> Date? {
        guard let event else { return nil }
        return parseGolfTiersDate(event.date)
    }

    /// Check if tournament has started
    func hasTournamentStarted(espnEventID: String) async -> Bool {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard"),
              let (data, _) = try? await session.data(from: url),
              let scoreboard = try? JSONDecoder().decode(ESPNPGAScoreboardResponse.self, from: data) else {
            return false
        }
        guard let event = scoreboard.events.first(where: { $0.id == espnEventID }) else { return false }
        let state = event.status.type.state ?? "pre"
        return state == "in" || state == "post"
    }

    /// Check if tournament is fully complete (R4 final)
    func isTournamentComplete(espnEventID: String) async -> Bool {
        guard let snapshot = try? await fetchLiveScores(espnEventID: espnEventID) else { return false }
        return snapshot.isTournamentComplete
    }

    // MARK: Private Helpers

    private func pickActiveEvent(from events: [ESPNPGAEvent]) -> ESPNPGAEvent? {
        // min-id per tier: on a two-event week (major + opposite-field, e.g.
        // The Open + Corales) ESPN gives the marquee event the lower
        // sequential id — array order isn't guaranteed, and a flip-flopping
        // pick re-binds the tiers tournament to the wrong event.
        func best(_ state: String) -> ESPNPGAEvent? {
            events.filter { $0.status.type.state == state }
                .min { (Int($0.id) ?? .max) < (Int($1.id) ?? .max) }
        }
        if let live = best("in") { return live }
        if let upcoming = best("pre") { return upcoming }
        if let finished = best("post") { return finished }
        return events.first
    }

    // MARK: OWGR World Rankings

    private func fetchOWGRRankings() async -> [String: Int] {
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

    private func normalizeForMatching(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ð", with: "d")
            .replacingOccurrences(of: "þ", with: "th")
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    private func matchWorldRanking(name: String, rankings: [String: Int]) -> Int {
        let normalized = normalizeForMatching(name)
        if let rank = rankings[name.lowercased()] { return rank }
        for (rName, rank) in rankings {
            if normalizeForMatching(rName) == normalized { return rank }
        }
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
            if matches.count == 1 { return matches[0].1 }
        }
        return 999
    }

    private func parseGolfTiersDate(_ dateString: String) -> Date? {
        let formatters: [DateFormatter] = {
            let f1 = DateFormatter()
            f1.dateFormat = "yyyy-MM-dd'T'HH:mmZ"
            f1.locale = Locale(identifier: "en_US_POSIX")
            let f2 = DateFormatter()
            f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            f2.locale = Locale(identifier: "en_US_POSIX")
            return [f1, f2]
        }()
        for f in formatters {
            if let date = f.date(from: dateString) { return date }
        }
        let isoF = ISO8601DateFormatter()
        isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoF.date(from: dateString) { return date }
        isoF.formatOptions = [.withInternetDateTime]
        return isoF.date(from: dateString)
    }
}

// MARK: - Bot Generation

struct GolfTiersBotDrafter {
    enum BotPersonality: CaseIterable {
        case favoritesHeavy
        case balanced
        case sleeperPicker
        case formBased
        case homeCrowd

        var noiseMultiplier: Double {
            switch self {
            case .favoritesHeavy: return 0.15
            case .balanced: return 0.25
            case .sleeperPicker: return 0.35
            case .formBased: return 0.40
            case .homeCrowd: return 0.25
            }
        }
    }

    static let botNames = [
        "AceHunter", "BirdieKing", "FairwayFinder", "EagleEye", "GreenInReg",
        "SandSaver", "ClubTwirler", "PuttMaster", "DrivingRange", "BackNine",
        "HoleFinder", "BogeyFree", "MajorMagic", "TourPro", "ChipShot",
        "LinksMaster", "IronStrike", "WedgeWizard", "PinSeeker", "CourseRecord",
        "TigerLine", "FlagStick", "SundayRed", "AmesCorner", "TheClaret",
        "WanamakerWon", "ValhallaPro", "AugustaAce", "StAndrews", "PebbleBeach",
        "TPC_Sawgrass", "RyderCupper", "DawgPound", "BunkerBuster", "HoleInOner",
        "ProVee", "TitleistFan", "CallawayCrew", "TaylorMade", "MashieNiblick",
        "PlumbBobber", "FourIrons", "StingerShot", "FlightPath", "GimmeRange"
    ]

    /// Deterministic RNG seeded from a tournament ID
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
    }

    private static func seed(from tournamentID: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in tournamentID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    /// Generate bot entries with diversified picks.
    static func generateBotEntries(
        tiers: [[GolfTiersGolfer]],
        count: Int = 999,
        tournamentID: String? = nil
    ) -> [GolfTiersEntry] {
        guard tiers.count >= 6, tiers.prefix(6).allSatisfy({ !$0.isEmpty }) else {
            print("[GolfTiers] Cannot generate bots: invalid tier data (count=\(tiers.count), sizes=\(tiers.map(\.count)))")
            return []
        }

        var rng: SeededRNG? = tournamentID.map { SeededRNG(seed: seed(from: $0)) }
        var entries: [GolfTiersEntry] = []

        for i in 0..<count {
            let personality = BotPersonality.allCases[i % BotPersonality.allCases.count]
            let nameIndex = i % botNames.count
            let nameSuffix = i / botNames.count
            let botName = nameSuffix == 0 ? botNames[nameIndex] : "\(botNames[nameIndex])\(nameSuffix + 1)"

            if let picks = generateBotPicks(tiers: tiers, personality: personality, rng: &rng) {
                entries.append(GolfTiersEntry(
                    id: UUID(),
                    tournamentID: "",
                    userID: nil,
                    entryName: botName,
                    picks: picks,
                    totalScore: 0,
                    rank: 0,
                    isBot: true,
                    isCurrentUser: false
                ))
            }
        }

        print("[GolfTiers] Generated \(entries.count) bot entries")
        return entries
    }

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

    private static func generateBotPicks(
        tiers: [[GolfTiersGolfer]],
        personality: BotPersonality,
        rng: inout SeededRNG?
    ) -> [GolfTiersPick]? {
        var picks: [GolfTiersPick] = []

        for tierIndex in 0..<6 {
            let tierPlayers = tiers[tierIndex]
            guard !tierPlayers.isEmpty else { return nil }

            let noiseRange = personality.noiseMultiplier
            var candidates: [(golfer: GolfTiersGolfer, weight: Double)] = []

            for golfer in tierPlayers {
                let noise = randomDouble(in: (1.0 - noiseRange)...(1.0 + noiseRange), rng: &rng)
                // Weight by inverse of OWGR rank (lower rank = higher weight = more likely)
                var weight = max((1.0 / Double(max(golfer.owgrRank, 1))) * 1000.0 * noise, 0.1)

                switch personality {
                case .favoritesHeavy:
                    if golfer.owgrRank <= (tierPlayers.first?.owgrRank ?? 999) + 3 {
                        weight *= 1.5
                    }
                case .sleeperPicker:
                    // Invert: prefer bottom of tier
                    weight = max(1.0 / weight * 100.0, 0.1)
                case .homeCrowd:
                    let c = golfer.country.lowercased()
                    if c.contains("united states") || c.contains("england") || c.contains("australia") {
                        weight *= 1.3
                    }
                case .formBased, .balanced:
                    break
                }

                candidates.append((golfer, weight))
            }

            guard !candidates.isEmpty else { return nil }

            let totalWeight = candidates.reduce(0) { $0 + $1.weight }
            var roll = randomDouble(in: 0..<totalWeight, rng: &rng)
            var selected = candidates.last!.golfer

            for candidate in candidates {
                roll -= candidate.weight
                if roll <= 0 {
                    selected = candidate.golfer
                    break
                }
            }

            picks.append(GolfTiersPick(
                tier: tierIndex + 1,
                playerID: selected.id,
                playerName: selected.name,
                playerCountry: selected.country
            ))
        }

        return picks.count == 6 ? picks : nil
    }
}

// MARK: - Date Parsing

private enum GolfTiersDateParsers {
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
    nonisolated static var golfTiersDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            if let date = GolfTiersDateParsers.noSecondsUTC.date(from: value) { return date }
            if let date = GolfTiersDateParsers.withSecondsUTC.date(from: value) { return date }
            if let date = GolfTiersDateParsers.withFractionalSeconds.date(from: value) { return date }
            if let date = GolfTiersDateParsers.isoBasic.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try container.singleValueContainer(),
                                                    debugDescription: "Cannot parse date: \(value)")
        }
        return decoder
    }
}

// MARK: - Tournament ID Helper

extension GolfTiersTournament {
    /// Detect current/next major based on calendar date.
    /// Cutoffs are the Sunday of each major's final round — once we pass that,
    /// we roll forward to the next upcoming major.
    static func currentMajorID() -> String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: Date())
        let day = calendar.component(.day, from: Date())
        // Combined MMDD key for easy single-axis comparison. Previous logic used
        // `month <= 5` which would always select PGA Championship for ANY date in May,
        // including May 26+ when PGA is already settled.
        let mmdd = month * 100 + day

        if mmdd <= 420 { return "masters-\(year)" }            // Masters: ~April 2nd full week, Sun = ~Apr 12-20
        if mmdd <= 525 { return "pga-championship-\(year)" }   // PGA Championship: ~May 3rd week, Sun = ~May 18-25
        if mmdd <= 625 { return "us-open-\(year)" }            // US Open: ~June 3rd week, Sun = ~Jun 18-22
        if mmdd <= 725 { return "the-open-\(year)" }           // The Open: ~July 3rd week, Sun = ~Jul 19-22
        // Off-season: show next year's Masters
        return "masters-\(year + 1)"
    }

    /// Window-based predicate: returns the major ID **only** when today falls
    /// inside that major's pick/play/results window. Outside of any window
    /// (e.g. May 29 — between PGA Championship and US Open), returns nil so
    /// the lobby can render a "no active major this week" state instead of
    /// running golf tiers against a regular PGA Tour event.
    ///
    /// Windows: roughly 1 week of pre-pick time + 4 days of play + a few days
    /// of result review. Major weeks are seeded to the actual PGA calendar
    /// week-of so we don't accidentally label, e.g., the Charles Schwab
    /// Challenge as "US Open".
    static func activeMajorID(now: Date = Date()) -> String? {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let mmdd = month * 100 + day

        // (id, opens, closes) — MMDD bounds. Pick window opens about a week
        // before play; results window stays open ~3 days post-finish. Outside
        // any window, no major is active.
        let windows: [(id: String, opens: Int, closes: Int)] = [
            ("masters-\(year)",          402, 418),  // Masters: Thu-Sun ~Apr 9-12
            ("pga-championship-\(year)", 507, 523),  // PGA: Thu-Sun ~May 14-17
            ("us-open-\(year)",          611, 627),  // US Open: Thu-Sun ~Jun 18-21
            ("the-open-\(year)",         709, 725)   // The Open: Thu-Sun ~Jul 16-19
        ]
        for w in windows where mmdd >= w.opens && mmdd <= w.closes {
            return w.id
        }
        return nil
    }

    /// MMDD window bounds for a major ID — same table as `activeMajorID`.
    /// Used to validate stored tournament rows: a major can only lock/settle
    /// inside its own window, so a "settled" row whose lock time falls
    /// outside it is corrupt (created against the wrong ESPN event).
    static func windowBounds(for majorID: String) -> (opens: Int, closes: Int)? {
        if majorID.contains("masters") { return (402, 418) }
        if majorID.contains("pga-championship") { return (507, 523) }
        if majorID.contains("us-open") { return (611, 627) }
        if majorID.contains("the-open") { return (709, 725) }
        return nil
    }

    static func majorTitle(for id: String) -> String {
        if id.contains("masters") { return "Masters Tournament Tiers" }
        if id.contains("pga-championship") { return "PGA Championship Tiers" }
        if id.contains("us-open") { return "U.S. Open Tiers" }
        if id.contains("the-open") { return "The Open Championship Tiers" }
        return "Golf Major Tiers"
    }

    static func majorName(for id: String) -> String {
        if id.contains("masters") { return "masters" }
        if id.contains("pga-championship") { return "pga-championship" }
        if id.contains("us-open") { return "us-open" }
        if id.contains("the-open") { return "the-open" }
        return "golf-major"
    }

    /// Match ESPN event name to our major ID
    static func matchEventToMajor(eventName: String, year: Int) -> String? {
        let lower = eventName.lowercased()
        if lower.contains("masters") { return "masters-\(year)" }
        if lower.contains("pga championship") { return "pga-championship-\(year)" }
        if lower.contains("u.s. open") || lower.contains("us open") { return "us-open-\(year)" }
        if lower.contains("open championship") || lower.contains("the open") { return "the-open-\(year)" }
        return nil
    }

    static func currentSeason() -> String {
        let year = Calendar.current.component(.year, from: Date())
        return "\(year)"
    }

    /// The next upcoming major after the current one.
    static func nextMajorID() -> String? {
        let current = currentMajorID()
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let sequence = [
            "masters-\(year)",
            "pga-championship-\(year)",
            "us-open-\(year)",
            "the-open-\(year)"
        ]
        guard let idx = sequence.firstIndex(of: current), idx + 1 < sequence.count else {
            return nil  // The Open is the last of the season
        }
        return sequence[idx + 1]
    }
}
