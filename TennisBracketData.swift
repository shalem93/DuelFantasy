import Foundation

// MARK: - Enums

enum GrandSlam: String, Codable, CaseIterable, Identifiable {
    case australianOpen = "australian_open"
    case frenchOpen = "french_open"
    case wimbledon = "wimbledon"
    case usOpen = "us_open"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .australianOpen: return "Australian Open"
        case .frenchOpen: return "French Open"
        case .wimbledon: return "Wimbledon"
        case .usOpen: return "US Open"
        }
    }

    var shortName: String {
        switch self {
        case .australianOpen: return "AO"
        case .frenchOpen: return "RG"
        case .wimbledon: return "WIM"
        case .usOpen: return "USO"
        }
    }

    var hostCountry: String {
        switch self {
        case .australianOpen: return "AUS"
        case .frenchOpen: return "FRA"
        case .wimbledon: return "GBR"
        case .usOpen: return "USA"
        }
    }

    var surface: String {
        switch self {
        case .australianOpen: return "Hard"
        case .frenchOpen: return "Clay"
        case .wimbledon: return "Grass"
        case .usOpen: return "Hard"
        }
    }

    /// Approximate start month/day for the Grand Slam (used for display purposes).
    var approximateDateRange: String {
        switch self {
        case .australianOpen: return "January"
        case .frenchOpen: return "Late May – Early June"
        case .wimbledon: return "Late June – Early July"
        case .usOpen: return "Late August – Early September"
        }
    }

    /// Approximate end date (month, day) for finals weekend — used to
    /// pick the "next" slam after the current one wraps.
    private var approxEndMonthDay: (month: Int, day: Int) {
        switch self {
        case .australianOpen: return (1, 31)
        case .frenchOpen:     return (6, 7)
        case .wimbledon:      return (7, 14)
        case .usOpen:         return (9, 8)
        }
    }

    /// Returns the slam the user is most likely interested in right now:
    /// the in-progress slam if one is active, otherwise the next upcoming
    /// one in the calendar. Wraps around year-end so December lands on
    /// the Australian Open.
    static func currentOrUpcoming(_ date: Date = Date()) -> GrandSlam {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let comps = cal.dateComponents([.month, .day], from: date)
        let mmdd = (comps.month ?? 1) * 100 + (comps.day ?? 1)
        // Order by approximate end-of-tournament so a date past one
        // slam's final rolls forward to the next.
        let ordered: [(slam: GrandSlam, endMmdd: Int)] = [
            (.australianOpen, 131),
            (.frenchOpen, 607),
            (.wimbledon, 714),
            (.usOpen, 908)
        ]
        for entry in ordered where mmdd <= entry.endMmdd {
            return entry.slam
        }
        // Past US Open → next is Australian Open (early next year).
        return .australianOpen
    }
}

enum DrawType: String, Codable, CaseIterable, Identifiable {
    case atp, wta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .atp: return "ATP (Men's)"
        case .wta: return "WTA (Women's)"
        }
    }

    var shortName: String {
        switch self {
        case .atp: return "ATP"
        case .wta: return "WTA"
        }
    }

    var espnLeague: String {
        switch self {
        case .atp: return "atp"
        case .wta: return "wta"
        }
    }
}

// MARK: - Core Models

struct TennisBracketTournament: Equatable {
    let id: String                          // "french_open-atp-2026"
    let title: String
    let grandSlam: GrandSlam
    let drawType: DrawType
    let season: String
    let status: String                      // open, locked, live, settled
    let lockTime: Date?
    let entryCount: Int
    let isSettled: Bool
    let createdAt: Date
}

struct TennisBracketPlayer: Identifiable, Hashable, Codable {
    let seed: Int?                          // 1-32 for seeded, nil for unseeded
    let drawPosition: Int                   // 1-128 position in draw
    let name: String
    let country: String
    let rank: Int                           // ATP/WTA ranking

    var id: String { "\(drawPosition)" }

    func hash(into hasher: inout Hasher) { hasher.combine(drawPosition) }
    static func == (lhs: TennisBracketPlayer, rhs: TennisBracketPlayer) -> Bool {
        lhs.drawPosition == rhs.drawPosition
    }

    enum CodingKeys: String, CodingKey {
        case seed, drawPosition = "draw_position", name, country, rank
    }
}

struct TennisBracketEntry: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [String: String]             // "R1-1" → "Sinner", 127 total
    var totalPoints: Double
    var rank: Int
    let isBot: Bool
    let isCurrentUser: Bool

    static func == (lhs: TennisBracketEntry, rhs: TennisBracketEntry) -> Bool {
        lhs.id == rhs.id && lhs.totalPoints == rhs.totalPoints && lhs.rank == rhs.rank
    }
}

struct TennisBracketLeaderboardEntry: Identifiable {
    let id: UUID
    let entryName: String
    let picks: [String: String]
    let totalPoints: Double
    let rank: Int
    let isCurrentUser: Bool
    let roundBreakdown: [String: Int]       // "R1" → points from R1
    /// Theoretical ceiling: current points + every still-possible point.
    /// A pick can still score if it hasn't been eliminated by a played match.
    let maxPossiblePoints: Double
}

// MARK: - Private Groups

struct TennisBracketGroup: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date
}

struct TennisBracketGroupMember: Identifiable, Equatable {
    let id: UUID
    let groupID: UUID
    let userID: String
    let displayName: String
    let joinedAt: Date
}

// MARK: - Bracket Engine

struct TennisBracketEngine {

    static let rounds = ["R1", "R2", "R3", "R4", "QF", "SF", "F"]
    static let matchesPerRound = [64, 32, 16, 8, 4, 2, 1]
    static let pointsPerRound = [1, 2, 4, 8, 16, 32, 64]
    static let totalPicks = 127

    /// Generate Round 1 matchups from the 128-player draw.
    /// Positions are paired sequentially: 1v2, 3v4, 5v6, ... 127v128.
    static func generateR1Matchups(from draw: [TennisBracketPlayer]) -> [(TennisBracketPlayer, TennisBracketPlayer)] {
        guard draw.count == 128 else { return [] }
        let sorted = draw.sorted { $0.drawPosition < $1.drawPosition }
        var matchups: [(TennisBracketPlayer, TennisBracketPlayer)] = []
        for i in stride(from: 0, to: 128, by: 2) {
            matchups.append((sorted[i], sorted[i + 1]))
        }
        return matchups
    }

    /// Build the match slot key for a given round and 1-based match number.
    static func matchSlot(round: String, matchNumber: Int) -> String {
        "\(round)-\(matchNumber)"
    }

    /// Which slot does the winner of `slot` advance to?
    /// R1-1 → R2-1, R1-2 → R2-1, R1-3 → R2-2, R1-4 → R2-2, ...
    static func advancementSlot(from slot: String) -> String? {
        let parts = slot.split(separator: "-")
        guard parts.count == 2,
              let roundStr = parts.first,
              let matchNum = Int(parts.last ?? "") else { return nil }

        guard let roundIndex = rounds.firstIndex(of: String(roundStr)),
              roundIndex + 1 < rounds.count else { return nil }

        let nextRound = rounds[roundIndex + 1]
        let nextMatch = (matchNum + 1) / 2
        return matchSlot(round: nextRound, matchNumber: nextMatch)
    }

    /// The two source slots that feed into a given slot.
    /// R2-1 is fed by R1-1 and R1-2.
    static func sourceSlots(for slot: String) -> (String, String)? {
        let parts = slot.split(separator: "-")
        guard parts.count == 2,
              let roundStr = parts.first,
              let matchNum = Int(parts.last ?? "") else { return nil }

        guard let roundIndex = rounds.firstIndex(of: String(roundStr)),
              roundIndex > 0 else { return nil }

        let prevRound = rounds[roundIndex - 1]
        let firstSource = matchSlot(round: prevRound, matchNumber: matchNum * 2 - 1)
        let secondSource = matchSlot(round: prevRound, matchNumber: matchNum * 2)
        return (firstSource, secondSource)
    }

    /// Score a bracket by comparing picks to results.
    static func scoreBracket(picks: [String: String], results: [String: String]) -> (total: Double, breakdown: [String: Int]) {
        var total = 0.0
        var breakdown: [String: Int] = [:]

        for (roundIndex, round) in rounds.enumerated() {
            let matchCount = matchesPerRound[roundIndex]
            let ptsPerCorrect = pointsPerRound[roundIndex]
            var roundPoints = 0

            for matchNum in 1...matchCount {
                let slot = matchSlot(round: round, matchNumber: matchNum)
                if let picked = picks[slot],
                   let actual = results[slot],
                   normalizedName(picked) == normalizedName(actual) {
                    roundPoints += ptsPerCorrect
                }
            }

            total += Double(roundPoints)
            breakdown[round] = roundPoints
        }

        return (total, breakdown)
    }

    /// Maximum points a bracket can still finish with — current points plus
    /// every pick that hasn't been eliminated yet. A pick is eliminated if
    /// any played match on their path to a slot was won by someone else.
    /// Pass a precomputed `eliminated` set when scoring many brackets at
    /// once to avoid re-scanning results per pick (cuts leaderboard build
    /// time from seconds to milliseconds on a 999-bot field).
    static func maxPossibleScore(
        picks: [String: String],
        results: [String: String],
        eliminated: Set<String>? = nil
    ) -> Double {
        let eliminatedSet: Set<String> = eliminated ?? eliminatedPlayerNames(results: results)
        var total = 0.0
        for (roundIndex, round) in rounds.enumerated() {
            let matchCount = matchesPerRound[roundIndex]
            let ptsPerCorrect = pointsPerRound[roundIndex]
            for matchNum in 1...matchCount {
                let slot = matchSlot(round: round, matchNumber: matchNum)
                guard let picked = picks[slot] else { continue }
                if let actual = results[slot] {
                    if normalizedName(picked) == normalizedName(actual) {
                        total += Double(ptsPerCorrect)
                    }
                    continue
                }
                // Match not yet played — count if the pick is still alive.
                // O(1) set lookup instead of an O(results) scan per pick.
                if !eliminatedSet.contains(normalizedName(picked)) {
                    total += Double(ptsPerCorrect)
                }
            }
        }
        return total
    }

    /// A pick is eliminated iff there exists a played match where the pick
    /// was a participant (won one of the source matches) but isn't the
    /// winner of this match. Scanning forward over all results catches the
    /// case where a player lost two or more rounds before the current
    /// (unplayed) slot — the previous backward walk only looked at the
    /// immediate source matches and missed deeper-in-the-bracket exits.
    static func isPickAlive(pick: String, results: [String: String]) -> Bool {
        let normalizedPick = normalizedName(pick)
        for (playedSlot, winner) in results {
            if normalizedName(winner) == normalizedPick { continue }
            guard let (src1, src2) = sourceSlots(for: playedSlot) else { continue }
            let s1 = results[src1].map(normalizedName)
            let s2 = results[src2].map(normalizedName)
            if s1 == normalizedPick || s2 == normalizedPick {
                return false   // pick was in this match and lost
            }
        }
        return true
    }

    /// Pre-compute the set of eliminated player names for a results map.
    /// Cheaper than calling `isPickAlive` per pick when rendering a 127-row
    /// bracket detail sheet — the previous per-pick scan was O(picks ×
    /// results) which visibly froze the UI.
    static func eliminatedPlayerNames(results: [String: String]) -> Set<String> {
        var eliminated = Set<String>()
        for (slot, winner) in results {
            guard let (src1, src2) = sourceSlots(for: slot) else { continue }
            let winNorm = normalizedName(winner)
            if let s1 = results[src1] {
                let s1n = normalizedName(s1)
                if s1n != winNorm { eliminated.insert(s1n) }
            }
            if let s2 = results[src2] {
                let s2n = normalizedName(s2)
                if s2n != winNorm { eliminated.insert(s2n) }
            }
        }
        return eliminated
    }

    /// Compute leaderboard from entries + results.
    static func computeLeaderboard(
        entries: [TennisBracketEntry],
        results: [String: String],
        currentUserID: String?
    ) -> [TennisBracketLeaderboardEntry] {
        var scored: [(entry: TennisBracketEntry, total: Double, breakdown: [String: Int], maxPossible: Double)] = []

        // Precompute the eliminated set once across the whole field — the
        // alternative (per-entry, per-pick scan) was O(entries × picks ×
        // results) which froze the main actor for ~10s on a full 999-bot
        // field with R3+ underway.
        let eliminated = eliminatedPlayerNames(results: results)
        for entry in entries {
            let (total, breakdown) = scoreBracket(picks: entry.picks, results: results)
            let maxPossible = maxPossibleScore(picks: entry.picks, results: results, eliminated: eliminated)
            scored.append((entry, total, breakdown, maxPossible))
        }

        scored.sort { $0.total > $1.total }

        // Standard competition ranking (1, 2, 2, 2, 2, 6, ...): everyone with the same
        // score gets the same rank, and the next rank skips ahead by the size of the tie.
        var ranks: [Int] = []
        ranks.reserveCapacity(scored.count)
        for index in scored.indices {
            if index > 0, scored[index].total == scored[index - 1].total {
                ranks.append(ranks[index - 1])
            } else {
                ranks.append(index + 1)
            }
        }

        return scored.enumerated().map { index, item in
            TennisBracketLeaderboardEntry(
                id: item.entry.id,
                entryName: item.entry.entryName,
                picks: item.entry.picks,
                totalPoints: item.total,
                rank: ranks[index],
                isCurrentUser: item.entry.userID == currentUserID,
                roundBreakdown: item.breakdown,
                maxPossiblePoints: item.maxPossible
            )
        }
    }

    /// RR delta calculation (same tiers as DFS).
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

    /// Validate that picks cascade correctly: every later-round pick
    /// must also appear as the pick in a preceding round that feeds it.
    static func validatePickCascade(picks: [String: String]) -> Bool {
        for (roundIndex, round) in rounds.enumerated() where roundIndex > 0 {
            let matchCount = matchesPerRound[roundIndex]
            for matchNum in 1...matchCount {
                let slot = matchSlot(round: round, matchNumber: matchNum)
                guard let picked = picks[slot] else { continue }
                // This player must have been picked as the winner in one of the two source slots
                guard let (src1, src2) = sourceSlots(for: slot) else { return false }
                let srcPick1 = picks[src1]
                let srcPick2 = picks[src2]
                if normalizedName(srcPick1 ?? "") != normalizedName(picked) &&
                   normalizedName(srcPick2 ?? "") != normalizedName(picked) {
                    return false
                }
            }
        }
        return true
    }

    /// Normalize player name for comparison (lowercase, strip diacritics).
    static func normalizedName(_ name: String) -> String {
        // Replace hyphens/en-dashes with spaces so "Auger-Aliassime" and
        // "Auger Aliassime" match. ESPN's tennis feed flips between the
        // two forms across endpoints, so compound surnames stayed pending
        // for the entire tournament under the old strict-equality match.
        // Strip periods so initialized first names ("F. Auger Aliassime")
        // collapse onto the right surname tokens for last-name matching.
        // Collapse runs of whitespace produced by the substitutions.
        var s = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{2013}", with: " ")  // en-dash
            .replacingOccurrences(of: "\u{2014}", with: " ")  // em-dash
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s
    }

    /// Clear all downstream picks that depended on a specific player
    /// being picked at a given slot. Called when user changes a pick.
    static func clearDownstreamPicks(from slot: String, playerName: String, picks: inout [String: String]) {
        guard let nextSlot = advancementSlot(from: slot) else { return }
        if let current = picks[nextSlot], normalizedName(current) == normalizedName(playerName) {
            picks.removeValue(forKey: nextSlot)
            // Recurse to clear further downstream
            clearDownstreamPicks(from: nextSlot, playerName: playerName, picks: &picks)
        }
    }
}

// MARK: - ESPN Tennis Results Provider

struct ESPNTennisResultsProvider: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// Fetch completed match results from ESPN tennis scoreboard.
    /// Maps each completed match to a draw slot using player names.
    func fetchMatchResults(
        drawType: DrawType,
        drawPlayers: [TennisBracketPlayer],
        grandSlam: GrandSlam = .frenchOpen
    ) async -> [String: String] {
        var results: [String: String] = [:]
        var totalCompleted = 0
        var totalSingles = 0
        var totalNameMissed = 0

        // ESPN's tennis scoreboard returns one "event" per tournament — not per match.
        // The competitions array inside a scoreboard event is the tournament-level
        // summary, so all match-level data must come from the per-event summary endpoint.
        let league = drawType.espnLeague

        // Collect tournament event IDs paired with their name so we can filter to the
        // specific Grand Slam. The ATP/WTA scoreboard returns concurrent tour events
        // (Geneva, Hamburg, etc.) alongside the slam — without this filter, results
        // from those tournaments get mapped onto the slam's draw positions.
        var eventIDToName: [String: String] = [:]
        let calendar = Calendar.current
        let today = Date()
        for dayOffset in 0..<16 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            let dateKey = fmt.string(from: date)
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/tennis/\(league)/scoreboard?dates=\(dateKey)") else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let events = json["events"] as? [[String: Any]] else { continue }
                for event in events {
                    let id: String?
                    if let idStr = event["id"] as? String { id = idStr }
                    else if let idNum = event["id"] as? Int { id = String(idNum) }
                    else { id = nil }
                    guard let eventID = id else { continue }
                    let name = (event["name"] as? String)
                        ?? (event["shortName"] as? String)
                        ?? ""
                    eventIDToName[eventID] = name
                }
            } catch { continue }
        }

        // Pick the slam-specific keywords to look for. Use the broadest unique tokens
        // possible to defend against ESPN naming variations.
        let slamKeywords: [String]
        switch grandSlam {
        case .australianOpen: slamKeywords = ["australian", "aus open"]
        case .frenchOpen:     slamKeywords = ["roland", "garros", "french open"]
        case .wimbledon:      slamKeywords = ["wimbledon"]
        case .usOpen:         slamKeywords = ["us open", "u.s. open", "uso"]
        }
        print("[TennisESPN] \(league) all events found: \(eventIDToName)")
        let slamEventIDs = eventIDToName.filter { (_, name) in
            let lower = name.lowercased()
            return slamKeywords.contains(where: { lower.contains($0) })
        }.map(\.key)
        // Hard requirement: if we can't identify the slam, return no results rather than
        // mixing in matches from concurrent tour events (e.g., Geneva, Hamburg) which
        // would otherwise be mapped onto Roland Garros slot positions by name collision.
        guard !slamEventIDs.isEmpty else {
            print("[TennisESPN] \(league) no slam-name match in any event; returning empty to avoid cross-tournament pollution")
            return results
        }
        let tournamentEventIDs: [String] = slamEventIDs
        print("[TennisESPN] \(league) filtered to slam-only events: \(slamEventIDs)")

        // For each tournament event, try several known ESPN endpoint variants until one
        // returns a JSON body we can parse. Tennis tournament event IDs are non-numeric
        // (e.g. "942-2026"), which not every endpoint accepts.
        for eventID in tournamentEventIDs {
            // Strip the "-2026" suffix for endpoints that want just the event number.
            let numericID = eventID.components(separatedBy: "-").first ?? eventID
            let candidateURLs = [
                "https://sports.core.api.espn.com/v2/sports/tennis/leagues/\(league)/events/\(eventID)/competitions?limit=200",
                "https://sports.core.api.espn.com/v2/sports/tennis/leagues/\(league)/events/\(numericID)/competitions?limit=200",
                "https://sports.core.api.espn.com/v2/sports/tennis/leagues/\(league)/events/\(eventID)",
                "https://site.api.espn.com/apis/site/v2/sports/tennis/\(league)/summary?event=\(eventID)",
                "https://site.api.espn.com/apis/site/v2/sports/tennis/\(league)/summary?event=\(numericID)"
            ]

            var json: [String: Any]? = nil
            for candidateURL in candidateURLs {
                guard let url = URL(string: candidateURL) else { continue }
                do {
                    let (data, response) = try await session.data(from: url)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    if !(200..<300).contains(statusCode) {
                        print("[TennisESPN] event=\(eventID) URL=\(candidateURL) status=\(statusCode)")
                        continue
                    }
                    guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        print("[TennisESPN] event=\(eventID) URL=\(candidateURL) status=\(statusCode) not-json")
                        continue
                    }
                    print("[TennisESPN] event=\(eventID) URL=\(candidateURL) status=\(statusCode) topKeys=\(Array(parsed.keys).sorted())")
                    json = parsed
                    break
                } catch {
                    print("[TennisESPN] event=\(eventID) URL=\(candidateURL) error=\(error.localizedDescription)")
                    continue
                }
            }

            guard let json else { continue }

                // Match-level competitions live under several possible keys depending on
                // tour vs slam. Try them in order.
                var matchCompetitions: [[String: Any]] = []
                if let arr = json["competitions"] as? [[String: Any]] {
                    matchCompetitions = arr
                }
                if matchCompetitions.isEmpty, let groupings = json["groupings"] as? [[String: Any]] {
                    for group in groupings {
                        if let comps = group["competitions"] as? [[String: Any]] {
                            matchCompetitions.append(contentsOf: comps)
                        }
                    }
                }
                if matchCompetitions.isEmpty, let drawData = json["drawData"] as? [String: Any],
                   let rounds = drawData["rounds"] as? [[String: Any]] {
                    for round in rounds {
                        if let comps = round["competitions"] as? [[String: Any]] {
                            matchCompetitions.append(contentsOf: comps)
                        }
                    }
                }
                if matchCompetitions.isEmpty, let events = json["events"] as? [[String: Any]] {
                    for evt in events {
                        if let comps = evt["competitions"] as? [[String: Any]] {
                            matchCompetitions.append(contentsOf: comps)
                        }
                    }
                }
                if matchCompetitions.isEmpty, let header = json["header"] as? [String: Any],
                   let comps = header["competitions"] as? [[String: Any]] {
                    matchCompetitions = comps
                }

                // Core API: `items[]` is a list of $ref URLs to per-competition (per-match) details.
                if matchCompetitions.isEmpty, let items = json["items"] as? [[String: Any]] {
                    var refURLs: [String] = []
                    for item in items {
                        if let ref = item["$ref"] as? String { refURLs.append(ref) }
                    }

                    // ESPN's core API caps each page at limit=200 and returns pageCount.
                    // A Grand Slam (singles main draw 255 + doubles + qualifying) easily
                    // spans 2-3 pages, so we MUST paginate or 4+ R1 matches stay invisible.
                    if let pageCount = json["pageCount"] as? Int, pageCount > 1 {
                        print("[TennisESPN] event=\(eventID) paginating: \(pageCount) pages")
                        for page in 2...min(pageCount, 10) {
                            let pageURL = "https://sports.core.api.espn.com/v2/sports/tennis/leagues/\(league)/events/\(eventID)/competitions?limit=200&page=\(page)"
                            guard let url = URL(string: pageURL),
                                  let (data, _) = try? await session.data(from: url),
                                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let pageItems = parsed["items"] as? [[String: Any]] else { continue }
                            for item in pageItems {
                                if let ref = item["$ref"] as? String { refURLs.append(ref) }
                            }
                        }
                    }

                    print("[TennisESPN] event=\(eventID) found \(refURLs.count) $ref item URLs (core API, paginated)")
                    let drillLimit = 800
                    if refURLs.count > drillLimit {
                        print("[TennisESPN] WARNING event=\(eventID) truncating \(refURLs.count) → \(drillLimit) — some matches may be missed")
                    }

                    // Drill into each competition. Force HTTPS — ESPN's $ref URLs are http://
                    // which is blocked by App Transport Security. A Grand Slam (singles main
                    // draw 255 + doubles ~100 + qualifying ~64 + mixed/wheelchair) can exceed
                    // 500 competitions, so the limit needs to be generous.
                    let drilled: [[String: Any]] = await withTaskGroup(of: [String: Any]?.self) { group in
                        for ref in refURLs.prefix(drillLimit) {
                            let secured = ref.hasPrefix("http://") ? "https://" + ref.dropFirst("http://".count) : ref
                            group.addTask {
                                guard let url = URL(string: secured) else { return nil }
                                guard let (data, _) = try? await self.session.data(from: url),
                                      let comp = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                                return comp
                            }
                        }
                        var out: [[String: Any]] = []
                        for await comp in group { if let comp { out.append(comp) } }
                        return out
                    }
                    matchCompetitions = drilled
                    if let first = drilled.first {
                        print("[TennisESPN] event=\(eventID) first competition keys=\(Array(first.keys).sorted())")
                    }
                }

                print("[TennisESPN] event=\(eventID) summary → \(matchCompetitions.count) match competitions")

                // First pass: extract (slot, winnerName, winnerPos, loserPos) for every
                // valid, completed singles match. We sort R1→F before applying validation
                // so the R2+ "both players already in results.values" check fires AFTER
                // R1 winners have been recorded — otherwise R2 matches that arrived first
                // in the API stream were getting rejected.
                struct ParsedMatch {
                    let slot: String
                    let winnerName: String
                    let winnerPos: Int
                    let loserPos: Int
                    // True when this match's slot was inferred from a single mapped
                    // position (the other side was a qualifier/LL not in our draw).
                    // These are best-effort R1 assumptions and must NOT overwrite
                    // a slot that's already been resolved by a "both names mapped"
                    // match — otherwise a R2 with one unmapped name would clobber
                    // the real R1 result for the same slot.
                    let isInferred: Bool
                    // ESPN competition date — used to apply inferred matches in
                    // chronological order so the win-count-based round inference
                    // is deterministic when a player has multiple matches whose
                    // opponents are all unmapped (R1 vs WC + R2 vs Q, etc.).
                    let date: Date?
                }
                let parsed: [ParsedMatch] = await withTaskGroup(of: ParsedMatch?.self) { group in
                    var sampleLogged = false
                    var doublesSkipped = 0
                    for comp in matchCompetitions {
                        guard let competitors = comp["competitors"] as? [[String: Any]],
                              competitors.count == 2 else { continue }
                        if !sampleLogged, let first = competitors.first {
                            sampleLogged = true
                            print("[TennisESPN] event=\(eventID) sample competitor keys=\(Array(first.keys).sorted()) name=\(first["name"] ?? "nil")")
                        }

                        // Aggressive doubles filtering — we don't care about doubles/mixed/wheelchair.
                        // Check multiple potential indicators on the competition itself before we
                        // even bother parsing names. ESPN exposes this via several different fields
                        // depending on which endpoint surfaced the competition.
                        if Self.looksLikeNonSinglesCompetition(comp) {
                            doublesSkipped += 1
                            continue
                        }
                        // Per-competitor: a singles match always has exactly one athlete per side.
                        // Doubles competitors carry a `roster` array, `athletes` array, or no
                        // singular `athlete` field — skip if any competitor looks multi-player.
                        if competitors.contains(where: { Self.competitorIsMultiPlayer($0) }) {
                            doublesSkipped += 1
                            continue
                        }

                        let hasWinner = competitors.contains(where: { ($0["winner"] as? Bool) == true })
                        guard hasWinner else { continue }
                        // Parse competition date once before the inner task so it
                        // doesn't capture `comp` (which is the only sendable concern).
                        let compDate: Date? = {
                            if let dateStr = comp["date"] as? String {
                                return ISO8601DateFormatter().date(from: dateStr)
                            }
                            return nil
                        }()
                        group.addTask {
                            let names: [String?] = await withTaskGroup(of: (Int, String?).self) { inner in
                                for (i, c) in competitors.enumerated() {
                                    inner.addTask {
                                        if let n = c["name"] as? String, !n.isEmpty { return (i, n) }
                                        if let athlete = c["athlete"] as? [String: Any] {
                                            if let inline = athlete["displayName"] as? String, !inline.isEmpty { return (i, inline) }
                                            if let inline = athlete["fullName"] as? String, !inline.isEmpty { return (i, inline) }
                                            if let ref = athlete["$ref"] as? String {
                                                let secured = ref.hasPrefix("http://") ? "https://" + ref.dropFirst("http://".count) : ref
                                                if let url = URL(string: secured),
                                                   let (data, _) = try? await self.session.data(from: url),
                                                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                                    return (i, json["displayName"] as? String ?? json["fullName"] as? String)
                                                }
                                            }
                                        }
                                        return (i, nil)
                                    }
                                }
                                var out: [String?] = Array(repeating: nil, count: competitors.count)
                                for await (i, name) in inner { if i < out.count { out[i] = name } }
                                return out
                            }
                            guard let n0 = names[0], let n1 = names[1],
                                  !n0.contains(" / "), !n1.contains(" / ") else { return nil }
                            guard let wIdx = competitors.firstIndex(where: { ($0["winner"] as? Bool) == true }) else { return nil }
                            let winnerName = wIdx == 0 ? n0 : n1
                            let loserName = wIdx == 0 ? n1 : n0
                            let wPosMaybe = self.findDrawPosition(name: winnerName, in: drawPlayers)
                            let lPosMaybe = self.findDrawPosition(name: loserName, in: drawPlayers)

                            // Happy path: both names map → existing slot derivation.
                            if let wPos = wPosMaybe, let lPos = lPosMaybe,
                               let slot = self.determineSlot(winnerPos: wPos, loserPos: lPos) {
                                let resolvedName = drawPlayers.first(where: { $0.drawPosition == wPos })?.name ?? winnerName
                                return ParsedMatch(slot: slot, winnerName: resolvedName, winnerPos: wPos, loserPos: lPos, isInferred: false, date: compDate)
                            }

                            // Qualifier / lucky-loser path: exactly ONE name maps to the draw
                            // (the other is a qualifier or LL whose name wasn't filled in at
                            // draw-scrape time, OR was a withdrawal replacement). We assume R1
                            // because that's the only round where a single position uniquely
                            // identifies the match. ESPN's round field is typically a $ref URL
                            // we can't easily resolve inline, so the previous round-gating was
                            // failing silently. R2+ matches with one missing name are rare
                            // (winners are tracked) and would just be skipped here.
                            let knownPos = wPosMaybe ?? lPosMaybe
                            if let knownPos, (wPosMaybe == nil) != (lPosMaybe == nil) {
                                let matchNum = (knownPos - 1) / 2 + 1
                                let slot = TennisBracketEngine.matchSlot(round: "R1", matchNumber: matchNum)
                                let resolvedName: String = {
                                    if let wPos = wPosMaybe {
                                        return drawPlayers.first(where: { $0.drawPosition == wPos })?.name ?? winnerName
                                    }
                                    return winnerName
                                }()
                                let partnerPos = knownPos % 2 == 1 ? knownPos + 1 : knownPos - 1
                                let wPos = wPosMaybe ?? partnerPos
                                let lPos = lPosMaybe ?? partnerPos
                                return ParsedMatch(slot: slot, winnerName: resolvedName, winnerPos: wPos, loserPos: lPos, isInferred: true, date: compDate)
                            }

                            if wPosMaybe == nil {
                                print("[TennisESPN] name-miss: winner '\(winnerName)' not in draw (vs '\(loserName)')")
                            }
                            if lPosMaybe == nil {
                                print("[TennisESPN] name-miss: loser '\(loserName)' not in draw (vs '\(winnerName)')")
                            }
                            return nil
                        }
                    }
                    var out: [ParsedMatch] = []
                    for await m in group { if let m { out.append(m) } }
                    if doublesSkipped > 0 {
                        print("[TennisESPN] event=\(eventID) skipped \(doublesSkipped) non-singles competitions")
                    }
                    return out
                }
                totalCompleted += parsed.count
                totalSingles += parsed.count

                // Sort by round so R1 lands first, then R2, etc. — keeps the R2+ "both
                // competitors already advanced" validation working correctly.
                let roundOrder = ["R1", "R2", "R3", "R4", "QF", "SF", "F"]
                let sortedMatches = parsed.sorted { a, b in
                    let aIdx = roundOrder.firstIndex(of: a.slot.components(separatedBy: "-").first ?? "") ?? 99
                    let bIdx = roundOrder.firstIndex(of: b.slot.components(separatedBy: "-").first ?? "") ?? 99
                    return aIdx < bIdx
                }
                // Application order matters: R2+ matches use `isPlausibleSlotAtCurrentTime`
                // which counts each player's prior wins from `results.values` to verify
                // the round assignment. We must populate ALL R1 results before checking
                // R2+ plausibility — otherwise an R2/R3/etc winner whose R1 match was
                // inferred (qualifier or LL whose name wasn't in the draw) would only
                // be credited with 0 R1 wins at R2-check time, failing the gate and
                // silently dropping the R2 match. Same cascade happens through R3+.
                //
                // Fix: apply ALL R1 results first (confirmed + inferred), then apply
                // R2+ in round order. Confirmed still wins ties via the `results[slot]
                // == nil` guard on inferred.
                let r1Confirmed = sortedMatches.filter { !$0.isInferred && $0.slot.hasPrefix("R1-") }
                // Sort inferred matches by match date ASCENDING so when a
                // single player has multiple inferred matches (e.g. R1 vs
                // wildcard + R2 vs qualifier), the earlier round is applied
                // first. The win-count-based round inference then deterministically
                // promotes the later match to R2/R3/etc. Without this the apply
                // order was arbitrary and could invert R1↔R2 for that player.
                let r1Inferred = sortedMatches
                    .filter { $0.isInferred && $0.slot.hasPrefix("R1-") }
                    .sorted { (a, b) in
                        switch (a.date, b.date) {
                        case let (.some(da), .some(db)): return da < db
                        case (.some, .none): return true
                        case (.none, .some): return false
                        case (.none, .none): return false
                        }
                    }
                let laterRounds = sortedMatches.filter { !$0.slot.hasPrefix("R1-") }
                for match in r1Confirmed {
                    if !isPlausibleSlotAtCurrentTime(slot: match.slot, results: results, drawPlayers: drawPlayers,
                                                     winnerPos: match.winnerPos, loserPos: match.loserPos) {
                        continue
                    }
                    results[match.slot] = match.winnerName
                }
                for match in r1Inferred {
                    // Determine which side (winner or loser) is the known
                    // draw player. In the parse path's qualifier branch:
                    //   • winner-known: winnerPos is a real draw pos, and
                    //     match.winnerName equals the player at winnerPos.
                    //   • loser-known:  winnerPos is the loser's R1 partner
                    //     position (placeholder), match.winnerName is the
                    //     ESPN-only winner string (not in draw).
                    let winnerDrawName = drawPlayers.first(where: { $0.drawPosition == match.winnerPos })?.name
                    let loserDrawName  = drawPlayers.first(where: { $0.drawPosition == match.loserPos  })?.name
                    let winnerIsKnown = (winnerDrawName != nil) && (winnerDrawName == match.winnerName)

                    let roundLabels = ["R1", "R2", "R3", "R4", "QF", "SF", "F"]

                    if winnerIsKnown, let winnerName = winnerDrawName {
                        // Known winner, unmapped loser (qualifier/LL).
                        // Happy path: tentative R1 slot is empty → fill it.
                        if results[match.slot] == nil {
                            if !isPlausibleSlotAtCurrentTime(slot: match.slot, results: results, drawPlayers: drawPlayers,
                                                             winnerPos: match.winnerPos, loserPos: match.loserPos) {
                                continue
                            }
                            results[match.slot] = match.winnerName
                            continue
                        }
                        // R1 slot occupied — this is actually a LATER round
                        // for the known winner vs an unmapped opponent. Use
                        // win count to infer round.
                        let winsBefore = results.values.filter { $0 == winnerName }.count
                        let nextRoundIdx = winsBefore + 1
                        guard nextRoundIdx >= 1, nextRoundIdx <= roundLabels.count else { continue }
                        let roundLabel = roundLabels[nextRoundIdx - 1]
                        let divisor = Int(pow(2.0, Double(nextRoundIdx)))
                        let matchNum = (match.winnerPos - 1) / divisor + 1
                        let inferredSlot = TennisBracketEngine.matchSlot(round: roundLabel, matchNumber: matchNum)
                        guard results[inferredSlot] == nil else { continue }
                        if !isPlausibleSlotAtCurrentTime(slot: inferredSlot, results: results, drawPlayers: drawPlayers,
                                                         winnerPos: match.winnerPos, loserPos: match.loserPos) {
                            continue
                        }
                        results[inferredSlot] = winnerName
                        print("[TennisESPN] re-routed inferred match (winner-known) for \(winnerName): \(match.slot) (occupied) → \(inferredSlot) (\(winsBefore) prior wins → \(roundLabel))")
                    } else if let loserName = loserDrawName {
                        // Known loser, unmapped winner. The known player
                        // LOST this match against a qualifier/LL whose name
                        // ESPN provides as match.winnerName. We must still
                        // record the result so the user's pick of the loser
                        // gets marked wrong / eliminated downstream.
                        //
                        // Round inference uses the LOSER's existing win
                        // count: if Zverev has 1 R1 win in results and just
                        // lost, this is his R2. Record results[R2-slot] =
                        // ESPN's winner name string (de Jong, etc.).
                        let winsBefore = results.values.filter { $0 == loserName }.count
                        let nextRoundIdx = winsBefore + 1
                        guard nextRoundIdx >= 1, nextRoundIdx <= roundLabels.count else { continue }
                        let roundLabel = roundLabels[nextRoundIdx - 1]
                        let divisor = Int(pow(2.0, Double(nextRoundIdx)))
                        let matchNum = (match.loserPos - 1) / divisor + 1
                        let inferredSlot = TennisBracketEngine.matchSlot(round: roundLabel, matchNumber: matchNum)
                        guard results[inferredSlot] == nil else { continue }
                        // Plausibility uses the loser's prior-wins count
                        // (they had to reach this round to be playing it).
                        if !isPlausibleSlotAtCurrentTime(slot: inferredSlot, results: results, drawPlayers: drawPlayers,
                                                         winnerPos: match.loserPos, loserPos: match.loserPos) {
                            continue
                        }
                        results[inferredSlot] = match.winnerName
                        print("[TennisESPN] re-routed inferred match (loser-known) — \(loserName) lost to \(match.winnerName) at \(inferredSlot) (\(winsBefore) prior wins → \(roundLabel))")
                    }
                }
                for match in laterRounds {
                    // confirmed first (already filtered), then inferred isn't expected
                    // for R2+ but be defensive: only fill empty slots.
                    if !match.isInferred {
                        if !isPlausibleSlotAtCurrentTime(slot: match.slot, results: results, drawPlayers: drawPlayers,
                                                         winnerPos: match.winnerPos, loserPos: match.loserPos) {
                            continue
                        }
                        results[match.slot] = match.winnerName
                    } else {
                        guard results[match.slot] == nil else { continue }
                        if !isPlausibleSlotAtCurrentTime(slot: match.slot, results: results, drawPlayers: drawPlayers,
                                                         winnerPos: match.winnerPos, loserPos: match.loserPos) {
                            continue
                        }
                        results[match.slot] = match.winnerName
                    }
                }
        }

        print("[TennisESPN] Summary: \(totalCompleted) completed, \(totalSingles) singles, \(totalNameMissed) name-mismatches, \(results.count) slots resolved")

        // Diagnostic: list unresolved R1 slots so we can tell when ESPN's data is
        // genuinely missing a match vs when our parser dropped it.
        let r1MatchCount = TennisBracketEngine.matchesPerRound.first ?? 64
        var unresolvedR1: [String] = []
        for matchNum in 1...r1MatchCount {
            let slot = TennisBracketEngine.matchSlot(round: "R1", matchNumber: matchNum)
            if results[slot] == nil {
                let p1 = drawPlayers.first(where: { $0.drawPosition == 2 * matchNum - 1 })?.name ?? "?"
                let p2 = drawPlayers.first(where: { $0.drawPosition == 2 * matchNum })?.name ?? "?"
                unresolvedR1.append("\(slot) (\(p1) vs \(p2))")
            }
        }
        if !unresolvedR1.isEmpty {
            print("[TennisESPN] Unresolved R1 matches (\(unresolvedR1.count)): \(unresolvedR1.joined(separator: ", "))")
        }

        // Fallback: ESPN's JSON APIs don't expose Grand Slam matches, so scrape the
        // public bracket HTML page (the same source the draw fetcher already uses).
        if results.isEmpty {
            print("[TennisESPN] JSON APIs returned no results, falling back to bracket HTML scrape")
            let scraped = await scrapeResultsFromBracketHTML(drawType: drawType, drawPlayers: drawPlayers)
            for (slot, winner) in scraped { results[slot] = winner }
        }
        return results
    }

    /// Scrape match results from ESPN's public tennis bracket HTML page.
    /// Counts how many times each draw player is flagged `"winner":true` in the embedded
    /// JSON. A player's win count tells us how many rounds they've advanced.
    private func scrapeResultsFromBracketHTML(
        drawType: DrawType,
        drawPlayers: [TennisBracketPlayer]
    ) async -> [String: String] {
        // ESPN bracket page URL — only French Open is in the live draw set today.
        let candidatePages: [String] = [
            "https://www.espn.com/tennis/french-open/bracket\(drawType == .wta ? "/_/type/wta" : "")",
            "https://www.espn.com/tennis/bracket/_/eventId/172/year/2026\(drawType == .wta ? "/type/wta" : "")"
        ]
        var html: String?
        for urlString in candidatePages {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else { continue }
            print("[TennisESPN] bracket HTML \(urlString) → \(text.count) bytes, status=\(http.statusCode)")
            html = text
            break
        }
        guard let html else {
            print("[TennisESPN] bracket HTML fetch failed for both candidate URLs")
            return [:]
        }

        // Count how many times each player appears with winner:true.
        // ESPN's bracket JSON encodes competitors with displayName + winner flags.
        // Both orderings appear in different page builds, so check both.
        var winCount: [String: Int] = [:]
        let patterns = [
            #""displayName":"([^"]{1,80})"[^{\}]{0,400}?"winner":true"#,
            #""winner":true[^{\}]{0,400}?"displayName":"([^"]{1,80})""#,
            #""athlete":\{[^\}]*"displayName":"([^"]{1,80})"[^\}]*\}[^{]{0,300}?"winner":true"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
                guard let match, let nameRange = Range(match.range(at: 1), in: html) else { return }
                let raw = String(html[nameRange])
                let normalized = TennisBracketEngine.normalizedName(raw)
                winCount[normalized, default: 0] += 1
            }
        }
        print("[TennisESPN] bracket HTML produced winCount for \(winCount.count) players (top: \(winCount.sorted(by: { $0.value > $1.value }).prefix(5).map { "\($0.key)=\($0.value)" }))")

        // Resolve win counts to draw positions using normalized name lookup.
        func winsFor(_ player: TennisBracketPlayer) -> Int {
            let normalized = TennisBracketEngine.normalizedName(player.name)
            if let direct = winCount[normalized] { return direct }
            // Fallback: last-name match (handles diacritics drops, e.g. "Felix Auger-Aliassime" → "felix auger-aliassime")
            let lastName = normalized.split(separator: " ").last.map(String.init) ?? normalized
            let candidates = winCount.filter { entry in
                let entryLast = entry.key.split(separator: " ").last.map(String.init) ?? ""
                return entryLast == lastName
            }
            if candidates.count == 1 { return candidates.first!.value }
            return 0
        }

        let drawSorted = drawPlayers.sorted { $0.drawPosition < $1.drawPosition }
        guard drawSorted.count == 128 else { return [:] }
        var results: [String: String] = [:]

        // Walk the bracket round by round. winsFor(p) >= roundIndex+1 means p won at least that round.
        var prevWinners: [Int: TennisBracketPlayer] = [:]
        for matchNum in 1...64 {
            let p1 = drawSorted[(matchNum - 1) * 2]
            let p2 = drawSorted[(matchNum - 1) * 2 + 1]
            let w1 = winsFor(p1)
            let w2 = winsFor(p2)
            // Winner must have >= 1 win and more than opponent
            let winner: TennisBracketPlayer?
            if w1 >= 1 && w1 > w2 { winner = p1 }
            else if w2 >= 1 && w2 > w1 { winner = p2 }
            else { winner = nil }
            if let w = winner {
                results[TennisBracketEngine.matchSlot(round: "R1", matchNumber: matchNum)] = w.name
                prevWinners[matchNum] = w
            }
        }
        for roundIndex in 1..<TennisBracketEngine.rounds.count {
            let round = TennisBracketEngine.rounds[roundIndex]
            let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
            var current: [Int: TennisBracketPlayer] = [:]
            for matchNum in 1...matchCount {
                guard let p1 = prevWinners[matchNum * 2 - 1],
                      let p2 = prevWinners[matchNum * 2] else { continue }
                let needed = roundIndex + 1
                let w1 = winsFor(p1)
                let w2 = winsFor(p2)
                let winner: TennisBracketPlayer?
                if w1 >= needed && w1 > w2 { winner = p1 }
                else if w2 >= needed && w2 > w1 { winner = p2 }
                else { winner = nil }
                if let w = winner {
                    results[TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)] = w.name
                    current[matchNum] = w
                }
            }
            prevWinners = current
        }

        print("[TennisESPN] bracket HTML scraper resolved \(results.count) slots")
        return results
    }

    /// Reject slot mappings that can't possibly correspond to a real match yet.
    /// For round N (where R1=1, R2=2, ..., F=7), both competitors must already have
    /// (N-1) prior wins recorded in `results`. Counting appearances in `results.values`
    /// gives us that directly — a R1 winner shows up once, a R2 winner shows up twice,
    /// etc. This stops a qualifying-round upset from getting walked into a deep-bracket
    /// slot just because both names happen to match main-draw players.
    private func isPlausibleSlotAtCurrentTime(
        slot: String,
        results: [String: String],
        drawPlayers: [TennisBracketPlayer],
        winnerPos: Int,
        loserPos: Int
    ) -> Bool {
        let round = slot.components(separatedBy: "-").first ?? ""
        if round == "R1" { return true }
        let roundOrder: [String: Int] = ["R1": 1, "R2": 2, "R3": 3, "R4": 4, "QF": 5, "SF": 6, "F": 7]
        guard let roundN = roundOrder[round] else { return false }
        // R2 always passes — the slot math from (winnerPos, loserPos) is
        // deterministic and at R2 the only "wrong slot" case would be a
        // qualifier-round match where both names happen to also be
        // main-draw players, which is vanishingly rare.
        guard roundN >= 3 else { return true }
        let winnerName = drawPlayers.first(where: { $0.drawPosition == winnerPos })?.name ?? ""
        var winsByPlayer: [String: Int] = [:]
        for v in results.values { winsByPlayer[v, default: 0] += 1 }
        // For R3 and deeper: require the winner has AT LEAST ONE recorded
        // prior win, not exactly `roundN - 1`. The strict count breaks
        // when ESPN's data has gaps:
        //   • Walkovers: ESPN sometimes omits a walkover match entirely.
        //     If Fils won R2 by walkover, results has no R2 entry for
        //     him, his win count is 1 (just R1), and a strict R3 check
        //     (requires 2) drops his legitimate R3 win.
        //   • Retirements / late name updates: same shape.
        //   • Qualifier R1 paths where ESPN's match data didn't surface.
        // Trust the slot math; require only that the winner shows up
        // somewhere upstream so we still reject purely orphan matches.
        return (winsByPlayer[winnerName] ?? 0) >= 1
    }

    /// Find draw position by fuzzy name match. Handles compound surnames like
    /// "Diaz Acosta", "Van Assche", "Auger Aliassime" by trying both single
    /// last-name and two-word last-name. Also tries first-initial + last-name
    /// matches so "S. Wawrinka" resolves to "Stan Wawrinka". And handles ESPN's
    /// Asian name ordering (e.g. "Wu Yibing" → "Yibing Wu") via reversed-token
    /// fallback.
    private func findDrawPosition(name: String, in draw: [TennisBracketPlayer]) -> Int? {
        let normalized = TennisBracketEngine.normalizedName(name)

        // Exact match first
        if let player = draw.first(where: { TennisBracketEngine.normalizedName($0.name) == normalized }) {
            return player.drawPosition
        }

        let parts = normalized.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }

        // ESPN sometimes uses Asian name ordering (Surname Given) where the draw
        // has Western order (Given Surname). Try the reversed token order as an
        // exact match. Handles "Wu Yibing" ↔ "Yibing Wu", "Zhang Zhizhen" ↔ "Zhizhen Zhang".
        if parts.count >= 2 {
            let reversed = parts.reversed().joined(separator: " ")
            if let player = draw.first(where: {
                TennisBracketEngine.normalizedName($0.name) == reversed
            }) {
                return player.drawPosition
            }
        }

        // Try LAST TWO words as a compound surname (Diaz Acosta, Van Assche, Auger Aliassime).
        if parts.count >= 2 {
            let twoWord = parts.suffix(2).joined(separator: " ")
            let matches = draw.filter { player in
                let pNorm = TennisBracketEngine.normalizedName(player.name)
                let pParts = pNorm.split(separator: " ").map(String.init)
                guard pParts.count >= 2 else { return false }
                let pTwoWord = pParts.suffix(2).joined(separator: " ")
                return pTwoWord == twoWord
            }
            if matches.count == 1 { return matches[0].drawPosition }
        }

        // Last word as surname (Wawrinka, Wu, Zhang). Only succeeds when unique.
        let lastName = parts.last ?? normalized
        let lastNameMatches = draw.filter { player in
            let playerLastName = TennisBracketEngine.normalizedName(player.name)
                .split(separator: " ").last.map(String.init) ?? ""
            return playerLastName == lastName
        }
        if lastNameMatches.count == 1 { return lastNameMatches[0].drawPosition }

        // First-initial + last-name fallback ("S. Wawrinka" → first=S, last=wawrinka).
        // Useful when ESPN abbreviates the first name.
        if parts.count >= 2 {
            let firstChar = parts.first?.first
            let multi = draw.filter { player in
                let pNorm = TennisBracketEngine.normalizedName(player.name)
                let pParts = pNorm.split(separator: " ").map(String.init)
                guard pParts.count >= 2 else { return false }
                let pLast = pParts.last ?? ""
                let pFirstChar = pParts.first?.first
                return pLast == lastName && firstChar == pFirstChar
            }
            if multi.count == 1 { return multi[0].drawPosition }
        }

        return nil
    }

    /// Returns true if the competition object looks like anything other than a
    /// main-draw singles match (doubles, mixed doubles, wheelchair, juniors,
    /// quad, etc.). We inspect several optional fields because ESPN's exact
    /// shape varies by endpoint.
    private static func looksLikeNonSinglesCompetition(_ comp: [String: Any]) -> Bool {
        // type: { id, text, abbreviation }
        if let type = comp["type"] as? [String: Any] {
            for key in ["text", "abbreviation", "name", "description"] {
                if let s = type[key] as? String, isNonSinglesLabel(s) { return true }
            }
        }
        // format hints
        if let format = comp["format"] as? [String: Any] {
            for key in ["name", "text", "description"] {
                if let s = format[key] as? String, isNonSinglesLabel(s) { return true }
            }
        }
        // notes: [{ type, value }]
        if let notes = comp["notes"] as? [[String: Any]] {
            for note in notes {
                if let v = note["value"] as? String, isNonSinglesLabel(v) { return true }
                if let v = note["headline"] as? String, isNonSinglesLabel(v) { return true }
            }
        }
        // headline / name / shortName fallbacks
        for key in ["name", "shortName", "headline", "displayName"] {
            if let s = comp[key] as? String, isNonSinglesLabel(s) { return true }
        }
        // $ref path occasionally contains "/doubles/" or competition path
        if let ref = comp["$ref"] as? String, isNonSinglesLabel(ref) { return true }
        return false
    }

    private static func isNonSinglesLabel(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("doubles")
            || lower.contains("mixed")
            || lower.contains("wheelchair")
            || lower.contains("junior")
            || lower.contains("quad")
            || lower.contains("legends")
    }

    /// Returns true if a competitor object looks like a doubles team (multiple
    /// athletes, a roster array, or an empty/missing singular athlete).
    private static func competitorIsMultiPlayer(_ c: [String: Any]) -> Bool {
        if let athletes = c["athletes"] as? [Any], athletes.count > 1 { return true }
        if let roster = c["roster"] as? [Any], roster.count > 1 { return true }
        // ESPN sometimes uses a team object with multiple athlete refs
        if let team = c["team"] as? [String: Any],
           let teamAthletes = team["athletes"] as? [Any], teamAthletes.count > 1 { return true }
        // A slash in the visible name is the classic doubles signature
        if let name = c["name"] as? String, name.contains(" / ") { return true }
        if let display = c["displayName"] as? String, display.contains(" / ") { return true }
        return false
    }

    /// Given two draw positions of match participants, determine the bracket slot.
    /// R1: positions 1,2 → R1-1; positions 3,4 → R1-2; etc.
    /// R2: winner of R1-1 vs winner of R1-2 → R2-1; etc.
    private func determineSlot(winnerPos: Int, loserPos: Int) -> String? {
        // Find which R1 match each position belongs to
        let r1Match1 = (winnerPos - 1) / 2 + 1  // 1-based R1 match number
        let r1Match2 = (loserPos - 1) / 2 + 1

        if r1Match1 == r1Match2 {
            // Both in the same R1 match
            return TennisBracketEngine.matchSlot(round: "R1", matchNumber: r1Match1)
        }

        // They met in a later round. Walk up the bracket.
        for (roundIndex, round) in TennisBracketEngine.rounds.enumerated() where roundIndex > 0 {
            let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
            let divisor = Int(pow(2.0, Double(roundIndex + 1)))

            let m1 = (winnerPos - 1) / divisor + 1
            let m2 = (loserPos - 1) / divisor + 1

            if m1 == m2 && m1 >= 1 && m1 <= matchCount {
                return TennisBracketEngine.matchSlot(round: round, matchNumber: m1)
            }
        }

        return nil
    }
}

// MARK: - Hardcoded Draw Data

/// Pre-loaded draw data for Grand Slams. ESPN bracket pages are client-rendered
/// and unreliable for HTML scraping, so we hardcode draws when available.
struct TennisBracketDrawData {

    /// Returns the hardcoded draw for a given Grand Slam, draw type, and year if available.
    static func hardcodedDraw(grandSlam: GrandSlam, drawType: DrawType, year: Int) -> [TennisBracketPlayer]? {
        switch (grandSlam, drawType, year) {
        case (.frenchOpen, .atp, 2026): return frenchOpen2026ATP()
        case (.frenchOpen, .wta, 2026): return frenchOpen2026WTA()
        default: return nil
        }
    }

    // MARK: - 2026 Roland Garros ATP Men's Singles

    private static func frenchOpen2026ATP() -> [TennisBracketPlayer] {
        // Draw positions 1-128, paired as matchups: 1v2, 3v4, 5v6, ... 127v128
        let drawEntries: [(name: String, seed: Int?, country: String, rank: Int)] = [
            // Match 1: [1] Sinner vs Tabur
            ("Jannik Sinner", 1, "ITA", 1),
            ("Constant Tabur", nil, "FRA", 95),
            // Match 2: Fearnley vs J.M. Cerundolo
            ("Jack Fearnley", nil, "GBR", 58),
            ("Juan Manuel Cerundolo", nil, "ARG", 75),
            // Match 3: Landaluce vs Prado Angelo
            ("Martin Landaluce", nil, "ESP", 80),
            ("Juan Pablo Prado Angelo", nil, "BOL", 130),
            // Match 4: Kopriva vs [30] Moutet
            ("Vit Kopriva", nil, "CZE", 110),
            ("Corentin Moutet", 30, "FRA", 30),
            // Match 5: [22] Rinderknech vs Rodionov
            ("Arthur Rinderknech", 22, "FRA", 22),
            ("Jurij Rodionov", nil, "AUT", 88),
            // Match 6: Fucsovics vs Berrettini
            ("Marton Fucsovics", nil, "HUN", 78),
            ("Matteo Berrettini", nil, "ITA", 42),
            // Match 7: Quinn vs Comesana
            ("Ethan Quinn", nil, "USA", 90),
            ("Federico Comesana", nil, "ARG", 72),
            // Match 8: Ofner vs [14] Darderi
            ("Sebastian Ofner", nil, "AUT", 62),
            ("Luciano Darderi", 14, "ITA", 14),
            // Match 9: [9] Bublik vs Struff
            ("Alexander Bublik", 9, "KAZ", 9),
            ("Jan-Lennard Struff", nil, "GER", 55),
            // Match 10: Faria vs Shapovalov
            ("Joao Faria", nil, "POR", 105),
            ("Denis Shapovalov", nil, "CAN", 65),
            // Match 11: Munar vs Hurkacz
            ("Jaume Munar", nil, "ESP", 68),
            ("Hubert Hurkacz", nil, "POL", 38),
            // Match 12: Spizzirri vs [19] Tiafoe
            ("Ethan Spizzirri", nil, "USA", 115),
            ("Frances Tiafoe", 19, "USA", 19),
            // Match 13: [29] Griekspoor vs Arnaldi
            ("Tallon Griekspoor", 29, "NED", 29),
            ("Matteo Arnaldi", nil, "ITA", 36),
            // Match 14: Muller vs Tsitsipas
            ("Alexandre Muller", nil, "FRA", 53),
            ("Stefanos Tsitsipas", nil, "GRE", 40),
            // Match 15: Collignon vs Vukic
            ("Romain Collignon", nil, "BEL", 120),
            ("Aleksandar Vukic", nil, "AUS", 60),
            // Match 16: Merida vs [5] Shelton
            ("Daniel Merida", nil, "ESP", 125),
            ("Ben Shelton", 5, "USA", 5),
            // Match 17: [4] Auger-Aliassime vs Altmaier
            ("Felix Auger-Aliassime", 4, "CAN", 4),
            ("Daniel Altmaier", nil, "GER", 82),
            // Match 18: Baez vs Burruchaga
            ("Sebastian Baez", nil, "ARG", 44),
            ("Roman Burruchaga", nil, "ARG", 100),
            // Match 19: Van Assche vs Kypson
            ("Luca Van Assche", nil, "FRA", 85),
            ("Peter Kypson", nil, "USA", 128),
            // Match 20: Bautista Agut vs [31] Nakashima
            ("Roberto Bautista Agut", nil, "ESP", 50),
            ("Brandon Nakashima", 31, "USA", 31),
            // Match 21: [20] Norrie vs Vallejo
            ("Cameron Norrie", 20, "GBR", 20),
            ("Andres Vallejo", nil, "PAR", 118),
            // Match 22: Cilic vs Kouame
            ("Marin Cilic", nil, "CRO", 92),
            ("Mathieu Kouame", nil, "FRA", 135),
            // Match 23: Tabilo vs Majchrzak
            ("Alejandro Tabilo", nil, "CHI", 48),
            ("Kamil Majchrzak", nil, "POL", 108),
            // Match 24: Faurel vs [16] Vacherot
            ("Theo Faurel", nil, "FRA", 112),
            ("Valentin Vacherot", 16, "MON", 16),
            // Match 25: [10] Cobolli vs Pellegrino
            ("Flavio Cobolli", 10, "ITA", 10),
            ("Andrea Pellegrino", nil, "ITA", 70),
            // Match 26: Wu vs Giron
            ("Yibing Wu", nil, "CHN", 98),
            ("Marcos Giron", nil, "USA", 64),
            // Match 27: Diaz Acosta vs Zhang
            ("Facundo Diaz Acosta", nil, "ARG", 56),
            ("Zhizhen Zhang", nil, "CHN", 46),
            // Match 28: Garin vs [18] Tien
            ("Cristian Garin", nil, "CHI", 76),
            ("Learner Tien", 18, "USA", 18),
            // Match 29: [25] F. Cerundolo vs Van De Zandschulp
            ("Francisco Cerundolo", 25, "ARG", 25),
            ("Botic Van De Zandschulp", nil, "NED", 52),
            // Match 30: Gaston vs Monfils
            ("Hugo Gaston", nil, "FRA", 88),
            ("Gael Monfils", nil, "FRA", 35),
            // Match 31: Popyrin vs Svajda
            ("Alexei Popyrin", nil, "AUS", 34),
            ("Zachary Svajda", nil, "USA", 122),
            // Match 32: Walton vs [6] Medvedev
            ("Adam Walton", nil, "AUS", 102),
            ("Daniil Medvedev", 6, "RUS", 6),
            // Match 33: [8] de Minaur vs Samuel
            ("Alex de Minaur", 8, "AUS", 8),
            ("Tommy Samuel", nil, "GBR", 132),
            // Match 34: Blockx vs Wong
            ("Alexander Blockx", nil, "BEL", 96),
            ("Coleman Wong", nil, "HKG", 116),
            // Match 35: Navone vs Brooksby
            ("Mariano Navone", nil, "ARG", 47),
            ("Jenson Brooksby", nil, "USA", 84),
            // Match 36: Droguet vs [26] Mensik
            ("Terence Droguet", nil, "FRA", 106),
            ("Jakub Mensik", 26, "CZE", 26),
            // Match 37: [23] Etcheverry vs Borges
            ("Tomas Martin Etcheverry", 23, "ARG", 23),
            ("Nuno Borges", nil, "POR", 33),
            // Match 38: Kecmanovic vs Marozsan
            ("Miomir Kecmanovic", nil, "SRB", 54),
            ("Fabian Marozsan", nil, "HUN", 66),
            // Match 39: Nava vs Ugo Carabelli
            ("Emilio Nava", nil, "USA", 74),
            ("Camilo Ugo Carabelli", nil, "ARG", 86),
            // Match 40: Buse vs [11] Rublev
            ("Ignacio Buse", nil, "PER", 138),
            ("Andrey Rublev", 11, "RUS", 11),
            // Match 41: [15] Ruud vs Safiullin
            ("Casper Ruud", 15, "NOR", 15),
            ("Roman Safiullin", nil, "RUS", 78),
            // Match 42: Medjedovic vs Hanfmann
            ("Hamad Medjedovic", nil, "SRB", 57),
            ("Yannick Hanfmann", nil, "GER", 94),
            // Match 43: Sonego vs Herbert
            ("Lorenzo Sonego", nil, "ITA", 49),
            ("Pierre-Hugues Herbert", nil, "FRA", 140),
            // Match 44: Hijikata vs [24] Paul
            ("Rinky Hijikata", nil, "AUS", 60),
            ("Tommy Paul", 24, "USA", 24),
            // Match 45: [28] Fonseca vs Pavlovic
            ("Joao Fonseca", 28, "BRA", 28),
            ("Luka Pavlovic", nil, "FRA", 104),
            // Match 46: Zheng vs Prizmic
            ("Mackenzie Zheng", nil, "USA", 98),
            ("Dino Prizmic", nil, "CRO", 114),
            // Match 47: Dellien vs Royer
            ("Hugo Dellien", nil, "BOL", 88),
            ("Victor Royer", nil, "FRA", 130),
            // Match 48: Mpetshi Perricard vs [3] Djokovic
            ("Giovanni Mpetshi Perricard", nil, "FRA", 32),
            ("Novak Djokovic", 3, "SRB", 3),
            // Match 49: [7] Fritz vs Basavareddy
            ("Taylor Fritz", 7, "USA", 7),
            ("Nishesh Basavareddy", nil, "USA", 108),
            // Match 50: Shevchenko vs Michelsen
            ("Alexander Shevchenko", nil, "KAZ", 58),
            ("Alex Michelsen", nil, "USA", 39),
            // Match 51: Duckworth vs Diallo
            ("James Duckworth", nil, "AUS", 90),
            ("Gabriel Diallo", nil, "CAN", 72),
            // Match 52: Kovacevic vs [27] Jodar
            ("Aleksandar Kovacevic", nil, "USA", 82),
            ("Roberto Jodar", 27, "ESP", 27),
            // Match 53: [21] Davidovich Fokina vs Dzumhur
            ("Alejandro Davidovich Fokina", 21, "ESP", 21),
            ("Damir Dzumhur", nil, "BIH", 120),
            // Match 54: Llamas Ruiz vs Tirante
            ("Pablo Llamas Ruiz", nil, "ESP", 96),
            ("Thiago Tirante", nil, "ARG", 64),
            // Match 55: Kokkinakis vs Atmane
            ("Thanasi Kokkinakis", nil, "AUS", 70),
            ("Terence Atmane", nil, "FRA", 100),
            // Match 56: Carreno Busta vs [12] Lehecka
            ("Pablo Carreno Busta", nil, "ESP", 50),
            ("Jiri Lehecka", 12, "CZE", 12),
            // Match 57: [13] Khachanov vs Gea
            ("Karen Khachanov", 13, "RUS", 13),
            ("Alexis Gea", nil, "FRA", 134),
            // Match 58: Jacquet vs Trungelliti
            ("Kyrian Jacquet", nil, "FRA", 110),
            ("Marco Trungelliti", nil, "ARG", 92),
            // Match 59: Cina vs Opelka
            ("Francesco Cina", nil, "ITA", 126),
            ("Reilly Opelka", nil, "USA", 42),
            // Match 60: Wawrinka vs [17] Fils
            ("Stan Wawrinka", nil, "SUI", 148),
            ("Arthur Fils", 17, "FRA", 17),
            // Match 61: [32] Humbert vs Mannarino
            ("Ugo Humbert", 32, "FRA", 32),
            ("Adrian Mannarino", nil, "FRA", 45),
            // Match 62: Halys vs Bellucci
            ("Quentin Halys", nil, "FRA", 78),
            ("Mattia Bellucci", nil, "ITA", 56),
            // Match 63: Machac vs Bergs
            ("Tomas Machac", nil, "CZE", 37),
            ("Zizou Bergs", nil, "BEL", 68),
            // Match 64: Bonzi vs [2] Zverev
            ("Benjamin Bonzi", nil, "FRA", 74),
            ("Alexander Zverev", 2, "GER", 2),
        ]

        return drawEntries.enumerated().map { index, entry in
            TennisBracketPlayer(
                seed: entry.seed,
                drawPosition: index + 1,
                name: entry.name,
                country: entry.country,
                rank: entry.rank
            )
        }
    }

    // MARK: - 2026 Roland Garros WTA Women's Singles

    private static func frenchOpen2026WTA() -> [TennisBracketPlayer] {
        // Draw positions 1-128, paired as matchups: 1v2, 3v4, 5v6, ... 127v128
        let drawEntries: [(name: String, seed: Int?, country: String, rank: Int)] = [
            // Match 1: [1] Sabalenka vs Bouzas Maneiro
            ("Aryna Sabalenka", 1, "BLR", 1),
            ("Jessica Bouzas Maneiro", nil, "ESP", 60),
            // Match 2: Fruhvirtova vs Jacquemot
            ("Linda Fruhvirtova", nil, "CZE", 55),
            ("Elsa Jacquemot", nil, "FRA", 85),
            // Match 3: Kasatkina vs Sonmez
            ("Daria Kasatkina", nil, "AUS", 52),
            ("Zeynep Sonmez", nil, "TUR", 95),
            // Match 4: Bandecchi vs [31] Bucsa
            ("Susan Bandecchi", nil, "SUI", 70),
            ("Cristina Bucsa", 31, "ESP", 31),
            // Match 5: [17] Jovic vs Eala
            ("Iva Jovic", 17, "USA", 17),
            ("Alexandra Eala", nil, "PHI", 38),
            // Match 6: Navarro vs Tjen
            ("Emma Navarro", nil, "USA", 39),
            ("Janice Tjen", nil, "INA", 41),
            // Match 7: Vekic vs Tubello
            ("Donna Vekic", nil, "CRO", 56),
            ("Alice Tubello", nil, "FRA", 110),
            // Match 8: Siegemund vs [16] Osaka
            ("Laura Siegemund", nil, "GER", 46),
            ("Naomi Osaka", 16, "JPN", 16),
            // Match 9: [9] Mboko vs Bartunkova
            ("Victoria Mboko", 9, "CAN", 9),
            ("Nikola Bartunkova", nil, "CZE", 75),
            // Match 10: Waltert vs Siniakova
            ("Simona Waltert", nil, "SUI", 80),
            ("Katerina Siniakova", nil, "CZE", 36),
            // Match 11: Ruzic vs Krueger
            ("Antonia Ruzic", nil, "CRO", 90),
            ("Ashlyn Krueger", nil, "USA", 65),
            // Match 12: Vandewinkel vs [19] Keys
            ("Hanne Vandewinkel", nil, "BEL", 100),
            ("Madison Keys", 19, "USA", 19),
            // Match 13: [25] Shnaider vs Zarazua
            ("Diana Shnaider", 25, "RUS", 25),
            ("Renata Zarazua", nil, "MEX", 88),
            // Match 14: Guo vs Kessler
            ("Haiyu Guo", nil, "CHN", 105),
            ("McCartney Kessler", nil, "USA", 47),
            // Match 15: Pridankina vs Oliynykova
            ("Ekaterina Pridankina", nil, "RUS", 115),
            ("Olesya Oliynykova", nil, "UKR", 120),
            // Match 16: Birrell vs [5] Pegula
            ("Kimberly Birrell", nil, "AUS", 68),
            ("Jessica Pegula", 5, "USA", 5),
            // Match 17: [4] Gauff vs Townsend
            ("Coco Gauff", 4, "USA", 4),
            ("Taylor Townsend", nil, "USA", 62),
            // Match 18: Galfi vs Sherif
            ("Dalma Galfi", nil, "HUN", 72),
            ("Mayar Sherif", nil, "EGY", 78),
            // Match 19: Urhobo vs Boulter
            ("Alycia Urhobo", nil, "USA", 125),
            ("Katie Boulter", nil, "GBR", 58),
            // Match 20: Joint vs [28] Potapova
            ("Maya Joint", nil, "AUS", 34),
            ("Anastasia Potapova", 28, "AUT", 28),
            // Match 21: [22] Kalinskaya vs Boisson
            ("Anna Kalinskaya", 22, "RUS", 22),
            ("Lois Boisson", nil, "FRA", 50),
            // Match 22: Korneeva vs Cocciaretto
            ("Alina Korneeva", nil, "RUS", 64),
            ("Elisabetta Cocciaretto", nil, "ITA", 40),
            // Match 23: Gibson vs Putintseva
            ("Tina Gibson", nil, "AUS", 98),
            ("Yulia Putintseva", nil, "KAZ", 54),
            // Match 24: Osorio vs [14] Alexandrova
            ("Camila Osorio", nil, "COL", 82),
            ("Ekaterina Alexandrova", 14, "RUS", 14),
            // Match 25: [12] Noskova vs Sakkari
            ("Linda Noskova", 12, "CZE", 12),
            ("Maria Sakkari", nil, "GRE", 48),
            // Match 26: Liu vs Uchijima
            ("Claire Liu", nil, "USA", 74),
            ("Moyuka Uchijima", nil, "JPN", 66),
            // Match 27: Chwalinska vs Zheng
            ("Maja Chwalinska", nil, "POL", 116),
            ("Qinwen Zheng", nil, "CHN", 53),
            // Match 28: Maria vs [23] Mertens
            ("Tatjana Maria", nil, "GER", 92),
            ("Elise Mertens", 23, "BEL", 23),
            // Match 29: [30] Li vs Zhang
            ("Ann Li", 30, "USA", 30),
            ("Shuai Zhang", nil, "CHN", 108),
            // Match 30: Kalinina vs Parry
            ("Anhelina Kalinina", nil, "UKR", 76),
            ("Diane Parry", nil, "FRA", 63),
            // Match 31: Grabher vs Sramkova
            ("Julia Grabher", nil, "AUT", 84),
            ("Rebecca Sramkova", nil, "SVK", 57),
            // Match 32: Rakotomanga Rajaonah vs [6] Anisimova
            ("Tessah Rakotomanga Rajaonah", nil, "FRA", 130),
            ("Amanda Anisimova", 6, "USA", 6),
            // Match 33: [7] Svitolina vs Bondar
            ("Elina Svitolina", 7, "UKR", 7),
            ("Anna Bondar", nil, "HUN", 71),
            // Match 34: Quevedo vs Jeanjean
            ("Karen Quevedo", nil, "ESP", 112),
            ("Leolia Jeanjean", nil, "FRA", 86),
            // Match 35: Sorribes Tormo vs Korpatsch
            ("Sara Sorribes Tormo", nil, "ESP", 73),
            ("Tamara Korpatsch", nil, "GER", 77),
            // Match 36: Tagger vs [32] Wang Xinyu
            ("Lina Tagger", nil, "AUT", 102),
            ("Wang Xinyu", 32, "CHN", 32),
            // Match 37: [21] Tauson vs Snigur
            ("Clara Tauson", 21, "DEN", 21),
            ("Daria Snigur", nil, "UKR", 96),
            // Match 38: Kenin vs Stearns
            ("Sofia Kenin", nil, "USA", 69),
            ("Peyton Stearns", nil, "USA", 67),
            // Match 39: Tomljanovic vs McNally
            ("Ajla Tomljanovic", nil, "AUS", 79),
            ("Catherine McNally", nil, "USA", 83),
            // Match 40: Kraus vs [11] Bencic
            ("Sinja Kraus", nil, "AUT", 104),
            ("Belinda Bencic", 11, "SUI", 11),
            // Match 41: [15] Kostyuk vs Selekhmeteva
            ("Marta Kostyuk", 15, "UKR", 15),
            ("Oksana Selekhmeteva", nil, "RUS", 87),
            // Match 42: Volynets vs Burel
            ("Katie Volynets", nil, "USA", 61),
            ("Clara Burel", nil, "FRA", 59),
            // Match 43: Udvardy vs Golubic
            ("Panna Udvardy", nil, "HUN", 81),
            ("Viktorija Golubic", nil, "SUI", 93),
            // Match 44: Parks vs [24] Fernandez
            ("Alycia Parks", nil, "USA", 89),
            ("Leylah Fernandez", 24, "CAN", 24),
            // Match 45: [29] Ostapenko vs Seidel
            ("Jelena Ostapenko", 29, "LAT", 29),
            ("Ella Seidel", nil, "GER", 107),
            // Match 46: Valentova vs Linette
            ("Tereza Valentova", nil, "CZE", 43),
            ("Magda Linette", nil, "POL", 94),
            // Match 47: Bejlek vs Stephens
            ("Sara Bejlek", nil, "CZE", 35),
            ("Sloane Stephens", nil, "USA", 99),
            // Match 48: Jones vs [3] Swiatek
            ("Emerson Jones", nil, "AUS", 91),
            ("Iga Swiatek", 3, "POL", 3),
            // Match 49: [8] Andreeva vs Ferro
            ("Mirra Andreeva", 8, "RUS", 8),
            ("Fiona Ferro", nil, "FRA", 118),
            // Match 50: Bassols Ribera vs Arango
            ("Marina Bassols Ribera", nil, "ESP", 97),
            ("Emiliana Arango", nil, "COL", 103),
            // Match 51: F. Jones vs Haddad Maia
            ("Francesca Jones", nil, "GBR", 106),
            ("Beatriz Haddad Maia", nil, "BRA", 51),
            // Match 52: Bronzetti vs [27] Bouzkova
            ("Lucia Bronzetti", nil, "ITA", 74),
            ("Marie Bouzkova", 27, "CZE", 27),
            // Match 53: [20] Samsonova vs Teichmann
            ("Liudmila Samsonova", 20, "RUS", 20),
            ("Jil Teichmann", nil, "SUI", 101),
            // Match 54: Frech vs Ruse
            ("Magdalena Frech", nil, "POL", 49),
            ("Elena-Gabriela Ruse", nil, "ROU", 109),
            // Match 55: Rakhimova vs Cristian
            ("Kamilla Rakhimova", nil, "UZB", 111),
            ("Jaqueline Cristian", nil, "ROU", 33),
            // Match 56: Zakharova vs [10] Muchova
            ("Anastasia Zakharova", nil, "RUS", 114),
            ("Karolina Muchova", 10, "CZE", 10),
            // Match 57: [13] Paolini vs Yastremska
            ("Jasmine Paolini", 13, "ITA", 13),
            ("Dayana Yastremska", nil, "UKR", 45),
            // Match 58: Raducanu vs Sierra
            ("Emma Raducanu", nil, "GBR", 37),
            ("Solana Sierra", nil, "ARG", 113),
            // Match 59: Marcinko vs Lys
            ("Petra Marcinko", nil, "CRO", 117),
            ("Eva Lys", nil, "GER", 70),
            // Match 60: Efremova vs [18] Cirstea
            ("Karina Efremova", nil, "FRA", 122),
            ("Sorana Cirstea", 18, "ROU", 18),
            // Match 61: [26] Baptiste vs Krejcikova
            ("Hailey Baptiste", 26, "USA", 26),
            ("Barbora Krejcikova", nil, "CZE", 42),
            // Match 62: Kovinic vs Wang Xiyu
            ("Danka Kovinic", nil, "MNE", 100),
            ("Wang Xiyu", nil, "CHN", 44),
            // Match 63: Blinkova vs Starodubtseva
            ("Anna Blinkova", nil, "RUS", 82),
            ("Yuliya Starodubtseva", nil, "UKR", 76),
            // Match 64: Erjavec vs [2] Rybakina
            ("Veronika Erjavec", nil, "SLO", 128),
            ("Elena Rybakina", 2, "KAZ", 2),
        ]

        return drawEntries.enumerated().map { index, entry in
            TennisBracketPlayer(
                seed: entry.seed,
                drawPosition: index + 1,
                name: entry.name,
                country: entry.country,
                rank: entry.rank
            )
        }
    }
}

// MARK: - ESPN Draw Fetcher

struct ESPNTennisDrawFetcher: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// Fetch the 128-player main draw from ESPN's bracket page HTML.
    /// Parses player names, seeds, countries, and draw positions from the rendered bracket.
    func fetchDraw(grandSlam: GrandSlam, drawType: DrawType) async -> [TennisBracketPlayer] {
        let bracketPath: String
        switch grandSlam {
        case .australianOpen: bracketPath = "australian-open"
        case .frenchOpen: bracketPath = "french-open"
        case .wimbledon: bracketPath = "wimbledon"
        case .usOpen: bracketPath = "us-open"
        }

        let urlString: String
        switch drawType {
        case .atp:
            urlString = "https://www.espn.com/tennis/\(bracketPath)/bracket"
        case .wta:
            urlString = "https://www.espn.com/tennis/\(bracketPath)/bracket/_/type/wta"
        }

        guard let url = URL(string: urlString) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return [] }

            return parseDrawFromHTML(html: html)
        } catch {
            print("[TennisDraw] Error fetching bracket page: \(error)")
            return []
        }
    }

    /// Parse the ESPN bracket HTML to extract draw positions 1-128.
    /// ESPN renders first-round matchups in draw order. We extract player names,
    /// seeds, and country abbreviations from the bracket markup.
    private func parseDrawFromHTML(html: String) -> [TennisBracketPlayer] {
        var players: [TennisBracketPlayer] = []
        var seenNames = Set<String>()

        // ESPN bracket uses "Bracket__Match" containers with two competitors per match.
        // Each competitor has a name, seed badge, and country flag/abbrev.
        // We'll extract using regex patterns on the HTML.

        // Pattern 1: Extract competitor data blocks — look for player name + seed + country
        // ESPN uses patterns like: data-competitor-id, athlete display name, seed, flag

        // Strategy: Find all first-round matchup blocks, extract the two players from each.
        // ESPN renders R1 matchups first in the bracket, with 64 matches (128 competitors).

        // Look for competitor entries in the bracket HTML
        // ESPN format: class="Bracket__Competitor" with nested name and seed info

        // Try multiple extraction patterns
        let extracted = extractPlayersFromBracketHTML(html)
        if extracted.count >= 128 {
            return Array(extracted.prefix(128))
        }

        // Fallback: simpler regex-based extraction
        // ESPN bracket HTML typically has patterns like:
        // <span class="...truncate...">[seed] PlayerName</span>
        // and country info nearby

        // Extract all player name instances with optional seed prefix
        let namePattern = #"class=\"[^\"]*truncate[^\"]*\"[^>]*>(?:\s*<[^>]+>)*\s*(?:\[(\d+)\]\s*)?([A-Z][a-zÀ-ÿ\-']+(?:\s+[A-Za-zÀ-ÿ\-']+)+)"#
        if let regex = try? NSRegularExpression(pattern: namePattern, options: []) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, options: [], range: range)

            for match in matches {
                var seed: Int? = nil
                if let seedRange = Range(match.range(at: 1), in: html) {
                    seed = Int(html[seedRange])
                }
                if let nameRange = Range(match.range(at: 2), in: html) {
                    let name = String(html[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = TennisBracketEngine.normalizedName(name)
                    if !seenNames.contains(normalized) {
                        seenNames.insert(normalized)
                        let position = players.count + 1
                        players.append(TennisBracketPlayer(
                            seed: seed,
                            drawPosition: position,
                            name: name,
                            country: "---",
                            rank: seed ?? (position + 32)
                        ))
                    }
                }
                if players.count >= 128 { break }
            }
        }

        if players.count >= 128 {
            return Array(players.prefix(128))
        }

        print("[TennisDraw] Extracted \(players.count) players from HTML (need 128)")
        return players
    }

    /// More structured extraction from ESPN bracket HTML.
    private func extractPlayersFromBracketHTML(_ html: String) -> [TennisBracketPlayer] {
        var players: [TennisBracketPlayer] = []
        var seenNames = Set<String>()

        // ESPN's bracket page embeds data in __espnfitt__ or window.__espnfitt__ JSON
        // Try to extract structured data first
        if let jsonStart = html.range(of: "\"competitors\":[{"),
           let jsonData = extractJSONArray(from: html, startingNear: jsonStart.lowerBound) {
            // Parse competitor objects
            for item in jsonData {
                guard let name = item["displayName"] as? String ?? item["name"] as? String else { continue }
                let normalized = TennisBracketEngine.normalizedName(name)
                guard !seenNames.contains(normalized) else { continue }
                seenNames.insert(normalized)

                let seed = item["seed"] as? Int ?? (item["seed"] as? String).flatMap { Int($0) }
                let country = item["country"] as? String ?? item["flag"] as? String ?? "---"
                let rank = item["rank"] as? Int ?? seed ?? (players.count + 33)

                players.append(TennisBracketPlayer(
                    seed: seed,
                    drawPosition: players.count + 1,
                    name: name,
                    country: country,
                    rank: rank
                ))

                if players.count >= 128 { break }
            }
        }

        return players
    }

    /// Try to extract a JSON array from HTML near a given position.
    private func extractJSONArray(from html: String, startingNear: String.Index) -> [[String: Any]]? {
        // Find the nearest '[' before or after the position
        let searchRange = html.index(startingNear, offsetBy: -100, limitedBy: html.startIndex) ?? html.startIndex
        let substring = html[searchRange...]
        guard let bracketStart = substring.firstIndex(of: "[") else { return nil }

        var depth = 0
        var bracketEnd: String.Index?
        var idx = bracketStart
        while idx < html.endIndex {
            let char = html[idx]
            if char == "[" { depth += 1 }
            if char == "]" { depth -= 1 }
            if depth == 0 { bracketEnd = idx; break }
            idx = html.index(after: idx)
        }

        guard let end = bracketEnd else { return nil }
        let jsonStr = String(html[bracketStart...end])
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return parsed
    }
}

// MARK: - Bot Bracket Generator

struct TennisBracketBotDrafter {

    enum BotPersonality: CaseIterable {
        case chalkPicker
        case upsetHunter
        case darkHorse
        case balanced
        case homeAdvantage

        var noiseMultiplier: Double {
            switch self {
            case .chalkPicker: return 0.10
            case .upsetHunter: return 0.40
            case .darkHorse: return 0.25
            case .balanced: return 0.20
            case .homeAdvantage: return 0.25
            }
        }
    }

    static let botNames = [
        "AceServe", "BreakPoint", "NetRusher", "BaselinePro", "GrandSlamFan",
        "TennisGuru", "VolleyKing", "DropShotPro", "MatchPoint", "SetPoint",
        "TieBreaker", "DoubleFault", "TopSpin", "SliceServe", "ClayKing",
        "GrassCourtPro", "HardCourtHero", "RallyMaster", "ServiceAce", "CourtCraft",
        "Forecaster", "BracketBoss", "SlamPicker", "DeuceDropper", "WildCard",
        "Qualifier", "SeedBuster", "ChampPick", "DrawMaster", "GameSetMatch",
        "LobShot", "PassingShot", "BackhandAce", "ForehandKing", "PointBuilder",
        "ReturnAce", "SmashHit", "BallBasher", "SpinDoctor", "CourtMaster",
        "NetWinner", "LinePainter", "AngleFinder", "PowerServe", "TennisBrain"
    ]

    /// Generate bot entries with varied bracket picks.
    static func generateBotEntries(
        draw: [TennisBracketPlayer],
        grandSlam: GrandSlam,
        count: Int = 999,
        tournamentID: String = ""
    ) -> [TennisBracketEntry] {
        guard draw.count == 128 else { return [] }

        var entries: [TennisBracketEntry] = []
        let personalities = BotPersonality.allCases

        for i in 0..<count {
            let personality = personalities[i % personalities.count]
            // Append the bot index (1-based) to every name so 999 bots all
            // have unique handles. The previous formula reused the same
            // `baseName` for all 5 personality variants of the same name
            // slot, producing 5 identical "AceServe" rows in the leaderboard.
            let baseName = botNames[i % botNames.count]
            let botName = "\(baseName)\(i + 1)"

            // Seeded RNG keyed on (tournamentID, botIndex) makes picks
            // deterministic across regenerations. Without this, every
            // call to `generateBotPicks` used the global random source
            // and produced a fresh set of picks — so any path that
            // re-generated bots (insert failed silently, server fetch
            // returned <500 rows, stale-cache guard tripped, etc.)
            // shuffled the leaderboard between views even when the
            // user's score and the underlying draw hadn't changed.
            var rng = TennisBracketBotDrafter.makeSeededRNG(
                tournamentID: tournamentID, botIndex: i
            )
            guard let picks = generateBotPicks(
                draw: draw, personality: personality,
                grandSlam: grandSlam, rng: &rng
            ) else { continue }

            entries.append(TennisBracketEntry(
                id: UUID(),
                tournamentID: "",  // set by caller
                userID: nil,
                entryName: botName,
                picks: picks,
                totalPoints: 0,
                rank: 0,
                isBot: true,
                isCurrentUser: false
            ))
        }

        return entries
    }

    /// Generate a full 127-pick bracket for one bot.
    /// Splitmix64 — a small, fast, deterministic PRNG suitable for
    /// reproducible bot generation. Keyed off (tournamentID, botIndex)
    /// so any regeneration produces identical picks.
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static func makeSeededRNG(tournamentID: String, botIndex: Int) -> SeededRNG {
        // FNV-1a hash of "<tournamentID>#<index>" to seed the PRNG.
        var hash: UInt64 = 0xCBF29CE484222325
        let prime: UInt64 = 0x100000001B3
        for byte in tournamentID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        hash ^= UInt64(bitPattern: Int64(botIndex))
        hash = hash &* prime
        return SeededRNG(state: hash == 0 ? 0xDEADBEEF : hash)
    }

    private static func generateBotPicks(
        draw: [TennisBracketPlayer],
        personality: BotPersonality,
        grandSlam: GrandSlam,
        rng: inout SeededRNG
    ) -> [String: String]? {
        guard draw.count == 128 else { return nil }

        let sorted = draw.sorted { $0.drawPosition < $1.drawPosition }
        var picks: [String: String] = [:]

        // R1: simulate each of 64 matches
        var r1Winners: [Int: TennisBracketPlayer] = [:]  // match number → winner
        for matchNum in 1...64 {
            let p1 = sorted[(matchNum - 1) * 2]
            let p2 = sorted[(matchNum - 1) * 2 + 1]
            let prob = winProbability(player1: p1, player2: p2, personality: personality, grandSlam: grandSlam, rng: &rng)
            let winner = Double.random(in: 0...1, using: &rng) < prob ? p1 : p2
            let slot = TennisBracketEngine.matchSlot(round: "R1", matchNumber: matchNum)
            picks[slot] = winner.name
            r1Winners[matchNum] = winner
        }

        // Subsequent rounds
        var prevWinners = r1Winners
        for roundIndex in 1..<TennisBracketEngine.rounds.count {
            let round = TennisBracketEngine.rounds[roundIndex]
            let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
            var currentWinners: [Int: TennisBracketPlayer] = [:]

            for matchNum in 1...matchCount {
                let src1 = matchNum * 2 - 1
                let src2 = matchNum * 2
                guard let p1 = prevWinners[src1], let p2 = prevWinners[src2] else { continue }

                let prob = winProbability(player1: p1, player2: p2, personality: personality, grandSlam: grandSlam, rng: &rng)
                let winner = Double.random(in: 0...1, using: &rng) < prob ? p1 : p2
                let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
                picks[slot] = winner.name
                currentWinners[matchNum] = winner
            }

            prevWinners = currentWinners
        }

        return picks.count == TennisBracketEngine.totalPicks ? picks : nil
    }

    /// Probability that player1 wins, adjusted for personality.
    private static func winProbability(
        player1: TennisBracketPlayer,
        player2: TennisBracketPlayer,
        personality: BotPersonality,
        grandSlam: GrandSlam,
        rng: inout SeededRNG
    ) -> Double {
        let rank1 = max(1, Double(player1.rank))
        let rank2 = max(1, Double(player2.rank))
        let rankGap = abs(rank1 - rank2)
        let total = rank1 + rank2
        // Higher rank number = worse player, so rank2/total favors player1 when rank2 > rank1
        var prob = rank2 / total

        // Personality noise
        let noise = Double.random(in: -personality.noiseMultiplier...personality.noiseMultiplier, using: &rng)

        switch personality {
        case .upsetHunter:
            // Mildly flatten — still favor the chalk, just less strongly
            prob = 0.5 + (prob - 0.5) * 0.75 + noise
        case .chalkPicker:
            prob = 0.5 + (prob - 0.5) * 1.5 + noise
        case .homeAdvantage:
            prob += noise
            if player1.country == grandSlam.hostCountry { prob += 0.06 }
            if player2.country == grandSlam.hostCountry { prob -= 0.06 }
        default:
            prob += noise
        }

        // Chalk floor: top seeds against unseeded long-shots almost never lose early rounds.
        // Tennis Grand Slam R1/R2 upsets of #1-4 seeds vs. rank >30 are extremely rare.
        let topSeed1 = (player1.seed ?? 99) <= 4
        let topSeed2 = (player2.seed ?? 99) <= 4
        if topSeed1 && !topSeed2 && rank2 > 30 { prob = max(prob, 0.93) }
        if topSeed2 && !topSeed1 && rank1 > 30 { prob = min(prob, 0.07) }

        // Generic large-rank-gap floor: a 40+ rank delta almost always wins.
        if rankGap > 40 {
            if rank1 < rank2 { prob = max(prob, 0.85) } else { prob = min(prob, 0.15) }
        }

        return max(0.05, min(0.95, prob))
    }
}
